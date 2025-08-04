#!/bin/bash
set -euo pipefail

# ===[ Configuration ]===
# Uncomment the correct region:
# PORT_API_BASE_URL="https://api.us.port.io"
PORT_API_BASE_URL="https://api.getport.io"
CACHE_FILE=".cache/port_token"
CACHE_TTL_SECONDS=3300

# ===[ Accept Parameters ]===
ACTION_IDENTIFIER="$1"
PORT_RUN_ID="$2"

if [[ -z "$ACTION_IDENTIFIER" || -z "$PORT_RUN_ID" ]]; then
  echo "❌ Usage: $0 <actionIdentifier> <runId>"
  exit 1
fi

TITLE="Automation for runs of $ACTION_IDENTIFIER"
AUTOMATION_IDENTIFIER=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')

# ===[ Logging Function ]===
post_log() {
  local MSG="$1"
  echo "$MSG"
  if [[ -n "${TOKEN:-}" && -n "$PORT_RUN_ID" ]]; then
    curl -s -X POST "$PORT_API_BASE_URL/v1/actions/runs/$PORT_RUN_ID/logs" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"message\": \"$MSG\"}" > /dev/null
  fi
}

# ===[ Error Trap ]===
handle_error() {
  local EXIT_CODE=$?
  local LINE=$1
  local MESSAGE="❌ Script failed at line $LINE with exit code $EXIT_CODE"
  echo "$MESSAGE"
  post_log "$MESSAGE"
  exit $EXIT_CODE
}

trap 'handle_error $LINENO' ERR

# ===[ Token Management ]===
refresh_token() {
  AUTH_RESPONSE=$(curl -s -X POST "$PORT_API_BASE_URL/v1/auth/access_token" \
    -H "Content-Type: application/json" \
    -d "{\"clientId\": \"$PORT_CLIENT_ID\", \"clientSecret\": \"$PORT_CLIENT_SECRET\"}")
  TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.accessToken')
  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    post_log "❌ Failed to retrieve token"
    exit 1
  fi
  mkdir -p .cache
  echo "{\"token\":\"$TOKEN\", \"timestamp\":$(date +%s)}" > "$CACHE_FILE"
}

get_cached_token() {
  if [[ ! -f "$CACHE_FILE" ]]; then
    refresh_token
  else
    TIMESTAMP=$(jq -r '.timestamp' "$CACHE_FILE")
    TOKEN=$(jq -r '.token' "$CACHE_FILE")
    NOW=$(date +%s)
    AGE=$((NOW - TIMESTAMP))
    if [[ $AGE -ge $CACHE_TTL_SECONDS ]]; then
      refresh_token
    fi
  fi
}

get_cached_token

# ===[ Check if automation already exists ]===
post_log "🔍 Checking if automation '$AUTOMATION_IDENTIFIER' exists..."
STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  "$PORT_API_BASE_URL/v1/actions/$AUTOMATION_IDENTIFIER")

if [[ "$STATUS_CODE" == "200" ]]; then
  post_log "✅ Automation '$AUTOMATION_IDENTIFIER' already exists. Skipping creation."
  exit 0
elif [[ "$STATUS_CODE" != "404" ]]; then
  post_log "❌ Unexpected HTTP status $STATUS_CODE while checking automation."
  exit 1
fi

# ===[ Define properties block with double-escaping for jq expressions ]===
PROPERTIES_JSON=$(cat <<'EOF'
{
  "run_id": "{{.event.diff.after.id}}",
  "run_url": "https://app.port.io/organization/run?runId={{.event.diff.after.id}}",
  "status": "{{.event.diff.after.status}}",
  "created_at": "{{.event.diff.after.createdAt}}",
  "updated_at": "{{.event.diff.after.updatedAt}}",
   "{{if (.event.diff.after.status == \"SUCCESS\") then \"duration\" else null end}}": "{{ (.event.diff.after.createdAt | gsub(\"\\\\.[0-9]+Z$\"; \"Z\") | fromdateiso8601) as $created | (.event.diff.after.updatedAt | gsub(\"\\\\.[0-9]+Z$\"; \"Z\") | fromdateiso8601) as $updated | $updated - $created }}",
  "{{if (.event.diff.after.status == \"SUCCESS\" and .event.diff.before.requiredApproval == true) then \"waiting_for_approval_duration\" else null end}}": "{{ (.event.diff.before.createdAt | gsub(\"\\\\.[0-9]+Z$\"; \"Z\") | fromdateiso8601) as $created | (.event.diff.before.updatedAt | gsub(\"\\\\.[0-9]+Z$\"; \"Z\") | fromdateiso8601) as $updated | $updated - $created }}",
  "{{if (.event.diff.after.status == \"SUCCESS\") then \"cycle_time\" else null end}}": "{{ (.event.diff.before.updatedAt | gsub(\"\\\\.[0-9]+Z$\"; \"Z\") | fromdateiso8601) as $created | (.event.diff.after.updatedAt | gsub(\"\\\\.[0-9]+Z$\"; \"Z\") | fromdateiso8601) as $updated | $updated - $created }}"
}
EOF
)

# ===[ Create Automation ]===
post_log "🚀 Creating automation '$AUTOMATION_IDENTIFIER'..."

curl -s -X POST "$PORT_API_BASE_URL/v1/actions" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d @- <<EOF
{
  "identifier": "$AUTOMATION_IDENTIFIER",
  "title": "$TITLE",
  "description": "Update action run data in Port after creation",
  "trigger": {
    "type": "automation",
    "event": {
      "type": "ANY_RUN_CHANGE",
      "actionIdentifier": "$ACTION_IDENTIFIER"
    }
  },
  "invocationMethod": {
    "type": "UPSERT_ENTITY",
    "blueprintIdentifier": "action_run",
    "mapping": {
      "identifier": "{{.event.diff.after.id}}",
      "title": "{{.event.diff.after.id}}",
      "properties": $PROPERTIES_JSON,
      "relations": {
        "parent_action": "{{.event.diff.after.action.identifier}}",
        "ran_by_actual_user": "{{.event.diff.after.properties.user}}"
      }
    }
  },
  "publish": true
}
EOF

post_log "✅ Automation '$AUTOMATION_IDENTIFIER' successfully created."
