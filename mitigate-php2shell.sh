#!/usr/bin/env bash
#
# Script Mitigasi php2shell (CVE-2026-109618 & CVE-2026-109619)
# Mendukung Single PHP dan Multiple PHP (Remi SCL, Ubuntu/Debian PPA, cPanel, Plesk)
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

# b. Remi Software Collections (Multiple PHP di RHEL/AlmaLinux)
for d in /etc/opt/remi/php*/php.d; do
  [ -d "$d" ] && CONFIG_DIRS+=("$d")
done

# c. Red Hat Software Collections (rh-php*)
for d in /etc/opt/rh/rh-php*/php.d; do
  [ -d "$d" ] && CONFIG_DIRS+=("$d")
done

# d. Debian / Ubuntu / Ondrej PPA (cli, fpm, apache2 conf.d)
for d in /etc/php/*/*/conf.d; do
  [ -d "$d" ] && CONFIG_DIRS+=("$d")
done

# e. cPanel EasyApache 4
for d in /opt/cpanel/ea-php*/root/etc/php.d; do
  [ -d "$d" ] && CONFIG_DIRS+=("$d")
done

# f. Plesk PHP
for d in /opt/plesk/php/*/etc/php.d; do
  [ -d "$d" ] && CONFIG_DIRS+=("$d")
done

# Validasi apakah ada direktori yang ditemukan
if [ ${#CONFIG_DIRS[@]} -eq 0 ]; then
  echo -e "${RED}[ERROR] Tidak ditemukan direktori konfigurasi PHP di server ini!${NC}"
  exit 1
fi

echo -e "\n${YELLOW}[1/3] Menulis file konfigurasi mitigasi...${NC}"
APPLIED_COUNT=0
for dir in "${CONFIG_DIRS[@]}"; do
  target_file="$dir/$INI_FILENAME"
  echo "$INI_CONTENT" > "$target_file"
  chmod 644 "$target_file"
  echo -e " ${GREEN}✔${NC} Diterapkan ke: $target_file"
  APPLIED_COUNT=$((APPLIED_COUNT + 1))
done
echo -e "${GREEN}Berhasil menerapkan konfigurasi ke $APPLIED_COUNT direktori PHP.${NC}"

# 3. Restart / Reload service PHP dan Web Server yang AKTIF saja
echo -e "\n${YELLOW}[2/3] Memeriksa dan me-reload service yang sedang berjalan...${NC}"

# Pola nama service PHP-FPM dan Web Server
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

# Kumpulkan semua binary PHP yang tersedia
PHP_BINARIES=()

# Binary default di PATH
type -P php &>/dev/null && PHP_BINARIES+=("$(type -P php)")

# Binary Remi SCL (php74, php80, php81, php82, php83, php84, dll)
for b in $(compgen -c php 2>/dev/null | grep -E '^php[0-9]{2}$' | sort -u); do
  type -P "$b" &>/dev/null && PHP_BINARIES+=("$(type -P "$b")")
done

# Binary cPanel / Plesk jika ada
for b in /opt/cpanel/ea-php*/root/usr/bin/php /opt/plesk/php/*/bin/php; do
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
