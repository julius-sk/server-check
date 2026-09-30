#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Install the pinned internal CA chain that fixes HTTPS download errors.
set -Eeuo pipefail

original_args=("$@")
MODE=apply
NO_NETWORK_CHECK=0
REPLACE_OPENSSL_CERT_FILE=0
VERIFY_URL="${VERIFY_URL:-https://security.ubuntu.com/ubuntu/dists/jammy-security/InRelease}"

usage() {
  cat <<'USAGE'
Usage:
  bash 01-install-ca-to-fix-https-download-errors.sh
  bash 01-install-ca-to-fix-https-download-errors.sh --check

The default mode applies the repair. Apply mode:
  - validates bundled file checksums and pinned certificate fingerprints
  - backs up the current host files into the run evidence directory
  - installs the SK Hynix Root and Subordinate CA files as root:root 0644
  - runs update-ca-certificates
  - creates the missing OpenSSL cert.pem link to the Debian system CA bundle
  - verifies the installed chain and checks wget for certificate warnings

Options:
  --check                       Inspect the host without changing it.
  --apply                       Apply the repair explicitly; this is the default.
  --no-network-check            Skip the final wget TLS probe.
  --replace-openssl-cert-file   Back up and replace an existing OpenSSL cert.pem
                                that does not resolve to the Debian CA bundle.
  -h, --help                    Show this help.

The final network check treats HTTP policy errors such as Cisco WSA 403 as
separate from TLS trust. It fails only on a certificate warning or mismatch.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      MODE=check
      ;;
    --apply)
      MODE=apply
      ;;
    --no-network-check)
      NO_NETWORK_CHECK=1
      ;;
    --replace-openssl-cert-file)
      REPLACE_OPENSSL_CERT_FILE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_SOURCE="${SCRIPT_DIR}/certs/SK_Hynix_America_Root_CA.crt"
SUBORDINATE_SOURCE="${SCRIPT_DIR}/certs/SK_Hynix_America_Subordinate_CA_1.crt"
CHECKSUM_FILE="${SCRIPT_DIR}/certs/SHA256SUMS"
ROOT_TARGET=/usr/local/share/ca-certificates/root_SK_Hynix_America_CA.crt
SUBORDINATE_TARGET=/usr/local/share/ca-certificates/SK_Hynix_America_Subordinate_CA_1.crt
SYSTEM_BUNDLE=/etc/ssl/certs/ca-certificates.crt
ROOT_FINGERPRINT=DCF9F7EFB3D98A8BDE639D0517EDEE112C899E9CFB3C136178830E7360AFC8A5
SUBORDINATE_FINGERPRINT=74C8F1018E1F8CA206ACBE48BEC2D5F624A8E588E27366B1676919A7D7D627F8
ROOT_SUBJECT='CN=SK Hynix America Root CA,OU=IT,O=SK Hynix America,L=San Jose,ST=California,C=US'
SUBORDINATE_SUBJECT='CN=SK Hynix America Subordinate CA 1,OU=IT,O=SK Hynix America,L=San Jose,ST=California,C=US'

need_command() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  }
}

request_root() {
  [[ "${EUID}" -eq 0 ]] && return 0
  need_command sudo
  echo 'Administrator access is required; requesting sudo authentication...'
  exec sudo -- env \
    VERIFY_URL="${VERIFY_URL}" \
    SOLAB_TOOLS_STATE_DIR="${SOLAB_TOOLS_STATE_DIR:-}" \
    bash "${SCRIPT_DIR}/01-install-ca-to-fix-https-download-errors.sh" "${original_args[@]}"
}

need_command openssl
need_command sha256sum
need_command stat

test -r "${CHECKSUM_FILE}" || {
  echo "Certificate checksum file is missing or unreadable: ${CHECKSUM_FILE}" >&2
  exit 1
}
(cd "${SCRIPT_DIR}/certs" && sha256sum --check SHA256SUMS)

if grep -E -q -- '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' \
  "$ROOT_SOURCE" "$SUBORDINATE_SOURCE" 2>/dev/null; then
  echo 'Refusing package containing a private key.' >&2
  exit 1
