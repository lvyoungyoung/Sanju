#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-status}"
TARGET_ENVIRONMENT="${TARGET_ENVIRONMENT:-unknown}"
EXPECTED_SUPABASE_PROJECT_ID="${EXPECTED_SUPABASE_PROJECT_ID:-}"
SUPABASE_PROJECT_ID="${SUPABASE_PROJECT_ID:-${SUPABASE_PROJECT_REF:-}}"
SUPABASE_DB_USER="${SUPABASE_DB_USER:-postgres}"
SUPABASE_DB_NAME="${SUPABASE_DB_NAME:-postgres}"
SUPABASE_DB_PORT="${SUPABASE_DB_PORT:-5432}"
SUPABASE_DB_SSLMODE="${SUPABASE_DB_SSLMODE:-require}"

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

if [[ -z "${SUPABASE_DB_HOST:-}" ]]; then
  echo "SUPABASE_DB_HOST is required." >&2
  exit 1
fi

if [[ -z "${SUPABASE_DB_PASSWORD:-}" ]]; then
  echo "SUPABASE_DB_PASSWORD is required." >&2
  exit 1
fi

DB_URL="$(
  SUPABASE_DB_USER="${SUPABASE_DB_USER}" \
  SUPABASE_DB_PASSWORD="${SUPABASE_DB_PASSWORD}" \
  SUPABASE_DB_HOST="${SUPABASE_DB_HOST}" \
  SUPABASE_DB_PORT="${SUPABASE_DB_PORT}" \
  SUPABASE_DB_NAME="${SUPABASE_DB_NAME}" \
  SUPABASE_DB_SSLMODE="${SUPABASE_DB_SSLMODE}" \
  node -e '
    const user = encodeURIComponent(process.env.SUPABASE_DB_USER);
    const password = encodeURIComponent(process.env.SUPABASE_DB_PASSWORD);
    let host = process.env.SUPABASE_DB_HOST.trim();
    if (/^https?:\/\//i.test(host)) {
      host = new URL(host).hostname;
    } else {
      host = host.split("/")[0].split(":")[0];
    }
    const port = process.env.SUPABASE_DB_PORT;
    const database = encodeURIComponent(process.env.SUPABASE_DB_NAME);
    const sslmode = encodeURIComponent(process.env.SUPABASE_DB_SSLMODE);
    process.stdout.write(`postgresql://${user}:${password}@${host}:${port}/${database}?sslmode=${sslmode}`);
  '
)"

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
echo "Mode: ${MODE}"
echo "Migration files: ${#MIGRATION_VERSIONS[@]}"

case "${MODE}" in
  status)
    supabase migration list \
      --workdir "${ROOT_DIR}" \
      --db-url "${DB_URL}"
    ;;
  baseline)
    supabase migration repair "${MIGRATION_VERSIONS[@]}" \
      --workdir "${ROOT_DIR}" \
      --db-url "${DB_URL}" \
      --status applied \
      --yes
    ;;
  apply)
    supabase db push \
      --workdir "${ROOT_DIR}" \
      --db-url "${DB_URL}" \
      --yes
    ;;
esac
