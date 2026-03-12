#!/bin/bash
# bench.sh: Measures per-tool-call latency overhead introduced by ferrofaction WAL hooks.
#
# Runs N iterations of a fixed 5-tool-call session in two modes:
#   - WITH hooks:    gemini run from REPO_ROOT (settings.json hooks active)
#   - WITHOUT hooks: gemini run from WORK_DIR (no settings.json, no hooks)
#
# WORK_DIR is warmed up with a throwaway session before timing begins to
# eliminate first-run initialization bias. Order within each iteration is
# randomized to avoid systematic ordering effects.
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
WORK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK_DIR"
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

# ── warmup ────────────────────────────────────────────────────────────────────

echo "ferrofaction bench — $ITERATIONS iterations × 2 modes (with/without hooks)"
echo "Bucket: $BUCKET"
echo "Repo:   $REPO_ROOT"
echo "WorkDir: $WORK_DIR"
echo
echo "Registering WORK_DIR as a known gemini project (eliminating first-run init bias)..."
PROJECTS_FILE="$HOME/.gemini/projects.json"
REAL_WORK_DIR="$(python3 -c "import os; print(os.path.realpath('$WORK_DIR'))")"
python3 - "$PROJECTS_FILE" "$REAL_WORK_DIR" <<'EOF'
import json, sys, os
path, new_dir = sys.argv[1], sys.argv[2]
data = json.load(open(path)) if os.path.exists(path) else {"projects": {}}
# derive a project name the same way gemini does: basename of the path
name = os.path.basename(new_dir)
data["projects"][new_dir] = name
json.dump(data, open(path, "w"), indent=4)
print(f"  registered {new_dir} as '{name}'")
EOF
echo

# ── main ──────────────────────────────────────────────────────────────────────

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
            t=$(cd "$REPO_ROOT" && run_timed gemini -y --output-format text -p "$PROMPT")
            WITH_TIMES+=("$t")
        else
            echo -n "  without hooks: "
            t=$(cd "$WORK_DIR" && run_timed gemini -y --output-format text -p "$PROMPT")
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
