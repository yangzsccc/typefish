# TypeFish Auto-Correction Input Surface Research

Date: 2026-05-09

## Goal

TypeFish should learn from a user's manual edits after paste, without requiring a manual hotkey, across common macOS input surfaces:

- native apps
- Codex-like custom chat inputs
- Chrome/web contenteditable inputs
- Discord/Electron apps
- WeChat
- Terminal/Ghostty/iTerm-style terminal emulators

The conclusion is that there is no single reliable macOS API for all of these. We need a capability-based strategy selected per focused app/input surface.

## Current TypeFish Evidence

Observed in `/tmp/typefish.log` and the current codebase:

- **WeChat works through Accessibility.**
  - `ContextReader.readInputState()` succeeded.
  - EditTracker detected `cloud -> Claude`.
  - LLM accepted it.
  - Dictionary and `auto-corrections.jsonl` were updated.
  - This means the WeChat failure the user saw was overlay visibility, not learning.

- **Codex currently fails both AX and clipboard snapshot.**
  - AX: `Context: cannot get focused element (-25212)`.
  - Snapshot: `Context snapshot: no usable copied text (copySucceeded=false)`.
  - So Codex needs a different fallback; further tuning `Cmd+A/C` is unlikely to be enough.

- **Chrome contenteditable is a good Codex-like automated proxy, but not identical to Codex.**
  - `ContextSnapshotE2ETests/testClipboardSnapshotCapturesChromeContentEditableComposer` passes.
  - It verifies Chromium/web contenteditable + real `Cmd+A/C` + safety gate.
  - Codex still differs because its app/input layer does not respond to our synthetic copy path.

- **Auto-learn overlay now has a real E2E.**
  - `OverlayPanelE2ETests/testAutoLearnOverlayCreatesVisibleWindow` checks a real visible `NSPanel`.
  - It also captures `/tmp/typefish-autolearn-overlay-e2e.png`.

## macOS Input Surface Taxonomy

| Class | Examples | Typical implementation | Best capture method | Status / risk |
|---|---|---|---|---|
| Native AppKit text controls | TextEdit, Notes, Mail, many settings/search fields | `NSTextView`, `NSTextField`, `NSTextInputClient` | AX focused element: `AXValue`, `AXSelectedTextRange` | Highest confidence |
| Native/custom but AX-exposed apps | WeChat in current testing | Custom/native text element with usable AX value/range | AX read + keypress debounce + Enter immediate analysis | Confirmed works |
| Browser web text inputs | Chrome/Safari pages with `input`, `textarea`, `contenteditable` | Web accessibility tree backed by browser | AX if available; otherwise sentinel clipboard snapshot | Chrome contenteditable E2E passes |
| Electron/Chromium desktop chat apps | Discord, Slack, Teams, VS Code chat-like inputs | Chromium view embedded in app; often inconsistent AX | Try AX, then sentinel snapshot; app-specific fallback if both fail | Mixed. Needs per-app probing |
| Codex-like custom app input | Codex desktop app | Custom app/WebView/input stack; AX and synthetic copy may be blocked | Event-sourced mirror buffer is likely required | Current blocker |
| Terminal emulators | Terminal.app, Ghostty, iTerm2, Warp | PTY grid, not a normal editable document | Do not use `Cmd+A/C`; use event mirror or shell integration | Needs special mode |
| Secure/password fields | Password prompts, keychain, browser password fields, sudo in terminal | Secure input / secure text fields | Skip tracking | Must not capture |
| Remote/VM/canvas inputs | Remote Desktop, VNC, games, canvas editors | Pixels/remote session, weak local text state | Skip or explicit manual learn | Low confidence |

## Capability Layers

### 1. AX Input State

Use when `ContextReader.readInputState()` can read full text and cursor range.

Best for:

- TextEdit/native apps
- WeChat
- some browser inputs

Why: Apple exposes editable text attributes like selected text range for editable accessibility objects. Standard AppKit controls generally provide accessibility automatically. AX can still return `kAXErrorCannotComplete` when the target app is unresponsive or does not expose the focused element.

Implementation:

