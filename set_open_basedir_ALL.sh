#!/bin/bash

# Get the list of all domains
DOMAINS=$(virtualmin list-domains --name-only)

# Loop through each domain
for DOMAIN in $DOMAINS; do
    echo "Processing domain: $DOMAIN"

    # Get the home directory for the domain
    HOME_DIR=$(virtualmin list-domains --domain $DOMAIN --multiline | grep "Home directory" | awk '{print $3}')

    # Check if the home directory was found
    if [ -z "$HOME_DIR" ]; then
        echo "Home directory not found for domain $DOMAIN"
        continue
    fi

    # Define the user-specific temporary directory relative to HOME_DIR
    #TMP_DIR="${HOME_DIR}/tmp"

    # Set the open_basedir directive
    #virtualmin modify-php-ini --domain $DOMAIN --ini-name open_basedir --ini-value "${HOME_DIR}:${TMP_DIR}"
    virtualmin modify-php-ini --domain $DOMAIN --ini-name open_basedir --ini-value "${HOME_DIR}"

    # Output success message
    #echo "open_basedir set to ${HOME_DIR}:${TMP_DIR} for domain $DOMAIN"
    echo "open_basedir set to ${HOME_DIR} for domain $DOMAIN"
done

# Restart Apache
sudo systemctl restart apache2 || sudo systemctl restart httpd

echo "open_basedir setting completed for all domains."
