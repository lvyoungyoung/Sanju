#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNCTION_LIST="${ROOT_DIR}/scripts/edge-functions.txt"
TARGET_FUNCTION="${1:-all}"
FUNCTIONS_CLI_BIN="${FUNCTIONS_CLI_BIN:-functions-cli}"

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

  if [[ ! -f "${function_dir}/index.ts" ]]; then
    echo "Missing Edge Function entrypoint: ${function_dir}/index.ts" >&2
    exit 1
  fi

  case "${function_name}" in
    delete-account)
      deploy_flags+=("--no-verify-jwt")
      ;;
  esac

  echo "Deploying ${function_name}"
  (
    cd "${ROOT_DIR}"
    "${FUNCTIONS_CLI_BIN}" deploy "${function_name}" "${deploy_flags[@]}"
  )
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