- On paste, store `pastedText`.
- Poll after keypress debounce.
- Compare current full content with pasted text.
- On Enter, analyze immediately.
- Keep strict safety gates.

### 2. Sentinel Clipboard Snapshot

Use when AX fails but `Cmd+A/C` works in the target input.

Best for:

- Chrome local `contenteditable`
- many web chat composers
- possibly some Electron apps

Current mechanism:

- Save pasteboard.
- Select all.
- Write a sentinel into pasteboard.
- Copy.
- If sentinel was replaced, treat copied text as current field content.
- Restore pasteboard.

This avoids the old bug where stale clipboard contents were treated as a fresh snapshot.

Limitations:

- Disrupts selection briefly.
- Can fail if the app ignores synthetic `Cmd+A/C`.
- In terminal emulators, `Cmd+A` often means something unrelated to "current input line".

### 3. Event-Sourced Mirror Buffer

Use when both AX and clipboard snapshot fail, but TypeFish already knows the pasted text and can observe the user's edits while tracking is active.

Best for:

- Codex desktop app
- custom chat inputs with blocked AX/copy
- possibly Discord if snapshot fails

Mechanism:

- Initialize an internal editable buffer with `pastedText`.
- During the 15-second tracking window, apply observed key events:
  - character insertion
  - Backspace/Delete
  - arrow movement
  - Option/Command movement where feasible
  - Cmd+A replacement
  - paste events from pasteboard when detectable
- On Enter, compare mirror buffer to original and analyze.

Why this is promising for Codex:

- Paste works into Codex.
- Key events are observed by TypeFish after paste.
- The failure is reading the field, not observing that the user typed.

Risks:

- Mouse selection edits are hard to mirror.
- IME/composition text is hard to reconstruct from raw key events.
- Cmd+Z, drag/drop, autocomplete, and rich text behavior need guardrails.

Privacy boundary:

- Only enable while TypeFish is tracking a recent TypeFish paste.
- Never run as a general keylogger.
- Disable immediately on timeout, new recording, secure input, or unrelated focus change.

### 4. Shell / Terminal Integration

Use for Terminal, Ghostty, iTerm2, Warp.

Do not rely on AX or `Cmd+A/C` as the default. Terminals are PTY grids, not document editors. `Cmd+A` may select all terminal output or trigger app behavior; copying may capture scrollback or nothing useful.

Possible strategies:

- **Short term:** event-sourced mirror buffer after TypeFish paste, with conservative constraints.
- **Better:** optional shell integration:
  - zsh/bash hook captures the current command line before execution.
  - TypeFish stores the pasted text and receives the final submitted command from shell hook.
  - Analyze only if overlap/diff safety gate passes.
- **Skip cases:** sudo/password prompts or secure keyboard input.

### 5. Explicit Manual Learn Fallback

Use only when the app is not safely readable.

Examples:

- remote desktops
- VMs
- canvas-based apps
- terminals without shell integration
- secure/unknown fields

This can be a fallback, not the main path: e.g. "Learn correction from selected/current clipboard" or a dedicated hotkey after the user selects the corrected text.

## App-by-App Recommendation

| App / surface | Recommended strategy | Implementation priority |
|---|---|---|
| WeChat | AX input state | Already works; keep overlay visible and logged |
| TextEdit/native AppKit | AX input state | Already covered by tests |
| Chrome web inputs | AX or sentinel snapshot | Covered by contenteditable E2E |
| Safari web inputs | Add Safari contenteditable E2E; likely AX/snapshot | Medium |
| Discord | Probe AX first; if AX fails, try sentinel snapshot; if both fail, event mirror | High |
| Slack/Teams | Same as Discord | Medium |
| Codex | Event-sourced mirror buffer | Highest priority |
| Terminal.app | Event mirror only for simple edits; shell integration for robust support | Medium |
| Ghostty | Same terminal category; shell integration preferred | Medium |
| iTerm2/Warp | Same terminal category; check secure input settings | Medium |
| VS Code/Cursor chat/editor | AX/snapshot probe, then event mirror | Medium |
| Password/secure fields | Skip | Required |

## Capability Probe Design

Add a per-bundle capability cache:

