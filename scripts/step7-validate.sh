#!/usr/bin/env bash
# Validates APIM vs direct Azure OpenAI responses for a given group.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/step7-validate.sh --group GROUP --file PAYLOAD.json [options]

Required:
  -g, --group GROUP          Model group name (e.g. team-a)
  -f, --file PATH            JSON payload sent to both endpoints

Options:
  -k, --subscription-key KEY APIM subscription key (defaults to $APIM_SUBSCRIPTION_KEY or
                              MODEL_SUBSCRIPTION_PRIMARY_KEYS entry)
  -o, --openai-key KEY       Azure OpenAI API key for direct call (defaults to $OPENAI_API_KEY
                              or MODEL_API_KEYS entry). Ignored with --skip-direct.
  -v, --api-version VERSION  Override API version (defaults to MODEL_API_VERSIONS or
                              OPENAI_API_VERSION)
  -e, --endpoint SEGMENT     Relative path under deployment (default: chat/completions)
  -s, --stream               Enable curl --no-buffer to observe streaming behaviour
      --skip-direct          Skip the direct Azure OpenAI call
  -h, --help                 Show this help and exit

Environment defaults:
  APIM_SUBSCRIPTION_KEY, OPENAI_API_KEY
USAGE
}

GROUP=""
PAYLOAD=""
subscription_key="${APIM_SUBSCRIPTION_KEY:-}"
openai_key="${OPENAI_API_KEY:-}"
api_version=""
endpoint_segment="chat/completions"
stream_flag=false
skip_direct=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g|--group)
      GROUP="$2"
      shift 2
      ;;
    -f|--file)
      PAYLOAD="$2"
      shift 2
      ;;
    -k|--subscription-key)
      subscription_key="$2"
      shift 2
      ;;
    -o|--openai-key)
      openai_key="$2"
      shift 2
      ;;
    -v|--api-version)
      api_version="$2"
      shift 2
      ;;
    -e|--endpoint)
      endpoint_segment="$2"
      shift 2
      ;;
    -s|--stream)
      stream_flag=true
      shift
      ;;
    --skip-direct)
      skip_direct=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$GROUP" ]]; then
  echo "--group is required" >&2
  usage >&2
  exit 1
fi

if [[ -z "$PAYLOAD" ]]; then
  echo "--file is required" >&2
  usage >&2
  exit 1
fi

if [[ ! -f "$PAYLOAD" ]]; then
  echo "Payload file '$PAYLOAD' not found" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEP1_SCRIPT="${SCRIPT_DIR}/step1-params.sh"

if [[ ! -f "${STEP1_SCRIPT}" ]]; then
  echo "Step 1 script not found at ${STEP1_SCRIPT}." >&2
  exit 1
fi

# Source Step 1 parameters so the required exports and arrays are available.
# shellcheck source=/dev/null
if ! source "${STEP1_SCRIPT}"; then
  echo "Failed to source ${STEP1_SCRIPT}. Fix the errors above before rerunning." >&2
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

service_url="${MODEL_SERVICE_URLS[$GROUP]:-}"
if [[ -z "$service_url" ]]; then
  echo "MODEL_SERVICE_URLS[$GROUP] is empty. Ensure scripts/step1-params.sh is configured." >&2
  exit 1
fi
if [[ "$service_url" == *"<"*">"* ]]; then
  echo "MODEL_SERVICE_URLS[$GROUP] still contains placeholder brackets. Update scripts/step1-params.sh." >&2
  exit 1
fi

if ! api_path=$(get_optional_value MODEL_API_PATHS "$GROUP"); then
  api_path="openai/${GROUP}"
fi
api_path="${api_path#/}"
api_path="${api_path%/}"
if [[ -z "$api_path" ]]; then
  echo "API path resolved to empty for group $GROUP." >&2
  exit 1
fi

endpoint_segment="${endpoint_segment#/}"
endpoint_segment="${endpoint_segment%/}"
if [[ -z "$endpoint_segment" ]]; then
  echo "Endpoint segment cannot be empty." >&2
  exit 1
fi

if [[ -z "$api_version" ]]; then
  api_version="${MODEL_API_VERSIONS[$GROUP]:-$OPENAI_API_VERSION}"
fi
if [[ -z "$api_version" ]]; then
  echo "API version could not be resolved. Set --api-version or configure MODEL_API_VERSIONS / OPENAI_API_VERSION." >&2
  exit 1
fi

if [[ -z "$subscription_key" ]]; then
  subs="${MODEL_SUBSCRIPTIONS[$GROUP]:-}"
  if [[ -n "$subs" ]]; then
    read -r -a sub_names <<< "$subs"
    first_sub="${sub_names[0]:-}"
    if [[ -n "$first_sub" ]]; then
      subscription_key="${MODEL_SUBSCRIPTION_PRIMARY_KEYS[$first_sub]:-}"
    fi
  fi
fi

if [[ -z "$subscription_key" ]]; then
  echo "APIM subscription key not provided. Use --subscription-key, set APIM_SUBSCRIPTION_KEY, or populate MODEL_SUBSCRIPTION_PRIMARY_KEYS." >&2
  exit 1
fi

if ! skip_direct; then
  if [[ -z "$openai_key" ]]; then
    openai_key="${MODEL_API_KEYS[$GROUP]:-}"
  fi
  if [[ -z "$openai_key" ]]; then
    echo "OpenAI API key not provided; skipping direct call." >&2
    skip_direct=true
  fi
fi

payload_path="$(cd "$(dirname "$PAYLOAD")" && pwd)/$(basename "$PAYLOAD")"

service_url="${service_url%/}/"
api_path_trimmed="${api_path%/}"
apim_url="https://${APIM_NAME}.azure-api.net/${api_path_trimmed}/${endpoint_segment}?api-version=${api_version}"
direct_url="${service_url}${endpoint_segment}?api-version=${api_version}"

overall_status=0

curl_base=(
  curl
  --silent
  --show-error
  -H "Content-Type: application/json"
  -H "Accept: application/json"
  --data-binary "@${payload_path}"
  --write-out "\nHTTP_STATUS:%{http_code}\n"
)

if [[ "$stream_flag" == true ]]; then
  curl_base+=(--no-buffer)
fi

run_request() {
  local label="$1"
  shift
  local tmp
  tmp="$(mktemp)"
  printf '=== %s ===\n' "$label"
  set +e
  "$@" | tee "$tmp"
  local exit_code=${PIPESTATUS[0]}
  set -e
  local status_line
  status_line="$(tail -n1 "$tmp" | tr -d '\r')"
  local http_status="unknown"
  if [[ "$status_line" == HTTP_STATUS:* ]]; then
    http_status="${status_line#HTTP_STATUS:}"
  fi
  printf '--- %s HTTP Status: %s ---\n\n' "$label" "$http_status"
  if [[ "$http_status" =~ ^[0-9]+$ ]] && (( http_status >= 400 )); then
    overall_status=1
  fi
  if (( exit_code != 0 )); then
    overall_status=$exit_code
  fi
  rm -f "$tmp"
}

apim_cmd=( "${curl_base[@]}" -H "api-key: ${subscription_key}" "$apim_url" )
run_request "APIM ${GROUP}" "${apim_cmd[@]}"

if [[ "$skip_direct" == false ]]; then
  direct_cmd=( "${curl_base[@]}" -H "api-key: ${openai_key}" "$direct_url" )
  run_request "Direct Azure OpenAI ${GROUP}" "${direct_cmd[@]}"
else
  printf 'Skipping direct Azure OpenAI call.\n'
fi

exit "$overall_status"
