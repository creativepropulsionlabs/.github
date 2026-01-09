---
description: Multi-agent code review for pull requests (adaptive depth)
---

Provide a code review for PR #$ARGUMENTS in this repository.

## Step 1: Pre-flight Checks

Launch a subagent to check if any of the following are true:
- The pull request is closed
- The pull request is a draft
- The pull request does not need code review (e.g. automated PR, trivial change that is obviously correct)

If any condition is true, output:
```json
{
  "verdict": "approved",
  "summary": "Skipped: [reason]",
  "issues": [],
  "skipped": true,
  "profile": "skipped"
}
```
And stop.

Note: Still review Claude-generated PRs - they need validation too.

## Step 2: Measure Change Size

Run `gh pr diff $PR_NUMBER --stat` and extract:
- `files_changed`: number of files modified
- `lines_added`: lines with `+`
- `lines_removed`: lines with `-`
- `total_lines`: lines_added + lines_removed

Also check if ANY of these sensitive paths are touched:
- `auth/`, `permissions/`, `rbac/`
- `billing/`, `payments/`
- `migrations/`, `schema/`
- `.github/workflows/`, `infra/`, `deploy/`
- `security`, `secrets`

## Step 3: Determine Review Profile

Use these thresholds (deterministic, no interpretation):

**SMALL** (fast path) - ALL must be true:
- files_changed ≤ 5
- total_lines ≤ 200
- No sensitive paths touched

**LARGE** (full review) - ANY is true:
- files_changed > 15
- total_lines > 800
- ANY sensitive path touched

**MEDIUM** - Everything else (between SMALL and LARGE)

## Step 4: Gather Guidelines

Launch a subagent to return file paths for relevant guideline files:
- Root CONTRIBUTING.md
- Any CONTRIBUTING.md in modified directories

## Step 5: Execute Review (Profile-Dependent)

### If SMALL Profile:

Launch 2 agents in parallel:

**Agent 1: Compliance Check**
- Audit for CONTRIBUTING.md violations
- Only flag where you can quote the exact rule

**Agent 2: Bug Scan (Diff-Only)**
- Scan for obvious bugs in the diff
- Focus: null checks, typos, missing awaits, logic errors
- Do NOT read context outside the diff

SKIP: Second compliance agent, validation pass, history analysis

### If MEDIUM Profile:

Launch 3 agents in parallel:

**Agent 1: Compliance Check (Primary)**
- Audit for CONTRIBUTING.md violations

**Agent 2: Compliance Check (Secondary)**  
- Independent redundancy check

**Agent 3: Bug Scan (Diff-Only)**
- Same as SMALL

SKIP: Validation pass (unless any issue has confidence < 80)

### If LARGE Profile:

Launch 4 agents in parallel:

**Agent 1: Compliance Check (Primary)**
**Agent 2: Compliance Check (Secondary)**
**Agent 3: Bug Scan (Diff-Only)**
**Agent 4: Bug Scan (Context-Aware)**
- Security issues (SQL injection, XSS)
- Incorrect API usage
- Breaking interface changes

THEN run validation pass for ALL issues found.

## Step 6: Issue Format

Each agent returns issues with:
- `file`: file path
- `line`: line number or range
- `description`: what's wrong
- `type`: "compliance" or "bug"
- `confidence`: 0-100

**CRITICAL: HIGH SIGNAL ONLY**

Flag only:
- Objective bugs causing incorrect runtime behavior
- Clear CONTRIBUTING.md violations with quoted rules

Do NOT flag:
- Subjective concerns or suggestions
- Style preferences not explicitly required
- Potential issues that "might" be problems
- Anything linters will catch

## Step 7: Filter Issues

Remove issues with confidence < 80.

Also filter out:
- Pre-existing issues not introduced in this PR
- Pedantic nitpicks
- General quality concerns not in CONTRIBUTING.md

## Step 8: Format Output

```json
{
  "verdict": "approved" | "changes_requested" | "rejected",
  "summary": "Brief summary",
  "issues": [
    {
      "file": "path/to/file.ts",
      "line": "42-45",
      "description": "Missing null check",
      "type": "bug",
      "confidence": 85
    }
  ],
  "profile": "small" | "medium" | "large",
  "agents_run": <number>
}
```

Verdict logic:
- Any confidence ≥ 90 bug → "changes_requested"
- Multiple confidence ≥ 80 issues → "changes_requested"
- Security issue of any confidence → "changes_requested"
- Single minor issue → "approved" (with note)
- No issues → "approved"

## Notes

- Use `gh` CLI for all GitHub operations
- The JSON output MUST be valid and parseable
- Keep descriptions concise but actionable
