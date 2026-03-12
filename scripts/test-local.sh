#!/bin/bash
# test-local.sh: Local test suite for ferrofaction
#
# Tests wal-sync.sh and vm-wrapper.sh fully offline by shimming the
# aws and gsutil CLIs with local filesystem equivalents.
#
# The shims treat a local temp directory as the "bucket", translating
# s3:// and gs:// URLs to paths under that directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WAL_SYNC="$SCRIPT_DIR/wal-sync.sh"
VM_WRAPPER="$SCRIPT_DIR/vm-wrapper.sh"

PASS=0
FAIL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC} $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAIL=$((FAIL+1)); }
section() { echo -e "\n${YELLOW}=== $1 ===${NC}"; }

# ── shim directory ────────────────────────────────────────────────────────────
# All shims are written to a temp bin dir and prepended to PATH for subshells.

SHIM_DIR=$(mktemp -d)
trap 'rm -rf "$SHIM_DIR"' EXIT

# Translate a bucket URL (s3://bucket/path or gs://bucket/path) to a local path
# under FAKE_BUCKET_ROOT. Used inside the shims via eval.
bucket_to_path() {
    local url="$1"
    local stripped="${url#s3://}"
    stripped="${stripped#gs://}"
    echo "$FAKE_BUCKET_ROOT/$stripped"
}

# Write the aws shim
cat > "$SHIM_DIR/aws" <<'SHIM'
#!/bin/bash
# Minimal aws s3 shim for ferrofaction tests
# Supports: s3 sync, s3 cp, s3 ls, s3 rm

bucket_to_path() {
    local url="$1"
    local stripped="${url#s3://}"
    echo "$FAKE_BUCKET_ROOT/$stripped"
}

subcommand="$1"; shift  # "s3"
action="$1"; shift      # sync / cp / ls / rm

case "$action" in
    sync)
        # aws s3 sync <src> <dst> [flags...]
        SRC="$1"; DST="$2"
        # strip flags
        if [[ "$SRC" == s3://* ]]; then
            SRC_PATH="$(bucket_to_path "$SRC")"
            DST_PATH="$DST"
        else
            SRC_PATH="$SRC"
            DST_PATH="$(bucket_to_path "$DST")"
        fi
        mkdir -p "$DST_PATH"
        rsync -a --delete "$SRC_PATH/" "$DST_PATH/" 2>/dev/null || true
        ;;
    cp)
        # aws s3 cp - <dst>  (stdin to bucket object)
        # aws s3 cp <src> <dst>
        SRC="$1"; DST="$2"
        if [ "$SRC" = "-" ]; then
            DST_PATH="$(bucket_to_path "$DST")"
            mkdir -p "$(dirname "$DST_PATH")"
            cat > "$DST_PATH"
        elif [[ "$SRC" == s3://* ]]; then
            SRC_PATH="$(bucket_to_path "$SRC")"
            mkdir -p "$(dirname "$DST")"
            cp "$SRC_PATH" "$DST"
        else
            DST_PATH="$(bucket_to_path "$DST")"
            mkdir -p "$(dirname "$DST_PATH")"
            cp "$SRC" "$DST_PATH"
        fi
        ;;
    ls)
        # aws s3 ls <url>  — exit 0 if exists, 1 if not
        TARGET="$(bucket_to_path "$1")"
        if [ -e "$TARGET" ]; then
            echo "exists $TARGET"
            exit 0
        else
            exit 1
        fi
        ;;
    rm)
        TARGET="$(bucket_to_path "$1")"
        rm -f "$TARGET"
        ;;
    *)
        echo "aws shim: unsupported action '$action'" >&2
        exit 1
        ;;
esac
SHIM
chmod +x "$SHIM_DIR/aws"

# Write the gcloud shim
cat > "$SHIM_DIR/gcloud" <<'SHIM'
#!/bin/bash
# Minimal gcloud storage shim for ferrofaction tests
# Supports: storage rsync, storage cp, storage objects describe, storage rm

bucket_to_path() {
    local url="$1"
    local stripped="${url#gs://}"
    echo "$FAKE_BUCKET_ROOT/$stripped"
}

