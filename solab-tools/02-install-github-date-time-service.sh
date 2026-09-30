#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Install a systemd fallback clock service using GitHub HTTPS Date headers.
set -euo pipefail

original_args=("$@")
SERVICE_NAME="github-date-time-sync.service"
HELPER_PATH="/usr/local/sbin/github-date-time-sync"
ENV_PATH="/etc/default/github-date-time-sync"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}"
TIMEZONE="America/Los_Angeles"
COMMAND_TIMEOUT="20m"

usage() {
  cat <<'USAGE'
Usage:
  bash 02-install-github-date-time-service.sh
  bash 02-install-github-date-time-service.sh [--no-run-now]
  bash 02-install-github-date-time-service.sh --plan

Install a system boot service that checks the UTC clock against the HTTPS Date
header returned by https://github.com. This is portable across the lab's
systemd-based Linux servers when normal NTP is unreliable or blocked.

Shared installation path:
  bash 02-install-github-date-time-service.sh

Default behavior:
  - set the system timezone to America/Los_Angeles
  - write /usr/local/sbin/github-date-time-sync
  - write /etc/default/github-date-time-sync
  - write /etc/systemd/system/github-date-time-sync.service
  - systemctl daemon-reload
  - systemctl enable github-date-time-sync.service
  - systemctl start github-date-time-sync.service once immediately

Use --plan to print this plan without changing the host. The service runs as root,
waits for network-online.target, and enforces the America/Los_Angeles timezone.
It exits immediately when NTP reports a synchronized clock. Otherwise, it
compares the local clock with GitHub and only performs a manual correction when
the difference exceeds the configured threshold. NTP is disabled only during
that correction and is enabled again on both success and failure paths.
USAGE
}

RUN_NOW=1
APPLY=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-run-now)
      RUN_NOW=0
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --plan)
      APPLY=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${APPLY}" -ne 1 ]]; then
  usage
  echo
  echo "PLAN_ONLY: no files, services, timezone, or clock settings were changed."
  exit 0
fi

