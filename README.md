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

## Usage

```
ralph [OPTIONS]

Options:
  -b, --beads ISSUE_ID        Work children of this epic/parent issue
  -p, --prompt FILE           Plan/prompt file (alternative to beads)
  -r, --ralph-instructions    Custom instructions file (overwrites defaults)
  -i, --max-iterations N      Maximum iterations (default: 10)
  -w, --worktree NAME         Git worktree to run in (.worktree/<name>)
  -s, --settings FILE         Claude settings JSON for permissions (optional)
  -c, --config FILE           Config file with project info (default: prd.json)
  -h, --help                  Show help message
```

## How It Works

### The Loop

1. Ralph builds a prompt (beads workflow or plan file)
2. Injects core instructions (read progress.txt, work one task, signal completion)
3. Runs Claude with the combined prompt
4. Checks output for `<promise>COMPLETE</promise>`
5. If not complete, loops back to step 3
6. Exits on completion or max iterations

### Beads Workflow

Each iteration, Claude:

1. **Checks for in-progress tasks** - `bd list --status in_progress` - finish what was started
2. **Finds next ready task** - `bd ready` to pick unblocked work
3. **Works the task** - `bd update <id> --status in_progress`, makes commits
4. **Closes when done** - `bd close <id>` to mark complete
5. **Exits** - One task per iteration

This enables **autonomous multi-session work** - Ralph can work through an entire epic without human intervention.

### Injected Instructions

Ralph automatically injects these core instructions into every prompt:

```markdown
## Instructions

**FIRST: Read progress.txt** to see what has been completed. Skip exploration for completed work.

1. **Focus on ONE task at a time** - Complete the current task fully, then exit
2. **Use beads for tracking** - If using beads, update status with `bd` commands as you progress
3. **Signal completion correctly** - Output <promise>COMPLETE</promise> ONLY when ALL tasks are finished
4. **Handle blockers gracefully** - If blocked, document why and exit without signaling completion
5. **Commit frequently** - Make atomic commits as you complete logical units of work
6. **Stay focused** - Do not refactor unrelated code or add unrequested features

After completing each task, append to progress.txt:
- Task completed (with issue ID if using beads)
- Key decisions made
- Files changed
- Blockers or notes for next iteration

When ALL tasks are done, output: <promise>COMPLETE</promise>
```

You can overwrite these with `-r/--ralph-instructions` for project-specific rules.

## Configuration

### prd.json

Ralph can read project configuration from `prd.json`:

```json
{
  "projectName": "my-project",
  "branchName": "feature/epic-001",
  "description": "Implement user authentication",
  "beadsEpic": "EPIC-001"
}
```

### Claude Settings (Optional)

Ralph can use Claude's settings file for permissions. Default location: `.claude/settings.local.json`

If not provided, Claude runs with default permissions (interactive approval).

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

### Example 3: With Custom Instructions

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

## Progress Tracking

### With Beads

Ralph updates beads issues automatically:

- Sets status to `in_progress` when starting a task
- Adds comments showing work progress
- Sets status to `completed` when task is done
- Moves to next ready task

### With prd.json

Ralph updates `progress.txt` with iteration logs:

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