# First arg is always "storage"
shift  # consume "storage"
action="$1"; shift

case "$action" in
    rsync)
        # gcloud storage rsync --recursive [--delete-unmatched-destination-objects] <src> <dst>
        while [[ "${1:-}" == -* ]]; do shift; done
        SRC="$1"; DST="$2"
        if [[ "$SRC" == gs://* ]]; then
            SRC_PATH="$(bucket_to_path "$SRC")"
            DST_PATH="$DST"
        else
            SRC_PATH="$SRC"
            DST_PATH="$(bucket_to_path "$DST")"
        fi
        mkdir -p "$DST_PATH"
        rsync -a --delete "$SRC_PATH/" "$DST_PATH/" 2>/dev/null || true
        ;;
    cp)
        # gcloud storage cp - <dst>  (stdin to object)
        SRC="$1"; DST="$2"
        if [ "$SRC" = "-" ]; then
            DST_PATH="$(bucket_to_path "$DST")"
            mkdir -p "$(dirname "$DST_PATH")"
            cat > "$DST_PATH"
        fi
        ;;
    objects)
        # gcloud storage objects describe <url>  — exit 0 if exists, 1 if not
        shift  # consume "describe"
        TARGET="$(bucket_to_path "$1")"
        if [ -e "$TARGET" ]; then
            exit 0
        else
            exit 1
        fi
        ;;
    rm)
        # gcloud storage rm [--recursive] <url>
        while [[ "${1:-}" == -* ]]; do shift; done
        TARGET="$(bucket_to_path "$1")"
        if [ -d "$TARGET" ]; then
            rm -rf "$TARGET"
        else
            rm -f "$TARGET"
        fi
        ;;
    ls)
        TARGET="$(bucket_to_path "$1")"
        if [ -e "$TARGET" ]; then
            ls "$TARGET" 2>/dev/null
            exit 0
        else
            exit 1
        fi
        ;;
    *)
        echo "gcloud shim: unsupported storage action '$action'" >&2
        exit 1
        ;;
esac
SHIM
chmod +x "$SHIM_DIR/gcloud"

# ── test helpers ──────────────────────────────────────────────────────────────

# Create a fresh local state dir + fake bucket root, export for subshells
new_env() {
    local base
    base=$(mktemp -d)
    mkdir -p "$base/local/.gemini"
    mkdir -p "$base/bucket"
    echo "$base"
}

cleanup() { rm -rf "$1"; }

# Run wal-sync.sh with the shim PATH and given bucket URL
run_wal() {
    local base="$1" bucket="$2"
    FAKE_BUCKET_ROOT="$base/bucket" \
    FERROFACTION_BUCKET="$bucket" \
    FERROFACTION_LOCAL_STATE="$base/local/.gemini" \
    PATH="$SHIM_DIR:$PATH" \
        bash "$WAL_SYNC" 2>/dev/null
}

