# ferrofaction

Resilient session management for Gemini CLI on ephemeral cloud VMs.

Syncs agent state to S3 or GCS after every tool call, and detects VM crashes via a lockfile in the bucket — ensuring sessions can be safely resumed without human intervention.

---

## How it works

| Component | File | Purpose |
|---|---|---|
| WAL sync hook | `scripts/wal-sync.sh` | Syncs `.gemini/` state to the bucket before/after every tool call |
| VM wrapper | `scripts/vm-wrapper.sh` | Pulls state from bucket on start; writes/removes a lockfile; injects recovery prompt on crash |
| Recovery protocol | `GEMINI.md` | Loaded by Gemini CLI as system context; instructs the agent on post-crash behavior |
| Hook wiring | `.gemini/settings.json` | Registers `wal-sync.sh` as `BeforeTool` and `AfterTool` hooks |

**Durability guarantee:** every bucket `PUT` (S3 or GCS) is synchronously acknowledged before the agent loop continues. If the sync fails, the hook returns `{"decision": "deny"}` and the agent halts rather than proceeding with unsynced state.

---

## Quick start

### Prerequisites

- Gemini CLI installed
- One of:
  - AWS CLI (`aws`) configured with bucket access
  - `gsutil` configured with bucket access

### Install

```bash
sudo ./scripts/install.sh --project-dir /path/to/your/project
```

### Configure

```bash
# AWS S3
export FERROFACTION_BUCKET=s3://your-bucket/agent-state
export AWS_DEFAULT_REGION=us-east-1   # or set in ~/.aws/config

# Google Cloud Storage
export FERROFACTION_BUCKET=gs://your-bucket/agent-state
```

### Run

Replace direct `gemini` invocations with:

```bash
vm-wrapper.sh [gemini-cli-args...]
```

---

## Tuning hook performance (optional)

By default, `wal-sync.sh` is registered as both a `BeforeTool` and `AfterTool` hook, firing on every tool call. The `BeforeTool` sync captures state just before a mutating tool runs — so if the VM crashes mid-execution, the bucket reflects what the agent was about to do.

For read-only tools (file reads, searches, web fetches) the `BeforeTool` sync is unnecessary: no state changes, so there's nothing new to capture. If you want to skip the presync for specific tools, `configure-hooks.sh` manages a denylist in your `.gemini/settings.json`:

```bash
# Skip presync for common read-only tools
bash scripts/configure-hooks.sh --skip read_file,list_directory,glob,grep,search_file_content

# Add or remove individual tools later
bash scripts/configure-hooks.sh --skip web_fetch
bash scripts/configure-hooks.sh --unskip glob

# See what's currently excluded
bash scripts/configure-hooks.sh --show

# Go back to syncing before every tool call
bash scripts/configure-hooks.sh --reset
```

**This is a tradeoff.** With a denylist you save ~1.5s per excluded tool call, but if a tool you marked as read-only turns out to write state (e.g. a shell command that also modifies files), the `BeforeTool` sync is silently skipped. Only use this if you have a well-understood, stable tool set and the latency savings matter.

The `AfterTool` hook is never modified by `configure-hooks.sh` — it always fires for every tool, regardless of denylist settings.

---

## Environment variables

| Variable | Default | Description |
|---|---|---|
| `FERROFACTION_BUCKET` | *(required)* | Bucket URL: `s3://bucket/prefix` or `gs://bucket/prefix` |
| `FERROFACTION_LOCAL_STATE` | `~/.gemini` | Local state directory to sync |
| `GEMINI_CMD` | `gemini` | Path to the Gemini CLI binary |

---

## What happens on a crash

1. **VM starts** → wrapper pulls latest state from `$BUCKET/state/` to `~/.gemini/`
2. **Lockfile check** → if `$BUCKET/session.lock` exists, an unclean shutdown is detected
3. **Recovery prompt** → wrapper pipes a `[SYSTEM ALERT]` message into `gemini --resume`
4. **Agent follows `GEMINI.md`** → inspects last tool call, verifies state with read-only tools, then decides to retry, skip, or escalate

---

## Running the tests

The test suite runs fully offline — `aws` and `gsutil` are shimmed with local filesystem equivalents:

```bash
bash scripts/test-local.sh
```

Covers: S3 sync, GCS sync, missing bucket config, bad scheme, multi-file sync, lockfile lifecycle, exit code propagation, state pull on startup, and full crash/recover cycle.

---

## Supported backends

| Backend | Bucket URL format | CLI required |
|---|---|---|
| AWS S3 | `s3://bucket/prefix` | `aws` (AWS CLI v2) |
| Google Cloud Storage | `gs://bucket/prefix` | `gsutil` (or `gcloud storage`) |
| Cloudflare R2 | `s3://bucket/prefix` + `--endpoint-url` in `~/.aws/config` | `aws` |
| Backblaze B2 | `s3://bucket/prefix` + B2 S3-compatible endpoint | `aws` |
