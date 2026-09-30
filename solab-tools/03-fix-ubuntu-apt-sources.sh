#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Repair Ubuntu APT sources and apply bounded network timeout policies.
set -Eeuo pipefail
export LC_ALL=C

TARGET_MIRROR="https://mirror.arizona.edu/ubuntu"
APT_POLICY_FILE="/etc/apt/apt.conf.d/99-apt-network-resilience"
AUTO_APT_UNITS=(
  apt-daily.service
  apt-daily-upgrade.service
  apt-daily.timer
  apt-daily-upgrade.timer
)

usage() {
  cat <<EOF
Usage:
  $0 [--update] [--disable-automatic-updates]
  $0 --plan

Actions:
  * Ask for sudo authentication automatically when started as a normal user.
  * Back up the active APT source files and the previous local network policy.
  * Replace active Ubuntu archive URLs using security.ubuntu.com,
    archive.ubuntu.com, or a country archive with:
      ${TARGET_MIRROR}
  * Leave archive.canonical.com and all third-party repositories unchanged.
  * Install bounded IPv4/retry/timeout/pipeline settings for APT.
  * Leave automatic APT services and timers unchanged by default.
  * With --disable-automatic-updates, persistently mask and stop apt-daily,
    apt-daily-upgrade, and both timers when systemd is available. Manual apt
    and apt-get commands remain usable.
  * With --update, run a 20-minute-bounded apt-get update after applying and
    verifying the configuration.

This helper supports Ubuntu servers that use APT. It is idempotent and applies
the repair by default. Use --plan to review the actions without changing files.
EOF
}

original_args=("$@")
apply=1
run_update=0
disable_auto_apt=0
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --apply) apply=1 ;;
    --plan) apply=0 ;;
    --update) run_update=1 ;;
    --disable-automatic-updates) disable_auto_apt=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      echo "ERROR: unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

(( apply == 1 )) || {
  usage
  echo
  echo 'PLAN_ONLY: no APT configuration, services, or package indexes were changed.'
  exit 0
}

if [[ "${EUID}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || {
    echo "ERROR: sudo is required but is not installed or not in PATH" >&2
    exit 1
  }
  script_path="$(readlink -f -- "$0" 2>/dev/null || printf '%s' "$0")"
  echo "Root access is required; requesting sudo authentication..."
  exec sudo -- env \
    SOLAB_TOOLS_STATE_DIR="${SOLAB_TOOLS_STATE_DIR:-}" \
    bash "${script_path}" "${original_args[@]}"
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
caller_user="${SUDO_USER:-root}"
caller_home="$(getent passwd "${caller_user}" 2>/dev/null | awk -F: 'NR == 1 {print $6}')"
[[ -n "${caller_home}" ]] || caller_home="/root"
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
out_dir="${state_root}/${stamp}-fix-ubuntu-apt-sources"

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

phase="PRECHECK"
message="APT configuration has not been changed"
backup_dir=""
source_files_changed=0
update_rc=""
lock_wait_seconds=120
auto_apt_disabled=0

section() {
  printf '\n===== %s =====\n' "$*"
}

run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

die() {
  message="$*"
  echo "ERROR: $*" >&2
  exit 1
}

finish() {
  local rc=$?
  trap - EXIT
  {
    echo "TIME=${stamp}"
    echo "HOST=$(hostname 2>/dev/null || true)"
    echo "EXIT_CODE=${rc}"
    echo "PHASE=${phase}"
    echo "MESSAGE=${message}"
    echo "TARGET_MIRROR=${TARGET_MIRROR}"
    echo "APT_POLICY_FILE=${APT_POLICY_FILE}"
    echo "BACKUP_DIR=${backup_dir}"
    echo "SOURCE_FILES_CHANGED=${source_files_changed}"
    echo "RUN_UPDATE=${run_update}"
    echo "DISABLE_AUTOMATIC_UPDATES=${disable_auto_apt}"
    echo "APT_UPDATE_EXIT_CODE=${update_rc}"
    echo "LOCK_WAIT_SECONDS=${lock_wait_seconds}"
    echo "AUTO_APT_DISABLED=${auto_apt_disabled}"
  } >"${out_dir}/summary.txt"

  if [[ "${caller_user}" != root ]]; then
    chown -R "${caller_uid}:${caller_gid}" "${out_dir}" 2>/dev/null || true
  fi

  echo
  echo "Result directory: ${out_dir}"
  if (( rc != 0 )); then
    echo "APT repair stopped in phase ${phase}: ${message}"
  fi
  exit "${rc}"
}

trap finish EXIT
export STAMP="${stamp}"

[[ -r /etc/os-release ]] || die "missing /etc/os-release"
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "this helper supports Ubuntu APT servers; detected ID=${ID:-unknown}"
ubuntu_codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
[[ -n "${ubuntu_codename}" ]] || die "could not determine the Ubuntu release codename"
[[ -d /etc/apt ]] || die "missing /etc/apt"

for cmd in install cp find apt-config apt-get timeout tee grep sha256sum wc readlink getent awk date sleep sort paste tr ps sed cmp mktemp mv chmod chown; do
  command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
done
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  die "curl or wget is required to verify the target mirror"
fi

probe_url() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    run curl -4 -fL --connect-timeout 5 --max-time 30 --range 0-1023 \
      -o /dev/null "${url}"
  else
    run timeout 30s wget -4 --quiet --output-document=/dev/null \
      --timeout=5 --tries=2 "${url}"
  fi
}

