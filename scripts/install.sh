#!/bin/bash
# install.sh: Installs the resilient Gemini session management system
#
# This script installs:
#   - wal-sync.sh to /usr/local/bin/
#   - vm-wrapper.sh to /usr/local/bin/
#   - .gemini/settings.json to the target project directory
#   - GEMINI.md to the target project directory
#
# Usage:
#   sudo ./install.sh [--project-dir /path/to/project] [--state-dir /mnt/agent-state]
#
# Options:
#   --project-dir DIR   Project directory to install .gemini/settings.json and GEMINI.md
#                       (default: current directory)
#   --state-dir DIR     Path where the NFS volume is (or will be) mounted
#                       (default: /mnt/agent-state)
#   --dry-run           Print actions without executing them

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd)"
STATE_DIR="/mnt/agent-state"
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir)
            PROJECT_DIR="$2"
            shift 2
            ;;
        --state-dir)
            STATE_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--project-dir DIR] [--state-dir DIR] [--dry-run]" >&2
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

echo "=== Resilient Gemini Session Manager Installer ==="
echo "  Project dir : $PROJECT_DIR"
echo "  State dir   : $STATE_DIR"
echo "  Dry run     : $DRY_RUN"
echo ""

# --- Install binaries ---

echo "[1/4] Installing wal-sync.sh to /usr/local/bin/wal-sync.sh"
run cp "$SCRIPT_DIR/wal-sync.sh" /usr/local/bin/wal-sync.sh
run chmod +x /usr/local/bin/wal-sync.sh

# Patch the STATE_DIR into the installed wal-sync.sh
if [ "$DRY_RUN" = false ]; then
    sed -i "s|STATE_DIR=\"\${GEMINI_STATE_DIR:-/mnt/agent-state/.gemini}\"|STATE_DIR=\"\${GEMINI_STATE_DIR:-$STATE_DIR/.gemini}\"|" \
        /usr/local/bin/wal-sync.sh
fi

echo "[2/4] Installing vm-wrapper.sh to /usr/local/bin/vm-wrapper.sh"
run cp "$SCRIPT_DIR/vm-wrapper.sh" /usr/local/bin/vm-wrapper.sh
run chmod +x /usr/local/bin/vm-wrapper.sh

# Patch the STATE_DIR into the installed vm-wrapper.sh
if [ "$DRY_RUN" = false ]; then
    sed -i "s|STATE_DIR=\"\${STATE_DIR:-/mnt/agent-state}\"|STATE_DIR=\"\${STATE_DIR:-$STATE_DIR}\"|" \
        /usr/local/bin/vm-wrapper.sh
fi

# --- Install project files ---

echo "[3/4] Installing .gemini/settings.json to $PROJECT_DIR/.gemini/settings.json"
run mkdir -p "$PROJECT_DIR/.gemini"
run cp "$SCRIPT_DIR/../.gemini/settings.json" "$PROJECT_DIR/.gemini/settings.json"

echo "[4/4] Installing GEMINI.md to $PROJECT_DIR/GEMINI.md"
if [ -f "$PROJECT_DIR/GEMINI.md" ]; then
    echo "  WARNING: $PROJECT_DIR/GEMINI.md already exists. Skipping to avoid overwrite."
    echo "  Manually merge content from: $SCRIPT_DIR/../GEMINI.md"
else
    run cp "$SCRIPT_DIR/../GEMINI.md" "$PROJECT_DIR/GEMINI.md"
fi

# --- Create state directory ---

echo ""
echo "=== Post-install ==="

if [ "$DRY_RUN" = false ]; then
    if ! mountpoint -q "$STATE_DIR" 2>/dev/null; then
        echo "  NOTE: $STATE_DIR is not currently a mountpoint."
        echo "  Ensure your NFS volume is mounted there before running vm-wrapper.sh."
        echo "  Example (EFS): mount -t efs fs-XXXXXXXX:/ $STATE_DIR"
    else
        echo "  NFS volume detected at $STATE_DIR. Creating .gemini state directory..."
        mkdir -p "$STATE_DIR/.gemini"
        echo "  Done."
    fi
fi

echo ""
echo "Installation complete."
echo ""
echo "Usage:"
echo "  vm-wrapper.sh [gemini-cli-args...]"
echo ""
echo "To validate your NFS mount:"
echo "  mount | grep nfs"
echo "  nfsstat -c | grep -i commit"
