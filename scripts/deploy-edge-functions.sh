#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNCTION_LIST="${ROOT_DIR}/scripts/edge-functions.txt"
TARGET_FUNCTION="${1:-all}"
FUNCTIONS_CLI_BIN="${FUNCTIONS_CLI_BIN:-functions-cli}"
DEPLOY_MAX_ATTEMPTS="${DEPLOY_MAX_ATTEMPTS:-3}"
DEPLOY_RETRY_DELAY_SECONDS="${DEPLOY_RETRY_DELAY_SECONDS:-20}"

if [[ -z "${SUPABASE_API_URL:-}" ]]; then
  echo "SUPABASE_API_URL is required." >&2
  exit 1
fi

if [[ -z "${SUPABASE_API_KEY:-}" ]]; then
  echo "SUPABASE_API_KEY is required." >&2
  exit 1
fi

deploy_function() {
  local function_name="$1"
  local function_dir="${ROOT_DIR}/supabase/functions/${function_name}"
  local deploy_flags=()
  local deploy_command=("${FUNCTIONS_CLI_BIN}" deploy "${function_name}")

  if [[ ! -f "${function_dir}/index.ts" ]]; then
    echo "Missing Edge Function entrypoint: ${function_dir}/index.ts" >&2
    exit 1
  fi

  case "${function_name}" in
    delete-account)
      deploy_flags+=("--no-verify-jwt")
      ;;
  esac
  if (( ${#deploy_flags[@]} > 0 )); then
    deploy_command+=("${deploy_flags[@]}")
  fi

  echo "Deploying ${function_name}"
  local attempt=1
  while (( attempt <= DEPLOY_MAX_ATTEMPTS )); do
    echo "Deploy attempt ${attempt}/${DEPLOY_MAX_ATTEMPTS}: ${function_name}"

    if (
      cd "${ROOT_DIR}"
      "${deploy_command[@]}"
    ); then
      return 0
    fi

    if (( attempt == DEPLOY_MAX_ATTEMPTS )); then
      echo "Deploy failed after ${DEPLOY_MAX_ATTEMPTS} attempt(s): ${function_name}" >&2
      return 1
    fi

    echo "Deploy failed, retrying in ${DEPLOY_RETRY_DELAY_SECONDS}s..."
    sleep "${DEPLOY_RETRY_DELAY_SECONDS}"
    attempt=$((attempt + 1))
  done
}

if [[ "${TARGET_FUNCTION}" == "all" ]]; then
  while IFS= read -r function_name; do
    [[ -z "${function_name}" || "${function_name}" == \#* ]] && continue
    deploy_function "${function_name}"
  done < "${FUNCTION_LIST}"
else
  if ! grep -Fxq "${TARGET_FUNCTION}" "${FUNCTION_LIST}"; then
    echo "Unknown Edge Function: ${TARGET_FUNCTION}" >&2
    echo "Allowed values are:" >&2
    sed 's/^/  - /' "${FUNCTION_LIST}" >&2
    exit 1
  fi

  deploy_function "${TARGET_FUNCTION}"
fi
