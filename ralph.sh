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
#   --glab                      Use GitLab issues via glab CLI
#   --milestone NAME            Filter issues by milestone (glab/gh)
#   --gh                        Use GitHub issues via gh CLI
#   -d, --debug                 Show Claude output in real-time
#   -h, --help                  Show this help message
#
# Exit codes: 0=complete, 1=max iterations, 2=config error, 3=usage/rate limit
# Completion: Exits when output contains <promise>COMPLETE</promise>
#
# Examples:
#   ralph                     # auto-discovery via bd ready
#   ralph -b EPIC-001         # work children of EPIC-001
#   ralph -p plan.md          # work from a plan file
#   ralph --prd prd.json      # work from a PRD file
#   ralph --glab              # work from GitLab issues
#   ralph --gh                # work from GitHub issues
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
ISSUES_CLI=""
MILESTONE=""
SETTINGS_FILE=".claude/settings.local.json"
COMPLETION_SIGNAL="<promise>COMPLETE</promise>"
DEBUG=false

# Discovery state (issues mode)
DRAFT_MR_IID=""
DRAFT_MR_TITLE=""
DRAFT_MR_BRANCH=""
DRAFT_MR_DESC=""
ELIGIBLE_ISSUES=""
ISSUES_SOURCE=""  # "assigned" or "unassigned"
ISSUES_HAS_WORK=false

# Detect usage/rate limit errors in Claude CLI output
# Prints error description to stdout and returns 0 if a limit error is detected
# Returns 1 if no error found
detect_limit_error() {
    local output="$1"

    # Subscription usage limit (fatal - wait hours for reset)
    if echo "$output" | grep -qi "usage limit reached"; then
        echo "$output" | grep -i "usage limit reached" | head -1 | sed 's/^[[:space:]]*//'
        return 0
    fi

    # API rate limit error (429)
    if echo "$output" | grep -q "rate_limit_error"; then
        echo "API rate limit error (HTTP 429)"
        return 0
    fi

    # API overloaded after CLI retries exhausted (529)
    if echo "$output" | grep -q "overloaded_error"; then
        echo "API overloaded (HTTP 529)"
        return 0
    fi

    return 1
}

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

# Deterministic task discovery for issues mode (glab/gh)
# Runs CLI commands to find work BEFORE invoking Claude, so if there's
# nothing to do, Claude is never called (saves tokens, deterministic).

# Find draft MRs/PRs assigned to the current user
# Sets DRAFT_MR_* globals on success, returns 1 if none found
discover_draft_mr() {
    local cli="$1"
    local json_output

    if [[ "$cli" == "glab" ]]; then
        json_output=$($cli mr list --assignee @me --draft --output json 2>/dev/null) || return 1
    else
        json_output=$($cli pr list --author @me --draft --json number,title,headRefName,body 2>/dev/null) || return 1
    fi

    local count
    count=$(echo "$json_output" | jq 'length' 2>/dev/null) || return 1
    [[ "$count" == "0" || -z "$count" ]] && return 1

    if [[ "$cli" == "glab" ]]; then
        DRAFT_MR_IID=$(echo "$json_output" | jq -r '.[0].iid')
        DRAFT_MR_TITLE=$(echo "$json_output" | jq -r '.[0].title')
        DRAFT_MR_BRANCH=$(echo "$json_output" | jq -r '.[0].source_branch')
        DRAFT_MR_DESC=$(echo "$json_output" | jq -r '.[0].description // ""')
    else
        DRAFT_MR_IID=$(echo "$json_output" | jq -r '.[0].number')
        DRAFT_MR_TITLE=$(echo "$json_output" | jq -r '.[0].title')
        DRAFT_MR_BRANCH=$(echo "$json_output" | jq -r '.[0].headRefName')
        DRAFT_MR_DESC=$(echo "$json_output" | jq -r '.[0].body // ""')
    fi
    return 0
}

