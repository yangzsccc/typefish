# Main Window Dictionary Learning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a regular TypeFish app window with settings and dictionary management, while improving correction-learning provenance and safety.

**Architecture:** Keep the app AppKit-based. Move shared config/dictionary operations into `AppState` and `CustomDictionary`, then rebuild `MainWindow` as a tabbed control center. Keep the menu bar as a fallback that calls the same helpers.

**Tech Stack:** Swift 5.9, AppKit, Swift Package Manager, XCTest.

---

### Task 1: Test Harness And Dictionary Metadata

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/TypeFish/Dictionary.swift`
- Create: `Tests/TypeFishTests/DictionaryTests.swift`

- [ ] Add an XCTest target in `Package.swift`.
- [ ] Write failing tests for backward-compatible decode, replacement provenance, and safe replacement boundaries.
- [ ] Implement `ReplacementMetadata`, source-aware add/update/remove helpers, and word-boundary replacement.
- [ ] Run `swift test`.

### Task 2: Token Diff And Safer Auto-Learn Application

**Files:**
- Modify: `Sources/TypeFish/EditTracker.swift`
- Create: `Tests/TypeFishTests/EditTrackerTests.swift`

- [ ] Expose deterministic internal helpers for token diff and validation under `@testable`.
- [ ] Write failing tests proving token diff does not reverse characters and unrelated edits are rejected.
- [ ] Replace character-level diff with token-level diff.
- [ ] Disable arbitrary clipboard fallback unless text overlap is high.
- [ ] Deduplicate accepted corrections and save them with `source: .autoLearned`.
- [ ] Run `swift test`.

### Task 3: Shared App Operations

**Files:**
- Modify: `Sources/TypeFish/AppState.swift`
- Modify: `Sources/TypeFish/MenuBarController.swift`

- [ ] Add shared config save/reload/dictionary methods to `AppState`.
- [ ] Update menu actions to use the shared helpers.
- [ ] Run `swift build`.

### Task 4: Regular Main Window Control Center

**Files:**
- Replace: `Sources/TypeFish/MainWindow.swift`

- [ ] Rebuild the window as a larger regular AppKit window with `NSTabView`.
- [ ] Add Dashboard, Dictionary, Settings, and Learning tabs.
- [ ] Implement dictionary tables for hints, vocabulary, manual replacements, and auto-learned replacements.
- [ ] Add add/edit/delete/search/reload/open-file controls.
- [ ] Add microphone and compression selectors that update config immediately.
- [ ] Run `swift build`.

### Task 5: Verification

**Files:**
- All touched files.

- [ ] Run `swift test`.
- [ ] Run `swift build`.
- [ ] Inspect `git diff` for accidental unrelated changes.
- [ ] Summarize remaining manual UI verification that requires launching the macOS app.
