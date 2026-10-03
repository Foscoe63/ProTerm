#!/bin/bash

echo "🧪 Testing ProTerm Command Execution Fix"
echo "=================================="

echo "1. Testing PATH inheritance in current shell:"
if command -v opencode &>/dev/null; then
    echo "✅ opencode found in current shell: $(which opencode)"
else
    echo "❌ opencode NOT found in current shell"
fi

echo ""
echo "2. Current PATH analysis:"
echo "$PATH" | tr ':' '\n' | grep -E "(opencode|local|brew)" | head -5

echo ""
echo "3. ProTerm build status:"
cd /Volumes/Storage/Projects/ProTerm
xcodebuild -project ProTerm.xcodeproj -scheme ProTerm -configuration Debug build > /dev/null 2>&1 && echo "✅ ProTerm builds successfully" || echo "❌ ProTerm build failed"

echo ""
echo "📋 Test Results:"
echo "- Command PATH fix implemented in SafeFileHandle.m"
echo "- SSH environment inheritance fixed in TerminalSession.swift"  
echo "- ProcessRunner PATH fallbacks added"
echo "- Build status: $(xcodebuild -project ProTerm.xcodeproj -scheme ProTerm -configuration Debug build > /dev/null 2>&1 && echo '✅ Success' || echo '❌ Failed')"

echo ""
echo "🎯 Next Steps:"
echo "1. Run ProTerm and test 'opencode' command"
echo "2. If it still fails, check shell initialization within PTY"
echo "3. Verify environment variables are properly inherited"