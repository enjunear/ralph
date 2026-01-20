#!/usr/bin/env bash
#
# ralph - Agentic coding loop with beads integration
#
# Usage: ralph [OPTIONS]
#   -p, --prompt FILE           Plan/prompt file (required unless -b provided)
#   -b, --beads ISSUE_ID        Beads epic or parent issue to work through
#   -r, --ralph-instructions    Custom instructions file (overwrites defaults)
#   -i, --max-iterations N      Maximum number of iterations (default: 10)
#   -w, --worktree NAME         Git worktree to run in (.worktree/<name>)
#   -s, --settings FILE         Path to Claude settings JSON file
#   -c, --config FILE           Config file with project info (default: prd.json)
#   -d, --debug                 Show Claude output in real-time
#   -h, --help                  Show this help message
#
# Completion: Exits when output contains <promise>COMPLETE</promise>
#
# Examples:
#   ralph                     # auto-discovery via bd ready
#   ralph -b EPIC-001         # work children of EPIC-001
#   ralph -p plan.md          # work from a plan file
#   ralph -b EPIC-001 -i 20   # with iteration limit
#

set -euo pipefail

# Script directory (for finding config files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
MAX_ITERATIONS=10
WORKTREE=""
PROMPT_FILE=""
RALPH_INSTRUCTIONS_FILE=""
BEADS_ISSUE=""
SETTINGS_FILE=".claude/settings.local.json"
CONFIG_FILE="prd.json"
COMPLETION_SIGNAL="<promise>COMPLETE</promise>"
DEBUG=false

# Core ralph instructions (hardcoded for homebrew deployment)
RALPH_CORE_INSTRUCTIONS='## Instructions

**FIRST: Read progress.txt** to see what has been completed. Skip exploration for completed work.

Follow these rules strictly:

1. **Focus on ONE task at a time** - Complete the current task fully, then exit
2. **Use beads for tracking** - If using beads, update status and add comments as you progress
3. **Signal completion correctly** - Output <promise>COMPLETE</promise> ONLY when ALL tasks are finished
4. **Handle blockers gracefully** - If blocked, document why and exit without signaling completion
5. **Commit frequently** - Make atomic commits as you complete logical units of work
6. **Stay focused** - Do not refactor unrelated code or add unrequested features

After completing each task, append to progress.txt:
- Task completed (with issue ID if using beads)
- Key decisions made
- Files changed
- Blockers or notes for next iteration
Keep entries concise. This file helps future iterations skip exploration.

When ALL tasks are done, output:
<promise>COMPLETE</promise>

Do NOT output the completion signal until everything is truly done.'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--prompt)
            PROMPT_FILE="$2"
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
        -c|--config)
            CONFIG_FILE="$2"
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
BEADS_MODE=""
if [[ -n "$BEADS_ISSUE" ]]; then
    BEADS_MODE="parent"
elif [[ -z "$PROMPT_FILE" ]]; then
    # No prompt and no beads issue - use auto-discovery mode
    BEADS_MODE="auto"
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
    WORKTREE_PATH="$SCRIPT_DIR/.worktree/$WORKTREE"
    if [[ -d "$WORKTREE_PATH" ]]; then
        WORK_DIR="$WORKTREE_PATH"
        echo "Using worktree: $WORK_DIR"
    else
        echo "Error: Worktree not found at $WORKTREE_PATH" >&2
        exit 2
    fi
fi

# 2. Check config file for branchName
if [[ -z "$WORK_DIR" ]] && [[ -f "$SCRIPT_DIR/$CONFIG_FILE" ]]; then
    BRANCH_FROM_CONFIG=$(jq -r '.branchName // empty' "$SCRIPT_DIR/$CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$BRANCH_FROM_CONFIG" ]]; then
        WORKTREE_PATH="$SCRIPT_DIR/.worktree/$BRANCH_FROM_CONFIG"
        if [[ -d "$WORKTREE_PATH" ]]; then
            WORK_DIR="$WORKTREE_PATH"
            echo "Using worktree from $CONFIG_FILE: $WORK_DIR"
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

