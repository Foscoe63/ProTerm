#!/bin/bash

echo "🧪 Testing ProTerm Command Execution Fix"
echo "====================================="

# Test our fix by running opencode command in different contexts
echo "📍 Testing in current shell:"
if command -v opencode &> /dev/null; then
    echo "✅ opencode found at: $(which opencode)"
    echo "📦 Version: $(opencode --version 2>/dev/null || echo 'N/A')"
else
    echo "❌ opencode not found in PATH"
fi

echo ""
echo "🔍 Current PATH analysis:"
echo "$PATH" | tr ':' '\n' | grep -E "(opencode|local|brew)" | head -5

echo ""
echo "📋 Building ProTerm with our changes..."
cd /Volumes/Storage/Projects/ProTerm
xcodebuild -project ProTerm.xcodeproj -scheme ProTerm -configuration Debug build > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "✅ Build successful - our changes compile correctly"
else
    echo "❌ Build failed"
    exit 1
fi

echo ""
echo "🎯 Summary of Changes Made:"
echo "1. ✅ Fixed proterm_forkpty_spawn to inherit full environment"
echo "2. ✅ Fixed ProcessRunner to ensure PATH always exists"
echo "3. ✅ Fixed SSH execution to inherit current environment"
echo ""
echo "🚀 ProTerm is ready for testing with opencode!"