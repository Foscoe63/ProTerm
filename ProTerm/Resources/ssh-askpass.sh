# Secure SSH password prompt using AppleScript
PROMPT="$1"
if [ -z "$PROMPT" ]; then
    PROMPT="SSH Password:"
fi

# Get password via secure AppleScript dialog (no process env exposure)
PASSWORD=$(/usr/bin/osascript -e ' Tell application "System Events" to display dialog "'"$PROMPT"'" default answer "" with hidden answer' -e 'text returned of result' 2>/dev/null)

# Sanitize output (escape special characters)
echo "$PASSWORD" | sed 's/[$`\\"]/\\/&/g'
