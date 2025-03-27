#!/bin/bash

# File containing the URLs
FILE="unmul"

# Check if the file exists
if [ ! -f "$FILE" ]; then
  echo "File '$FILE' not found!"
  exit 1
fi

# Read URLs from the file and process each one
while IFS= read -r URL; do
  # Get the HTTP status code and Content-Type for each URL with a timeout of 1 second
  RESPONSE=$(curl -s -I --max-time 3 "$URL/.git/logs/HEAD")
  
  # Extract the status code
  STATUS_CODE=$(echo "$RESPONSE" | grep -i "HTTP/" | awk '{print $2}')
  
  # Extract the Content-Type
  CONTENT_TYPE=$(echo "$RESPONSE" | grep -i "Content-Type" | awk '{print $2}' | tr -d '\r')
  
  # Check if Content-Type is not 'text/html'
  if [[ "$CONTENT_TYPE" != "text/html" ]]; then
    echo "$URL/.git/logs/HEAD - Status Code: $STATUS_CODE - Content-Type: $CONTENT_TYPE"
  else
    echo "$URL/.git/logs/HEAD is served as HTML - Skipping"
  fi
done < "$FILE"
