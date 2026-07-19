#!/bin/bash

# Menangkap argumen pertama sebagai file input
TARGET_FILE="$1"

# 1. Validasi apakah user memasukkan argumen file
if [ -z "$TARGET_FILE" ]; then
    echo "❌ Error: Kamu belum memasukkan file list user."
    echo "💡 Cara pakai: $0 [nama_file_teks]"
    echo "👉 Contoh: $0 /root/list.txt"
    exit 1
fi

# 2. Validasi apakah file yang dimasukkan benar-benar ada
if [ ! -f "$TARGET_FILE" ]; then
    echo "❌ Error: File '$TARGET_FILE' tidak ditemukan!"
    exit 1
fi

# 3. Membaca file teks ke dalam array (mengabaikan baris kosong)
mapfile -t WEBSITES < <(grep -v '^$' "$TARGET_FILE")

echo "=================================================="
echo " Memulai Update Massal WordPress"
echo " Menggunakan list file: $TARGET_FILE"
echo " Total target: ${#WEBSITES[@]} website"
echo "=================================================="

# 4. Proses Perulangan Update
for USERNAME in "${WEBSITES[@]}"
do
    # Menghapus karakter spasi atau new-line tersembunyi (\r)
    USERNAME=$(echo "$USERNAME" | tr -d '\r' | xargs)
    WP_PATH="/home/${USERNAME}/public_html"
    
    # Validasi apakah direktori public_html ada
    if [ -d "$WP_PATH" ]; then
        echo "🔄 [${USERNAME}] Sedang diproses..."
        
        su ${USERNAME} -c "/usr/local/bin/wp core update --path=${WP_PATH}"
        su ${USERNAME} -c "/usr/local/bin/wp core update-db --path=${WP_PATH}"
        su ${USERNAME} -c "/usr/local/bin/wp plugin update --all --path=${WP_PATH}"
        su ${USERNAME} -c "/usr/local/bin/wp theme update --all --path=${WP_PATH}"
        
        echo "✅ [${USERNAME}] Selesai diperbarui."
        echo "----------------------------------------"
    else
        echo "⚠️  [${USERNAME}] Folder tidak ditemukan (${WP_PATH}), dilewati."
        echo "----------------------------------------"
    fi
done

echo "🎉 Semua proses update selesai!"
