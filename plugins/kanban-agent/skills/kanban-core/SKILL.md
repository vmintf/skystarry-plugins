# kanban-core

Shared rules and SQL patterns that all agents must follow when interacting with the kanban board.

## Database location

The DB is always at the project root. Always resolve to an absolute path — never use a relative path, since agents may run from a worktree subdirectory.

```bash
KANBAN_DB=${KANBAN_DB:-$(git rev-parse --show-toplevel)/.kanban/kanban.db}
```

## Group-based flow model

Tasks are always members of a `task_group`. A group is the **unit of flow**: all tasks in a group share one worktree, one branch, one review, and one QA session. They move through columns together as a unit.

Worktree layout:
```
{project_root}/.worktrees/group-{group_id}   ← group implementer worktree
```

Branch naming:
```
group/{group_id}
```

Tasks without a `group_id` are processed individually via the legacy single-task path (backward-compatible).

## Column states

| Column | Meaning |
|---|---|
| `draft` | Group defined by planner, not yet picked up |
| `in_progress` | Claimed by an implementer, work underway |
| `review` | Implementer handed off; awaiting code review |
| `qa` | Reviewer approved; awaiting execution validation |
| `done` | QA confirmed working |
| `error` | Defect found by reviewer or QA; back to implementer |
| `need_verify` | Ambiguous — requires human or planner decision |

## Priority convention

Integer, higher = more urgent.

| Value | Meaning |
|---|---|
| 10 | Critical / blocking |
| 7–9 | High |
| 4–6 | Normal |
| 1–3 | Low |
| 0 | Unprioritised |

## Claiming a group (concurrency-safe)

Never do a bare UPDATE. Always use a transaction so two agents cannot claim the same group:

```bash
sqlite3 $KANBAN_DB <<'SQL'
BEGIN IMMEDIATE;

SELECT COUNT(*) AS claimable
FROM tasks
WHERE group_id = {group_id} AND column = 'draft';

-- Only proceed if claimable equals the group's task count
UPDATE tasks
SET column = 'in_progress', assigned_to = 'implementer#group-{group_id}'
WHERE group_id = {group_id} AND column = 'draft';

COMMIT;
SQL
```

If SELECT returns 0 (another agent grabbed it first), ROLLBACK and pick the next available group from `pending_groups`.

## Claiming a review or QA group (parallel reviewers / QA agents)

The same CAS pattern applies when multiple reviewers or QA agents run in parallel. The sentinel values are:

- **review:** implementer hands off with `assigned_to = 'reviewer'` on all tasks; claimant flips to `'reviewer#group-{N}'`
- **qa:** reviewer hands off with `assigned_to = 'qa'` on all tasks; claimant flips to `'qa#group-{N}'`

```bash
# Reviewer claim
sqlite3 $KANBAN_DB <<'SQL'
BEGIN IMMEDIATE;

SELECT COUNT(*) AS claimable
FROM tasks
WHERE group_id = {group_id} AND column = 'review' AND assigned_to = 'reviewer';

UPDATE tasks
SET assigned_to = 'reviewer#group-{group_id}'
WHERE group_id = {group_id} AND column = 'review' AND assigned_to = 'reviewer';

COMMIT;
SQL

# QA claim
sqlite3 $KANBAN_DB <<'SQL'
BEGIN IMMEDIATE;

SELECT COUNT(*) AS claimable
FROM tasks
WHERE group_id = {group_id} AND column = 'qa' AND assigned_to = 'qa';

UPDATE tasks
SET assigned_to = 'qa#group-{group_id}'
WHERE group_id = {group_id} AND column = 'qa' AND assigned_to = 'qa';

COMMIT;
SQL
```

If SELECT returns 0, pick the next unclaimed group.

**Handoff sentinel values to use when moving groups:**

```sql
-- Implementer → Reviewer (set on all tasks in group)
SET column = 'review', assigned_to = 'reviewer',
    review_note = 'worktree: .worktrees/group-{N}, branch: group/{N}'

-- Reviewer → QA (set on all tasks in group)
SET column = 'qa', assigned_to = 'qa',
    review_note = 'worktree: .worktrees/group-{N}, branch: group/{N} | {review summary}'

-- QA → Done (set on all tasks in group)
SET column = 'done', assigned_to = 'qa#group-{N}'
```

Always use `WHERE group_id = {group_id}` — never update individual tasks within a group selectively.

## Error recovery (group path)

When a reviewer or QA sends a group to `error`, it disappears from all active views (`pending_groups`, `review_groups`, `qa_groups`) and surfaces only in `needs_attention`. The group is a dead end until the main session or planner resets it.

