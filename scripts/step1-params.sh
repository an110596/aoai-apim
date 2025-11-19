#!/usr/bin/env bash
# Sets all Step 1 parameters for the Azure OpenAI + APIM setup.
# Usage: source scripts/step1-params.sh

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "This script must be sourced (e.g. source ${BASH_SOURCE[0]})." >&2
  exit 1
fi

set -o errexit
set -o nounset
set -o pipefail

# ---- Core APIM / Azure metadata ----
export RG_NAME="rg-aoai-apim"
export LOCATION="japaneast"
export APIM_NAME="apim-aoai-team"
export PUBLISHER_NAME="ExampleCorp"
export PUBLISHER_EMAIL="aoai-admin@example.com"

# Optional: expose the raw OpenAI API key when you need direct testing.
# export OPENAI_API_KEY=""

# ---- Model groups and per-group backend wiring ----
export OPENAI_API_VERSION="${OPENAI_API_VERSION:-2024-02-15-preview}"
MODEL_GROUPS=("aoai-endpoint-1" "aoai-endpoint-2" "aoai-endpoint-3")

# Map each group to its Azure OpenAI deployment endpoint (must end with a slash).
declare -Ag MODEL_SERVICE_URLS=(
  ["aoai-endpoint-1"]="https://<your-openai-endpoint-1>.openai.azure.com/openai/deployments/gpt-4o/"
  ["aoai-endpoint-2"]="https://<your-openai-endpoint-2>.openai.azure.com/openai/deployments/gpt-4o/"
  ["aoai-endpoint-3"]="https://<your-openai-endpoint-3>.openai.azure.com/openai/deployments/gpt-4o-mini/"
)

# Optional override for API version per group.
declare -Ag MODEL_API_VERSIONS=(
  # ["team-a"]="2024-08-01-preview"
)

# Map each group to its OpenAI API key (load securely from files to avoid committing secrets).
declare -Ag MODEL_API_KEYS=(
  ["aoai-endpoint-1"]="$(<\"${HOME}/secrets/aoai-endpoint-1.key\")"
  ["aoai-endpoint-2"]="$(<\"${HOME}/secrets/aoai-endpoint-2.key\")"
  ["aoai-endpoint-3"]="$(<\"${HOME}/secrets/aoai-endpoint-3.key\")"
)

# Space-separated IP addresses or CIDR blocks allowed to call the APIM endpoint per group.
declare -Ag MODEL_ALLOWED_IPS=(
  ["aoai-endpoint-1"]="<endpoint-1-allow-ip-1> <endpoint-1-allow-cidr-2>"
  ["aoai-endpoint-2"]="<endpoint-2-allow-ip-1>"
  ["aoai-endpoint-3"]="<endpoint-3-allow-ip-1>"
)

# ---- Consumer endpoints (1:1 with client keys) ----
CLIENT_ENDPOINTS=("key-a" "key-b" "key-c" "key-d" "key-e" "key-f" "key-g")

declare -Ag CLIENT_ENDPOINT_GROUPS=(
  ["key-a"]="aoai-endpoint-1"
  ["key-b"]="aoai-endpoint-1"
  ["key-c"]="aoai-endpoint-1"
  ["key-d"]="aoai-endpoint-2"
  ["key-e"]="aoai-endpoint-2"
  ["key-f"]="aoai-endpoint-3"
  ["key-g"]="aoai-endpoint-3"
)

declare -Ag CLIENT_ENDPOINT_KEYS=(
  ["key-a"]="$(<\"${HOME}/secrets/client-key-a.txt\")"
  ["key-b"]="$(<\"${HOME}/secrets/client-key-b.txt\")"
  ["key-c"]="$(<\"${HOME}/secrets/client-key-c.txt\")"
  ["key-d"]="$(<\"${HOME}/secrets/client-key-d.txt\")"
  ["key-e"]="$(<\"${HOME}/secrets/client-key-e.txt\")"
  ["key-f"]="$(<\"${HOME}/secrets/client-key-f.txt\")"
  ["key-g"]="$(<\"${HOME}/secrets/client-key-g.txt\")"
)

# Optional overrides per endpoint (defaults documented in README)
declare -Ag CLIENT_ENDPOINT_PATHS=(
  ["key-a"]="openai/key-a"
  ["key-b"]="openai/key-b"
  ["key-c"]="openai/key-c"
  ["key-d"]="openai/key-d"
  ["key-e"]="openai/key-e"
  ["key-f"]="openai/key-f"
  ["key-g"]="openai/key-g"
)
declare -Ag CLIENT_ENDPOINT_API_IDS=()
declare -Ag CLIENT_ENDPOINT_API_DISPLAY_NAMES=()

