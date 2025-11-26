#!/bin/bash
# SSH_ASKPASS helper for ProTerm
# This script is called by SSH to get the password

# Read the prompt from SSH (passed as argument)
PROMPT="$1"

# Use osascript to show a password dialog
PASSWORD=$(/usr/bin/osascript -e 'Tell application "System Events" to display dialog "'"$PROMPT"'" default answer "" with hidden answer' -e 'text returned of result' 2>/dev/null)

# Output the password to stdout (SSH reads it from here)
echo "$PASSWORD"
