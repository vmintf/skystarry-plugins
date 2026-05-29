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
| `'reviewer'`, `'qa'`, `'planner'`, `'overseer'` | Single shared memory per role |

### Writing memory

```bash
# Shared role memory (always update at session end)
sqlite3 $KANBAN_DB "
  INSERT INTO agent_memory (agent_name, summary)
  VALUES ('{agent_name}', '{distilled summary of patterns and lessons}')
  ON CONFLICT(agent_name) DO UPDATE SET summary = excluded.summary, updated_at = CURRENT_TIMESTAMP;
"

# Task-scoped session memory (implementer only)
sqlite3 $KANBAN_DB "
  INSERT INTO agent_memory (agent_name, summary)
  VALUES ('implementer#task-{N}', '{decisions made, edge cases hit, notes for reviewer}')
  ON CONFLICT(agent_name) DO UPDATE SET summary = excluded.summary, updated_at = CURRENT_TIMESTAMP;
"
```

### Reading memory

```bash
# Own role memory
sqlite3 $KANBAN_DB "SELECT summary FROM agent_memory WHERE agent_name = '{agent_name}';"

# All role memories (overseer / cross-agent context)
sqlite3 $KANBAN_DB "SELECT agent_name, summary, updated_at FROM agent_memory WHERE agent_name NOT LIKE '%#%' ORDER BY updated_at DESC;"

# All implementer task sessions (overseer diagnosis)
sqlite3 $KANBAN_DB "SELECT agent_name, summary, updated_at FROM agent_memory WHERE agent_name LIKE 'implementer#%' ORDER BY updated_at DESC LIMIT 20;"
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
