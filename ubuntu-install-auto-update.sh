#!/usr/bin/env bash
#
# install-auto-update.sh
# Installer auto-update untuk Ubuntu/Debian (systemd timer + logrotate)
#
# Install  : curl -sSL URL | sudo bash
# Opsi     : curl -sSL URL | sudo AUTO_REBOOT=no SCHEDULE="*-*-* 03:00:00" bash
# Uninstall: curl -sSL URL | sudo bash -s -- uninstall

set -euo pipefail

# ===== Opsi (bisa dioverride lewat environment variable) =====
AUTO_REBOOT="${AUTO_REBOOT:-yes}"                # yes / no
REBOOT_DELAY_MIN="${REBOOT_DELAY_MIN:-5}"        # menit sebelum reboot
UPGRADE_MODE="${UPGRADE_MODE:-upgrade}"          # upgrade / dist-upgrade
SCHEDULE="${SCHEDULE:-*-*-* 02:00:00}"           # format systemd OnCalendar
RANDOM_DELAY="${RANDOM_DELAY:-30min}"
FORCE_CONFIG="${FORCE_CONFIG:-no}"               # yes = timpa config lama
# =============================================================

BIN="/usr/local/sbin/auto-update.sh"
CONF="/etc/default/auto-update"
SERVICE="/etc/systemd/system/auto-update.service"
TIMER="/etc/systemd/system/auto-update.timer"
LOGROTATE="/etc/logrotate.d/auto-update"

info() { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Harus root. Jalankan: curl -sSL URL | sudo bash"

# ---------- Uninstall ----------
if [[ "${1:-}" == "uninstall" ]]; then
    info "Menghapus auto-update..."
    systemctl disable --now auto-update.timer 2>/dev/null || true
    rm -f "$BIN" "$SERVICE" "$TIMER" "$LOGROTATE"
    systemctl daemon-reload
    info "Selesai. Config ($CONF) dan log (/var/log/auto-update.log) dibiarkan."
    exit 0
fi

# ---------- Validasi ----------
[[ -r /etc/os-release ]] || die "/etc/os-release tidak ditemukan."
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}${ID_LIKE:-}" in
    *ubuntu*|*debian*) ;;
    *) die "Hanya untuk Ubuntu/Debian (terdeteksi: ${PRETTY_NAME:-unknown})." ;;
esac
command -v systemctl >/dev/null || die "systemd tidak tersedia."
[[ "$AUTO_REBOOT" =~ ^(yes|no)$ ]] || die "AUTO_REBOOT harus yes/no."
[[ "$UPGRADE_MODE" =~ ^(upgrade|dist-upgrade)$ ]] || die "UPGRADE_MODE harus upgrade/dist-upgrade."
[[ "$REBOOT_DELAY_MIN" =~ ^[0-9]+$ ]] || die "REBOOT_DELAY_MIN harus angka."

# ---------- Config ----------
if [[ ! -f "$CONF" || "$FORCE_CONFIG" == "yes" ]]; then
    info "Menulis config: $CONF"
    cat >"$CONF" <<EOF
# Konfigurasi auto-update
AUTO_REBOOT="$AUTO_REBOOT"
REBOOT_DELAY_MIN="$REBOOT_DELAY_MIN"
UPGRADE_MODE="$UPGRADE_MODE"
EOF
    chmod 644 "$CONF"
else
    warn "Config sudah ada, dipertahankan: $CONF (pakai FORCE_CONFIG=yes untuk menimpa)"
fi

# ---------- Worker script ----------
info "Memasang worker: $BIN"
cat >"$BIN" <<'WORKER'
#!/usr/bin/env bash
# auto-update.sh - dipanggil oleh auto-update.service
set -euo pipefail

LOG_FILE="/var/log/auto-update.log"
LOCK_FILE="/run/auto-update.lock"
AUTO_REBOOT="yes"
REBOOT_DELAY_MIN=5
UPGRADE_MODE="upgrade"

# shellcheck disable=SC1091
[[ -r /etc/default/auto-update ]] && . /etc/default/auto-update

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # needrestart: restart service otomatis tanpa prompt

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

[[ $EUID -eq 0 ]] || { echo "Harus root." >&2; exit 1; }

exec 200>"$LOCK_FILE"
flock -n 200 || { log "Proses update lain masih berjalan, keluar."; exit 1; }

APT_OPTS=(-y -o DPkg::Lock::Timeout=300
          -o Dpkg::Options::=--force-confdef
          -o Dpkg::Options::=--force-confold)

log "===== Mulai update ($UPGRADE_MODE) ====="

log "apt-get update"
apt-get update "${APT_OPTS[@]}" >>"$LOG_FILE" 2>&1

log "apt-get $UPGRADE_MODE"
apt-get "$UPGRADE_MODE" "${APT_OPTS[@]}" >>"$LOG_FILE" 2>&1

log "autoremove & autoclean"
apt-get autoremove "${APT_OPTS[@]}" >>"$LOG_FILE" 2>&1
apt-get autoclean -y >>"$LOG_FILE" 2>&1

if [[ -f /var/run/reboot-required ]]; then
    log "Reboot diperlukan."
    if [[ "$AUTO_REBOOT" == "yes" ]]; then
        log "Reboot dijadwalkan dalam $REBOOT_DELAY_MIN menit."
        shutdown -r "+$REBOOT_DELAY_MIN" "Reboot otomatis setelah update"
    fi
else
    log "Tidak perlu reboot."
fi

log "===== Update selesai ====="
WORKER
chmod 750 "$BIN"

# ---------- systemd ----------
info "Memasang systemd service & timer"
cat >"$SERVICE" <<EOF
[Unit]
Description=Automatic apt update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$BIN
EOF

cat >"$TIMER" <<EOF
[Unit]
Description=Jalankan auto-update terjadwal

[Timer]
OnCalendar=$SCHEDULE
RandomizedDelaySec=$RANDOM_DELAY
Persistent=true

[Install]
WantedBy=timers.target
EOF

# ---------- logrotate ----------
cat >"$LOGROTATE" <<'EOF'
/var/log/auto-update.log {
    monthly
    rotate 6
    compress
    missingok
    notifempty
}
EOF

systemctl daemon-reload
systemctl enable --now auto-update.timer

info "Terpasang."
echo
systemctl list-timers auto-update.timer --no-pager || true
cat <<EOF

Perintah berguna:
  Jalankan manual : sudo systemctl start auto-update.service
  Lihat log       : tail -f /var/log/auto-update.log
  Status          : systemctl status auto-update.service
  Ubah pengaturan : sudo nano $CONF
  Batalkan reboot : sudo shutdown -c
  Uninstall       : curl -sSL URL | sudo bash -s -- uninstall
EOF
