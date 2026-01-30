#!/usr/bin/env bash
#
# ralph - Agentic coding loop with beads integration
#
# Usage: ralph [OPTIONS]
#   -p, --plan FILE             Plan/prompt file (content prepended to instructions)
#   --prd FILE                  PRD JSON file with requirements
#   -b, --beads ISSUE_ID        Beads epic or parent issue to work through
#   -r, --ralph-instructions    Custom instructions file (overwrites defaults)
#   -i, --max-iterations N      Maximum number of iterations (default: 10)
#   -w, --worktree NAME         Git worktree to run in (.worktree/<name>)
#   -s, --settings FILE         Path to Claude settings JSON file
#   -d, --debug                 Show Claude output in real-time
#   -h, --help                  Show this help message
#
# Completion: Exits when output contains <promise>COMPLETE</promise>
#
# Examples:
#   ralph                     # auto-discovery via bd ready
#   ralph -b EPIC-001         # work children of EPIC-001
#   ralph -p plan.md          # work from a plan file
#   ralph --prd prd.json      # work from a PRD file
#   ralph -b EPIC-001 -i 20   # with iteration limit
#

set -euo pipefail

# Script directory (for finding config files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
MAX_ITERATIONS=10
WORKTREE=""
PLAN_FILE=""
PRD_FILE=""
RALPH_INSTRUCTIONS_FILE=""
BEADS_ISSUE=""
SETTINGS_FILE=".claude/settings.local.json"
COMPLETION_SIGNAL="<promise>COMPLETE</promise>"
DEBUG=false

