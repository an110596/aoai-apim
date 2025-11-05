#!/usr/bin/env bash
# Creates or updates APIs and Products per model group and links them.

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

for group in "${MODEL_GROUPS[@]}"; do
  service_url="${MODEL_SERVICE_URLS[$group]:-}"
  if [[ -z "$service_url" ]]; then
    echo "MODEL_SERVICE_URLS[$group] is empty. Fix scripts/step1-params.sh." >&2
    exit 1
  fi
  if [[ "$service_url" == *"<"*">"* ]]; then
    echo "MODEL_SERVICE_URLS[$group] still contains placeholder brackets. Update scripts/step1-params.sh." >&2
    exit 1
  fi

  if ! api_id=$(get_optional_value MODEL_API_IDS "$group"); then
    api_id="aoai-${group}"
  fi
  if ! product_id=$(get_optional_value MODEL_PRODUCT_IDS "$group"); then
    product_id="product-${group}"
  fi
  if ! api_path=$(get_optional_value MODEL_API_PATHS "$group"); then
    api_path="openai/${group}"
  fi
  if ! display_name=$(get_optional_value MODEL_API_DISPLAY_NAMES "$group"); then
    display_name="AOAI ${group}"
  fi
  if ! product_display_name=$(get_optional_value MODEL_PRODUCT_DISPLAY_NAMES "$group"); then
    product_display_name="AOAI ${group}"
  fi

  printf 'Processing API/Product for group %s (API ID: %s, Product ID: %s)\n' "$group" "$api_id" "$product_id"

  if az apim api show --resource-group "$RG_NAME" --service-name "$APIM_NAME" --api-id "$api_id" >/dev/null 2>&1; then
    printf 'Updating API %s...\n' "$api_id"
    az apim api update \
      --resource-group "$RG_NAME" \
      --service-name "$APIM_NAME" \
      --api-id "$api_id" \
      --display-name "$display_name" \
      --path "$api_path" \
      --service-url "$service_url" \
      --protocols https \
      --subscription-key-header-name "api-key"
  else
    printf 'Creating API %s...\n' "$api_id"
    az apim api create \
      --resource-group "$RG_NAME" \
      --service-name "$APIM_NAME" \
      --api-id "$api_id" \
      --display-name "$display_name" \
      --path "$api_path" \
      --protocols https \
      --service-url "$service_url" \
      --subscription-key-header-name "api-key"
  fi

  if az apim product show --resource-group "$RG_NAME" --service-name "$APIM_NAME" --product-id "$product_id" >/dev/null 2>&1; then
    printf 'Updating Product %s...\n' "$product_id"
    az apim product update \
      --resource-group "$RG_NAME" \
      --service-name "$APIM_NAME" \
      --product-id "$product_id" \
      --product-name "$product_display_name" \
      --approval-required false \
      --subscriptions-limit 1
  else
    printf 'Creating Product %s...\n' "$product_id"
    az apim product create \
      --resource-group "$RG_NAME" \
      --service-name "$APIM_NAME" \
      --product-id "$product_id" \
      --product-name "$product_display_name" \
      --approval-required false \
      --subscriptions-limit 1
  fi

  if az apim product api check --resource-group "$RG_NAME" --service-name "$APIM_NAME" --product-id "$product_id" --api-id "$api_id" >/dev/null 2>&1; then
    printf 'API %s already linked to product %s.\n' "$api_id" "$product_id"
  else
    printf 'Linking API %s to product %s...\n' "$api_id" "$product_id"
    az apim product api add \
      --resource-group "$RG_NAME" \
      --service-name "$APIM_NAME" \
      --product-id "$product_id" \
      --api-id "$api_id"
  fi

done

printf 'APIs and products processed for groups: %s\n' "${MODEL_GROUPS[*]}"
