#!/usr/bin/env python3
"""
Deep analysis of TypeFish vs Typeless comparison results.
Categorizes differences and identifies actionable improvement areas.
"""

import json
import re
from pathlib import Path
from collections import Counter

RESULTS_FILE = Path.home() / ".config/typefish/logs/comparison/results.jsonl"

def load_results():
    results = []
    for line in RESULTS_FILE.read_text().strip().split("\n"):
        if line.strip():
            try:
                results.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return results

def normalize(s):
    return re.sub(r'[\s，。、！？,.!?\n：:；;"""\'\(\)（）]+', '', s).lower()

def has_english(s):
    return bool(re.search(r'[a-zA-Z]{2,}', s))

def find_english_words(s):
    return re.findall(r'[a-zA-Z][a-zA-Z0-9_.\-]*[a-zA-Z0-9]|[a-zA-Z]', s)

def count_paragraphs(s):
    return len([p for p in s.split('\n') if p.strip()])

def count_sentences(s):
    return len(re.split(r'[。.！!？?\n]+', s))

def has_spaces_around_english(s):
    """Check if English words have spaces around them in Chinese context."""
    return bool(re.search(r'[\u4e00-\u9fff]\s+[a-zA-Z]|[a-zA-Z]\s+[\u4e00-\u9fff]', s))

def find_translated_words(whisper_raw, typeless):
    """Find English words in Typeless that got translated to Chinese in Whisper."""
    tl_eng = set(w.lower() for w in find_english_words(typeless))
    wr_eng = set(w.lower() for w in find_english_words(whisper_raw))
    # Words in Typeless but missing from Whisper raw = likely translated by Whisper
    return tl_eng - wr_eng

