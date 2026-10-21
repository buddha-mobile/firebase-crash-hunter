# Firebase Crash Hunter

> An AI agent that queries Firebase Crashlytics via BigQuery, diagnoses crashes in your codebase, and opens draft PRs on GitHub — automatically.

Trigger with one command: `/crash-hunter` in Claude Code, or `bash crash_hunter.sh` in your terminal.

---

## Quick Start

```bash
# 1. Copy files into your repo
mkdir -p .claude/scripts .claude/commands
cp crash_hunter.sh     .claude/scripts/
cp crash-hunter.md     .claude/commands/
cp .crash-hunter.example .crash-hunter   # then edit it

# 2. Configure (edit .crash-hunter)
FIREBASE_PROJECT_ID=my-firebase-project
ANDROID_PACKAGE_NAME=com.example.myapp

# 3. Add to .gitignore
echo ".crash-hunter" >> .gitignore
echo ".claude/scripts/crash_hunter.log" >> .gitignore

# 4. Make executable
chmod +x .claude/scripts/crash_hunter.sh

# 5. Run
bash .claude/scripts/crash_hunter.sh
# or from Claude Code:
# /crash-hunter
```

---

## Prerequisites

| Tool | Install | Purpose |
|---|---|---|
| Claude Code CLI | `npm i -g @anthropic-ai/claude-code` | Analyzes crashes and writes fixes |
| Google Cloud SDK | `brew install --cask google-cloud-sdk` | Queries BigQuery |
| GitHub CLI | `brew install gh` | Creates draft PRs |
| Firebase project | — | Source of crash data |
| BigQuery export | Firebase Console → Integrations → BigQuery | Streams crashes to SQL |

### Authentication

```bash
# Google Cloud (BigQuery)
gcloud init
gcloud auth application-default login
gcloud auth application-default set-quota-project YOUR_PROJECT_ID

# GitHub
gh auth login
```

---

## Usage

```bash
bash crash_hunter.sh          # last 24h
bash crash_hunter.sh 7        # last 7 days
bash crash_hunter.sh --test   # synthetic crash, no BigQuery needed
```

Or from Claude Code chat:
```
/crash-hunter        → last 24h
/crash-hunter 7      → last 7 days
```

---

## What it fixes

**HIGH confidence (auto-PR):**
- `NullPointerException` caused by `!!` in Kotlin code
- `String.toInt()` / `toLong()` on non-numeric input
- `Uri.parse()` without try-catch
- `Json.decodeFromString` without try-catch
- `popBackStack()` called eagerly or without back stack check
- Serialized enum missing `UNKNOWN` fallback

**LOW confidence (skipped):**
- Logic bugs, OOM, native crashes, system library crashes, architecture issues

---

## CLAUDE.md (optional but recommended)

If your repo has a `CLAUDE.md` with coding rules, the agent reads it before touching any code. If not, universal Kotlin/Android rules are used automatically.

---

## Files

```
.claude/
├── scripts/
│   └── crash_hunter.sh   ← main agent script
└── commands/
    └── crash-hunter.md   ← Claude Code slash command
.crash-hunter             ← your config (gitignored)
```

---

## License

MIT