fi

validate_certificate() {
  local path="$1"
  local expected_fingerprint="$2"
  local expected_subject="$3"
  local expected_issuer="$4"
  local actual_fingerprint actual_subject actual_issuer

  test -r "$path" || {
    printf 'Certificate is missing or unreadable: %s\n' "$path" >&2
    return 1
  }
  actual_fingerprint="$(openssl x509 -in "$path" -noout -fingerprint -sha256 \
    | cut -d= -f2 | tr -d ':')"
  actual_subject="$(openssl x509 -in "$path" -noout -subject -nameopt RFC2253 \
    | sed 's/^subject=//')"
  actual_issuer="$(openssl x509 -in "$path" -noout -issuer -nameopt RFC2253 \
    | sed 's/^issuer=//')"

  [[ "$actual_fingerprint" == "$expected_fingerprint" ]] || {
    printf 'Fingerprint mismatch for %s\nexpected=%s\nactual=%s\n' \
      "$path" "$expected_fingerprint" "$actual_fingerprint" >&2
    return 1
  }
  [[ "$actual_subject" == "$expected_subject" ]] || {
    printf 'Subject mismatch for %s\nexpected=%s\nactual=%s\n' \
      "$path" "$expected_subject" "$actual_subject" >&2
    return 1
  }
  [[ "$actual_issuer" == "$expected_issuer" ]] || {
    printf 'Issuer mismatch for %s\nexpected=%s\nactual=%s\n' \
      "$path" "$expected_issuer" "$actual_issuer" >&2
    return 1
  }
  openssl x509 -in "$path" -noout -text \
    | grep -A2 'Basic Constraints' \
    | grep -q 'CA:TRUE' || {
      printf 'Certificate is not marked CA:TRUE: %s\n' "$path" >&2
      return 1
    }

  printf 'VALID_CERTIFICATE=%s\n' "$path"
  printf 'FINGERPRINT=%s\n' "$actual_fingerprint"
  printf 'SUBJECT=%s\n' "$actual_subject"
  printf 'ISSUER=%s\n' "$actual_issuer"
}

validate_certificate "$ROOT_SOURCE" "$ROOT_FINGERPRINT" \
  "$ROOT_SUBJECT" "$ROOT_SUBJECT"
validate_certificate "$SUBORDINATE_SOURCE" "$SUBORDINATE_FINGERPRINT" \
  "$SUBORDINATE_SUBJECT" "$ROOT_SUBJECT"

