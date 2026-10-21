#!/bin/bash
# Firebase Crashlytics Auto-Fix Agent — KMP Edition (Android + iOS)
# Queries BigQuery for top crashes on both platforms, invokes Claude Code to
# analyze each one, and raises DRAFT PRs for crashes it can fix with HIGH confidence.
set -euo pipefail

# ── Paths ──────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_FILE="$SCRIPT_DIR/crash_hunter.log"
CLAUDE_BIN="/Users/buddhabhushanbuktare/.nvm/versions/node/v20.20.0/bin/claude"

PROJECT_ID="bachattcustomerapp"
DATASET="firebase_crashlytics"
ANDROID_TABLE="app_bachatt_customer_ANDROID"
IOS_TABLE="app_bachatt_customer_IOS"

# ── Args ───────────────────────────────────────────────────────────────────
# bash crash_hunter.sh          → last 1 day
# bash crash_hunter.sh 7        → last 7 days
# bash crash_hunter.sh --test   → synthetic KMP crash, skips BigQuery
INTERVAL_DAYS=${1:-1}
TEST_MODE=false
[ "${1:-}" = "--test" ] && TEST_MODE=true && INTERVAL_DAYS=1

# ── Logging ────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

log "════════════════════════════════════════════"
log "  Firebase Crash Hunter — KMP Edition"
log "  $(date '+%Y-%m-%d') · window: ${INTERVAL_DAYS}d"
log "════════════════════════════════════════════"

# ── Sanity checks ──────────────────────────────────────────────────────────
for bin in bq python3 git gh "$CLAUDE_BIN"; do
  if ! command -v "$bin" &>/dev/null && [ ! -x "$bin" ]; then
    log "ERROR: Required binary not found: $bin"; exit 1
  fi
done

# ── Git safety ─────────────────────────────────────────────────────────────
cd "$REPO_ROOT"
git fetch origin master --quiet 2>/dev/null || true
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "master" ]; then
  log "Not on master (on '$CURRENT_BRANCH'). Switching..."
  git checkout master --quiet
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
  log "Uncommitted changes — stashing..."
  git stash push -m "crash-hunter-auto-stash-$(date +%Y%m%d_%H%M%S)" --quiet
  STASHED=true
else
  STASHED=false
fi

