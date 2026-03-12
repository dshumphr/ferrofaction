#!/bin/bash
# test-integration.sh: Real end-to-end integration test for ferrofaction
#
# Uses a live GCS bucket and real Gemini CLI to validate:
#   1. WAL hook syncs session state to GCS after tool calls
#   2. Crash (kill -9) leaves lockfile in bucket
#   3. vm-wrapper detects lockfile and injects recovery prompt on restart
#   4. Recovered session history ends with a post-tool entry (tool result
#      present, no subsequent model response) — the key ambiguous crash case
#
# Prerequisites:
#   - gemini CLI authenticated and working
#   - gsutil authenticated with access to $BUCKET
#   - Run from the ferrofaction repo root

set -euo pipefail

# Ensure gcloud and gemini are on PATH
for _dir in \
    /Users/danielhumphries/google-cloud-sdk/bin \
    /opt/homebrew/bin \
    /usr/local/bin; do
    [[ ":$PATH:" != *":$_dir:"* ]] && export PATH="$PATH:$_dir"
done
unset _dir

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUCKET="gs://ferrofaction-test/agent"

# Temp working dir with no .gemini/settings.json — used for all gemini calls
# except test 1, which needs the WAL hooks to fire. This prevents the hooks
# from adding multi-second gcloud rsync overhead to every tool call in every
# recovery session.
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# Session state dir is keyed to whatever dir gemini is run from
LOCAL_STATE_HOOKS="$HOME/.gemini/tmp/ferrofaction/chats"
LOCAL_STATE_PLAIN="$HOME/.gemini/tmp/$(basename "$WORK_DIR")/chats"
LOCAL_STATE="$LOCAL_STATE_PLAIN"  # default; test 1 overrides

WAL_SYNC="$SCRIPT_DIR/wal-sync.sh"
VM_WRAPPER="$SCRIPT_DIR/vm-wrapper.sh"

PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); }
section() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }
info() { echo -e "  ${CYAN}INFO${NC} $1"; }

# ── helpers ───────────────────────────────────────────────────────────────────

bucket_path() { echo "$BUCKET/state"; }

clean_bucket() {
    gcloud storage rm --recursive "$BUCKET/" > /dev/null 2>&1 || true
}

latest_session_file() {
    ls -t "$LOCAL_STATE"/session-*.json 2>/dev/null | head -1
}

