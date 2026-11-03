#!/usr/bin/env bash
# ==============================================================================
# Script: switch-to-oracle-linux-repo.sh
# Description: Universal script to switch any Enterprise Linux / Oracle Linux
#              system (OL 7, 8, 9, 10) to official upstream Oracle Linux
#              repositories (yum.oracle.com) that are always up-to-date.
# Author: System Administrator
# Usage: curl -fsSL <URL> | bash
#        or: bash switch-to-oracle-linux-repo.sh
# ==============================================================================

set -euo pipefail

# ANSI color codes
CLR_RESET="\033[0m"
CLR_INFO="\033[1;32m"
CLR_WARN="\033[1;33m"
CLR_ERR="\033[1;31m"
CLR_CYAN="\033[1;36m"
CLR_BOLD="\033[1m"

log_info() { echo -e "${CLR_INFO}[INFO]${CLR_RESET} $*"; }
log_warn() { echo -e "${CLR_WARN}[WARN]${CLR_RESET} $*"; }
log_err()  { echo -e "${CLR_ERR}[ERROR]${CLR_RESET} $*" >&2; }
log_step() { echo -e "\n${CLR_CYAN}==>${CLR_RESET} ${CLR_BOLD}$*${CLR_RESET}"; }

# ------------------------------------------------------------------------------
# 1. Root Check
# ------------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    log_err "Skrip ini harus dijalankan dengan hak akses root (sudo)."
    exit 1
fi

echo -e "${CLR_CYAN}==============================================================${CLR_RESET}"
echo -e "${CLR_BOLD}  Oracle Linux Official Upstream Repository Switcher  ${CLR_RESET}"
echo -e "${CLR_CYAN}==============================================================${CLR_RESET}"

# ------------------------------------------------------------------------------
# 2. OS & Version Detection
# ------------------------------------------------------------------------------
log_step "Mendeteksi Sistem Operasi dan Versi..."

MAJOR_VER=""
DISTRO_NAME=""

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_NAME="${PRETTY_NAME:-$NAME}"
    MAJOR_VER="${VERSION_ID%%.*}"
elif [[ -f /etc/redhat-release ]]; then
    DISTRO_NAME=$(cat /etc/redhat-release)
    MAJOR_VER=$(grep -oE '[0-9]+' /etc/redhat-release | head -n1)
fi

ARCH=$(uname -m)

log_info "Sistem Terdeteksi : ${DISTRO_NAME}"
log_info "Major Version   : ${MAJOR_VER}"
log_info "Arsitektur CPU  : ${ARCH}"

case "${MAJOR_VER}" in
    7|8|9|10)
        log_info "Versi ${MAJOR_VER} didukung penuh."
        ;;
    *)
        log_err "Versi sistem '${MAJOR_VER}' tidak didukung. Skrip ini hanya mendukung versi 7, 8, 9, dan 10."
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# 3. Package Manager Detection
# ------------------------------------------------------------------------------
PKG_MGR="dnf"
if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
else
    log_err "Tidak ditemukan 'dnf' atau 'yum' di sistem ini."
    exit 1
fi
log_info "Package Manager : ${PKG_MGR}"

# ------------------------------------------------------------------------------
# 4. Backup Existing Distribution Repositories
# ------------------------------------------------------------------------------
log_step "Membuat Backup Repository yang Ada..."

REPOS_DIR="/etc/yum.repos.d"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${REPOS_DIR}/backup-${TIMESTAMP}"

mkdir -p "${BACKUP_DIR}"

# Pola file repo distro yang akan di-backup dan diganti
# Catatan: Repo aplikasi pihak ketiga (seperti pritunl, tailscale, mongodb, remi, docker)
#          TIDAK dipindahkan agar service yang berjalan tetap aman.
DISTRO_PATTERNS=(
    "*oracle*.repo"
    "*uek*.repo"
    "*virt*.repo"
    "*centos*.repo"
    "*rhel*.repo"
    "*rocky*.repo"
    "*alma*.repo"
    "*leapp*.repo*"
    "*.save"
    "*.bak"
    "*.rpmsave"
    "*.rpmnew"
)

MOVED_COUNT=0
for pattern in "${DISTRO_PATTERNS[@]}"; do
    for f in ${REPOS_DIR}/${pattern}; do
        if [[ -f "$f" ]]; then
            mv "$f" "${BACKUP_DIR}/"
            MOVED_COUNT=$((MOVED_COUNT + 1))
        fi
    done
