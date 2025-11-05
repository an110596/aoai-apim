#!/usr/bin/env bash
# Creates or updates APIM subscriptions per group and outputs the keys.

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

SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
if [[ -z "$SUBSCRIPTION_ID" ]]; then
  if ! SUBSCRIPTION_ID="$(az account show --query id -o tsv 2>/dev/null)"; then
    echo "Unable to determine subscription ID. Set AZURE_SUBSCRIPTION_ID or run 'az account set'." >&2
    exit 1
  fi
  if [[ -z "$SUBSCRIPTION_ID" ]]; then
    echo "Subscription ID resolved to empty. Set AZURE_SUBSCRIPTION_ID." >&2
    exit 1
  fi
fi

APIM_SUBSCRIPTION_API_VERSION="${APIM_SUBSCRIPTION_API_VERSION:-2023-05-01-preview}"

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

split_subscription_list() {
  local raw="$1"
  local -n result_ref="$2"
  result_ref=()

  if [[ -z "$raw" ]]; then
    return 0
  fi

  if [[ "$raw" == *$'\n'* ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      # Remove any trailing carriage returns from Windows-style files.
      line="${line%$'\r'}"
      if [[ -z "${line//[[:space:]]/}" ]]; then
        continue
      fi
      result_ref+=("$line")
    done <<< "$raw"
  else
    read -r -a tokens <<< "$raw"
    for token in "${tokens[@]}"; do
      if [[ -n "$token" ]]; then
        result_ref+=("$token")
      fi
    done
  fi
}

for group in "${MODEL_GROUPS[@]}"; do
  subs="${MODEL_SUBSCRIPTIONS[$group]:-}"
  if [[ -z "$subs" ]]; then
    printf 'No subscriptions configured for group %s; skipping.\n' "$group"
    continue
  fi

  if ! product_id=$(get_optional_value MODEL_PRODUCT_IDS "$group"); then
    product_id="product-${group}"
  fi

  if ! az apim product show --resource-group "$RG_NAME" --service-name "$APIM_NAME" --product-id "$product_id" >/dev/null 2>&1; then
    echo "Product ${product_id} not found in APIM ${APIM_NAME}. Ensure Step 4 completed successfully." >&2
    exit 1
  fi

  subscription_names=()
  split_subscription_list "$subs" subscription_names
  if [[ ${#subscription_names[@]} -eq 0 ]]; then
    printf 'No subscriptions configured for group %s after parsing; skipping.\n' "$group"
    continue
  fi
  for display_name in "${subscription_names[@]}"; do
    if [[ -z "$display_name" ]]; then
      continue
    fi

    if ! subscription_id=$(get_optional_value MODEL_SUBSCRIPTION_IDS "$display_name"); then
      subscription_id="$display_name"
    fi
    state="${MODEL_SUBSCRIPTION_STATES[$display_name]:-active}"
    primary="${MODEL_SUBSCRIPTION_PRIMARY_KEYS[$display_name]:-}"
    secondary="${MODEL_SUBSCRIPTION_SECONDARY_KEYS[$display_name]:-}"

    scope="/products/${product_id}"

    subscription_uri="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/subscriptions/${subscription_id}?api-version=${APIM_SUBSCRIPTION_API_VERSION}"

    set +e
    az rest --method get --uri "$subscription_uri" >/dev/null 2>&1
    get_status=$?
    set -e
    if [[ $get_status -eq 0 ]]; then
      printf 'Updating subscription %s (group %s)...\n' "$subscription_id" "$group"
    else
      printf 'Creating subscription %s (group %s)...\n' "$subscription_id" "$group"
    fi

    payload_file="$(mktemp)"
    trap 'rm -f "$payload_file"' EXIT

    {
      printf '{'
      printf '"properties":{'
      printf '"displayName":"%s",' "$(printf '%s' "$display_name" | sed 's/"/\\"/g')"
      printf '"scope":"%s",' "$(printf '%s' "$scope" | sed 's/"/\\"/g')"
      printf '"state":"%s"' "$(printf '%s' "$state" | sed 's/"/\\"/g')"
      if [[ -n "$primary" ]]; then
        printf ',"primaryKey":"%s"' "$(printf '%s' "$primary" | sed 's/"/\\"/g')"
      fi
      if [[ -n "$secondary" ]]; then
        printf ',"secondaryKey":"%s"' "$(printf '%s' "$secondary" | sed 's/"/\\"/g')"
      fi
      printf '}'
      printf '}'
    } >"$payload_file"

    az rest \
      --method put \
      --uri "$subscription_uri" \
      --body @"$payload_file" \
      --headers "Content-Type=application/json" >/dev/null

    rm -f "$payload_file"
    trap - EXIT

    primary_key=$(az rest --method get --uri "$subscription_uri" --query "properties.primaryKey" -o tsv)
    secondary_key=$(az rest --method get --uri "$subscription_uri" --query "properties.secondaryKey" -o tsv)

    printf '  Display Name: %s\n' "$display_name"
    printf '  Subscription ID: %s\n' "$subscription_id"
    printf '  Scope: %s\n' "$scope"
    printf '  Primary Key: %s\n' "$primary_key"
    printf '  Secondary Key: %s\n' "$secondary_key"
  done

done

printf 'Subscriptions processed for groups with entries in MODEL_SUBSCRIPTIONS.\n'
