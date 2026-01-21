# Security Review: Ralph

**Reviewed:** 2026-01-21
**Scope:** Full repository security analysis
**Reviewer:** Automated Security Review

## Executive Summary

Ralph is a bash-based agentic coding loop tool that orchestrates Claude (Anthropic's AI) for autonomous development tasks. The codebase is relatively small (~374 lines of bash) with minimal dependencies. Overall, the project demonstrates several good security practices but has areas that warrant attention.

**Risk Level:** Medium
**Critical Issues:** 0
**High Issues:** 2
**Medium Issues:** 4
**Low Issues:** 3
**Informational:** 3

---

## Findings

### HIGH-1: Path Traversal in Worktree Parameter

**Location:** `ralph.sh:133-140`

**Description:** The `-w/--worktree` parameter is used to construct a directory path without sanitization. An attacker could potentially escape the intended `.worktree/` directory.

```bash
WORKTREE_PATH="$SCRIPT_DIR/.worktree/$WORKTREE"
if [[ -d "$WORKTREE_PATH" ]]; then
    WORK_DIR="$WORKTREE_PATH"
```

**Attack Scenario:**
```bash
ralph -w "../../etc" -p plan.md
# Could resolve to /etc if the path exists and is a directory
```

**Mitigation:**
- Validate that `$WORKTREE` does not contain path traversal sequences (`..`, leading `/`)
- Use `realpath` to resolve and verify the final path stays within expected boundaries

---

### HIGH-2: Permissive Claude Execution Mode

**Location:** `ralph.sh:298`

**Description:** Claude is invoked with `--permission-mode acceptEdits` hardcoded, which automatically approves all file edits without user confirmation. This is by design for autonomous operation but creates risk if the prompt or Claude's behavior is compromised.

```bash
CLAUDE_ARGS=("--permission-mode" "acceptEdits" "-p" "$COMBINED_PROMPT")
```

**Risk:**
- Malicious prompts could instruct Claude to modify sensitive files
- No guardrails on what files can be edited
- Combined with the worktree path traversal, this could affect files outside the project

**Mitigation:**
- Consider adding file path allowlists/blocklists
- Document the security implications prominently
- Consider adding a `--safe-mode` option that uses interactive approval

---

### MEDIUM-1: Potential Command Injection via Config File

**Location:** `ralph.sh:145`

**Description:** The `jq` command processes a user-configurable config file. While `jq` itself is safe, the extracted value is used in path construction.

```bash
BRANCH_FROM_CONFIG=$(jq -r '.branchName // empty' "$SCRIPT_DIR/$CONFIG_FILE" 2>/dev/null || echo "")
```

**Risk:** If `prd.json` contains a malicious `branchName` value with path traversal sequences, it could affect worktree resolution.

**Mitigation:** Validate extracted config values before using them in path construction.

---

### MEDIUM-2: Echo -e with User Content

**Location:** `ralph.sh:246`

**Description:** The `build_prompt()` function uses `echo -e` with variable expansion, which interprets escape sequences.

```bash
echo -e "$prompt"
```

**Risk:** If user-controlled content (from prompt files or config) contains escape sequences, they will be interpreted. This is primarily a data integrity issue.

**Mitigation:** Use `printf '%s\n' "$prompt"` instead, which doesn't interpret escape sequences.

---

### MEDIUM-3: TOCTOU Race Conditions

**Location:** Multiple locations (lines 134, 174-177, 189-193)

**Description:** File existence checks are performed, followed by file operations. In a multi-process environment, the file state could change between check and use.

```bash
if [[ -d "$WORKTREE_PATH" ]]; then
    WORK_DIR="$WORKTREE_PATH"  # Could be different by this point
```

**Risk:** Low in typical usage, but could be exploited in shared environments.

**Mitigation:** Use atomic operations where possible, or implement file locking.

---

### MEDIUM-4: Unvalidated External Command Dependencies

**Location:** `ralph.sh:306, 330, 339`

**Description:** External commands (`claude`, `bd`, `jq`) are invoked by name without full path verification. This relies on PATH security.

**Risk:** PATH injection attacks could substitute malicious binaries.

**Mitigation:**
- Optionally allow configuring full paths to dependencies
- Document that users should ensure PATH security
- Consider adding dependency verification on startup

---

### LOW-1: Debug Logs May Contain Sensitive Data

**Location:** `ralph.sh:304-328`

**Description:** Debug mode creates JSON log files containing full Claude session data, which could include sensitive information from the codebase or prompts.

```bash
mkdir -p "$WORK_DIR/.ralph-logs"
DEBUG_TMP=$(mktemp "$WORK_DIR/.ralph-logs/tmp.XXXXXX")
```

**Risk:** Sensitive data exposure if logs are not properly protected.

**Mitigation:**
- Add `.ralph-logs/` to `.gitignore` (currently not present)
- Document that debug logs may contain sensitive information
- Consider automatic log rotation/cleanup

---

### LOW-2: No Symlink Validation

**Location:** File operations throughout

**Description:** The script doesn't check if files or directories are symlinks before operating on them.

**Risk:** Symlink attacks could redirect operations to unintended locations.

**Mitigation:** Add `-L` checks before critical file operations, or use `realpath` to resolve symlinks.

---

### LOW-3: Information Disclosure in Startup Banner

**Location:** `ralph.sh:263-277`

**Description:** The startup banner displays full file paths, which could reveal directory structure information.

**Risk:** Minor information disclosure, primarily relevant in multi-tenant environments.

**Mitigation:** Consider adding a quiet mode that suppresses detailed path output.

---

### INFO-1: Positive - Strict Bash Mode Enabled

**Location:** `ralph.sh:25`

```bash
set -euo pipefail
```

This enables strict error handling:
- `-e`: Exit on error
- `-u`: Error on undefined variables
- `-o pipefail`: Pipeline returns rightmost non-zero status

This is a security best practice that prevents many common bash pitfalls.

---

### INFO-2: Positive - Security Scanning in CI/CD

**Location:** `.gitlab-ci.yml`

The project includes GitLab CI/CD with:
- SAST (Static Application Security Testing)
- Secret Detection scanning

This demonstrates security awareness in the development process.

---

### INFO-3: Positive - No Hardcoded Credentials

No hardcoded secrets, API keys, passwords, or credentials were found in the codebase.

---

## Recommendations Summary

### Immediate Actions (High Priority)

1. **Sanitize path parameters** - Add validation to reject path traversal sequences in `-w`, `-p`, `-r`, `-s`, and `-c` parameters

2. **Document security model** - Clearly document that `acceptEdits` mode grants Claude full file edit permissions, and the implications of this

### Short-term Improvements (Medium Priority)

3. **Add `.ralph-logs/` to `.gitignore`** - Prevent accidental commit of debug logs

4. **Replace `echo -e` with `printf`** - Avoid escape sequence interpretation

5. **Validate config file values** - Sanitize `branchName` and other extracted values

### Long-term Considerations (Low Priority)

6. **Add `--safe-mode` option** - Allow users to opt into interactive approval mode

7. **Implement file operation allowlists** - Restrict which directories Claude can modify

8. **Add symlink validation** - Prevent symlink-based attacks

---

## Testing Recommendations

The following test cases should be added:

```bash
# Path traversal tests
ralph -w "../.." -p plan.md  # Should be rejected
ralph -w "foo/../bar" -p plan.md  # Should be rejected or normalized

# Input validation tests
ralph -i -5  # Should fail (already handled)
ralph -i "$(whoami)"  # Should fail (already handled)
```

---

## Compliance Notes

- **No PII handling detected** - The tool processes code, not personal data
- **No network operations** - All operations are local (except Claude API calls handled by Claude CLI)
- **MIT License** - Permissive open source license

---

## Conclusion

Ralph demonstrates good baseline security practices including strict bash mode, CI/CD security scanning, and no hardcoded credentials. The main concerns relate to path traversal vulnerabilities and the permissive file edit mode, which are inherent to the tool's autonomous operation model. The recommended mitigations would strengthen the security posture while maintaining the tool's core functionality.
