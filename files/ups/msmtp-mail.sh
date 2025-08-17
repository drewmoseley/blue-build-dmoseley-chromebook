#!/bin/bash

# Minimal replacement for the 'mail' command using msmtp.
# Usage: echo "message body" | msmtp-mail.sh -s "subject" recipient@example.com

# Parse options
subject=""
while getopts "s:" opt; do
  case $opt in
    s) subject="$OPTARG" ;;
    *) echo "Usage: $0 [-s subject] recipient"; exit 1 ;;
  esac
done
shift $((OPTIND -1))

# Remaining argument is the recipient
recipient="$1"
if [ -z "$recipient" ]; then
  echo "Usage: $0 [-s subject] recipient"
  exit 1
fi

# Read message body from stdin
body=$(cat)

# Exit silently if input is empty
if [ -z "$body" ]; then
  exit 0
fi

# Send using msmtp
{
  echo "To: $recipient"
  echo "Subject: $subject"
  echo
  echo "$body"
} | msmtp -C /etc/ups/.msmtprc -t

