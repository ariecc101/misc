#!/usr/bin/env bash
#
# Script: remove_old_php.sh
# Deskripsi: Menghapus paket PHP versi lama (PHP 5.x s/d 8.1) pada sistem RedHat dan Debian/Ubuntu,
#            serta memastikan base PHP sistem default (/bin/php) beralih ke minimal PHP 8.2.
#            Mendukung opsi --dry-run dan penanganan lock apt/dpkg otomatis.
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
    echo "  -d, --dry-run     Mode simulasi (menampilkan aksi yang akan dilakukan tanpa eksekusi)"
    echo "  -y, --yes         Lewati konfirmasi interaktif saat eksekusi langsung"
    echo "  -h, --help        Tampilkan bantuan ini"
    echo ""
    echo -e "${YELLOW}Catatan: Script ini menargetkan PHP 5.4 - 8.1 dan memastikan default sistem menggunakan PHP 8.2.${NC}"
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

# Fungsi menunggu lock APT / DPKG di Debian/Ubuntu
wait_for_apt_lock() {
    local max_wait=180
    local waited=0
    local lock_files=("/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock" "/var/lib/apt/lists/lock")
    
    while true; do
        local is_locked=false
        local lock_pids=""

        for lf in "${lock_files[@]}"; do
            if [ -f "$lf" ]; then
                local p=""
                if command -v fuser &>/dev/null; then
                    p=$(fuser "$lf" 2>/dev/null || true)
                elif command -v lsof &>/dev/null; then
                    p=$(lsof -t "$lf" 2>/dev/null || true)
                fi
                if [ -n "$p" ]; then
                    is_locked=true
                    lock_pids="$lock_pids $p"
                fi
            fi
        done

        if [ "$is_locked" = false ]; then
            break
        fi

        echo -e "${YELLOW}[!] APT/dpkg sedang dikunci proses lain (PID:${lock_pids}). Menunggu... (${waited}s / ${max_wait}s)${NC}"
        sleep 3
        waited=$((waited + 3))

        if [ $waited -ge $max_wait ]; then
            echo -e "${RED}[ERROR] Timeout menunggu lock APT dilepas oleh proses PID:${lock_pids}.${NC}"
            echo -e "${YELLOW}[TIPS] Anda bisa mengecek proses dengan: ps -fp${lock_pids}${NC}"
            return 1
        fi
    done
    return 0
}

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Pembersihan Versi PHP Lama & Pengaturan PHP 8.2 Default${NC}"
echo -e " Sistem Operasi : ${BOLD}${PRETTY_NAME:-$OS_FAMILY}${NC} (Kategori: ${BOLD}$OS_FAMILY${NC})"
if [ "$DRY_RUN" = true ]; then
    echo -e " Mode Operasi   : ${YELLOW}${BOLD}DRY RUN (Simulasi - Tanpa Menghapus/Mengubah Apapun)${NC}"
else
    echo -e " Mode Operasi   : ${RED}${BOLD}EKSEKUSI LANGSUNG${NC}"
fi
echo -e "${CYAN}============================================================${NC}"

# 1. Cek Versi PHP Default Sistem Saat Ini (/bin/php)
CURRENT_BASE_PHP=""
if command -v php &>/dev/null; then
    CURRENT_BASE_PHP=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)
fi

NEED_BASE_UPGRADE=false
if [ -n "$CURRENT_BASE_PHP" ]; then
    IS_OLD=$(awk -v ver="$CURRENT_BASE_PHP" 'BEGIN {
        if (ver ~ /^[0-9]+(\.[0-9]+)?$/) {
            split(ver, a, ".")
            maj = a[1] + 0; min = a[2] + 0
            if (maj < 8 || (maj == 8 && min < 2)) {
                print "yes"
                exit
            }
        }
        print "no"
    }')
    if [ "$IS_OLD" = "yes" ]; then
        NEED_BASE_UPGRADE=true
    fi
fi

# 2. Target versi PHP lama multi-version (5.4 s/d 8.1)
RHEL_VERSIONS=("php54" "php55" "php56" "php70" "php71" "php72" "php73" "php74" "php80" "php81")
DEB_VERSIONS=("5.4" "5.5" "5.6" "7.0" "7.1" "7.2" "7.3" "7.4" "8.0" "8.1")

INSTALLED_PACKAGES=()
SERVICES_TO_STOP=()
DIRS_TO_CLEAN=()

echo -e "${BLUE}[*] Memeriksa paket dan service yang terpasang...${NC}"

