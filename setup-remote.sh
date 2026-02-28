#!/bin/bash
# TypeFish Setup — Run this on the new machine
# Usage: bash setup-remote.sh
set -e

echo "🐟 TypeFish Setup"
echo ""

# Check if API key is already set
CONFIG_DIR="$HOME/.config/typefish"
KEY_FILE="$CONFIG_DIR/groq_key"

if [ -f "$KEY_FILE" ]; then
    echo "✅ API key already configured at $KEY_FILE"
else
    echo "📝 Enter Groq API key (get one free at https://console.groq.com):"
    read -r API_KEY
    if [ -z "$API_KEY" ]; then
        echo "❌ No API key provided. You can set it later:"
        echo "   mkdir -p ~/.config/typefish"
        echo "   echo 'YOUR_KEY' > ~/.config/typefish/groq_key"
    else
        mkdir -p "$CONFIG_DIR"
        echo "$API_KEY" > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        echo "✅ API key saved to $KEY_FILE"
    fi
fi

echo ""
echo "📋 Next steps:"
echo "   1. Double-click TypeFish.app (if blocked: right-click → Open)"
echo "   2. Grant Accessibility: System Settings → Privacy → Accessibility → add TypeFish"
echo "   3. Grant Microphone when prompted"
echo "   4. Restart TypeFish after granting Accessibility"
echo "   5. Option+Space to start/stop recording!"
echo ""
echo "🐟 Done!"