```swift
enum EditCaptureMode {
    case accessibility
    case clipboardSnapshot
    case eventMirror
    case terminalShellIntegration
    case unsupported
}
```

At `startTracking`:

1. Save bundle id, app name, pid.
2. Try an AX read after paste.
3. If AX fails, classify app:
   - known terminal -> terminal strategy
   - known blocked custom app like Codex -> event mirror
   - known Electron/web -> snapshot or event mirror
4. Cache success/failure by bundle id and app version when possible.
5. Log the chosen mode:

```text
EditTracker: capture mode=accessibility app=WeChat
EditTracker: capture mode=eventMirror app=Codex reason=ax_failed,snapshot_failed
```

## Suggested Implementation Phases

### Phase 1: Instrumentation and routing

- Add `EditCaptureMode`.
- Log mode choice and mode-specific failures.
- Cache per-app capability results.
- Add app classifiers:
  - native/AX-capable
  - web/electron
  - terminal
  - blocked/custom
  - secure/unsupported

### Phase 2: Codex fallback

- Implement event-sourced mirror buffer for the tracking window.
- Start with simple operations:
  - regular character insertion
  - Backspace/Delete
  - left/right arrow
  - Cmd+A + replacement
  - Enter finalization
- Add tests for `Cloud Code -> Claude Code`.
- Only analyze if safety gate passes.

### Phase 3: terminal support

- Add terminal app detection:
  - `com.apple.Terminal`
  - Ghostty bundle id
  - iTerm2 bundle id
  - Warp bundle id
- Use event mirror only for simple post-paste edits.
- Design optional shell integration for robust command-line learning.

### Phase 4: app-specific E2Es

Keep the current E2E script, then add:

- Safari contenteditable composer
- Discord-like local Electron harness if feasible
- event-mirror Codex-like synthetic key stream test
- terminal mirror-buffer unit tests

## False Positive Policy

The safety gate should remain strict:

- Require significant overlap between original and edited text.
- Require a focused diff, preferably one changed region.
- Reject large length differences.
- Reject low phonetic similarity.
- Reject changes involving passwords/secure inputs/terminal prompts with no reliable context.
- Require correction terms to exist in original/edited text before adding dictionary entries.

For terminal and event mirror modes, use even stricter gates because the capture layer is less authoritative.

## Bottom Line

TypeFish can cover most macOS input types, but not with one mechanism:

- **AX read** for native and AX-friendly apps like WeChat.
- **Sentinel clipboard snapshot** for many browser/web composers.
- **Event-sourced mirror buffer** for Codex-like blocked inputs.
- **Terminal-specific mode or shell integration** for Terminal/Ghostty/iTerm/Warp.
- **Skip or manual fallback** for secure, remote, or canvas inputs.

The next practical engineering step is Codex support via event-sourced mirror buffer, because current logs show Codex consistently fails both AX and snapshot while still delivering key events to TypeFish.

## Sources

- Apple Developer Documentation: `NSTextInputClient` describes how custom text views participate in Cocoa text input and marked-text handling.
  https://developer.apple.com/documentation/AppKit/NSTextInputClient
- Apple Developer Documentation: `kAXSelectedTextRangeAttribute` is required for editable text accessibility objects.
  https://developer.apple.com/documentation/applicationservices/kaxselectedtextrangeattribute
- Apple Developer Documentation: `AXUIElement.h` documents AX messaging and errors such as `kAXErrorCannotComplete`.
  https://developer.apple.com/documentation/applicationservices/axuielement_h
- Apple Developer Documentation: `NSPasteboard` is the shared system pasteboard interface.
  https://developer.apple.com/documentation/appkit/nspasteboard
- Apple Developer Documentation: Quartz Event Services / `CGEvent` event taps can observe/filter keyboard input before foreground delivery.
  https://developer.apple.com/documentation/coregraphics/quartz-event-services
  https://developer.apple.com/documentation/coregraphics/cgevent
- Apple Technical Note TN2150: Secure Event Input prevents other processes from receiving keyboard events while enabled.
  https://leopard-adc.pepas.com/technotes/tn2007/tn2150.html
