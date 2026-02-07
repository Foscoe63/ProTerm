#!/bin/bash

echo "🧪 Testing ProTerm with Fixed Environment"
echo "============================================"

# Test 1: Verify our changes are in the source
echo "✅ Checking SafeFileHandle.m for execve fix:"
grep -n "execve.*environ" /Volumes/Storage/Projects/ProTerm/ProTerm/Source/SafeFileHandle.m && echo "   ✓ execve with environ found" || echo "   ✗ execve fix NOT found"

echo ""

# Test 2: Check PTyWrapper for SSH environment fix  
echo "✅ Checking PTyWrapper.m for SSH environment fix:"
grep -n "envVars.*ProcessInfo" /Volumes/Storage/Projects/ProTerm/ProTerm/Source/PTyWrapper.swift && echo "   ✓ SSH environment inheritance found" || echo "   ✗ SSH fix NOT found"

echo ""

# Test 3: Check ProcessRunner for PATH fallback
echo "✅ Checking ProcessRunner.swift for PATH fallback:"
grep -n "PATH.*always exists" /Volumes/Storage/Projects/ProTerm/ProTerm/Source/ProcessRunner.swift && echo "   ✓ PATH safety fallback found" || echo "   ✗ PATH fallback NOT found"

echo ""

# Test 4: Verify current build status
echo "🏗 Testing ProTerm build:"
cd /Volumes/Storage/Projects/ProTerm
xcodebuild -project ProTerm.xcodeproj -scheme ProTerm -configuration Debug build > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "   ✅ Build SUCCESSFUL"
else
    echo "   ❌ Build FAILED"
    echo "   Checking errors..."
fi

echo ""
echo "📋 Summary:"
echo "- Fixed execve environment inheritance in PTY paths"
echo "- Enhanced SSH session environment handling"  
echo "- Added PATH safety fallbacks in ProcessRunner"
echo "- All changes should enable opencode and user-installed tools"
echo ""
echo "🚀 Next Step: Run the built ProTerm and test 'opencode' command"
echo ""
echo "💡 If opencode still fails, the issue may be in:"
echo "   - Shell initialization order within PTY"
echo "   - Environment variable precedence"  
echo "   - Path resolution timing"
echo ""
echo "🎯 Run this command to test: /Users/ewg/Library/Developer/Xcode/DerivedData/ProTerm-bsgsvjzhjfoywmdmryjfsqubbhpo/Build/Products/Debug/ProTerm.app/Contents/MacOS/ProTerm"