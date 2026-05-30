# kanban-agent

A kanban board for Claude Code — where your AI agents actually work as a team.

---

## What this is

Most AI coding sessions are one-on-one: you ask, Claude does, repeat. That works for small things. For anything bigger — a feature, a refactor, a whole milestone — it breaks down. You end up managing context, re-explaining decisions, and serializing work that could happen in parallel.

`kanban-agent` is a different approach. It gives Claude Code a shared board backed by a local SQLite database. Multiple agents — planner, implementer, reviewer, QA, overseer — coordinate through that board. Each one has a defined role and a clear boundary. Work flows from task to task, stage to stage, without you having to hold it all together.

You set the direction. The agents handle the execution.

---

## Getting started

**1. Install the plugin:**

```
/plugin install kanban-agent@skystarry-plugins
```

**2. Initialize the board in your project:**

```
/kanban-agent:init
```

This creates a `.kanban/kanban.db` file in your project root and seeds the board with example tasks so you can see it working immediately.

**3. Check the board at any time:**

```
/kanban-agent:status
```

---

## The agents

### `@kanban-planner`

The planner thinks before anyone codes. It reads your project, understands what exists, and breaks the milestone into tasks that are actually implementable — specific enough to act on, independent enough to parallelize. It also watches for strategic advisories from the overseer and decides whether to act on them.

Invoke when: you have a new feature or milestone to plan, the task queue is empty, or an implementer has surfaced a blocker that needs replanning.

### `@kanban-implementer`

The implementer claims one task, creates an isolated git worktree for it, writes the code, runs lint and build checks, then hands off to the reviewer. It never touches another agent's work. You can run several implementers at once — each gets its own branch, its own task, its own context.

Invoke when: there are tasks in draft. Run multiple instances in parallel to move faster.

### `@kanban-reviewer`

The reviewer reads the code diff in the implementer's worktree. It checks correctness, consistency with the rest of the project, and whether the acceptance criteria are met. If it passes, the task moves to QA. If not, it goes back to the implementer with specific notes.

Invoke when: tasks are sitting in the review column.

### `@kanban-qa`

QA does one thing: run the code and see if it works. It doesn't read source files. It starts the application, interacts with it, takes screenshots if needed, and validates the behavior against the task description. It's the only agent that can move a task to `done`.

Invoke when: tasks are in the QA column and ready to validate.

### `@kanban-overseer`

The overseer is a diagnostic agent. It reads the entire board — every task, every agent memory, every edge case, every change — and looks for patterns that individual agents can't see from their own vantage point. Cycling tasks. Recurring failures. Architectural decisions that are quietly blocking three other things. It writes advisories; the planner decides what to do with them.

Invoke when: tasks are cycling, things feel stuck, or you want a systemic diagnosis before continuing.

---

## How work flows

```
draft → in_progress → review → qa → done
                    ↘ error ↗      ↘ error
                    need_verify     need_verify
```

Tasks move forward through defined stages. They can go back to `error` if review or QA finds a problem. They land in `need_verify` when something ambiguous needs a human or planner decision. Only QA can declare something done.

---

## Parallel execution

The most powerful thing about this setup: multiple `@kanban-implementer` instances can run at the same time.

Each one claims its own task using a database transaction that prevents conflicts. Each one works in its own git worktree (`.worktrees/task-{id}`). Each one builds up its own session memory. They don't know about each other — they just work.

When you have a backlog of independent tasks, you don't have to serialize them. Start three implementers. Let them run.

---

## Recommended workflow

```
# First-time board setup
/kanban-agent:init

# At the start of each new session — loads DB structure and rules into context
/kanban-core

# Run agents individually
@kanban-planner             # plan the milestone

@kanban-implementer         # implement — run several at once for parallel work
@kanban-implementer         # press Ctrl+B to background (Ctrl+B twice in tmux)
@kanban-implementer

@kanban-reviewer            # review the code changes

@kanban-qa                  # validate through execution

@kanban-overseer            # diagnose if anything is stuck or cycling
```

Press `Ctrl+B` while an agent is running to move it to the background and start the next one immediately. Use `/tasks` to see all running background agents and their status.

---

## Requirements

- `sqlite3` available on your PATH
- `git` 2.5 or later (for worktree support)
- Linux, macOS, or Windows Subsystem for Linux (WSL)

---

## Author

minsung — [minsung@skystarry.xyz](mailto:minsung@skystarry.xyz)

## License

MIT