openssl_dir="$(openssl version -d | awk -F'"' '{print $2}')"
if [[ -z "$openssl_dir" || "$openssl_dir" != /* ]]; then
  echo 'Could not determine the OpenSSL default directory.' >&2
  exit 1
fi
OPENSSL_CERT_FILE="${openssl_dir}/cert.pem"

path_state() {
  local path="$1"
  if [[ -L "$path" ]]; then
    printf 'symlink:%s' "$(readlink "$path")"
  elif [[ -e "$path" ]]; then
    stat -c 'file:%A:%U:%G' "$path"
  else
    printf 'missing'
  fi
}

repair_needed=0
for target in "$ROOT_TARGET" "$SUBORDINATE_TARGET"; do
  if [[ ! -r "$target" || "$(stat -Lc '%a' "$target" 2>/dev/null || true)" != 644 ]]; then
    repair_needed=1
  fi
done
if [[ ! -e "$OPENSSL_CERT_FILE" && ! -L "$OPENSSL_CERT_FILE" ]]; then
  repair_needed=1
elif [[ "$(readlink -f "$OPENSSL_CERT_FILE" 2>/dev/null || true)" != "$SYSTEM_BUNDLE" ]]; then
  repair_needed=1
fi

printf 'MODE=%s\n' "$MODE"
printf 'HOST=%s\n' "$(hostname)"
printf 'SYSTEM_BUNDLE=%s\n' "$SYSTEM_BUNDLE"
printf 'ROOT_TARGET_STATE=%s\n' "$(path_state "$ROOT_TARGET")"
printf 'SUBORDINATE_TARGET_STATE=%s\n' "$(path_state "$SUBORDINATE_TARGET")"
printf 'OPENSSL_CERT_FILE=%s\n' "$OPENSSL_CERT_FILE"
printf 'OPENSSL_CERT_FILE_STATE=%s\n' "$(path_state "$OPENSSL_CERT_FILE")"
printf 'REPAIR_NEEDED=%s\n' "$repair_needed"

if [[ "$MODE" == check ]]; then
  printf 'NEXT_COMMAND=bash %q\n' "${SCRIPT_DIR}/01-install-ca-to-fix-https-download-errors.sh"
  echo 'NOTE=the default apply mode requests sudo authentication automatically'
  exit 0
fi

request_root

need_command install
need_command update-ca-certificates
need_command tee

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
caller_user="${SUDO_USER:-root}"
caller_home="$(getent passwd "$caller_user" 2>/dev/null | cut -d: -f6 || true)"
[[ -n "$caller_home" ]] || caller_home=/root
caller_uid="$(id -u "$caller_user")"
caller_gid="$(id -g "$caller_user")"
state_root="${SOLAB_TOOLS_STATE_DIR:-${caller_home}/.local/state/solab-tools}"
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
state_root="$(readlink -m -- "${state_root}")"
case "${state_root}" in
  "${repository_root}"|"${repository_root}"/*)
    echo "ERROR: run logs must stay outside the solab-tools checkout: ${state_root}" >&2
    exit 1
    ;;
esac
out_dir="${state_root}/${stamp}-install-ca-for-https-downloads"

prepare_state_directory() {
  local default_state_root="${caller_home}/.local/state/solab-tools"
  local directory

  if [[ "${EUID}" -eq 0 && "${caller_user}" != root && "${state_root}" == "${default_state_root}" ]]; then
    for directory in "${caller_home}/.local" "${caller_home}/.local/state" "${default_state_root}"; do
      [[ ! -L "${directory}" ]] || {
        echo "Refusing to repair symlinked state directory: ${directory}" >&2
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

  install -d -o "${caller_uid}" -g "${caller_gid}" -m 0700 "$out_dir"
}

prepare_state_directory
output_log="${out_dir}/output.log"
summary_file="${out_dir}/summary.txt"
backup_dir="${out_dir}/backups"
install -d -m 0700 "$backup_dir"

status=FAIL
changed=0
network_tls=NOT_RUN

finish() {
  local rc="$?"
  trap - EXIT
  if [[ "$rc" -eq 0 ]]; then
    status=PASS
  fi
  {
    printf 'SUMMARY_STATUS=%s\n' "$status"
    printf 'HOST=%s\n' "$(hostname)"
    printf 'MODE=%s\n' "$MODE"
    printf 'CHANGED=%s\n' "$changed"
    printf 'NETWORK_TLS=%s\n' "$network_tls"
    printf 'SYSTEM_BUNDLE=%s\n' "$SYSTEM_BUNDLE"
    printf 'OPENSSL_CERT_FILE=%s\n' "$OPENSSL_CERT_FILE"
    printf 'OUTPUT_LOG=%s\n' "$output_log"
    printf 'ENDED_AT=%s\n' "$(date -Is)"
  } >"$summary_file"
  if [[ "$caller_user" != root ]]; then
    chown -R "${caller_uid}:${caller_gid}" "$out_dir" || true
  fi
  printf 'SUMMARY_FILE=%s\n' "$summary_file"
  exit "$rc"
}
trap finish EXIT
exec > >(tee -a "$output_log") 2>&1

backup_path() {
  local path="$1"
  local label="$2"
  if [[ -e "$path" || -L "$path" ]]; then
    cp -a --no-dereference "$path" "${backup_dir}/${label}"
    printf 'BACKED_UP=%s\n' "$path"
  fi
}

echo 'Installing pinned SK Hynix CA certificates.'
backup_path "$ROOT_TARGET" root_SK_Hynix_America_CA.crt.before
backup_path "$SUBORDINATE_TARGET" SK_Hynix_America_Subordinate_CA_1.crt.before
backup_path "$OPENSSL_CERT_FILE" openssl-cert.pem.before

install -d -o root -g root -m 0755 /usr/local/share/ca-certificates
install -o root -g root -m 0644 "$ROOT_SOURCE" "$ROOT_TARGET"
install -o root -g root -m 0644 "$SUBORDINATE_SOURCE" "$SUBORDINATE_TARGET"
changed=1

update-ca-certificates
test -r "$SYSTEM_BUNDLE"

resolved_cert_file="$(readlink -f "$OPENSSL_CERT_FILE" 2>/dev/null || true)"
if [[ "$resolved_cert_file" == "$SYSTEM_BUNDLE" ]]; then
  echo "OpenSSL cert.pem already resolves to ${SYSTEM_BUNDLE}."
elif [[ ! -e "$OPENSSL_CERT_FILE" || -L "$OPENSSL_CERT_FILE" && ! -e "$OPENSSL_CERT_FILE" ]]; then
  install -d -o root -g root -m 0755 "$openssl_dir"
  temporary_link="${OPENSSL_CERT_FILE}.ca-download-repair.$$"
  ln -s "$SYSTEM_BUNDLE" "$temporary_link"
  mv -Tf "$temporary_link" "$OPENSSL_CERT_FILE"
  echo "Created ${OPENSSL_CERT_FILE} -> ${SYSTEM_BUNDLE}."
elif [[ "$REPLACE_OPENSSL_CERT_FILE" -eq 1 ]]; then
  rm -f "$OPENSSL_CERT_FILE"
  ln -s "$SYSTEM_BUNDLE" "$OPENSSL_CERT_FILE"
  echo "Replaced ${OPENSSL_CERT_FILE} with a link to ${SYSTEM_BUNDLE}."
else
  echo "Refusing to replace existing ${OPENSSL_CERT_FILE}." >&2
  echo 'Review its backup, then rerun with --replace-openssl-cert-file if appropriate.' >&2
  exit 1
fi

validate_certificate "$ROOT_TARGET" "$ROOT_FINGERPRINT" \
  "$ROOT_SUBJECT" "$ROOT_SUBJECT"
validate_certificate "$SUBORDINATE_TARGET" "$SUBORDINATE_FINGERPRINT" \
  "$SUBORDINATE_SUBJECT" "$ROOT_SUBJECT"
[[ "$(stat -Lc '%a:%U:%G' "$ROOT_TARGET")" == '644:root:root' ]]
[[ "$(stat -Lc '%a:%U:%G' "$SUBORDINATE_TARGET")" == '644:root:root' ]]
[[ "$(readlink -f "$OPENSSL_CERT_FILE")" == "$SYSTEM_BUNDLE" ]]
openssl verify -CAfile "$SYSTEM_BUNDLE" "$ROOT_TARGET"
openssl verify -CAfile "$SYSTEM_BUNDLE" "$SUBORDINATE_TARGET"

if [[ "$NO_NETWORK_CHECK" -eq 1 ]]; then
  network_tls=SKIPPED
elif command -v wget >/dev/null 2>&1; then
  wget_log="${out_dir}/wget-verification.log"
  set +e
  timeout 30 wget --debug --spider --timeout=20 --tries=1 "$VERIFY_URL" \
    >"$wget_log" 2>&1
  wget_rc=$?
  set -e
  printf 'WGET_EXIT=%s\n' "$wget_rc"
  grep -Ei 'certificate|verified|HTTP/|403 Forbidden|ERROR' "$wget_log" \
    | sed -n '1,100p' || true
  if grep -Eqi 'cannot verify|certificate.*not trusted|certificate verification error' "$wget_log"; then
    network_tls=FAIL
    echo 'wget still reports a certificate verification failure.' >&2
    exit 1
  elif grep -Eq 'certificate:|connected\.' "$wget_log"; then
    network_tls=PASS
  else
    network_tls=UNREACHABLE
    echo 'Network endpoint was not reachable; offline CA verification passed.'
  fi
else
  network_tls=SKIPPED_WGET_UNAVAILABLE
fi

echo 'Internal CA installation and HTTPS trust verification completed.'
