#!/usr/bin/env bash
# ==============================================================================
# Script: switch-almalinux-repo.sh
# Deskripsi: Mengalihkan konfigurasi repository ke repository resmi utama
#            AlmaLinux (https://repo.almalinux.org) secara universal (v8, v9, v10).
# Penggunaan:
#   curl -fsSL <URL_RAW_SCRIPT> | bash
#   atau:
#   bash switch-almalinux-repo.sh
# ==============================================================================

set -eo pipefail

# Warna output terminal
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# 1. Pastikan dijalankan sebagai root
if [[ "$EUID" -ne 0 ]]; then
    log_error "Script ini harus dijalankan dengan hak akses root (sudo)."
    exit 1
fi

echo -e "${BOLD}${CYAN}====================================================${NC}"
echo -e "${BOLD}${CYAN}   AlmaLinux Official Main Repository Switcher     ${NC}"
echo -e "${BOLD}${CYAN}====================================================${NC}"

# 2. Verifikasi sistem operasi
if [[ ! -f /etc/os-release ]]; then
    log_error "File /etc/os-release tidak ditemukan. Tidak dapat mendeteksi OS."
    exit 1
fi

# Load variabel OS
. /etc/os-release

if [[ "${ID:-}" != "almalinux" ]]; then
    log_error "Sistem ini bukan AlmaLinux (terdeteksi: '${ID:-unknown}'). Script dibatalkan."
    exit 1
fi

MAJOR_VERSION="${VERSION_ID%%.*}"
log_info "Sistem terdeteksi : ${PRETTY_NAME:-AlmaLinux} (Major Version: ${MAJOR_VERSION})"
log_info "Arsitektur       : $(uname -m)"

# 3. Buat backup repository yang ada
REPOS_DIR="/etc/yum.repos.d"
BACKUP_DIR="${REPOS_DIR}/backup-almarepo-$(date +%Y%m%d_%H%M%S)"

log_info "Membuat backup konfigurasi repo ke: ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}"
if compgen -G "${REPOS_DIR}/*.repo" > /dev/null; then
    cp -p "${REPOS_DIR}"/*.repo "${BACKUP_DIR}/"
    log_success "Backup selesai."
else
    log_warn "Tidak ada file .repo yang ditemukan di ${REPOS_DIR}."
fi

# 4. Fungsi universal AWK untuk migrasi repo file ke repo.almalinux.org
migrate_repo_file() {
    local file="$1"
    local temp_file
    temp_file=$(mktemp)

    awk '
    function get_path(s) {
        if (s == "baseos") return "BaseOS/$basearch/os/"
        if (s == "appstream") return "AppStream/$basearch/os/"
        if (s == "extras") return "extras/$basearch/os/"
        if (s == "powertools") return "PowerTools/$basearch/os/"
        if (s == "crb") return "CRB/$basearch/os/"
        if (s == "ha" || s == "highavailability") return "HighAvailability/$basearch/os/"
        if (s == "plus") return "plus/$basearch/os/"
        if (s == "rt") return "RT/$basearch/os/"
        if (s == "resilientstorage") return "ResilientStorage/$basearch/os/"
        if (s == "nfv") return "NFV/$basearch/os/"
        if (s == "sap") return "SAP/$basearch/os/"
        if (s == "saphana") return "SAPHANA/$basearch/os/"
        return ""
    }

    function flush_sec() {
        if (target_path != "" && !has_baseurl) {
            print "baseurl=https://repo.almalinux.org/almalinux/$releasever/" target_path
            has_baseurl = 1
        }
    }

    BEGIN {
        sec = ""
        target_path = ""
        has_baseurl = 0
        in_continuation = 0
    }

    /^\[.*\]/ {
        flush_sec()
        match($0, /\[(.*)\]/, m)
        sec = m[1]
        target_path = get_path(sec)
        has_baseurl = 0
        in_continuation = 0
        print $0
        next
    }

    in_continuation && /^[ \t]+/ {
        next
    }

    {
        in_continuation = 0
    }

    /^[ \t]*#*[ \t]*mirrorlist=/ {
        if (target_path != "") {
            sub(/^[ \t]*#*[ \t]*/, "#")
            print $0
            if (!has_baseurl) {
                print "baseurl=https://repo.almalinux.org/almalinux/$releasever/" target_path
                has_baseurl = 1
            }
            next
        }
    }

    /^[ \t]*#*[ \t]*baseurl=/ {
        if (target_path != "") {
            in_continuation = 1
            if (!has_baseurl) {
                print "baseurl=https://repo.almalinux.org/almalinux/$releasever/" target_path
                has_baseurl = 1
            }
            next
        }
    }

    {
        print $0
    }

    END {
        flush_sec()
    }
    ' "$file" > "$temp_file"

    chmod --reference="$file" "$temp_file" 2>/dev/null || chmod 644 "$temp_file"
    mv "$temp_file" "$file"
}

# 5. Eksekusi pengalihan repo AlmaLinux
shopt -s nullglob
alma_repos=("${REPOS_DIR}"/almalinux*.repo)
shopt -u nullglob

