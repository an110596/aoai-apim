#!/usr/bin/env bash
# Validates APIM vs direct Azure OpenAI responses for a given client endpoint.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: bash scripts/step7-validate.sh --endpoint KEY --file PAYLOAD.json [options]

Required:
  -e, --endpoint KEY        Client endpoint ID (e.g. key-a)
  -f, --file PATH           JSON payload sent to both endpoints

Options:
  -k, --client-key KEY      Client API key (defaults to CLIENT_ENDPOINT_KEYS entry)
  -o, --openai-key KEY      Azure OpenAI API key for direct call (defaults to MODEL_API_KEYS entry
                            for the mapped backend group). Ignored with --skip-direct.
  -v, --api-version VERSION Override API version (defaults to MODEL_API_VERSIONS or OPENAI_API_VERSION)
  -p, --path SEGMENT        Relative path under the client API (default: chat/completions)
  -s, --stream              Enable curl --no-buffer to observe streaming behaviour
      --skip-direct         Skip the direct Azure OpenAI call
  -h, --help                Show this help and exit
USAGE
}

ENDPOINT=""
PAYLOAD=""
client_key=""
openai_key="${OPENAI_API_KEY:-}"
api_version=""
endpoint_segment="chat/completions"
stream_flag=false
skip_direct=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--endpoint)
      ENDPOINT="$2"
      shift 2
      ;;
    -f|--file)
      PAYLOAD="$2"
      shift 2
      ;;
    -k|--client-key)
      client_key="$2"
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
    -p|--path)
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

if [[ -z "$ENDPOINT" ]]; then
  echo "--endpoint is required" >&2
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

# shellcheck source=/dev/null
if ! source "${STEP1_SCRIPT}"; then
  echo "Failed to source ${STEP1_SCRIPT}. Fix the errors above before rerunning." >&2
  exit 1
fi

group="${CLIENT_ENDPOINT_GROUPS[$ENDPOINT]:-}"
if [[ -z "$group" ]]; then
  echo "CLIENT_ENDPOINT_GROUPS[$ENDPOINT] is empty. Ensure scripts/step1-params.sh is configured." >&2
  exit 1
fi

service_url="${MODEL_SERVICE_URLS[$group]:-}"
if [[ -z "$service_url" ]]; then
  echo "MODEL_SERVICE_URLS[$group] is empty. Ensure scripts/step1-params.sh is configured." >&2
  exit 1
fi
if [[ "$service_url" == *"<"*">"* ]]; then
  echo "MODEL_SERVICE_URLS[$group] still contains placeholder brackets. Update scripts/step1-params.sh." >&2
  exit 1
fi

if [[ -z "$api_version" ]]; then
  api_version="${MODEL_API_VERSIONS[$group]:-$OPENAI_API_VERSION}"
fi
if [[ -z "$api_version" ]]; then
  echo "API version could not be resolved. Set --api-version or configure MODEL_API_VERSIONS / OPENAI_API_VERSION." >&2
  exit 1
fi

if [[ -z "$client_key" ]]; then
  client_key="${CLIENT_ENDPOINT_KEYS[$ENDPOINT]:-}"
fi
if [[ -z "$client_key" ]]; then
  echo "Client API key not provided. Use --client-key or set CLIENT_ENDPOINT_KEYS[$ENDPOINT]." >&2
  exit 1
fi

if ! skip_direct; then
  if [[ -z "$openai_key" ]]; then
    openai_key="${MODEL_API_KEYS[$group]:-}"
  fi
  if [[ -z "$openai_key" ]]; then
    echo "OpenAI API key not provided; skipping direct call." >&2
    skip_direct=true
  fi
fi

api_path="${CLIENT_ENDPOINT_PATHS[$ENDPOINT]:-}"
if [[ -z "$api_path" ]]; then
  api_path="openai/${ENDPOINT}"
fi
api_path="${api_path#/}"
api_path="${api_path%/}"
if [[ -z "$api_path" ]]; then
  echo "API path resolved to empty for endpoint $ENDPOINT." >&2
  exit 1
fi

endpoint_segment="${endpoint_segment#/}"
endpoint_segment="${endpoint_segment%/}"
if [[ -z "$endpoint_segment" ]]; then
  echo "Endpoint segment cannot be empty." >&2
  exit 1
fi

payload_path="$(cd "$(dirname "$PAYLOAD")" && pwd)/$(basename "$PAYLOAD")"

service_url="${service_url%/}/"
apim_url="https://${APIM_NAME}.azure-api.net/${api_path}/${endpoint_segment}?api-version=${api_version}"
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

apim_cmd=( "${curl_base[@]}" -H "api-key: ${client_key}" "$apim_url" )
run_request "APIM ${ENDPOINT}" "${apim_cmd[@]}"

if [[ "$skip_direct" == false ]]; then
  direct_cmd=( "${curl_base[@]}" -H "api-key: ${openai_key}" "$direct_url" )
  run_request "Direct Azure OpenAI ${group}" "${direct_cmd[@]}"
else
  printf 'Skipping direct Azure OpenAI call.\n'
fi

exit "$overall_status"
