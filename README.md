# Ralph

Based on Geoffrey Huntley's [Ralph](https://ghuntley.com/ralph/) pattern.

**Ralph** is an agentic coding loop that runs Claude iteratively until a task is complete. It's designed to work through complex, multi-step development tasks autonomously, with first-class support for the [beads](https://github.com/steveyegge/beads) issue tracking system.

## Features

- **Iterative execution** - Runs Claude in a loop until completion or max iterations
- **Beads integration** - Pass an epic or parent issue, and Ralph works through blocking/child tasks automatically
- **Completion detection** - Exits when Claude signals `<promise>COMPLETE</promise>`
- **Progress tracking** - Maintains logs in beads issues or `progress.txt`
- **Worktree support** - Run isolated work in git worktrees
- **Configurable prompts** - Inject custom instructions alongside your plan

## Installation

```bash
git clone https://github.com/enjunear/ralph.git
cd ralph
chmod +x ralph.sh
ln -s "$(pwd)/ralph.sh" /usr/local/bin/ralph
```

## Quick Start

### With Beads (recommended)

In a beads-initialized repo, just run:

```bash
ralph
```

Ralph will find in-progress tasks to finish, then pick the next ready task.

### With Parent Issue

Work through children of an epic or parent issue:

```bash
ralph -b EPIC-001
```

Ralph will find in-progress tasks to finish, then pick the next ready task.

### With Plan File

Use a plan file instead of beads:

```bash
ralph -p plan.md
```

### With PRD File

Work through requirements in a PRD JSON file:

```bash
ralph --prd requirements.json
```

## Usage

```
ralph [OPTIONS]

Options:
  -b, --beads ISSUE_ID        Work children of this epic/parent issue
  -p, --plan FILE             Plan file to work through
  --prd FILE                  PRD JSON file with requirements (default: prd.json if exists)
  -r, --ralph-instructions    Custom instructions file (overwrites defaults)
  -i, --max-iterations N      Maximum iterations (default: 10)
  -w, --worktree NAME         Git worktree to run in (.worktree/<name>)
  -s, --settings FILE         Claude settings JSON for permissions (optional)
  -d, --debug                 Show Claude output in real-time, save logs to .ralph-logs/
  -h, --help                  Show help message
```

## How It Works

### The Loop

1. Ralph determines mode based on arguments (beads-auto, beads-parent, plan, or prd)
2. Builds mode-specific instructions
3. Runs Claude with the combined prompt
4. Checks output for `<promise>COMPLETE</promise>`
5. If not complete, loops back to step 3
6. Exits on completion or max iterations

### Modes

Ralph supports four modes:

| Mode | Triggered By | Description |
|------|--------------|-------------|
| **beads-auto** | No arguments | Auto-discovers tasks via `bd ready` |
| **beads-parent** | `-b ISSUE_ID` | Works children of a specific epic/parent |
| **plan** | `-p FILE` | Works through tasks in a plan file |
| **prd** | `--prd FILE` | Works through requirements in a PRD JSON file |

### Beads Workflow

Each iteration, Claude:

1. **Checks for in-progress tasks** - `bd list --status in_progress` - finish what was started
2. **Finds next ready task** - `bd ready` to pick unblocked work
3. **Works the task** - `bd update <id> --status in_progress`, makes commits
4. **Documents progress** - `bd update <id> --notes "..."` for key decisions
5. **Closes when done** - `bd close <id>` to mark complete
6. **Stops** - One task per iteration

This enables **autonomous multi-session work** - Ralph can work through an entire epic without human intervention.

### Injected Instructions

Ralph injects mode-specific instructions. Here's an example for **plan mode**:

```markdown
You are working through the plan.

- Read `@plan.md` for the full plan
- Read `progress.txt` to see what has been completed
- Find the next incomplete task in the plan
- Make atomic commits as you complete work
- Log to `progress.txt`: task completed, key decisions, files changed

STOP work, do not progress with any other tasks.

## Completion

Only when ALL tasks in the plan are done, output `<promise>COMPLETE</promise>`.
```

For **beads modes**, instructions include `bd` commands for task discovery and status updates. For **PRD mode**, instructions track requirements with `passing: true/false`.

You can overwrite these with `-r/--ralph-instructions` for project-specific rules.

## Configuration

### prd.json (PRD Mode)

When using `--prd`, Ralph works through requirements in a PRD file. Each requirement should have a `passing` field:

```json
{
  "projectName": "my-project",
  "branchName": "feature/epic-001",
  "requirements": [
    { "id": "REQ-001", "description": "User can log in", "passing": false },
    { "id": "REQ-002", "description": "User can log out", "passing": false }
  ]
}
```

The `branchName` field is also used to auto-detect worktrees in `.worktree/<branchName>`.

### Claude Settings (Optional)

Ralph can use Claude's settings file for permissions. Default location: `.claude/settings.local.json`

If not provided, Claude runs with `--permission-mode acceptEdits`.

