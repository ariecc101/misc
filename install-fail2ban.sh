#!/usr/bin/env bash
#
# install-fail2ban.sh
# Installer fail2ban universal: AlmaLinux, Oracle Linux (dan RHEL-family lain),
# Ubuntu, Debian. Idempotent, aman dijalankan ulang.
#
# Pemakaian:
#   sudo bash install-fail2ban.sh
#
# Override opsional lewat environment variable:
#   BANTIME=1d FINDTIME=10m MAXRETRY=3 IGNORE_IPS="10.0.0.0/8 203.0.113.5" \
#   SSH_PORT=2222 sudo -E bash install-fail2ban.sh
#
set -euo pipefail

BANTIME="${BANTIME:-1d}"
FINDTIME="${FINDTIME:-10m}"
MAXRETRY="${MAXRETRY:-3}"
IGNORE_IPS="${IGNORE_IPS:-}"
SSH_PORT="${SSH_PORT:-}"

JAIL_FILE="/etc/fail2ban/jail.d/99-sshd-hardening.local"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- prasyarat
[[ $EUID -eq 0 ]] || die "Jalankan sebagai root (sudo bash $0)."
[[ -r /etc/os-release ]] || die "/etc/os-release tidak ditemukan, OS tidak dikenali."
command -v systemctl >/dev/null 2>&1 || die "Script ini membutuhkan systemd."

# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-}"
OS_VER="${VERSION_ID%%.*}"

family=""
case " $OS_ID $OS_LIKE " in
  *" debian "*|*" ubuntu "*)                          family="debian" ;;
  *" rhel "*|*" centos "*|*" fedora "*|*" almalinux "*|*" ol "*) family="rhel" ;;
esac
[[ -n "$family" ]] || die "Distro tidak didukung: $PRETTY_NAME"
log "Terdeteksi: $PRETTY_NAME (family: $family)"

# ---------------------------------------------------------------- instalasi
install_debian() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # python3-systemd dibutuhkan untuk backend=systemd (journald)
  apt-get install -y -qq fail2ban python3-systemd
}

install_rhel() {
  local pm="dnf"
  command -v dnf >/dev/null 2>&1 || pm="yum"

  if ! $pm -q list --available fail2ban >/dev/null 2>&1 \
     && ! rpm -q fail2ban >/dev/null 2>&1; then
    log "fail2ban ada di EPEL, mengaktifkan repo EPEL..."
    if [[ "$OS_ID" == "ol" ]]; then
      $pm install -y "oracle-epel-release-el${OS_VER}" \
        || $pm install -y epel-release \
        || die "Gagal memasang repo EPEL untuk Oracle Linux."
    else
      $pm install -y epel-release || die "Gagal memasang epel-release."
    fi
    # Aktifkan repo crb/powertools bila ada (dependensi EPEL), abaikan jika gagal
    if command -v crb >/dev/null 2>&1; then crb enable >/dev/null 2>&1 || true; fi
  fi

  $pm install -y fail2ban

  # Integrasi firewalld (opsional, paket bisa tidak ada di semua versi)
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    $pm install -y fail2ban-firewalld >/dev/null 2>&1 || true
  fi
  # Paket systemd backend (EL8/EL9 punya fail2ban-systemd)
  $pm install -y fail2ban-systemd >/dev/null 2>&1 || true
  # Pastikan python systemd binding ada
  $pm install -y python3-systemd >/dev/null 2>&1 || true
}

if rpm -q fail2ban >/dev/null 2>&1 || dpkg -s fail2ban >/dev/null 2>&1; then
  log "fail2ban sudah terpasang, lewati instalasi paket."
else
  log "Memasang fail2ban..."
  "install_${family}"
fi

# ---------------------------------------------------------------- deteksi konfigurasi
# Port SSH
if [[ -z "$SSH_PORT" ]]; then
  if command -v sshd >/dev/null 2>&1; then
    SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{p=$2} END{print p}' || true)"
  fi
  SSH_PORT="${SSH_PORT:-22}"
fi
log "Port SSH: $SSH_PORT"