done

log_info "Berhasil mem-backup ${MOVED_COUNT} file repo distro ke: ${BACKUP_DIR}"

# ------------------------------------------------------------------------------
# 5. Download and Import Official Oracle GPG Keys
# ------------------------------------------------------------------------------
log_step "Mengunduh dan Mengimpor GPG Key Resmi Oracle Linux..."

GPG_DIR="/etc/pki/rpm-gpg"
mkdir -p "${GPG_DIR}"

GPG_URL="https://yum.oracle.com/RPM-GPG-KEY-oracle-ol${MAJOR_VER}"
GPG_DEST="${GPG_DIR}/RPM-GPG-KEY-oracle-ol${MAJOR_VER}"

log_info "Mengunduh GPG Key dari: ${GPG_URL}"
if curl -fsSL --connect-timeout 10 --max-time 30 "${GPG_URL}" -o "${GPG_DEST}"; then
    cp -f "${GPG_DEST}" "${GPG_DIR}/RPM-GPG-KEY-oracle"
    chmod 644 "${GPG_DIR}/RPM-GPG-KEY-oracle"*
    rpm --import "${GPG_DIR}/RPM-GPG-KEY-oracle" 2>/dev/null || true
    log_info "GPG Key resmi Oracle Linux berhasil diimpor ke RPM keyring."
else
    log_warn "Gagal mengunduh GPG key spesifik ol${MAJOR_VER}, mencoba key lokal yang ada..."
    if [[ -f "${GPG_DIR}/RPM-GPG-KEY-oracle" ]]; then
        rpm --import "${GPG_DIR}/RPM-GPG-KEY-oracle" 2>/dev/null || true
    fi
fi

# ------------------------------------------------------------------------------
# 6. Configure DNF / YUM Variables
# ------------------------------------------------------------------------------
log_step "Menyetel variabel DNF/YUM (ocidomain & ociregion)..."

for vdir in /etc/dnf/vars /etc/yum/vars; do
    if [[ -d "$(dirname "$vdir")" ]]; then
        mkdir -p "$vdir"
        echo "oracle.com" > "$vdir/ocidomain"
        echo "" > "$vdir/ociregion"
    fi
done

# ------------------------------------------------------------------------------
# 7. Write Official Upstream Repository Files (yum.oracle.com)
# ------------------------------------------------------------------------------
log_step "Membuat konfigurasi repo upstream resmi Oracle Linux ${MAJOR_VER}..."

# Repository files will point directly to Oracle's global CDN (yum.oracle.com)
# ensuring maximum availability and always up-to-date packages.

if [[ "${MAJOR_VER}" == "9" ]]; then

    cat <<'EOF' > "${REPOS_DIR}/oracle-linux-ol9.repo"
[ol9_baseos_latest]
name=Oracle Linux 9 BaseOS Latest ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/baseos/latest/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol9
gpgcheck=1
enabled=1

[ol9_appstream]
name=Oracle Linux 9 Application Stream Packages ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/appstream/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol9
gpgcheck=1
enabled=1

[ol9_codeready_builder]
name=Oracle Linux 9 CodeReady Builder ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/codeready/builder/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol9
gpgcheck=1
enabled=1

[ol9_addons]
name=Oracle Linux 9 Addons ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/addons/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol9
gpgcheck=1
enabled=1
EOF

    cat <<'EOF' > "${REPOS_DIR}/uek-ol9.repo"
[ol9_UEKR7]
name=Oracle Linux 9 UEK Release 7 ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/UEKR7/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol9
gpgcheck=1
enabled=1

[ol9_UEKR8]
name=Oracle Linux 9 UEK Release 8 ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/UEKR8/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol9
gpgcheck=1
enabled=1
EOF

    cat <<'EOF' > "${REPOS_DIR}/oracle-epel-ol9.repo"
[ol9_developer_EPEL]
name=Oracle Linux 9 EPEL Packages for Development ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL9/developer/EPEL/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol9
gpgcheck=1
enabled=1
EOF

elif [[ "${MAJOR_VER}" == "8" ]]; then

    cat <<'EOF' > "${REPOS_DIR}/oracle-linux-ol8.repo"
[ol8_baseos_latest]
name=Oracle Linux 8 BaseOS Latest ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL8/baseos/latest/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol8
gpgcheck=1
enabled=1

