-- kanban-agent schema
-- DB location: {project_root}/.kanban/kanban.db
-- Always reference via absolute path: $KANBAN_DB or $(git rev-parse --show-toplevel)/.kanban/kanban.db
--
-- Worktree layout (parallel implementers, group-based):
--   {project_root}/                     ← main worktree (planner, overseer, QA)
--   {project_root}/.worktrees/group-N   ← per-group implementer worktree
--   {project_root}/.kanban/kanban.db    ← single shared DB across all worktrees
--
-- Tasks are always members of a task_group. A group is the unit of flow:
-- draft → in_progress → review → qa → done (all tasks in a group move together).
-- Tasks without a group_id are processed individually (backward-compatible path).
--
-- agent_memory key conventions:
--   'implementer'           → shared role memory (accumulated patterns)
--   'implementer#group-{N}' → per-group session memory (implementer)
--   'reviewer'              → shared role memory
--   'reviewer#group-{N}'    → per-group session memory (parallel reviewer scenario)
--   'qa'                    → shared role memory
--   'qa#group-{N}'          → per-group session memory (parallel QA scenario)
--   'planner', 'overseer'   → single shared memory (these roles are never parallelised)
--
-- assigned_to sentinel values (group-level):
--   'reviewer'              → review group unclaimed (ready for a reviewer agent)
--   'reviewer#group-{N}'    → claimed by reviewer for group N
--   'qa'                    → qa group unclaimed (ready for a QA agent)
--   'qa#group-{N}'          → claimed by QA agent for group N

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

