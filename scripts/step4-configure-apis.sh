#!/usr/bin/env bash
# Creates or updates client-facing APIs per endpoint by importing a shared OpenAPI surface.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP1_SCRIPT="${SCRIPT_DIR}/step1-params.sh"

if [[ ! -f "${STEP1_SCRIPT}" ]]; then
  echo "Step 1 script not found at ${STEP1_SCRIPT}." >&2
  exit 1
fi

# Source Step 1 parameters so the required exports are available.
# shellcheck source=/dev/null
if ! source "${STEP1_SCRIPT}"; then
  echo "Failed to source ${STEP1_SCRIPT}. Fix the errors above before rerunning." >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required but not found in PATH." >&2
  exit 1
fi

SPEC_URL="${OPENAPI_SPEC_URL:-}"
if [[ -z "$SPEC_URL" ]]; then
  echo "OPENAPI_SPEC_URL is not set. Provide an HTTP(S) (or other accessible) URL to the OpenAPI specification." >&2
  exit 1
fi

printf 'Using OpenAPI specification: %s\n' "$SPEC_URL"

REQUIRED_VARS=(RG_NAME APIM_NAME MODEL_GROUPS CLIENT_ENDPOINTS)
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "Environment variable ${var} is empty. Update scripts/step1-params.sh and source it again." >&2
    exit 1
  fi
done

if [[ ${#MODEL_GROUPS[@]} -eq 0 ]]; then
  echo "MODEL_GROUPS is empty; specify at least one group in scripts/step1-params.sh." >&2
  exit 1
fi
if [[ ${#CLIENT_ENDPOINTS[@]} -eq 0 ]]; then
  echo "CLIENT_ENDPOINTS is empty; configure at least one endpoint/key pair in scripts/step1-params.sh." >&2
  exit 1
fi

get_optional_value() {
  local array_name="$1"
  local key="$2"
  if declare -p "$array_name" >/dev/null 2>&1; then
    local value
    eval "value=\"\${$array_name[$key]:-}\""
    if [[ -n "$value" ]]; then
      printf '%s' "$value"
      return 0
    fi
  fi
  return 1
}

for endpoint in "${CLIENT_ENDPOINTS[@]}"; do
  group="${CLIENT_ENDPOINT_GROUPS[$endpoint]:-}"
  if [[ -z "$group" ]]; then
    echo "CLIENT_ENDPOINT_GROUPS[$endpoint] is empty. Map endpoints to model groups in scripts/step1-params.sh." >&2
    exit 1
  fi

  service_url="${MODEL_SERVICE_URLS[$group]:-}"
  if [[ -z "$service_url" ]]; then
    echo "MODEL_SERVICE_URLS[$group] is empty. Fix scripts/step1-params.sh." >&2
    exit 1
  fi
  if [[ "$service_url" == *"<"*">"* ]]; then
    echo "MODEL_SERVICE_URLS[$group] still contains placeholder brackets. Update scripts/step1-params.sh." >&2
    exit 1
  fi

  if ! api_id=$(get_optional_value CLIENT_ENDPOINT_API_IDS "$endpoint"); then
    api_id="aoai-${endpoint}"
  fi
  if ! api_path=$(get_optional_value CLIENT_ENDPOINT_PATHS "$endpoint"); then
    api_path="openai/${endpoint}"
  fi
  if ! display_name=$(get_optional_value CLIENT_ENDPOINT_API_DISPLAY_NAMES "$endpoint"); then
    display_name="AOAI ${endpoint}"
  fi

  api_path="${api_path#/}"
  api_path="${api_path%/}"
  if [[ -z "$api_path" ]]; then
    echo "API path resolved to empty for endpoint $endpoint." >&2
    exit 1
  fi

  printf 'Processing API for endpoint %s (group %s, API ID: %s)\n' "$endpoint" "$group" "$api_id"

  if az apim api show --resource-group "$RG_NAME" --service-name "$APIM_NAME" --api-id "$api_id" >/dev/null 2>&1; then
    printf 'Importing operations into existing API %s...\n' "$api_id"
  else
    printf 'Creating API %s via import...\n' "$api_id"
  fi

  az apim api import \
    --resource-group "$RG_NAME" \
    --service-name "$APIM_NAME" \
    --api-id "$api_id" \
    --display-name "$display_name" \
    --path "$api_path" \
    --protocols https \
    --service-url "$service_url" \
    --subscription-required false \
    --specification-format OpenApi \
    --specification-url "$SPEC_URL"

done

printf 'APIs processed for endpoints: %s\n' "${CLIENT_ENDPOINTS[*]}"
