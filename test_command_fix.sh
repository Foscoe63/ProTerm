#!/bin/bash

echo "Testing command execution fix..."

# Test 1: Check if PATH is properly inherited in PTY sessions
echo "=== Test 1: PATH Inheritance ==="
echo "Current PATH in regular shell:"
echo $PATH

# Test 2: Try to find opencode command
echo "=== Test 2: Command Discovery ==="
if command -v opencode &> /dev/null; then
    echo "✅ opencode found at: $(which opencode)"
else
    echo "❌ opencode not found in PATH"
fi

# Test 3: Check common paths
echo "=== Test 3: Common Path Analysis ==="
echo "Checking if user-specific paths exist:"
for path in "/Users/$USER/.opencode/bin" "/opt/homebrew/bin" "/usr/local/bin"; do
    if [ -d "$path" ]; then
        echo "✅ $path exists"
        ls -la "$path" | head -3
    else
        echo "❌ $path not found"
    fi
done

echo "=== Test 4: Environment Variables ==="
echo "TERM: $TERM"
echo "COLUMNS: $COLUMNS"
echo "LINES: $LINES"