# Find issues that don't already have MRs/PRs
# Args: $1=cli (glab|gh), $2=mode ("me" for assigned to me, "unassigned" for no assignee)
# Sets ELIGIBLE_ISSUES global (JSON array) on success, returns 1 if none found
discover_eligible_issues() {
    local cli="$1"
    local mode="${2:-me}"
    local json_output

    if [[ "$cli" == "glab" ]]; then
        local milestone_args=()
        [[ -n "$MILESTONE" ]] && milestone_args=(--milestone "$MILESTONE")
        if [[ "$mode" == "me" ]]; then
            json_output=$($cli issue list --assignee @me "${milestone_args[@]}" --output json 2>/dev/null) || return 1
        else
            # glab has no "unassigned" filter; fetch all and filter client-side
            json_output=$($cli issue list "${milestone_args[@]}" --output json 2>/dev/null) || return 1
        fi
    else
        local gh_milestone_args=()
        [[ -n "$MILESTONE" ]] && gh_milestone_args=(--milestone "$MILESTONE")
        if [[ "$mode" == "me" ]]; then
            json_output=$($cli issue list --assignee @me "${gh_milestone_args[@]}" --json number,title,body,labels 2>/dev/null) || return 1
        else
            json_output=$($cli issue list --search "no:assignee" "${gh_milestone_args[@]}" --json number,title,body,labels 2>/dev/null) || return 1
        fi
    fi

    local count
    count=$(echo "$json_output" | jq 'length' 2>/dev/null) || return 1
    [[ "$count" == "0" || -z "$count" ]] && return 1

    # glab: filter to unassigned issues client-side (gh handles this via --search)
    if [[ "$mode" == "unassigned" && "$cli" == "glab" ]]; then
        json_output=$(echo "$json_output" | jq '[.[] | select(.assignees | length == 0)]')
        count=$(echo "$json_output" | jq 'length' 2>/dev/null) || return 1
        [[ "$count" == "0" || -z "$count" ]] && return 1
    fi

    if [[ "$cli" == "glab" ]]; then
        # glab provides merge_requests_count — filter to issues with no MR
        ELIGIBLE_ISSUES=$(echo "$json_output" | jq '[.[] | select(.merge_requests_count == 0)]')
    else
        # gh: cross-reference with open PR branch names to filter
        local pr_branches
        pr_branches=$($cli pr list --json headRefName 2>/dev/null | jq -r '.[].headRefName' 2>/dev/null) || pr_branches=""

        if [[ -n "$pr_branches" ]]; then
            # Extract issue numbers from branch names (pattern: <number>-rest-of-name)
            local nums=()
            while IFS= read -r branch; do
                local num="${branch%%-*}"
                [[ "$num" =~ ^[0-9]+$ ]] && nums+=("$num")
            done <<< "$pr_branches"

            if [[ ${#nums[@]} -gt 0 ]]; then
                local nums_csv
                nums_csv=$(IFS=,; echo "${nums[*]}")
                ELIGIBLE_ISSUES=$(echo "$json_output" | jq --argjson exclude "[$nums_csv]" \
                    '[.[] | select((.number | tostring) as $n | $exclude | map(tostring) | index($n) | not)]')
            else
                ELIGIBLE_ISSUES="$json_output"
            fi
        else
            ELIGIBLE_ISSUES="$json_output"
        fi
    fi

    local eligible_count
    eligible_count=$(echo "$ELIGIBLE_ISSUES" | jq 'length' 2>/dev/null) || eligible_count=0
    [[ "$eligible_count" == "0" ]] && return 1
    return 0
}

# Orchestrate task discovery: draft MRs → my issues → unassigned issues
# Sets ISSUES_HAS_WORK=true if work found
discover_issues_work() {
    local cli="$1"
    ISSUES_HAS_WORK=false
    DRAFT_MR_IID=""
    DRAFT_MR_TITLE=""
    DRAFT_MR_BRANCH=""
    DRAFT_MR_DESC=""
    ELIGIBLE_ISSUES=""
    ISSUES_SOURCE=""

    echo "  Discovering work via $cli..."

    # Step 1: Check for in-progress draft MRs (resume work)
    if discover_draft_mr "$cli"; then
        ISSUES_HAS_WORK=true
        echo "  Found draft MR !$DRAFT_MR_IID: $DRAFT_MR_TITLE (branch: $DRAFT_MR_BRANCH)"
        return
    fi

    # Step 2: Check for issues assigned to me (no MR yet)
    if discover_eligible_issues "$cli" "me"; then
        ISSUES_HAS_WORK=true
        ISSUES_SOURCE="assigned"
        local count
        count=$(echo "$ELIGIBLE_ISSUES" | jq 'length')
        echo "  Found $count issue(s) assigned to me"
        return
    fi

    # Step 3: Check for unassigned issues (no MR yet)
    if discover_eligible_issues "$cli" "unassigned"; then
        ISSUES_HAS_WORK=true
        ISSUES_SOURCE="unassigned"
        local count
        count=$(echo "$ELIGIBLE_ISSUES" | jq 'length')
        echo "  Found $count unassigned issue(s)"
        return
    fi

    echo "  No work found"
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
        --glab)
            [[ -z "$ISSUES_CLI" ]] && ISSUES_CLI=glab
            shift
            ;;
        --milestone)
            MILESTONE="$2"
            shift 2
            ;;
        --gh)
            [[ -z "$ISSUES_CLI" ]] && ISSUES_CLI=gh
            shift
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
elif [[ -n "$ISSUES_CLI" ]]; then
    MODE="issues"
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
        prompt+="**Tip**: If a \`bd\` command fails or you are unsure of the syntax, run \`bd --help\` or \`bd <command> --help\` to discover available commands and flags.${nl}${nl}"
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
        prompt+="**Tip**: If a \`bd\` command fails or you are unsure of the syntax, run \`bd --help\` or \`bd <command> --help\` to discover available commands and flags.${nl}${nl}"
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
    elif [[ "$MODE" == "issues" ]]; then
        local cli="$ISSUES_CLI"

        # Build prompt from deterministic discovery results
        if [[ -n "$DRAFT_MR_IID" ]]; then
            # Resume in-progress draft MR
            local mr_view mr_ready
            if [[ "$cli" == "glab" ]]; then
                mr_view="glab mr view"
                mr_ready="glab mr update $DRAFT_MR_IID --ready"
            else
                mr_view="gh pr view"
                mr_ready="gh pr ready $DRAFT_MR_IID"
            fi

            prompt+="You have in-progress work on merge request !${DRAFT_MR_IID}: **${DRAFT_MR_TITLE}**${nl}"
            prompt+="Branch: \`$DRAFT_MR_BRANCH\`${nl}${nl}"
            [[ -n "$DRAFT_MR_DESC" && "$DRAFT_MR_DESC" != "null" ]] && prompt+="MR description:${nl}${DRAFT_MR_DESC}${nl}${nl}"

            prompt+="## Implementation${nl}${nl}"
            prompt+="1. Ensure you are on the correct branch: \`git checkout $DRAFT_MR_BRANCH\`${nl}"
            prompt+="2. Read the MR for full context: \`$mr_view $DRAFT_MR_IID --comments\`${nl}"
            prompt+="3. Implement your solution. Make atomic commits.${nl}${nl}"

            prompt+="## Close-out${nl}${nl}"
            prompt+="1. Ensure all checks and tests pass${nl}"
            prompt+="2. Push your work: \`git push\`${nl}"
            prompt+="3. If the work is complete, mark the MR as ready: \`$mr_ready\`${nl}"
            prompt+="4. Switch back to main: \`git switch main && git pull\`${nl}${nl}"

            prompt+="Do NOT start any other tasks. You are FINISHED after this.${nl}${nl}"

        elif [[ -n "$ELIGIBLE_ISSUES" ]]; then
            # Work on one of the discovered issues
            local issue_view mr_create_hint
            if [[ "$cli" == "glab" ]]; then
                issue_view="glab issue view"
                mr_create_hint="glab mr create --related-issue <iid> --assignee @me --copy-issue-labels --create-source-branch --draft --no-editor --remove-source-branch --squash-before-merge"
            else
                issue_view="gh issue view"
                mr_create_hint="Create a branch (git checkout -b feature/<iid>-<short-description>), then after committing: gh pr create --draft --assignee @me --title \"<title>\" --body \"Closes #<iid>\""
            fi

            if [[ "$ISSUES_SOURCE" == "unassigned" ]]; then
                prompt+="The following unassigned issues are available:${nl}${nl}"
            else
                prompt+="The following issues are assigned to you:${nl}${nl}"
            fi
            local i=0
            local count
            count=$(echo "$ELIGIBLE_ISSUES" | jq 'length')
            while [[ $i -lt $count ]]; do
                local iid title
                if [[ "$cli" == "glab" ]]; then
                    iid=$(echo "$ELIGIBLE_ISSUES" | jq -r ".[$i].iid")
                    title=$(echo "$ELIGIBLE_ISSUES" | jq -r ".[$i].title")
                else
                    iid=$(echo "$ELIGIBLE_ISSUES" | jq -r ".[$i].number")
                    title=$(echo "$ELIGIBLE_ISSUES" | jq -r ".[$i].title")
                fi
                prompt+="- #$iid: $title${nl}"
                i=$((i + 1))
            done

            prompt+="${nl}## Implementation${nl}${nl}"
            prompt+="1. Pick the most suitable issue from the list above${nl}"
            prompt+="2. Read full context: \`$issue_view <iid> --comments\`${nl}"
            local step=3
            if [[ "$ISSUES_SOURCE" == "unassigned" ]]; then
                local assign_hint
                if [[ "$cli" == "glab" ]]; then
                    assign_hint="glab issue update <iid> --assignee @me"
                else
                    assign_hint="gh issue edit <iid> --add-assignee @me"
                fi
                prompt+="$step. Assign the issue to yourself: \`$assign_hint\`${nl}"
                step=$((step + 1))
            fi
            prompt+="$step. Create a draft MR: \`$mr_create_hint\`${nl}"
            step=$((step + 1))
            prompt+="$step. Implement your solution. Make atomic commits.${nl}${nl}"

            prompt+="## Close-out${nl}${nl}"
            prompt+="1. Ensure all checks and tests pass${nl}"
            prompt+="2. Push your work: \`git push -u origin HEAD\`${nl}"
            prompt+="3. Switch back to main: \`git switch main && git pull\`${nl}${nl}"

            prompt+="Do NOT start any other tasks. You are FINISHED after this.${nl}${nl}"
        fi
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
[[ "$MODE" == "issues" ]] && echo "  Mode:              $ISSUES_CLI issues"
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

    # Deterministic discovery for issues mode (before invoking Claude)
    if [[ "$MODE" == "issues" ]]; then
        discover_issues_work "$ISSUES_CLI"
        if [[ "$ISSUES_HAS_WORK" == false ]]; then
            echo ""
            echo "═══════════════════════════════════════════════════════"
            echo "  No work discovered via $ISSUES_CLI - all done!"
            echo "  Finished after $iteration iteration(s)"
            echo "═══════════════════════════════════════════════════════"
            exit 0
        fi

        # For draft MRs, ensure we're on the right branch
        if [[ -n "$DRAFT_MR_BRANCH" ]]; then
            echo "  Switching to branch: $DRAFT_MR_BRANCH"
            git fetch --prune 2>/dev/null || true
            git checkout "$DRAFT_MR_BRANCH" 2>/dev/null || \
                git checkout -b "$DRAFT_MR_BRANCH" "origin/$DRAFT_MR_BRANCH" 2>/dev/null || true
        fi
    fi

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

    # Check for usage/rate limit errors before continuing
    limit_msg=""
    if limit_msg=$(detect_limit_error "$output"); then
        if [[ -n "$PROGRESS_FILE" ]]; then
            {
                echo ""
                echo "### STOPPED (limit error) - $(date)"
                echo "$limit_msg"
            } >> "$PROGRESS_FILE"
        fi

        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "  Ralph stopped: $limit_msg"
        echo "  Occurred during iteration $iteration of $MAX_ITERATIONS"
        echo "═══════════════════════════════════════════════════════"
        exit 3
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
    elif [[ "$MODE" == "issues" ]]; then
        echo ""
        echo "─────────────────────────────────────────────────────────"
        echo "  Issues"
        echo "─────────────────────────────────────────────────────────"
        $ISSUES_CLI issue list 2>/dev/null || true
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