# Backend firewall
if systemctl is-active --quiet firewalld 2>/dev/null; then
  BANACTION="firewallcmd-ipset"
  FW="firewalld"
elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null || true)" == *"Status: active"* ]]; then
  BANACTION="ufw"
  FW="ufw"
elif command -v nft >/dev/null 2>&1; then
  BANACTION="nftables-multiport"
  FW="nftables"
else
  BANACTION="iptables-multiport"
  FW="iptables"
fi
log "Firewall terdeteksi: $FW (banaction: $BANACTION)"

# Whitelist: loopback + IP sesi SSH saat ini (supaya tidak mengunci diri sendiri)
IGNORE="127.0.0.1/8 ::1"
CLIENT_IP=""
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  CLIENT_IP="${SSH_CONNECTION%% *}"
elif [[ -n "${SSH_CLIENT:-}" ]]; then
  CLIENT_IP="${SSH_CLIENT%% *}"
else
  # sudo biasanya menghapus SSH_CONNECTION; fallback ke info login terminal
  CLIENT_IP="$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' || true)"
fi
if [[ "$CLIENT_IP" =~ ^[0-9a-fA-F:.]+$ ]]; then
  IGNORE="$IGNORE $CLIENT_IP"
  log "IP sesi SSH Anda ($CLIENT_IP) dimasukkan ke ignoreip."
else
  warn "IP sesi SSH tidak terdeteksi. Set IGNORE_IPS=\"IP_Anda\" agar tidak terkunci."
fi
[[ -n "$IGNORE_IPS" ]] && IGNORE="$IGNORE $IGNORE_IPS"

# ---------------------------------------------------------------- tulis jail
mkdir -p /etc/fail2ban/jail.d
if [[ -f "$JAIL_FILE" ]]; then
  cp -a "$JAIL_FILE" "${JAIL_FILE}.bak.$(date +%Y%m%d%H%M%S)"
fi

# journalmatch mencakup unit sshd.service (RHEL) dan ssh.service (Debian/Ubuntu),
# serta proses sshd-session (OpenSSH >= 9.8) yang tidak tertangkap filter lama.
cat > "$JAIL_FILE" <<EOF
# Dibuat oleh install-fail2ban.sh
[DEFAULT]
ignoreip  = ${IGNORE}
bantime   = ${BANTIME}
findtime  = ${FINDTIME}
maxretry  = ${MAXRETRY}
backend   = systemd
banaction = ${BANACTION}
banaction_allports = ${BANACTION}

# Ban IP berulang dengan durasi makin lama
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 4w

[sshd]
enabled      = true
port         = ${SSH_PORT}
mode         = aggressive
journalmatch = _SYSTEMD_UNIT=sshd.service + _SYSTEMD_UNIT=ssh.service + _COMM=sshd + _COMM=sshd-session
EOF
chmod 644 "$JAIL_FILE"
log "Konfigurasi ditulis ke $JAIL_FILE"

# ---------------------------------------------------------------- validasi & start
log "Validasi konfigurasi..."
if ! fail2ban-client -t >/dev/null 2>&1; then
  fail2ban-client -t || true
  die "Konfigurasi fail2ban tidak valid. Periksa $JAIL_FILE"
fi

systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban

# Tunggu socket siap
for _ in $(seq 1 15); do
  fail2ban-client ping >/dev/null 2>&1 && break
  sleep 1
done
fail2ban-client ping >/dev/null 2>&1 || die "fail2ban tidak merespons. Cek: journalctl -u fail2ban -n 50"

log "fail2ban aktif. Status jail sshd:"
fail2ban-client status sshd || warn "Jail sshd belum terbaca, cek: journalctl -u fail2ban -n 50"

cat <<'EOF'

Perintah berguna:
  fail2ban-client status sshd              # lihat IP yang di-ban
  fail2ban-client set sshd unbanip <IP>    # lepas ban
  fail2ban-client get sshd ignoreip        # lihat whitelist
  journalctl -u fail2ban -f                # log live
EOF
