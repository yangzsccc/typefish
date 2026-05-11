#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Running focused EditTracker logic tests"
swift test --filter EditTrackerTests

echo "==> Running event mirror capture-mode tests"
swift test --filter EditMirrorBufferTests

echo "==> Running real AppKit focus/clipboard snapshot E2E"
TYPEFISH_RUN_E2E=1 swift test --filter ContextSnapshotE2ETests/testClipboardSnapshotCapturesFrontmostTextEditDocument

echo "==> Running Chromium contenteditable composer snapshot E2E"
TYPEFISH_RUN_E2E=1 swift test --filter ContextSnapshotE2ETests/testClipboardSnapshotCapturesChromeContentEditableComposer

echo "==> Running auto-learn overlay visibility E2E"
TYPEFISH_RUN_E2E=1 swift test --filter OverlayPanelE2ETests/testAutoLearnOverlayCreatesVisibleWindow

echo "==> Building TypeFish"
swift build
