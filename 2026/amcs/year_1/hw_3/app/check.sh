#!/usr/bin/env bash
set -euo pipefail

STAGE="init"
PROJECT_NAME="hw3_check_$$_$(date +%s)"
BACKUP_DIR="$(mktemp -d "/tmp/redis_backup_${PROJECT_NAME}_XXXXXX")"
APP_PORT="${CHECK_APP_PORT:-18080}"
BASE_URL="http://127.0.0.1:${APP_PORT}"
INCREMENTS=3

fail_stage() {
  local exit_code=$?
  echo "[ERROR] Failed at stage: ${STAGE} (exit code: ${exit_code})" >&2
  exit "${exit_code}"
}

cleanup() {
  local exit_code=$?
  trap - ERR
  echo "[CLEANUP] Removing Compose project '${PROJECT_NAME}' and its volumes..."
  docker compose -p "${PROJECT_NAME}" down -v --remove-orphans >/dev/null 2>&1 || true
  if [[ -d "${BACKUP_DIR}" ]]; then
    echo "[CLEANUP] Removing temporary backup dir '${BACKUP_DIR}'..."
    rm -rf "${BACKUP_DIR}"
  fi
  exit "${exit_code}"
}

trap cleanup EXIT
trap fail_stage ERR

wait_for_url() {
  local url="$1"
  local expected_code="$2"
  local timeout_sec="${3:-30}"
  local elapsed=0

  while true; do
    code="$(curl --max-time 2 -s -o /dev/null -w "%{http_code}" "${url}" || true)"
    if [[ "${code}" == "${expected_code}" ]]; then
      return 0
    fi
    if (( elapsed >= timeout_sec )); then
      echo "[TIMEOUT] Expected HTTP ${expected_code} from ${url} within ${timeout_sec}s (last: ${code})" >&2
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
}

get_counter() {
  curl --max-time 5 -fsS "${BASE_URL}/" | tr -d '[:space:]'
}

STAGE="1_start_project"
echo "[STAGE ${STAGE}] Starting isolated Compose project '${PROJECT_NAME}' on port ${APP_PORT}..."
APP_PORT="${APP_PORT}" docker compose -p "${PROJECT_NAME}" up -d --build --wait

wait_for_url "${BASE_URL}/healthz" "200" 30
wait_for_url "${BASE_URL}/readyz" "200" 30

STAGE="2_initial_and_increment"
echo "[STAGE ${STAGE}] Checking initial counter is 0 and running ${INCREMENTS} POST /increment..."
init_val="$(get_counter)"
if [[ "${init_val}" != "0" ]]; then
  echo "Expected initial counter 0, got '${init_val}'" >&2
  exit 1
fi

for i in $(seq 1 "${INCREMENTS}"); do
  curl --max-time 5 -fsS -X POST "${BASE_URL}/increment" >/dev/null
done

after_inc="$(get_counter)"
if [[ "${after_inc}" != "${INCREMENTS}" ]]; then
  echo "Expected counter ${INCREMENTS} after increments, got '${after_inc}'" >&2
  exit 1
fi
echo "[OK] Counter reached ${after_inc}"

STAGE="3_recreate_app"
echo "[STAGE ${STAGE}] Recreating only app container and verifying counter persists..."
APP_PORT="${APP_PORT}" docker compose -p "${PROJECT_NAME}" up -d --force-recreate --no-deps app
wait_for_url "${BASE_URL}/healthz" "200" 30
wait_for_url "${BASE_URL}/readyz" "200" 30

after_recreate="$(get_counter)"
if [[ "${after_recreate}" != "${INCREMENTS}" ]]; then
  echo "Expected counter ${INCREMENTS} after recreating app, got '${after_recreate}'" >&2
  exit 1
fi
echo "[OK] Counter after app recreate: ${after_recreate}"

STAGE="4_redis_stop_and_start"
echo "[STAGE ${STAGE}] Stopping redis and verifying 200 on /healthz and 503 on /readyz and POST /increment..."
docker compose -p "${PROJECT_NAME}" stop redis

health_code="$(curl --max-time 5 -s -o /dev/null -w "%{http_code}" "${BASE_URL}/healthz")"
ready_code="$(curl --max-time 5 -s -o /dev/null -w "%{http_code}" "${BASE_URL}/readyz")"
inc_code="$(curl --max-time 5 -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/increment")"

if [[ "${health_code}" != "200" || "${ready_code}" != "503" || "${inc_code}" != "503" ]]; then
  echo "Unexpected codes when redis stopped: healthz=${health_code}, readyz=${ready_code}, increment=${inc_code}" >&2
  exit 1
fi

echo "[STAGE ${STAGE}] Starting redis again and waiting for readiness..."
docker compose -p "${PROJECT_NAME}" start redis
wait_for_url "${BASE_URL}/readyz" "200" 30

after_start="$(get_counter)"
if [[ "${after_start}" != "${INCREMENTS}" ]]; then
  echo "Expected counter ${INCREMENTS} after redis restart, got '${after_start}'" >&2
  exit 1
fi


curl --max-time 5 -fsS -X POST "${BASE_URL}/increment" >/dev/null
expected_next=$((INCREMENTS + 1))
after_next_inc="$(get_counter)"
if [[ "${after_next_inc}" != "${expected_next}" ]]; then
  echo "Expected counter ${expected_next} after next increment, got '${after_next_inc}'" >&2
  exit 1
fi
echo "[OK] Counter after redis restart and +1 increment: ${after_next_inc}"

STAGE="5_backup_redis_data"
echo "[STAGE ${STAGE}] Gracefully stopping app and redis, then copying /data with structure and permissions preserved..."
docker compose -p "${PROJECT_NAME}" stop app redis

volume_name="${PROJECT_NAME}_redis_data"
docker run --rm \
  -v "${volume_name}:/source_data:ro" \
  -v "${BACKUP_DIR}:/backup_target" \
  alpine:3.20 \
  sh -c "cp -a /source_data/. /backup_target/"

if [[ ! -d "${BACKUP_DIR}" || -z "$(ls -A "${BACKUP_DIR}")" ]]; then
  echo "Backup directory is empty: ${BACKUP_DIR}" >&2
  exit 1
fi
echo "[OK] Redis data backed up to '${BACKUP_DIR}'"

STAGE="6_teardown_project"
echo "[STAGE ${STAGE}] Tearing down project '${PROJECT_NAME}' with volumes (down -v)..."
docker compose -p "${PROJECT_NAME}" down -v --remove-orphans

echo "[SUCCESS] All stages passed for project '${PROJECT_NAME}'."
