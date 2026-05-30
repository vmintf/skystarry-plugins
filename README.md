[![Listed on ClaudePluginHub](https://www.claudepluginhub.com/badge/vmintf-kanban-agent-plugins-kanban-agent)](https://www.claudepluginhub.com/plugins/vmintf-kanban-agent-plugins-kanban-agent?ref=badge)

# skystarry-plugins

Claude Code plugin marketplace by [minsung@skystarry.xyz](mailto:minsung@skystarry.xyz).

---

## Adding this marketplace

```
/plugin marketplace add https://github.com/vmintf/skystarry-plugins
```

---

## Available Plugins

### kanban-agent

Your AI team, finally working together.

`kanban-agent` gives Claude Code a shared project board — a kanban — that multiple AI agents can read and write to at the same time, without stepping on each other. You describe what needs to be built, and a team of specialized agents takes it from plan to done: one thinks, one codes, one reviews, one tests, one watches over the whole thing.

No more "do everything yourself in one long conversation." This is async, parallel, and self-coordinating.

**Install:**

```
/plugin install kanban-agent@skystarry-plugins
```

---

**The agents:**

| Agent | What it does |
|---|---|
| `@kanban-planner` | Reads the project, breaks work into tasks, keeps the backlog healthy |
| `@kanban-implementer` | Picks up a task, codes it in its own isolated branch, hands off to review |
| `@kanban-reviewer` | Reads the code changes, approves or sends back with notes |
| `@kanban-qa` | Runs the code, checks the output, and is the only one who can call a task done |
| `@kanban-overseer` | Watches the whole board for patterns — stuck tasks, recurring failures, systemic issues |

Multiple implementers can run at once. Each one works in its own branch so they never conflict.

---

**Commands:**

- `/kanban-agent:init` — set up the board in your project
- `/kanban-agent:status` — see what's happening right now

---

**How work moves:**

```
draft → in_progress → review → qa → done
                    ↘ error ↗      ↘ error
                    need_verify     need_verify
```

Tasks don't skip steps. QA has the final word.

---

**A typical session:**

```
/kanban-agent:init          # one-time setup
@kanban-planner             # "here's the milestone — break it down"
@kanban-implementer         # start coding (run several at once)
@kanban-reviewer            # review what's been built
@kanban-qa                  # run it and confirm it works
@kanban-overseer            # if things feel stuck, ask for a diagnosis
```

---

**Requirements:**

- `sqlite3` on your PATH
- `git` 2.5 or later
- Linux, macOS, or WSL

---

## Author

minsung — [minsung@skystarry.xyz](mailto:minsung@skystarry.xyz)

## License

MIT
