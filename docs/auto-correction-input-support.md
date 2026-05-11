# TypeFish Auto-Correction Input Support

Date: 2026-05-11

TypeFish auto-correction learns from edits you make after TypeFish pastes a transcription. It now uses multiple capture strategies because macOS apps expose text input in different ways.

## Support Matrix

| Input surface | Examples | Current support | Capture strategy |
|---|---|---|---|
| Native macOS text fields | TextEdit, Notes, Mail, standard search fields | Supported | Accessibility text read |
| AX-friendly custom apps | WeChat in current testing | Supported | Accessibility text read |
| Browser text inputs | Chrome pages with `input`, `textarea`, `contenteditable` | Supported when copy/AX works | Accessibility, then clipboard snapshot |
| Electron chat apps | Discord, Slack, Teams | Best effort | Before-send clipboard snapshot after edits |
| Codex-like custom inputs | Codex desktop app | Best effort for keyboard-driven edits | Event mirror buffer |
| Terminal emulators | Terminal.app, Ghostty, iTerm2, Warp | Conservative best effort | Event mirror buffer with stricter safety gates |
| Secure/password inputs | Password fields, sudo password prompts, keychain prompts | Not captured | Skipped |
| Remote/canvas inputs | Remote Desktop, VNC, games, canvas editors | Not automatically captured | Manual fallback only |

## What Works Best

Auto-correction is strongest when the target app exposes the current text field through macOS Accessibility. This includes standard AppKit controls and some custom apps. In that mode, TypeFish reads the full field content after your edit and compares it with the text TypeFish pasted.

Browser and Electron apps vary. TypeFish first tries Accessibility. If the app does not expose the focused text, TypeFish can briefly snapshot the draft with a guarded select-all/copy flow before send. This is protected by a sentinel pasteboard check so stale clipboard contents are not treated as real input.

Codex-like inputs can block both Accessibility reads and synthetic copy. For these, TypeFish uses an event mirror: after TypeFish pastes text, it keeps a short-lived internal buffer and applies the keyboard edits you make during the tracking window. It is active only immediately after a TypeFish paste, and it stops on timeout, a new recording, or unreliable edit patterns.

## Important Limits

- Event mirror works best for keyboard edits: typing, Backspace/Delete, arrow movement, Cmd+A replacement, and Cmd+V replacement.
- Mouse-only cursor moves, drag/drop, rich text transformations, autocomplete, Cmd+Z, and complex IME composition may make the mirror unreliable.
- Terminal support is intentionally conservative because terminal apps are PTY grids, not normal text editors.
- Secure input and password-like fields are skipped by design.

## False-Positive Protection

Before TypeFish learns anything, the edit must pass strict safety gates:

- the edited text must substantially overlap the original text
- the diff must be focused, preferably one changed region
- the wrong and corrected terms must both appear in the original/edited texts
- length difference and length ratio must stay small
- phonetic similarity must be high enough
- secure, unrelated, or low-confidence captures are rejected

If the edit looks like a rewrite, an appended sentence, a command change, or unrelated clipboard text, TypeFish should not add a dictionary correction.

## How To Interpret "Supported"

Supported means TypeFish has an automatic path for that input class. It does not mean every custom app or every editor widget inside that class behaves identically. When TypeFish cannot safely read or reconstruct an edit, it should skip learning instead of guessing.