section "verify the Arizona mirror before changing APT"
run sha256sum "$0"
for suite in "${ubuntu_codename}" "${ubuntu_codename}-updates" "${ubuntu_codename}-security"; do
  probe_url "${TARGET_MIRROR}/dists/${suite}/InRelease"
done

section "back up the current APT configuration"
phase="BACKUP"
message="backing up APT sources and the previous local policy"
backup_dir="/etc/apt/apt-network-backup-${stamp}"
run install -d -m 0700 "${backup_dir}"
if [[ -f /etc/apt/sources.list ]]; then
  run cp -a /etc/apt/sources.list "${backup_dir}/sources.list"
fi
if [[ -d /etc/apt/sources.list.d ]]; then
  run cp -a /etc/apt/sources.list.d "${backup_dir}/sources.list.d"
fi
if [[ -e "${APT_POLICY_FILE}" ]]; then
  run cp -a "${APT_POLICY_FILE}" "${backup_dir}/99-apt-network-resilience"
fi

section "replace active Ubuntu archive URLs"
phase="REWRITE_SOURCES"
message="rewriting active Ubuntu archive sources to the Arizona mirror"
source_files_changed=0
shopt -s nullglob
source_files=(
  /etc/apt/sources.list
  /etc/apt/sources.list.d/*.list
  /etc/apt/sources.list.d/*.sources
)
shopt -u nullglob
for source_file in "${source_files[@]}"; do
  [[ -f "${source_file}" ]] || continue
  source_tmp="$(mktemp "${source_file}.solab-tools.XXXXXX")"
  if [[ "${source_file}" == *.sources ]]; then
    sed -E \
      "/^[[:space:]]*URIs[[:space:]]*:/Is#https?://(([a-z]{2}\.)?archive|security)\.ubuntu\.com/ubuntu/?#${TARGET_MIRROR}#gI" \
      "${source_file}" >"${source_tmp}"
  else
    sed -E \
      "/^[[:space:]]*(deb|deb-src)[[:space:]]/Is#https?://(([a-z]{2}\.)?archive|security)\.ubuntu\.com/ubuntu/?#${TARGET_MIRROR}#gI" \
      "${source_file}" >"${source_tmp}"
  fi
  if cmp -s "${source_file}" "${source_tmp}"; then
    rm -f -- "${source_tmp}"
    continue
  fi
  chmod --reference="${source_file}" "${source_tmp}"
  chown --reference="${source_file}" "${source_tmp}"
  mv -f -- "${source_tmp}" "${source_file}"
  source_files_changed="$((source_files_changed + 1))"
done
[[ "${source_files_changed}" =~ ^[0-9]+$ ]] || die "source rewrite returned an invalid change count"
echo "SOURCE_FILES_CHANGED=${source_files_changed}"

section "install bounded APT network policy"
phase="WRITE_POLICY"
message="installing IPv4, retry, timeout, and pipeline settings"
policy_tmp="$(mktemp /etc/apt/99-apt-network-resilience.XXXXXX)"
cat >"${policy_tmp}" <<'EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "2";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::http::Pipeline-Depth "0";
EOF
run install -m 0644 "${policy_tmp}" "${APT_POLICY_FILE}"
rm -f "${policy_tmp}"

section "verify resulting source and Acquire configuration"
phase="VERIFY"
message="verifying that blocked Ubuntu archive hostnames are no longer active"
target_count=0
blocked_count=0
for source_file in "${source_files[@]}"; do
  [[ -f "${source_file}" ]] || continue
  line_number=0
  while IFS= read -r source_line || [[ -n "${source_line}" ]]; do
    line_number="$((line_number + 1))"
    if [[ "${source_file}" == *.sources ]]; then
      [[ "${source_line}" =~ ^[[:space:]]*[Uu][Rr][Ii][Ss][[:space:]]*: ]] || continue
    else
      [[ "${source_line}" =~ ^[[:space:]]*([Dd][Ee][Bb]|[Dd][Ee][Bb]-[Ss][Rr][Cc])[[:space:]] ]] || continue
    fi
    if grep -Eiq 'https?://(([a-z]{2}\.)?archive|security)\.ubuntu\.com/ubuntu/?' <<<"${source_line}"; then
      echo "Blocked active Ubuntu archive URL remains: ${source_file}:${line_number}:${source_line}" >&2
      blocked_count="$((blocked_count + 1))"
    fi
    if grep -Fq "${TARGET_MIRROR}" <<<"${source_line}"; then
      target_count="$((target_count + 1))"
    fi
  done <"${source_file}"
done
(( blocked_count == 0 )) || die "active blocked Ubuntu archive URLs remain"
(( target_count > 0 )) || die "Arizona mirror is not present in any active source"
echo "ARIZONA_ACTIVE_SOURCE_COUNT=${target_count}"

apt-config dump | grep -E \
  '^Acquire::(ForceIPv4|Retries|http::Timeout|https::Timeout|http::Pipeline-Depth) ' \
  | tee "${out_dir}/effective-apt-network-policy.txt"
[[ "$(wc -l <"${out_dir}/effective-apt-network-policy.txt")" -eq 5 ]] || \
  die "not all five required APT network policy values are effective"

if (( disable_auto_apt == 1 )); then
  section "persistently disable automatic APT jobs"
  phase="DISABLE_AUTO_APT"
  message="masking apt-daily services and timers"
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    run timeout 120s systemctl mask --now "${AUTO_APT_UNITS[@]}"
    for unit in "${AUTO_APT_UNITS[@]}"; do
      enabled_state="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
      active_state="$(systemctl is-active "${unit}" 2>/dev/null || true)"
      echo "AUTO_APT_UNIT=${unit} ENABLED=${enabled_state:-unknown} ACTIVE=${active_state:-unknown}"
      [[ "${enabled_state}" == masked ]] || die "${unit} is not masked after persistent disable"
      [[ "${active_state}" != active && "${active_state}" != activating ]] || \
        die "${unit} remains ${active_state} after persistent disable"
    done
    auto_apt_disabled=1
  else
    echo "systemd is unavailable; apt-daily services and timers are not present on this host"
  fi
else
  section "preserve automatic APT jobs"
  echo "Automatic APT services and timers are unchanged."
fi

if (( run_update == 1 )); then
  if command -v fuser >/dev/null 2>&1; then
    phase="WAIT_APT_LOCKS"
    message="waiting for package-manager locks to drain"
    locks=(
      /var/lib/dpkg/lock-frontend
      /var/lib/dpkg/lock
      /var/lib/apt/lists/lock
      /var/cache/apt/archives/lock
    )
    wait_started="$(date +%s)"
    last_report=0
    consecutive_free_checks=0
    while :; do
      held_locks=()
      holder_pids=()
      fuser_unreliable=0
      for lock in "${locks[@]}"; do
        set +e
        fuser -s "${lock}"
        fuser_rc=$?
        set -e
        case "${fuser_rc}" in
          0)
            held_locks+=("${lock}")
            while read -r pid; do
              [[ "${pid}" =~ ^[0-9]+$ ]] && holder_pids+=("${pid}")
            done < <(fuser "${lock}" 2>/dev/null | tr ' ' '\n')
            ;;
          1) ;;
          *)
            echo "WARNING: fuser returned ${fuser_rc} for ${lock}; apt-get will do the authoritative lock check"
            fuser_unreliable=1
            ;;
        esac
      done

      if (( fuser_unreliable == 1 )); then
        break
      fi

      if [[ "${#held_locks[@]}" -eq 0 ]]; then
        consecutive_free_checks="$((consecutive_free_checks + 1))"
        if (( consecutive_free_checks >= 2 )); then
          echo "All APT and dpkg locks were free in two consecutive checks."
          break
        fi
        sleep 1
        continue
      fi
      consecutive_free_checks=0

      now="$(date +%s)"
      elapsed="$((now - wait_started))"
      if (( elapsed >= lock_wait_seconds )); then
        echo "Package-manager locks are still held after ${elapsed} seconds:" >&2
        printf '  %s\n' "${held_locks[@]}" >&2
        if [[ "${#holder_pids[@]}" -gt 0 ]]; then
          unique_pids="$(printf '%s\n' "${holder_pids[@]}" | sort -nu | paste -sd, -)"
          ps -ww -p "${unique_pids}" -o pid,ppid,user,stat,lstart,etime,cmd >&2 || true
        fi
        die "APT or dpkg locks did not drain within ${lock_wait_seconds} seconds"
      fi

      if (( elapsed == 0 || elapsed - last_report >= 15 )); then
        echo "Waiting for APT locks (${elapsed}/${lock_wait_seconds}s): ${held_locks[*]}"
        if [[ "${#holder_pids[@]}" -gt 0 ]]; then
          unique_pids="$(printf '%s\n' "${holder_pids[@]}" | sort -nu | paste -sd, -)"
          ps -ww -p "${unique_pids}" -o pid,ppid,user,stat,etime,cmd || true
        fi
        last_report="${elapsed}"
      fi
      sleep 5
    done
  else
    echo "WARNING: fuser is unavailable; apt-get will perform the authoritative lock check"
  fi

  section "run a bounded apt-get update"
  phase="APT_UPDATE"
  message="running apt-get update with the repaired source and network policy"
  set +e
  timeout 1200s apt-get -o DPkg::Lock::Timeout="${lock_wait_seconds}" update
  update_rc=$?
  set -e
  [[ "${update_rc}" -eq 0 ]] || die "apt-get update failed or timed out with exit code ${update_rc}"
fi

phase="COMPLETE"
message="APT network policy and Arizona mirror configuration were applied successfully"
echo
echo "APT_REPAIR_COMPLETE=1"
echo "TARGET_MIRROR=${TARGET_MIRROR}"
echo "BACKUP_DIR=${backup_dir}"
echo "SOURCE_FILES_CHANGED=${source_files_changed}"
echo "RUN_UPDATE=${run_update}"
echo "DISABLE_AUTOMATIC_UPDATES=${disable_auto_apt}"
echo "AUTO_APT_DISABLED=${auto_apt_disabled}"
