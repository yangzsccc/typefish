# TypeFish Main Window, Dictionary Manager, And Auto-Learning Design

## Context

TypeFish is currently discoverable through two surfaces:

- `MenuBarController`: the status bar menu contains most actions, but it can be hidden by macOS menu bar overflow.
- `MainWindow`: a small Dock-accessible status window with shortcuts and health stats.

The recording overlay in `OverlayPanel` is intentionally tiny and transient. It should remain focused on live recording feedback, result copy fallback, and short notifications. The regular app window should become the durable control surface.

Auto-learning currently lives in `EditTracker` and writes learned corrections directly into `CustomDictionary.replacements`. Recent code added source-text and phonetic hard gates, which prevents bad entries, but recent logs show zero accepted corrections. The system also has no durable provenance for whether a replacement was manual or auto-learned.

## Goals

1. Make the regular TypeFish window the primary UI for settings and dictionary management.
2. Preserve the menu bar as a compact launcher/status fallback.
3. Let users inspect, add, edit, delete, and reload dictionary entries from the main window.
4. Clearly separate dictionary entry types: Whisper hints, vocabulary, manual replacements, and auto-learned corrections.
5. Add enough provenance to distinguish manual vs auto-learned replacements.
6. Improve auto-learning so it is reliable enough to learn real corrections without silently adding bad replacements.

## Non-Goals

- No SwiftUI rewrite in this pass.
- No new cloud service or server-side learning.
- No full replacement of the transient recording overlay.
- No hotkey customization in this pass unless already supported by existing config.

## Recommended UI

Extend `MainWindow` into a regular AppKit control center with a wider window and a tab selector. A tab layout fits the current AppKit code, avoids a large SwiftUI rewrite, and keeps the first version contained.

Sections:

- Dashboard: current status, shortcuts, recent health stats, current microphone, current compression, version.
- Dictionary: editable lists for hints, vocabulary, replacements, and auto-learned corrections.
- Settings: microphone selector, audio compression selector, dictionary reload/open-file actions, update check.
- Learning: auto-learning status and recent learned corrections from logs.

The Dictionary section is the highest priority. It should support:

- Add hint.
- Add vocabulary term.
- Add replacement with wrong/right fields.
- Edit selected replacement.
- Delete selected entries.
- Filter/search entries.
- Reload from disk.
- Open dictionary file for power-user editing.

## Data Model

Keep `CustomDictionary` backward compatible:

```swift
var hints: [String]
var replacements: [String: String]
var vocabulary: [String]
var replacementMetadata: [String: ReplacementMetadata]
```

`ReplacementMetadata` should include:

- `source`: `manual`, `autoLearned`, or `imported`
- `createdAt`
- `updatedAt`

Existing dictionaries decode unchanged because the new metadata field has a default empty value. Existing replacement entries without metadata should display as imported. Manual additions from both the menu and main window should mark source as `manual`. Auto-learning should mark source as `autoLearned`.

## Auto-Learning Direction

The current hard gates are safer, but the detection path is still weak because Accessibility reads often fail and clipboard fallback can compare unrelated text. The next iteration should:

1. Stop treating arbitrary clipboard changes as trusted corrections.
2. Use token-level diffs instead of character-level diffs before asking the LLM.
3. Keep source-text, edited-text, and phonetic validation gates.
4. Deduplicate candidates before applying.
5. Make learned entries visible and removable from the Dictionary/Learning UI.

Recommended behavior:

- High-confidence targeted edits can still be auto-added, but must be visible in the Learning/Dictionary UI and undoable.
- Low-confidence candidates should be logged or rejected instead of added.
- The UI should make it easy to delete bad auto-learned corrections.

## Implementation Boundaries

Use small helper APIs instead of duplicating menu logic in `MainWindow`:

- `AppState.saveConfig()`
- `AppState.reloadDictionary()`
- `CustomDictionary.addReplacement(..., source:)`
- `CustomDictionary.updateReplacement(...)`
- `CustomDictionary.removeReplacement(...)`
- similar helpers for hints and vocabulary

This lets `MenuBarController` and `MainWindow` share the same behavior.

## Testing

Add a Swift test target for deterministic logic:

- Dictionary metadata preserves backward compatibility.
- Manual and auto-learned replacements save with correct provenance.
- Word-boundary replacement does not corrupt longer words.
- Token-level diff avoids reversed/garbled character diffs.
- Auto-learning validation rejects unrelated clipboard-style edits.

Manual verification:

- `swift build`
- Launch `.build/debug/TypeFish`
- Click Dock icon and verify the regular window opens.
- Add, edit, delete, reload dictionary entries from the window.
- Select microphone/compression from the window.
- Confirm existing menu bar actions still work.
