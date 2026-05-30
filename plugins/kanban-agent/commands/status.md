# /kanban-agent:status

Shows the current state of the kanban board.

## Steps

### 0. Resolve DB path

```bash
KANBAN_DB=${KANBAN_DB:-$(git rev-parse --show-toplevel)/.kanban/kanban.db}
```

### 1. Tasks by column

```bash
echo "=== BOARD ===" && sqlite3 -column -header $KANBAN_DB "
SELECT id, title, priority, column, assigned_to, lint_result, build_result
FROM tasks
ORDER BY
  CASE column
    WHEN 'error'       THEN 1
    WHEN 'need_verify' THEN 2
    WHEN 'qa'          THEN 3
    WHEN 'review'      THEN 4
    WHEN 'in_progress' THEN 5
    WHEN 'draft'       THEN 6
    WHEN 'done'        THEN 7
  END,
  priority DESC;"
```

### 2. Needs attention (error / need_verify)

```bash
echo "" && echo "=== NEEDS ATTENTION ===" && sqlite3 -column -header $KANBAN_DB "
SELECT id, title, column, review_note, priority
FROM needs_attention
ORDER BY priority DESC;"
```

### 3. Blocked tasks

```bash
echo "" && echo "=== BLOCKED (waiting on dependencies) ===" && sqlite3 -column -header $KANBAN_DB "
SELECT id, title, priority, depends_on, blocking_status
FROM blocked_tasks
ORDER BY priority DESC;"
```

### 4. QA queue

```bash
echo "" && echo "=== QA QUEUE ===" && sqlite3 -column -header $KANBAN_DB "
SELECT id, title, priority, review_note
FROM qa_queue;"
```

### 5. Review queue

```bash
echo "" && echo "=== REVIEW QUEUE ===" && sqlite3 -column -header $KANBAN_DB "
SELECT id, title, priority, lint_result, build_result
FROM review_queue;"
```

### 6. Open edge cases

```bash
echo "" && echo "=== OPEN EDGE CASES ===" && sqlite3 -column -header $KANBAN_DB "
SELECT id, title, priority, status
FROM edge_cases
WHERE status != 'resolved'
ORDER BY priority DESC;"
```

### 7. Agent memory

```bash
echo "" && echo "=== AGENT MEMORY (roles) ===" && sqlite3 -column -header $KANBAN_DB "
SELECT agent_name, substr(summary, 1, 120) AS summary, updated_at
FROM agent_memory
WHERE agent_name NOT LIKE '%#%'
ORDER BY updated_at DESC;"

echo "" && echo "=== AGENT MEMORY (per-task sessions, last 10) ===" && sqlite3 -column -header $KANBAN_DB "
SELECT agent_name, substr(summary, 1, 120) AS summary, updated_at
FROM agent_memory
WHERE agent_name LIKE '%#%'
ORDER BY updated_at DESC
LIMIT 10;"
```

### 8. Active worktrees

```bash
echo "" && echo "=== WORKTREES ===" && git worktree list
```

### 9. Recent change log

```bash
echo "" && echo "=== RECENT CHANGES (last 10) ===" && sqlite3 -column -header $KANBAN_DB "
SELECT changed_at, table_name, record_id, field, old_value, new_value, changed_by
FROM change_log
ORDER BY changed_at DESC
LIMIT 10;"
```
