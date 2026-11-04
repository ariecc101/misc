#!/usr/bin/env bash
#
# harden-ssh.sh
# Hardening sshd lewat drop-in /etc/ssh/sshd_config.d/00-hardening.conf
# Root hanya boleh login dengan public key. Password login dimatikan.
# Kompatibel: AlmaLinux, Oracle Linux, RHEL-family, Ubuntu, Debian.
#
# Pemakaian:
#   sudo bash harden-ssh.sh
#
# Override opsional (environment variable):
#   ALLOW_USERS="suni deploy"   # batasi user yang boleh login (hati-hati lockout)
#   ROOT_LOGIN=prohibit-password  # atau "no" untuk menolak root sepenuhnya
#   MAX_AUTH_TRIES=3
#   FORCE=1                     # lewati cek authorized_keys (tidak disarankan)
#
set -euo pipefail

DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN="$DROPIN_DIR/00-hardening.conf"
MAIN_CONF="/etc/ssh/sshd_config"

ROOT_LOGIN="${ROOT_LOGIN:-prohibit-password}"
MAX_AUTH_TRIES="${MAX_AUTH_TRIES:-3}"
ALLOW_USERS="${ALLOW_USERS:-}"
FORCE="${FORCE:-0}"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Jalankan sebagai root (sudo bash $0)."
command -v sshd >/dev/null 2>&1 || [[ -x /usr/sbin/sshd ]] || die "sshd tidak ditemukan."
SSHD="$(command -v sshd || echo /usr/sbin/sshd)"

case "$ROOT_LOGIN" in
  prohibit-password|no) ;;
  *) die "ROOT_LOGIN harus 'prohibit-password' atau 'no'." ;;
esac

# Nama service: ssh (Debian/Ubuntu) atau sshd (RHEL-family)
# (tanpa pipe ke grep -q: dengan 'set -o pipefail' itu bisa gagal karena SIGPIPE)
if systemctl cat sshd.service >/dev/null 2>&1; then
  SVC="sshd"
elif systemctl cat ssh.service >/dev/null 2>&1; then
  SVC="ssh"
else
  die "Unit service SSH (sshd.service / ssh.service) tidak ditemukan."
fi

# ------------------------------------------------- cek anti-lockout
has_keys() {
  local home="$1"
  [[ -s "$home/.ssh/authorized_keys" ]] && grep -Eq '^(ssh-|ecdsa-|sk-)' "$home/.ssh/authorized_keys"
}

if [[ "$FORCE" != "1" ]]; then
  who_login="${SUDO_USER:-root}"
  home_dir="$(getent passwd "$who_login" | cut -d: -f6)"
  if [[ -z "$home_dir" ]] || ! has_keys "$home_dir"; then
    die "User '$who_login' belum punya public key di $home_dir/.ssh/authorized_keys.
    Tambahkan dulu (ssh-copy-id), uji login pakai key di terminal lain,
    baru jalankan script ini. (FORCE=1 untuk melewati, berisiko terkunci.)"
  fi
  log "authorized_keys untuk '$who_login' ditemukan."

  if [[ "$ROOT_LOGIN" == "prohibit-password" ]] && ! has_keys /root; then
    warn "root belum punya key; login root praktis tidak akan bisa (tidak masalah jika Anda pakai sudo user)."
  fi
fi

# ------------------------------------------------- pastikan Include aktif
mkdir -p "$DROPIN_DIR"
if ! grep -Eqi '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "$MAIN_CONF"; then
  warn "sshd_config belum meng-Include sshd_config.d, menambahkan di baris paling atas."
  cp -a "$MAIN_CONF" "${MAIN_CONF}.bak.$(date +%Y%m%d%H%M%S)"
  sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$MAIN_CONF"
fi

# Nama opsi keyboard-interactive berbeda antar versi OpenSSH
sshd_dump="$("$SSHD" -T 2>/dev/null || true)"
if grep -qi '^kbdinteractiveauthentication' <<<"$sshd_dump"; then
  KBD_OPT="KbdInteractiveAuthentication"
else
  KBD_OPT="ChallengeResponseAuthentication"
fi

# ------------------------------------------------- tulis drop-in
[[ -f "$DROPIN" ]] && cp -a "$DROPIN" "${DROPIN}.bak.$(date +%Y%m%d%H%M%S)"

{
cat <<EOF
# Dibuat oleh harden-ssh.sh
# Prefix 00- disengaja: sshd memakai nilai PERTAMA yang dibaca, sehingga file ini
# mengalahkan drop-in lain (mis. 50-cloud-init.conf yang sering set PasswordAuthentication yes).

# --- Autentikasi ---
PermitRootLogin ${ROOT_LOGIN}
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
${KBD_OPT} no
AuthenticationMethods publickey
UsePAM yes
MaxAuthTries ${MAX_AUTH_TRIES}
LoginGraceTime 20

# --- Redam serangan koneksi massal ---
MaxStartups 10:30:60
MaxSessions 4

# --- Pengurangan permukaan serangan ---
X11Forwarding no
AllowAgentForwarding no
PermitUserEnvironment no
PermitTunnel no
GatewayPorts no

# --- Sesi idle dan logging ---
ClientAliveInterval 300
ClientAliveCountMax 2
LogLevel VERBOSE
EOF
if [[ -n "$ALLOW_USERS" ]]; then
  echo
  echo "# --- Batasi user ---"
  echo "AllowUsers ${ALLOW_USERS}"
fi
} > "$DROPIN"
chmod 644 "$DROPIN"
log "Config ditulis ke $DROPIN"

# ------------------------------------------------- validasi sebelum reload
if ! "$SSHD" -t; then
  rm -f "$DROPIN"
  die "Konfigurasi sshd tidak valid, drop-in dihapus. Tidak ada perubahan diterapkan."
fi

# Verifikasi nilai efektif (bukan sekadar isi file)
eff="$("$SSHD" -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null)"
check() {
  local key="$1" want="$2" got
  got="$(awk -v k="$key" 'tolower($1)==k{print $2; exit}' <<<"$eff")"
  # sshd -T menampilkan 'without-password' (alias lama) untuk prohibit-password
  # pada beberapa versi OpenSSH; keduanya identik.
  [[ "$got" == "without-password" ]] && got="prohibit-password"
  if [[ "$got" != "$want" ]]; then
    rm -f "$DROPIN"
    die "Nilai efektif '$key' = '$got' (diharapkan '$want'). Ada konfigurasi lain yang menimpa. Drop-in dibatalkan."
  fi
}
check passwordauthentication no
check permitrootlogin "$ROOT_LOGIN"
check pubkeyauthentication yes
log "Validasi nilai efektif OK."

# ------------------------------------------------- terapkan (reload, bukan restart)
systemctl reload "$SVC"
log "Service $SVC di-reload."

cat <<EOF

SELESAI. Penting sebelum menutup sesi ini:
  1. JANGAN tutup sesi SSH yang sekarang.
  2. Buka terminal baru dan uji login memakai key.
  3. Cek yang tertolak:  ssh -o PubkeyAuthentication=no user@host   (harus gagal)
  4. Rollback bila perlu: rm $DROPIN && systemctl reload $SVC

Cek nilai efektif kapan saja:
  sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|pubkeyauthentication|authenticationmethods|maxauthtries'
EOF
