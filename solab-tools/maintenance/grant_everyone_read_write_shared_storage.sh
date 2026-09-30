#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Grant every user persistent read/write access to shared models and datasets.
set -Eeuo pipefail
export LC_ALL=C

original_args=("$@")
apply=0
targets=(/shared/datasets /shared/models)
test_user="${TEST_USER:-nobody}"
clear_sticky_bits="${CLEAR_STICKY_BITS:-1}"

usage() {
  cat <<'EOF'
Usage:
  bash maintenance/grant_everyone_read_write_shared_storage.sh
  bash maintenance/grant_everyone_read_write_shared_storage.sh --apply

Default mode prints a read-only plan. Apply mode grants every user read/write
access to existing regular files and read/write/traverse access to directories
below /shared/datasets and /shared/models. It also installs default ACLs on all
directories so newly created entries inherit world read/write access.

Symbolic links and nested filesystems are not followed. Existing file execute
bits are preserved. Run this on the s1 storage server; NFS root squash may stop
a client from changing server-side permissions.

WARNING: Every user can overwrite shared files and create or delete entries.
Set CLEAR_STICKY_BITS=0 only if existing sticky-bit deletion restrictions must
remain in place.
EOF
}

case "${1:-}" in
  "") ;;
  --apply) apply=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo 'ERROR: too many arguments' >&2; exit 2; }
[[ "${clear_sticky_bits}" == 0 || "${clear_sticky_bits}" == 1 ]] || {
  echo 'ERROR: CLEAR_STICKY_BITS must be 0 or 1' >&2
  exit 2
}

if [[ "${apply}" -eq 1 && "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    echo 'ERROR: sudo is required but is not installed or available in PATH' >&2
    exit 1
  }
  script_path="$(readlink -f -- "${BASH_SOURCE[0]}")"
  echo 'Administrator access is required; requesting sudo authentication...'
  exec sudo -- env \
    TEST_USER="${test_user}" CLEAR_STICKY_BITS="${clear_sticky_bits}" \
    SOLAB_TOOLS_STATE_DIR="${SOLAB_TOOLS_STATE_DIR:-}" \
    bash "${script_path}" "${original_args[@]}"
fi

for target in "${targets[@]}"; do
  [[ -d "${target}" ]] || {
    echo "ERROR: required target is not a directory: ${target}" >&2
    exit 1
  }
  printf 'TARGET=%s\n' "${target}"
  findmnt -T "${target}" -o TARGET,SOURCE,FSTYPE,OPTIONS || true
  printf 'DIRECTORIES=%s\n' "$(find -P "${target}" -xdev -type d -printf . | wc -c)"
  printf 'REGULAR_FILES=%s\n' "$(find -P "${target}" -xdev -type f -printf . | wc -c)"
done

echo "CLEAR_STICKY_BITS=${clear_sticky_bits}"
echo "TEST_USER=${test_user}"
if [[ "${apply}" -ne 1 ]]; then
  echo 'PLAN_ONLY=1'
  echo 'Apply mode will change existing permission bits, install default ACLs, and run a write/delete smoke test.'
  echo "NEXT_COMMAND=bash $0 --apply"
  echo 'NOTE=apply mode requests sudo authentication automatically'
  exit 0
fi
for command in setfacl getfacl runuser; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "ERROR: ${command} is required; install the acl/util-linux packages" >&2
    exit 127
  }
done
id "${test_user}" >/dev/null 2>&1 || {
  echo "ERROR: smoke-test user does not exist: ${test_user}" >&2
  exit 1
}

caller_user="${SUDO_USER:-root}"
caller_home="$(getent passwd "${caller_user}" 2>/dev/null | cut -d: -f6)"
caller_home="${caller_home:-/root}"
caller_uid="$(id -u "${caller_user}")"
caller_gid="$(id -g "${caller_user}")"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
state_root="${SOLAB_TOOLS_STATE_DIR:-${caller_home}/.local/state/solab-tools}"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
state_root="$(readlink -m -- "${state_root}")"
case "${state_root}" in
  "${repository_root}"|"${repository_root}"/*)
    echo "ERROR: run logs must stay outside the solab-tools checkout: ${state_root}" >&2
    exit 1
    ;;
esac
out_dir="${state_root}/${stamp}-grant-everyone-shared-storage-access"

prepare_state_directory() {
  local default_state_root="${caller_home}/.local/state/solab-tools"
  local directory

  if [[ "${EUID}" -eq 0 && "${caller_user}" != root && "${state_root}" == "${default_state_root}" ]]; then
    for directory in "${caller_home}/.local" "${caller_home}/.local/state" "${default_state_root}"; do
      [[ ! -L "${directory}" ]] || {
        echo "ERROR: refusing to repair symlinked state directory: ${directory}" >&2
        exit 1
      }
      mkdir -p "${directory}"
      chown "${caller_uid}:${caller_gid}" "${directory}"
      chmod u+rwx "${directory}"
    done
    chown -R "${caller_uid}:${caller_gid}" "${default_state_root}"
  else
    mkdir -p "${state_root}"
  fi

  install -d -o "${caller_uid}" -g "${caller_gid}" -m 0700 "${out_dir}"
}

prepare_state_directory
exec > >(tee -a "${out_dir}/output.log") 2>&1

for target in "${targets[@]}"; do
  echo "APPLYING=${target}"
  find -P "${target}" -xdev -type d -exec chmod a+rwx -- {} +
  find -P "${target}" -xdev -type f -exec chmod a+rw -- {} +
  if [[ "${clear_sticky_bits}" == 1 ]]; then
    find -P "${target}" -xdev -type d -exec chmod -t -- {} +
  fi
  find -P "${target}" -xdev \( -type d -o -type f \) \
    -exec setfacl -m 'u::rwX,g::rwX,o::rwX,m::rwX' -- {} +
  find -P "${target}" -xdev -type d \
    -exec setfacl -m 'd:u::rwx,d:g::rwx,d:o::rwx,d:m::rwx' -- {} +
done

for target in "${targets[@]}"; do
  bad_directory="$(find -P "${target}" -xdev -type d ! -perm -0007 -print -quit)"
  bad_file="$(find -P "${target}" -xdev -type f ! -perm -0006 -print -quit)"
  [[ -z "${bad_directory}" ]] || {
    echo "ERROR: directory is not writable by everyone: ${bad_directory}" >&2
    exit 1
  }
  [[ -z "${bad_file}" ]] || {
    echo "ERROR: file is not readable/writable by everyone: ${bad_file}" >&2
    exit 1
  }

  marker="${target}/.world_rw_smoke_${stamp}_$(hostname)"
  printf 'created by root at %s\n' "$(date -Is)" >"${marker}"
  runuser -u "${test_user}" -- bash -c \
    'printf "updated by %s at %s\n" "$(id -un)" "$(date -Is)" >>"$1"; rm -f -- "$1"' \
    _ "${marker}"
  [[ ! -e "${marker}" ]] || {
    echo "ERROR: ${test_user} could not delete ${marker}" >&2
    exit 1
  }
done

echo 'SHARED_STORAGE_PERMISSIONS_OK=1'
echo "LOG=${out_dir}/output.log"
if [[ "${caller_user}" != root ]]; then
  chown -R "${caller_uid}:${caller_gid}" "${out_dir}" || true
fi
