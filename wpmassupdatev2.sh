#!/bin/bash

echo "=================================================="
echo " Memulai Pencarian & Update Massal WordPress"
echo "=================================================="

# 1. Cari semua file wp-config.php dan lakukan perulangan path
find /home/ -maxdepth 4 -type f -name "wp-config.php" | while read -r CONFIG_PATH
do
    # Ambil path direktori utama WordPress (folder yang berisi wp-config.php)
    WP_PATH=$(dirname "$CONFIG_PATH")
    
    # Ambil nama user Linux pemilik folder tersebut berdasarkan struktur /home/NAMA_USER/
    USERNAME=$(echo "$WP_PATH" | awk -F'/' '{print $3}')
    
    echo "🔍 Ditemukan WordPress di: $WP_PATH (User: $USERNAME)"
    
    # 2. Amankan hak kepemilikan file (chown) sebelum update agar tidak error permission
    chown -R "${USERNAME}:${USERNAME}" "$WP_PATH"
    
    # 3. Eksekusi rangkaian update menggunakan user pemiliknya
    echo "🔄 Sedang memperbarui..."
    su "$USERNAME" -c "/usr/local/bin/wp core update --path=$WP_PATH"
    su "$USERNAME" -c "/usr/local/bin/wp core update-db --path=$WP_PATH"
    su "$USERNAME" -c "/usr/local/bin/wp plugin update --all --path=$WP_PATH"
    su "$USERNAME" -c "/usr/local/bin/wp theme update --all --path=$WP_PATH"
    
    echo "✅ Selesai untuk $WP_PATH"
    echo "--------------------------------------------------"
done

echo "🎉 Semua instalasi WordPress berhasil dipindai dan diperbarui!"
