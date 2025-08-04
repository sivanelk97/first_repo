#!/bin/bash
set -e

# ===[ Configuration ]===
PORT_API_BASE_URL="https://api.getport.io"
CACHE_FILE=".cache/port_token"
CACHE_TTL_SECONDS=3300

# ===[ Accept Parameters ]===
ACTION_IDENTIFIER="$1"
ACTION_TITLE="$2"
PORT_RUN_ID="$3"

if [[ -z "$ACTION_IDENTIFIER" || -z "$ACTION_TITLE" || -z "$PORT_RUN_ID" ]]; then
  echo "❌ Usage: $0 <actionIdentifier> <actionTitle> <runId>"
  exit 1
fi

# ===[ Logging Function ]===
post_log() {
  local MSG="$1"
  echo "$MSG"
  if [[ -n "$TOKEN" && -n "$PORT_RUN_ID" ]]; then
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
    post_log "❌ Failed to retrieve token from Port"
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

# ===[ Check for Existing Action ]===
post_log "🔍 Checking if action '$ACTION_IDENTIFIER' exists..."
STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  "$PORT_API_BASE_URL/v1/actions/$ACTION_IDENTIFIER")

if [[ "$STATUS_CODE" == "200" ]]; then
  post_log "✅ Action '$ACTION_IDENTIFIER' already exists. Skipping creation."
elif [[ "$STATUS_CODE" == "404" ]]; then
  post_log "➕ Action not found. Creating '$ACTION_IDENTIFIER'..."

  HTTP_STATUS=$(curl -s -w "%{http_code}" -o .port_action_response.json -X POST "$PORT_API_BASE_URL/v1/actions" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @- <<EOF
{
  "identifier": "$ACTION_IDENTIFIER",
  "title": "$ACTION_TITLE",
  "description": "Auto-created placeholder action",
  "trigger": {
    "type": "self-service",
    "operation": "CREATE",
    "userInputs": {
      "properties": {
        "user": {
          "type": "string",
          "format": "user",
          "title": "User",
          "default": {
            "jqQuery": ".user.email"
          },
          "visible": false
        }
      },
      "required": [],
      "order": []
    }
  },
  "invocationMethod": {
    "type": "WEBHOOK",
    "url": "https://example.com",
    "method": "POST",
    "headers": {
      "RUN_ID": "{{ .run.id }}",
      "Content-Type": "application/json"
    },
    "body": {
      "{{ spreadValue() }}": "{{ .inputs }}",
      "port_context": {
        "runId": "{{ .run.id }}"
      }
    },
    "agent": false,
    "synchronized": true
  }
}
EOF
  )

  if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "201" ]]; then
    ID=$(jq -r '.action.identifier' .port_action_response.json)
    post_log "📦 Successfully created action: $ID"
  else
    post_log "❌ Failed to create action. HTTP status: $HTTP_STATUS"
    cat .port_action_response.json
    exit 1
  fi

  rm .port_action_response.json
else
  post_log "❌ Unexpected error while checking for action '$ACTION_IDENTIFIER'. HTTP status: $STATUS_CODE"
  exit 1
fi
