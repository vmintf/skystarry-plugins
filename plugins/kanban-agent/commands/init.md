# /kanban-agent:init

Sets up the kanban board database and scaffolds example agents for the current project.

## What this command does

1. Creates `.kanban/` directory in the project root
2. Find a `kanban.db` and Initializing the database with the schema.
3. Inserts example tasks and an edge case so agents have something to reference immediately
4. Prints a summary of the board state

### Kanban DB Path
* Claude Code global path: `~/.claude/plugins/marketplaces/skystarry-plugins/plugins/kanban-agent/db/schema.sql`
* Claude Code project path: `.claude/plugins/marketplaces/skystarry-plugins/plugins/kanban-agent/db/schema.sql`

## Steps

### 1. Locate project root

Use the `pwd` of the current session. All paths below are relative to it.

### 2. Create the database

```bash
mkdir -p .kanban
sqlite3 .kanban/kanban.db < "(Kanban DB Path)/db/schema.sql"
```

### 3. Seed example data

```bash
sqlite3 .kanban/kanban.db <<'SQL'
-- Example tasks (highest priority first)
INSERT INTO tasks (title, description, priority, column) VALUES
  ('Define project requirements', 'List all functional requirements before implementation begins.', 10, 'draft'),
  ('Set up CI pipeline',          'Configure GitHub Actions with lint + test steps.',              7,  'draft'),
  ('Write unit tests',            'Cover core logic with at least 80% branch coverage.',           5,  'draft');

-- Example edge case (already resolved, serves as reference)
INSERT INTO edge_cases (title, description, priority, status, resolution) VALUES
  (
    'Concurrent task grab race condition',
    'Two implementer agents tried to move the same draft task to in_progress simultaneously.',
    8,
    'resolved',
    'Wrapped the SELECT + UPDATE in BEGIN IMMEDIATE transaction. First writer wins; second reads the updated column and skips.'
  );

-- Seed agent memory stubs
INSERT INTO agent_memory (agent_name, summary) VALUES
  ('planner',     'No sessions yet.'),
  ('implementer', 'No sessions yet.');
SQL
```

### 4. Register the PostToolUse hook

Append the kanban hook to `.claude/settings.json`. If the file does not exist, create it. If it already has a `PostToolUse` array, merge into it without overwriting existing hooks.

```bash
python3 - <<'PY'
import json, os, sys

path = ".claude/settings.json"
hook = {
    "matcher": "Bash",
    "hooks": [
        {
            "type": "command",
            "command": "input=$(cat); echo \"$input\" | grep -q '.kanban/kanban.db' && { ctx=$(sqlite3 -column -header .kanban/kanban.db 'SELECT changed_at, table_name, record_id, field, old_value, new_value, changed_by FROM change_log ORDER BY changed_at DESC LIMIT 5;' 2>/dev/null); python3 -c 'import json,sys; print(json.dumps({\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUse\",\"additionalContext\":sys.argv[1]}}))' \"$ctx\"; } 2>/dev/null || true"
        }
    ]
}

settings = {}
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)

hooks = settings.setdefault("hooks", {})
post = hooks.setdefault("PostToolUse", [])

# skip if already registered
already = any(
    any(h.get("command", "").find("kanban/kanban.db") != -1 for h in entry.get("hooks", []))
    for entry in post
)
if not already:
    post.append(hook)
    os.makedirs(".claude", exist_ok=True)
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
    print("Hook registered in", path)
else:
    print("Hook already present — skipped")
PY
```

### 5. Confirm setup

```bash
echo "=== Tasks ===" && sqlite3 -column -header .kanban/kanban.db "SELECT id, title, priority, column FROM tasks;"
echo ""
echo "=== Edge Cases ===" && sqlite3 -column -header .kanban/kanban.db "SELECT id, title, priority, status FROM edge_cases;"
```

### 6. Done

Tell the user:
- Database is at `.kanban/kanban.db`
- Add `.kanban/` to `.gitignore` if the board is local-only, or commit it if the team shares state
- Run `/kanban-agent:status` at any time to see the current board
- Agents reference `skills/planner/SKILL.md` and `skills/implementer/SKILL.md` for their operating instructions
