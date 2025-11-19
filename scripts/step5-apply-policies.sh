#!/usr/bin/env bash
# Applies per-group APIM policies with IP restrictions and backend/key forwarding.

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

APIM_POLICY_API_VERSION="${APIM_POLICY_API_VERSION:-2023-05-01-preview}"

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

emit_optional_block() {
  local indent="$1"
  local content="$2"
  if [[ -z "$content" ]]; then
    return 0
  fi
  while IFS= read -r line; do
    if [[ -z "$line" ]]; then
      printf '\n'
    else
      printf '%s%s\n' "$indent" "$line"
    fi
  done <<< "$content"
}

for endpoint in "${CLIENT_ENDPOINTS[@]}"; do
  group="${CLIENT_ENDPOINT_GROUPS[$endpoint]:-}"
  if [[ -z "$group" ]]; then
    echo "CLIENT_ENDPOINT_GROUPS[$endpoint] is empty. Map endpoints to model groups in scripts/step1-params.sh." >&2
    exit 1
  fi

  allowed_ips="${MODEL_ALLOWED_IPS[$group]:-}"
  if [[ -z "$allowed_ips" ]]; then
    echo "MODEL_ALLOWED_IPS[$group] is empty. Update scripts/step1-params.sh." >&2
    exit 1
  fi
  read -r -a allowed_entries <<< "$allowed_ips"
  if [[ ${#allowed_entries[@]} -eq 0 ]]; then
    echo "MODEL_ALLOWED_IPS[$group] has no entries after parsing." >&2
    exit 1
  fi

  client_nv="client-api-key-${endpoint}"
  backend_service_nv="openai-service-url-${group}"
  backend_key_nv="openai-api-key-${group}"

  if ! api_id=$(get_optional_value CLIENT_ENDPOINT_API_IDS "$endpoint"); then
    api_id="aoai-${endpoint}"
  fi

  if ! az apim api show --resource-group "$RG_NAME" --service-name "$APIM_NAME" --api-id "$api_id" >/dev/null 2>&1; then
    echo "API ${api_id} (endpoint ${endpoint}) not found in APIM ${APIM_NAME}. Ensure Step 4 completed successfully." >&2
    exit 1
  fi

  policy_file="$(mktemp)"
  trap 'rm -f "$policy_file"' EXIT

  {
    printf '<policies>\n'
    printf '  <inbound>\n'
    printf '    <base />\n'
    printf '    <ip-filter action="allow">\n'
    for ip in "${allowed_entries[@]}"; do
      printf '      <address>%s</address>\n' "$ip"
    done
    printf '    </ip-filter>\n'
    printf '    <ip-filter action="forbid" />\n'
    printf '    <check-header name="api-key" failed-check-httpcode="401" failed-check-error-message="Invalid API key.">\n'
    printf '      <value>{{%s}}</value>\n' "$client_nv"
    printf '    </check-header>\n'
    printf '    <set-backend-service base-url="{{%s}}" />\n' "$backend_service_nv"
    printf '    <set-header name="api-key" exists-action="override">\n'
    printf '      <value>{{%s}}</value>\n' "$backend_key_nv"
    printf '    </set-header>\n'
    emit_optional_block "    " "${MODEL_POLICY_EXTRA_INBOUND[$group]:-}"
    printf '  </inbound>\n'
    printf '  <backend>\n'
    printf '    <base />\n'
    emit_optional_block "    " "${MODEL_POLICY_EXTRA_BACKEND[$group]:-}"
    printf '  </backend>\n'
    printf '  <outbound>\n'
    printf '    <base />\n'
    emit_optional_block "    " "${MODEL_POLICY_EXTRA_OUTBOUND[$group]:-}"
    printf '  </outbound>\n'
    printf '  <on-error>\n'
    printf '    <base />\n'
    emit_optional_block "    " "${MODEL_POLICY_EXTRA_ON_ERROR[$group]:-}"
    printf '  </on-error>\n'
    printf '</policies>\n'
  } > "$policy_file"

  printf 'Applying policy for API %s (endpoint %s, group %s)...\n' "$api_id" "$endpoint" "$group"
  policy_uri="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG_NAME}/providers/Microsoft.ApiManagement/service/${APIM_NAME}/apis/${api_id}/policies/policy?api-version=${APIM_POLICY_API_VERSION}"
  az rest \
    --method put \
    --uri "$policy_uri" \
    --headers "Content-Type=application/vnd.ms-azure-apim.policy+xml" \
    --body @"$policy_file" >/dev/null

  rm -f "$policy_file"
  trap - EXIT
done

printf 'Policies applied for endpoints: %s\n' "${CLIENT_ENDPOINTS[*]}"
