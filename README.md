# ferrofaction

Resilient session management for Gemini CLI on ephemeral cloud VMs.

Ensures that mid-flight tool executions survive hard VM terminations and can be safely resumed or rolled back by the agent without human intervention.

---

## The Problem

LLM-driven agents (Gemini CLI, Claude Code) maintain state locally. On ephemeral cloud VMs:

1. **State Loss** — a hard VM crash destroys local in-memory and page-cache state.
2. **I/O Race Conditions** — the CLI writes tool intent asynchronously; a crash before the OS flushes to NFS corrupts that state.
3. **Context Blindness** — when a new VM resumes the session, the LLM doesn't know a crash occurred and may blindly re-execute destructive operations.

## The Solution

Three components working together:

| Component | File | Purpose |
|---|---|---|
| WAL sync hook | `scripts/wal-sync.sh` | Forces `fsync()` on NFS state files before/after every tool call |
| VM wrapper | `scripts/vm-wrapper.sh` | Detects crashes via lockfile; injects recovery prompt on restart |
| Recovery protocol | `GEMINI.md` | Instructs the agent on how to behave after a crash |
| Hook wiring | `.gemini/settings.json` | Wires the WAL sync hook into Gemini CLI's BeforeTool/AfterTool lifecycle |

---

## Quick Start

### Prerequisites

- A persistent NFS volume mounted at `/mnt/agent-state` (AWS EFS, GCP Filestore, or Azure NetApp Files)
- Gemini CLI installed
- Python 3 (for `fsync` calls)

### Install

```bash
sudo ./scripts/install.sh --project-dir /path/to/your/project --state-dir /mnt/agent-state
```

This copies `wal-sync.sh` and `vm-wrapper.sh` to `/usr/local/bin/`, and places `.gemini/settings.json` and `GEMINI.md` in your project directory.

### Run

Replace direct `gemini` invocations with:

```bash
vm-wrapper.sh [gemini-cli-args...]
```

---

## Architecture

### WAL Sync (`wal-sync.sh`)

Registered as both a `BeforeTool` and `AfterTool` hook in `.gemini/settings.json`. Before and after every tool the agent executes, this script:

1. Opens each file in the `.gemini/` state directory and calls `fsync()` on the file descriptor.
2. Opens the directory itself and calls `fsync()` on it (flushes metadata).

On NFSv3/v4, `fsync()` on an open file descriptor causes the NFS client to issue a `COMMIT` RPC to the remote server. The call blocks until the storage array acknowledges the write to stable storage.

If `fsync()` fails for any reason other than `ENOENT` (a file deleted mid-flight), the hook returns `{"decision": "deny"}`, which halts the agent loop. This prevents the agent from proceeding with a potentially corrupted state log.

### Crash Detection (`vm-wrapper.sh`)

On clean start:
- Creates `$STATE_DIR/session.lock` and `fsync`s it to NFS.
- Runs `gemini`.
- On clean exit, removes the lockfile and `fsync`s the directory.

On restart:
- If `session.lock` exists, an unclean shutdown is assumed.
- Injects a recovery context prompt into the agent's session via `gemini --resume`.
- The agent follows the protocol in `GEMINI.md` before continuing.

### Recovery Protocol (`GEMINI.md`)

Loaded automatically by Gemini CLI as system context. Defines a deterministic decision tree:

1. **Identify** the last in-flight tool call from recovered history.
2. **Classify** it as read-only, idempotent, or non-idempotent.
3. **Verify** actual system state with read-only tool calls.
4. **Decide** to retry, skip, or escalate to a human operator.

---

## Supported Infrastructure

| Cloud | Storage | Status |
|---|---|---|
| AWS | EC2 + Amazon EFS | ✅ Supported |
| GCP | Compute Engine + Cloud Filestore | ✅ Supported |
| Azure | VMs + Azure NetApp Files / Azure Files Premium NFS | ✅ Supported |
| Self-hosted | NFS with `async` export flag | ❌ Unsupported — silent data loss risk |
| Any | SMB/CIFS mounts | ❌ Unsupported — unpredictable `fsync` semantics |

---

## Validation

### Verify NFS mount flags

```bash
mount | grep nfs
```

Confirm `async` is not present (it bypasses the COMMIT RPC guarantee).

### Monitor NFS COMMIT RPCs

```bash
nfsstat -c | grep -i commit
```

Observe the counter increment when `wal-sync.sh` fires.

### Hard crash test

1. Start a long-running agent task.
2. While a tool is executing, hard-kill the VM (`kill -9 <pid>` or stop the instance via cloud console).
3. Remount the volume on a new VM.
4. Verify `.gemini/` reflects the pre-crash state.
5. Run `vm-wrapper.sh` — confirm the recovery prompt is injected.

---

## Configuration

| Variable | Default | Description |
|---|---|---|
| `GEMINI_STATE_DIR` | `/mnt/agent-state/.gemini` | Path to the `.gemini` state directory on NFS |
| `STATE_DIR` | `/mnt/agent-state` | Root of the NFS mount (for lockfile) |
| `GEMINI_CMD` | `gemini` | Path to the Gemini CLI binary |

---

## Performance Notes

Each tool call incurs two `fsync` round-trips to the NFS server (one pre, one post). On AWS EFS with default settings, this typically adds 5–50ms per tool call depending on network latency. For agent workloads where tool calls are already measured in seconds, this overhead is generally negligible. See `PLAN.md` §5 for further discussion.
