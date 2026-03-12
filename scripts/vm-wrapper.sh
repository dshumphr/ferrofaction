#!/bin/bash
# vm-wrapper.sh: Crash detection and session resumption wrapper for Gemini CLI
#
# On startup: pulls agent state from the bucket to local disk, then checks
# for a session lockfile in the bucket. If found, an unclean shutdown is
# assumed and a recovery prompt is injected into the agent session.
#
# On clean exit: removes the lockfile from the bucket.
#
# Required environment variables:
#   FERROFACTION_BUCKET   Bucket URL, e.g. s3://my-bucket/agent or gs://my-bucket/agent
#
# Optional environment variables:
#   FERROFACTION_LOCAL_STATE   Local .gemini directory (default: ~/.gemini)
#   GEMINI_CMD                 Path to the gemini CLI binary (default: gemini)

set -euo pipefail

BUCKET="${FERROFACTION_BUCKET:-}"
LOCAL_STATE="${FERROFACTION_LOCAL_STATE:-$HOME/.gemini}"
GEMINI_CMD="${GEMINI_CMD:-gemini}"
LOCK_OBJECT="$BUCKET/session.lock"

if [ -z "$BUCKET" ]; then
    echo "ERROR: FERROFACTION_BUCKET is not set." >&2
    exit 1
fi

# Detect backend
if [[ "$BUCKET" == s3://* ]]; then
    BACKEND="s3"
elif [[ "$BUCKET" == gs://* ]]; then
    BACKEND="gcs"
else
    echo "ERROR: Unrecognized bucket URL '$BUCKET'. Must start with s3:// or gs://" >&2
    exit 1
fi

# ── backend helpers ───────────────────────────────────────────────────────────

lock_exists() {
    if [ "$BACKEND" = "s3" ]; then
        aws s3 ls "$LOCK_OBJECT" > /dev/null 2>&1
    else
        gcloud storage objects describe "$LOCK_OBJECT" > /dev/null 2>&1
    fi
}

write_lock() {
    if [ "$BACKEND" = "s3" ]; then
        echo "locked" | aws s3 cp - "$LOCK_OBJECT" > /dev/null 2>&1
    else
        echo "locked" | gcloud storage cp - "$LOCK_OBJECT" > /dev/null 2>&1
    fi
}

delete_lock() {
    if [ "$BACKEND" = "s3" ]; then
        aws s3 rm "$LOCK_OBJECT" > /dev/null 2>&1 || true
    else
        gcloud storage rm "$LOCK_OBJECT" > /dev/null 2>&1 || true
    fi
}

pull_state() {
    mkdir -p "$LOCAL_STATE"
    if [ "$BACKEND" = "s3" ]; then
        aws s3 sync "$BUCKET/state/" "$LOCAL_STATE/" \
            --exact-timestamps \
            --no-progress \
            > /dev/null 2>&1 || true
    else
        gcloud storage rsync \
            --recursive \
            "$BUCKET/state/" "$LOCAL_STATE/" \
            > /dev/null 2>&1 || true
    fi
}

# ── startup ───────────────────────────────────────────────────────────────────

echo "[ferrofaction] Pulling state from $BUCKET..." >&2
pull_state

if lock_exists; then
    echo "[ferrofaction] Unclean shutdown detected (session.lock present in bucket). Injecting recovery context." >&2

    RECOVERY_PROMPT="[SYSTEM ALERT: The host VM crashed and has been restarted. Your session state has been restored from $BUCKET. Before continuing:
1. Inspect your last tool call in the recovered history.
2. If it was READ-ONLY (ls, cat, grep, read_file), it is safe to retry.
3. If it was STATE-MUTATING (write_file, git commit, npm install, database operations), DO NOT blindly retry. Use read-only tools to verify whether the operation completed successfully before proceeding.
4. If verification is ambiguous or impossible, halt and ask the operator for guidance.
Proceed with caution.]"

    if [ -t 0 ]; then
        "$GEMINI_CMD" -i "$RECOVERY_PROMPT" "$@" --resume latest
    else
        "$GEMINI_CMD" -p "$RECOVERY_PROMPT" "$@" --resume latest < /dev/null
    fi
    EXIT_CODE=$?

    echo "[ferrofaction] Clean exit from recovery session (code $EXIT_CODE). Removing session lockfile." >&2
    delete_lock

    exit $EXIT_CODE
else
    echo "[ferrofaction] Clean start. Writing session lockfile to bucket." >&2
    write_lock

    "$GEMINI_CMD" "$@"
    EXIT_CODE=$?

    echo "[ferrofaction] Clean exit (code $EXIT_CODE). Removing session lockfile." >&2
    delete_lock

    exit $EXIT_CODE
fi
