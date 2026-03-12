---

# Specification: Resilient Agentic Session Management in Distributed Environments

## 1. Abstract

This document outlines a system architecture to provide robust session persistence, crash recovery, and state validation for LLM-driven command-line agents (specifically Gemini CLI, extensible to Claude Code) running on ephemeral cloud virtual machines. The system ensures that mid-flight tool executions (e.g., file writes, database drops, network requests) survive hard VM terminations and can be safely resumed or rolled back by the agent without human intervention.

## 2. Problem Statement

LLMs are inherently stateless. Agentic CLIs manage this by maintaining a local chat history and executing tools in a Read-Eval-Print-Loop (REPL). In a distributed environment using ephemeral compute:

1. **State Loss:** A hard VM crash destroys local in-memory and page-cache state.
2. **I/O Race Conditions:** CLIs write their intent to execute a tool (e.g., to a JSON file or SQLite DB) asynchronously. If the VM crashes before the OS flushes the page cache to the storage layer, the state is corrupted.
3. **Context Blindness:** When a new VM resumes the session, the LLM is unaware that a crash occurred and may blindly re-execute destructive, non-idempotent operations.

## 3. Architecture Overview

The solution relies on three core pillars:

1. **Persistent Storage:** An external network volume (e.g., AWS EFS, Google Cloud Filestore) mounted to the ephemeral VM to house the project directory and CLI hidden state (`.gemini/`).
2. **Synchronous Write-Ahead Log (WAL):** Leveraging the CLI's native lifecycle hooks to intercept the execution loop and force a blocking OS-level disk flush before and after any tool execution.
3. **Agentic Recovery Protocol:** An infrastructure-level wrapper script that detects unclean shutdowns via a lockfile and injects a context-aware system prompt, forcing the LLM to verify system state before proceeding.

---

## 4. Implementation Details

### 4.1 The WAL Sync Mechanism & Storage Durability

To guarantee that the CLI's intent to execute a tool is physically written to the network volume before the subprocess spawns, we utilize the CLI's synchronous hook system (`BeforeTool` and `AfterTool`).

**Durability Constraints on Network Volumes:**
A standard OS-level `sync` or `sync -f` command is insufficient for network-attached storage (NFS/EFS). It primarily flushes the local kernel buffer cache but does not strictly guarantee the remote storage server has acknowledged the write to stable storage. Furthermore, executing `fsync()` solely on a directory's file descriptor only guarantees the durability of the directory's *metadata* (ensuring the file exists after a crash), not the file's data blocks.

To enforce strict ACID-like durability, the pre- and post-tool hooks invoke a script that explicitly iterates through the state directory, calls `fsync()` on the individual file descriptors to flush the data blocks, and subsequently calls `fsync()` on the directory descriptor to flush the metadata.

This forces the Linux NFS client to issue a `COMMIT` RPC to the remote server, blocking the agent's REPL loop until the remote storage array acknowledges the write.

**I/O Flush Script (`/usr/local/bin/wal-sync.sh`):**
To prevent silent failures, any I/O error (disk full, permission denied, NFS timeout) other than a legitimate mid-flight file deletion (`ENOENT`) is treated as fatal. This halts the hook execution and blocks the agent from proceeding, preventing state corruption.

```bash
#!/bin/bash
# wal-sync.sh: Synchronous explicit fsync for agent state

# We use Python to explicitly fsync the file descriptors for both the contents 
# of the state files and the parent directory itself. 
python3 -c '
import os, sys, errno

state_dir = "/mnt/agent-state/.gemini"

# 1. fsync the contents of all files in the state directory
try:
    for filename in os.listdir(state_dir):
        filepath = os.path.join(state_dir, filename)
        if os.path.isfile(filepath):
            try:
                # O_RDONLY is sufficient and intentional; write permission is 
                # not required to fsync a file descriptor.
                fd = os.open(filepath, os.O_RDONLY)
                os.fsync(fd)
                os.close(fd)
            except OSError as e:
                # Only ignore ENOENT (transient files deleted mid-flight)
                if e.errno != errno.ENOENT:
                    print(f"WAL fsync failed on {filepath}: {e}", file=sys.stderr)
                    sys.exit(1)
except OSError as e:
    print(f"WAL directory sync failed: {e}", file=sys.stderr)
    sys.exit(1)

# 2. fsync the directory to guarantee metadata (new files/deletions) is committed
try:
    dir_fd = os.open(state_dir, os.O_RDONLY | os.O_DIRECTORY)
    os.fsync(dir_fd)
    os.close(dir_fd)
except OSError as e:
    print(f"WAL directory sync failed: {e}", file=sys.stderr)
    sys.exit(1)
' >&2

# Capture Python exit code
PY_EXIT=$?

if [ $PY_EXIT -ne 0 ]; then
    # If fsync fails, strictly deny execution to prevent state divergence
    echo '{"decision": "deny", "reason": "WAL fsync failed, aborting tool execution to prevent state corruption."}'
    exit 1
fi

# Return the required JSON payload to unblock the CLI
echo '{"decision": "allow"}'
exit 0

```

**Hook Wiring (`.gemini/settings.json`):**