**Who resets:** The planner or main session (not the implementer). No agent should self-assign from `needs_attention` without an explicit handoff.

**Reset pattern:**

```bash
# Planner or main session reads what went wrong
sqlite3 $KANBAN_DB "
SELECT id, title, column, review_note FROM tasks WHERE group_id = {group_id};
"
sqlite3 $KANBAN_DB "
SELECT author, body, created_at FROM comments_with_refs
WHERE task_id IN (SELECT id FROM tasks WHERE group_id = {group_id})
ORDER BY created_at DESC LIMIT 10;
"

# Reset group to draft (clears lint/build results too)
sqlite3 $KANBAN_DB "
UPDATE tasks
SET column = 'draft', assigned_to = NULL, lint_result = NULL, build_result = NULL
WHERE group_id = {group_id};
"
```

Leave a comment before resetting so the next implementer knows what changed:

```bash
sqlite3 $KANBAN_DB "
INSERT INTO comments (task_id, author, body)
SELECT id, 'planner', 'Resetting to draft. Reviewer rejected: {reason}. Fix {specific issue} before re-submitting.'
FROM tasks WHERE group_id = {group_id};
"
```

Once reset, the group re-enters `pending_groups` and an implementer will pick it up normally.

## Dynamic workflow patterns

When a workflow script orchestrates parallel agents, follow these rules to avoid the most common failure modes.

### 1. Column count queries — use column alone, not assigned_to

```javascript
// WRONG — breaks once an agent claims the group
const count = await agent(`sqlite3 ... "SELECT COUNT(*) FROM tasks
  WHERE column='review' AND assigned_to='reviewer'"`)

// CORRECT
const count = await agent(`sqlite3 ... "SELECT COUNT(*) FROM tasks WHERE column='review'"`)
```

`assigned_to` persists across column transitions and is NOT a reliable "unclaimed" signal outside of a CAS claim statement.

**Exception:** when querying unclaimed groups to build an assignment list, use the role sentinel explicitly:

```javascript
// Querying unclaimed QA groups for 1:1 assignment
const groups = await agent(`sqlite3 -json ... "SELECT group_id, group_name FROM qa_groups
  WHERE assigned_to='qa' ORDER BY max_priority DESC"`)
```

### 2. Parallel agents — assign group IDs from the orchestrator

Never spawn N agents and tell them to "pick a group themselves" — they will all pick the same one.

```javascript
// WRONG — race condition
await parallel(Array.from({length: N}, () => () =>
  agent(`Pick any group from the qa column and validate it.`)
))

// CORRECT — orchestrator fetches list first, each agent gets its own group_id
const raw = await agent(`sqlite3 -json $KANBAN_DB "SELECT group_id, group_name FROM qa_groups
  WHERE assigned_to='qa' ORDER BY max_priority DESC"`)
const groups = JSON.parse(raw.match(/\[[\s\S]*\]/)?.[0] ?? '[]')
await parallel(groups.map(g => () =>
  agent(`Validate group #${g.group_id}: ${g.group_name}. Only touch group #${g.group_id}.`)
))
```

Each agent must still run the CAS claim as a second layer of safety.

### 3. QA agents — do not set up worktrees

QA validates an already-implemented worktree. It does not clone, branch, or create one. The worktree path is in `review_note`. Explicitly tell QA agents:

```
DO NOT create or set up a worktree.
The code is already checked out at .worktrees/group-{N}. The path is in the task's review_note field.
Your job is to start the application from that path and validate behaviour.
```

### 4. Structured output (`schema`) — only for reasoning agents

```javascript
// WRONG — a shell-command agent will not call StructuredOutput
const result = await agent(`sqlite3 -json $DB "SELECT ..."`, { schema: MY_SCHEMA })

// CORRECT — receive as text, parse in the workflow script
const raw = await agent(`sqlite3 -json $DB "SELECT ..." && echo DONE`)
const rows = JSON.parse(raw.match(/\[[\s\S]*\]/)?.[0] ?? '[]')
```

Use `schema` only when the agent performs analysis or judgment that produces a structured result.

## Reading the board

```bash
# All pending groups, highest priority first
sqlite3 $KANBAN_DB "SELECT * FROM pending_groups;"

# All groups in review (with unclaimed filter)
sqlite3 $KANBAN_DB "SELECT * FROM review_groups WHERE assigned_to = 'reviewer';"

# All groups in QA (with unclaimed filter)
sqlite3 $KANBAN_DB "SELECT * FROM qa_groups WHERE assigned_to = 'qa';"