if [[ "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    echo 'ERROR: sudo is required but is not installed or available in PATH' >&2
    exit 1
  }
  script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
  echo 'Administrator access is required; requesting sudo authentication...'
  exec sudo -- bash "${script_path}" "${original_args[@]}"
fi

for required_command in systemctl timedatectl timeout; do
  command -v "${required_command}" >/dev/null 2>&1 || {
    echo "${required_command} is required." >&2
    exit 1
  }
done

run_timed() {
  timeout --foreground "${COMMAND_TIMEOUT}" "$@"
}

install -d -m 0755 "$(dirname "${HELPER_PATH}")"
install -d -m 0755 "$(dirname "${ENV_PATH}")"

run_timed timedatectl set-timezone "${TIMEZONE}"

cat >"${HELPER_PATH}" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail

URL="${GITHUB_TIME_URL:-https://github.com}"
ATTEMPTS="${GITHUB_TIME_ATTEMPTS:-12}"
SLEEP_SECONDS="${GITHUB_TIME_SLEEP_SECONDS:-5}"
FETCH_MAX_TIME="${GITHUB_TIME_FETCH_MAX_TIME:-${GITHUB_TIME_CURL_MAX_TIME:-10}}"
TIMEZONE="${GITHUB_TIME_TIMEZONE:-America/Los_Angeles}"
INSECURE_TLS="${GITHUB_TIME_INSECURE_TLS:-0}"
MAX_SKEW_SECONDS="${GITHUB_TIME_MAX_SKEW_SECONDS:-300}"
COMMAND_TIMEOUT_SECONDS="${GITHUB_TIME_COMMAND_TIMEOUT_SECONDS:-1200}"

log() {
  printf '[github-date-time-sync] %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)" "$*"
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "github-date-time-sync must run as root." >&2
  exit 1
fi

for required_command in timeout; do
  command -v "${required_command}" >/dev/null 2>&1 || {
    echo "${required_command} is required." >&2
    exit 1
  }
done
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  echo "curl or wget is required." >&2
  exit 1
fi

if ! [[ "${ATTEMPTS}" =~ ^[0-9]+$ ]] || [[ "${ATTEMPTS}" -lt 1 ]]; then
  echo "Invalid GITHUB_TIME_ATTEMPTS=${ATTEMPTS}" >&2
  exit 2
fi

for numeric_setting in SLEEP_SECONDS FETCH_MAX_TIME MAX_SKEW_SECONDS COMMAND_TIMEOUT_SECONDS; do
  value="${!numeric_setting}"
  if ! [[ "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -lt 1 ]]; then
    echo "Invalid ${numeric_setting}=${value}" >&2
    exit 2
  fi
done

run_timed() {
  timeout --foreground "${COMMAND_TIMEOUT_SECONDS}s" "$@"
}

log "setting timezone to ${TIMEZONE}"
run_timed timedatectl set-timezone "${TIMEZONE}"

ntp_synchronized="$(run_timed timedatectl show --property=NTPSynchronized --value 2>/dev/null || true)"
if [[ "${ntp_synchronized,,}" == "yes" ]]; then
  log "NTP reports that the system clock is synchronized; no GitHub correction is needed"
  run_timed timedatectl status || true
  exit 0
fi

fetch_remote_date() {
  if command -v curl >/dev/null 2>&1; then
    local -a curl_args=(
      -fsSI
      --connect-timeout "${FETCH_MAX_TIME}"
      --max-time "${FETCH_MAX_TIME}"
    )
    if [[ "${INSECURE_TLS}" == "1" ]]; then
      log "WARNING: TLS certificate verification is explicitly disabled" >&2
      curl_args+=(-k)
    fi
    curl "${curl_args[@]}" "${URL}" \
      | awk 'BEGIN{IGNORECASE=1}/^date:/{sub(/^[^:]*:[[:space:]]*/,""); sub(/\r$/,""); print; exit}'
    return
  fi

  local -a wget_args=(
    --quiet
    --server-response
    --spider
    --timeout="${FETCH_MAX_TIME}"
    --tries=1
  )
  if [[ "${INSECURE_TLS}" == "1" ]]; then
    log "WARNING: TLS certificate verification is explicitly disabled" >&2
    wget_args+=(--no-check-certificate)
  fi
  wget "${wget_args[@]}" "${URL}" 2>&1 \
    | awk 'BEGIN{IGNORECASE=1}/^[[:space:]]*date:/{sub(/^[^:]*:[[:space:]]*/,""); sub(/\r$/,""); print; exit}'
}

remote_date=""
target_epoch=""

for attempt in $(seq 1 "${ATTEMPTS}"); do
  log "fetching Date header from ${URL}, attempt ${attempt}/${ATTEMPTS}"
  remote_date="$(fetch_remote_date 2>/dev/null || true)"
  if [[ -n "${remote_date}" ]]; then
    if target_epoch="$(date -u -d "${remote_date}" +%s 2>/dev/null)"; then
      break
    fi
    log "could not parse remote Date header: ${remote_date}"
  fi

  if [[ "${attempt}" -lt "${ATTEMPTS}" ]]; then
    sleep "${SLEEP_SECONDS}"
  fi
done

if [[ -z "${target_epoch}" ]]; then
  echo "Could not get a valid Date header from ${URL}." >&2
  exit 1
fi

log "selected remote Date header: ${remote_date}"
local_epoch="$(date -u +%s)"
clock_skew_seconds=$((target_epoch - local_epoch))
if [[ "${clock_skew_seconds}" -lt 0 ]]; then
  absolute_skew_seconds=$((-clock_skew_seconds))
else
  absolute_skew_seconds="${clock_skew_seconds}"
fi

if [[ "${absolute_skew_seconds}" -le "${MAX_SKEW_SECONDS}" ]]; then
  log "local clock differs from GitHub by ${absolute_skew_seconds}s; no correction is needed"
  run_timed timedatectl status || true
  exit 0
fi

log "local clock differs from GitHub by ${absolute_skew_seconds}s; manual correction is required"

ntp_restore_needed=0
restore_ntp() {
  if [[ "${ntp_restore_needed}" -eq 1 ]]; then
    log "enabling NTP after manual clock correction"
    if run_timed timedatectl set-ntp true; then
      ntp_restore_needed=0
    else
      log "WARNING: failed to enable NTP; the next service run will retry"
    fi
  fi
  return 0
}
trap restore_ntp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "temporarily disabling NTP before setting the system clock"
ntp_restore_needed=1
run_timed timedatectl set-ntp false

log "setting UTC system clock to epoch ${target_epoch}"
run_timed date -u -s "@${target_epoch}"

if command -v hwclock >/dev/null 2>&1; then
  log "writing UTC hardware clock"
  run_timed hwclock --systohc --utc || log "WARNING: failed to write the hardware clock"
else
  log "WARNING: hwclock is unavailable; leaving the hardware clock unchanged"
fi

restore_ntp

log "verification"
run_timed timedatectl status || true
HELPER

chmod 0755 "${HELPER_PATH}"

cat >"${ENV_PATH}" <<'ENV'
# Optional settings for github-date-time-sync.service.
GITHUB_TIME_URL=https://github.com
GITHUB_TIME_ATTEMPTS=12
GITHUB_TIME_SLEEP_SECONDS=5
GITHUB_TIME_FETCH_MAX_TIME=10
GITHUB_TIME_TIMEZONE=America/Los_Angeles
GITHUB_TIME_MAX_SKEW_SECONDS=300
GITHUB_TIME_COMMAND_TIMEOUT_SECONDS=1200
# Emergency opt-in only when an invalid local clock prevents TLS bootstrap.
GITHUB_TIME_INSECURE_TLS=0
ENV

chmod 0644 "${ENV_PATH}"

cat >"${UNIT_PATH}" <<EOF
[Unit]
Description=Check and correct UTC clock from GitHub HTTPS Date header
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-${ENV_PATH}
ExecStart=${HELPER_PATH}
TimeoutStartSec=20min

[Install]
WantedBy=multi-user.target
EOF

run_timed systemctl daemon-reload
run_timed systemctl enable "${SERVICE_NAME}"

if [[ "${RUN_NOW}" -eq 1 ]]; then
  run_timed systemctl start "${SERVICE_NAME}"
fi

echo
echo "Installed ${SERVICE_NAME}."
echo "Status:"
run_timed systemctl --no-pager --full status "${SERVICE_NAME}" || true