if [[ ${#alma_repos[@]} -gt 0 ]]; then
    log_info "Memperbarui file repo AlmaLinux yang ada:"
    for repo_file in "${alma_repos[@]}"; do
        base_name=$(basename "$repo_file")
        # Lewati file backup atau testing jika bukan repo rilis utama
        if [[ "$base_name" == *"testing"* ]]; then
            continue
        fi
        log_info " - Memperbarui ${base_name}..."
        migrate_repo_file "$repo_file"
    done
    log_success "File repo AlmaLinux berhasil diperbarui."
else
    # Jika tidak ada file repo almalinux (misal terhapus), buatkan fresh template
    log_warn "File almalinux*.repo tidak ditemukan. Membuat template repo resmi baru..."
    if [[ "$MAJOR_VERSION" -eq 8 ]]; then
        cat << 'EOF' > "${REPOS_DIR}/almalinux.repo"
# almalinux.repo (Official Main Repository)
[baseos]
name=AlmaLinux $releasever - BaseOS
#mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/baseos
baseurl=https://repo.almalinux.org/almalinux/$releasever/BaseOS/$basearch/os/
enabled=1
gpgcheck=1
countme=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux

[appstream]
name=AlmaLinux $releasever - AppStream
#mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/appstream
baseurl=https://repo.almalinux.org/almalinux/$releasever/AppStream/$basearch/os/
enabled=1
gpgcheck=1
countme=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux

[extras]
name=AlmaLinux $releasever - Extras
#mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/extras
baseurl=https://repo.almalinux.org/almalinux/$releasever/extras/$basearch/os/
enabled=1
gpgcheck=1
countme=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux
EOF
        cat << 'EOF' > "${REPOS_DIR}/almalinux-powertools.repo"
# almalinux-powertools.repo (Official Main Repository)
[powertools]
name=AlmaLinux $releasever - PowerTools
#mirrorlist=https://mirrors.almalinux.org/mirrorlist/$releasever/powertools
baseurl=https://repo.almalinux.org/almalinux/$releasever/PowerTools/$basearch/os/
enabled=0
gpgcheck=1
countme=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux
EOF
    else
        # AlmaLinux 9 / 10
        GPG_KEY_NAME="RPM-GPG-KEY-AlmaLinux-${MAJOR_VERSION}"
        cat << EOF > "${REPOS_DIR}/almalinux-baseos.repo"
[baseos]
name=AlmaLinux \$releasever - BaseOS
#mirrorlist=https://mirrors.almalinux.org/mirrorlist/\$releasever/baseos
baseurl=https://repo.almalinux.org/almalinux/\$releasever/BaseOS/\$basearch/os/
enabled=1
gpgcheck=1
countme=1
gpgkey=file:///etc/pki/rpm-gpg/${GPG_KEY_NAME}
EOF
        cat << EOF > "${REPOS_DIR}/almalinux-appstream.repo"
[appstream]
name=AlmaLinux \$releasever - AppStream
#mirrorlist=https://mirrors.almalinux.org/mirrorlist/\$releasever/appstream
baseurl=https://repo.almalinux.org/almalinux/\$releasever/AppStream/\$basearch/os/
enabled=1
gpgcheck=1
countme=1
gpgkey=file:///etc/pki/rpm-gpg/${GPG_KEY_NAME}
EOF
        cat << EOF > "${REPOS_DIR}/almalinux-crb.repo"
[crb]
name=AlmaLinux \$releasever - CRB
#mirrorlist=https://mirrors.almalinux.org/mirrorlist/\$releasever/crb
baseurl=https://repo.almalinux.org/almalinux/\$releasever/CRB/\$basearch/os/
enabled=0
gpgcheck=1
countme=1
gpgkey=file:///etc/pki/rpm-gpg/${GPG_KEY_NAME}
EOF
        cat << EOF > "${REPOS_DIR}/almalinux-extras.repo"
[extras]
name=AlmaLinux \$releasever - Extras
#mirrorlist=https://mirrors.almalinux.org/mirrorlist/\$releasever/extras
baseurl=https://repo.almalinux.org/almalinux/\$releasever/extras/\$basearch/os/
enabled=1
gpgcheck=1
countme=1
gpgkey=file:///etc/pki/rpm-gpg/${GPG_KEY_NAME}
EOF
    fi
    log_success "Template repo resmi berhasil dibuat."
fi

# 6. Pembersihan & Pembaruan Cache DNF/YUM
log_info "Membersihkan dan merefresh metadata DNF..."
dnf clean all > /dev/null 2>&1 || yum clean all > /dev/null 2>&1

log_info "Mengambil metadata repo resmi utama..."
if dnf makecache --timer > /dev/null 2>&1 || dnf makecache > /dev/null 2>&1 || yum makecache > /dev/null 2>&1; then
    log_success "Metadata DNF berhasil diperbarui dari repo resmi!"
else
    log_warn "DNF makecache selesai dengan beberapa peringatan, memeriksa repolist..."
fi

echo -e "\n${BOLD}${CYAN}Daftar Repositori Aktif Saat Ini:${NC}"
dnf repolist

echo -e "\n${BOLD}${GREEN}====================================================${NC}"
echo -e "${BOLD}${GREEN}  Sukses! Repo AlmaLinux telah dialihkan ke:        ${NC}"
echo -e "${BOLD}${GREEN}  https://repo.almalinux.org                        ${NC}"
echo -e "${BOLD}${GREEN}====================================================${NC}"
echo -e "Catatan:"
echo -e " - Backup konfigurasi lama tersimpan di: ${CYAN}${BACKUP_DIR}${NC}"
echo -e " - Jalankan '${YELLOW}dnf check-update${NC}' untuk memeriksa update paket terbaru."