[ol8_appstream]
name=Oracle Linux 8 Application Stream Packages ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL8/appstream/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol8
gpgcheck=1
enabled=1

[ol8_codeready_builder]
name=Oracle Linux 8 CodeReady Builder ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL8/codeready/builder/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol8
gpgcheck=1
enabled=1

[ol8_addons]
name=Oracle Linux 8 Addons ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL8/addons/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol8
gpgcheck=1
enabled=1
EOF

    cat <<'EOF' > "${REPOS_DIR}/uek-ol8.repo"
[ol8_UEKR7]
name=Oracle Linux 8 UEK Release 7 ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL8/UEKR7/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol8
gpgcheck=1
enabled=1

[ol8_UEKR6]
name=Oracle Linux 8 UEK Release 6 ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL8/UEKR6/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol8
gpgcheck=1
enabled=1
EOF

    cat <<'EOF' > "${REPOS_DIR}/oracle-epel-ol8.repo"
[ol8_developer_EPEL]
name=Oracle Linux 8 EPEL Packages for Development ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL8/developer/EPEL/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol8
gpgcheck=1
enabled=1
EOF

elif [[ "${MAJOR_VER}" == "7" ]]; then

    cat <<'EOF' > "${REPOS_DIR}/oracle-linux-ol7.repo"
[ol7_latest]
name=Oracle Linux 7 Latest ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL7/latest/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol7
gpgcheck=1
enabled=1

[ol7_addons]
name=Oracle Linux 7 Addons ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL7/addons/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol7
gpgcheck=1
enabled=1

[ol7_optional_latest]
name=Oracle Linux 7 Optional Latest ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL7/optional/latest/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol7
gpgcheck=1
enabled=1
EOF

    cat <<'EOF' > "${REPOS_DIR}/uek-ol7.repo"
[ol7_UEKR6]
name=Oracle Linux 7 UEK Release 6 ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL7/UEKR6/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol7
gpgcheck=1
enabled=1

[ol7_UEKR5]
name=Oracle Linux 7 UEK Release 5 ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL7/UEKR5/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol7
gpgcheck=1
enabled=1
EOF

    cat <<'EOF' > "${REPOS_DIR}/oracle-epel-ol7.repo"
[ol7_developer_EPEL]
name=Oracle Linux 7 EPEL Packages for Development ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL7/developer_EPEL/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol7
gpgcheck=1
enabled=1
EOF

elif [[ "${MAJOR_VER}" == "10" ]]; then

    cat <<'EOF' > "${REPOS_DIR}/oracle-linux-ol10.repo"
[ol10_baseos_latest]
name=Oracle Linux 10 BaseOS Latest ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL10/baseos/latest/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol10
gpgcheck=1
enabled=1

[ol10_appstream]
name=Oracle Linux 10 Application Stream Packages ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL10/appstream/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol10
gpgcheck=1
enabled=1

[ol10_codeready_builder]
name=Oracle Linux 10 CodeReady Builder ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL10/codeready/builder/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol10
gpgcheck=1
enabled=1

[ol10_addons]
name=Oracle Linux 10 Addons ($basearch)
baseurl=https://yum.oracle.com/repo/OracleLinux/OL10/addons/$basearch/
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-oracle https://yum.oracle.com/RPM-GPG-KEY-oracle-ol10
gpgcheck=1
enabled=1
EOF

fi

chmod 644 "${REPOS_DIR}"/*.repo

# ------------------------------------------------------------------------------
# 8. Clean and Refresh Metadata Cache
# ------------------------------------------------------------------------------
log_step "Membersihkan dan memperbarui metadata cache (${PKG_MGR})..."

${PKG_MGR} clean all
${PKG_MGR} makecache

# ------------------------------------------------------------------------------
# 9. Summary & Verification
# ------------------------------------------------------------------------------
log_step "Memverifikasi repository aktif..."

echo ""
${PKG_MGR} repolist
echo ""

log_info "Konfigurasi repository resmi Oracle Linux ${MAJOR_VER} selesai dengan sukses!"
log_info "Seluruh repository sekarang terhubung langsung ke upstream resmi: https://yum.oracle.com"
log_info "Backup repository lama tersimpan aman di: ${BACKUP_DIR}"
echo -e "${CLR_CYAN}==============================================================${CLR_RESET}"
