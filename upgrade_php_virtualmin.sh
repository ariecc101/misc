#!/usr/bin/env bash
#
# Script: upgrade_php_virtualmin.sh
# Deskripsi: Mendeteksi domain dengan PHP versi 5.x - 8.1 lalu meng-upgrade ke minimal PHP 8.2.
#            Domain dengan versi >= 8.2 akan dibiarkan tetap pada versinya.
#

set -uo pipefail

TARGET_PHP_VERSION="8.2"
DRY_RUN=false

# Warna output terminal
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

usage() {
    echo "Penggunaan: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -d, --dry-run        Mode simulasi (hanya cek & deteksi, tanpa mengubah konfigurasi)"
    echo "  -v, --version VER    Versi PHP target (default: 8.2)"
    echo "  -h, --help           Tampilkan bantuan ini"
    exit 0
}

# Parsing argument
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--version)
            TARGET_PHP_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Argumen tidak dikenal: $1${NC}"
            usage
            ;;
    esac
done

# Pengecekan tools pendukung
for cmd in virtualmin jq awk; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}[ERROR] Perintah '$cmd' tidak ditemukan. Pastikan sudah terinstall.${NC}"
        exit 1
    fi
done

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN} Virtualmin PHP Version Auto-Upgrade (Min. ${TARGET_PHP_VERSION})${NC}"
if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW} MODE: DRY RUN (SIMULASI - Tidak ada perubahan konfigurasi)${NC}"
else
    echo -e "${GREEN} MODE: EKSEKUSI LANGSUNG${NC}"
fi
echo -e "${CYAN}============================================================${NC}"

echo -e "${BLUE}[*] Mengambil data virtual server dari Virtualmin...${NC}"
DOMAINS_JSON=$(virtualmin list-domains --json 2>/dev/null)

if [ -z "$DOMAINS_JSON" ]; then
    echo -e "${RED}[ERROR] Gagal mendapatkan daftar domain dari Virtualmin.${NC}"
    exit 1
fi

TOTAL_SCANNED=0
TOTAL_UPGRADED=0
TOTAL_KEPT=0
TOTAL_SKIPPED=0
TOTAL_FAILED=0

# Loop tiap domain yang didapatkan dari JSON
while IFS=$'\t' read -r domain current_php; do
    [ -z "$domain" ] && continue
    TOTAL_SCANNED=$((TOTAL_SCANNED + 1))

    # Cek apakah versi valid numerik
    ACTION=$(awk -v ver="$current_php" -v target="$TARGET_PHP_VERSION" 'BEGIN {
        if (ver ~ /^[0-9]+(\.[0-9]+)?$/) {
            split(ver, cur, ".")
            split(target, tgt, ".")
            c_maj = cur[1] + 0; c_min = cur[2] + 0
            t_maj = tgt[1] + 0; t_min = tgt[2] + 0

            # Cek jika versi PHP antara 5.0 s/d di bawah target (8.2)
            if (c_maj >= 5 && (c_maj < t_maj || (c_maj == t_maj && c_min < t_min))) {
                print "UPGRADE"
                exit
            } else {
                print "KEEP"
                exit
            }
        }
        print "SKIP"
    }')

    case "$ACTION" in
        UPGRADE)
            echo -e "[#$TOTAL_SCANNED] ${YELLOW}$domain${NC} (PHP $current_php) -> ${GREEN}Upgrade ke $TARGET_PHP_VERSION${NC}"
            if [ "$DRY_RUN" = true ]; then
                echo -e "      ${YELLOW}[SIMULASI] virtualmin modify-web --domain $domain --php-version $TARGET_PHP_VERSION${NC}"
                TOTAL_UPGRADED=$((TOTAL_UPGRADED + 1))
            else
                if virtualmin modify-web --domain "$domain" --php-version "$TARGET_PHP_VERSION" &>/dev/null; then
                    echo -e "      ${GREEN}[OK] Berhasil diubah ke PHP $TARGET_PHP_VERSION${NC}"
                    TOTAL_UPGRADED=$((TOTAL_UPGRADED + 1))
                else
                    echo -e "      ${RED}[FAIL] Gagal mengubah domain $domain${NC}"
                    TOTAL_FAILED=$((TOTAL_FAILED + 1))
                fi
            fi
            ;;
        KEEP)
            echo -e "[#$TOTAL_SCANNED] ${GREEN}$domain${NC} (PHP $current_php) -> ${CYAN}Tetap (>= $TARGET_PHP_VERSION)${NC}"
            TOTAL_KEPT=$((TOTAL_KEPT + 1))
            ;;
        SKIP)
            echo -e "[#$TOTAL_SCANNED] ${NC}$domain${NC} (PHP: ${current_php:-Tidak ada}) -> ${YELLOW}Dilewati (Bukan web / PHP tidak aktif)${NC}"
            TOTAL_SKIPPED=$((TOTAL_SKIPPED + 1))
            ;;
    esac
done < <(echo "$DOMAINS_JSON" | jq -r '.data[] | [.name, (.values.php_version[0] // "-")] | @tsv')

echo -e "\n${CYAN}============================================================${NC}"
echo -e "${CYAN} RINGKASAN:${NC}"
echo -e " Total Domain Diperiksa : $TOTAL_SCANNED"
echo -e " Diupgrade ke PHP $TARGET_PHP_VERSION   : ${GREEN}$TOTAL_UPGRADED${NC}"
echo -e " Dipertahankan (>= $TARGET_PHP_VERSION) : ${CYAN}$TOTAL_KEPT${NC}"
echo -e " Dilewati (Tanpa PHP)   : ${YELLOW}$TOTAL_SKIPPED${NC}"
if [ $TOTAL_FAILED -gt 0 ]; then
    echo -e " Gagal Diupdate         : ${RED}$TOTAL_FAILED${NC}"
fi
echo -e "${CYAN}============================================================${NC}"
