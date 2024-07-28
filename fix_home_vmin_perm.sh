#!/bin/bash

# Check if the directory argument is supplied
if [ -z "$1" ]; then
  echo "Usage: $0 /path/to/directory"
  exit 1
fi

cd $1
chmod 755 awstats
chmod 755 bin
chmod 750 cgi-bin
chmod 755 cgi-bin/awstats.pl
chmod 755 etc
chmod 755 fcgi-bin
chmod 755 homes
chmod 750 logs
chmod 700 Maildir
chmod 700 Maildir/.Drafts
chmod 700 Maildir/.Sent
chmod 700 Maildir/.Trash
chmod 700 Maildir/cur
chmod 700 Maildir/new
chmod 700 Maildir/tmp
chmod 644 Maildir/subscriptions
chmod 750 tmp
chmod 700 virtualmin-backup