# Optional policy fragments to append inside each section.
declare -Ag MODEL_POLICY_EXTRA_INBOUND=(
  # ["team-a"]="<set-header name=\"Authorization\" exists-action=\"override\"><value>@(context.Request.Headers.GetValueOrDefault(\"Authorization\", \"\"))</value></set-header>"
)
declare -Ag MODEL_POLICY_EXTRA_BACKEND=()
declare -Ag MODEL_POLICY_EXTRA_OUTBOUND=()
declare -Ag MODEL_POLICY_EXTRA_ON_ERROR=()

# ---- Validation to avoid silent misconfiguration ----
if [[ ${#MODEL_GROUPS[@]} -eq 0 ]]; then
  echo "MODEL_GROUPS is empty. Configure at least one Azure OpenAI deployment group." >&2
  return 1
fi

for group in "${MODEL_GROUPS[@]}"; do
  if [[ -z "${MODEL_SERVICE_URLS[$group]:-}" ]]; then
    echo "MODEL_SERVICE_URLS[${group}] is empty. Fill in the Azure OpenAI endpoint." >&2
    return 1
  fi
  if [[ "${MODEL_SERVICE_URLS[$group]}" == *"<"*">"* ]]; then
    echo "MODEL_SERVICE_URLS[${group}] still contains placeholder angle brackets. Update it." >&2
    return 1
  fi
  if [[ -z "${MODEL_API_KEYS[$group]:-}" ]]; then
    echo "MODEL_API_KEYS[${group}] is empty. Load or set the Azure OpenAI key before continuing." >&2
    return 1
  fi
  if [[ "${MODEL_API_KEYS[$group]}" == *"<"*">"* ]]; then
    echo "MODEL_API_KEYS[${group}] appears to contain placeholder brackets. Update it." >&2
    return 1
  fi

  allowed_ips="${MODEL_ALLOWED_IPS[$group]:-}"
  if [[ -z "$allowed_ips" ]]; then
    echo "MODEL_ALLOWED_IPS[${group}] is empty. Define the allowed IPs/CIDRs." >&2
    return 1
  fi
  read -r -a allowed_tokens <<< "$allowed_ips"
  if [[ ${#allowed_tokens[@]} -eq 0 ]]; then
    echo "MODEL_ALLOWED_IPS[${group}] has no entries after parsing." >&2
    return 1
  fi
  for ip in "${allowed_tokens[@]}"; do
    if [[ "$ip" == *"<"*">"* ]]; then
      echo "MODEL_ALLOWED_IPS[${group}] still contains placeholder brackets. Update it." >&2
      return 1
    fi
  done
done

if [[ ${#CLIENT_ENDPOINTS[@]} -eq 0 ]]; then
  echo "CLIENT_ENDPOINTS is empty. Define at least one client-facing endpoint/key pair." >&2
  return 1
fi

for endpoint in "${CLIENT_ENDPOINTS[@]}"; do
  group="${CLIENT_ENDPOINT_GROUPS[$endpoint]:-}"
  if [[ -z "$group" ]]; then
    echo "CLIENT_ENDPOINT_GROUPS[${endpoint}] is empty. Map each endpoint to a model group." >&2
    return 1
  fi

  group_found=false
  for defined_group in "${MODEL_GROUPS[@]}"; do
    if [[ "$defined_group" == "$group" ]]; then
      group_found=true
      break
    fi
  done
  if [[ "$group_found" != true ]]; then
    echo "CLIENT_ENDPOINT_GROUPS[${endpoint}] references unknown group '${group}'." >&2
    return 1
  fi

  client_key="${CLIENT_ENDPOINT_KEYS[$endpoint]:-}"
  if [[ -z "$client_key" ]]; then
    echo "CLIENT_ENDPOINT_KEYS[${endpoint}] is empty. Provide the client-facing API key value." >&2
    return 1
  fi
  if [[ "$client_key" == *"<"*">"* ]]; then
    echo "CLIENT_ENDPOINT_KEYS[${endpoint}] still contains placeholder brackets. Update it." >&2
    return 1
  fi

done

echo "Loaded Step 1 parameters for groups: ${MODEL_GROUPS[*]} (endpoints: ${CLIENT_ENDPOINTS[*]})"
