#!/bin/bash
# Build TypeFish.app — double-clickable macOS app bundle
set -e

echo "🐟 Building TypeFish..."
cd "$(dirname "$0")"

# Build release
swift build -c release 2>&1 | tail -3

# Create .app bundle
APP_DIR="TypeFish.app/Contents/MacOS"
mkdir -p "$APP_DIR"
mkdir -p "TypeFish.app/Contents/Resources"

# Copy binary
cp .build/release/TypeFish "$APP_DIR/TypeFish"

# Create Info.plist
cat > TypeFish.app/Contents/Info.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>TypeFish</string>
    <key>CFBundleDisplayName</key>
    <string>TypeFish</string>
    <key>CFBundleIdentifier</key>
    <string>com.shuchen.typefish</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>TypeFish</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>TypeFish needs microphone access to record your speech for transcription.</string>
</dict>
</plist>
PLIST

echo "✅ Built: $(pwd)/TypeFish.app"
echo "📋 Next steps:"
echo "   1. Double-click TypeFish.app to launch"
echo "   2. Grant Accessibility permission when prompted"
echo "   3. Grant Microphone permission when prompted"
echo "   4. Option+Space to start/stop recording"
echo ""
echo "💡 To add to Login Items (auto-start):"
echo "   System Settings → General → Login Items → add TypeFish.app"
