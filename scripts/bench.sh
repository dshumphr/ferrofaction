#!/bin/bash
# bench.sh: Measures per-tool-call latency overhead introduced by ferrofaction WAL hooks.
#
# Runs N iterations of a fixed 5-tool-call session in two modes:
#   - WITH hooks:    gemini run from HOOKS_DIR (contains .gemini/settings.json)
#   - WITHOUT hooks: gemini run from PLAIN_DIR (no .gemini/settings.json)
#
# Both dirs are fresh temp directories treated identically by gemini,
# so first-run initialization cost is equal across both conditions.
# Order within each iteration is randomized to avoid systematic bias.
#
# At the end, prints per-iteration timings and summary statistics (mean, min, max).
#
# Usage:
#   bash scripts/bench.sh [ITERATIONS]
#
# Environment variables:
#   FERROFACTION_BUCKET        GCS/S3 bucket URL (required for hooked runs)
#   FERROFACTION_LOCAL_STATE   Local state dir (default: ~/.gemini/tmp/ferrofaction/chats)

set -euo pipefail

export PATH="$PATH:/Users/danielhumphries/google-cloud-sdk/bin"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ITERATIONS="${1:-3}"
BUCKET="${FERROFACTION_BUCKET:-gs://ferrofaction-test/agent}"
LOCAL_STATE="${FERROFACTION_LOCAL_STATE:-$HOME/.gemini/tmp/ferrofaction/chats}"
HOOKS_DIR="$(mktemp -d)"
PLAIN_DIR="$(mktemp -d)"

# Inject settings.json into the hooked dir only
mkdir -p "$HOOKS_DIR/.gemini"
cp "$REPO_ROOT/.gemini/settings.json" "$HOOKS_DIR/.gemini/settings.json"

cleanup() {
    rm -rf "$HOOKS_DIR" "$PLAIN_DIR"
    rm -f "$REPO_ROOT"/perf-{a,b,c}.txt
}
trap cleanup EXIT

PROMPT="Do each of these steps with a separate tool call, in order: \
1) write 'hello' to $REPO_ROOT/perf-a.txt \
2) write 'world' to $REPO_ROOT/perf-b.txt \
3) read $REPO_ROOT/perf-a.txt \
4) read $REPO_ROOT/perf-b.txt \
5) write 'done' to $REPO_ROOT/perf-c.txt"

# ── helpers ───────────────────────────────────────────────────────────────────

run_timed() {
    local start end
    start=$(python3 -c "import time; print(time.time())")
    "$@" > /dev/null 2>&1
    end=$(python3 -c "import time; print(time.time())")
    python3 -c "print(f'{$end - $start:.2f}')"
}

summarize() {
    local label="$1"; shift
    python3 - "$label" "$@" <<'EOF'
import sys
label = sys.argv[1]
vals = [float(x) for x in sys.argv[2:]]
n = len(vals)
mean = sum(vals) / n
mn = min(vals)
mx = max(vals)
print(f"{label}: n={n}  mean={mean:.2f}s  min={mn:.2f}s  max={mx:.2f}s")
EOF
}

clear_bucket() {
    gcloud storage rm --recursive "$BUCKET/" 2>/dev/null || true
}

# ── main ──────────────────────────────────────────────────────────────────────

echo "ferrofaction bench — $ITERATIONS iterations × 2 modes (with/without hooks)"
echo "Bucket:   $BUCKET"
echo "HooksDir: $HOOKS_DIR"
echo "PlainDir: $PLAIN_DIR"
echo

WITH_TIMES=()
WITHOUT_TIMES=()

for i in $(seq 1 "$ITERATIONS"); do
    echo "── iteration $i/$ITERATIONS ──────────────────────────────────"

    # Randomize order each iteration
    if [ $(( RANDOM % 2 )) -eq 0 ]; then
        FIRST="with" SECOND="without"
    else
        FIRST="without" SECOND="with"
    fi

    for mode in "$FIRST" "$SECOND"; do
        rm -f "$REPO_ROOT"/perf-{a,b,c}.txt
        if [ "$mode" = "with" ]; then
            clear_bucket
            echo -n "  with hooks:    "
            t=$(cd "$HOOKS_DIR" && run_timed gemini -y --output-format text -p "$PROMPT")
            WITH_TIMES+=("$t")
        else
            echo -n "  without hooks: "
            t=$(cd "$PLAIN_DIR" && run_timed gemini -y --output-format text -p "$PROMPT")
            WITHOUT_TIMES+=("$t")
        fi
        echo "${t}s"
    done
    echo
done

echo "══════════════════════════════════════════════════════"
summarize "with hooks   " "${WITH_TIMES[@]}"
summarize "without hooks" "${WITHOUT_TIMES[@]}"

python3 - "${WITH_TIMES[@]}" "---" "${WITHOUT_TIMES[@]}" <<'EOF'
import sys
sep = sys.argv.index("---")
with_t = [float(x) for x in sys.argv[1:sep]]
without_t = [float(x) for x in sys.argv[sep+1:]]
overhead = sum(with_t)/len(with_t) - sum(without_t)/len(without_t)
per_call = overhead / 10
print(f"hook overhead  : mean={overhead:.2f}s total  {per_call:.2f}s/hook-invocation (10 hooks per 5-tool session)")
EOF
echo "══════════════════════════════════════════════════════"
