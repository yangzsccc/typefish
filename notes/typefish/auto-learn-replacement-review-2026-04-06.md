# Auto-Learned Replacement Quality Review

**Date:** 2026-04-06
**Scope:** EditTracker.swift, Dictionary.swift, production logs & dictionary

---

## Executive Summary

TypeFish's auto-learn feature (EditTracker) has **five systemic failure modes** that produce garbage dictionary entries in production. The root causes are:

1. **A fundamentally broken character-level diff** that produces reversed/garbled text fed to the LLM
2. **Clipboard fallback comparing completely unrelated texts** (treats any clipboard change as a user correction)
3. **No verification that LLM-proposed "wrong" words exist in the original STT output**
4. **No phonetic similarity validation** — the system blindly trusts LLM output
5. **Dangerous replacement keys** — short/common words that match inside unrelated text during `applyReplacements`

The result: 60-70% of auto-learned entries in the production dictionary are invalid. Some are actively harmful (e.g., `替換 → re` will corrupt any Chinese text containing 替換; `Claw → CL` breaks the user's own product name).

---

## Evidence

### E1: Garbled Diff Text Sent to LLM

**File:** `EditTracker.swift:294-318` — `computeDiff()`

The function uses Swift's `CollectionDifference` which operates character-by-character. When characters are removed from position N and inserted at position M, joining all removed characters produces **reversed/jumbled gibberish**, not meaningful word-level diffs.

**Production evidence** (app-2026-04-04.log):
```
focused diff prompt: [？制限的wCneO跑于对ciporhtnA过绕样怎] → [还是想 n来跑。]
```
- `ciporhtnA` = "Anthropic" backwards
- `wCneO` = garbled "OpenC"
- The entire "removed" string is the original Chinese text characters in approximately reverse order

The LLM then "corrects" these reversed strings, creating entries like:
- `ciporhtnA → Anthropic` (will never appear in real STT)
- `cneO → Open` (will never appear in real STT)

### E2: Clipboard Fallback Comparing Unrelated Texts

**File:** `EditTracker.swift:99-118` — `checkClipboardFallback()`

The clipboard fallback triggers when:
1. AX API failed on the previous paste (common — see E5)
2. The current clipboard content differs from the last pasted text
3. The difference passes the loose `isLargeModification` check

**Problem:** Any clipboard change within 60 seconds is treated as "the user corrected the STT output." In reality, the user simply copied different text for a different purpose.

**Production evidence** (auto-corrections.jsonl, 2026-04-05):
```json
{
  "original_pasted": "Let's do better cost control here. It reduces the O3 usage and gives me a better plan.",
  "edited_field": "Also, I have set up the codecs OAuth for you, making sure that you're using OAuth instead of API.",
  "corrections": [{"wrong":"O3","right":"OAuth"}, {"wrong":"Let's","right":"Also"}]
}
```
These are two completely unrelated sentences. The LLM invented phonetic relationships that don't exist.

### E3: No Verification of "Wrong" Word in Original Text

**File:** `EditTracker.swift:486-509` — correction application

After `parseCorrections()` returns pairs, the code directly calls `addReplacement()` without checking if the "wrong" word actually appears in the original pasted text. The LLM is free to hallucinate any word pair.

**Production evidence** (auto-corrections.jsonl, 2026-03-31):
```json
{
  "original_pasted": "根据这个codebase，有什么能够benefit到我在Amazon日常工作的insight？",
  "corrections": [
    {"wrong":"tifeneb够能么什有","right":"面临任务"},
    {"wrong":"esabedoc个这据根","right":"不只包括cod"}
  ]
}
```
- `tifeneb够能么什有` = garbled reversed characters — never in the original text
- The LLM hallucinated corrections from garbled diff input

### E4: Dangerous Short/Common Replacement Keys

**File:** `Dictionary.swift:167-180` — `applyReplacements()`

Current production dictionary contains:
| Wrong | Right | Risk |
|-------|-------|------|
| `替换` | `re` | Corrupts any Chinese text containing "替换" (= "replace", very common) |
| `把这` | `prompt` | Corrupts "把这" (= "take this", very common Chinese phrase) |
| `Claw` | `CL` | Breaks the user's own product name OpenClaw |
| `Let's` | `Also` | Replaces all occurrences of "Let's" in English text |
| `O3` | `OAuth` | Replaces legitimate "O3" references |
| `充实我的银行` | `充实我的bank` | Pointless Chinglish — not a phonetic error |
| `[并且]` | `[好的]` | Bracket-wrapped text — likely LLM prompt artifacts |
| `[overlay]` | `[prompt]` | Same — prompt artifacts |
| `[replacement]` | `[guidance]` | Same — prompt artifacts |

`applyReplacements()` uses `replacingOccurrences(of:)` — a global substring match with no word boundary awareness. Short keys like `O3` or `Claw` will match inside longer words.

### E5: AX API Almost Always Fails

**Production evidence** (app-2026-04-04.log, app-2026-04-05.log):
- Every single EditTracker session logs `cannot read field content`
- Zero successful AX reads across 2 full days of logs
- This means the **only** working path is the clipboard fallback — which is the most error-prone path (E2)

The likely cause: the user primarily uses Electron apps (Discord, Slack, VS Code, browsers) where AX text reading doesn't work.

### E6: Duplicate Corrections in Same Batch

**File:** `EditTracker.swift:476-509`

The LLM sometimes returns the same correction multiple times (e.g., `O3 → OAuth` appears 3 times, `cneO → Open` appears twice). The code calls `addReplacement` for each without deduplication, causing unnecessary saves and confusing undo behavior.

---

## Root Causes

### RC1: `computeDiff()` is fundamentally wrong for word-level comparison (CRITICAL)

`CollectionDifference` on `String` produces character-level edit operations. Joining removed characters gives garbled text because characters from different positions in the string are concatenated out of order. This is not a bug in the algorithm — it's a category error. Character-level diff is the wrong tool for identifying word-level STT corrections.

**Impact:** Garbled diff text → LLM hallucination → garbage corrections
**Evidence:** E1, E3

### RC2: Clipboard fallback has no semantic similarity gate (CRITICAL)

The clipboard is a shared system resource. Any `Cmd+C` the user performs within 60 seconds replaces the clipboard content and triggers the fallback. The `isLargeModification` check (50% size / 2x ratio) is too loose — it passes when the two texts are completely unrelated but happen to be similar in length.

**Impact:** Unrelated text pairs → LLM forced to find patterns in noise → garbage corrections
**Evidence:** E2

### RC3: No post-LLM validation against source text (HIGH)

The system trusts the LLM output completely. It doesn't verify:
- That the "wrong" word exists in the original pasted text
- That the "right" word exists in the edited text
- That the "wrong" and "right" words are phonetically similar

**Impact:** LLM hallucinations pass straight through to the dictionary
**Evidence:** E3, E4

### RC4: No word-boundary awareness in replacement application (MEDIUM)

`applyReplacements()` uses `replacingOccurrences(of:with:)` which is a substring match. A replacement like `O3 → OAuth` will match inside "O365" or "CO3".

**Impact:** Correct text gets corrupted by over-eager replacement
**Evidence:** E4

### RC5: Validation heuristics are necessary but insufficient (MEDIUM)

`isValidCorrection()` has good heuristics (length ratio, noise words, functional words, arrow chars) but misses:
- Reversed/garbled strings (RC1)
- Common words that shouldn't be replacement keys (e.g., "Let's", "把这")
- Bracket-wrapped text
- No check against the source text

**Impact:** Many invalid corrections pass validation
**Evidence:** E4

---

## Benchmark / Best-Practice Comparison

### Typeless Pattern (Reverse-Engineered)

Based on the EditTracker docstring and the Typeless reference:
1. **Server-side phonetic analysis** — Typeless sends edits to their server which does phonetic matching (pinyin similarity, IPA distance), not LLM-based guessing
2. **Word-level alignment** — compares word-by-word, not character-by-character
3. **Confidence scoring** — only accepts corrections above a phonetic similarity threshold
4. **User confirmation** — shows corrections and lets user accept/reject before adding to dictionary

### Best Practices for STT Correction Learning

1. **Word-level diff, not character-level:** Use word tokenization (splitting on spaces/punctuation, with CJK character segmentation) then `CollectionDifference` on word arrays
2. **Phonetic similarity gate:** Compare pinyin (for Chinese) or phonetic encoding (Soundex/Metaphone for English) before accepting a correction
3. **Source verification:** The "wrong" word MUST appear in the original STT output; the "right" word MUST appear in the corrected text
4. **Minimum edit confidence:** Only learn from small, targeted edits (1-3 word changes) — not wholesale text rewrites
5. **Replacement key safety:** Reject replacement keys that are common words (frequency > threshold) or shorter than 3 characters
6. **Word-boundary replacement:** Use regex word boundaries or exact-match-only mode instead of substring replacement

---

## Solution Plan

### P0: Immediate Safeguards (prevent further damage)

#### P0.1: Add source-text verification to parseCorrections output

**What:** After LLM returns corrections, verify each "wrong" word exists in `pastedText` and each "right" word exists (or is a plausible substring of) `editedFieldContent`.

**Where:** `EditTracker.swift`, new function + call site at line ~486

```swift
/// Verify correction against source texts
private func verifyCorrection(wrong: String, right: String, 
                               original: String, edited: String) -> Bool {
    // "wrong" must appear in original STT output
    guard original.contains(wrong) else {
        Log.info("📝 EditTracker: rejected (not in original): \(wrong)")
        return false
    }
    // "right" must appear in edited text
    guard edited.contains(right) else {
        Log.info("📝 EditTracker: rejected (not in edited): \(right)")
        return false
    }
    return true
}
```

Call at line ~488:
```swift
for (wrong, right) in corrections {
    guard verifyCorrection(wrong: wrong, right: right,
                           original: pastedText, edited: cappedField) else { continue }
    appState.dictionary.addReplacement(wrong: wrong, right: right)
}
```

**Impact:** Eliminates all garbled/reversed text corrections (RC1, RC3). Single biggest quality improvement.
**Risk:** Low — pure additive validation, no behavior change for correct corrections.
**Complexity:** ~20 lines of code.
**Verification:** Run with existing auto-corrections.jsonl — replay each entry and confirm invalid ones are rejected.

#### P0.2: Disable clipboard fallback (or add strong similarity gate)

**What:** Remove `checkClipboardFallback()` call, or gate it with a high Jaccard word-similarity threshold (>0.5).

**Where:** `EditTracker.swift:59` — comment out or gate the call

Option A (disable):
```swift
// checkClipboardFallback(apiKey: apiKey, appState: appState)
```

Option B (gate with word overlap):
```swift
private func hasSignificantOverlap(_ a: String, _ b: String) -> Bool {
    let wordsA = Set(a.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
    let wordsB = Set(b.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
    guard !wordsA.isEmpty, !wordsB.isEmpty else { return false }
    let intersection = wordsA.intersection(wordsB).count
    let union = wordsA.union(wordsB).count
    return Double(intersection) / Double(union) > 0.4
}
```

**Impact:** Eliminates the #1 source of unrelated-text comparisons (RC2).
**Risk:** Low (Option A) / Medium (Option B — needs tuning). AX API rarely works anyway, so clipboard fallback is the main path, but it produces more harm than good.
**Complexity:** 1 line (A) or ~15 lines (B).
**Verification:** Check that `Let's → Also` and `O3 → OAuth` type entries stop appearing.

#### P0.3: Add replacement key blocklist / minimum length

**What:** In `isValidCorrection()`, reject:
- Replacement keys < 3 characters (for non-CJK) or < 2 characters (for CJK)
- Common English words (the, is, a, let's, also, etc.)
- Bracket-wrapped text like `[foo]`

**Where:** `EditTracker.swift:555-609` — extend `isValidCorrection()`

```swift
// Reject bracket-wrapped text
if wrong.hasPrefix("[") && wrong.hasSuffix("]") { return false }
if right.hasPrefix("[") && right.hasSuffix("]") { return false }

// Reject if wrong is a common English word
let commonWords: Set<String> = ["let's", "also", "the", "is", "are", "was", "were", 
    "have", "has", "had", "this", "that", "will", "would", "could", "should"]
if commonWords.contains(wrong.lowercased()) { return false }
```

**Impact:** Prevents common-word replacement keys from entering dictionary.
**Risk:** Low — conservative blocklist.
**Complexity:** ~10 lines.
**Verification:** Replay auto-corrections.jsonl; confirm `Let's`, `[overlay]`, `[并且]` are rejected.

#### P0.4: Clean existing garbage from dictionary

**What:** Extend `sanitizeReplacements()` to remove the known-bad entries currently in production.

**Where:** `Dictionary.swift:69-113`

Add checks for:
- Reversed text (contains `ciporhtnA`, `cneO`, etc.)
- Bracket-wrapped keys/values
- Common-word keys
- Keys that are substrings of the user's own hints/vocabulary

**Impact:** Immediate quality improvement for existing users.
**Risk:** Low — only removes clearly invalid entries.
**Complexity:** ~20 lines.
**Verification:** Load dictionary, count entries before/after, verify no legitimate entries removed.

#### P0.5: Deduplicate corrections before applying

**What:** Before the `for (wrong, right) in corrections` loop, deduplicate by `wrong` key.

**Where:** `EditTracker.swift:486`

```swift
let uniqueCorrections = Dictionary(corrections.map { ($0.0, $0.1) }, 
    uniquingKeysWith: { first, _ in first })
let deduped = Array(uniqueCorrections).map { ($0.key, $0.value) }
```

**Impact:** Prevents duplicate log entries and redundant saves.
**Risk:** Very low.
**Complexity:** 3 lines.

### P1: Architectural Improvements

#### P1.1: Replace character-level diff with word-level diff

**What:** Rewrite `computeDiff()` to operate on word/token arrays instead of individual characters. For CJK text, segment by character (each CJK char is a "word"). For Latin text, split on whitespace/punctuation.

**Where:** `EditTracker.swift:294-318`

```swift
private func computeWordDiff(original: String, edited: String) -> [(removed: String, inserted: String)] {
    let origTokens = tokenize(original)
    let editTokens = tokenize(edited)
    let diff = editTokens.difference(from: origTokens)
    
    // Group consecutive removals/insertions into word-level changes
    // ... (word-level grouping logic)
}

private func tokenize(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    for char in text {
        if char.unicodeScalars.allSatisfy({ $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
            if !current.isEmpty { tokens.append(current); current = "" }
            tokens.append(String(char))
        } else if char.isWhitespace || char.isPunctuation {
            if !current.isEmpty { tokens.append(current); current = "" }
        } else {
            current.append(char)
        }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
}
```

**Impact:** Eliminates garbled diff text entirely (RC1). Produces meaningful word-level diffs for the LLM.
**Risk:** Medium — needs thorough testing with CJK/English/mixed text.
**Complexity:** ~50 lines.
**Verification:** Unit test with known good/bad pairs from auto-corrections.jsonl.

#### P1.2: Add phonetic similarity validation

**What:** Before accepting a correction, compute phonetic similarity:
- For Chinese: convert both to pinyin, compare
- For English: use Soundex or Levenshtein on lowercase

Reject if similarity is below threshold (e.g., 0.3 for pinyin, Soundex match for English).

**Where:** New file `PhoneticValidator.swift` or extend `EditTracker.swift`

**Impact:** Directly addresses the core design gap — the system currently has zero phonetic validation (RC3).
**Risk:** Medium — pinyin library needed (or simple lookup table), false-reject rate needs tuning.
**Complexity:** ~80-120 lines for a basic implementation.
**Verification:** Test against known phonetic pairs (面金→面经, 索奎→suki) and known non-phonetic pairs (Let's→Also, 把这→prompt).

#### P1.3: Add word-boundary-aware replacement

**What:** Replace `replacingOccurrences(of:with:)` with word-boundary-aware matching. For CJK, exact character-sequence match is acceptable. For Latin text, use `\b` word boundaries.

**Where:** `Dictionary.swift:167-180`

```swift
func applyReplacements(_ text: String) -> String {
    guard !replacements.isEmpty else { return text }
    var result = text
    let sorted = replacements.sorted { $0.key.count > $1.key.count }
    for (wrong, right) in sorted {
        let isCJK = wrong.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
        if isCJK {
            result = result.replacingOccurrences(of: wrong, with: right)
        } else {
            // Word-boundary match for Latin text
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: wrong))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                result = regex.stringByReplacingMatches(in: result, 
                    range: NSRange(result.startIndex..., in: result), withTemplate: right)
            }
        }
    }
    return result
}
```

**Impact:** Prevents short Latin replacement keys from matching inside longer words (RC4).
**Risk:** Low-medium — regex has edge cases with mixed scripts.
**Complexity:** ~20 lines.
**Verification:** Test `O3` doesn't match inside "O365"; `Claw` doesn't match inside "OpenClaw".

#### P1.4: Rethink the AX-fail → clipboard fallback chain

**What:** Since AX API fails ~100% of the time for this user's apps, the entire tracking mechanism is effectively clipboard-only. Design a more reliable comparison:
- After paste, snapshot the clipboard content
- On next recording trigger (not arbitrary clipboard change), compare if the user corrected the text in-place
- Or: use AX focused-element monitoring with a broader set of element types

**Impact:** Addresses the fundamental architectural issue that the designed path (AX monitoring) never works.
**Risk:** High — significant redesign.
**Complexity:** ~100+ lines.
**Verification:** Integration testing with Discord, Slack, browser text fields.

### P2: UX & Observability Improvements

#### P2.1: Confidence scoring and user confirmation for low-confidence corrections

**What:** Instead of auto-adding every correction, assign a confidence score based on:
- Phonetic similarity (P1.2)
- Number of overlapping words between original and edited text
- Length of the correction

Low-confidence corrections (<0.7) should show a confirmation dialog instead of auto-adding.

**Impact:** Prevents user frustration from bad auto-learned entries.
**Risk:** Low — additive UX improvement.
**Complexity:** ~40 lines.

#### P2.2: Dictionary entry provenance and aging

**What:** Track when each replacement was added, how many times it's been applied, and whether it was auto-learned or manual. Auto-learned entries that have never been used after N days can be flagged for review or auto-removed.

**Impact:** Self-cleaning dictionary; easier debugging.
**Risk:** Low — requires dictionary schema change.
**Complexity:** ~60 lines.

#### P2.3: Enhanced logging with LLM input/output capture

**What:** Log the full LLM prompt and response in auto-corrections.jsonl for offline analysis.

**Impact:** Much easier debugging of future quality issues.
**Risk:** Very low.
**Complexity:** ~10 lines.

---

## Rollout & Metrics

### Rollout Order

1. **P0.1 + P0.3 + P0.5** (same release) — source verification + blocklist + dedup
2. **P0.2** (same or next release) — disable/gate clipboard fallback
3. **P0.4** (same release as P0.2) — clean existing garbage
4. **P1.1** (next minor) — word-level diff
5. **P1.3** (next minor) — word-boundary replacement
6. **P1.2** (next minor) — phonetic validation
7. **P2.x** (future) — confidence scoring, provenance, logging

### Success Metrics

| Metric | Current (estimated) | Target |
|--------|-------------------|--------|
| Invalid entries in dictionary | ~30/90 (33%) | <5% |
| Auto-corrections per day that survive manual review | ~30% | >85% |
| Reversed/garbled strings in corrections log | ~15% of entries | 0% |
| Common-word replacement keys | ~8 entries | 0 entries |
| User undo rate on auto-learn overlay | Unknown (not tracked) | <10% |

### Verification Methods

- **Replay test:** Feed existing auto-corrections.jsonl through updated validation pipeline, compare accept/reject decisions
- **Shadow mode:** Log what would be accepted/rejected without actually modifying dictionary, review after 1 week
- **Dictionary audit:** After each release, dump dictionary and manually review new entries

---

## Open Questions

1. **Should clipboard fallback be removed entirely or gated?** Given that AX API never works for this user's apps, removing it means zero auto-learning. Gating with word-overlap similarity is the middle ground, but needs tuning.

2. **Is LLM-based correction identification the right approach?** Typeless uses server-side phonetic analysis. A local pinyin/Soundex comparison would be more reliable and faster (no API call). The LLM could be replaced with a deterministic phonetic matcher for P1.2.

3. **Should auto-learned entries require N occurrences before becoming active?** A "staging area" where corrections must be confirmed by appearing 2-3 times independently would dramatically reduce false positives.

4. **CJK segmentation strategy:** For word-level diff (P1.1), should we use a proper segmentation library (e.g., CFStringTokenizer on macOS) or simple character-by-character for CJK?

5. **Replacement scope:** Should replacements be case-sensitive? Currently they are, leading to duplicate entries like `Chat GPT` and `chat GPT` both mapping to `ChatGPT`.

6. **Maximum dictionary size:** No limit exists. At current rate of garbage accumulation, the dictionary will grow unbounded. Should there be a cap with LRU eviction?

---

## Appendix: Production Bad Entries (Sampled)

From `~/.config/typefish/dictionary.json` as of 2026-04-06:

| Wrong | Right | Failure Mode | Root Cause |
|-------|-------|-------------|------------|
| `ciporhtnA` | `Anthropic` | Reversed string | RC1 (garbled diff) |
| `cneO` | `Open` | Reversed string | RC1 (garbled diff) |
| `Claw` | `CL` | Wrong correction | RC2 (unrelated texts) + RC3 (no verification) |
| `Let's` | `Also` | Common word replaced | RC2 (unrelated texts) |
| `O3` | `OAuth` | Common term replaced | RC2 (unrelated texts) |
| `替换` | `re` | Common Chinese word | RC2 + RC3 |
| `把这` | `prompt` | Common Chinese phrase | RC2 + RC3 |
| `[并且]` | `[好的]` | Bracket artifact | RC5 (validation gap) |
| `[overlay]` | `[prompt]` | Bracket artifact | RC5 (validation gap) |
| `[replacement]` | `[guidance]` | Bracket artifact | RC5 (validation gap) |
| `PowerDraft` | `帮我draft` | Mixed-language noise | RC2 + RC3 |
| `充实我的银行` | `充实我的bank` | Not phonetic | RC3 (LLM hallucination) |

Legitimate entries (for reference):
| Wrong | Right | Why Valid |
|-------|-------|-----------|
| `面金` | `面经` | Phonetic: miàn jīn → miàn jīng |
| `索奎` | `suki` | Phonetic: suǒ kuí → suki |
| `Chat GBT` | `ChatGPT` | STT spacing error |
| `Cooper Netties` | `Kubernetes` | Phonetic: English |
| `Superbased` | `Supabase` | Phonetic: English |
