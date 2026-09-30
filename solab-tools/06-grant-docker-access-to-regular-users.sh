#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Grant regular interactive users root-equivalent Docker group access.
set -Eeuo pipefail
export LC_ALL=C

original_args=("$@")
grant_access=0

usage() {
  cat <<'USAGE'
Add every regular interactive local user to the docker group.

Usage:
  bash 06-grant-docker-access-to-regular-users.sh
  bash 06-grant-docker-access-to-regular-users.sh --grant-root-equivalent-access

Default mode only prints the affected users. The explicit
--grant-root-equivalent-access confirmation creates the docker group if needed
and updates supplementary memberships. The script reports whether the Docker
CLI and daemon are available, but it does not install or start Docker.

WARNING: docker group membership is effectively root-level access because a
user can start privileged containers and mount host filesystems.
USAGE
}

case "${1:-}" in
  "") ;;
  --grant-root-equivalent-access) grant_access=1 ;;
  --apply)
    echo 'ERROR: use --grant-root-equivalent-access to acknowledge Docker root-level access' >&2
    exit 2
    ;;
  -h|--help) usage; exit 0 ;;
  *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "ERROR: too many arguments" >&2; exit 2; }

if [[ "${grant_access}" -eq 1 && "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    echo 'ERROR: sudo is required but is not installed or available in PATH' >&2
    exit 1
  }
  script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
  echo 'Administrator access is required; requesting sudo authentication...'
  exec sudo -- bash "${script_path}" "${original_args[@]}"
fi

uid_min="$(awk '$1 == "UID_MIN" {print $2; exit}' /etc/login.defs 2>/dev/null || true)"
uid_max="$(awk '$1 == "UID_MAX" {print $2; exit}' /etc/login.defs 2>/dev/null || true)"
uid_min="${uid_min:-1000}"
uid_max="${uid_max:-60000}"

mapfile -t users < <(
  getent passwd | awk -F: -v min="$uid_min" -v max="$uid_max" '
    $3 >= min && $3 <= max &&
    $7 !~ /(nologin|false)$/ &&
    $6 ~ /^\// { print $1 }
  ' | sort -u
)

[[ "${#users[@]}" -gt 0 ]] || { echo "ERROR: no regular interactive users found" >&2; exit 1; }

docker_cli_state="missing"
docker_cli_path=""
if command -v docker >/dev/null 2>&1; then
  docker_cli_state="present"
  docker_cli_path="$(command -v docker)"
fi

docker_daemon_state="not-detected"
if command -v systemctl >/dev/null 2>&1; then
  docker_service_load_state="$(systemctl show --property=LoadState --value docker.service 2>/dev/null || true)"
  if [[ -n "${docker_service_load_state}" && "${docker_service_load_state}" != "not-found" ]]; then
    docker_daemon_state="$(systemctl is-active docker.service 2>/dev/null || true)"
    docker_daemon_state="${docker_daemon_state:-unknown}"
  fi
fi
if [[ "${docker_daemon_state}" == "not-detected" && -S /var/run/docker.sock ]]; then
  docker_daemon_state="socket-present"
fi

echo "MODE=$([[ "$grant_access" -eq 1 ]] && echo GRANT || echo PLAN)"
echo "UID_RANGE=${uid_min}-${uid_max}"
echo "DOCKER_CLI_STATE=${docker_cli_state}"
[[ -z "${docker_cli_path}" ]] || echo "DOCKER_CLI_PATH=${docker_cli_path}"
echo "DOCKER_DAEMON_STATE=${docker_daemon_state}"
echo "WARNING=docker group grants effective root access"
if [[ "${docker_cli_state}" != "present" || "${docker_daemon_state}" != "active" ]]; then
  echo "NOTE=this script only manages docker group membership; it does not install or start Docker"
fi
printf 'TARGET_USER=%s\n' "${users[@]}"

if [[ "$grant_access" -ne 1 ]]; then
  echo "PLAN_ONLY=1"
  echo "NEXT_COMMAND=bash $0 --grant-root-equivalent-access"
  echo 'NOTE=grant mode requests sudo authentication automatically'
  exit 0
fi

getent group docker >/dev/null || groupadd docker
for user in "${users[@]}"; do
  if id -nG "$user" | tr ' ' '\n' | grep -Fxq docker; then
    echo "UNCHANGED_USER=$user"
  else
    usermod -aG docker "$user"
    echo "ADDED_USER=$user"
  fi
done

for user in "${users[@]}"; do
  id -nG "$user" | tr ' ' '\n' | grep -Fxq docker || {
    echo "ERROR: docker membership verification failed for $user" >&2
    exit 1
  }
done

echo "DOCKER_GROUP_GID=$(getent group docker | cut -d: -f3)"
echo "DOCKER_ACCESS_OK=1"
echo "Users must start a new login session before the new group is active."