# Run vm-wrapper.sh with the shim PATH and a fake gemini command
run_wrapper() {
    local base="$1" bucket="$2" gemini_cmd="$3"; shift 3
    FAKE_BUCKET_ROOT="$base/bucket" \
    FERROFACTION_BUCKET="$bucket" \
    FERROFACTION_LOCAL_STATE="$base/local/.gemini" \
    GEMINI_CMD="$gemini_cmd" \
    PATH="$SHIM_DIR:$PATH" \
        bash "$VM_WRAPPER" "$@" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# SUITE 1: wal-sync.sh — S3 backend
# ─────────────────────────────────────────────────────────────────────────────
section "wal-sync.sh (S3) — syncs state and returns allow"

B=$(new_env)
echo '{"history": []}' > "$B/local/.gemini/history.json"

set +e; OUT=$(run_wal "$B" "s3://test-bucket/agent"); EXIT=$?; set -e
if echo "$OUT" | grep -q '"decision": "allow"' && [ $EXIT -eq 0 ]; then
    pass "returns allow and exits 0"
else
    fail "expected allow/0, got: $OUT (exit $EXIT)"
fi

if [ -f "$B/bucket/test-bucket/agent/state/history.json" ]; then
    pass "state file synced to bucket"
else
    fail "state file not found in fake bucket"
fi
cleanup "$B"

# ─────────────────────────────────────────────────────────────────────────────
section "wal-sync.sh (GCS) — syncs state and returns allow"

B=$(new_env)
echo '{"history": []}' > "$B/local/.gemini/history.json"

set +e; OUT=$(run_wal "$B" "gs://test-bucket/agent"); EXIT=$?; set -e
if echo "$OUT" | grep -q '"decision": "allow"' && [ $EXIT -eq 0 ]; then
    pass "returns allow and exits 0"
else
    fail "expected allow/0, got: $OUT (exit $EXIT)"
fi

if [ -f "$B/bucket/test-bucket/agent/state/history.json" ]; then
    pass "state file synced to bucket"
else
    fail "state file not found in fake bucket"
fi
cleanup "$B"

# ─────────────────────────────────────────────────────────────────────────────
section "wal-sync.sh — missing FERROFACTION_BUCKET → deny"

B=$(new_env)
set +e
OUT=$(FERROFACTION_BUCKET="" FERROFACTION_LOCAL_STATE="$B/local/.gemini" \
    PATH="$SHIM_DIR:$PATH" bash "$WAL_SYNC" 2>/dev/null)
EXIT=$?
set -e
if echo "$OUT" | grep -q '"decision": "deny"' && [ $EXIT -ne 0 ]; then
    pass "returns deny when FERROFACTION_BUCKET unset"
else
    fail "expected deny, got: $OUT (exit $EXIT)"
fi
cleanup "$B"

# ─────────────────────────────────────────────────────────────────────────────
section "wal-sync.sh — bad bucket scheme → deny"

B=$(new_env)
set +e; OUT=$(run_wal "$B" "ftp://bad-scheme/bucket"); EXIT=$?; set -e
if echo "$OUT" | grep -q '"decision": "deny"' && [ $EXIT -ne 0 ]; then
    pass "returns deny for unrecognized scheme"
else
    fail "expected deny for bad scheme, got: $OUT (exit $EXIT)"
fi
cleanup "$B"

# ─────────────────────────────────────────────────────────────────────────────
section "wal-sync.sh — syncs multiple files"

B=$(new_env)
for i in 1 2 3; do echo "data $i" > "$B/local/.gemini/file$i.json"; done

set +e; OUT=$(run_wal "$B" "s3://test-bucket/agent"); set -e
SYNCED=$(ls "$B/bucket/test-bucket/agent/state/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$SYNCED" = "3" ]; then
    pass "all 3 state files synced to bucket"
else
    fail "expected 3 synced files, found $SYNCED"
fi
cleanup "$B"

# ─────────────────────────────────────────────────────────────────────────────
# SUITE 2: vm-wrapper.sh — clean lifecycle
# ─────────────────────────────────────────────────────────────────────────────
section "vm-wrapper.sh — clean start writes lockfile to bucket"

B=$(new_env)
FAKE_GEM=$(mktemp "$SHIM_DIR/fake-gemini-XXXXXX")
printf '#!/bin/bash\nexit 0\n' > "$FAKE_GEM"; chmod +x "$FAKE_GEM"

set +e; run_wrapper "$B" "s3://test-bucket/agent" "$FAKE_GEM"; set -e
LOCK_PATH="$B/bucket/test-bucket/agent/session.lock"
if [ ! -f "$LOCK_PATH" ]; then
    pass "lockfile removed from bucket after clean exit"
else
    fail "lockfile still present in bucket after clean exit"
fi
cleanup "$B"; rm -f "$FAKE_GEM"

# ─────────────────────────────────────────────────────────────────────────────
section "vm-wrapper.sh — lockfile present in bucket during agent run"

B=$(new_env)
LOCK_CHECK=$(mktemp)
FAKE_GEM=$(mktemp "$SHIM_DIR/fake-gemini-XXXXXX")
LOCK_PATH="$B/bucket/test-bucket/agent/session.lock"
cat > "$FAKE_GEM" <<EOF
#!/bin/bash
if [ -f "$LOCK_PATH" ]; then
    echo "LOCKFILE_EXISTS" > "$LOCK_CHECK"
fi
exit 0
EOF
chmod +x "$FAKE_GEM"

set +e; FAKE_BUCKET_ROOT="$B/bucket" run_wrapper "$B" "s3://test-bucket/agent" "$FAKE_GEM"; set -e
if grep -q "LOCKFILE_EXISTS" "$LOCK_CHECK" 2>/dev/null; then
    pass "lockfile exists in bucket while agent is running"
else
    fail "lockfile was not present in bucket during agent run"
fi
cleanup "$B"; rm -f "$FAKE_GEM" "$LOCK_CHECK"

# ─────────────────────────────────────────────────────────────────────────────
section "vm-wrapper.sh — propagates agent exit code"

B=$(new_env)
FAKE_GEM=$(mktemp "$SHIM_DIR/fake-gemini-XXXXXX")
printf '#!/bin/bash\nexit 42\n' > "$FAKE_GEM"; chmod +x "$FAKE_GEM"

set +e; run_wrapper "$B" "s3://test-bucket/agent" "$FAKE_GEM"; CODE=$?; set -e
if [ $CODE -eq 42 ]; then
    pass "wrapper propagates agent exit code (42)"
else
    fail "expected exit 42, got $CODE"
fi
cleanup "$B"; rm -f "$FAKE_GEM"

# ─────────────────────────────────────────────────────────────────────────────
section "vm-wrapper.sh — pulls existing state from bucket on start"

B=$(new_env)
# Pre-populate the bucket with state
mkdir -p "$B/bucket/test-bucket/agent/state"
echo '{"history": ["recovered"]}' > "$B/bucket/test-bucket/agent/state/history.json"

PULLED_CHECK=$(mktemp)
FAKE_GEM=$(mktemp "$SHIM_DIR/fake-gemini-XXXXXX")
cat > "$FAKE_GEM" <<EOF
#!/bin/bash
if [ -f "$B/local/.gemini/history.json" ]; then
    echo "STATE_PULLED" > "$PULLED_CHECK"
fi
exit 0
EOF
chmod +x "$FAKE_GEM"

set +e; run_wrapper "$B" "s3://test-bucket/agent" "$FAKE_GEM"; set -e
if grep -q "STATE_PULLED" "$PULLED_CHECK" 2>/dev/null; then
    pass "state pulled from bucket to local before agent starts"
else
    fail "state was not pulled from bucket"
fi
cleanup "$B"; rm -f "$FAKE_GEM" "$PULLED_CHECK"

# ─────────────────────────────────────────────────────────────────────────────
# SUITE 3: Crash detection and recovery
# ─────────────────────────────────────────────────────────────────────────────
section "crash simulation — recovery prompt injected when lockfile present"

B=$(new_env)
# Simulate a crash: pre-create the lockfile in the bucket
mkdir -p "$B/bucket/test-bucket/agent"
echo "locked" > "$B/bucket/test-bucket/agent/session.lock"

RECOVERY_LOG=$(mktemp)
FAKE_GEM=$(mktemp "$SHIM_DIR/fake-gemini-XXXXXX")
cat > "$FAKE_GEM" <<EOF
#!/bin/bash
echo "ARGS: \$*" >> "$RECOVERY_LOG"
cat >> "$RECOVERY_LOG"
exit 0
EOF
chmod +x "$FAKE_GEM"

set +e; run_wrapper "$B" "s3://test-bucket/agent" "$FAKE_GEM" 2>/dev/null || true; set -e

if grep -q "\-\-resume" "$RECOVERY_LOG" 2>/dev/null; then
    pass "recovery path passes --resume to agent"
else
    fail "--resume not found (got: $(cat "$RECOVERY_LOG" 2>/dev/null || echo empty))"
fi
if grep -q "SYSTEM ALERT" "$RECOVERY_LOG" 2>/dev/null; then
    pass "recovery prompt injected via -p arg"
else
    fail "SYSTEM ALERT not found in agent args"
fi
cleanup "$B"; rm -f "$FAKE_GEM" "$RECOVERY_LOG"

# ─────────────────────────────────────────────────────────────────────────────
section "crash simulation — GCS recovery also works"

B=$(new_env)
mkdir -p "$B/bucket/test-bucket/agent"
echo "locked" > "$B/bucket/test-bucket/agent/session.lock"

RECOVERY_LOG=$(mktemp)
FAKE_GEM=$(mktemp "$SHIM_DIR/fake-gemini-XXXXXX")
cat > "$FAKE_GEM" <<EOF
#!/bin/bash
echo "ARGS: \$*" >> "$RECOVERY_LOG"
cat >> "$RECOVERY_LOG"
exit 0
EOF
chmod +x "$FAKE_GEM"

set +e; run_wrapper "$B" "gs://test-bucket/agent" "$FAKE_GEM" 2>/dev/null || true; set -e

if grep -q "SYSTEM ALERT" "$RECOVERY_LOG" 2>/dev/null; then
    pass "GCS recovery prompt injected via -p arg"
else
    fail "GCS recovery prompt not found"
fi
cleanup "$B"; rm -f "$FAKE_GEM" "$RECOVERY_LOG"

# ─────────────────────────────────────────────────────────────────────────────
section "crash simulation — full cycle: start → crash → recover"

B=$(new_env)
echo '{"history": [{"role": "tool", "parts": [{"functionCall": {"name": "write_file"}}]}]}' \
    > "$B/local/.gemini/history.json"

# Step 1: clean start — wrapper writes lockfile
FAKE_GEM=$(mktemp "$SHIM_DIR/fake-gemini-XXXXXX")
CRASH_SIGNAL=$(mktemp)
cat > "$FAKE_GEM" <<EOF
#!/bin/bash
# Signal that we started, then simulate crash by just exiting without cleanup
echo "STARTED" > "$CRASH_SIGNAL"
exit 0
EOF
chmod +x "$FAKE_GEM"

set +e; run_wrapper "$B" "s3://test-bucket/agent" "$FAKE_GEM" 2>/dev/null; set -e

if grep -q "STARTED" "$CRASH_SIGNAL" 2>/dev/null; then
    pass "step 1: agent ran on clean start"
else
    fail "step 1: agent did not run"
fi

# Simulate crash: manually restore the lockfile (wrapper removed it on clean exit above)
echo "locked" > "$B/bucket/test-bucket/agent/session.lock"
pass "step 2: crash simulated (lockfile restored in bucket)"

# Step 3: WAL sync of recovered state still works
set +e; WAL_OUT=$(run_wal "$B" "s3://test-bucket/agent"); WAL_EXIT=$?; set -e
if echo "$WAL_OUT" | grep -q '"decision": "allow"' && [ $WAL_EXIT -eq 0 ]; then
    pass "step 3: WAL sync succeeds on recovered state"
else
    fail "step 3: WAL sync failed: $WAL_OUT"
fi

# Step 4: recovery start delivers prompt
RECOVERY_LOG=$(mktemp)
FAKE_GEM2=$(mktemp "$SHIM_DIR/fake-gemini-XXXXXX")
cat > "$FAKE_GEM2" <<EOF
#!/bin/bash
echo "ARGS: \$*" >> "$RECOVERY_LOG"
cat >> "$RECOVERY_LOG"
exit 0
EOF
chmod +x "$FAKE_GEM2"

set +e; run_wrapper "$B" "s3://test-bucket/agent" "$FAKE_GEM2" 2>/dev/null || true; set -e
if grep -q "SYSTEM ALERT" "$RECOVERY_LOG" 2>/dev/null; then
    pass "step 4: recovery prompt delivered to agent"
else
    fail "step 4: recovery prompt not found"
fi

cleanup "$B"; rm -f "$FAKE_GEM" "$FAKE_GEM2" "$CRASH_SIGNAL" "$RECOVERY_LOG"

# ─────────────────────────────────────────────────────────────────────────────
# RESULTS
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
TOTAL=$((PASS + FAIL))
if [ $FAIL -eq 0 ]; then
    echo -e "${GREEN}All $TOTAL tests passed.${NC}"
else
    echo -e "${RED}$FAIL/$TOTAL tests FAILED.${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[ $FAIL -eq 0 ]
