#!/bin/bash
# vm-wrapper.sh: Crash detection and session resumption wrapper for Gemini CLI
#
# This script manages the Gemini CLI lifecycle on an ephemeral VM. It uses a
# lockfile on the persistent NFS volume to distinguish between a clean exit
# and a hard VM crash. On unclean restarts, it injects a recovery context
# prompt to orient the agent before it proceeds.
#
# Usage:
#   ./vm-wrapper.sh [gemini-cli-args...]
#
# Environment variables:
#   STATE_DIR  - Path to the persistent NFS mount point (default: /mnt/agent-state)
#   GEMINI_CMD - Path to the gemini CLI binary (default: gemini)

STATE_DIR="${STATE_DIR:-/mnt/agent-state}"
LOCK_FILE="$STATE_DIR/session.lock"
GEMINI_CMD="${GEMINI_CMD:-gemini}"

# Helper: reliably fsync a file or directory to the NFS server.
# Failure is non-fatal (emits a warning). A failed lockfile fsync may
# cause a benign false-positive recovery prompt on the next restart,
# but strictly aborting VM startup/shutdown over it is unnecessary.
fsync_path() {
    local path="$1"
    python3 -c "
import os, sys
path = '$path'
try:
    if os.path.isfile(path):
        fd = os.open(path, os.O_RDONLY)
        os.fsync(fd)
        os.close(fd)
    elif os.path.isdir(path):
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        os.fsync(fd)
        os.close(fd)
except OSError as e:
    print(f'Warning: Failed to fsync {path}: {e}', file=sys.stderr)
"
}

# Verify the persistent volume is actually mounted before proceeding
if ! mountpoint -q "$STATE_DIR" 2>/dev/null; then
    echo "ERROR: $STATE_DIR is not a mountpoint. Ensure the NFS volume is mounted." >&2
    exit 1
fi

if [ -f "$LOCK_FILE" ]; then
    echo "[vm-wrapper] Unclean shutdown detected (lockfile present). Injecting recovery context." >&2

    RECOVERY_PROMPT="[SYSTEM ALERT: The host VM crashed and has been restarted. Your session has been restored from the persistent volume. Before continuing:
1. Inspect your last tool call in the recovered history.
2. If it was READ-ONLY (ls, cat, grep, read_file), it is safe to retry.
3. If it was STATE-MUTATING (write_file, git commit, npm install, database operations), DO NOT blindly retry. Use read-only tools to verify whether the operation completed successfully before proceeding.
4. If verification is ambiguous or impossible, halt and ask the operator for guidance.
Proceed with caution.]"

    echo "$RECOVERY_PROMPT" | "$GEMINI_CMD" "$@" --resume
else
    echo "[vm-wrapper] Clean start. Creating session lockfile." >&2

    # Create lockfile and commit it to NFS before spawning the agent
    touch "$LOCK_FILE"
    fsync_path "$LOCK_FILE"
    fsync_path "$STATE_DIR"

    "$GEMINI_CMD" "$@"
    EXIT_CODE=$?

    # Clean exit: remove lockfile and commit the deletion to NFS
    echo "[vm-wrapper] Clean exit (code $EXIT_CODE). Removing session lockfile." >&2
    rm -f "$LOCK_FILE"
    fsync_path "$STATE_DIR"

    exit $EXIT_CODE
fi