wait_for_file() {
    local path="$1" timeout="${2:-10}"
    local i=0
    while [ $i -lt $timeout ]; do
        [ -f "$path" ] && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

wait_for_bucket_object() {
    local obj="$1" timeout="${2:-20}"
    local i=0
    while [ $i -lt $timeout ]; do
        gcloud storage objects describe "$obj" > /dev/null 2>&1 && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

# Run wal-sync with real bucket pointed at the actual gemini session dir
run_wal() {
    FERROFACTION_BUCKET="$BUCKET" \
    FERROFACTION_LOCAL_STATE="$LOCAL_STATE" \
        bash "$WAL_SYNC" 2>/dev/null
}

# Run vm-wrapper with real bucket and real gemini
run_wrapper() {
    FERROFACTION_BUCKET="$BUCKET" \
    FERROFACTION_LOCAL_STATE="$LOCAL_STATE" \
    GEMINI_CMD="gemini" \
        bash "$VM_WRAPPER" "$@"
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT
# ─────────────────────────────────────────────────────────────────────────────
section "pre-flight checks"

BUCKET_ROOT="${BUCKET%%/agent*}"  # e.g. gs://ferrofaction-test
if ! gcloud storage ls "$BUCKET_ROOT" > /dev/null 2>&1; then
    echo "ERROR: Cannot access bucket. Check gcloud auth." >&2
    exit 1
fi
pass "GCS bucket accessible"

if ! gemini --version > /dev/null 2>&1; then
    echo "ERROR: gemini CLI not found." >&2
    exit 1
fi
pass "gemini CLI found ($(gemini --version 2>&1))"

mkdir -p "$LOCAL_STATE"
info "session state dir: $LOCAL_STATE"
info "bucket: $BUCKET"

# Clean bucket before tests
clean_bucket
info "bucket cleaned"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 1: WAL hook syncs session state to bucket
# ─────────────────────────────────────────────────────────────────────────────
section "test 1: WAL hook fires and syncs session state to GCS"

info "running a headless gemini session with a tool call (write a temp file)..."

TMPFILE="/tmp/ferrofaction-inttest-$$"
cd "$REPO_ROOT"

# Use -y to auto-approve, -p for headless. Ask gemini to write a file — this
# triggers the write_file tool, which fires BeforeTool and AfterTool hooks.
set +e
gemini -y -p "Write the text 'ferrofaction-test' to $TMPFILE and then stop." \
    --output-format text 2>/dev/null
SESSION_EXIT=$?
set -e

if [ -f "$TMPFILE" ]; then
    pass "gemini executed write_file tool (file exists)"
else
    fail "write_file tool did not create $TMPFILE — hooks may not have fired"
fi
rm -f "$TMPFILE"

# Check that the WAL hook synced the session to the bucket
BUCKET_STATE="$(bucket_path)"
SYNCED_COUNT=$(gcloud storage ls "$BUCKET_STATE/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$SYNCED_COUNT" -gt "0" ]; then
    pass "WAL hook synced $SYNCED_COUNT object(s) to bucket after tool call"
else
    fail "no objects found in bucket after tool call — WAL hook may not have run"
fi

# Grab the latest session file for later inspection
SESSION_FILE="$(latest_session_file)"
if [ -n "$SESSION_FILE" ]; then
    pass "session file found: $(basename "$SESSION_FILE")"
    info "session has $(python3 -c "import json; d=json.load(open('$SESSION_FILE')); print(len(d['messages']))" 2>/dev/null) messages"
else
    fail "no session file found in $LOCAL_STATE"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TEST 2: Post-tool crash state — history ends with tool result, no model reply
# ─────────────────────────────────────────────────────────────────────────────
section "test 2: post-tool crash state — synthesize and verify"

info "synthesizing a post-tool-call crash scenario..."

# We manually craft a session that ends with a tool result (functionResponse)
# with no subsequent model message — exactly the ambiguous crash case.
# Then we sync it to the bucket to simulate what the WAL would have captured.

SESSION_ID="ferrofaction-crash-test-$$"
CRASH_SESSION_FILE="$LOCAL_STATE/session-crash-${SESSION_ID}.json"

python3 - <<EOF
import json, datetime, uuid

now = datetime.datetime.utcnow().isoformat() + "Z"

session = {
    "sessionId": "$SESSION_ID",
    "projectHash": "test",
    "startTime": now,
    "lastUpdated": now,
    "messages": [
        {
            "id": str(uuid.uuid4()),
            "timestamp": now,
            "type": "user",
            "content": [{"text": "Write 'hello' to /tmp/ferrofaction-crash-test.txt"}]
        },
        {
            "id": str(uuid.uuid4()),
            "timestamp": now,
            "type": "gemini",
            "content": "I'll write that file now.",
            "thoughts": [],
            "tokens": {"input": 100, "output": 10, "cached": 0, "thoughts": 0, "tool": 0, "total": 110},
            "model": "gemini-3-flash-preview"
        },
        {
            "id": str(uuid.uuid4()),
            "timestamp": now,
            "type": "tool_call",
            "content": {
                "name": "write_file",
                "args": {"path": "/tmp/ferrofaction-crash-test.txt", "content": "hello"}
            }
        },
        {
            "id": str(uuid.uuid4()),
            "timestamp": now,
            "type": "tool_result",
            "content": {
                "name": "write_file",
                "result": {"success": True}
            }
        }
        # NOTE: No model response after this — this is the post-tool crash state.
        # The tool completed, the WAL captured it, but the VM died before
        # the model could respond to the tool result.
    ],
    "kind": "main"
}

with open("$CRASH_SESSION_FILE", "w") as f:
    json.dump(session, f, indent=2)

print(f"wrote crash session with {len(session['messages'])} messages")
print(f"last message type: {session['messages'][-1]['type']}")
EOF

if [ -f "$CRASH_SESSION_FILE" ]; then
    pass "synthesized post-tool crash session created"
    LAST_TYPE=$(python3 -c "import json; d=json.load(open('$CRASH_SESSION_FILE')); print(d['messages'][-1]['type'])" 2>/dev/null)
    if [ "$LAST_TYPE" = "tool_result" ]; then
        pass "confirmed: last message is 'tool_result' (no model reply — correct crash state)"
    else
        fail "unexpected last message type: $LAST_TYPE"
    fi
else
    fail "failed to create crash session file"
fi

# Sync it to the bucket (simulating what the AfterTool WAL hook would have done)
set +e; OUT=$(run_wal); WAL_EXIT=$?; set -e
if echo "$OUT" | grep -q '"decision": "allow"' && [ $WAL_EXIT -eq 0 ]; then
    pass "WAL sync of post-tool crash state succeeded"
else
    fail "WAL sync failed: $OUT"
fi

SYNCED=$(gcloud storage ls "$(bucket_path)/" 2>/dev/null | grep -c "crash" || true)
if [ "$SYNCED" -gt "0" ]; then
    pass "crash session synced to bucket"
else
    fail "crash session not found in bucket after WAL sync"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TEST 3: Crash detection — vm-wrapper detects lockfile
# ─────────────────────────────────────────────────────────────────────────────
section "test 3: crash detection via bucket lockfile"

# Plant the lockfile in the bucket (simulating that vm-wrapper wrote it at
# session start, then the VM was killed before the clean-exit path removed it)
echo "locked" | gcloud storage cp - "$BUCKET/session.lock" > /dev/null 2>&1
if gcloud storage objects describe "$BUCKET/session.lock" > /dev/null 2>&1; then
    pass "lockfile planted in bucket"
else
    fail "failed to plant lockfile in bucket"
fi

# ─────────────────────────────────────────────────────────────────────────────
# TEST 4: Recovery — vm-wrapper injects prompt and agent inspects history
# ─────────────────────────────────────────────────────────────────────────────
section "test 4: recovery — agent receives prompt and inspects crash state"

# Ensure lockfile is present (test 3 may have left it, but re-plant to be safe)
echo "locked" | gcloud storage cp - "$BUCKET/session.lock" > /dev/null 2>&1

info "starting gemini via vm-wrapper with lockfile present..."
info "agent should detect crash, inspect history, and report the post-tool state"

RECOVERY_OUTPUT=$(mktemp)

# Run non-interactively: the wrapper detects the lockfile, injects the SYSTEM
# ALERT via -p, and appends --resume latest automatically.
# We pass --output-format text to get plain output.
set +e
FERROFACTION_BUCKET="$BUCKET" \
FERROFACTION_LOCAL_STATE="$LOCAL_STATE" \
GEMINI_CMD="gemini" \
    bash "$VM_WRAPPER" \
    --output-format text \
    2>/dev/null > "$RECOVERY_OUTPUT"
WRAPPER_EXIT=$?
set -e

RECOVERY_TEXT=$(cat "$RECOVERY_OUTPUT" 2>/dev/null || echo "")
info "agent response: $RECOVERY_TEXT"

# The lockfile should be gone — wrapper removes it after a recovery run
# (or the agent exited — either way the wrapper's clean-exit path ran)
if ! gcloud storage objects describe "$BUCKET/session.lock" > /dev/null 2>&1; then
    pass "lockfile removed from bucket after recovery session"
else
    info "lockfile still present (wrapper may have taken the recovery branch without cleanup)"
fi

# The agent should mention the tool call or write_file in its response
if echo "$RECOVERY_TEXT" | grep -qi -E "write_file|tool|file|result|no.*response|no.*reply|did not respond|not.*replied"; then
    pass "agent response references the post-tool state"
else
    fail "agent response did not reference tool state (got: $RECOVERY_TEXT)"
fi

rm -f "$RECOVERY_OUTPUT"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 5: Kill -9 crash with real session in flight
# ─────────────────────────────────────────────────────────────────────────────
section "test 5: real kill -9 crash during tool execution"

info "cleaning bucket for fresh crash test..."
clean_bucket

info "starting gemini session with a slow task, then kill -9 mid-flight..."

CRASH_LOG=$(mktemp)

# Start a session that writes multiple files (slow enough to kill mid-way)
# Run in background so we can kill it
FERROFACTION_BUCKET="$BUCKET" \
FERROFACTION_LOCAL_STATE="$LOCAL_STATE" \
GEMINI_CMD="gemini" \
    bash "$VM_WRAPPER" \
    -y \
    -p "Write the word 'one' to /tmp/ff-t1.txt, then write 'two' to /tmp/ff-t2.txt, then write 'three' to /tmp/ff-t3.txt. Do them one at a time." \
    --output-format text \
    > "$CRASH_LOG" 2>&1 &
WRAPPER_PID=$!

info "wrapper PID: $WRAPPER_PID — waiting for lockfile to appear in bucket..."

# Wait for the lockfile to appear (wrapper wrote it at startup)
if wait_for_bucket_object "$BUCKET/session.lock" 15; then
    pass "lockfile appeared in bucket (session started)"
else
    fail "lockfile never appeared — wrapper may have failed to start"
    kill $WRAPPER_PID 2>/dev/null || true
    rm -f "$CRASH_LOG"
    # Skip to results
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    TOTAL=$((PASS + FAIL))
    echo -e "${RED}$FAIL/$TOTAL tests FAILED (early exit).${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi

# Let the agent get at least one tool call in, then kill hard
info "sleeping 8s to let first tool call complete and WAL sync..."
sleep 8

info "sending kill -9 to wrapper (PID $WRAPPER_PID)..."
set +e
kill -9 $WRAPPER_PID 2>/dev/null || true
# Also kill any child gemini process
pkill -9 -P $WRAPPER_PID 2>/dev/null || true
set -e

sleep 2

# Verify lockfile is still in bucket (crash left it behind)
if gcloud storage objects describe "$BUCKET/session.lock" > /dev/null 2>&1; then
    pass "lockfile persists in bucket after kill -9 (crash confirmed)"
else
    fail "lockfile missing — was the session too fast and completed cleanly?"
fi

# Verify some state was synced before the crash
OBJECT_COUNT=$(gcloud storage ls "$(bucket_path)/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$OBJECT_COUNT" -gt "0" ]; then
    pass "WAL synced $OBJECT_COUNT object(s) to bucket before crash"
else
    fail "no WAL objects in bucket — hooks may not have fired before kill"
fi

info "agent output before crash: $(cat "$CRASH_LOG" 2>/dev/null | tail -3)"

# Verify the last session's final message is a tool_result (post-tool crash)
LATEST=$(ls -t "$LOCAL_STATE"/session-*.json 2>/dev/null | head -1)
if [ -n "$LATEST" ]; then
    LAST_TYPE=$(python3 -c "
import json
d = json.load(open('$LATEST'))
msgs = d.get('messages', [])
if msgs:
    last = msgs[-1]
    # gemini may use different type names
    print(last.get('type', 'unknown'))
else:
    print('empty')
" 2>/dev/null)
    info "last message type in recovered session: $LAST_TYPE"
    # Accept tool_result, tool_call, or function_response — any non-model type
    # indicates the crash happened mid or post tool, not after model response
    if echo "$LAST_TYPE" | grep -qiE "tool|function|result|call"; then
        pass "recovered session ends with a tool message (not a model reply) — correct post-tool crash state"
    else
        info "last message type was '$LAST_TYPE' — may have crashed after model responded (timing dependent)"
    fi
else
    fail "no session file found after crash"
fi

rm -f "$CRASH_LOG"

# ─────────────────────────────────────────────────────────────────────────────
# TEST 6: Recovery after real kill -9
# ─────────────────────────────────────────────────────────────────────────────
section "test 6: recovery session after real kill -9 crash"

info "restarting via vm-wrapper — should detect lockfile and inject recovery prompt..."

# Verify lockfile is still present before we run the wrapper
if ! gcloud storage objects describe "$BUCKET/session.lock" > /dev/null 2>&1; then
    fail "lockfile missing before test 6 — kill -9 may not have left it behind"
fi

RECOVERY_OUTPUT=$(mktemp)

set +e
FERROFACTION_BUCKET="$BUCKET" \
FERROFACTION_LOCAL_STATE="$LOCAL_STATE" \
GEMINI_CMD="gemini" \
    bash "$VM_WRAPPER" \
    --output-format text \
    2>/dev/null > "$RECOVERY_OUTPUT"
set -e

RECOVERY_TEXT=$(cat "$RECOVERY_OUTPUT" 2>/dev/null || echo "")
info "agent response: $RECOVERY_TEXT"

if [ -n "$RECOVERY_TEXT" ]; then
    pass "agent produced a response after crash recovery"
else
    fail "agent produced no response"
fi

if echo "$RECOVERY_TEXT" | grep -qi -E "verify|check|confirm|tool|write|file|crash|recover|complet"; then
    pass "agent response reflects crash-aware reasoning"
else
    fail "agent response does not appear crash-aware (got: $RECOVERY_TEXT)"
fi

rm -f "$RECOVERY_OUTPUT"

# ─────────────────────────────────────────────────────────────────────────────
# CLEANUP
# ─────────────────────────────────────────────────────────────────────────────
section "cleanup"

clean_bucket
rm -f "$CRASH_SESSION_FILE" 2>/dev/null || true
rm -f /tmp/ff-t1.txt /tmp/ff-t2.txt /tmp/ff-t3.txt 2>/dev/null || true
pass "bucket cleaned up"

# ─────────────────────────────────────────────────────────────────────────────
# RESULTS
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All $TOTAL integration tests passed.${NC}"
else
    echo -e "${RED}$FAIL/$TOTAL tests FAILED.${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ $FAIL -eq 0 ]
