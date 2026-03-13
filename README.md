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

## Helping the agent recover from mid-tool crashes

When a crash happens during a tool call, the recovered session ends with a `functionCall` entry but no corresponding `functionResponse`. The agent receives a generic recovery prompt and must figure out what to do. Out of the box it applies the rules in `GEMINI.md` — but those rules are general-purpose. You can make recovery significantly smarter by giving the agent tool-specific knowledge.

### Option 1: Annotate your skills/tools with recovery hints

If your project uses Gemini CLI skills or custom tools, add a `## Recovery` section to each skill's `SKILL.md` or tool description. The agent will read this as part of its context when it resumes. Include:

- **Idempotency:** is it safe to call this tool twice with the same arguments?
- **Verification:** what read-only check confirms whether the operation completed?
- **Partial failure:** are there side effects that may have occurred even if the tool didn't return?

Example for a `deploy_service` skill:

```markdown
## Recovery

- **Idempotent:** No. Deploying twice may create duplicate resources.
- **Verify completion:** Run `get_deployment_status(service_id)` and check for status `RUNNING`.
  If status is `PENDING` or absent, the deploy did not complete.
- **Partial failure risk:** IAM role may have been created even if the deployment failed.
  Run `list_iam_roles()` and check before retrying.
```

Example for a `write_report` skill that writes a file:

```markdown
## Recovery

- **Idempotent:** Yes. Writing the same report twice produces the same file.
- **Verify completion:** Read the output file and check it is non-empty and contains the expected header.
```

NOTE: Equally, you could create a separate skill for recovery (eg. write_report_recovery) to minimize context for normal skill use.

### Option 2: Extend `GEMINI.md` with project-specific rules

`GEMINI.md` is loaded as system context on every session, not just recovery. You can append a project-specific table that overrides or extends the generic classification in the recovery protocol:

```markdown
## Project-Specific Tool Classification

| Tool / Operation | Idempotent? | Verify With | On Ambiguity |
|---|---|---|---|
| `run_shell_command` → `make build` | Yes | Check build artifacts exist and are newer than sources | Retry |
| `run_shell_command` → `git push` | No | `git log origin/main..HEAD` — empty means push succeeded | Ask operator |
| `run_shell_command` → `terraform apply` | No | `terraform plan` — no changes means apply completed | Ask operator |
| `write_file` | Yes | Read file and verify contents match | Retry |
| `delete_file` | Yes | Check file no longer exists | Continue |
| `run_shell_command` → `psql ... INSERT` | No | `SELECT` the inserted row by primary key | Ask operator |
```

### What the agent does with this information

On recovery the agent follows `GEMINI.md` step-by-step:

1. Identifies the last in-flight tool call from the recovered history
2. Looks up the tool in the project-specific table (if present), or falls back to the generic classification
3. Runs the specified verification command
4. Retries, skips, or halts based on the result

The more precisely you describe verification steps, the less likely the agent is to either blindly retry a destructive operation or unnecessarily halt and wait for a human.

---

## Tuning hook performance (optional)

By default, `wal-sync.sh` is registered as both a `BeforeTool` and `AfterTool` hook, firing on every tool call. The `BeforeTool` sync captures state just before a mutating tool runs — so if the VM crashes mid-execution, the bucket reflects what the agent was about to do.

For cheap, fast, idempotent tools - like read-only tools (file reads, searches, web fetches) the `BeforeTool` sync is unnecessary: no state changes, so there's nothing new to capture. If you want to skip the presync for specific tools, `configure-hooks.sh` manages a denylist in your `.gemini/settings.json`:

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
