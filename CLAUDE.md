# TypeFish — macOS Voice-to-Text

## What This Is
A macOS menu bar app that converts speech to text with light AI polishing.
Press a hotkey to start recording, press again to stop, and polished text appears at your cursor.

## Tech Stack
- **Language:** Swift 5.9+
- **UI:** SwiftUI + AppKit (NSStatusItem for menu bar)
- **Audio:** AVAudioEngine (microphone capture → m4a file)
- **STT:** Groq Whisper API (whisper-large-v3-turbo)
- **Polish LLM:** Groq llama-3.3-70b-versatile (light text cleanup)
- **Paste:** NSPasteboard + CGEvent (simulate Cmd+V)
- **Target:** macOS 14+ (Sonoma), Apple Silicon
- **Build:** Swift Package Manager

## Architecture

```
Sources/TypeFish/
├── main.swift              — AppDelegate, NSApplication setup
├── MenuBarController.swift — NSStatusItem, menu, recording state indicator
├── AppState.swift          — Observable state, recording toggle, orchestrates pipeline
├── HotkeyManager.swift     — CGEvent tap for global hotkey (Option+Space)
├── AudioRecorder.swift     — AVAudioEngine → save to m4a/wav file
├── WhisperAPI.swift        — Groq Whisper API transcription
├── TextPolisher.swift      — Groq LLM light polish (fix stutters, keep original)
├── PasteService.swift      — Write to pasteboard + simulate Cmd+V
├── Config.swift            — Load config.json
└── Logger.swift            — File logger → /tmp/typefish.log
```

## Pipeline
```
[Option+Space] → Start recording (menu bar turns red)
[Option+Space] → Stop recording
  → AudioRecorder saves m4a
  → WhisperAPI transcribes (Groq, <1s)
  → TextPolisher cleans up (Groq LLM, <1s)
  → PasteService pastes at cursor
Total: < 3 seconds for short speech
```

## Key Design Decisions
1. **Toggle mode** (not hold-to-talk): Press once to start, press once to stop
2. **Light polish only**: Fix stutters, repetitions, self-corrections. Do NOT rewrite content.
3. **Groq for everything**: Both Whisper and LLM on Groq = fast + free tier
4. **No stealth needed**: This is a normal visible menu bar app
5. **CGEvent tap**: Swallow Option+Space so it doesn't trigger other things

## API Keys
Read from these locations (in order):
1. Environment variable: `GROQ_API_KEY`
2. File: `~/.config/typefish/groq_key`
3. File: `~/.config/noclue/groq_key` (shared with NoClue)

Format in file: `gsk_xxxxx` (raw key, no quotes, no prefix)

## Config (config.json in app directory)
```json
{
  "hotkey": "Option+Space",
  "whisper": {
    "model": "whisper-large-v3-turbo"
  },
  "polisher": {
    "model": "llama-3.3-70b-versatile",
    "systemPrompt": "You are a minimal text editor. Fix only: stutters, repetitions, and self-corrections. Keep the original wording, structure, and language. Do not rewrite, do not add formality, do not add formatting. If the input is already clean, output it unchanged. Output only the cleaned text, nothing else."
  }
}
```

## Permissions Required
1. **Accessibility** — CGEvent tap for global hotkey (System Settings → Privacy → Accessibility)
2. **Microphone** — Audio recording (auto-requested on launch)

## Build & Run
```bash
cd /Users/shuchenzhao/typefish
swift build
.build/debug/TypeFish
```

## Log
`/tmp/typefish.log`

## Reference
- NoClue project at `/Users/shuchenzhao/no-clue` has working examples of:
  - CGEvent tap (HotkeyManager.swift)
  - AVAudioEngine recording (AudioCapture.swift)
  - Groq Whisper API (SystemAudioCapture.swift)
  - Refer to these for proven patterns, but write fresh clean code.
