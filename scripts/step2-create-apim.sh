#!/usr/bin/env bash
# Creates the resource group and APIM instance defined in Step 1.

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

REQUIRED_VARS=(RG_NAME LOCATION APIM_NAME PUBLISHER_NAME PUBLISHER_EMAIL)
for var in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "Environment variable ${var} is empty. Update scripts/step1-params.sh and source it again." >&2
    exit 1
  fi
done

printf 'Ensuring resource group %s in %s...\n' "$RG_NAME" "$LOCATION"
az group create \
  --name "$RG_NAME" \
  --location "$LOCATION"

if az apim show --name "$APIM_NAME" --resource-group "$RG_NAME" >/dev/null 2>&1; then
  printf 'APIM instance %s already exists in resource group %s; skipping creation.\n' "$APIM_NAME" "$RG_NAME"
  exit 0
fi

printf 'Creating APIM instance %s...\n' "$APIM_NAME"
az apim create \
  --name "$APIM_NAME" \
  --resource-group "$RG_NAME" \
  --location "$LOCATION" \
  --publisher-name "$PUBLISHER_NAME" \
  --publisher-email "$PUBLISHER_EMAIL" \
  --sku-name Consumption \
  --enable-managed-identity
