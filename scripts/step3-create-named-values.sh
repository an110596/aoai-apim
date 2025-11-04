#!/usr/bin/env bash
# Creates or updates Named Values for each model group.

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

REQUIRED_VARS=(RG_NAME APIM_NAME MODEL_GROUPS)
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

create_or_update_nv() {
  local id="$1"
  local value="$2"
  local secret_flag="$3"
  local display_name="$4"

  if az apim nv show \
    --resource-group "$RG_NAME" \
    --service-name "$APIM_NAME" \
    --named-value-id "$id" >/dev/null 2>&1; then
    printf 'Updating Named Value %s...\n' "$id"
    az apim nv update \
      --resource-group "$RG_NAME" \
      --service-name "$APIM_NAME" \
      --named-value-id "$id" \
      --set value="$value" secret=$secret_flag displayName="$display_name"
  else
    printf 'Creating Named Value %s...\n' "$id"
    az apim nv create \
      --resource-group "$RG_NAME" \
      --service-name "$APIM_NAME" \
      --named-value-id "$id" \
      --display-name "$display_name" \
      --value "$value" \
      --secret "$secret_flag"
  fi
}

for group in "${MODEL_GROUPS[@]}"; do
  service_url="${MODEL_SERVICE_URLS[$group]:-}"
  api_key="${MODEL_API_KEYS[$group]:-}"

  if [[ -z "$service_url" ]]; then
    echo "MODEL_SERVICE_URLS[$group] is empty. Fix scripts/step1-params.sh." >&2
    exit 1
  fi
  if [[ "$service_url" == *"<"*">"* ]]; then
    echo "MODEL_SERVICE_URLS[$group] still contains placeholder brackets. Update scripts/step1-params.sh." >&2
    exit 1
  fi
  if [[ -z "$api_key" ]]; then
    echo "MODEL_API_KEYS[$group] is empty. Load the Azure OpenAI API key for $group." >&2
    exit 1
  fi

  create_or_update_nv "openai-service-url-${group}" "$service_url" false "openai-service-url-${group}"
  create_or_update_nv "openai-api-key-${group}" "$api_key" true "openai-api-key-${group}"
done

printf 'Named Values processed for groups: %s\n' "${MODEL_GROUPS[*]}"
