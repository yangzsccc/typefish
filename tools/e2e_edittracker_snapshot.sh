#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Running focused EditTracker logic tests"
swift test --filter EditTrackerTests

echo "==> Running insertion and background learning tests"
swift test --filter PostPasteCaptureTests
swift test --filter EditLearningMonitorTests

echo "==> Running the TextEdit insertion and edit test"
TYPEFISH_RUN_E2E=1 swift test --filter ContextSnapshotE2ETests/testAnchoredPasteAndOwnedEditInTextEdit

echo "==> Running Chromium contenteditable composer snapshot E2E"
TYPEFISH_RUN_E2E=1 swift test --filter ContextSnapshotE2ETests/testAnchoredPasteAndOwnedEditInChromeContentEditable

echo "==> Running auto-learn overlay visibility E2E"
TYPEFISH_RUN_E2E=1 swift test --filter OverlayPanelE2ETests/testAutoLearnOverlayCreatesVisibleWindow

echo "==> Building TypeFish"
swift build