```json
{
  "permissions": {
    "allow": [
      "Bash(npm run build)",
      "Bash(npm test)",
      "Read",
      "Edit",
      "Write"
    ]
  }
}
```

### Worktrees

Ralph supports git worktrees for isolated work:

```bash
# Create a worktree
git worktree add .worktree/feature-x feature-x

# Run ralph in that worktree
ralph -w feature-x -p plan.md
```

## Examples

### Example 1: Simple Bug Fix

```bash
# Create a plan
cat > fix-bug.md << 'EOF'
Fix the null pointer exception in UserService.java:

1. Add null check before accessing user.getEmail()
2. Add unit test for null user case
3. Run tests to verify fix
EOF

ralph -p fix-bug.md -i 5
```

### Example 2: Working an Epic

```bash
# Initialize beads if not already done
bd init

# Create an epic with child tasks
bd create --title "Add dark mode" --type epic
bd create --title "Add theme context" --parent EPIC-001
bd create --title "Create theme toggle component" --parent EPIC-001 --blocked-by TASK-001
bd create --title "Update all components for theming" --parent EPIC-001 --blocked-by TASK-002

# Let ralph work through it
ralph -b EPIC-001 -i 20
```

### Example 3: With PRD File

```bash
# Create a PRD file with requirements
cat > requirements.json << 'EOF'
{
  "projectName": "auth-feature",
  "branchName": "feature/auth",
  "requirements": [
    { "id": "REQ-001", "description": "User can register with email", "passing": false },
    { "id": "REQ-002", "description": "User can log in with credentials", "passing": false },
    { "id": "REQ-003", "description": "User can reset password", "passing": false }
  ]
}
EOF

ralph --prd requirements.json -i 15
```

### Example 4: With Custom Instructions

```bash
# Create ralph instructions for your project
cat > .ralph-instructions.md << 'EOF'
## Project-Specific Rules

- Always run `pnpm test` after changes (not npm)
- Use conventional commits (feat:, fix:, chore:)
- Update CHANGELOG.md for user-facing changes
- This is a TypeScript project - no `any` types allowed
EOF

ralph -p plan.md -r .ralph-instructions.md
```

### Example 5: Debug Mode

```bash
# Watch Claude work in real-time
ralph -b EPIC-001 -d

# Logs saved to .ralph-logs/ for later review
```

## Progress Tracking

### With Beads

In beads modes, Claude tracks progress directly in beads:

- Sets status to `in_progress` when starting a task
- Documents work with `bd update <id> --notes "..."`
- Sets status to `completed` when task is done via `bd close`
- Moves to next ready task

### With Plan/PRD Files

In plan and PRD modes, Ralph creates and updates `progress.txt`:

```txt
# Ralph Progress Log
Started: 2024-01-15 10:30:00
Branch: feature/epic-001
---

### Iteration 1 - 2024-01-15 10:30:05
Working on: Add theme context
Status: Completed

### Iteration 2 - 2024-01-15 10:32:15
Working on: Create theme toggle component
Status: In progress...
```

## Debug Mode

Use `-d/--debug` to see Claude's output in real-time:

```bash
ralph -p plan.md -d
```

Debug mode:
- Streams Claude's responses as they happen
- Saves full JSON logs to `.ralph-logs/` directory
- Logs are named by session ID or iteration number

## Completion Signal

Ralph watches for this exact string in Claude's output:

```markdown
<promise>COMPLETE</promise>
```

Claude should output this **only** when all tasks in the plan are finished. The injected instructions reinforce this behavior.

## Exit Codes

| Code | Meaning |
| ------ | --------- |
| 0 | Success - completion signal detected |
| 1 | Max iterations reached without completion |
| 2 | Configuration error (missing files, invalid options) |

## Troubleshooting

### Ralph exits immediately

Check that your prompt file exists. If using a settings file, ensure it's valid JSON.

### Max iterations reached

- Increase `-i` for complex tasks
- Break your plan into smaller pieces
- Check if Claude is getting stuck on a particular step

### Beads tasks not progressing

- Run `bd ready` to see what tasks are available
- Check for circular dependencies with `bd blocked`
- Ensure tasks have proper `--blocked-by` relationships

## Philosophy

Ralph is named after the idea of "wrapping" work - it wraps Claude in a loop that enables autonomous, multi-step development. The key principles:

1. **Linearity** - Tasks should form a clear dependency chain
2. **Autonomy** - Minimize human intervention during execution
3. **Observability** - Always know what Ralph is doing via beads/progress logs
4. **Completion** - Clear signals when work is done

## Contributing

Contributions welcome! Please open an issue or PR.

## References

- [Ralph Wiggum as a "software engineer"](https://ghuntley.com/ralph)
- [11 Tips For AI Coding With Ralph Wiggum](https://www.aihero.dev/tips-for-ai-coding-with-ralph-wiggum)
- [snarktank/ralph](https://github.com/snarktank/ralph)

## License

MIT
