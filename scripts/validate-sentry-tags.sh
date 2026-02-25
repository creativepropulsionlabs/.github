#!/usr/bin/env bash
#
# Sentry Tag Compliance Validator
#
# Validates that Sentry events carry required correlation tags per ADR-0805.
# Works locally and in CI (requires curl + jq).
#
# Required env vars:
#   SENTRY_AUTH_TOKEN      - Sentry API bearer token
#   SENTRY_ORG_SLUG        - Sentry organization slug
#   SENTRY_PROJECT_SLUG    - Sentry project slug
#   ENVIRONMENT            - Target environment (development|staging|production)
#
# Optional:
#   SAMPLE_SIZE            - Number of events to check (default: 50)
#   COMPLIANCE_THRESHOLD   - Minimum compliance percentage (default: 95)
#
# Exit codes:
#   0 - Compliance met (or no events found)
#   1 - Compliance below threshold or error

set -euo pipefail

# ---------- inputs ----------

: "${SENTRY_AUTH_TOKEN:?SENTRY_AUTH_TOKEN is required}"
: "${SENTRY_ORG_SLUG:?SENTRY_ORG_SLUG is required}"
: "${SENTRY_PROJECT_SLUG:?SENTRY_PROJECT_SLUG is required}"
: "${ENVIRONMENT:?ENVIRONMENT is required}"

SAMPLE_SIZE="${SAMPLE_SIZE:-50}"
COMPLIANCE_THRESHOLD="${COMPLIANCE_THRESHOLD:-95}"

SENTRY_BASE="https://sentry.io/api/0"

# ---------- helpers ----------

# Mask token in any logged output
log() { echo "[sentry-tags] $*"; }

die() { log "ERROR: $*" >&2; exit 1; }

# Retry-aware curl wrapper (3 attempts, exponential backoff, masks token)
sentry_curl() {
  local url="$1"
  local attempt=0 max_attempts=3 backoff=2
  while true; do
    attempt=$((attempt + 1))
    local http_code body
    body=$(curl -s -w "\n%{http_code}" \
      -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" \
      "$url") || true

    http_code=$(echo "$body" | tail -1)
    body=$(echo "$body" | sed '$d')

    case "$http_code" in
      200) echo "$body"; return 0 ;;
      429)
        if [ "$attempt" -ge "$max_attempts" ]; then
          die "Rate limited after $max_attempts attempts"
        fi
        local retry_after
        retry_after=$((backoff ** attempt))
        log "Rate limited, retrying in ${retry_after}s (attempt $attempt/$max_attempts)"
        sleep "$retry_after"
        ;;
      *)
        if [ "$attempt" -ge "$max_attempts" ]; then
          die "API returned HTTP $http_code after $max_attempts attempts"
        fi
        sleep $((backoff ** attempt))
        ;;
    esac
  done
}

# ---------- fetch events ----------

log "Fetching up to $SAMPLE_SIZE events from $SENTRY_PROJECT_SLUG ($ENVIRONMENT)"

EVENTS_URL="${SENTRY_BASE}/projects/${SENTRY_ORG_SLUG}/${SENTRY_PROJECT_SLUG}/events/?query=environment:${ENVIRONMENT}&per_page=${SAMPLE_SIZE}"

EVENTS_RAW=$(sentry_curl "$EVENTS_URL")

EVENT_COUNT=$(echo "$EVENTS_RAW" | jq 'length')

if [ "$EVENT_COUNT" -eq 0 ]; then
  log "No events found - project may not be instrumented yet"
  # Output SKIPPED result
  jq -n \
    --arg project "$SENTRY_PROJECT_SLUG" \
    --arg env "$ENVIRONMENT" \
    '{
      status: "SKIPPED",
      project: $project,
      environment: $env,
      compliant: 0,
      total: 0,
      percentage: 0,
      missing_tags: [],
      contract_violations: []
    }'
  # Write to GITHUB_OUTPUT before early exit
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "compliance_percentage=0" >> "$GITHUB_OUTPUT"
    echo "status=SKIPPED" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

log "Checking $EVENT_COUNT events for tag compliance"

# ---------- core tags (always required) ----------

CORE_TAGS=("trace_id" "project_id" "environment" "release")

# orchestration tags (required when any orchestration tag is present)
ORCH_TAGS=("job_id" "execution_id" "task_id" "repository_id" "agent_type")

# ---------- evaluate ----------

