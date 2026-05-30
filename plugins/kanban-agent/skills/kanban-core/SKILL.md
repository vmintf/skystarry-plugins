# kanban-core

Shared rules and SQL patterns that all agents must follow when interacting with the kanban board.

## Database location

The DB is always at the project root. Always resolve to an absolute path — never use a relative path, since agents may run from a worktree subdirectory.

```bash
KANBAN_DB=${KANBAN_DB:-$(git rev-parse --show-toplevel)/.kanban/kanban.db}
```

## Column states

| Column | Meaning |
|---|---|
| `draft` | Task defined by planner, not yet picked up |
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

## Claiming a task (concurrency-safe)

Never do a bare UPDATE. Always use a transaction so two agents cannot claim the same task:

```bash
sqlite3 $KANBAN_DB <<'SQL'
BEGIN IMMEDIATE;

SELECT id, title, description, priority
FROM tasks
WHERE id = {task_id} AND column = 'draft';

-- Only proceed if the row above was returned
UPDATE tasks
SET column = 'in_progress', assigned_to = '{agent_name}#{task_id}'
WHERE id = {task_id} AND column = 'draft';

COMMIT;
SQL
```

If the SELECT returns nothing (another agent grabbed it first), ROLLBACK and pick the next available task from `pending_tasks`.

## Claiming a review or QA task (parallel reviewers / QA agents)

The same CAS pattern applies when multiple reviewers or QA agents run in parallel. The sentinel values are:

- **review:** implementer hands off with `assigned_to = 'reviewer'`; claimant flips to `'reviewer#{task_id}'`
- **qa:** reviewer hands off with `assigned_to = 'qa'`; claimant flips to `'qa#{task_id}'`

```bash
# Reviewer claim
sqlite3 $KANBAN_DB <<'SQL'
BEGIN IMMEDIATE;

SELECT id FROM tasks
WHERE id = {task_id} AND column = 'review' AND assigned_to = 'reviewer';

UPDATE tasks
SET assigned_to = 'reviewer#{task_id}'
WHERE id = {task_id} AND column = 'review' AND assigned_to = 'reviewer';

COMMIT;
SQL

# QA claim
sqlite3 $KANBAN_DB <<'SQL'
BEGIN IMMEDIATE;

SELECT id FROM tasks
WHERE id = {task_id} AND column = 'qa' AND assigned_to = 'qa';

UPDATE tasks
SET assigned_to = 'qa#{task_id}'
WHERE id = {task_id} AND column = 'qa' AND assigned_to = 'qa';

COMMIT;
SQL
```

If the SELECT returns nothing, pick the next task.

**Handoff sentinel values to use when moving tasks:**

```sql
-- Implementer → Reviewer
SET column = 'review', assigned_to = 'reviewer'

-- Reviewer → QA (passing)
SET column = 'qa', assigned_to = 'qa'

-- QA → Done (sets final assigned_to; preserves audit trail)
SET column = 'done', assigned_to = 'qa#{task_id}'
```

## Dynamic workflow patterns

When a workflow script orchestrates parallel agents, follow these rules to avoid the most common failure modes:

### 1. Column count queries — never filter by `assigned_to`

Use column alone to count work in each stage:

```javascript
// WRONG — breaks once an agent claims the task (assigned_to is no longer null)
const count = await agent(`sqlite3 ... "SELECT COUNT(*) FROM tasks
  WHERE column='review' AND (assigned_to IS NULL OR assigned_to = '')"`)

// CORRECT
const count = await agent(`sqlite3 ... "SELECT COUNT(*) FROM tasks WHERE column='review'"`)
```

`assigned_to` persists across column transitions and is NOT a reliable "unclaimed" signal outside of a CAS claim statement.

**Exception:** when querying unclaimed tasks to build an assignment list, use the role sentinel explicitly:

```javascript
// Querying unclaimed QA tasks for 1:1 assignment
const tasks = await agent(`sqlite3 -json ... "SELECT id, title FROM tasks
  WHERE column='qa' AND assigned_to='qa' ORDER BY priority DESC"`)
```

### 2. Parallel agents — always assign task IDs from the orchestrator

Never spawn N agents and tell them to "pick a task themselves" — they will all pick the same one.

```javascript
// WRONG — race condition: multiple agents select the same task
await parallel(Array.from({length: N}, () => () =>
  agent(`Pick any task from the qa column and validate it.`)
))

