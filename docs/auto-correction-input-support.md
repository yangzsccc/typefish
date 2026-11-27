# TypeFish post-dictation spelling support

On-device acceptance, November 27, 2026. Apple Silicon, macOS 26.3. The measurements below come from the local feature-acceptance build. The v2.6.0 release checks are listed separately below.

## What happens after a paste

TypeFish reads the foreground app, window, editable Accessibility element, UTF-16 selection and text immediately before posting the paste. It confirms the expected edit and the resulting caret in the same element. An immutable prefix and suffix identify the inserted range, including when the same sentence already occurs elsewhere. A secure field, a changed destination, a caret outside that range or an unconfirmed paste ends learning for the session. A genuinely empty native field is supported. For the tested blank Codex composer, TypeFish recognizes the placeholder child, its matching title and the collapsed start selection.

During a session a background reader samples the confirmed field. TypeFish waits for a settled substitution, checks its size and phonetic overlap, and asks the configured classifier to identify the preferred term. An observed edit can also finish when Enter clears the same editor. Marked text defers classification. The deadline is 75 seconds, the idle timeout is 15 seconds and stable edits normally settle for 1.6 seconds. A new recording cancels the previous session. A late result must pass the live session and destination checks before it can write. The passive Enter observer is removed on exit.

Learned spellings enter the next Whisper spelling guide and polish reference. Newer preferences have priority in the Whisper prompt budget. The notification's Undo and the **Learned** dictionary tab remove a specific learned record. Hand-authored and legacy imported replacements retain their previous behavior. Entries explicitly tagged as auto-learned in the old format migrate to spelling preferences.

## Same-audio acceptance

Each comparison used the same synthetic WAV before and after the real user edit. The app started with an empty temporary dictionary. The configured-service controls used the machine's full TypeFish service configuration, including its polish prompt.

| Real destination | First raw / pasted | User edit and saved preference | Next raw / pasted |
| --- | --- | --- | --- |
| TextEdit | `cloud code` / `cloud code` | `Claude Code` | `Claude Code` / `Claude Code` |
| TextEdit | `张明` / `张明` | `张铭` | `张铭` / `张铭` |
| TextEdit, Chrome textarea, Codex unsent draft | `Sochiel` / `Sochiel` | `Xochitl` | `Xochitl` / `Xochitl` |

After learning **Claude Code**, an independent control WAV produced **Google Cloud** in both the raw transcript and the pasted text. With **Xochitl** saved, clicking the real notification's Undo, quitting the QA app, restarting and replaying the original waveform returned **Sochiel**. Each of the three editors passed that sequence.

## Verified input surfaces

| Destination | Positive evidence | Negative cases and boundaries |
| --- | --- | --- |
| TextEdit 1.20 | Empty and existing documents, keyboard edits, mouse double-click selection, changed second occurrence, Return retaining a newline. Pinyin provisional text remained unlearned. Committing `张敏 → 张明` with Space learned `张明` while Pinyin was still selected. | Append, unrelated rewrite, native editor Undo, edit to the earlier duplicate and a second dictation starting before settlement all left the dictionary empty. |
| Chrome 157.0.8103.79 | Empty textarea, mouse-selected word, duplicate in a draft, retained Return and a locally handled Enter that clears the input. A corrected draft that cleared on Enter learned the name and used it on the next WAV. A separate foreground XCTest exercised a real contenteditable with a prefix and suffix. | Append, rewrite, editor Undo, changed older duplicate, rapid second dictation, moving the caret outside the inserted span, switching fields and unchanged Enter-clear produced no learned terms. GUI acceptance used an isolated profile with renderer accessibility enabled. A separate cold-profile check failed to establish a readable focused fixture. |
| Codex 26.1120.50957 (`com.openai.codex`) | Existing unsent draft, genuinely empty composer, corrected second duplicate and subsequent reuse. Mouse double-click selection and replacement also saved Xochitl. The mouse-specific replay lost foreground focus. The independent keyboard run verified the next dictation in Codex. | Append, rewrite, editor Undo, rapid second dictation and edits outside the inserted occurrence produced no entries. Plain Enter was intentionally omitted to keep the draft unsent. The local browser form exercised the equivalent clearing behavior without delivering a message. |

The distinct keyboard, duplicate, Enter, focus and rapid-recording cases comprise **24 real cases**. All six positives saved the intended term and used it on the next replay. All 18 negatives left the spelling dictionary empty. The mouse, blank-field, IME, migration and restart checks are additional. Trace rows contain only the inserted slice and the observation. The controlled drafts' surrounding synthetic prefix and suffix remained outside the candidate.

