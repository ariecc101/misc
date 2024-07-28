#!/bin/bash

# Check if directory and mode arguments are supplied
if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <directory> <mode>"
  echo "Modes:"
  echo "  debug - Only show files and directories that need permissions fixed"
  echo "  fix   - Fix chmod 644 for files and chmod 755 for directories"
  exit 1
fi

# Set the directory and mode to the arguments
TARGET_DIR="$1"
MODE="$2"

# Ensure the target directory exists
if [ ! -d "$TARGET_DIR" ]; then
  echo "Error: Directory $TARGET_DIR does not exist."
  exit 1
fi

# Function to find and print directories that need permission changes
debug_directories() {
  find "$TARGET_DIR" -type d \( ! -perm 755 -a ! -perm 000 \)
}

# Function to find and print files that need permission changes
debug_files() {
  find "$TARGET_DIR" -type f \( ! -perm 644 -a ! -perm 000 -a ! -perm 600 \)
}

# Function to find and fix directories permissions
fix_directories() {
  find "$TARGET_DIR" -type d \( ! -perm 755 -a ! -perm 000 \) -exec chmod 755 {} +
}

# Function to find and fix files permissions
fix_files() {
  find "$TARGET_DIR" -type f \( ! -perm 644 -a ! -perm 000 -a ! -perm 600 \) -exec chmod 644 {} +
}

# Determine the mode and execute corresponding actions
case "$MODE" in
  debug)
    echo "Directories needing permission changes:"
    debug_directories
    echo "Files needing permission changes:"
    debug_files
    ;;
  fix)
    echo "Fixing directory permissions..."
    fix_directories
    echo "Fixing file permissions..."
    fix_files
    ;;
  *)
    echo "Invalid mode. Use 'debug' to show or 'fix' to apply permission changes."
    exit 1
    ;;
esac