COMPLIANT=0
TOTAL=0
MISSING_TAGS_JSON="[]"
VIOLATIONS_JSON="[]"

for i in $(seq 0 $((EVENT_COUNT - 1))); do
  TOTAL=$((TOTAL + 1))
  EVENT_ID=$(echo "$EVENTS_RAW" | jq -r ".[$i].eventID // .[$i].id // \"unknown-$i\"")

  # Extract tags into a lookup object: { "tag_key": "tag_value", ... }
  TAGS_OBJ=$(echo "$EVENTS_RAW" | jq -c ".[$i].tags | if type == \"array\" then map({(.key // .name): .value}) | add // {} elif type == \"object\" then . else {} end")

  MISSING=()
  IS_COMPLIANT=true

  # Check core tags
  for tag in "${CORE_TAGS[@]}"; do
    HAS=$(echo "$TAGS_OBJ" | jq -r --arg t "$tag" 'has($t)')
    if [ "$HAS" != "true" ]; then
      MISSING+=("$tag")
      IS_COMPLIANT=false
    fi
  done

  # Check orchestration tags only if any orchestration tag is present
  HAS_ORCH=false
  for tag in "${ORCH_TAGS[@]}"; do
    HAS=$(echo "$TAGS_OBJ" | jq -r --arg t "$tag" 'has($t)')
    if [ "$HAS" = "true" ]; then
      HAS_ORCH=true
      break
    fi
  done

  if [ "$HAS_ORCH" = "true" ]; then
    for tag in "${ORCH_TAGS[@]}"; do
      HAS=$(echo "$TAGS_OBJ" | jq -r --arg t "$tag" 'has($t)')
      if [ "$HAS" != "true" ]; then
        MISSING+=("$tag")
        IS_COMPLIANT=false
      fi
    done
  fi

  if [ "$IS_COMPLIANT" = "true" ]; then
    COMPLIANT=$((COMPLIANT + 1))
  else
    MISSING_STR=$(printf '%s\n' "${MISSING[@]}" | jq -R . | jq -s .)
    VIOLATIONS_JSON=$(echo "$VIOLATIONS_JSON" | jq \
      --arg eid "$EVENT_ID" \
      --argjson missing "$MISSING_STR" \
      '. + [{"event_id": $eid, "missing_tags": $missing}]')

    # Accumulate unique missing tag names
    MISSING_TAGS_JSON=$(echo "$MISSING_TAGS_JSON" | jq --argjson m "$MISSING_STR" '. + $m | unique')
  fi
done

# ---------- calculate compliance ----------

if [ "$TOTAL" -gt 0 ]; then
  PERCENTAGE=$(( (COMPLIANT * 100) / TOTAL ))
else
  PERCENTAGE=0
fi

# Determine status
if [ "$PERCENTAGE" -ge "$COMPLIANCE_THRESHOLD" ]; then
  STATUS="VALIDATED"
else
  STATUS="REJECTED"
fi

log "Result: $COMPLIANT/$TOTAL compliant ($PERCENTAGE%) - $STATUS (threshold: ${COMPLIANCE_THRESHOLD}%)"

# ---------- output ----------

RESULT=$(jq -n \
  --arg status "$STATUS" \
  --arg project "$SENTRY_PROJECT_SLUG" \
  --arg env "$ENVIRONMENT" \
  --argjson compliant "$COMPLIANT" \
  --argjson total "$TOTAL" \
  --argjson percentage "$PERCENTAGE" \
  --argjson threshold "$COMPLIANCE_THRESHOLD" \
  --argjson missing_tags "$MISSING_TAGS_JSON" \
  --argjson contract_violations "$VIOLATIONS_JSON" \
  '{
    status: $status,
    project: $project,
    environment: $env,
    compliant: $compliant,
    total: $total,
    percentage: $percentage,
    threshold: $threshold,
    missing_tags: $missing_tags,
    contract_violations: $contract_violations
  }')

echo "$RESULT" | jq .

# Write to GITHUB_OUTPUT if running in CI
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "compliance_percentage=$PERCENTAGE" >> "$GITHUB_OUTPUT"
  echo "status=$STATUS" >> "$GITHUB_OUTPUT"
  # Multi-line JSON output
  {
    echo "result<<SENTRY_EOF"
    echo "$RESULT"
    echo "SENTRY_EOF"
  } >> "$GITHUB_OUTPUT"
fi

# Exit code based on status
if [ "$STATUS" = "REJECTED" ]; then
  exit 1
fi
