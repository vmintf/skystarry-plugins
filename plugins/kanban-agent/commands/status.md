# /kanban-agent:status

Shows the current state of the kanban board.

## Steps

### 0. Resolve DB path

```bash
KANBAN_DB=${KANBAN_DB:-$(git rev-parse --show-toplevel)/.kanban/kanban.db}
```

### 1. Groups overview

```bash
echo "=== PENDING GROUPS ===" && sqlite3 -column -header $KANBAN_DB "
SELECT group_id, group_name, max_priority, task_count, task_ids
FROM pending_groups;"

echo "" && echo "=== REVIEW GROUPS ===" && sqlite3 -column -header $KANBAN_DB "
SELECT group_id, group_name, max_priority, task_count, assigned_to
FROM review_groups;"

echo "" && echo "=== QA GROUPS ===" && sqlite3 -column -header $KANBAN_DB "
SELECT group_id, group_name, max_priority, task_count, assigned_to
FROM qa_groups;"
```

### 2. Tasks by column (all tasks)

```bash
echo "" && echo "=== BOARD ===" && sqlite3 -column -header $KANBAN_DB "
SELECT t.id, g.name AS group_name, t.title, t.priority, t.column, t.assigned_to, t.lint_result, t.build_result
FROM tasks t
LEFT JOIN task_groups g ON g.id = t.group_id
ORDER BY
  CASE t.column
    WHEN 'error'       THEN 1
    WHEN 'need_verify' THEN 2
    WHEN 'qa'          THEN 3
    WHEN 'review'      THEN 4
    WHEN 'in_progress' THEN 5
    WHEN 'draft'       THEN 6
    WHEN 'done'        THEN 7
  END,
  t.priority DESC;"
```

### 3. Needs attention (error / need_verify)

```bash
echo "" && echo "=== NEEDS ATTENTION ===" && sqlite3 -column -header $KANBAN_DB "
SELECT id, title, column, review_note, priority, group_id
FROM needs_attention
ORDER BY priority DESC;"
```

### 4. Blocked tasks (ungrouped)

```bash
echo "" && echo "=== BLOCKED (waiting on dependencies) ===" && sqlite3 -column -header $KANBAN_DB "
SELECT id, title, priority, depends_on, blocking_status
FROM blocked_tasks
ORDER BY priority DESC;"
```

### 5. QA queue (ungrouped tasks)

```bash
echo "" && echo "=== QA QUEUE (ungrouped) ===" && sqlite3 -column -header $KANBAN_DB "
SELECT id, title, priority, review_note
FROM qa_queue;"
```

### 6. Review queue (ungrouped tasks)

```bash
echo "" && echo "=== REVIEW QUEUE (ungrouped) ===" && sqlite3 -column -header $KANBAN_DB "
SELECT id, title, priority, lint_result, build_result
FROM review_queue;"
```

### 7. Open edge cases

```bash
echo "" && echo "=== OPEN EDGE CASES ===" && sqlite3 -column -header $KANBAN_DB "
SELECT id, title, priority, status
FROM edge_cases
WHERE status != 'resolved'
ORDER BY priority DESC;"
```

### 8. Agent memory

```bash
echo "" && echo "=== AGENT MEMORY (roles) ===" && sqlite3 -column -header $KANBAN_DB "
SELECT agent_name, substr(summary, 1, 120) AS summary, updated_at
FROM agent_memory
WHERE agent_name NOT LIKE '%#%'
ORDER BY updated_at DESC;"

echo "" && echo "=== AGENT MEMORY (per-group sessions, last 10) ===" && sqlite3 -column -header $KANBAN_DB "
SELECT agent_name, substr(summary, 1, 120) AS summary, updated_at
FROM agent_memory
WHERE agent_name LIKE '%#%'
ORDER BY updated_at DESC
LIMIT 10;"
```

### 9. Active worktrees

```bash
echo "" && echo "=== WORKTREES ===" && git worktree list
```

### 10. Recent change log

```bash
echo "" && echo "=== RECENT CHANGES (last 10) ===" && sqlite3 -column -header $KANBAN_DB "
SELECT changed_at, table_name, record_id, field, old_value, new_value, changed_by
FROM change_log
ORDER BY changed_at DESC
LIMIT 10;"
```
