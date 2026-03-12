#!/bin/bash
# wal-sync.sh: WAL sync hook for Gemini CLI
#
# Syncs the local .gemini/ state directory to a cloud bucket (S3 or GCS)
# after every tool call, providing a durable write-ahead log.
#
# Registered as BeforeTool and AfterTool in .gemini/settings.json.
#
# Required environment variables:
#   FERROFACTION_BUCKET   Bucket URL, e.g. s3://my-bucket/agent or gs://my-bucket/agent
#
# Optional environment variables:
#   FERROFACTION_LOCAL_STATE   Local state directory to sync (default: ~/.gemini)
#
# Exit behavior:
#   - On sync success: prints {"decision": "allow"} and exits 0
#   - On sync failure: prints {"decision": "deny"} and exits 1
#     This halts the agent loop, preventing it from proceeding with unsynced state.

set -euo pipefail

BUCKET="${FERROFACTION_BUCKET:-}"
LOCAL_STATE="${FERROFACTION_LOCAL_STATE:-$HOME/.gemini}"

if [ -z "$BUCKET" ]; then
    echo "WAL sync error: FERROFACTION_BUCKET is not set." >&2
    echo '{"decision": "deny", "reason": "FERROFACTION_BUCKET is not set."}'
    exit 1
fi

if [ ! -d "$LOCAL_STATE" ]; then
    echo "WAL sync error: local state directory '$LOCAL_STATE' does not exist." >&2
    echo '{"decision": "deny", "reason": "Local state directory does not exist."}'
    exit 1
fi

# Detect backend from bucket URL prefix
if [[ "$BUCKET" == s3://* ]]; then
    BACKEND="s3"
elif [[ "$BUCKET" == gs://* ]]; then
    BACKEND="gcs"
else
    echo "WAL sync error: unrecognized bucket URL '$BUCKET'. Must start with s3:// or gs://" >&2
    echo '{"decision": "deny", "reason": "Unrecognized bucket URL scheme."}'
    exit 1
fi

flush_gemini_files() {
    # Find any session JSON files that gemini has open in LOCAL_STATE and fsync them
    # so the OS kernel buffers are flushed to disk before we rsync to the bucket.
    local pids
    pids=$(pgrep -x gemini 2>/dev/null || true)
    if [ -z "$pids" ]; then
        return 0
    fi
    local open_files
    open_files=$(lsof -p "$(echo "$pids" | tr '\n' ',')" 2>/dev/null \
        | awk '{print $NF}' \
        | grep -F "$LOCAL_STATE" \
        | grep '\.json$' \
        | sort -u || true)
    if [ -z "$open_files" ]; then
        return 0
    fi
    python3 -c "
import os, sys
for path in sys.argv[1:]:
    try:
        fd = os.open(path, os.O_RDONLY)
        os.fsync(fd)
        os.close(fd)
    except OSError:
        pass
" $open_files
}

sync_to_bucket() {
    if [ "$BACKEND" = "s3" ]; then
        aws s3 sync "$LOCAL_STATE/" "$BUCKET/state/" \
            --exact-timestamps \
            --no-progress \
            2>&1
    else
        gcloud storage rsync \
            --recursive \
            --delete-unmatched-destination-objects \
            "$LOCAL_STATE/" "$BUCKET/state/" \
            2>&1
    fi
}

flush_gemini_files

if ! sync_to_bucket; then
    echo '{"decision": "deny", "reason": "WAL sync to bucket failed, aborting tool execution to prevent state divergence."}'
    exit 1
fi

echo '{"decision": "allow"}'
exit 0
