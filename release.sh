#!/bin/bash
# Usage: bash release.sh [version]
# Example: bash release.sh 1.2.0

set -e

VERSION="${1:-$(grep 'currentVersion' Sources/TypeFish/Updater.swift | head -1 | sed 's/.*"\(.*\)".*/\1/')}"
TAG="v${VERSION}"

echo "🐟 Releasing TypeFish $TAG..."

# Build
swift build -c release
bash build-app.sh

# Create release zip
TMPDIR=$(mktemp -d)
cp -R TypeFish.app "$TMPDIR/"
cd "$TMPDIR"
zip -r TypeFish.zip TypeFish.app
cd -

# Also update desktop zip for manual sharing
cp "$TMPDIR/TypeFish.zip" ~/Desktop/TypeFish.zip

# Git commit & tag
git add -A
git commit -m "release: TypeFish $TAG" --allow-empty
git tag -f "$TAG"
git push origin main --force-with-lease
git push origin "$TAG" --force

# Create GitHub release
gh release delete "$TAG" -y 2>/dev/null || true
gh release create "$TAG" "$TMPDIR/TypeFish.zip" \
    --title "TypeFish $TAG" \
    --notes "TypeFish $TAG release"

rm -rf "$TMPDIR"

echo "✅ Released TypeFish $TAG"
echo "📦 GitHub: https://github.com/yangzsccc/typefish/releases/tag/$TAG"
echo "📁 Desktop: ~/Desktop/TypeFish.zip"