// CORRECT — orchestrator fetches list first, each agent gets its own ID
const raw = await agent(`sqlite3 -json $KANBAN_DB "SELECT id, title FROM tasks
  WHERE column='qa' AND assigned_to='qa' ORDER BY priority DESC"`)
const tasks = JSON.parse(raw.match(/\[[\s\S]*\]/)?.[0] ?? '[]')
await parallel(tasks.map(task => () =>
  agent(`Validate task #${task.id}: ${task.title}. Only touch task #${task.id}.`)
))
```

Each agent must still run the CAS claim as a second layer of safety.

### 3. QA agents — do not set up worktrees

QA validates an already-implemented worktree. It does not clone, branch, or create one. The worktree path is in `review_note`. Explicitly tell QA agents:

```
DO NOT create or set up a worktree.
The code is already checked out. The worktree path is in the task's review_note field.
Your job is to start the application from that path and validate behaviour.
```

### 4. Structured output (`schema`) — only for reasoning agents

The `schema` option forces the agent to call `StructuredOutput`. Agents that only run shell commands and print text will fail:

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
# All pending tasks, highest priority first
sqlite3 $KANBAN_DB "SELECT * FROM pending_tasks;"

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
| `'implementer#task-{N}'` | Per-task session memory — what happened in a specific worktree |
| `'reviewer'` | Shared role memory — accumulated review patterns |
| `'reviewer#task-{N}'` | Per-task session memory — written when reviewer runs in parallel (task_id assigned by orchestrator) |
| `'qa'` | Shared role memory — accumulated QA patterns |
| `'qa#task-{N}'` | Per-task session memory — written when QA runs in parallel (task_id assigned by orchestrator) |
| `'planner'`, `'overseer'` | Single shared memory — these roles are never parallelised per task |

**Rule:** When invoked with a specific `task_id` (parallel orchestration), write *both* the per-task key (`{role}#task-{N}`) and the shared key (`{role}`). When invoked without a task_id, write only the shared key.

### Writing memory

```bash
# Shared role memory (always update at session end)
sqlite3 $KANBAN_DB "
  INSERT INTO agent_memory (agent_name, summary)
  VALUES ('{agent_name}', '{distilled summary of patterns and lessons}')
  ON CONFLICT(agent_name) DO UPDATE SET summary = excluded.summary, updated_at = CURRENT_TIMESTAMP;
"

# Task-scoped session memory (when invoked with a specific task_id — implementer, reviewer, qa)
sqlite3 $KANBAN_DB "
  INSERT INTO agent_memory (agent_name, summary)
  VALUES ('{role}#task-{N}', '{decisions made, edge cases hit, notes for next agent}')
  ON CONFLICT(agent_name) DO UPDATE SET summary = excluded.summary, updated_at = CURRENT_TIMESTAMP;
"
```

### Reading memory

```bash
# Own role memory
sqlite3 $KANBAN_DB "SELECT summary FROM agent_memory WHERE agent_name = '{agent_name}';"

# All role memories (overseer / cross-agent context)
sqlite3 $KANBAN_DB "SELECT agent_name, summary, updated_at FROM agent_memory WHERE agent_name NOT LIKE '%#%' ORDER BY updated_at DESC;"

# All per-task session memories across all roles (overseer diagnosis)
sqlite3 $KANBAN_DB "SELECT agent_name, summary, updated_at FROM agent_memory WHERE agent_name LIKE '%#%' ORDER BY updated_at DESC LIMIT 20;"
```

## Comments

Any agent can leave a comment on a task.

### Plain comment

```bash
sqlite3 $KANBAN_DB "
  INSERT INTO comments (task_id, author, body)
  VALUES ({task_id}, '{agent_name}', '{message}');
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

### Comment with a reference to agent memory

```bash
sqlite3 $KANBAN_DB "
  INSERT INTO comments (task_id, author, body, ref_type, ref_id)
  VALUES (
    {task_id},
    '{agent_name}',
    'Implementer memory covers a similar setup step — check before proceeding.',
    'agent_memory',
    'implementer'
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

- Leave a comment when moving a task back to `draft` so the next agent knows why
- When referencing an edge case, briefly summarise the relevance in `body` — do not rely solely on the link
- One comment per noteworthy event; do not append running logs
