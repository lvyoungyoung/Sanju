#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-status}"
TARGET_ENVIRONMENT="${TARGET_ENVIRONMENT:-unknown}"
EXPECTED_SUPABASE_PROJECT_ID="${EXPECTED_SUPABASE_PROJECT_ID:-}"
SUPABASE_PROJECT_ID="${SUPABASE_PROJECT_ID:-${SUPABASE_PROJECT_REF:-}}"
SUPABASE_CLI_BIN="${SUPABASE_CLI_BIN:-supabase}"

if [[ "${MODE}" != "status" && "${MODE}" != "baseline" && "${MODE}" != "apply" ]]; then
  echo "Invalid mode: ${MODE}. Expected status, baseline, or apply." >&2
  exit 1
fi

if [[ -n "${EXPECTED_SUPABASE_PROJECT_ID}" && "${SUPABASE_PROJECT_ID}" != "${EXPECTED_SUPABASE_PROJECT_ID}" ]]; then
  echo "SUPABASE_PROJECT_ID does not match ${TARGET_ENVIRONMENT} project." >&2
  echo "Expected project id: ${EXPECTED_SUPABASE_PROJECT_ID}" >&2
  echo "Actual project id: ${SUPABASE_PROJECT_ID:-<empty>}" >&2
  exit 1
fi

if [[ -z "${SUPABASE_PROJECT_ID:-}" ]]; then
  echo "SUPABASE_PROJECT_ID is required." >&2
  exit 1
fi

if [[ -z "${SUPABASE_DB_PASSWORD:-}" ]]; then
  echo "SUPABASE_DB_PASSWORD is required." >&2
  exit 1
fi

if [[ -z "${ALIYUN_ACCESS_TOKEN:-}" && ( -z "${ALIBABA_CLOUD_ACCESS_KEY_ID:-}" || -z "${ALIBABA_CLOUD_ACCESS_KEY_SECRET:-}" ) ]]; then
  echo "ALIYUN_ACCESS_TOKEN or ALIBABA_CLOUD_ACCESS_KEY_ID/ALIBABA_CLOUD_ACCESS_KEY_SECRET is required." >&2
  exit 1
fi

MIGRATION_VERSIONS=()
while IFS= read -r migration_version; do
  MIGRATION_VERSIONS+=("${migration_version}")
done < <(
  find "${ROOT_DIR}/supabase/migrations" -maxdepth 1 -type f -name '*.sql' -print \
    | sed -E 's|.*/([0-9]+)_.+\.sql|\1|' \
    | sort
)

if [[ "${#MIGRATION_VERSIONS[@]}" -eq 0 ]]; then
  echo "No migration files found." >&2
  exit 1
fi

echo "Sanju Supabase CLI migration runner"
echo "Target environment: ${TARGET_ENVIRONMENT}"
echo "Project id: ${SUPABASE_PROJECT_ID}"
echo "Region: ${ALIYUN_REGION_ID:-<cli default>}"
echo "Mode: ${MODE}"
echo "Migration files: ${#MIGRATION_VERSIONS[@]}"

case "${MODE}" in
  status)
    "${SUPABASE_CLI_BIN}" migration list \
      --workdir "${ROOT_DIR}" \
      --project-ref "${SUPABASE_PROJECT_ID}" \
      --password "${SUPABASE_DB_PASSWORD}"
    ;;
  baseline)
    "${SUPABASE_CLI_BIN}" migration repair "${MIGRATION_VERSIONS[@]}" \
      --workdir "${ROOT_DIR}" \
      --project-ref "${SUPABASE_PROJECT_ID}" \
      --password "${SUPABASE_DB_PASSWORD}" \
      --status applied \
      --yes
    ;;
  apply)
    "${SUPABASE_CLI_BIN}" db push \
      --workdir "${ROOT_DIR}" \
      --project-ref "${SUPABASE_PROJECT_ID}" \
      --password "${SUPABASE_DB_PASSWORD}" \
      --yes
    ;;
esac
