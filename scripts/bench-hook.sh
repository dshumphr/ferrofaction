#!/bin/bash
# bench-hook.sh: Measures raw wal-sync.sh invocation latency.
#
# Invokes wal-sync.sh N times and reports mean/min/max/p95.
# No gemini involved — isolates pure hook cost.
#
# Usage:
#   bash scripts/bench-hook.sh [ITERATIONS]
#
# Environment variables:
#   FERROFACTION_BUCKET        GCS/S3 bucket URL (required)
#   FERROFACTION_LOCAL_STATE   Local state dir (default: ~/.gemini/tmp/ferrofaction/chats)

set -euo pipefail

export PATH="$PATH:/Users/danielhumphries/google-cloud-sdk/bin"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITERATIONS="${1:-20}"
BUCKET="${FERROFACTION_BUCKET:-gs://ferrofaction-test/agent}"
LOCAL_STATE="${FERROFACTION_LOCAL_STATE:-$HOME/.gemini/tmp/ferrofaction/chats}"
WAL="$REPO_ROOT/scripts/wal-sync.sh"

echo "ferrofaction hook bench — $ITERATIONS iterations"
echo "Bucket: $BUCKET"
echo "State:  $LOCAL_STATE"
echo

TIMES=()

for i in $(seq 1 "$ITERATIONS"); do
    start=$(python3 -c "import time; print(time.time())")
    FERROFACTION_BUCKET="$BUCKET" \
    FERROFACTION_LOCAL_STATE="$LOCAL_STATE" \
        bash "$WAL" > /dev/null 2>&1
    end=$(python3 -c "import time; print(time.time())")
    t=$(python3 -c "print(f'{$end - $start:.3f}')")
    TIMES+=("$t")
    printf "  %3d: %ss\n" "$i" "$t"
done

echo
python3 - "${TIMES[@]}" <<'EOF'
import sys
vals = sorted(float(x) for x in sys.argv[1:])
n = len(vals)
mean = sum(vals) / n
p95 = vals[int(n * 0.95)]
print("══════════════════════════════════════════════════════")
print(f"  n={n}  mean={mean:.3f}s  min={vals[0]:.3f}s  max={vals[-1]:.3f}s  p95={p95:.3f}s")
print(f"  per-tool-call overhead (2 hooks): {mean*2:.3f}s")
print("══════════════════════════════════════════════════════")
EOF