TextEdit exposes `AXTextInputMarkedRange`. In a real Pinyin test its range length was six during the composition of `ni hao` and zero after committing `你好`. The Chrome and Codex test editors did not provide a verifiable marked range. Both deferred learning while Pinyin was active, including after a visible commit. Switching back to direct input allowed the Codex sample to learn. The Chrome run did not save a term. Other editor builds, other input methods and other macOS releases are unverified.

Spelling guidance can be outweighed by the recording. For example, audio spoken as `张敏` still yielded `张敏` after a user edited it to the differently pronounced `张明`. The separate same-pronunciation `张明 → 张铭` case passed through the entire pipeline. An unavailable classifier or an explicit rejection produces no new preference.

## Timing and test boundaries

| Measurement | Samples | Median | p95 |
| --- | ---: | ---: | ---: |
| Original local paste to observable TextEdit content | 25 | 170.24 ms | 198.69 ms |
| Refactored local paste to observable TextEdit content | 25 | 14.59 ms | 16.00 ms |
| Whisper request and response | 106 | 359.5 ms | 499 ms |
| Polish request and response, including retries | 106 | 488.0 ms | 3673 ms |

Local measurements used the same Mac, synthetic TextEdit document shape, 25 inserted tokens, two discarded warm-ups and a monotonic clock. Each interval ended when the real text field exposed the token. The old code waited 150 ms to reactivate even an already-frontmost app. The new code avoids that wait and caps pre-paste Accessibility work at 25 ms. Service timings are separate wall-clock samples from the synthetic acceptance runs. They include service inference and, for some polish calls, a rate-limit retry.

The QA executable used the production Carbon hotkey callback, record finalization, requests, paste, monitor, classifier, dictionary and overlay. A file-backed recorder supplied identical audio in place of room sound. The QA shortcut was Option+J so the installed app could keep Option+Space. Most interaction-matrix runs used the configured service models and the app's built-in cleanup prompt. The dedicated configured controls also used the machine's customized cleanup prompt. No personal history or dictionary was copied into the test profile.

`TYPEFISH_RUN_E2E=1 swift test` ran 89 tests with zero failures. One optional historical microphone-truncation sample was absent. Its synthetic trimming regression passed. Regression tests used simulated delayed classification, cancellation, timeout during confirmation or classification, network failure, repeated observations, Undo during classification, background read failures and old callbacks after a new session. The final release passed strict code-signature verification, reached its ready state and registered hotkeys.

## Version 2.6.0 release verification

A clean release checkout ran 74 tests with desktop integration enabled. The TextEdit and Chrome contenteditable tests both verified the paste, the selected correction and the extracted text. One optional historical recording fixture was unavailable. The earlier 89-test run above included separate local microphone work.

In a foreground TextEdit fixture on this Mac, a synthetic Command-V posted at the hardware event tap could leave the editor unchanged. The release verifies the foreground process and posts the shortcut to the current login session. If the original app cannot regain focus, the dictated text is available on the clipboard. The release candidate also passed strict code-signature verification after extraction with the updater’s unzip tool.

## ChatGPT delivery and Notes learning in the 2.6.1 candidate

For the tested installation of ChatGPT for Mac, the application identifies itself as `com.openai.codex`. The candidate records the focused field when recording begins. If the renderer has not exposed an editable field yet, it requests Electron's accessibility tree while recording. When possible it invokes the application's standard Paste menu item. After an ambiguous menu response it checks the result without posting another paste. The Done indicator requires the expected text and caret in the original field, with the composer on screen. Unconfirmed dictation remains available in a Copy panel until dismissed or another recording starts. [Electron accessibility](https://www.electronjs.org/docs/latest/tutorial/accessibility/)

After confirming a paste, the learning monitor allows a two-second interruption in Accessibility reads if the original window is still active. A confirmed field or window change, an unsafe caret, or a changed insertion boundary still ends the session. Unit tests cover recovery, expiry, and a fresh field check before saving. A service integration test with a temporary dictionary replayed identical synthetic Mandarin audio and obtained the corrected full name in both the raw transcription and polished output.

The release-mode candidate has independent regression and service coverage. Foreground acceptance on the reported Mac ChatGPT and Apple Notes windows requires an unlocked desktop.
