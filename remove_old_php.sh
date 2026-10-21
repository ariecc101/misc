#!/usr/bin/env bash
#
# Script: remove_old_php.sh
# Deskripsi: Menghapus paket PHP versi lama (PHP 5.x s/d 8.1) pada sistem RedHat dan Debian/Ubuntu.
#            Mendukung opsi --dry-run untuk simulasi aman.
#

set -uo pipefail

DRY_RUN=false
AUTO_CONFIRM=false

# Warna output terminal
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

usage() {
    echo -e "${BOLD}Penggunaan:${NC} $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d, --dry-run     Mode simulasi (menampilkan paket/service yang akan dihapus tanpa mengeksekusi)"
    echo "  -y, --yes         Lewati konfirmasi interaktif saat eksekusi langsung"
    echo "  -h, --help        Tampilkan bantuan ini"
    echo ""
    echo -e "${YELLOW}Catatan: Script ini HANYA menargetkan PHP 5.4 - 8.1. PHP >= 8.2 tidak akan disentuh.${NC}"
    exit 0
}

# Parsing argument
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -y|--yes)
            AUTO_CONFIRM=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}[ERROR] Argumen tidak dikenal: $1${NC}"
            usage
            ;;
    esac
done

# Pastikan dijalankan sebagai root (jika bukan dry-run)
if [ "$DRY_RUN" = false ] && [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Script harus dijalankan sebagai root (atau gunakan sudo).${NC}"
    exit 1
fi

# Deteksi Keluarga OS
OS_FAMILY=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}" in
        rhel|centos|almalinux|rocky|fedora|ol)
            OS_FAMILY="redhat"
            ;;
        debian|ubuntu|pop|mint)
            OS_FAMILY="debian"
            ;;
        *)
            if [[ "${ID_LIKE:-}" =~ (rhel|centos|fedora) ]]; then
                OS_FAMILY="redhat"
            elif [[ "${ID_LIKE:-}" =~ (debian|ubuntu) ]]; then
                OS_FAMILY="debian"
            fi
            ;;
    esac
fi

if [ -z "$OS_FAMILY" ]; then
    echo -e "${RED}[ERROR] Sistem operasi tidak dikenali sebagai turunan RedHat atau Debian.${NC}"
    exit 1
fi

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Pembersihan Versi PHP Lama (5.x s/d 8.1)${NC}"
echo -e " Sistem Operasi : ${BOLD}${PRETTY_NAME:-$OS_FAMILY}${NC} (Kategori: ${BOLD}$OS_FAMILY${NC})"
if [ "$DRY_RUN" = true ]; then
    echo -e " Mode Operasi   : ${YELLOW}${BOLD}DRY RUN (Simulasi - Tanpa Menghapus Apapun)${NC}"
else
    echo -e " Mode Operasi   : ${RED}${BOLD}EKSEKUSI PENGHAPUSAN LANGSUNG${NC}"
fi
echo -e "${CYAN}============================================================${NC}"

# Target versi PHP yang akan dihapus: 5.4 s/d 8.1
RHEL_VERSIONS=("php54" "php55" "php56" "php70" "php71" "php72" "php73" "php74" "php80" "php81")
DEB_VERSIONS=("5.4" "5.5" "5.6" "7.0" "7.1" "7.2" "7.3" "7.4" "8.0" "8.1")

INSTALLED_PACKAGES=()
SERVICES_TO_STOP=()
DIRS_TO_CLEAN=()

echo -e "${BLUE}[*] Memeriksa paket dan service yang terpasang...${NC}"

if [ "$OS_FAMILY" = "redhat" ]; then
    # Cari package Remi / SCL
    for ver in "${RHEL_VERSIONS[@]}"; do
        # Cari paket rpm yang terpasang
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && INSTALLED_PACKAGES+=("$pkg")
        done < <(rpm -qa | grep -E "^${ver}(-|$)" || true)

        # Cek systemd service
        if systemctl list-unit-files "${ver}-php-fpm.service" &>/dev/null; then
            SERVICES_TO_STOP+=("${ver}-php-fpm.service")
        fi

        # Cek direktori konfigurasi
        [ -d "/etc/opt/remi/${ver}" ] && DIRS_TO_CLEAN+=("/etc/opt/remi/${ver}")
        [ -d "/var/opt/remi/${ver}" ] && DIRS_TO_CLEAN+=("/var/opt/remi/${ver}")
        [ -d "/opt/remi/${ver}" ] && DIRS_TO_CLEAN+=("/opt/remi/${ver}")
    done

