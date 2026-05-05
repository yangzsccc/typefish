#!/bin/bash
# Build TypeFish.app — double-clickable macOS app bundle
set -e

echo "🐟 Building TypeFish..."
cd "$(dirname "$0")"
VERSION="$(grep 'currentVersion' Sources/TypeFish/Updater.swift | head -1 | sed 's/.*"\(.*\)".*/\1/')"

# Build release
swift build -c release 2>&1 | tail -3

# Create .app bundle
APP_DIR="TypeFish.app/Contents/MacOS"
mkdir -p "$APP_DIR"
mkdir -p "TypeFish.app/Contents/Resources"

# Copy binary
cp .build/release/TypeFish "$APP_DIR/TypeFish"

# Copy custom sounds
cp Sources/TypeFish/Sounds/*.aiff "TypeFish.app/Contents/Resources/" 2>/dev/null || true

# Copy default dictionary
cp default-dictionary.json "TypeFish.app/Contents/Resources/" 2>/dev/null || true

# Generate app icon from source PNG
if [ -f "Assets/AppIcon.png" ]; then
    ICONSET="TypeFish.app/Contents/Resources/AppIcon.iconset"
    mkdir -p "$ICONSET"
    sips -z 16 16     "Assets/AppIcon.png" --out "$ICONSET/icon_16x16.png" >/dev/null 2>&1
    sips -z 32 32     "Assets/AppIcon.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null 2>&1
    sips -z 32 32     "Assets/AppIcon.png" --out "$ICONSET/icon_32x32.png" >/dev/null 2>&1
    sips -z 64 64     "Assets/AppIcon.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null 2>&1
    sips -z 128 128   "Assets/AppIcon.png" --out "$ICONSET/icon_128x128.png" >/dev/null 2>&1
    sips -z 256 256   "Assets/AppIcon.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "Assets/AppIcon.png" --out "$ICONSET/icon_256x256.png" >/dev/null 2>&1
    sips -z 512 512   "Assets/AppIcon.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "Assets/AppIcon.png" --out "$ICONSET/icon_512x512.png" >/dev/null 2>&1
    sips -z 1024 1024 "Assets/AppIcon.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "$ICONSET" -o "TypeFish.app/Contents/Resources/AppIcon.icns" 2>/dev/null
    rm -rf "$ICONSET"
fi

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
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>TypeFish</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <false/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>TypeFish needs microphone access to record your speech for transcription.</string>
</dict>
</plist>
PLIST

# Code sign (preserves Accessibility permission across rebuilds)
# Try named certificate first, fall back to ad-hoc signing
if security find-identity -v -p codesigning | grep -q "Local Dev Signing"; then
    codesign --force --deep --sign "Local Dev Signing" "TypeFish.app" 2>&1
else
    codesign --force --deep --sign - "TypeFish.app" 2>&1
fi
echo "✅ Built & signed: $(pwd)/TypeFish.app"
echo "📋 Next steps:"
echo "   1. Double-click TypeFish.app to launch"
echo "   2. Grant Accessibility permission when prompted"
echo "   3. Grant Microphone permission when prompted"
echo "   4. Option+Space to start/stop recording"
echo ""
echo "💡 To add to Login Items (auto-start):"
echo "   System Settings → General → Login Items → add TypeFish.app"