# All tasks in a specific group
sqlite3 $KANBAN_DB "SELECT id, title, column, priority FROM tasks WHERE group_id = {group_id};"

# All open edge cases (check before starting any task)
sqlite3 $KANBAN_DB "SELECT * FROM open_edge_cases;"

# Recent change log (last 20 entries)
sqlite3 $KANBAN_DB "SELECT * FROM change_log ORDER BY changed_at DESC LIMIT 20;"
```

## Logging an edge case

When you encounter an unexpected situation:

```bash
sqlite3 $KANBAN_DB "
  INSERT INTO edge_cases (title, description, priority, status, related_task_id)
  VALUES ('{short title}', '{what happened and why it was unexpected}', {priority}, 'open', {task_id or NULL});
"
```

When resolved:

```bash
sqlite3 $KANBAN_DB "
  UPDATE edge_cases
  SET status = 'resolved', resolution = '{how it was fixed, concise}'
  WHERE id = {edge_case_id};
"
```

## Agent memory conventions

Memory keys follow a two-tier pattern:

| Key pattern | Meaning |
|---|---|
| `'implementer'` | Shared role memory — accumulated patterns across all sessions |
| `'implementer#group-{N}'` | Per-group session memory — what happened in a specific worktree |
| `'reviewer'` | Shared role memory — accumulated review patterns |
| `'reviewer#group-{N}'` | Per-group session memory — written when reviewer runs in parallel |
| `'qa'` | Shared role memory — accumulated QA patterns |
| `'qa#group-{N}'` | Per-group session memory — written when QA runs in parallel |
| `'planner'`, `'overseer'` | Single shared memory — these roles are never parallelised |

**Rule:** When invoked with a specific `group_id` (parallel orchestration), write *both* the per-group key (`{role}#group-{N}`) and the shared key (`{role}`). When invoked without a group_id, write only the shared key.

### Writing memory

```bash
# Shared role memory (always update at session end)
sqlite3 $KANBAN_DB "
  INSERT INTO agent_memory (agent_name, summary)
  VALUES ('{agent_name}', '{distilled summary of patterns and lessons}')
  ON CONFLICT(agent_name) DO UPDATE SET summary = excluded.summary, updated_at = CURRENT_TIMESTAMP;
"

# Group-scoped session memory (when invoked with a specific group_id)
sqlite3 $KANBAN_DB "
  INSERT INTO agent_memory (agent_name, summary)
  VALUES ('{role}#group-{N}', '{decisions made, edge cases hit, notes for next agent}')
  ON CONFLICT(agent_name) DO UPDATE SET summary = excluded.summary, updated_at = CURRENT_TIMESTAMP;
"
```

### Reading memory

```bash
# Own role memory
sqlite3 $KANBAN_DB "SELECT summary FROM agent_memory WHERE agent_name = '{agent_name}';"

# All role memories (overseer / cross-agent context)
sqlite3 $KANBAN_DB "SELECT agent_name, summary, updated_at FROM agent_memory WHERE agent_name NOT LIKE '%#%' ORDER BY updated_at DESC;"

# All per-group session memories across all roles (overseer diagnosis)
sqlite3 $KANBAN_DB "SELECT agent_name, summary, updated_at FROM agent_memory WHERE agent_name LIKE '%#%' ORDER BY updated_at DESC LIMIT 20;"
```

## Comments

Any agent can leave a comment on a task.

### Comment on a single task

```bash
sqlite3 $KANBAN_DB "
  INSERT INTO comments (task_id, author, body)
  VALUES ({task_id}, '{agent_name}', '{message}');
"
```

### Comment on all tasks in a group (preferred for group-level feedback)

```bash
sqlite3 $KANBAN_DB "
  INSERT INTO comments (task_id, author, body)
  SELECT id, '{agent_name}', '{message}'
  FROM tasks WHERE group_id = {group_id};
"
```

### Comment with a reference to an edge case

```bash
sqlite3 $KANBAN_DB "
  INSERT INTO comments (task_id, author, body, ref_type, ref_id)
  VALUES (
    {task_id},
    '{agent_name}',
    'Ran into the same race condition as before — see linked edge case for the fix.',
    'edge_case',
    '{edge_case_id}'
  );
"
```

### Reading comments on a task

```bash
sqlite3 $KANBAN_DB "
  SELECT author, body, ref_type, ref_label, created_at
  FROM comments_with_refs
  WHERE task_id = {task_id};
"
```

### Conventions

- Leave a comment on all group tasks when moving a group back to `draft` so the next agent knows why
- When referencing an edge case, briefly summarise the relevance in `body` — do not rely solely on the link
- One comment per noteworthy event; do not append running logs