elif [ "$OS_FAMILY" = "debian" ]; then
    # Cari package Sury / Debian
    for ver in "${DEB_VERSIONS[@]}"; do
        # Cari paket dpkg yang terpasang
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && INSTALLED_PACKAGES+=("$pkg")
        done < <(dpkg-query -W -f='${binary:Package} ${Status}\n' "php${ver}*" 2>/dev/null | awk '/install ok installed/{print $1}' || true)

        # Cek systemd service
        if systemctl list-unit-files "php${ver}-fpm.service" &>/dev/null; then
            SERVICES_TO_STOP+=("php${ver}-fpm.service")
        fi

        # Cek direktori konfigurasi
        [ -d "/etc/php/${ver}" ] && DIRS_TO_CLEAN+=("/etc/php/${ver}")
        [ -d "/var/log/php${ver}-fpm" ] && DIRS_TO_CLEAN+=("/var/log/php${ver}-fpm")
    done
fi

# Tampilkan hasil deteksi
if [ ${#INSTALLED_PACKAGES[@]} -eq 0 ] && [ ${#SERVICES_TO_STOP[@]} -eq 0 ]; then
    echo -e "${GREEN}[INFO] Tidak ditemukan paket atau service PHP 5.x - 8.1 di sistem ini.${NC}"
    echo "Sistem Anda sudah bersih dari PHP lama."
    exit 0
fi

if [ ${#SERVICES_TO_STOP[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}[!] Service PHP-FPM yang akan dihentikan & didisable:${NC}"
    for svc in "${SERVICES_TO_STOP[@]}"; do
        echo -e "    - $svc"
    done
fi

if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}[!] Paket PHP (${#INSTALLED_PACKAGES[@]} paket) yang akan dihapus:${NC}"
    for pkg in "${INSTALLED_PACKAGES[@]}"; do
        echo -e "    - $pkg"
    done
fi

if [ ${#DIRS_TO_CLEAN[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}[!] Direktori konfigurasi/data sisa yang akan dibersihkan:${NC}"
    for d in "${DIRS_TO_CLEAN[@]}"; do
        echo -e "    - $d"
    done
fi

echo -e "\n${CYAN}------------------------------------------------------------${NC}"

# Jika mode DRY RUN, keluar setelah menampilkan
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}${BOLD}[DRY RUN SELESAI]${NC} Tidak ada perubahan yang dilakukan pada sistem."
    echo -e "Untuk menghapus paket-paket di atas secara nyata, jalankan: ${BOLD}$0${NC}"
    exit 0
fi

# Konfirmasi interaktif jika bukan dry run dan tanpa -y
if [ "$AUTO_CONFIRM" = false ]; then
    echo -e "${RED}${BOLD}PERINGATAN: Penghapusan paket bersifat permanen!${NC}"
    echo -e "Pastikan tidak ada website yang masih bergantung pada versi PHP di atas."
    read -rp "Apakah Anda yakin ingin melanjutkan penghapusan? (ketik 'yes' untuk lanjut): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${BLUE}[BATAL] Proses dibatalkan oleh pengguna.${NC}"
        exit 0
    fi
fi

echo -e "\n${BLUE}[1/4] Menghentikan dan mendisable service PHP-FPM...${NC}"
for svc in "${SERVICES_TO_STOP[@]}"; do
    echo "    Menghentikan $svc..."
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
done

echo -e "\n${BLUE}[2/4] Menghapus paket PHP lama...${NC}"
if [ "$OS_FAMILY" = "redhat" ]; then
    PKG_MGR="dnf"
    command -v dnf &>/dev/null || PKG_MGR="yum"
    $PKG_MGR remove -y "${INSTALLED_PACKAGES[@]}"
elif [ "$OS_FAMILY" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y "${INSTALLED_PACKAGES[@]}"
    apt-get autoremove -y
fi

echo -e "\n${BLUE}[3/4] Membersihkan direktori sisa konfigurasi...${NC}"
for d in "${DIRS_TO_CLEAN[@]}"; do
    if [ -d "$d" ]; then
        echo "    Menghapus direktori: $d"
        rm -rf "$d"
    fi
done

echo -e "\n${BLUE}[4/4] Memperbarui daftar versi PHP Virtualmin...${NC}"
if command -v virtualmin &>/dev/null; then
    echo "    Memeriksa versi PHP yang tersisa di Virtualmin..."
    virtualmin list-php-versions
fi

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN} SELESAI! Semua versi PHP 5.x - 8.1 telah berhasil dihapus.${NC}"
echo -e "${GREEN}============================================================${NC}"
