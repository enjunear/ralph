# BEADS PARENT MODE

You are working on the tasks in beads issue $BEADS_ISSUE.

- Use `bd show $BEADS_ISSUE` to read full task context before starting
- Pick your task:
  - Check for any in-progress tasks using `bd list --parent $BEADS_ISSUE --status in_progress`
  - If there is an in-progress task, continue it.
  - If there are no tasks in progress, find one using: `bd ready --parent $BEADS_ISSUE`
  - Claim the task: `bd update <id> --status in_progress`
- Make atomic commits as you complete work
- Document your work, including challenges and key decisions with `bd update <id> --notes "..."`
- When you have completed the task, use `bd close <id>`

STOP work, do not progress with any other tasks.

## Completion

If there are no more tasks to work on (`bd ready --parent $BEADS_ISSUE` returns nothing), mark $BEADS_ISSUE as ready for review.
`bd close $BEADS_ISSUE --reason "Ready for review"`
`bd pin $BEADS_ISSUE --for code-review`

Only when ALL tasks are done (`bd ready` returns nothing), output `<promise>COMPLETE</promise>`.


# BEADS AUTO MODE

You are working on the beads issues.

- Use `bd list --limit 0` to read full task context before starting
- Pick your task:
  - Check for any in-progress tasks using `bd list --status in_progress`
  - If there is an in-progress task, continue it.
  - If there are no tasks in progress, find one using: `bd ready`
  - Claim the task: `bd update <id> --status in_progress`
- Make atomic commits as you complete work
- Document your work, including challenges and key decisions with `bd update <id> --notes "..."`
- When you have completed the task, use `bd close <id>`

STOP work, do not progress with any other tasks.

## Completion

Only when ALL tasks are done (`bd ready` returns nothing), output `<promise>COMPLETE</promise>`.

# PLAN MODE

You are working through the plan.

- Read `@$PLAN` for the full plan
- Read `progress.txt` to see what has been completed
- Find the next incomplete task in the plan
- Make atomic commits as you complete work
- Log to `progress.txt`: task completed, key decisions, files changed

STOP work, do not progress with any other tasks.

## Completion

Only when ALL tasks in the plan are done, output `<promise>COMPLETE</promise>`.


# PRD MODE

You are working through the PRD.

- Read `@$PRD` for the full project requirements
- Read `progress.txt` to see what has been completed
- Find the next incomplete task in the PRD where `passing:false`
- Make atomic commits as you complete work
- Log to `progress.txt`: task completed, key decisions, files changed
- When the requirement is fulfilled, set `passing: true` for that requirement.

STOP work, do not progress with any other tasks.

## Completion

Only when ALL tasks in the PRD are done, output `<promise>COMPLETE</promise>`.