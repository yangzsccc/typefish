#!/usr/bin/env python3
"""
Compare whisper-large-v3-turbo vs whisper-large-v3 on the same audio.
Focus on English word preservation in mixed Chinese-English speech.
"""

import json
import sys
import os
import time
import re
import requests
from pathlib import Path

RESULTS_FILE = Path.home() / ".config/typefish/logs/comparison/results.jsonl"
TYPELESS_DB = Path.home() / "Library/Application Support/Typeless/typeless.db"
GROQ_KEY_PATHS = [
    Path.home() / ".config/typefish/groq_key",
    Path.home() / ".config/noclue/groq_key",
]
DICT_PATH = Path.home() / ".config/typefish/dictionary.json"

MODELS = ["whisper-large-v3-turbo", "whisper-large-v3"]


def get_api_key():
    for p in GROQ_KEY_PATHS:
        if p.exists():
            return p.read_text().strip()
    return os.environ.get("GROQ_API_KEY")


def get_whisper_prompt():
    if DICT_PATH.exists():
        d = json.loads(DICT_PATH.read_text())
        hints = d.get("hints", [])
        prefix = "Spelling guide: "
        prompt = prefix + ", ".join(hints)
        return prompt[:896]
    return None


def transcribe(audio_path, api_key, model, prompt=None):
    with open(audio_path, "rb") as f:
        data = {"model": model, "response_format": "text"}
        if prompt:
            data["prompt"] = prompt
        resp = requests.post(
            "https://api.groq.com/openai/v1/audio/transcriptions",
            headers={"Authorization": f"Bearer {api_key}"},
            files={"file": (Path(audio_path).name, f, "audio/ogg")},
            data=data,
            timeout=30,
        )
    if resp.status_code == 429:
        wait = int(resp.headers.get("retry-after", "10"))
        print(f"  ⏳ Rate limited, waiting {wait}s...")
        time.sleep(wait)
        return transcribe(audio_path, api_key, model, prompt)
    if resp.status_code != 200:
        print(f"  ❌ {resp.status_code}: {resp.text[:100]}")
        return None
    return resp.text.strip()


def main():
    api_key = get_api_key()
    prompt = get_whisper_prompt()

    # Load old results and find entries where English was likely translated
    import sqlite3
    conn = sqlite3.connect(str(TYPELESS_DB))
    conn.row_factory = sqlite3.Row

    old_results = {}
    for line in RESULTS_FILE.read_text().strip().split("\n"):
        if line.strip():
            r = json.loads(line)
            old_results[r["id"]] = r

    # Pick entries where Typeless had English words that Whisper missed
    interesting = []
    for r in old_results.values():
        tl = r["typeless_output"]
        wr = r["typefish_whisper_raw"]
        tl_eng = set(w.lower() for w in re.findall(r'[a-zA-Z]{2,}', tl))
        wr_eng = set(w.lower() for w in re.findall(r'[a-zA-Z]{2,}', wr))
        missing = tl_eng - wr_eng
        if missing and len(missing) >= 1:
            interesting.append((r, missing))

    interesting.sort(key=lambda x: -len(x[1]))
    interesting = interesting[:15]

    print(f"📊 Testing {len(interesting)} entries with English word translation issues\n")

    for i, (r, missing_words) in enumerate(interesting):
        eid = r["id"]
        cur = conn.cursor()
        cur.execute("SELECT audio_local_path FROM history WHERE id = ?", (eid,))
        row = cur.fetchone()
        if not row or not Path(row["audio_local_path"]).exists():
            continue

        audio = row["audio_local_path"]
        print(f"[{i+1}/{len(interesting)}] {eid[:8]} — missing: {missing_words}")
        print(f"  Typeless: {r['typeless_output'][:100]}")

        for model in MODELS:
            result = transcribe(audio, api_key, model, prompt)
            if result:
                # Check English preservation
                result_eng = set(w.lower() for w in re.findall(r'[a-zA-Z]{2,}', result))
                recovered = missing_words & result_eng
                tag = f"✅ +{len(recovered)}" if recovered else "❌"
                print(f"  {model:30s}: {result[:100]}  {tag} {recovered if recovered else ''}")
            time.sleep(1.5)  # Rate limit between calls

        print()

    conn.close()


if __name__ == "__main__":
    main()
