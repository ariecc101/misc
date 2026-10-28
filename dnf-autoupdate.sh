#!/usr/bin/env bash
# ==============================================================================
# Script: Setup / Patch dnf-automatic on AlmaLinux / RHEL / Rocky Linux
# Options:
# - Update All Packages (upgrade_type = default)
# - Schedule: Every Day at 03:00 AM (systemd timer drop-in override)
# - Reboot: when-needed
# - Notification: None (emit_via = None)
# - Safe & Idempotent: Bisa dijalankan untuk instalasi baru MAUPUN patching
# ==============================================================================

set -euo pipefail

# 1. Pastikan dieksekusi sebagai root
if [ "${EUID}" -ne 0 ]; then
    echo "[ERROR] Script ini harus dijalankan sebagai root (atau gunakan sudo)!" >&2
    exit 1
fi

echo "=============================================================================="
echo "          dnf-automatic Setup & Schedule Patch (03:00 AM)                     "
echo "=============================================================================="

echo "==> [1/4] Memeriksa kompatibilitas OS..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "    Sistem: ${PRETTY_NAME:-$ID $VERSION_ID}"
    case "${ID_LIKE:-$ID}" in
        *rhel*|*fedora*|*centos*|*almalinux*|*rocky*)
            ;;
        *)
            echo "    [PERINGATAN] Sistem bukan turunan RHEL/AlmaLinux."
            ;;
    esac
fi

echo "==> [2/4] Memeriksa paket dnf-automatic..."
if rpm -q dnf-automatic >/dev/null 2>&1; then
    echo "    Paket dnf-automatic sudah terpasang ($(rpm -q dnf-automatic)). Melanjutkan patch konfigurasi..."
else
    echo "    Menginstal dnf-automatic..."
    dnf install -y dnf-automatic
fi

echo "==> [3/4] Mengonfigurasi /etc/dnf/automatic.conf & patch timer 03:00 pagi..."
# Backup konfigurasi lama jika ada
if [ -f /etc/dnf/automatic.conf ]; then
    cp -a /etc/dnf/automatic.conf "/etc/dnf/automatic.conf.bak.$(date +%Y%m%d%H%M%S)"
fi

# Tulis konfigurasi automatic.conf
cat << 'EOF' > /etc/dnf/automatic.conf
[commands]
# Update semua paket yang tersedia
upgrade_type = default
random_sleep = 0
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

# Terapkan patch drop-in override systemd agar jalan setiap jam 03:00 pagi tanpa delay
mkdir -p /etc/systemd/system/dnf-automatic.timer.d
cat << 'EOF' > /etc/systemd/system/dnf-automatic.timer.d/override.conf
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=0
EOF

echo "==> [4/4] Memuat ulang systemd & me-restart dnf-automatic.timer..."
systemctl daemon-reload
systemctl enable dnf-automatic.timer
systemctl restart dnf-automatic.timer

echo ""
echo "=============================================================================="
echo " [SUKSES] dnf-automatic berhasil dipasang / dipatch!"
echo " - Tipe Update : Semua Paket (upgrade_type = default)"
echo " - Jadwal Jam  : Setiap hari pukul 03:00 pagi (OnCalendar=*-*-* 03:00:00)"
echo " - Reboot      : when-needed (shutdown -r +5 saat dibutuhkan)"
echo " - Email/Notif : None (dimatikan)"
echo "=============================================================================="
echo ""
echo "Status & Jadwal Timer Aktif:"
systemctl status dnf-automatic.timer --no-pager | grep -E "Loaded:|Drop-In:|Active:|Trigger:"
