-- kanban-agent schema
-- DB location: {project_root}/.kanban/kanban.db
-- Always reference via absolute path: $KANBAN_DB or $(git rev-parse --show-toplevel)/.kanban/kanban.db
--
-- Worktree layout (parallel implementers):
--   {project_root}/                  ← main worktree (planner, overseer, QA)
--   {project_root}/.worktrees/task-N ← per-task implementer worktree
--   {project_root}/.kanban/kanban.db ← single shared DB across all worktrees
--
-- agent_memory key conventions:
--   'implementer'          → shared role memory (accumulated patterns)
--   'implementer#task-{N}' → per-task session memory (implementer)
--   'reviewer'             → shared role memory
--   'reviewer#task-{N}'    → per-task session memory (parallel reviewer scenario)
--   'qa'                   → shared role memory
--   'qa#task-{N}'          → per-task session memory (parallel QA scenario)
--   'planner', 'overseer'  → single shared memory (these roles are never parallelised per task)
--
-- assigned_to sentinel values:
--   'reviewer'             → review task unclaimed (ready for a reviewer agent to pick up)
--   'reviewer#{N}'         → claimed by reviewer for task N
--   'qa'                   → qa task unclaimed (ready for a QA agent to pick up)
--   'qa#{N}'               → claimed by QA agent for task N

PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

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
    review_note  TEXT,                         -- reviewer comment (filled by reviewer)
    depends_on   TEXT,                         -- comma-separated task IDs this task is blocked by
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

-- View: pending work for implementer (excludes tasks with unresolved dependencies)
CREATE VIEW IF NOT EXISTS pending_tasks AS
SELECT t.id, t.title, t.description, t.priority, t.assigned_to
FROM tasks t
WHERE t.column = 'draft'
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

-- View: blocked tasks (has depends_on and at least one dependency not done)
CREATE VIEW IF NOT EXISTS blocked_tasks AS
SELECT t.id, t.title, t.priority, t.depends_on,
       GROUP_CONCAT(dep.id || ':' || dep.column, ', ') AS blocking_status
FROM tasks t
         JOIN tasks dep ON dep.id IN (
    SELECT CAST(TRIM(value) AS INTEGER)
    FROM json_each('["' || REPLACE(t.depends_on, ',', '","') || '"]')
)
WHERE t.column = 'draft'
  AND t.depends_on IS NOT NULL
  AND dep.column != 'done'
GROUP BY t.id;

-- View: tasks awaiting review
CREATE VIEW IF NOT EXISTS review_queue AS
SELECT id, title, description, priority, lint_result, build_result
FROM tasks
WHERE column = 'review'
ORDER BY priority DESC, updated_at ASC;

-- View: tasks awaiting QA
CREATE VIEW IF NOT EXISTS qa_queue AS
SELECT id, title, description, priority, review_note
FROM tasks
WHERE column = 'qa'
ORDER BY priority DESC, updated_at ASC;

-- View: tasks requiring main session attention
CREATE VIEW IF NOT EXISTS needs_attention AS
SELECT id, title, column, review_note, priority, updated_at
FROM tasks
WHERE column IN ('error', 'need_verify')
ORDER BY priority DESC, updated_at ASC;

-- View: open edge cases
CREATE VIEW IF NOT EXISTS open_edge_cases AS
SELECT id, title, description, priority, related_task_id, resolution
FROM edge_cases
WHERE status != 'resolved'
ORDER BY priority DESC, created_at ASC;

-- Comments (task-scoped, operational notes from implementer/reviewer)
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
-- task_id is nullable: advisories may be board-level (no specific task) or task-scoped
CREATE TABLE IF NOT EXISTS advisories (
                                          id              INTEGER PRIMARY KEY AUTOINCREMENT,
                                          title           TEXT    NOT NULL,
                                          body            TEXT    NOT NULL,
                                          scope           TEXT    NOT NULL DEFAULT 'board'
                                          CHECK(scope IN ('board', 'task')),
    -- board: systemic finding not tied to one task
    -- task:  finding scoped to a specific task (task_id required)
    task_id         INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
    status          TEXT    NOT NULL DEFAULT 'open'
    CHECK(status IN ('open', 'accepted', 'rejected', 'deferred')),
    -- open:     planner has not yet reviewed
    -- accepted: planner incorporated into plan
    -- rejected: planner reviewed and dismissed with reason
    -- deferred: planner acknowledged, will revisit later
    planner_note    TEXT,              -- planner's response when status changes from open
    related_edge_case_ids TEXT,        -- comma-separated edge_case IDs that support this advisory
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