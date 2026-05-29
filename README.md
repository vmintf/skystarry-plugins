# skystarry-plugins

Claude Code plugin marketplace by [minsung@skystarry.xyz](mailto:minsung@skystarry.xyz).

## Adding this marketplace

```
/plugin marketplace add https://github.com/vmintf/skystarry-plugins
```

## Available plugins

### kanban-agent

SQLite-backed kanban board for multi-agent workflows. Planner, implementer, reviewer, QA, and overseer subagents coordinate via a shared SQLite DB. Parallel implementers each run in isolated git worktrees. QA validates through execution and screenshots only — no source code access.

**Install:**

```
/plugin install kanban-agent@skystarry-plugins
```

**What it includes:**

- `/kanban-agent:init` — initialise the board in the current project
- `/kanban-agent:status` — display the current board state, active worktrees, and agent memory
- `@kanban-planner` — analyses the project, creates tasks in `draft`, reviews overseer advisories
- `@kanban-implementer` — claims tasks concurrency-safely, implements in an isolated git worktree, hands off to reviewer
- `@kanban-reviewer` — reviews code changes in the implementer's worktree, passes to QA or returns to implementer
- `@kanban-qa` — validates features through execution and screenshots; the only agent that can move tasks to `done`
- `@kanban-overseer` — diagnoses systemic issues across the full board; read-only, writes advisories only
- `kanban-core` skill — shared DB path resolution, SQL patterns, concurrency rules, and memory conventions for all agents
- `PostToolUse` hook — injects board state updates into the active agent's context automatically

**Typical workflow:**

```
/kanban-agent:init          # set up the board
/kanban-agent:status        # check board state at any time
@kanban-planner             # plan tasks for the current milestone
@kanban-implementer         # implement in a dedicated worktree (run multiple in parallel)
@kanban-reviewer            # review code changes
@kanban-qa                  # validate through execution; moves task to done
@kanban-overseer            # diagnose if tasks are cycling or edge cases are accumulating
```

**Pipeline:**

```
draft → in_progress → review → qa → done
                    ↘ error ↗      ↘ error
                    need_verify     need_verify
```

**Parallel execution (Dynamic Workflows):**

Multiple `@kanban-implementer` instances can run simultaneously. Each gets its own git worktree (`.worktrees/task-{id}`) and writes task-scoped memory (`implementer#task-{id}`) alongside shared role memory (`implementer`). The shared SQLite DB coordinates all agents via `BEGIN IMMEDIATE` transactions.

**Supported platforms:**
- Linux
- macOS
- Windows Subsystem for Linux (WSL)

**Requirements:**

- `sqlite3` available on `PATH`
- `git` 2.5+ (for worktree support)

## Author

minsung — [minsung@skystarry.xyz](mailto:minsung@skystarry.xyz)

## License
MIT
