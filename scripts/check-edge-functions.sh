#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FUNCTION_LIST="${ROOT_DIR}/scripts/edge-functions.txt"

while IFS= read -r function_name; do
  [[ -z "${function_name}" || "${function_name}" == \#* ]] && continue

  function_file="${ROOT_DIR}/supabase/functions/${function_name}/index.ts"
  if [[ ! -f "${function_file}" ]]; then
    echo "Missing Edge Function entrypoint: ${function_file}" >&2
    exit 1
  fi

  echo "Checking ${function_name}"
  deno check "${function_file}"
done < "${FUNCTION_LIST}"
