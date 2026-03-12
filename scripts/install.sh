#!/bin/bash
# install.sh: Installs ferrofaction — resilient session management for Gemini CLI
#
# Installs:
#   - wal-sync.sh  → /usr/local/bin/wal-sync.sh
#   - vm-wrapper.sh → /usr/local/bin/vm-wrapper.sh
#   - .gemini/settings.json → <project-dir>/.gemini/settings.json
#   - GEMINI.md → <project-dir>/GEMINI.md
#
# Usage:
#   sudo ./install.sh [--project-dir DIR] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--project-dir DIR] [--dry-run]" >&2
            exit 1
            ;;
    esac
done

run() {
    if [ "$DRY_RUN" = true ]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

echo "=== ferrofaction installer ==="
echo "  Project dir : $PROJECT_DIR"
echo "  Dry run     : $DRY_RUN"
echo ""

echo "[1/4] Installing wal-sync.sh"
run cp "$SCRIPT_DIR/wal-sync.sh" /usr/local/bin/wal-sync.sh
run chmod +x /usr/local/bin/wal-sync.sh

echo "[2/4] Installing vm-wrapper.sh"
run cp "$SCRIPT_DIR/vm-wrapper.sh" /usr/local/bin/vm-wrapper.sh
run chmod +x /usr/local/bin/vm-wrapper.sh

echo "[3/4] Installing .gemini/settings.json"
run mkdir -p "$PROJECT_DIR/.gemini"
run cp "$SCRIPT_DIR/../.gemini/settings.json" "$PROJECT_DIR/.gemini/settings.json"

echo "[4/4] Installing GEMINI.md"
if [ -f "$PROJECT_DIR/GEMINI.md" ]; then
    echo "  WARNING: $PROJECT_DIR/GEMINI.md already exists. Skipping."
    echo "  Manually merge content from: $SCRIPT_DIR/../GEMINI.md"
else
    run cp "$SCRIPT_DIR/../GEMINI.md" "$PROJECT_DIR/GEMINI.md"
fi

echo ""
echo "Installation complete."
echo ""
echo "Required: set FERROFACTION_BUCKET before running."
echo ""
echo "  AWS S3:"
echo "    export FERROFACTION_BUCKET=s3://your-bucket/agent-state"
echo "    export AWS_DEFAULT_REGION=us-east-1"
echo ""
echo "  Google Cloud Storage:"
echo "    export FERROFACTION_BUCKET=gs://your-bucket/agent-state"
echo ""
echo "Usage:"
echo "  vm-wrapper.sh [gemini-cli-args...]"
