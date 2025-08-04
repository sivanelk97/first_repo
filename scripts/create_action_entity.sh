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
CATEGORY_IDENTIFIER="$2"
LEAD_TIME_BEFORE="${3:-}"
CYCLE_TIME="${4:-}"
PORT_RUN_ID="$5"
ACTION_TITLE="$6"

if [[ -z "$ACTION_IDENTIFIER" || -z "$CATEGORY_IDENTIFIER" || -z "$PORT_RUN_ID" || -z "$ACTION_TITLE" ]]; then
  echo "❌ Usage: $0 <actionIdentifier> <categoryIdentifier> [leadTimeBefore] [cycleTime] <runId> <actionTitle>"
  exit 1
fi

# ===[ Logging Function ]===
post_log() {
  local MSG="$1"
  echo "$MSG"
  if [[ -n "${TOKEN:-}" && -n "$PORT_RUN_ID" ]]; then
    RESPONSE=$(curl -s -w "%{http_code}" -o .port_log_response \
      -X POST "$PORT_API_BASE_URL/v1/actions/runs/$PORT_RUN_ID/logs" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"message\": \"$MSG\"}")
    STATUS="$RESPONSE"
    if [[ "$STATUS" != "201" ]]; then
      echo "⚠️ Failed to post log to Port (HTTP $STATUS)"
      echo "::group::Log API Response"
      cat .port_log_response
      echo "::endgroup::"
    fi
    rm -f .port_log_response
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

# ===[ Token Handling ]===
refresh_token() {
  echo "🔐 Requesting new token..."
  AUTH_RESPONSE=$(curl -s -X POST "$PORT_API_BASE_URL/v1/auth/access_token" \
    -H "Content-Type: application/json" \
    -d "{\"clientId\": \"$PORT_CLIENT_ID\", \"clientSecret\": \"$PORT_CLIENT_SECRET\"}")
  TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.accessToken')
  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "❌ Failed to retrieve token"
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

# ===[ Build properties dynamically ]===
PROPERTIES="{}"
if [[ -n "$LEAD_TIME_BEFORE" || -n "$CYCLE_TIME" ]]; then
  PROPERTIES="{"
  [[ -n "$LEAD_TIME_BEFORE" ]] && PROPERTIES+="\"lead_time_before\": $LEAD_TIME_BEFORE"
  [[ -n "$LEAD_TIME_BEFORE" && -n "$CYCLE_TIME" ]] && PROPERTIES+=", "
  [[ -n "$CYCLE_TIME" ]] && PROPERTIES+="\"cycle_time\": $CYCLE_TIME"
  PROPERTIES+="}"
fi

ENTITY_PAYLOAD=$(cat <<EOF
{
  "identifier": "$ACTION_IDENTIFIER",
  "title": "$ACTION_TITLE",
  "properties": $PROPERTIES,
  "relations": {
    "category": "$CATEGORY_IDENTIFIER"
  }
}
EOF
)

post_log "📦 Creating or updating entity in blueprint 'action'..."

HTTP_STATUS=$(curl -s -w "%{http_code}" -o .entity_response.json \
  -X POST "$PORT_API_BASE_URL/v1/blueprints/action/entities?upsert=true&run_id=$PORT_RUN_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "$ENTITY_PAYLOAD")

if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "201" ]]; then
  post_log "✅ Entity '$ACTION_IDENTIFIER' successfully created/updated"
else
  post_log "❌ Failed to create/update entity. HTTP $HTTP_STATUS"
  {
    echo "❌ Failed to create/update entity. HTTP $HTTP_STATUS"
    if [[ -s .entity_response.json ]]; then
      echo "::group::API Error Response"
      cat .entity_response.json
      echo "::endgroup::"
      jq -r '.message // .error // empty' .entity_response.json || true
    else
      echo "⚠️ No response body received or file is empty."
    fi
  } || true
  rm -f .entity_response.json
  exit 1
fi

rm -f .entity_response.json
