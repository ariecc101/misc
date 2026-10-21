#!/usr/bin/env bash
#
# Script Mitigasi php2shell (CVE-2026-109618 & CVE-2026-109619)
# Mendukung Single PHP dan Multiple PHP:
# - Format titik: 7.4, 8.0, 8.1, 8.2, 8.4 (Debian/Ubuntu, Ondrej PPA, dsb)
# - Format angka: 74, 80, 81, 82, 84 (Remi SCL, cPanel, CloudLinux, dsb)
#

set -e

# Warna output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}     Script Mitigasi Kerentanan PHP (php2shell)     ${NC}"
echo -e "${BLUE}====================================================${NC}"

# 1. Pastikan dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Script ini harus dijalankan sebagai root (gunakan sudo).${NC}"
  exit 1
fi

INI_FILENAME="99-php2shell.ini"
INI_CONTENT="; Mitigasi php2shell CVE-2026-109619
session.upload_progress.enabled = 0
"

CONFIG_DIRS=()

# 2. Deteksi direktori konfigurasi PHP (Single & Multiple PHP)
# a. Standar RHEL / AlmaLinux / CentOS / Fedora
[ -d "/etc/php.d" ] && CONFIG_DIRS+=("/etc/php.d")

# b. Remi Software Collections (format php74, php80, php81, php82, php84)
for d in /etc/opt/remi/php*/php.d; do
  [ -d "$d" ] && CONFIG_DIRS+=("$d")
done

# c. Red Hat Software Collections (rh-php*)
for d in /etc/opt/rh/rh-php*/php.d; do
  [ -d "$d" ] && CONFIG_DIRS+=("$d")
done

# d. Debian / Ubuntu / Ondrej PPA (format 7.4, 8.0, 8.1, 8.2, 8.4 - conf.d & mods-available)
for d in /etc/php/*/*/conf.d /etc/php/*/mods-available; do
  [ -d "$d" ] && CONFIG_DIRS+=("$d")
done

# e. cPanel EasyApache 4 (ea-php74, ea-php81, ea-php82, dsb)
for d in /opt/cpanel/ea-php*/root/etc/php.d; do
  [ -d "$d" ] && CONFIG_DIRS+=("$d")
done

# f. Plesk PHP (format php/7.4/etc/php.d, php/8.2/etc/php.d, dsb)
for d in /opt/plesk/php/*/etc/php.d; do
  [ -d "$d" ] && CONFIG_DIRS+=("$d")
done

# Buang duplikat direktori jika ada
UNIQUE_CONFIG_DIRS=($(printf "%s\n" "${CONFIG_DIRS[@]}" | sort -u))

# Validasi apakah ada direktori yang ditemukan
if [ ${#UNIQUE_CONFIG_DIRS[@]} -eq 0 ]; then
  echo -e "${RED}[ERROR] Tidak ditemukan direktori konfigurasi PHP di server ini!${NC}"
  exit 1
fi

echo -e "\n${YELLOW}[1/3] Menulis file konfigurasi mitigasi...${NC}"
APPLIED_COUNT=0
for dir in "${UNIQUE_CONFIG_DIRS[@]}"; do
  target_file="$dir/$INI_FILENAME"
  echo "$INI_CONTENT" > "$target_file"
  chmod 644 "$target_file"
  echo -e " ${GREEN}✔${NC} Diterapkan ke: $target_file"
  APPLIED_COUNT=$((APPLIED_COUNT + 1))
done
echo -e "${GREEN}Berhasil menerapkan konfigurasi ke $APPLIED_COUNT direktori PHP.${NC}"

# Aktifkan via phpenmod jika sistem mendukung (khusus Debian/Ubuntu)
if command -v phpenmod &>/dev/null; then
  phpenmod 99-php2shell 2>/dev/null || true
fi

# 3. Restart / Reload service PHP dan Web Server yang AKTIF saja
echo -e "\n${YELLOW}[2/3] Memeriksa dan me-reload service yang sedang berjalan...${NC}"

# Mendukung service: php-fpm, php74-php-fpm, php7.4-fpm, php8.2-fpm, httpd, apache2, nginx, lsws
SERVICES_PATTERN="php.*fpm|httpd|apache2|nginx|lsws"

ACTIVE_SERVICES=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null \
  | awk '{print $1}' \
  | grep -E "^($SERVICES_PATTERN)" || true)

if [ -n "$ACTIVE_SERVICES" ]; then
  for s in $ACTIVE_SERVICES; do
    echo -n " Merestart $s ... "
    if systemctl restart "$s"; then
      echo -e "${GREEN}[OK]${NC}"
    else
      echo -e "${RED}[GAGAL]${NC}"
    fi
  done
else
  echo -e "${YELLOW}Tidak ada service PHP-FPM/Web Server yang terdeteksi aktif via systemd.${NC}"
fi

# 4. Verifikasi Status Akhir
echo -e "\n${YELLOW}[3/3] Memverifikasi status session.upload_progress.enabled...${NC}"

PHP_BINARIES=()

# Binary default di PATH
type -P php &>/dev/null && PHP_BINARIES+=("$(type -P php)")

# Binary dalam PATH dengan format php74, php82 maupun format titik php7.4, php8.2
for b in $(compgen -c php 2>/dev/null | grep -E '^php([0-9]{2}|[0-9]+\.[0-9]+)$' | sort -u); do
  type -P "$b" &>/dev/null && PHP_BINARIES+=("$(type -P "$b")")
done

# Pencarian langsung di path umum (Debian, Ubuntu, Remi, cPanel, Plesk)
for b in /usr/bin/php \
         /usr/bin/php[0-9][0-9] \
         /usr/bin/php[0-9].[0-9] \
         /usr/local/bin/php \
         /usr/local/bin/php[0-9][0-9] \
         /usr/local/bin/php[0-9].[0-9] \
         /opt/cpanel/ea-php*/root/usr/bin/php \
         /opt/plesk/php/*/bin/php \
         /opt/remi/php*/root/usr/bin/php \
         /opt/rh/rh-php*/root/usr/bin/php; do
  [ -x "$b" ] && PHP_BINARIES+=("$b")
done

# Buang duplikat binary
UNIQUE_PHP=($(printf "%s\n" "${PHP_BINARIES[@]}" | sort -u))

ALL_SECURE=true
for bin in "${UNIQUE_PHP[@]}"; do
  val=$("$bin" -r 'echo ini_get("session.upload_progress.enabled");' 2>/dev/null || echo "ERR")
  ver=$("$bin" -r 'echo PHP_VERSION;' 2>/dev/null || echo "Unknown")
  
  if [ "$val" = "0" ] || [ "$val" = "" ]; then
    echo -e " ${GREEN}✔ [AMAN]${NC} $bin (PHP $ver): session.upload_progress.enabled = Off"
  else
    echo -e " ${RED}✖ [RENTAN]${NC} $bin (PHP $ver): session.upload_progress.enabled = On"
    ALL_SECURE=false
  fi
done

echo -e "\n${BLUE}====================================================${NC}"
if [ "$ALL_SECURE" = true ]; then
  echo -e "${GREEN}SELESAI: Seluruh instalasi PHP di server telah termitigasi!${NC}"
else
  echo -e "${RED}PERINGATAN: Ada versi PHP yang belum berhasil dimitigasi.${NC}"
fi
echo -e "${BLUE}====================================================${NC}"