-- Task groups: a group is the unit of flow through the pipeline
CREATE TABLE IF NOT EXISTS task_groups (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL,   -- short label, e.g. 'auth-feature', 'dashboard-ui'
    description TEXT,               -- what this group of tasks implements together
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Trigger: stamp updated_at on task_groups changes
CREATE TRIGGER IF NOT EXISTS stamp_task_group_updated_at
AFTER UPDATE ON task_groups
BEGIN
    UPDATE task_groups SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;

-- Main task board
CREATE TABLE IF NOT EXISTS tasks (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT    NOT NULL,
    description  TEXT,
    priority     INTEGER NOT NULL DEFAULT 0,  -- higher = more urgent
    column       TEXT    NOT NULL DEFAULT 'draft'
                 CHECK(column IN ('draft', 'in_progress', 'review', 'qa', 'done', 'error', 'need_verify')),
    assigned_to  TEXT,                         -- agent name
    lint_result  TEXT,                         -- 'pass' | 'fail' | NULL
    build_result TEXT,                         -- 'pass' | 'fail' | NULL
    review_note  TEXT,                         -- worktree path and notes (filled by implementer/reviewer)
    depends_on   TEXT,                         -- comma-separated task IDs this task is blocked by
    group_id     INTEGER REFERENCES task_groups(id) ON DELETE SET NULL,
    created_at   DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at   DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Edge cases encountered during task execution
CREATE TABLE IF NOT EXISTS edge_cases (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    title           TEXT    NOT NULL,
    description     TEXT    NOT NULL,
    priority        INTEGER NOT NULL DEFAULT 0,
    status          TEXT    NOT NULL DEFAULT 'open'
                    CHECK(status IN ('open', 'handling', 'resolved')),
    related_task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
    resolution      TEXT,
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Per-agent persistent memory summaries
CREATE TABLE IF NOT EXISTS agent_memory (
    agent_name  TEXT PRIMARY KEY,
    summary     TEXT,
    updated_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Audit log
CREATE TABLE IF NOT EXISTS change_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    table_name  TEXT    NOT NULL,
    record_id   INTEGER NOT NULL,
    field       TEXT    NOT NULL,
    old_value   TEXT,
    new_value   TEXT,
    changed_by  TEXT,
    changed_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Trigger: log task column changes
CREATE TRIGGER IF NOT EXISTS log_task_column_change
AFTER UPDATE OF column ON tasks
BEGIN
    INSERT INTO change_log(table_name, record_id, field, old_value, new_value, changed_by)
    VALUES ('tasks', NEW.id, 'column', OLD.column, NEW.column, NEW.assigned_to);

    UPDATE tasks SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;

-- Trigger: log edge_case status changes
CREATE TRIGGER IF NOT EXISTS log_edge_case_status_change
AFTER UPDATE OF status ON edge_cases
BEGIN
    INSERT INTO change_log(table_name, record_id, field, old_value, new_value, changed_by, changed_at)
    VALUES ('edge_cases', NEW.id, 'status', OLD.status, NEW.status, NULL, CURRENT_TIMESTAMP);

    UPDATE edge_cases SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;

-- ─── Group-based views (primary path) ────────────────────────────────────────

-- View: groups ready to be implemented
--   All member tasks are draft AND no cross-group dependency is unresolved
CREATE VIEW IF NOT EXISTS pending_groups AS
SELECT
    g.id              AS group_id,
    g.name            AS group_name,
    g.description     AS group_description,
    MAX(t.priority)   AS max_priority,
    COUNT(t.id)       AS task_count,
    GROUP_CONCAT(t.id) AS task_ids
FROM task_groups g
JOIN tasks t ON t.group_id = g.id
WHERE g.id NOT IN (
    -- exclude groups that have any non-draft task
    SELECT DISTINCT group_id FROM tasks
    WHERE group_id IS NOT NULL AND column != 'draft'
)
AND g.id NOT IN (
    -- exclude groups where any task has an unresolved cross-group dependency
    SELECT DISTINCT t2.group_id
    FROM tasks t2
    WHERE t2.group_id IS NOT NULL
      AND t2.depends_on IS NOT NULL
      AND EXISTS (
          SELECT 1 FROM tasks dep
          WHERE dep.id IN (
              SELECT CAST(TRIM(value) AS INTEGER)
              FROM json_each('["' || REPLACE(t2.depends_on, ',', '","') || '"]')
          )
          AND dep.column != 'done'
          AND (dep.group_id IS NULL OR dep.group_id != t2.group_id)
      )
)
GROUP BY g.id, g.name, g.description
ORDER BY max_priority DESC, g.created_at ASC;

-- View: groups awaiting review (all tasks in the group are in 'review')
--   assigned_to = 'reviewer'         → unclaimed (ready for a reviewer to pick up)
--   assigned_to = 'reviewer#group-N' → already claimed
CREATE VIEW IF NOT EXISTS review_groups AS
SELECT
    g.id              AS group_id,
    g.name            AS group_name,
    MAX(t.priority)   AS max_priority,
    COUNT(t.id)       AS task_count,
    GROUP_CONCAT(t.id) AS task_ids,
    MIN(t.assigned_to) AS assigned_to,
    MAX(t.lint_result) AS lint_result,
    MAX(t.build_result) AS build_result
FROM task_groups g
JOIN tasks t ON t.group_id = g.id AND t.column = 'review'
WHERE g.id NOT IN (
    SELECT DISTINCT group_id FROM tasks
    WHERE group_id IS NOT NULL AND column != 'review'
)
GROUP BY g.id, g.name
ORDER BY max_priority DESC;

-- View: groups awaiting QA (all tasks in the group are in 'qa')
--   assigned_to = 'qa'         → unclaimed
--   assigned_to = 'qa#group-N' → claimed
CREATE VIEW IF NOT EXISTS qa_groups AS
SELECT
    g.id              AS group_id,
    g.name            AS group_name,
    MAX(t.priority)   AS max_priority,
    COUNT(t.id)       AS task_count,
    GROUP_CONCAT(t.id) AS task_ids,
    MIN(t.assigned_to) AS assigned_to,
    MAX(t.review_note) AS review_note
FROM task_groups g
JOIN tasks t ON t.group_id = g.id AND t.column = 'qa'
WHERE g.id NOT IN (
    SELECT DISTINCT group_id FROM tasks
    WHERE group_id IS NOT NULL AND column != 'qa'
)
GROUP BY g.id, g.name
ORDER BY max_priority DESC;

-- ─── Ungrouped task views (backward-compatible / singleton path) ──────────────

-- View: pending work for implementer — ungrouped tasks only
--   (grouped tasks are handled via pending_groups)
CREATE VIEW IF NOT EXISTS pending_tasks AS
SELECT t.id, t.title, t.description, t.priority, t.assigned_to
FROM tasks t
WHERE t.column = 'draft'
  AND t.group_id IS NULL
  AND (
      t.depends_on IS NULL
      OR NOT EXISTS (
          SELECT 1 FROM tasks dep
          WHERE dep.id IN (
              SELECT CAST(TRIM(value) AS INTEGER)
              FROM json_each('["' || REPLACE(t.depends_on, ',', '","') || '"]')
          )
          AND dep.column != 'done'
      )
  )
ORDER BY t.priority DESC, t.created_at ASC;

-- View: blocked tasks (ungrouped, has depends_on and at least one dep not done)
CREATE VIEW IF NOT EXISTS blocked_tasks AS
SELECT t.id, t.title, t.priority, t.depends_on,
       GROUP_CONCAT(dep.id || ':' || dep.column, ', ') AS blocking_status
FROM tasks t
         JOIN tasks dep ON dep.id IN (
    SELECT CAST(TRIM(value) AS INTEGER)
    FROM json_each('["' || REPLACE(t.depends_on, ',', '","') || '"]')
)
WHERE t.column = 'draft'
  AND t.group_id IS NULL
  AND t.depends_on IS NOT NULL
  AND dep.column != 'done'
GROUP BY t.id;

-- View: ungrouped tasks awaiting review
CREATE VIEW IF NOT EXISTS review_queue AS
SELECT id, title, description, priority, lint_result, build_result, review_note, assigned_to
FROM tasks
WHERE column = 'review'
  AND group_id IS NULL
ORDER BY priority DESC, updated_at ASC;

-- View: ungrouped tasks awaiting QA
CREATE VIEW IF NOT EXISTS qa_queue AS
SELECT id, title, description, priority, review_note, assigned_to
FROM tasks
WHERE column = 'qa'
  AND group_id IS NULL
ORDER BY priority DESC, updated_at ASC;

-- ─── Shared views ─────────────────────────────────────────────────────────────

-- View: tasks requiring main session attention (all tasks, grouped or not)
CREATE VIEW IF NOT EXISTS needs_attention AS
SELECT id, title, column, review_note, priority, group_id, updated_at
FROM tasks
WHERE column IN ('error', 'need_verify')
ORDER BY priority DESC, updated_at ASC;

-- View: open edge cases
CREATE VIEW IF NOT EXISTS open_edge_cases AS
SELECT id, title, description, priority, related_task_id, resolution
FROM edge_cases
WHERE status != 'resolved'
ORDER BY priority DESC, created_at ASC;

-- Comments (task-scoped, operational notes from implementer/reviewer/qa)
CREATE TABLE IF NOT EXISTS comments (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id         INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
    author          TEXT    NOT NULL,
    body            TEXT    NOT NULL,
    ref_type        TEXT    CHECK(ref_type IN ('edge_case', 'agent_memory', 'advisory', NULL)),
    ref_id          TEXT,
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- View: comments with resolved ref labels
CREATE VIEW IF NOT EXISTS comments_with_refs AS
SELECT
    c.id,
    c.task_id,
    t.title          AS task_title,
    t.column         AS task_column,
    c.author,
    c.body,
    c.ref_type,
    c.ref_id,
    CASE c.ref_type
        WHEN 'edge_case'    THEN (SELECT '[EC#' || e.id || '] ' || e.title FROM edge_cases e WHERE e.id = CAST(c.ref_id AS INTEGER))
        WHEN 'agent_memory' THEN (SELECT '[MEM:' || m.agent_name || '] ' || SUBSTR(m.summary, 1, 80) FROM agent_memory m WHERE m.agent_name = c.ref_id)
        WHEN 'advisory'     THEN (SELECT '[ADV#' || a.id || '] ' || SUBSTR(a.title, 1, 80) FROM advisories a WHERE a.id = CAST(c.ref_id AS INTEGER))
        ELSE NULL
        END              AS ref_label,
    c.created_at
FROM comments c
         JOIN tasks t ON t.id = c.task_id
ORDER BY c.created_at ASC;

-- Overseer technical advisories
CREATE TABLE IF NOT EXISTS advisories (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    title           TEXT    NOT NULL,
    body            TEXT    NOT NULL,
    scope           TEXT    NOT NULL DEFAULT 'board'
                    CHECK(scope IN ('board', 'task')),
    task_id         INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
    status          TEXT    NOT NULL DEFAULT 'open'
                    CHECK(status IN ('open', 'accepted', 'rejected', 'deferred')),
    planner_note    TEXT,
    related_edge_case_ids TEXT,
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP,
    updated_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- Trigger: stamp updated_at on advisory status change
CREATE TRIGGER IF NOT EXISTS log_advisory_status_change
AFTER UPDATE OF status ON advisories
BEGIN
    UPDATE advisories SET updated_at = CURRENT_TIMESTAMP WHERE id = NEW.id;
END;

-- View: open advisories for planner to review at session start
CREATE VIEW IF NOT EXISTS open_advisories AS
SELECT
    a.id,
    a.title,
    a.body,
    a.scope,
    a.task_id,
    t.title          AS task_title,
    a.related_edge_case_ids,
    a.created_at
FROM advisories a
         LEFT JOIN tasks t ON t.id = a.task_id
WHERE a.status = 'open'
ORDER BY a.created_at ASC;
