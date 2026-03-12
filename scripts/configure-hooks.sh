#!/bin/bash
# configure-hooks.sh: Adjusts which tools skip the BeforeTool WAL presync.
#
# Read-only or fast tools don't need a presync — AfterTool alone is sufficient.
# This script adds or removes tools from the BeforeTool matcher's exclusion list.
# The AfterTool hook is never modified; it always fires for every tool.
#
# Usage:
#   bash configure-hooks.sh [OPTIONS] [settings.json]
#
# Options:
#   --skip TOOL[,TOOL,...]    Add tools to the presync exclusion list.
#   --unskip TOOL[,TOOL,...]  Remove tools from the exclusion list.
#   --reset                   Clear all exclusions (BeforeTool fires for everything).
#   --show                    Print the current exclusion list and exit.
#
# settings.json defaults to .gemini/settings.json in the current directory.
#
# Examples:
#   bash configure-hooks.sh --skip read_file,list_directory,glob,grep
#   bash configure-hooks.sh --unskip glob
#   bash configure-hooks.sh --reset
#   bash configure-hooks.sh --show

set -euo pipefail

SETTINGS=""
SKIP_TOOLS=()
UNSKIP_TOOLS=()
MODE="update"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip)
            IFS=',' read -ra PARTS <<< "$2"
            SKIP_TOOLS+=("${PARTS[@]}")
            shift 2
            ;;
        --unskip)
            IFS=',' read -ra PARTS <<< "$2"
            UNSKIP_TOOLS+=("${PARTS[@]}")
            shift 2
            ;;
        --reset)
            MODE="reset"
            shift
            ;;
        --show)
            MODE="show"
            shift
            ;;
        --help|-h)
            sed -n '2,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p }; /^[^#]/q }' "$0"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            SETTINGS="$1"
            shift
            ;;
    esac
done

SETTINGS="${SETTINGS:-.gemini/settings.json}"

if [ ! -f "$SETTINGS" ]; then
    echo "Error: settings file not found: $SETTINGS" >&2
    echo "Run from your project root or pass the path explicitly." >&2
    exit 1
fi

python3 - "$SETTINGS" "$MODE" "${SKIP_TOOLS[@]+"${SKIP_TOOLS[@]}"}" "---" "${UNSKIP_TOOLS[@]+"${UNSKIP_TOOLS[@]}"}" <<'EOF'
import json, re, sys

path   = sys.argv[1]
mode   = sys.argv[2]
rest   = sys.argv[3:]
sep    = rest.index("---")
skip   = rest[:sep]
unskip = rest[sep+1:]

FULL_MATCHER = "*"
PATTERN      = re.compile(r'^\^\(\?!(.+)\)\.\*\$$')

def parse_exclusions(matcher):
    """Return sorted list of excluded tools from a negative-lookahead matcher, or [] for '*'."""
    if matcher == FULL_MATCHER:
        return []
    m = PATTERN.match(matcher)
    if not m:
        return []
    return [t.rstrip('$') for t in m.group(1).split('|')]

def build_matcher(exclusions):
    if not exclusions:
        return FULL_MATCHER
    inner = "|".join(f"{t}$" for t in sorted(exclusions))
    return f"^(?!{inner}).*$"

data = json.load(open(path))
before_hooks = data.get("hooks", {}).get("BeforeTool", [])

if not before_hooks:
    print("Warning: no BeforeTool hooks found in settings.", file=sys.stderr)
    sys.exit(1)

current_matcher  = before_hooks[0].get("matcher", FULL_MATCHER)
current_excluded = parse_exclusions(current_matcher)

if mode == "show":
    if not current_excluded:
        print("BeforeTool fires for all tools (no exclusions).")
    else:
        print("BeforeTool exclusions (presync skipped for):")
        for t in sorted(current_excluded):
            print(f"  {t}")
    sys.exit(0)

if mode == "reset":
    new_excluded = []
elif mode == "update":
    new_excluded = set(current_excluded)
    new_excluded.update(skip)
    new_excluded.difference_update(unskip)
    new_excluded = sorted(new_excluded)

new_matcher = build_matcher(new_excluded)
for entry in before_hooks:
    entry["matcher"] = new_matcher

json.dump(data, open(path, "w"), indent=2)

if not new_excluded:
    print("BeforeTool matcher reset to: * (fires for all tools)")
else:
    print(f"BeforeTool exclusions (presync skipped):")
    for t in sorted(new_excluded):
        print(f"  {t}")
EOF
