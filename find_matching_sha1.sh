#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    echo "Usage: $0 <directory_to_search> [disable_file]"
    exit 1
fi

# Assign arguments to variables
directory_to_search=$1
disable_file_mode=$2

# Read the list of SHA1 checksums from the file
checksum_list="file_list.txt"
declare -A checksums
while IFS= read -r checksum; do
    checksums["$checksum"]=1
    echo "SHA1 checksum to search: $checksum"
done < "$checksum_list"

# Function to change permissions and ownership
secure_file() {
    file=$1
    chmod 000 "$file"
    chown root:root "$file"
    echo "Secured file: $file"
}

# ANSI color codes for green and bold
GREEN="\033[1;32m"
RESET="\033[0m"

# Find and list all files with matching SHA1 checksums, and optionally secure them
echo "Searching for files with matching SHA1 checksums in $directory_to_search..."
find "$directory_to_search" -type f -exec sha1sum {} + | while read -r file_checksum file_path; do
    if [[ -n "${checksums[$file_checksum]}" ]]; then
        echo -e "${GREEN}File with matching SHA1 checksum found:${RESET} $file_path"
        if [ "$disable_file_mode" == "disable_file" ]; then
            secure_file "$file_path"
        fi
    fi
done