if [ "$OS_FAMILY" = "redhat" ]; then
    for ver in "${RHEL_VERSIONS[@]}"; do
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && INSTALLED_PACKAGES+=("$pkg")
        done < <(rpm -qa | grep -E "^${ver}(-|$)" || true)

        if systemctl list-unit-files "${ver}-php-fpm.service" &>/dev/null; then
            SERVICES_TO_STOP+=("${ver}-php-fpm.service")
        fi

        [ -d "/etc/opt/remi/${ver}" ] && DIRS_TO_CLEAN+=("/etc/opt/remi/${ver}")
        [ -d "/var/opt/remi/${ver}" ] && DIRS_TO_CLEAN+=("/var/opt/remi/${ver}")
        [ -d "/opt/remi/${ver}" ] && DIRS_TO_CLEAN+=("/opt/remi/${ver}")
    done

elif [ "$OS_FAMILY" = "debian" ]; then
    for ver in "${DEB_VERSIONS[@]}"; do
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && INSTALLED_PACKAGES+=("$pkg")
        done < <(dpkg-query -W -f='${binary:Package} ${Status}\n' "php${ver}*" 2>/dev/null | awk '/install ok installed/{print $1}' || true)

        if systemctl list-unit-files "php${ver}-fpm.service" &>/dev/null; then
            SERVICES_TO_STOP+=("php${ver}-fpm.service")
        fi

        [ -d "/etc/php/${ver}" ] && DIRS_TO_CLEAN+=("/etc/php/${ver}")
        [ -d "/var/log/php${ver}-fpm" ] && DIRS_TO_CLEAN+=("/var/log/php${ver}-fpm")
    done
fi

# Tampilkan ringkasan status base PHP
if [ "$NEED_BASE_UPGRADE" = true ]; then
    echo -e "${YELLOW}${BOLD}[!] Base PHP Sistem (/bin/php): PHP $CURRENT_BASE_PHP (< 8.2)${NC}"
    echo -e "    -> Akan dialihkan dan di-upgrade ke ${GREEN}${BOLD}PHP 8.2 sebagai default${NC}"
else
    echo -e "${GREEN}[OK] Base PHP Sistem (/bin/php): PHP ${CURRENT_BASE_PHP:-Tidak terpasang} (>= 8.2)${NC}"
fi

