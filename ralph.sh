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

# Core instructions for beads mode (hardcoded for homebrew deployment)
# Note: BEADS_COMPLETION_SIGNAL is set dynamically in build_prompt based on parent vs auto mode
RALPH_BEADS_INSTRUCTIONS='## Instructions

### Workflow
1. **Find your task** - `bd list --status in_progress` first, then `bd ready`
2. **Read it** - `bd show <id>` for full context
3. **Claim it** - `bd update <id> --status in_progress`
4. **Do the work** - make atomic commits
5. **Document and close** - `bd update <id> --notes "Summary of work done"` then `bd close <id>`
6. **Stop** - do not continue to the next task

Work ONE task, then stop.'

# Core instructions for plan file mode (non-beads)
RALPH_PLAN_INSTRUCTIONS='## Instructions

**Read progress.txt first** - see what is done, skip re-exploration.

### Workflow
1. **Find your task** - read progress.txt, find the next incomplete step
2. **Do the work** - make atomic commits
3. **Log to progress.txt** - task, decisions, files changed
4. **Stop** - do not continue to the next task

Work ONE task, then stop.

### Completion Signal
Only when ALL tasks in the plan are done, output `<promise>COMPLETE</promise>`.

**CRITICAL**: The signal means ALL work is finished. Do NOT output it prematurely.'

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

# 2. Check config file for branchName
if [[ -z "$WORK_DIR" ]] && [[ -f "$SCRIPT_DIR/$CONFIG_FILE" ]]; then
    BRANCH_FROM_CONFIG=$(jq -r '.branchName // empty' "$SCRIPT_DIR/$CONFIG_FILE" 2>/dev/null || echo "")
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
# Security: Uses printf '%s' to avoid interpreting escape sequences in user content (MEDIUM-2)
build_prompt() {
    local prompt=""
    local nl=$'\n'

    # 1. User's plan/prompt (if provided)
    if [[ -n "$PROMPT_FILE" ]]; then
        prompt+="$(cat "$PROMPT_FILE")"
        prompt+="${nl}${nl}"
    fi

    # 2. Beads context (use bd CLI, not /beads skills - skills unavailable in -p mode)
    if [[ "$BEADS_MODE" == "parent" ]]; then
        prompt+="## Beads Workflow (parent: $BEADS_ISSUE)${nl}${nl}"
        prompt+="1. \`bd list --status in_progress --parent $BEADS_ISSUE\` - finish in-progress first${nl}"
        prompt+="2. \`bd ready --parent $BEADS_ISSUE\` - if none, pick next unblocked task${nl}"
        prompt+="3. \`bd show <id>\` -> \`bd update <id> --status in_progress\` -> work -> \`bd update <id> --notes \"...\"\` -> \`bd close <id>\`${nl}${nl}"
        prompt+="Work ONE task, then stop.${nl}${nl}"
        prompt+="### Completion Signal${nl}"
        prompt+="Only when ALL tasks under $BEADS_ISSUE are done: \`bd close $BEADS_ISSUE\`, then output \`<promise>COMPLETE</promise>\`.${nl}${nl}"
    elif [[ "$BEADS_MODE" == "auto" ]]; then
        prompt+="## Beads Workflow${nl}${nl}"
        prompt+="1. \`bd list --status in_progress\` - finish in-progress first${nl}"
        prompt+="2. \`bd ready\` - if none, pick next unblocked task${nl}"
        prompt+="3. \`bd show <id>\` -> \`bd update <id> --status in_progress\` -> work -> \`bd update <id> --notes \"...\"\` -> \`bd close <id>\`${nl}${nl}"
        prompt+="Work ONE task, then stop.${nl}${nl}"
        prompt+="### Completion Signal${nl}"
        prompt+="Only when ALL tasks are done (\`bd ready\` returns nothing), output \`<promise>COMPLETE</promise>\`.${nl}${nl}"
    fi

    # 3. Ralph instructions (custom file overwrites defaults, otherwise mode-specific)
    if [[ -n "$RALPH_INSTRUCTIONS_FILE" ]]; then
        prompt+="$(cat "$RALPH_INSTRUCTIONS_FILE")"
        prompt+="${nl}"
    elif [[ -n "$BEADS_MODE" ]]; then
        prompt+="$RALPH_BEADS_INSTRUCTIONS"
        prompt+="${nl}${nl}"
    else
        prompt+="$RALPH_PLAN_INSTRUCTIONS"
        prompt+="${nl}${nl}"
    fi

    printf '%s\n' "$prompt"
}

# Initialize progress file (non-beads mode only - beads uses bd notes for tracking)
PROGRESS_FILE=""
if [[ -z "$BEADS_MODE" ]]; then
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

    # Log iteration start (non-beads mode only)
    if [[ -n "$PROGRESS_FILE" ]]; then
        {
            echo ""
            echo "### Iteration $iteration - $(date)"
        } >> "$PROGRESS_FILE"
    fi

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

    # Show beads progress after each iteration
    if [[ -n "$BEADS_MODE" ]]; then
        echo ""
        echo "─────────────────────────────────────────────────────────"
        echo "  Beads Status"
        echo "─────────────────────────────────────────────────────────"
        if [[ "$BEADS_MODE" == "parent" ]]; then
            bd list --pretty --parent "$BEADS_ISSUE" --limit 0 2>/dev/null || true
        elif [[ "$BEADS_MODE" == "auto" ]]; then
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