# Resolve prompt file path (if provided)
if [[ -n "$PROMPT_FILE" ]]; then
    if [[ ! "$PROMPT_FILE" = /* ]]; then
        if [[ -f "$WORK_DIR/$PROMPT_FILE" ]]; then
            PROMPT_FILE="$WORK_DIR/$PROMPT_FILE"
        elif [[ -f "$SCRIPT_DIR/$PROMPT_FILE" ]]; then
            PROMPT_FILE="$SCRIPT_DIR/$PROMPT_FILE"
        fi
    fi
    # Validate prompt file exists
    if [[ ! -f "$PROMPT_FILE" ]]; then
        echo "Error: Prompt file '$PROMPT_FILE' not found" >&2
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
build_prompt() {
    local prompt=""

    # 1. User's plan/prompt (if provided)
    if [[ -n "$PROMPT_FILE" ]]; then
        prompt+="$(cat "$PROMPT_FILE")"
        prompt+="\n\n"
    fi

    # 2. Beads context (use bd CLI, not /beads skills - skills unavailable in -p mode)
    if [[ "$BEADS_MODE" == "parent" ]]; then
        prompt+="## Beads Workflow\n\n"
        prompt+="Working on: $BEADS_ISSUE\n\n"
        prompt+="1. Run \`bd list --status in_progress --parent $BEADS_ISSUE\` - finish in-progress tasks first\n"
        prompt+="2. If none, run \`bd ready --parent $BEADS_ISSUE\` to find the next unblocked task\n"
        prompt+="3. Run \`bd show <id>\` to see task details\n"
        prompt+="4. Run \`bd update <id> --status in_progress\` when starting\n"
        prompt+="5. Run \`bd close <id>\` when done\n\n"
        prompt+="Work on ONE task only, then exit.\n\n"
    elif [[ "$BEADS_MODE" == "auto" ]]; then
        prompt+="## Beads Workflow\n\n"
        prompt+="1. Run \`bd list --status in_progress\` - finish in-progress tasks first\n"
        prompt+="2. If none, run \`bd ready\` to find the next unblocked task\n"
        prompt+="3. Run \`bd show <id>\` to see task details\n"
        prompt+="4. Run \`bd update <id> --status in_progress\` when starting\n"
        prompt+="5. Run \`bd close <id>\` when done\n\n"
        prompt+="Work on ONE task only, then exit.\n\n"
    fi

    # 3. Ralph instructions (custom file overwrites defaults)
    if [[ -n "$RALPH_INSTRUCTIONS_FILE" ]]; then
        prompt+="$(cat "$RALPH_INSTRUCTIONS_FILE")"
        prompt+="\n"
    else
        prompt+="$RALPH_CORE_INSTRUCTIONS"
        prompt+="\n\n"
    fi

    echo -e "$prompt"
}

# Initialize progress file
PROGRESS_FILE="$WORK_DIR/progress.txt"
if [[ ! -f "$PROGRESS_FILE" ]]; then
    {
        echo "# Ralph Progress Log"
        echo "Started: $(date)"
        echo "Branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')"
        [[ "$BEADS_MODE" == "parent" ]] && echo "Beads Issue: $BEADS_ISSUE"
        [[ "$BEADS_MODE" == "auto" ]] && echo "Beads Mode: auto-discovery"
        echo "---"
    } > "$PROGRESS_FILE"
fi

# Display startup banner
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Ralph - Agentic Coding Loop"
echo "═══════════════════════════════════════════════════════"
echo "  Max iterations:    $MAX_ITERATIONS"
echo "  Working dir:       $WORK_DIR"
[[ -n "$PROMPT_FILE" ]] && echo "  Prompt file:       $PROMPT_FILE"
[[ "$BEADS_MODE" == "parent" ]] && echo "  Beads mode:        parent ($BEADS_ISSUE)"
[[ "$BEADS_MODE" == "auto" ]] && echo "  Beads mode:        auto-discovery"
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

    # Log iteration start
    {
        echo ""
        echo "### Iteration $iteration - $(date)"
    } >> "$PROGRESS_FILE"

    # Build the combined prompt
    COMBINED_PROMPT=$(build_prompt)

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

    # Check for completion signal
    if echo "$output" | grep -qF "$COMPLETION_SIGNAL"; then
        {
            echo ""
            echo "### COMPLETED - $(date)"
        } >> "$PROGRESS_FILE"

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
{
    echo ""
    echo "### MAX ITERATIONS REACHED - $(date)"
} >> "$PROGRESS_FILE"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Ralph reached max iterations ($MAX_ITERATIONS)"
echo "  Check $PROGRESS_FILE for status"
echo "═══════════════════════════════════════════════════════"
exit 1
