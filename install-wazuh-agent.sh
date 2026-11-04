#!/usr/bin/env bash
# install-wazuh-agent.sh
# Wajib: WAZUH_MANAGER (hostname/IP manager)
# Opsional: WAZUH_MANAGER_IP (jika hostname perlu ditambahkan ke /etc/hosts),
#           WAZUH_VERSION, WAZUH_AGENT_GROUP, WAZUH_AGENT_NAME
set -euo pipefail

WAZUH_VERSION="${WAZUH_VERSION:-4.14.9}"
: "${WAZUH_MANAGER:?Set WAZUH_MANAGER (hostname atau IP manager)}"
WAZUH_MANAGER_IP="${WAZUH_MANAGER_IP:-}"

[[ $EUID -eq 0 ]] || { echo "Jalankan sebagai root (pakai sudo)." >&2; exit 1; }

# --- Deteksi arsitektur ---
case "$(uname -m)" in
  x86_64)  RPM_ARCH="x86_64";  DEB_ARCH="amd64" ;;
  aarch64) RPM_ARCH="aarch64"; DEB_ARCH="arm64" ;;
  *) echo "Arsitektur $(uname -m) tidak didukung." >&2; exit 1 ;;
esac

# --- Deteksi OS family ---
. /etc/os-release
ID_ALL="${ID:-} ${ID_LIKE:-}"
if   [[ $ID_ALL =~ (rhel|centos|fedora|almalinux|rocky|ol|amzn) ]]; then PKG="rpm"
elif [[ $ID_ALL =~ (debian|ubuntu) ]]; then PKG="deb"
else echo "OS tidak dikenali: ${PRETTY_NAME:-unknown}" >&2; exit 1; fi
echo ">> OS: ${PRETTY_NAME:-$ID} | paket: $PKG | arch: $(uname -m)"

# --- /etc/hosts (hanya jika WAZUH_MANAGER_IP diisi, idempotent) ---
if [[ -n "$WAZUH_MANAGER_IP" ]] && ! grep -qE "[[:space:]]${WAZUH_MANAGER}([[:space:]]|$)" /etc/hosts; then
  echo "${WAZUH_MANAGER_IP} ${WAZUH_MANAGER}" >> /etc/hosts
  echo ">> Entry hosts ditambahkan"
fi

# --- Download & install ---
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export WAZUH_MANAGER
[[ -n "${WAZUH_AGENT_GROUP:-}" ]] && export WAZUH_AGENT_GROUP
[[ -n "${WAZUH_AGENT_NAME:-}"  ]] && export WAZUH_AGENT_NAME

if [[ $PKG == "rpm" ]]; then
  F="wazuh-agent-${WAZUH_VERSION}-1.${RPM_ARCH}.rpm"
  curl -fsSL -o "$TMP/$F" "https://packages.wazuh.com/4.x/yum/$F"
  rpm -Uvh "$TMP/$F"
else
  F="wazuh-agent_${WAZUH_VERSION}-1_${DEB_ARCH}.deb"
  curl -fsSL -o "$TMP/$F" "https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/$F"
  dpkg -i "$TMP/$F"
fi

# --- Enable & start ---
systemctl daemon-reload
systemctl enable --now wazuh-agent
systemctl --no-pager status wazuh-agent | head -n 5
