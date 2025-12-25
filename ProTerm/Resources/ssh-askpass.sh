# Check if password is provided via environment variable
if [ ! -z "$PROTERM_SSH_PASSWORD" ]; then
    echo "$PROTERM_SSH_PASSWORD"
    exit 0
fi

# Fallback to osascript dialog if no environment variable is set
PROMPT="$1"
PASSWORD=$(/usr/bin/osascript -e 'Tell application "System Events" to display dialog "'"$PROMPT"'" default answer "" with hidden answer' -e 'text returned of result' 2>/dev/null)

echo "$PASSWORD"