def analyze():
    results = load_results()
    total = len(results)
    
    # Categories
    exact_match = []
    punct_only = []  # Only punctuation/whitespace differences
    
    # Issue categories
    issues = {
        "TRANSLATE": [],       # Whisper translated English to Chinese
        "PARAGRAPH": [],       # Typeless has better paragraph breaks
        "SPACING": [],         # English word spacing differences
        "SEMANTIC_FIX": [],    # Typeless made smarter semantic corrections
        "WORD_CHOICE": [],     # Different word choices (not translation)
        "STRUCTURE": [],       # Sentence restructuring
        "HALLUCINATION": [],   # One side hallucinated/added content
        "TRUNCATION": [],      # Typeless shows partial/truncated at end
        "TYPEFISH_BETTER": [], # Cases where TypeFish is actually better
    }
    
    translated_words_all = Counter()
    
    for r in results:
        tl = r["typeless_output"].strip()
        tf = r["typefish_polished"].strip()
        wr = r["typefish_whisper_raw"].strip()
        
        if tl == tf:
            exact_match.append(r)
            continue
        
        if normalize(tl) == normalize(tf):
            punct_only.append(r)
            continue
        
        entry_issues = []
        
        # 1. Check for translated English words
        translated = find_translated_words(wr, tl)
        if translated:
            issues["TRANSLATE"].append(r)
            entry_issues.append("TRANSLATE")
            for w in translated:
                translated_words_all[w] += 1
        
        # 2. Check paragraph structure
        tl_paras = count_paragraphs(tl)
        tf_paras = count_paragraphs(tf)
        if tl_paras > tf_paras and tl_paras >= 2:
            issues["PARAGRAPH"].append(r)
            entry_issues.append("PARAGRAPH")
        
        # 3. Check spacing around English
        tl_spaced = has_spaces_around_english(tl)
        tf_spaced = has_spaces_around_english(tf)
        if tl_spaced and not tf_spaced:
            issues["SPACING"].append(r)
            entry_issues.append("SPACING")
        
        # 4. Semantic corrections (Typeless fixed obvious speech errors)
        # Heuristic: if Typeless text is meaningfully different from Whisper raw
        # in ways that improve meaning
        tl_norm = normalize(tl)
        wr_norm = normalize(wr)
        tf_norm = normalize(tf)
        
        # If typeless diverges more from whisper raw than typefish does,
        # it's doing more semantic processing
        tl_diff_ratio = len(set(tl_norm) ^ set(wr_norm)) / max(len(wr_norm), 1)
        tf_diff_ratio = len(set(tf_norm) ^ set(wr_norm)) / max(len(wr_norm), 1)
        if tl_diff_ratio > tf_diff_ratio * 1.5 and tl_diff_ratio > 0.05:
            issues["SEMANTIC_FIX"].append(r)
            entry_issues.append("SEMANTIC_FIX")
        
        # 5. Check if TypeFish added content not in original
        if len(tf) > len(wr) * 1.3 and len(tf) > len(tl) * 1.2:
            issues["HALLUCINATION"].append(r)
            entry_issues.append("HALLUCINATION")
        
        # 6. Check if Typeless truncated
        if tl.rstrip().endswith(("...", "…", "：", ":")):
            issues["TRUNCATION"].append(r)
            entry_issues.append("TRUNCATION")
        
        # If no specific issue found, classify as general structure difference
        if not entry_issues:
            issues["STRUCTURE"].append(r)
    
    # --- Print Report ---
    print("=" * 70)
    print("TypeFish vs Typeless — Deep Analysis")
    print("=" * 70)
    print(f"\nTotal: {total}")
    print(f"Exact match: {len(exact_match)} ({len(exact_match)*100//total}%)")
    print(f"Punctuation-only diff: {len(punct_only)} ({len(punct_only)*100//total}%)")
    print(f"Meaningful differences: {total - len(exact_match) - len(punct_only)} ({(total - len(exact_match) - len(punct_only))*100//total}%)")
    
    print("\n" + "=" * 70)
    print("ISSUE BREAKDOWN")
    print("=" * 70)
    
    for cat, entries in sorted(issues.items(), key=lambda x: -len(x[1])):
        if not entries:
            continue
        print(f"\n{'─' * 60}")
        print(f"📌 {cat}: {len(entries)} cases ({len(entries)*100//total}%)")
        print(f"{'─' * 60}")
        
        for e in entries[:3]:  # Show top 3 examples
            print(f"\n  [{e['id'][:8]}] ({e['duration']:.0f}s)")
            print(f"  Whisper: {e['typefish_whisper_raw'][:120]}")
            print(f"  TypeFish: {e['typefish_polished'][:120]}")
            print(f"  Typeless: {e['typeless_output'][:120]}")
    
    if translated_words_all:
        print(f"\n{'=' * 70}")
        print("TRANSLATED ENGLISH WORDS (Whisper → Chinese, Typeless kept English)")
        print("=" * 70)
        for word, count in translated_words_all.most_common(30):
            print(f"  {word}: {count}x")
    
    # --- Root Cause Analysis ---
    print(f"\n{'=' * 70}")
    print("ROOT CAUSE ANALYSIS")
    print("=" * 70)
    
    whisper_issues = len(issues["TRANSLATE"])
    polisher_issues = len(issues["PARAGRAPH"]) + len(issues["SPACING"]) + len(issues["STRUCTURE"])
    
    print(f"""
┌─────────────────────────────────────────────────────┐
│ Layer          │ Issues │ % of diffs │ Fixable?      │
├─────────────────────────────────────────────────────┤
│ Whisper STT    │ {whisper_issues:>5}  │ {whisper_issues*100//(total - len(exact_match) - len(punct_only)) if (total - len(exact_match) - len(punct_only)) > 0 else 0:>8}%  │ Prompt/model   │
│ Polisher LLM   │ {polisher_issues:>5}  │ {polisher_issues*100//(total - len(exact_match) - len(punct_only)) if (total - len(exact_match) - len(punct_only)) > 0 else 0:>8}%  │ Prompt tuning  │
│ Semantic/Other │ {len(issues['SEMANTIC_FIX']):>5}  │ {len(issues['SEMANTIC_FIX'])*100//(total - len(exact_match) - len(punct_only)) if (total - len(exact_match) - len(punct_only)) > 0 else 0:>8}%  │ Harder (model) │
└─────────────────────────────────────────────────────┘
""")

    # --- Actionable Recommendations ---
    print("=" * 70)
    print("ACTIONABLE IMPROVEMENTS (by impact)")
    print("=" * 70)
    
    recs = []
    
    if issues["TRANSLATE"]:
        recs.append({
            "priority": "P0",
            "layer": "Whisper",
            "issue": f"English words translated to Chinese ({len(issues['TRANSLATE'])} cases)",
            "fix": [
                "Add English vocabulary to Whisper prompt (hints section)",
                "Top translated words: " + ", ".join(w for w, _ in translated_words_all.most_common(10)),
                "Consider switching to whisper-large-v3 (better multilingual)",
                "Test: set whisperLanguage to null (auto-detect) vs 'zh'",
            ]
        })
    
    if issues["PARAGRAPH"]:
        recs.append({
            "priority": "P1",
            "layer": "Polisher",
            "issue": f"No paragraph breaks for long text ({len(issues['PARAGRAPH'])} cases)",
            "fix": [
                "Add polisher rule: 'For text longer than ~50 chars with distinct topics, add paragraph breaks (\\n\\n) between them'",
                "Typeless uses paragraph breaks at semantic boundaries — TypeFish outputs wall of text",
            ]
        })
    
    if issues["SPACING"]:
        recs.append({
            "priority": "P2",
            "layer": "Polisher",
            "issue": f"No spaces around English in Chinese ({len(issues['SPACING'])} cases)",
            "fix": [
                "Current prompt says 'Do NOT add spaces' — this contradicts readability",
                "Typeless adds spaces: '用 System Design' — more readable",
                "Consider changing rule to: 'Add a space before/after English words in Chinese text'",
                "⚠️ This was a previous evolution decision to NOT add spaces — need to reconsider",
            ]
        })
    
    for r in recs:
        print(f"\n{'🔴' if r['priority'] == 'P0' else '🟡' if r['priority'] == 'P1' else '🟢'} {r['priority']} [{r['layer']}] {r['issue']}")
        for f in r['fix']:
            print(f"    → {f}")
    
    print()
    return issues, translated_words_all

if __name__ == "__main__":
    analyze()
