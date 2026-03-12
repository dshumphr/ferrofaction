# Agent Recovery Protocol

This file is automatically loaded by Gemini CLI as system context. It defines mandatory behavior for crash recovery and session resumption.

---

## On Session Start After a Crash

If you receive a `[SYSTEM ALERT]` message indicating a VM crash, follow this protocol strictly before doing anything else:

### Step 1: Identify Last State

Inspect the end of your recovered conversation history. Identify the last tool call that was in-flight or completed just before the crash.

### Step 2: Classify the Operation

| Operation Type | Examples | Recovery Action |
|---|---|---|
| **Read-only** | `ls`, `cat`, `grep`, `read_file`, `glob` | Safe to retry blindly |
| **Idempotent write** | Writing a config file with fixed content | Verify current state, then re-apply if needed |
| **Non-idempotent mutation** | `git commit`, `npm install`, `DROP TABLE`, `rm -rf` | **STOP. Verify first.** |

### Step 3: Verify Before Acting

For any state-mutating operation, issue read-only tool calls to check actual system state:

- **File writes:** Read the file to confirm its current contents.
- **Git operations:** Run `git log --oneline -5` and `git status` to check commit state.
- **Package installs:** Check `node_modules/`, `requirements.txt` lock files, etc.
- **Database mutations:** Query the affected tables/rows before assuming success or failure.

### Step 4: Decide

- If verification confirms the operation **completed successfully**: continue from the next logical step.
- If verification confirms the operation **did not complete**: retry it safely.
- If state is **ambiguous or unverifiable**: halt immediately and ask the operator for guidance. Do not guess.

### Step 5: Report

Before continuing normal work, briefly summarize to the operator:
- What you found in the recovered history
- What the last in-flight operation was
- What your verification revealed
- What action you are taking (or why you are halting)

---

## General Principles (Always Active)

- **Never blindly retry destructive operations.** Assume any mutation may have partially completed.
- **Prefer read-only verification.** Always confirm state before acting on assumptions.
- **Escalate ambiguity.** If you cannot verify state with certainty, ask a human before proceeding.
- **Log your reasoning.** When recovering, explain your decisions in the chat so the operator can audit them.
