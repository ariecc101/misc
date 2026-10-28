#!/usr/bin/env bash
# ==============================================================================
# Script: Setup dnf-automatic on AlmaLinux / RHEL / Rocky Linux
# Options: Update All Packages (default), Reboot When-Needed, No Email (None)
# ==============================================================================

set -euo pipefail

# 1. Pastikan dieksekusi sebagai root
if [ "${EUID}" -ne 0 ]; then
    echo "[ERROR] Script ini harus dijalankan sebagai root (atau gunakan sudo)!" >&2
    exit 1
fi

echo "==> [1/4] Memeriksa kompatibilitas OS..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "    Terdeteksi: ${PRETTY_NAME:-$ID $VERSION_ID}"
    case "${ID_LIKE:-$ID}" in
        *rhel*|*fedora*|*centos*|*almalinux*|*rocky*)
            ;;
        *)
            echo "[WARNING] Sistem bukan turunan RHEL/AlmaLinux. Proses tetap dilanjutkan..."
            ;;
    esac
else
    echo "[WARNING] /etc/os-release tidak ditemukan."
fi

echo "==> [2/4] Menginstal dnf-automatic..."
dnf install -y dnf-automatic

echo "==> [3/4] Mengonfigurasi /etc/dnf/automatic.conf..."
# Backup konfigurasi lama jika ada
if [ -f /etc/dnf/automatic.conf ]; then
    cp -a /etc/dnf/automatic.conf "/etc/dnf/automatic.conf.bak.$(date +%Y%m%d%H%M%S)"
fi

# Tulis konfigurasi baru sesuai preferensi:
# - upgrade_type = default (semua paket)
# - reboot = when-needed (restart otomatis jika kernel/glibc diupdate)
# - emit_via = None (tanpa email / silent)
cat << 'EOF' > /etc/dnf/automatic.conf
[commands]
# Update semua paket yang tersedia
upgrade_type = default
random_sleep = 300
network_online_timeout = 60

# Unduh dan terapkan pembaruan secara otomatis
download_updates = yes
apply_updates = yes

# Reboot otomatis jika dibutuhkan (misal ada pembaruan kernel atau glibc)
reboot = when-needed
reboot_command = "shutdown -r +5 'Rebooting system after applying package updates'"

[emitters]
# Matikan pengiriman pesan/notifikasi email
emit_via = None

[email]
email_from = root@localhost
email_to = root
email_host = localhost

[base]
debuglevel = 1
EOF

echo "==> [4/4] Mengaktifkan dan menjalankan dnf-automatic.timer..."
systemctl daemon-reload
systemctl enable --now dnf-automatic.timer

echo ""
echo "=============================================================================="
echo " [SUKSES] dnf-automatic berhasil dipasang dan dikonfigurasi!"
echo " - Tipe Update : Semua Paket (upgrade_type = default)"
echo " - Reboot      : when-needed (shutdown -r +5 saat dibutuhkan)"
echo " - Email/Notif : None (dimatikan)"
echo "=============================================================================="
echo ""
echo "Jadwal timer aktif:"
systemctl list-timers dnf-automatic.timer --no-pager
