#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Add regular interactive users to the shared storage group.
set -Eeuo pipefail
export LC_ALL=C

original_args=("$@")
group_name="${GROUP_NAME:-shared}"
group_gid="${GROUP_GID:-2000}"
min_uid="${MIN_UID:-1000}"
max_uid="${MAX_UID:-59999}"
dry_run=0

usage() {
  cat <<EOF
Usage:
  bash 04-add-regular-users-to-shared-group.sh
  bash 04-add-regular-users-to-shared-group.sh --plan

Adds every regular login user to ${group_name}:${group_gid}.

Regular login users are accounts with UID in [${min_uid}, ${max_uid}] whose login
shell is not nologin/false. System users, nobody, and service accounts are left
alone. The default adds the discovered users. Use --plan for a read-only preview.
EOF
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --plan|--dry-run)
      dry_run=1
      shift
      ;;
    --apply)
      dry_run=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${dry_run}" -ne 1 && "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    echo 'ERROR: sudo is required but is not installed or available in PATH' >&2
    exit 1
  }
  script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
  echo 'Administrator access is required; requesting sudo authentication...'
  exec sudo -- env \
    GROUP_NAME="${group_name}" GROUP_GID="${group_gid}" \
    MIN_UID="${min_uid}" MAX_UID="${max_uid}" \
    SOLAB_TOOLS_STATE_DIR="${SOLAB_TOOLS_STATE_DIR:-}" \
    bash "${script_path}" "${original_args[@]}"
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
caller_user="${SUDO_USER:-$(id -un)}"
caller_home="$(getent passwd "${caller_user}" 2>/dev/null | awk -F: 'NR == 1 {print $6}')"
[[ -n "${caller_home}" ]] || caller_home="${HOME}"
caller_uid="$(id -u "${caller_user}")"
caller_gid="$(id -g "${caller_user}")"
state_root="${SOLAB_TOOLS_STATE_DIR:-${caller_home}/.local/state/solab-tools}"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
state_root="$(readlink -m -- "${state_root}")"
case "${state_root}" in
  "${repository_root}"|"${repository_root}"/*)
    echo "ERROR: run logs must stay outside the solab-tools checkout: ${state_root}" >&2
    exit 1
    ;;
esac
out_dir=""

prepare_apply_log_directory() {
  local default_state_root="${caller_home}/.local/state/solab-tools"
  local directory

  if [[ "${EUID}" -eq 0 && "${caller_user}" != root && "${state_root}" == "${default_state_root}" ]]; then
    for directory in \
      "${caller_home}/.local" \
      "${caller_home}/.local/state" \
      "${default_state_root}"; do
      if [[ -L "${directory}" ]]; then
        echo "ERROR: refusing to repair symlinked state directory: ${directory}" >&2
        echo 'Set SOLAB_TOOLS_STATE_DIR to a trusted writable directory and retry.' >&2
        exit 1
      fi
      mkdir -p "${directory}"
      chown "${caller_uid}:${caller_gid}" "${directory}"
      chmod u+rwx "${directory}"
    done

    # Older runs may have left root-owned 0700 entries below this user-only
    # state directory. Return the complete state tree to the invoking user.
    chown -R "${caller_uid}:${caller_gid}" "${default_state_root}"
  else
    mkdir -p "${state_root}"
  fi

  out_dir="${state_root}/${stamp}-add-regular-users-to-shared-group"
  if [[ "${EUID}" -eq 0 && "${caller_user}" != root ]]; then
    install -d -o "${caller_uid}" -g "${caller_gid}" -m 0700 "${out_dir}"
  else
    mkdir -p "${out_dir}"
  fi
}

# Plan mode is genuinely read-only. Apply mode records evidence after sudo has
# repaired any state directories that an older root run created with mode 0700.
if [[ "${dry_run}" -ne 1 ]]; then
  prepare_apply_log_directory
  exec > >(tee -a "${out_dir}/output.log") 2>&1
fi

run_user="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
status="FAIL"
declare -a users=()
declare -a added_users=()
declare -a already_users=()
declare -a failed_users=()

json_string() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "${s}"
}

json_array() {
  local first=1 item
  printf '['
  for item in "$@"; do
    if [[ "${first}" -eq 0 ]]; then
      printf ', '
    fi
    first=0
    json_string "${item}"
  done
  printf ']'
}

write_summary() {
  local group_line
  [[ -n "${out_dir}" ]] || return 0
  group_line="$(getent group "${group_name}" 2>/dev/null || true)"

  {
    echo "status=${status}"
    echo "host=$(hostname 2>/dev/null || true)"
    echo "timestamp_utc=${stamp}"
    echo "state_root=${state_root}"
    echo "group_name=${group_name}"
    echo "group_gid=${group_gid}"
    echo "dry_run=${dry_run}"
    echo "uid_range=${min_uid}-${max_uid}"
    echo "users_considered=${users[*]:-}"
    echo "users_added=${added_users[*]:-}"
    echo "users_already_members=${already_users[*]:-}"
    echo "users_failed=${failed_users[*]:-}"
    echo "group_line=${group_line}"
  } >"${out_dir}/summary.txt"

  {
    printf '{\n'
    printf '  "status": '; json_string "${status}"; printf ',\n'
    printf '  "host": '; json_string "$(hostname 2>/dev/null || true)"; printf ',\n'
    printf '  "timestamp_utc": '; json_string "${stamp}"; printf ',\n'
    printf '  "state_root": '; json_string "${state_root}"; printf ',\n'
    printf '  "group_name": '; json_string "${group_name}"; printf ',\n'
    printf '  "group_gid": '; json_string "${group_gid}"; printf ',\n'
    printf '  "dry_run": %s,\n' "${dry_run}"
    printf '  "min_uid": %s,\n' "${min_uid}"
    printf '  "max_uid": %s,\n' "${max_uid}"
    printf '  "users_considered": '; json_array "${users[@]}"; printf ',\n'
    printf '  "users_added": '; json_array "${added_users[@]}"; printf ',\n'
    printf '  "users_already_members": '; json_array "${already_users[@]}"; printf ',\n'
    printf '  "users_failed": '; json_array "${failed_users[@]}"; printf ',\n'
    printf '  "group_line": '; json_string "${group_line}"; printf '\n'
    printf '}\n'
  } >"${out_dir}/status.json"
}

finish() {
  local rc=$?
  set +e
  if [[ "${status}" != "PASS" ]]; then
    status="FAIL"
  fi
  write_summary
  if [[ "${EUID}" -eq 0 && -n "${out_dir}" && "${caller_user}" != root ]]; then
    chown -R "${caller_uid}:${caller_gid}" "${out_dir}" || true
  fi
  exit "${rc}"
}
trap finish EXIT

section() {
  printf '\n===== %s =====\n' "$1"
}

run() {
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  if [[ "${dry_run}" -eq 1 ]]; then
    echo "DRY_RUN: skipped"
  else
    "$@"
  fi
}

discover_regular_users() {
  getent passwd | awk -F: -v min_uid="${min_uid}" -v max_uid="${max_uid}" '
    $3 >= min_uid &&
    $3 <= max_uid &&
    $1 != "nobody" &&
    $7 !~ /(nologin|false)$/ {
      print $1
    }
  ' | sort -u
}

ensure_group() {
  local existing_group existing_gid gid_owner
  existing_group="$(getent group "${group_name}" || true)"
  if [[ -n "${existing_group}" ]]; then
    existing_gid="$(printf '%s\n' "${existing_group}" | cut -d: -f3)"
    if [[ "${existing_gid}" != "${group_gid}" ]]; then
      echo "ERROR: group ${group_name} exists with gid ${existing_gid}, expected ${group_gid}"
      exit 1
    fi
    echo "group ${group_name} already exists with gid ${group_gid}"
    return 0
  fi

  gid_owner="$(getent group "${group_gid}" || true)"
  if [[ -n "${gid_owner}" ]]; then
    echo "ERROR: gid ${group_gid} is already used by: ${gid_owner}"
    exit 1
  fi

  run groupadd --gid "${group_gid}" "${group_name}"
}

is_member() {
  local user="$1"
  id -nG "${user}" 2>/dev/null | tr ' ' '\n' | grep -Fxq "${group_name}"
}

section "start"
hostname || true
date -Is || true
echo "state_root=${state_root}"
echo "out_dir=${out_dir:-not-created-in-plan-mode}"
echo "run_user=${run_user}"
echo "group_name=${group_name}"
echo "group_gid=${group_gid}"
echo "uid_range=${min_uid}-${max_uid}"
echo "dry_run=${dry_run}"

section "ensure group"
ensure_group

section "discover regular login users"
mapfile -t users < <(discover_regular_users)
printf 'regular_users='
printf ' %s' "${users[@]}"
printf '\n'
if [[ "${#users[@]}" -eq 0 ]]; then
  echo "WARNING: no regular login users found"
fi

section "add users"
for user in "${users[@]}"; do
  if is_member "${user}"; then
    echo "${user}: already in ${group_name}"
    already_users+=("${user}")
    continue
  fi

  if [[ "${dry_run}" -eq 1 ]]; then
    echo "${user}: would add to ${group_name}"
    added_users+=("${user}")
    continue
  fi

  if usermod -aG "${group_name}" "${user}"; then
    echo "${user}: added to ${group_name}"
    added_users+=("${user}")
  else
    echo "${user}: ERROR adding to ${group_name}"
    failed_users+=("${user}")
  fi
done

if [[ "${#failed_users[@]}" -gt 0 ]]; then
  echo "ERROR: at least one user failed to add to ${group_name}"
  exit 1
fi

section "verify"
getent group "${group_name}" || true
for user in "${users[@]}"; do
  id "${user}" || true
done

section "notes"
cat <<EOF
Existing shells and user-level services keep their old supplementary groups until
they log in again or restart. For immediate one-off commands, use:

  sg ${group_name} -c 'touch /shared/datasets/.write-test && rm /shared/datasets/.write-test'
EOF

status="PASS"
section "summary"
if [[ -n "${out_dir}" ]]; then
  cat "${out_dir}/summary.txt" 2>/dev/null || true
fi
echo "SUMMARY_STATUS=PASS"
echo "SUMMARY_RESULTS_DIR=${out_dir:-not-created-in-plan-mode}"