# Tampilkan hasil deteksi paket lama
if [ ${#SERVICES_TO_STOP[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}[!] Service PHP-FPM lama yang akan dihentikan & didisable:${NC}"
    for svc in "${SERVICES_TO_STOP[@]}"; do
        echo -e "    - $svc"
    done
fi

if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}[!] Paket PHP lama (${#INSTALLED_PACKAGES[@]} paket) yang akan dihapus:${NC}"
    for pkg in "${INSTALLED_PACKAGES[@]}"; do
        echo -e "    - $pkg"
    done
fi

if [ ${#DIRS_TO_CLEAN[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}${BOLD}[!] Direktori sisa yang akan dibersihkan:${NC}"
    for d in "${DIRS_TO_CLEAN[@]}"; do
        echo -e "    - $d"
    done
fi

if [ "$NEED_BASE_UPGRADE" = false ] && [ ${#INSTALLED_PACKAGES[@]} -eq 0 ] && [ ${#SERVICES_TO_STOP[@]} -eq 0 ]; then
    echo -e "\n${GREEN}[INFO] Sistem sudah menggunakan PHP >= 8.2 sebagai default dan tidak ada paket PHP lama (5.x - 8.1).${NC}"
    exit 0
fi

echo -e "\n${CYAN}------------------------------------------------------------${NC}"

# Jika mode DRY RUN, keluar setelah menampilkan
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}${BOLD}[DRY RUN SELESAI]${NC} Tidak ada perubahan yang dilakukan pada sistem."
    echo -e "Untuk mengeksekusi secara nyata, jalankan: ${BOLD}$0${NC}"
    exit 0
fi

# Konfirmasi interaktif jika bukan dry run dan tanpa -y
if [ "$AUTO_CONFIRM" = false ]; then
    echo -e "${RED}${BOLD}PERINGATAN: Perubahan akan diterapkan pada sistem!${NC}"
    read -rp "Apakah Anda yakin ingin melanjutkan? (ketik 'yes' untuk lanjut): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${BLUE}[BATAL] Proses dibatalkan oleh pengguna.${NC}"
        exit 0
    fi
fi

# 1. Hentikan Service PHP Lama
if [ ${#SERVICES_TO_STOP[@]} -gt 0 ]; then
    echo -e "\n${BLUE}[1/5] Menghentikan dan mendisable service PHP-FPM lama...${NC}"
    for svc in "${SERVICES_TO_STOP[@]}"; do
        echo "    Menghentikan $svc..."
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    done
fi

# 2. Upgrade Base PHP Sistem ke 8.2 jika masih < 8.2
if [ "$NEED_BASE_UPGRADE" = true ]; then
    echo -e "\n${BLUE}[2/5] Mengalihkan default base PHP (/bin/php) ke PHP 8.2...${NC}"
    if [ "$OS_FAMILY" = "redhat" ]; then
        if command -v dnf &>/dev/null; then
            echo "    Mengaktifkan module stream php:remi-8.2..."
            dnf module reset php -y || true
            dnf module enable php:remi-8.2 -y
            echo "    Memperbarui paket php sistem ke versi 8.2..."
            dnf update -y "php*" || dnf distro-sync -y --allowerasing
        fi
    elif [ "$OS_FAMILY" = "debian" ]; then
        export DEBIAN_FRONTEND=noninteractive
        APT_LOCK_OPTS=("-o" "DPkg::Lock::Timeout=180" "-o" "Dpkg::Options::=--force-confdef" "-o" "Dpkg::Options::=--force-confold")
        
        wait_for_apt_lock
        echo "    Memastikan repositori apt diperbarui..."
        apt-get "${APT_LOCK_OPTS[@]}" update -y || true

        wait_for_apt_lock
        echo "    Memasang runtime php8.2 jika belum lengkap..."
        apt-get "${APT_LOCK_OPTS[@]}" install -y php8.2 php8.2-cli php8.2-fpm php8.2-common

        if command -v update-alternatives &>/dev/null; then
            echo "    Mengatur update-alternatives ke php8.2..."
            update-alternatives --set php /usr/bin/php8.2 2>/dev/null || true
            update-alternatives --set phar /usr/bin/phar8.2 2>/dev/null || true
            update-alternatives --set phar.phar /usr/bin/phar.phar8.2 2>/dev/null || true
            update-alternatives --set phpize /usr/bin/phpize8.2 2>/dev/null || true
            update-alternatives --set php-config /usr/bin/php-config8.2 2>/dev/null || true
        fi
    fi
    echo -e "    ${GREEN}[OK] Base PHP sekarang: $(php -v 2>/dev/null | head -n1)${NC}"
fi

# 3. Hapus Paket PHP Lama Multi-Version
if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
    echo -e "\n${BLUE}[3/5] Menghapus paket PHP lama (5.x - 8.1)...${NC}"
    if [ "$OS_FAMILY" = "redhat" ]; then
        PKG_MGR="dnf"
        command -v dnf &>/dev/null || PKG_MGR="yum"
        if ! $PKG_MGR remove -y "${INSTALLED_PACKAGES[@]}"; then
            echo -e "${RED}[ERROR] Gagal menghapus paket PHP via $PKG_MGR.${NC}"
            exit 1
        fi
    elif [ "$OS_FAMILY" = "debian" ]; then
        export DEBIAN_FRONTEND=noninteractive
        APT_LOCK_OPTS=("-o" "DPkg::Lock::Timeout=180" "-o" "Dpkg::Options::=--force-confdef" "-o" "Dpkg::Options::=--force-confold")
        
        wait_for_apt_lock
        echo "    Menjalankan apt-get purge..."
        if ! apt-get "${APT_LOCK_OPTS[@]}" purge -y "${INSTALLED_PACKAGES[@]}"; then
            echo -e "${RED}[ERROR] Gagal menjalankan apt-get purge. Mencoba memulihkan status dpkg...${NC}"
            dpkg --configure -a || true
            wait_for_apt_lock
            apt-get "${APT_LOCK_OPTS[@]}" purge -y "${INSTALLED_PACKAGES[@]}" || {
                echo -e "${RED}[FATAL] Gagal menghapus paket PHP lama via apt-get.${NC}"
                exit 1
            }
        fi

        wait_for_apt_lock
        apt-get "${APT_LOCK_OPTS[@]}" autoremove -y || true
    fi
fi

# 4. Bersihkan Direktori Sisa
if [ ${#DIRS_TO_CLEAN[@]} -gt 0 ]; then
    echo -e "\n${BLUE}[4/5] Membersihkan direktori sisa konfigurasi...${NC}"
    for d in "${DIRS_TO_CLEAN[@]}"; do
        if [ -d "$d" ]; then
            echo "    Menghapus direktori: $d"
            rm -rf "$d"
        fi
    done
fi

# 5. Refresh Virtualmin
echo -e "\n${BLUE}[5/5] Memperbarui daftar versi PHP Virtualmin...${NC}"
if command -v virtualmin &>/dev/null; then
    echo "    Memeriksa versi PHP yang tersisa di Virtualmin:"
    virtualmin list-php-versions
fi

echo -e "\n${GREEN}============================================================${NC}"
echo -e "${GREEN} SELESAI! Default PHP sistem telah diatur ke 8.2 dan PHP lama telah dibersihkan.${NC}"
echo -e "${GREEN}============================================================${NC}"