# ── Build BigQuery query ───────────────────────────────────────────────────
# Returns the per-platform SELECT block with a literal platform tag injected.
# $1 = fully-qualified table name, $2 = platform string ('android' or 'ios')
bq_select() {
  local table="$1" platform="$2"
  cat <<SQL
  SELECT
    issue_id,
    issue_title,
    issue_subtitle,
    is_fatal,
    '$platform'                                               AS platform,
    ANY_VALUE(blame_frame.file)                               AS blamed_file,
    ANY_VALUE(blame_frame.symbol)                             AS blamed_symbol,
    ANY_VALUE(CAST(blame_frame.line AS STRING))               AS blamed_line,
    ANY_VALUE(blame_frame.library)                            AS blamed_library,
    ANY_VALUE(exceptions[SAFE_OFFSET(0)].type)                AS exception_type,
    ANY_VALUE(exceptions[SAFE_OFFSET(0)].exception_message)   AS exception_message,
    ANY_VALUE(ARRAY(
      SELECT AS STRUCT
        frame.file        AS file,
        frame.symbol      AS symbol,
        CAST(frame.line AS STRING) AS line,
        frame.library     AS library,
        frame.owner       AS owner,
        CAST(frame.blamed AS STRING) AS blamed
      FROM UNNEST(exceptions[SAFE_OFFSET(0)].frames) AS frame
      WHERE frame.owner = 'DEVELOPER'
        OR REGEXP_CONTAINS(IFNULL(frame.symbol,''), r'^kfun:')
      LIMIT 15
    )) AS developer_frames,
    COUNT(*)                                                  AS crash_count,
    FORMAT_TIMESTAMP('%Y-%m-%d %H:%M UTC', MAX(event_timestamp)) AS last_seen,
    ANY_VALUE(application.display_version)                    AS app_version
  FROM \`$PROJECT_ID.$DATASET.$table\`
  WHERE event_timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL ${INTERVAL_DAYS} DAY)
  GROUP BY issue_id, issue_title, issue_subtitle, is_fatal
SQL
}

# ── Fetch crashes ──────────────────────────────────────────────────────────
ANDROID_FILE="/tmp/bch_android_$(date +%Y%m%d_%H%M%S).json"
IOS_FILE="/tmp/bch_ios_$(date +%Y%m%d_%H%M%S).json"
CRASHES_FILE="/tmp/bch_combined_$(date +%Y%m%d_%H%M%S).json"

if [ "$TEST_MODE" = "true" ]; then
  log "TEST MODE — injecting synthetic KMP crash payload..."
  # Simulate the same commonMain bug showing on both platforms
  cat > "$CRASHES_FILE" << 'TESTEOF'
[
  {
    "platform": "android",
    "issue_id": "test_android_repayment01",
    "issue_title": "NullPointerException in RepaymentScreen",
    "issue_subtitle": "RepaymentScreen.kt line 140",
    "is_fatal": "true",
    "blamed_file": "RepaymentScreen.kt",
    "blamed_symbol": "RepaymentScreenKt.RepaymentContent",
    "blamed_line": "140",
    "blamed_library": "app.bachatt.customer",
    "exception_type": "java.lang.NullPointerException",
    "exception_message": "selectedOption was null",
    "developer_frames": [
      {"file": "RepaymentScreen.kt", "symbol": "RepaymentScreenKt.RepaymentContent", "line": "140", "library": "app.bachatt.customer", "owner": "DEVELOPER", "blamed": "true"},
      {"file": "RepaymentScreen.kt", "symbol": "RepaymentScreenKt.RepaymentScreen", "line": "85",  "library": "app.bachatt.customer", "owner": "DEVELOPER", "blamed": "false"}
    ],
    "crash_count": "47",
    "last_seen": "2026-10-21 09:15 UTC",
    "app_version": "6.2.5"
  },
  {
    "platform": "ios",
    "issue_id": "test_ios_repayment01",
    "issue_title": "Kotlin Native crash in RepaymentScreen",
    "issue_subtitle": "RepaymentScreen.kt",
    "is_fatal": "true",
    "blamed_file": "RepaymentScreen.kt",
    "blamed_symbol": "kfun:app.bachatt.customer.feature.loan.presentation.repayment.screens#RepaymentContent",
    "blamed_line": "140",
    "blamed_library": "ComposeApp",
    "exception_type": "kotlin.KotlinNullPointerException",
    "exception_message": "selectedOption must not be null",
    "developer_frames": [
      {"file": "RepaymentScreen.kt", "symbol": "kfun:app.bachatt.customer.feature.loan.presentation.repayment.screens#RepaymentContent", "line": "140", "library": "ComposeApp", "owner": "DEVELOPER", "blamed": "true"},
      {"file": "RepaymentScreen.kt", "symbol": "kfun:app.bachatt.customer.feature.loan.presentation.repayment.screens#RepaymentScreen",  "line": "85",  "library": "ComposeApp", "owner": "DEVELOPER", "blamed": "false"}
    ],
    "crash_count": "29",
    "last_seen": "2026-10-21 09:10 UTC",
    "app_version": "6.2.5"
  }
]
TESTEOF
  CRASH_COUNT=2
  log "Injected 2 synthetic crashes — same commonMain bug on Android + iOS."
else
  # ── Detect which tables exist ────────────────────────────────────────────
  ANDROID_EXISTS=false
  IOS_EXISTS=false

  if bq show --quiet "$PROJECT_ID:$DATASET.$ANDROID_TABLE" &>/dev/null; then
    ANDROID_EXISTS=true
    log "Android table: FOUND ($ANDROID_TABLE)"
  else
    log "Android table: NOT FOUND — skipping Android"
  fi

  if bq show --quiet "$PROJECT_ID:$DATASET.$IOS_TABLE" &>/dev/null; then
    IOS_EXISTS=true
    log "iOS table:     FOUND ($IOS_TABLE)"
  else
    log "iOS table:     NOT FOUND — enable BigQuery export for iOS in Firebase Console"
  fi

  if [ "$ANDROID_EXISTS" = "false" ] && [ "$IOS_EXISTS" = "false" ]; then
    log "ERROR: Neither Android nor iOS table found. Check BigQuery export setup."
    exit 1
  fi

  # ── Query Android ────────────────────────────────────────────────────────
  if [ "$ANDROID_EXISTS" = "true" ]; then
    log "Querying Android crashes..."
    ANDROID_QUERY="$(bq_select "$ANDROID_TABLE" "android") ORDER BY crash_count DESC LIMIT 5"
    if ! bq query --project_id="$PROJECT_ID" --format=json --use_legacy_sql=false --max_rows=5 \
        "$ANDROID_QUERY" > "$ANDROID_FILE" 2>&1; then
      log "WARNING: Android query failed — $(cat "$ANDROID_FILE" | head -2)"
      echo "[]" > "$ANDROID_FILE"
    else
      ANDROID_COUNT=$(python3 -c "import json,sys; print(len(json.load(sys.stdin)))" < "$ANDROID_FILE" 2>/dev/null || echo "0")
      log "Android: $ANDROID_COUNT crash groups"
    fi
  else
    echo "[]" > "$ANDROID_FILE"
  fi

  # ── Query iOS ────────────────────────────────────────────────────────────
  if [ "$IOS_EXISTS" = "true" ]; then
    log "Querying iOS crashes..."
    IOS_QUERY="$(bq_select "$IOS_TABLE" "ios") ORDER BY crash_count DESC LIMIT 5"
    if ! bq query --project_id="$PROJECT_ID" --format=json --use_legacy_sql=false --max_rows=5 \
        "$IOS_QUERY" > "$IOS_FILE" 2>&1; then
      log "WARNING: iOS query failed — $(cat "$IOS_FILE" | head -2)"
      echo "[]" > "$IOS_FILE"
    else
      IOS_COUNT=$(python3 -c "import json,sys; print(len(json.load(sys.stdin)))" < "$IOS_FILE" 2>/dev/null || echo "0")
      log "iOS: $IOS_COUNT crash groups"
    fi
  else
    echo "[]" > "$IOS_FILE"
  fi

  # ── Merge & sort top 5 by crash_count ───────────────────────────────────
  python3 - "$ANDROID_FILE" "$IOS_FILE" "$CRASHES_FILE" << 'PYEOF'
import json, sys
android = json.load(open(sys.argv[1]))
ios     = json.load(open(sys.argv[2]))
combined = android + ios
combined.sort(key=lambda x: int(x.get("crash_count", 0)), reverse=True)
json.dump(combined[:5], open(sys.argv[3], "w"), indent=2)
PYEOF

  CRASH_COUNT=$(python3 -c "import json,sys; print(len(json.load(sys.stdin)))" < "$CRASHES_FILE" 2>/dev/null || echo "0")
  log "Combined top crashes: $CRASH_COUNT (sorted by count)"
fi

rm -f "$ANDROID_FILE" "$IOS_FILE" 2>/dev/null || true

# ── Early exit if nothing to do ────────────────────────────────────────────
if [ "$CRASH_COUNT" = "0" ]; then
  log "No crashes found in last ${INTERVAL_DAYS}d. Nothing to do."
  rm -f "$CRASHES_FILE"
  [ "$STASHED" = "true" ] && git stash pop --quiet
  exit 0
fi

# ── Invoke Claude Code ─────────────────────────────────────────────────────
CRASH_DATA=$(cat "$CRASHES_FILE")
log "Invoking Claude Code for KMP crash analysis and auto-fix..."

"$CLAUDE_BIN" --dangerously-skip-permissions -p "
You are a senior KMP (Kotlin Multiplatform) engineer on the Bachatt customer app.
Your job is crash triage across BOTH Android and iOS.

ALWAYS read CLAUDE.md first — every fix must comply with those rules.
All shared business logic lives in composeApp/src/commonMain/.

━━━ CRASH DATA (BigQuery — last ${INTERVAL_DAYS}d, prod Android + iOS) ━━━━━━━━
$CRASH_DATA
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Each crash entry has a 'platform' field: 'android' or 'ios'.

PROCESS for each crash:

1. LOCATE
   - Use blamed_file / blamed_symbol / developer_frames to find the source file.
   - Android symbols: standard Kotlin class names (e.g. RepaymentScreenKt.RepaymentContent)
   - iOS symbols:     Kotlin Native mangled names starting with 'kfun:' — strip the prefix and
                      read the class/function name after the last '.' or '#' to find the file.
                      e.g. 'kfun:app.bachatt.customer.feature.loan...#RepaymentContent' → RepaymentScreen.kt
   - Search in composeApp/src/commonMain/ first, then androidMain/ or iosMain/ if not found.
   - If the file is not found or the symbol is a system/runtime frame, skip this crash.

2. DETECT CROSS-PLATFORM DUPLICATES
   - If two crashes (one android, one ios) point to the same blamed_file and blamed_line,
     they are the SAME commonMain bug seen on both platforms.
   - Treat them as ONE fix. Sum their crash_counts. Create ONE PR that mentions both platforms.
   - Branch name: fix/crash-kmp-[first 8 chars of android issue_id]

3. CLASSIFY — pick one:
   HIGH confidence (auto-fix):
     • NullPointerException / KotlinNullPointerException from !! in our Kotlin code
     • Unchecked null dereference on a nullable val/var
     • popBackStack() called eagerly or without previousBackStackEntry check
     • String.toInt() / toLong() / toDouble() on a value that can be non-numeric
     • Uri.parse() or Json.decodeFromString not wrapped in try-catch
     • Serialized enum missing UNKNOWN fallback causing JsonDataException
     • LaunchedEffect(Unit) collecting a SharedFlow
   LOW confidence (skip):
     • Logic bugs requiring product knowledge
     • OOM / OutOfMemoryError
     • Android: crashes in ART/system libraries with no Kotlin blamed frame
     • iOS: crashes in ObjC/Swift system frameworks (library does not contain 'bachatt' or 'ComposeApp')
     • iOS: EXC_BAD_ACCESS or signal crashes with no kfun: frame
     • Anything you are not 100% sure how to fix correctly

4. FOR HIGH CONFIDENCE ONLY:
   a. git checkout -b fix/crash-[first-8-chars-of-issue_id]  (use 'kmp-' prefix if cross-platform)
   b. Apply the minimal fix to the shared commonMain file. No extra refactoring.
      Follow ALL CLAUDE.md rules: no !!, use sdp/ssp sizing, no hardcoded strings, etc.
   c. git add [changed files only — never git add -A]
   d. git commit with message:
        fix: [exception_type] in [ClassName] ([total_crash_count] crashes/${INTERVAL_DAYS}d · [platforms])

        Fixes [android issue_id] (Android) and/or [ios issue_id] (iOS)

        Co-Authored-By: Firebase Crash Hunter <noreply@anthropic.com>
   e. git push -u origin HEAD
   f. gh pr create --draft --base master with this EXACT body template:
        ## Firebase Crash Fix

        | Field | Value |
        |---|---|
        | **Platform(s)** | [android / ios / android + ios (commonMain)] |
        | **Android issue** | [android issue_id or —] |
        | **iOS issue** | [ios issue_id or —] |
        | **Title** | [issue_title] |
        | **Total count (${INTERVAL_DAYS}d)** | [sum of crash_counts] crashes |
        | **Last seen** | [most recent last_seen] |
        | **App version** | [app_version] |
        | **Fatal** | [is_fatal] |

        ## Exception
        \`\`\`
        [exception_type]: [exception_message]
        \`\`\`

        ## Blamed Frame
        \`\`\`
        [blamed_file]:[blamed_line] — [blamed_symbol]
        \`\`\`

        ## Developer Stack Frames
        \`\`\`
        [developer_frames formatted as file:line  symbol]
        \`\`\`

        ## Root Cause
        [concise analysis — why this crashes, which layer (commonMain / androidMain / iosMain)]

        ## Fix Applied
        [what changed, which file, why it resolves the crash on both platforms if cross-platform]

        ---
        🤖 Auto-generated by Firebase Crash Hunter (KMP)
   g. git checkout master

5. FOR LOW CONFIDENCE: print 'SKIPPED [issue_id] ([platform]): [reason]' — do nothing else.

HARD LIMITS:
- Maximum 3 PRs per run. Cross-platform duplicates count as 1 PR, not 2.
- Never force-push. Never amend. Never git add -A.
- Never create a PR if you are not 100% certain the fix is correct and complete.
- If two crashes point to the same file, fix them on one branch in one PR.
" 2>&1 | tee -a "$LOG_FILE"

# ── Cleanup ────────────────────────────────────────────────────────────────
if [ "$STASHED" = "true" ]; then
  git checkout master --quiet 2>/dev/null || true
  git stash pop --quiet 2>/dev/null || log "WARNING: Could not restore stash — run 'git stash pop' manually."
fi
rm -f "$CRASHES_FILE"
log "════════════════════════════════════════════"
log "  Crash Hunter finished — $(date '+%H:%M:%S')"
log "════════════════════════════════════════════"
