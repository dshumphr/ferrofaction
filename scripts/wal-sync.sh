#!/bin/bash
# wal-sync.sh: Synchronous explicit fsync for agent state
#
# This script is invoked as a BeforeTool and AfterTool hook by Gemini CLI.
# It forces an OS-level fsync on all files in the agent state directory,
# ensuring that pending writes are committed to the remote NFS storage
# before or after any tool execution.
#
# On NFSv3/v4 (AWS EFS, GCP Filestore, Azure NetApp Files), this causes
# the NFS client to issue a COMMIT RPC to the remote server, blocking until
# the storage array acknowledges the write to stable storage.
#
# Exit behavior:
#   - On fsync success: prints {"decision": "allow"} and exits 0
#   - On fsync failure (except ENOENT): prints {"decision": "deny"} and exits 1
#     This halts the agent loop, preventing state corruption.

STATE_DIR="${GEMINI_STATE_DIR:-/mnt/agent-state/.gemini}"

python3 -c '
import os, sys, errno

state_dir = sys.argv[1]

# 1. fsync the contents of all files in the state directory
try:
    for filename in os.listdir(state_dir):
        filepath = os.path.join(state_dir, filename)
        if os.path.isfile(filepath):
            try:
                # O_RDONLY is sufficient and intentional; write permission is
                # not required to fsync a file descriptor.
                fd = os.open(filepath, os.O_RDONLY)
                os.fsync(fd)
                os.close(fd)
            except OSError as e:
                # Only ignore ENOENT (transient files deleted mid-flight)
                if e.errno != errno.ENOENT:
                    print(f"WAL fsync failed on {filepath}: {e}", file=sys.stderr)
                    sys.exit(1)
except OSError as e:
    print(f"WAL directory listing failed: {e}", file=sys.stderr)
    sys.exit(1)

# 2. fsync the directory to guarantee metadata (new files/deletions) is committed
try:
    dir_fd = os.open(state_dir, os.O_RDONLY | os.O_DIRECTORY)
    os.fsync(dir_fd)
    os.close(dir_fd)
except OSError as e:
    print(f"WAL directory sync failed: {e}", file=sys.stderr)
    sys.exit(1)
' "$STATE_DIR" >&2

PY_EXIT=$?

if [ $PY_EXIT -ne 0 ]; then
    # If fsync fails, strictly deny execution to prevent state divergence
    echo '{"decision": "deny", "reason": "WAL fsync failed, aborting tool execution to prevent state corruption."}'
    exit 1
fi

echo '{"decision": "allow"}'
exit 0
