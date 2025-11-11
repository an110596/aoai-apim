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
MODEL_GROUPS=("team-a" "team-b")

# Map each group to its Azure OpenAI deployment endpoint (must end with a slash).
declare -Ag MODEL_SERVICE_URLS=(
  ["team-a"]="https://<your-openai-team-a>.openai.azure.com/openai/deployments/gpt-4o/"
  ["team-b"]="https://<your-openai-team-b>.openai.azure.com/openai/deployments/gpt-4o-mini/"
)

# Optional override for API version per group.
declare -Ag MODEL_API_VERSIONS=(
  # ["team-a"]="2024-08-01-preview"
)

# Map each group to its OpenAI API key (leave empty and load securely if you prefer).
declare -Ag MODEL_API_KEYS=(
  # ["team-a"]="$(<"${HOME}/secrets/team-a-openai-key.txt")"
  # ["team-b"]="$(<"${HOME}/secrets/team-b-openai-key.txt")"
)

# Space-separated IP addresses or CIDR blocks allowed to call the APIM endpoint per group.
declare -Ag MODEL_ALLOWED_IPS=(
  ["team-a"]="<team-a-allow-ip-1> <team-a-allow-cidr-2>"
  ["team-b"]="<team-b-allow-ip-1>"
)

# Subscriptions (display names) per group. Leave blank to skip creation in Step 6.
# Use newline-separated values if the display name itself contains spaces.
declare -Ag MODEL_SUBSCRIPTIONS=(
  ["team-a"]=$'sub-team-a-alice\nsub-team-a-bob'
  ["team-b"]="sub-team-b-carol"
)

# Optional overrides for subscription metadata keyed by display name.
declare -Ag MODEL_SUBSCRIPTION_IDS=(
  # ["sub-team-a-alice"]="sub-team-a-alice"
)
declare -Ag MODEL_SUBSCRIPTION_STATES=(
  # ["sub-team-a-alice"]="active"
)
declare -Ag MODEL_SUBSCRIPTION_PRIMARY_KEYS=()
declare -Ag MODEL_SUBSCRIPTION_SECONDARY_KEYS=()

# Map each subscription display name to the APIM user ID that should own it.
declare -Ag MODEL_SUBSCRIPTION_USER_IDS=(
  ["sub-team-a-alice"]="user-team-a-alice"
  ["sub-team-a-bob"]="user-team-a-bob"
  ["sub-team-b-carol"]="user-team-b-carol"
)

# Per-APIM-user metadata keyed by user ID. Update these values for your environment.
declare -Ag MODEL_APIM_USER_EMAILS=(
  ["user-team-a-alice"]="alice@example.com"
  ["user-team-a-bob"]="bob@example.com"
  ["user-team-b-carol"]="carol@example.com"
)
declare -Ag MODEL_APIM_USER_ACCOUNT_NAMES=(
  ["user-team-a-alice"]="team-a-alice"
  ["user-team-a-bob"]="team-a-bob"
  ["user-team-b-carol"]="team-b-carol"
)
declare -Ag MODEL_APIM_USER_STATES=(
  # ["user-team-a-alice"]="active"
)
declare -Ag MODEL_APIM_USER_NOTES=()

# Optional policy fragments to append inside each section.
declare -Ag MODEL_POLICY_EXTRA_INBOUND=(
  # ["team-a"]="<set-header name=\"Authorization\" exists-action=\"override\"><value>@(context.Request.Headers.GetValueOrDefault(\"Authorization\", \"\"))</value></set-header>"
)
declare -Ag MODEL_POLICY_EXTRA_BACKEND=()
declare -Ag MODEL_POLICY_EXTRA_OUTBOUND=()
declare -Ag MODEL_POLICY_EXTRA_ON_ERROR=()

# ---- Validation to avoid silent misconfiguration ----
split_subscription_list() {
  local raw="$1"
  local -n ref="$2"
  ref=()

  if [[ -z "$raw" ]]; then
    return 0
  fi

  if [[ "$raw" == *$'\n'* ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      if [[ -n "${line//[[:space:]]/}" ]]; then
        ref+=("$line")
      fi
    done <<< "$raw"
  else
    read -r -a tokens <<< "$raw"
    for token in "${tokens[@]}"; do
      if [[ -n "$token" ]]; then
        ref+=("$token")
      fi
    done
  fi
}

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

  subs="${MODEL_SUBSCRIPTIONS[$group]:-}"
  if [[ -z "$subs" ]]; then
    continue
  fi
  subscription_names=()
  split_subscription_list "$subs" subscription_names
  if [[ ${#subscription_names[@]} -eq 0 ]]; then
    echo "MODEL_SUBSCRIPTIONS[${group}] has no entries after parsing." >&2
    return 1
  fi
  for display_name in "${subscription_names[@]}"; do
    owner_id="${MODEL_SUBSCRIPTION_USER_IDS[$display_name]:-}"
    if [[ -z "$owner_id" ]]; then
      echo "MODEL_SUBSCRIPTION_USER_IDS[${display_name}] is empty. Map each subscription to an APIM user ID." >&2
      return 1
    fi
    if [[ "$owner_id" == *"<"*">"* ]]; then
      echo "MODEL_SUBSCRIPTION_USER_IDS[${display_name}] still contains placeholder brackets. Update it." >&2
      return 1
    fi

    email="${MODEL_APIM_USER_EMAILS[$owner_id]:-}"
    account_name="${MODEL_APIM_USER_ACCOUNT_NAMES[$owner_id]:-}"

    if [[ -z "$email" ]]; then
      echo "MODEL_APIM_USER_EMAILS[${owner_id}] is empty. Provide the APIM user email address." >&2
      return 1
    fi
    if [[ "$email" == *"<"*">"* ]]; then
      echo "MODEL_APIM_USER_EMAILS[${owner_id}] still contains placeholder brackets. Update it." >&2
      return 1
    fi
    if [[ -z "$account_name" ]]; then
      echo "MODEL_APIM_USER_ACCOUNT_NAMES[${owner_id}] is empty. Provide the APIM user account name." >&2
      return 1
    fi
    if [[ "$account_name" == *"<"*">"* ]]; then
      echo "MODEL_APIM_USER_ACCOUNT_NAMES[${owner_id}] still contains placeholder brackets. Update it." >&2
      return 1
    fi
  done
done

echo "Loaded Step 1 parameters for groups: ${MODEL_GROUPS[*]}"
