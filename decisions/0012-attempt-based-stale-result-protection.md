# ADR-0012: Attempt-Based Stale Result Protection

## Status

Accepted

## Context

The job pipeline uses GitHub Actions webhooks to report CI results back to n8n orchestration. A race condition exists where:

1. Execution starts (attempt 1)
2. Network timeout causes n8n to retry → new execution starts (attempt 2)
3. Attempt 1 finally completes and sends result
4. Stale attempt 1 result overwrites current attempt 2 state

This can cause the pipeline to accept outdated results or corrupt job state.

## Decision

Implement attempt-based protection for **execution webhooks only**:

### Scope: Execution Only

| Signal Type | Needs Attempt? | Reason |
|-------------|----------------|--------|
| `execution-result` | ✅ YES | Destructive - stale results corrupt state |
| `validation-result` | ❌ NO | Idempotent - repeats are harmless |
| `review-result` | ❌ NO | Idempotent - repeats are harmless |

### Rationale

1. **Validation is idempotent** - Running validation twice produces the same result. A repeated VALIDATED signal doesn't corrupt anything.

2. **Execution is destructive** - Execution results (COMPLETED, ERROR) trigger state transitions, merge PRs, and update job status. Stale results can:
   - Mark a job complete when it's actually still running
   - Override current attempt's progress with old data
   - Corrupt retry state

3. **Attempt protects side effects** - The attempt counter exists to protect against stale signals that cause side effects, not to protect against harmless information.

4. **Adding attempt to validation creates fake coupling** - Validation workflows are triggered by `pull_request` events (automatic on PR creation), not by `workflow_dispatch` with attempt input. There's no source of attempt value in PR context.

### Implementation

1. **set_execution_fact RPC** enforces `attempt = current_attempt` check
2. **set_ci_fact RPC** (for validation/review) is terminal + idempotent, no attempt check
3. **Execution webhooks** include `attempt` parameter from workflow_dispatch input
4. **Validation webhooks** do NOT include attempt - they only report final status

### Key Principle

> If a signal can safely be repeated, it does not need attempt protection.

## Consequences

### Positive
- Prevents stale execution results from corrupting job state
- Validation workflows remain simple (no attempt tracking)
- Clear separation between destructive and idempotent operations

### Negative
- None identified - validation repeats are genuinely harmless

## Related

- Execute workflows: `.github/workflows/claude-code.yml` (all repos)
- Validate workflows: `.github/workflows/validate.yml` (all repos)
- Reusable workflows: `creativepropulsionlabs/.github/.github/workflows/`
