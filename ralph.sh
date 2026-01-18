#!/usr/bin/env bash
#
# ralph.sh - Run Claude in a loop with iteration limit and completion detection
#
# Usage: ./ralph.sh [OPTIONS]
#   -i, --max-iterations N    Maximum number of iterations (default: 10)
#   -b, --branch NAME         Branch/worktree to run in (.worktree/<branch>)
#   -f, --prompt-file FILE    Prompt file to use (default: prompt.md)
#   -s, --settings FILE       Path to Claude settings JSON file for permissions
#   -c, --config FILE         Config file with branch info (default: prd.json)
#   -h, --help                Show this help message
#
# Worktree detection order:
#   1. -b/--branch argument
#   2. Config file (prd.json) branchName field
#   3. Current directory (assumes already in correct location)
#
# Completion: Exits when output contains <promise>COMPLETE</promise>
#
# Example:
#   ./ralph.sh -b feature/my-branch -i 5
#   ./ralph.sh --max-iterations 20
#

set -euo pipefail

# Script directory (for finding config files)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
MAX_ITERATIONS=10
BRANCH=""
PROMPT_FILE="prompt.md"
SETTINGS_FILE=".claude/settings.local.json"
CONFIG_FILE="prd.json"
COMPLETION_SIGNAL="<promise>COMPLETE</promise>"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        -b|--branch)
            BRANCH="$2"
            shift 2
            ;;
        -f|--prompt-file)
            PROMPT_FILE="$2"
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

# Validate max iterations is a positive integer
if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$MAX_ITERATIONS" -lt 1 ]]; then
    echo "Error: max-iterations must be a positive integer" >&2
    exit 1
fi

# Determine working directory (worktree detection)
WORK_DIR=""

# 1. Check -b/--branch argument
if [[ -n "$BRANCH" ]]; then
    WORKTREE_PATH="$SCRIPT_DIR/.worktree/$BRANCH"
    if [[ -d "$WORKTREE_PATH" ]]; then
        WORK_DIR="$WORKTREE_PATH"
        echo "Using worktree from --branch: $WORK_DIR"
    else
        echo "Error: Worktree not found at $WORKTREE_PATH" >&2
        exit 1
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

# Resolve prompt file path (relative to work dir or absolute)
if [[ ! "$PROMPT_FILE" = /* ]]; then
    # Check work dir first, then script dir
    if [[ -f "$WORK_DIR/$PROMPT_FILE" ]]; then
        PROMPT_FILE="$WORK_DIR/$PROMPT_FILE"
    elif [[ -f "$SCRIPT_DIR/$PROMPT_FILE" ]]; then
        PROMPT_FILE="$SCRIPT_DIR/$PROMPT_FILE"
    fi
fi

# Validate prompt file exists
if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: Prompt file '$PROMPT_FILE' not found" >&2
    exit 1
fi

# Resolve settings file path (relative to work dir or absolute)
if [[ ! "$SETTINGS_FILE" = /* ]]; then
    # Check work dir first, then script dir
    if [[ -f "$WORK_DIR/$SETTINGS_FILE" ]]; then
        SETTINGS_FILE="$WORK_DIR/$SETTINGS_FILE"
    elif [[ -f "$SCRIPT_DIR/$SETTINGS_FILE" ]]; then
        SETTINGS_FILE="$SCRIPT_DIR/$SETTINGS_FILE"
    fi
fi

# Validate settings file exists
if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo "Error: Settings file '$SETTINGS_FILE' not found" >&2
    exit 1
fi

# Initialize progress file in worktree
PROGRESS_FILE="$WORK_DIR/progress.txt"
if [[ ! -f "$PROGRESS_FILE" ]]; then
    echo "# Ralph Progress Log" > "$PROGRESS_FILE"
    echo "Started: $(date)" >> "$PROGRESS_FILE"
    echo "Branch: ${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')}" >> "$PROGRESS_FILE"
    echo "---" >> "$PROGRESS_FILE"
fi

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Starting Ralph Loop"
echo "═══════════════════════════════════════════════════════"
echo "  Max iterations: $MAX_ITERATIONS"
echo "  Working dir:    $WORK_DIR"
echo "  Prompt file:    $PROMPT_FILE"
echo "  Progress file:  $PROGRESS_FILE"
echo "  Settings file:  $SETTINGS_FILE"
echo "  Completion:     $COMPLETION_SIGNAL"
echo "═══════════════════════════════════════════════════════"
echo ""

iteration=0
while [[ $iteration -lt $MAX_ITERATIONS ]]; do
    iteration=$((iteration + 1))
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Iteration $iteration of $MAX_ITERATIONS"
    echo "═══════════════════════════════════════════════════════"

    # Log iteration start to progress file
    echo "" >> "$PROGRESS_FILE"
    echo "### Iteration $iteration - $(date)" >> "$PROGRESS_FILE"

    # Build Claude command
    CLAUDE_ARGS=("-p" "$(cat "$PROMPT_FILE")")
    [[ -n "$SETTINGS_FILE" ]] && CLAUDE_ARGS=("--settings" "$SETTINGS_FILE" "${CLAUDE_ARGS[@]}")

    # Run Claude and capture output (tee to show live output)
    output=$(claude "${CLAUDE_ARGS[@]}" 2>&1 | tee /dev/stderr) || true

    # Check for completion signal
    if echo "$output" | grep -qF "$COMPLETION_SIGNAL"; then
        echo "" >> "$PROGRESS_FILE"
        echo "### COMPLETED - $(date)" >> "$PROGRESS_FILE"
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "  Ralph completed! Detected: $COMPLETION_SIGNAL"
        echo "  Finished after $iteration iteration(s)"
        echo "═══════════════════════════════════════════════════════"
        exit 0
    fi

    echo "Iteration $iteration complete. Continuing..."
    sleep 2
done

echo "" >> "$PROGRESS_FILE"
echo "### MAX ITERATIONS REACHED - $(date)" >> "$PROGRESS_FILE"
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Ralph reached max iterations ($MAX_ITERATIONS)"
echo "  Check $PROGRESS_FILE for status"
echo "═══════════════════════════════════════════════════════"
exit 1