```json
{
  "hooks": {
    "BeforeTool": [
      {
        "matcher": "*",
        "hooks": [{"name": "wal-presync", "type": "command", "command": "/usr/local/bin/wal-sync.sh"}]
      }
    ],
    "AfterTool": [
      {
        "matcher": "*",
        "hooks": [{"name": "wal-postsync", "type": "command", "command": "/usr/local/bin/wal-sync.sh"}]
      }
    ]
  }
}

```

**Empirical Validation:**
To empirically validate the WAL correctness, engineers must verify both the mount configuration and simulate a physical crash:

1. **Mount Verification:** Ensure the NFS client is not overriding POSIX behavior. Run `mount | grep nfs` and verify that the mount does *not* contain flags that weaken cache consistency (e.g., ensure `ac` or `actimeo` are understood for your workload, and `async` is not present if unsupported by the server).
2. **Hard Crash Test:** * Initiate a long-running, state-mutating agent action (e.g., creating a large file).
* Monitor `nfsstat -c | grep -i commit` to observe the RPC being issued when the pre-hook fires.
* Immediately trigger a hard VM termination (`kill -9` on the CLI process or an instance stop via the cloud console) *during* the tool execution.
* Remount the volume on a new VM and verify that the `.gemini` state directory perfectly reflects the pending tool intent before the crash occurred.



**Supported Infrastructure Matrix:**
Because this architecture relies on protocol-strict `COMMIT` RPCs, only specific VM and Storage combinations are supported for production deployment.

* **✅ Supported (Strict NFSv3/v4 POSIX Compliance):**
* **AWS:** EC2 instances mounting Amazon EFS.
* **GCP:** Compute Engine instances mounting Google Cloud Filestore.
* **Azure:** VMs mounting Azure NetApp Files or Azure Files (Premium NFS).


* **❌ Unsupported (Data Loss Risk):**
* **Self-Hosted NFS (`async` exports):** Custom NFS servers running with the `async` flag in `/etc/exports` will reply "success" before data hits the physical disk. A storage server crash will silently corrupt the agent WAL.
* **SMB/CIFS Mounts:** Windows File Sharing protocols handle `fsync()` POSIX translations unpredictably, leading to torn JSON writes or corrupted SQLite databases.



### 4.2 Crash Detection and Resumption

A shell wrapper manages the VM lifecycle, utilizing a lockfile to distinguish between a clean exit and a hard crash. The lockfile itself is strictly synchronized to the persistent volume to prevent race conditions during instance startup or shutdown.

**VM Wrapper Script:**

```bash
#!/bin/bash
STATE_DIR="/mnt/agent-state"
LOCK_FILE="$STATE_DIR/session.lock"

# Helper function to reliably fsync a file and/or its parent directory.
# Note: Failure here is intentionally non-fatal (prints a warning but does not exit).
# A failed lockfile fsync might cause a benign false-positive recovery prompt on restart, 
# but strictly aborting VM startup/shutdown over it is unnecessary.
fsync_path() {
    python3 -c "
import os, sys
path = '$1'
try:
    if os.path.isfile(path):
        fd = os.open(path, os.O_RDONLY)
        os.fsync(fd)
        os.close(fd)
    elif os.path.isdir(path):
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        os.fsync(fd)
        os.close(fd)
except OSError as e:
    # Best-effort: Emit warning but do not sys.exit(1) to avoid breaking VM lifecycle
    print(f'Warning: Failed to fsync {path}: {e}', file=sys.stderr)
"
}

if [ -f "$LOCK_FILE" ]; then
    # Unclean shutdown detected. Force recovery context.
    INJECTION="[SYSTEM ALERT: Host VM crashed and restarted. Review your last tool call. If it was state-mutating, use read-only tools to verify completion before continuing. Do not blindly retry destructive actions.]"
    echo "$INJECTION" | gemini /restore
else
    # Clean start: Create lockfile and force commit to NFS
    touch "$LOCK_FILE"
    fsync_path "$LOCK_FILE"
    fsync_path "$STATE_DIR"
    
    gemini
    
    # Clean exit: Remove lockfile and force commit to NFS
    rm "$LOCK_FILE"
    fsync_path "$STATE_DIR"
fi

```

### 4.3 The Recovery Protocol

A deterministic instruction set injected into the agent's context (e.g., via `GEMINI.md` in the project root) dictates its behavior upon waking up.

**Recovery Logic:**

1. **Identify State:** Inspect the end of the recovered history array.
2. **Idempotency Check:** If the hanging tool call was read-only (e.g., `ls`, `cat`), retry blindly.
3. **Mutation Check:** If the hanging tool call was state-mutating (e.g., `git commit`, `npm install`), pause execution.
4. **Verification:** Emit read-only tool calls to verify the current environment state.
5. **Escalation:** If state verification is impossible or ambiguous, halt and prompt the human operator for confirmation.

---

## 5. Performance Considerations & Next Steps

**The I/O Penalty:**
Forcing an OS-level `fsync` introduces latency into the agent's REPL loop. In environments with slow network-attached storage, this could add hundreds of milliseconds per tool call. We should test out the practical results of some workload.


---

