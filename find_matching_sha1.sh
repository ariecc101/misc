#!/bin/bash

# Check if the correct number of arguments is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <directory_to_search>"
    exit 1
fi

# Assign arguments to variables
directory_to_search=$1

# Read the list of SHA1 checksums from the file
checksum_list="file_list.txt"
declare -A checksums
while IFS= read -r checksum; do
    checksums["$checksum"]=1
    echo "SHA1 checksum to search: $checksum"
done < "$checksum_list"

# Find and list all files with matching SHA1 checksums
echo "Searching for files with matching SHA1 checksums in $directory_to_search..."
find "$directory_to_search" -type f -exec sha1sum {} + | while read -r file_checksum file_path; do
    if [[ -n "${checksums[$file_checksum]}" ]]; then
        echo "File with matching SHA1 checksum found: $file_path"
    fi
done
