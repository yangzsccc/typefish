# TypeFish — Voice-to-Text for macOS

> 按快捷键说话，松开后文字自动出现在光标处。轻润色，不改写。

## 项目位置
- **Local:** `/Users/shuchenzhao/typefish`
- **Owner:** Shuchen Zhao
- **PM/PgM:** Chewy 🐱
- **Channel:** Discord #typefish

---

## 🎯 Core Requirements

### 交互流程
1. 按一次全局快捷键（如 `Option+Space`）→ 开始录音，Menu bar 图标变红/有指示
2. 用户说话（任意时长）
3. 再按一次同样的快捷键 → 停止录音
4. 自动：音频 → Whisper 转录 → LLM 轻润色 → 粘贴到当前光标位置
5. 整个过程 < 3 秒（短句）

### 润色原则
- **保留原话**，不改写、不加修饰
- 只处理：结巴、重复、改口（保留最终意思）
- 保留用户的结构（说了分点就是分点）
- 不加标题、不变正式、不加 emoji
- 如果用户说的已经很清楚 → 原样输出，不画蛇添足

### 不做
- ❌ 隐身 / undetectable
- ❌ Speak to edit
- ❌ 翻译
- ❌ Per-app 语气切换
- ❌ 个性化学习
- ❌ iOS 版本（暂时）

---

## 🔧 Tech Stack

| 组件 | 选择 | 理由 |
|------|------|------|
| Language | Swift | macOS native，No-Clue 已验证 |
| UI | SwiftUI + AppKit | Menu bar app，极简 |
| 音频捕获 | AVAudioEngine | No-Clue 已验证，稳定 |
| STT | Groq Whisper API | 免费 tier，极快（<1s），准确 |
| 润色 LLM | Groq llama/mixtral 或 Claude Haiku | 轻润色不需要大模型，快+便宜 |
| 粘贴 | CGEvent (Cmd+V simulation) | 写入 pasteboard → 模拟粘贴 |
| 配置 | JSON 文件 | KISS |
| Build | Swift Package Manager | 和 No-Clue 一致 |

### API Keys 需要
- `GROQ_API_KEY` — Groq (Whisper + 可选 LLM)
- `ANTHROPIC_API_KEY` — Claude Haiku (可选，润色备选)

---

## 🏗️ Architecture

```
Sources/TypeFish/
├── main.swift              — AppDelegate, menu bar setup, startup
├── MenuBarController.swift — NSStatusItem, menu, recording indicator
├── AppState.swift          — Observable state, recording toggle, pipeline
├── HotkeyManager.swift     — CGEvent tap for global hotkey
├── AudioRecorder.swift     — AVAudioEngine, record to file
├── WhisperAPI.swift        — Groq Whisper transcription
├── TextPolisher.swift      — LLM light polish
├── PasteService.swift      — Pasteboard + CGEvent Cmd+V
├── Config.swift            — JSON config loading
└── Logger.swift            — Simple file logger
```

### Pipeline
```
[按快捷键] → 开始录音
     ↓
[再按快捷键] → 停止录音
     ↓
AudioRecorder → 保存为 m4a/wav
     ↓
WhisperAPI → raw transcript (string)
     ↓
TextPolisher → cleaned text (去结巴、去重复、保留原意)
     ↓
PasteService → 写入 pasteboard → 模拟 Cmd+V → 文字出现在光标处
```

---

## 📐 Config (config.json)

```json
{
  "hotkey": "Option+Space",
  "whisper": {
    "provider": "groq",
    "model": "whisper-large-v3",
    "language": "auto"
  },
  "polisher": {
    "provider": "groq",
    "model": "llama-3.3-70b-versatile",
    "systemPrompt": "You are a minimal text editor. Fix only: stutters, repetitions, and self-corrections. Keep the original wording and structure. Do not rewrite, do not add formality, do not add formatting. Output only the cleaned text, nothing else."
  },
  "audio": {
    "format": "m4a",
    "sampleRate": 16000
  }
}
```

---

## 🗺️ Phases

### Phase 1: Core Pipeline ← START HERE
- [ ] 1.1 项目初始化 (Swift Package, 基础结构)
- [ ] 1.2 Menu bar app (NSStatusItem, 图标)
- [ ] 1.3 Global hotkey (CGEvent tap, toggle 录音)
- [ ] 1.4 Audio recording (AVAudioEngine → m4a file)
- [ ] 1.5 Groq Whisper API 集成
- [ ] 1.6 Text polisher (Groq LLM)
- [ ] 1.7 Paste to cursor (pasteboard + Cmd+V)
- [ ] 1.8 End-to-end 测试

### Phase 2: Polish
- [ ] 2.1 录音时视觉反馈 (menu bar 图标变色/动画)
- [ ] 2.2 声音提示 (开始/结束录音 beep)
- [ ] 2.3 错误处理 (网络失败、API 错误)
- [ ] 2.4 Config 文件热加载
- [ ] 2.5 处理中状态指示

### Phase 3: Nice to Have
- [ ] 3.1 历史记录 (最近 N 条转录)
- [ ] 3.2 多语言自动检测
- [ ] 3.3 快捷键自定义 UI
- [ ] 3.4 Login item (开机自启)

---

## ⚡ Performance Targets
- 录音停止 → 文字粘贴：< 3 秒（30 秒内的语音）
- 内存占用：< 50MB
- CPU idle：< 1%

---

## 📝 Decision Log

| Date | Decision | Reason |
|------|----------|--------|
| 2026-02-27 | macOS only, no iOS | 先验证 core value |
| 2026-02-27 | Toggle mode (非 hold-to-talk) | Shuchen 偏好 |
| 2026-02-27 | Groq Whisper | 免费、极快 |
| 2026-02-27 | 轻润色不改写 | Shuchen 明确要求保留原话 |
| 2026-02-27 | Menu bar app (非 floating panel) | 不需要隐身，简洁即可 |
