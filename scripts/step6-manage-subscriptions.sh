#!/usr/bin/env bash
# Synchronizes client endpoint API keys into APIM Named Values and prints a routing summary.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP1_SCRIPT="${SCRIPT_DIR}/step1-params.sh"

if [[ ! -f "${STEP1_SCRIPT}" ]]; then
  echo "Step 1 script not found at ${STEP1_SCRIPT}." >&2
  exit 1
fi

# shellcheck source=/dev/null
if ! source "${STEP1_SCRIPT}"; then
  echo "Failed to source ${STEP1_SCRIPT}. Fix the errors above before rerunning." >&2
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Azure CLI (az) is required but not found in PATH." >&2
  exit 1
fi

REQUIRED_VARS=(RG_NAME APIM_NAME CLIENT_ENDPOINTS)
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "Environment variable ${var} is empty. Update scripts/step1-params.sh and source it again." >&2
    exit 1
  fi
done

if [[ ${#CLIENT_ENDPOINTS[@]} -eq 0 ]]; then
  echo "CLIENT_ENDPOINTS is empty; configure at least one endpoint/key pair in scripts/step1-params.sh." >&2
  exit 1
fi

create_or_update_nv() {
  local id="$1"
  local value="$2"
  local display_name="$3"

  if az apim nv show \
    --resource-group "$RG_NAME" \
    --service-name "$APIM_NAME" \
    --named-value-id "$id" >/dev/null 2>&1; then
    printf 'Updating Named Value %s...\n' "$id"
    az apim nv update \
      --resource-group "$RG_NAME" \
      --service-name "$APIM_NAME" \
      --named-value-id "$id" \
      --value "$value" \
      --secret true \
      --set "displayName=$display_name"
  else
    printf 'Creating Named Value %s...\n' "$id"
    az apim nv create \
      --resource-group "$RG_NAME" \
      --service-name "$APIM_NAME" \
      --named-value-id "$id" \
      --display-name "$display_name" \
      --value "$value" \
      --secret true
  fi
}

printf 'Synchronizing client API keys into APIM...\n'
for endpoint in "${CLIENT_ENDPOINTS[@]}"; do
  client_key="${CLIENT_ENDPOINT_KEYS[$endpoint]:-}"
  if [[ -z "$client_key" ]]; then
    echo "CLIENT_ENDPOINT_KEYS[$endpoint] is empty. Provide the key via scripts/step1-params.sh." >&2
    exit 1
  fi
  create_or_update_nv "client-api-key-${endpoint}" "$client_key" "client-api-key-${endpoint}"
done

printf '\nRouting summary (APIM base https://%s.azure-api.net)\n' "$APIM_NAME"
printf '%-12s  %-30s  %-18s  %s\n' "Endpoint" "APIM Path" "Backend Group" "Backend URL"
printf '%.0s-' {1..90}
printf '\n'

for endpoint in "${CLIENT_ENDPOINTS[@]}"; do
  group="${CLIENT_ENDPOINT_GROUPS[$endpoint]}"
  if [[ -z "$group" ]]; then
    echo "CLIENT_ENDPOINT_GROUPS[$endpoint] is empty. Update scripts/step1-params.sh." >&2
    exit 1
  fi
  backend_url="${MODEL_SERVICE_URLS[$group]:-}"
  if [[ -z "$backend_url" ]]; then
    echo "MODEL_SERVICE_URLS[$group] is empty. Update scripts/step1-params.sh." >&2
    exit 1
  fi
  api_path="${CLIENT_ENDPOINT_PATHS[$endpoint]:-}"
  if [[ -z "$api_path" ]]; then
    api_path="openai/${endpoint}"
  fi
  api_path="${api_path#/}"
  api_path="${api_path%/}"
  printf '%-12s  %-30s  %-18s  %s\n' "$endpoint" "$api_path" "$group" "$backend_url"
done

printf '\nClient API keys stored as Named Values client-api-key-<endpoint>. Retrieve with:\n'
printf '  az apim nv show --resource-group %s --service-name %s --named-value-id client-api-key-KEY --query value -o tsv --secret true\n' "$RG_NAME" "$APIM_NAME"