# Security: Validate path doesn't contain traversal sequences
# Returns 0 if safe, 1 if unsafe
validate_path_component() {
    local path="$1"
    local context="$2"

    # Reject empty paths
    if [[ -z "$path" ]]; then
        return 0  # Empty is OK (means not provided)
    fi

    # Reject absolute paths (for relative-only parameters)
    if [[ "$path" == /* ]]; then
        echo "Error: $context must be a relative path, got absolute path" >&2
        return 1
    fi

    # Reject path traversal sequences
    if [[ "$path" == *".."* ]]; then
        echo "Error: $context contains path traversal sequence (..)" >&2
        return 1
    fi

    return 0
}

# Security: Validate resolved path is within expected base directory
validate_path_within_base() {
    local resolved_path="$1"
    local base_dir="$2"
    local context="$3"

    # Use realpath to resolve symlinks and normalize
    local real_resolved real_base
    real_resolved=$(realpath -m "$resolved_path" 2>/dev/null) || {
        echo "Error: Cannot resolve $context path" >&2
        return 1
    }
    real_base=$(realpath -m "$base_dir" 2>/dev/null) || {
        echo "Error: Cannot resolve base directory" >&2
        return 1
    }

    # Check if resolved path starts with base directory
    if [[ "$real_resolved" != "$real_base"* ]]; then
        echo "Error: $context resolves outside expected directory" >&2
        return 1
    fi

    return 0
}

# Core instructions for plan file mode
# Note: PLAN_FILE_PATH is substituted in build_prompt
RALPH_PLAN_INSTRUCTIONS='You are working on ONE task from the plan.

## Pick ONE Task

1. Read `@PLAN_FILE_PATH` for the full plan
2. Read `progress.txt` to see what has been completed
3. Find the next incomplete task in the plan
4. If all tasks are complete, skip to Completion section below

## Complete the Task

Do the work for this ONE task only.

## MANDATORY: Before Moving On

You MUST do these steps IN ORDER after completing the task:

1. **Commit your work**: `git add <files> && git commit -m "..."`
2. **Log to progress.txt**: Append task completed, key decisions, files changed

## STOP - Do Not Continue

Do NOT look for or start another task. You are FINISHED. Exit.

## Completion

Only if ALL tasks in the plan are done (nothing left incomplete):

Output: `<promise>COMPLETE</promise>`'

# Core instructions for PRD file mode
# Note: PRD_FILE_PATH is substituted in build_prompt
RALPH_PRD_INSTRUCTIONS='You are working on ONE item from the PRD.

## Pick ONE Item

1. Read `@PRD_FILE_PATH` for the full project requirements
2. Read `progress.txt` to see what has been completed
3. Find the next item where `passes: false` (may be in `userStories`, `requirements`, or similar array)
4. If all items pass, skip to Completion section below
5. Review the acceptance criteria, steps, or description to understand what needs to be done

## Complete the Item

Do the work for this ONE item only.

## MANDATORY: Before Moving On

You MUST do these steps IN ORDER after completing the item:

1. **Commit your work**: `git add <files> && git commit -m "..."`
2. **Log to progress.txt**: Append item completed, key decisions, files changed
3. **Mark complete**: Set `passes: true` for that item in the PRD file

## STOP - Do Not Continue

Do NOT look for or start another item. You are FINISHED. Exit.

## Completion

Only if ALL items pass (`passes: true` for every item):

Output: `<promise>COMPLETE</promise>`'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--plan)
            PLAN_FILE="$2"
            shift 2
            ;;
        --prd)
            PRD_FILE="$2"
            shift 2
            ;;
        -b|--beads)
            BEADS_ISSUE="$2"
            shift 2
            ;;
        -r|--ralph-instructions)
            RALPH_INSTRUCTIONS_FILE="$2"
            shift 2
            ;;
        -i|--max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        -w|--worktree)
            WORKTREE="$2"
            shift 2
            ;;
        -s|--settings)
            SETTINGS_FILE="$2"
            shift 2
            ;;
        -d|--debug)
            DEBUG=true
            shift
            ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Determine mode based on arguments
MODE=""
if [[ -n "$BEADS_ISSUE" ]]; then
    MODE="beads-parent"
elif [[ -n "$PRD_FILE" ]]; then
    MODE="prd"
elif [[ -n "$PLAN_FILE" ]]; then
    MODE="plan"
else
    # No explicit mode - use beads auto-discovery
    MODE="beads-auto"
fi

# Validate max iterations is a positive integer
if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$MAX_ITERATIONS" -lt 1 ]]; then
    echo "Error: max-iterations must be a positive integer" >&2
    exit 2
fi

# Determine working directory
WORK_DIR=""

# 1. Check -w/--worktree argument
if [[ -n "$WORKTREE" ]]; then
    # Security: Validate worktree name (HIGH-1)
    if ! validate_path_component "$WORKTREE" "worktree name"; then
        exit 2
    fi

    WORKTREE_PATH="$SCRIPT_DIR/.worktree/$WORKTREE"

    # Security: Validate resolved path stays within .worktree directory
    if ! validate_path_within_base "$WORKTREE_PATH" "$SCRIPT_DIR/.worktree" "worktree"; then
        exit 2
    fi

    if [[ -d "$WORKTREE_PATH" ]]; then
        WORK_DIR="$WORKTREE_PATH"
        echo "Using worktree: $WORK_DIR"
    else
        echo "Error: Worktree not found at $WORKTREE_PATH" >&2
        exit 2
    fi
fi

# 2. Check prd.json for branchName (use PRD_FILE if provided, else check for prd.json)
PRD_CONFIG="${PRD_FILE:-$SCRIPT_DIR/prd.json}"
if [[ -z "$WORK_DIR" ]] && [[ -f "$PRD_CONFIG" ]]; then
    BRANCH_FROM_CONFIG=$(jq -r '.branchName // empty' "$PRD_CONFIG" 2>/dev/null || echo "")
    if [[ -n "$BRANCH_FROM_CONFIG" ]]; then
        # Security: Validate branchName from config (MEDIUM-1)
        if ! validate_path_component "$BRANCH_FROM_CONFIG" "branchName in config"; then
            exit 2
        fi

        WORKTREE_PATH="$SCRIPT_DIR/.worktree/$BRANCH_FROM_CONFIG"

        # Security: Validate resolved path stays within .worktree directory
        if ! validate_path_within_base "$WORKTREE_PATH" "$SCRIPT_DIR/.worktree" "branchName worktree"; then
            exit 2
        fi

        if [[ -d "$WORKTREE_PATH" ]]; then
            WORK_DIR="$WORKTREE_PATH"
            echo "Using worktree from prd.json: $WORK_DIR"
        fi
    fi
fi

# 3. Fall back to current directory
if [[ -z "$WORK_DIR" ]]; then
    WORK_DIR="$(pwd)"
    echo "Using current directory: $WORK_DIR"
fi

# Change to working directory
cd "$WORK_DIR"

# Resolve plan file path (if provided)
if [[ -n "$PLAN_FILE" ]]; then
    if [[ ! "$PLAN_FILE" = /* ]]; then
        if [[ -f "$WORK_DIR/$PLAN_FILE" ]]; then
            PLAN_FILE="$WORK_DIR/$PLAN_FILE"
        elif [[ -f "$SCRIPT_DIR/$PLAN_FILE" ]]; then
            PLAN_FILE="$SCRIPT_DIR/$PLAN_FILE"
        fi
    fi
    if [[ ! -f "$PLAN_FILE" ]]; then
        echo "Error: Plan file '$PLAN_FILE' not found" >&2
        exit 2
    fi
fi

# Resolve PRD file path (if provided)
if [[ -n "$PRD_FILE" ]]; then
    if [[ ! "$PRD_FILE" = /* ]]; then
        if [[ -f "$WORK_DIR/$PRD_FILE" ]]; then
            PRD_FILE="$WORK_DIR/$PRD_FILE"
        elif [[ -f "$SCRIPT_DIR/$PRD_FILE" ]]; then
            PRD_FILE="$SCRIPT_DIR/$PRD_FILE"
        fi
    fi
    if [[ ! -f "$PRD_FILE" ]]; then
        echo "Error: PRD file '$PRD_FILE' not found" >&2
        exit 2
    fi
fi

# Resolve ralph instructions file path (if provided)
if [[ -n "$RALPH_INSTRUCTIONS_FILE" ]]; then
    if [[ ! "$RALPH_INSTRUCTIONS_FILE" = /* ]]; then
        if [[ -f "$WORK_DIR/$RALPH_INSTRUCTIONS_FILE" ]]; then
            RALPH_INSTRUCTIONS_FILE="$WORK_DIR/$RALPH_INSTRUCTIONS_FILE"
        elif [[ -f "$SCRIPT_DIR/$RALPH_INSTRUCTIONS_FILE" ]]; then
            RALPH_INSTRUCTIONS_FILE="$SCRIPT_DIR/$RALPH_INSTRUCTIONS_FILE"
        fi
    fi
    if [[ ! -f "$RALPH_INSTRUCTIONS_FILE" ]]; then
        echo "Error: Ralph instructions file '$RALPH_INSTRUCTIONS_FILE' not found" >&2
        exit 2
    fi
fi

# Resolve settings file path (optional)
SETTINGS_RESOLVED=""
if [[ ! "$SETTINGS_FILE" = /* ]]; then
    if [[ -f "$WORK_DIR/$SETTINGS_FILE" ]]; then
        SETTINGS_RESOLVED="$WORK_DIR/$SETTINGS_FILE"
    elif [[ -f "$SCRIPT_DIR/$SETTINGS_FILE" ]]; then
        SETTINGS_RESOLVED="$SCRIPT_DIR/$SETTINGS_FILE"
    fi
elif [[ -f "$SETTINGS_FILE" ]]; then
    SETTINGS_RESOLVED="$SETTINGS_FILE"
fi

# Build the combined prompt
# Security: Uses printf '%s' to avoid interpreting escape sequences in user content (MEDIUM-2)
build_prompt() {
    local prompt=""
    local nl=$'\n'

    # Mode-specific instructions (custom file overwrites defaults)
    if [[ -n "$RALPH_INSTRUCTIONS_FILE" ]]; then
        prompt+="$(cat "$RALPH_INSTRUCTIONS_FILE")"
        prompt+="${nl}"
    elif [[ "$MODE" == "beads-parent" ]]; then
        prompt+="You are working on ONE task from beads issue $BEADS_ISSUE.${nl}${nl}"
        prompt+="## Pick ONE Task${nl}${nl}"
        prompt+="1. Check for any in-progress tasks: \`bd list --parent $BEADS_ISSUE --status in_progress\`${nl}"
        prompt+="2. If there is an in-progress task, continue it${nl}"
        prompt+="3. If no tasks are in progress, find one: \`bd ready --parent $BEADS_ISSUE\`${nl}"
        prompt+="4. If no tasks are ready, skip to Completion section below${nl}"
        prompt+="5. Claim the task: \`bd update <id> --status in_progress\`${nl}"
        prompt+="6. Use \`bd show <id>\` to read full task context${nl}${nl}"
        prompt+="## Complete the Task${nl}${nl}"
        prompt+="Do the work for this ONE task only.${nl}${nl}"
        prompt+="## MANDATORY: Before Closing${nl}${nl}"
        prompt+="You MUST do these steps IN ORDER before closing the task:${nl}${nl}"
        prompt+="1. **Commit your work**: \`git add <files> && git commit -m \"...\"\`${nl}"
        prompt+="2. **Document what you did**: \`bd update <id> --notes \"Brief summary of changes made, key decisions, any issues encountered\"\`${nl}"
        prompt+="3. **Close the task**: \`bd close <id>\`${nl}${nl}"
        prompt+="## STOP - Do Not Continue${nl}${nl}"
        prompt+="Do NOT look for or start another task. You are FINISHED. Exit.${nl}${nl}"
        prompt+="## Completion${nl}${nl}"
        prompt+="Only if there are NO tasks to work on (\`bd ready --parent $BEADS_ISSUE\` returns nothing AND no tasks are in-progress):${nl}${nl}"
        prompt+="1. Close the parent: \`bd close $BEADS_ISSUE --reason \"Ready for review\"\`${nl}"
        prompt+="2. Pin for review: \`bd pin $BEADS_ISSUE --for code-review\`${nl}"
        prompt+="3. Output: \`<promise>COMPLETE</promise>\`${nl}${nl}"
    elif [[ "$MODE" == "beads-auto" ]]; then
        prompt+="You are working on ONE beads task.${nl}${nl}"
        prompt+="## Pick ONE Task${nl}${nl}"
        prompt+="1. Check for any in-progress tasks: \`bd list --status in_progress\`${nl}"
        prompt+="2. If there is an in-progress task, continue it${nl}"
        prompt+="3. If no tasks are in progress, find one: \`bd ready\`${nl}"
        prompt+="4. If no tasks are ready, skip to Completion section below${nl}"
        prompt+="5. Claim the task: \`bd update <id> --status in_progress\`${nl}"
        prompt+="6. Use \`bd show <id>\` to read full task context${nl}${nl}"
        prompt+="## Complete the Task${nl}${nl}"
        prompt+="Do the work for this ONE task only.${nl}${nl}"
        prompt+="## MANDATORY: Before Closing${nl}${nl}"
        prompt+="You MUST do these steps IN ORDER before closing the task:${nl}${nl}"
        prompt+="1. **Commit your work**: \`git add <files> && git commit -m \"...\"\`${nl}"
        prompt+="2. **Document what you did**: \`bd update <id> --notes \"Brief summary of changes made, key decisions, any issues encountered\"\`${nl}"
        prompt+="3. **Close the task**: \`bd close <id>\`${nl}${nl}"
        prompt+="## STOP - Do Not Continue${nl}${nl}"
        prompt+="Do NOT look for or start another task. You are FINISHED. Exit.${nl}${nl}"
        prompt+="## Completion${nl}${nl}"
        prompt+="Only if there are NO tasks to work on (\`bd ready\` returns nothing AND no tasks are in-progress):${nl}${nl}"
        prompt+="Output: \`<promise>COMPLETE</promise>\`${nl}${nl}"
    elif [[ "$MODE" == "prd" ]]; then
        local prd_instructions="${RALPH_PRD_INSTRUCTIONS//PRD_FILE_PATH/$PRD_FILE}"
        prompt+="$prd_instructions"
        prompt+="${nl}${nl}"
    elif [[ "$MODE" == "plan" ]]; then
        local plan_instructions="${RALPH_PLAN_INSTRUCTIONS//PLAN_FILE_PATH/$PLAN_FILE}"
        prompt+="$plan_instructions"
        prompt+="${nl}${nl}"
    fi

    printf '%s\n' "$prompt"
}

# Initialize progress file (plan/prd mode only - beads uses bd notes for tracking)
PROGRESS_FILE=""
if [[ "$MODE" == "plan" || "$MODE" == "prd" ]]; then
    PROGRESS_FILE="$WORK_DIR/progress.txt"
    if [[ ! -f "$PROGRESS_FILE" ]]; then
        {
            echo "# Ralph Progress Log"
            echo "Started: $(date)"
            echo "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
            echo "---"
        } > "$PROGRESS_FILE"
    fi
fi

# Display startup banner
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Ralph - Agentic Coding Loop"
echo "═══════════════════════════════════════════════════════"
echo "  Max iterations:    $MAX_ITERATIONS"
echo "  Working dir:       $WORK_DIR"
[[ "$MODE" == "plan" ]] && echo "  Mode:              plan ($PLAN_FILE)"
[[ "$MODE" == "prd" ]] && echo "  Mode:              prd ($PRD_FILE)"
[[ "$MODE" == "beads-parent" ]] && echo "  Mode:              beads-parent ($BEADS_ISSUE)"
[[ "$MODE" == "beads-auto" ]] && echo "  Mode:              beads-auto"
[[ -n "$RALPH_INSTRUCTIONS_FILE" ]] && echo "  Extra instructions: $RALPH_INSTRUCTIONS_FILE"
[[ -n "$SETTINGS_RESOLVED" ]] && echo "  Settings file:     $SETTINGS_RESOLVED"
echo "  Completion signal: $COMPLETION_SIGNAL"
[[ "$DEBUG" == true ]] && echo "  Debug mode:        enabled"
echo "═══════════════════════════════════════════════════════"
echo ""

# Main loop
iteration=0
while [[ $iteration -lt $MAX_ITERATIONS ]]; do
    iteration=$((iteration + 1))
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Iteration $iteration of $MAX_ITERATIONS"
    echo "═══════════════════════════════════════════════════════"

    # Log iteration start (non-beads mode only)
    if [[ -n "$PROGRESS_FILE" ]]; then
        {
            echo ""
            echo "### Iteration $iteration - $(date)"
        } >> "$PROGRESS_FILE"
    fi

    # Build the combined prompt
    COMBINED_PROMPT=$(build_prompt)

    # Show prompt in debug mode
    if [[ "$DEBUG" == true ]]; then
        echo "─────────────────────────────────────────────────────────"
        echo "  Prompt"
        echo "─────────────────────────────────────────────────────────"
        echo "$COMBINED_PROMPT"
        echo "─────────────────────────────────────────────────────────"
        echo ""
    fi

    # Build Claude command
    CLAUDE_ARGS=("--permission-mode" "acceptEdits" "-p" "$COMBINED_PROMPT")
    [[ -n "$SETTINGS_RESOLVED" ]] && CLAUDE_ARGS=("--settings" "$SETTINGS_RESOLVED" "${CLAUDE_ARGS[@]}")

    # Run Claude and capture output
    if [[ "$DEBUG" == true ]]; then
        # Stream output through jq for pretty printing, save to logs dir
        mkdir -p "$WORK_DIR/.ralph-logs"
        DEBUG_TMP=$(mktemp "$WORK_DIR/.ralph-logs/tmp.XXXXXX")
        claude "${CLAUDE_ARGS[@]}" --verbose --output-format stream-json 2>&1 | tee "$DEBUG_TMP" | \
            jq -r --unbuffered '
                if .type == "assistant" and .message.content then
                    .message.content[] |
                    if .type == "text" then "\n>>> " + .text
                    elif .type == "tool_use" then "\n[tool] " + .name + ": " + (.input | tostring | .[0:200])
                    else empty end
                elif .type == "user" and .message.content then
                    .message.content[] |
                    if .type == "tool_result" then "[result] " + ((.content // "") | tostring | .[0:200])
                    else empty end
                else empty end
            ' 2>/dev/null || true
        output=$(cat "$DEBUG_TMP")
        # Rename to include session_id if we can extract it
        SESSION_ID=$(head -5 "$DEBUG_TMP" | jq -r 'select(.session_id) | .session_id' 2>/dev/null | head -1)
        if [[ -n "$SESSION_ID" ]]; then
            mv "$DEBUG_TMP" "$WORK_DIR/.ralph-logs/${SESSION_ID}.json"
            echo "Debug log: .ralph-logs/${SESSION_ID}.json"
        else
            mv "$DEBUG_TMP" "$WORK_DIR/.ralph-logs/iteration-${iteration}.json"
            echo "Debug log: .ralph-logs/iteration-${iteration}.json"
        fi
    else
        output=$(claude "${CLAUDE_ARGS[@]}" 2>&1) || true
    fi

    # Show beads progress after each iteration (beads modes only)
    if [[ "$MODE" == "beads-parent" || "$MODE" == "beads-auto" ]]; then
        echo ""
        echo "─────────────────────────────────────────────────────────"
        echo "  Beads Status"
        echo "─────────────────────────────────────────────────────────"
        if [[ "$MODE" == "beads-parent" ]]; then
            bd list --pretty --parent "$BEADS_ISSUE" --limit 0 2>/dev/null || true
        else
            bd list --pretty --limit 0 2>/dev/null || true
        fi
    fi

    # Check for completion signal
    if echo "$output" | grep -qF "$COMPLETION_SIGNAL"; then
        if [[ -n "$PROGRESS_FILE" ]]; then
            {
                echo ""
                echo "### COMPLETED - $(date)"
            } >> "$PROGRESS_FILE"
        fi

        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "  Ralph completed!"
        echo "  Detected: $COMPLETION_SIGNAL"
        echo "  Finished after $iteration iteration(s)"
        echo "═══════════════════════════════════════════════════════"
        exit 0
    fi

    echo "Iteration $iteration complete. Continuing..."
    sleep 2
done

# Max iterations reached
if [[ -n "$PROGRESS_FILE" ]]; then
    {
        echo ""
        echo "### MAX ITERATIONS REACHED - $(date)"
    } >> "$PROGRESS_FILE"
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Ralph reached max iterations ($MAX_ITERATIONS)"
if [[ -n "$PROGRESS_FILE" ]]; then
    echo "  Check $PROGRESS_FILE for status"
else
    echo "  Check beads status with: bd list"
fi
echo "═══════════════════════════════════════════════════════"
exit 1
