#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Diagnose active APT source connectivity with bounded read-only probes.
set -Eeuo pipefail
export LC_ALL=C

MAX_TOTAL_SECONDS="${APT_DIAG_MAX_TOTAL_SECONDS:-1200}"
CURL_MAX_SECONDS="${APT_DIAG_CURL_MAX_SECONDS:-12}"
started_epoch="$(date +%s)"

usage() {
  cat <<'EOF'
Usage:
  diagnose_apt_sources.sh

Read active APT source definitions and run bounded IPv4, IPv6, TLS, and wget
connectivity probes. The script is read-only. Insecure HTTPS probes are control
measurements only, discard response bodies, and never change APT configuration.

Environment variables:
  APT_DIAG_URL_FILE=FILE          Add one HTTP or HTTPS probe URL per line.
  APT_DIAG_MAX_TOTAL_SECONDS=N    Overall limit. Default: 1200.
  APT_DIAG_CURL_MAX_SECONDS=N     Per-curl limit. Default: 12.
EOF
}

case "${1:-}" in
  "") ;;
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
[[ "$#" -le 1 ]] || {
  usage >&2
  echo "ERROR: too many arguments" >&2
  exit 2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

for command_name in awk curl date dpkg mktemp sed sort timeout tr wget; do
  command -v "${command_name}" >/dev/null 2>&1 || die "missing required command: ${command_name}"
done
[[ "${MAX_TOTAL_SECONDS}" =~ ^[0-9]+$ ]] && (( MAX_TOTAL_SECONDS > 0 )) || \
  die "APT_DIAG_MAX_TOTAL_SECONDS must be a positive integer"
[[ "${CURL_MAX_SECONDS}" =~ ^[0-9]+$ ]] && (( CURL_MAX_SECONDS > 0 )) || \
  die "APT_DIAG_CURL_MAX_SECONDS must be a positive integer"

work_dir="$(mktemp -d)"
cleanup() {
  find "${work_dir}" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT
rows_file="${work_dir}/sources.tsv"
urls_file="${work_dir}/urls.txt"
: >"${rows_file}"
: >"${urls_file}"

apt_arch="$(dpkg --print-architecture 2>/dev/null || true)"
apt_arch="${apt_arch:-amd64}"

redact_url() {
  sed -E 's#(https?://)[^/@[:space:]]+@#\1<redacted>@#' <<<"$1"
}

make_probe() {
  local uri="$1"
  local suite="$2"
  uri="${uri//\$\(ARCH\)/${apt_arch}}"
  uri="${uri//\$\(ARCHITECTURE\)/${apt_arch}}"
  uri="${uri%/}"
  if [[ "${suite}" == */ ]]; then
    printf '%s/%sInRelease\n' "${uri}" "${suite}"
  else
    printf '%s/dists/%s/InRelease\n' "${uri}" "${suite}"
  fi
}

add_source_row() {
  local source_file="$1"
  local uri="$2"
  local suite="$3"
  local probe
  [[ -n "${uri}" && -n "${suite}" ]] || return 0
  probe="$(make_probe "${uri}" "${suite}")"
  printf '%s\t%s\t%s\t%s\n' "${source_file}" "${uri}" "${suite}" "${probe}" >>"${rows_file}"
  case "${probe}" in
    http://*|https://*) printf '%s\n' "${probe}" >>"${urls_file}" ;;
  esac
}

parse_list_file() {
  local source_file="$1"
  local raw line uri suite
  local -a fields
  while IFS= read -r raw || [[ -n "${raw}" ]]; do
    line="${raw#"${raw%%[![:space:]]*}"}"
    [[ -n "${line}" && "${line}" != \#* ]] || continue
    [[ "${line}" == deb\ * || "${line}" == deb-src\ * ]] || continue
    read -r -a fields <<<"${line}"
    fields=("${fields[@]:1}")
    if [[ "${fields[0]:-}" == \[* ]]; then
      while [[ "${#fields[@]}" -gt 0 && "${fields[0]}" != *\] ]]; do
        fields=("${fields[@]:1}")
      done
      [[ "${#fields[@]}" -gt 0 ]] && fields=("${fields[@]:1}")
    fi
    uri="${fields[0]:-}"
    suite="${fields[1]:-}"
    add_source_row "${source_file}" "${uri}" "${suite}"
  done <"${source_file}"
}

parse_deb822_file() {
  local source_file="$1"
  while IFS=$'\t' read -r uri suite; do
    add_source_row "${source_file}" "${uri}" "${suite}"
  done < <(
    awk '
      function emit(    uri_count, suite_count, uris_array, suites_array, i, j, enabled_lc, types_lc) {
        enabled_lc = tolower(enabled)
        types_lc = " " tolower(types) " "
        if (enabled_lc == "no" || enabled_lc == "false" || enabled_lc == "0") { reset(); return }
        if (types != "" && types_lc !~ / deb /) { reset(); return }
        uri_count = split(uris, uris_array, /[[:space:]]+/)
        suite_count = split(suites, suites_array, /[[:space:]]+/)
        for (i = 1; i <= uri_count; i++)
          for (j = 1; j <= suite_count; j++)
            if (uris_array[i] != "" && suites_array[j] != "")
              print uris_array[i] "\t" suites_array[j]
        reset()
      }
      function reset() { enabled="yes"; types="deb"; uris=""; suites=""; current="" }
      BEGIN { reset() }
      /^[[:space:]]*$/ { emit(); next }
      /^[[:space:]]/ {
        value=$0; sub(/^[[:space:]]+/, "", value)
        if (current == "uris") uris = uris " " value
        else if (current == "suites") suites = suites " " value
        else if (current == "types") types = types " " value
        next
      }
      {
        split($0, pair, ":")
        key=tolower(pair[1])
        value=$0; sub(/^[^:]*:[[:space:]]*/, "", value)
        current=key
        if (key == "enabled") enabled=value
        else if (key == "types") types=value
        else if (key == "uris") uris=value
        else if (key == "suites") suites=value
      }
      END { emit() }
    ' "${source_file}"
  )
}

shopt -s nullglob
source_files=(
  /etc/apt/sources.list
  /etc/apt/sources.list.d/*.list
  /etc/apt/sources.list.d/*.sources
)
shopt -u nullglob
for source_file in "${source_files[@]}"; do
  [[ -r "${source_file}" ]] || {
    echo "SOURCE_READ_ERROR\t${source_file}"
    continue
  }
  if [[ "${source_file}" == *.sources ]]; then
    parse_deb822_file "${source_file}"
  else
    parse_list_file "${source_file}"
  fi
done

echo "=== parsed active APT sources ==="
[[ -s "${rows_file}" ]] || {
  echo "NO_ACTIVE_APT_SOURCES=1"
  exit 1
}
echo $'source_file\tconfigured_uri\tsuite\tprobe_url'
while IFS=$'\t' read -r source_file uri suite probe; do
  printf '%s\t%s\t%s\t%s\n' \
    "${source_file}" "$(redact_url "${uri}")" "${suite}" "$(redact_url "${probe}")"
done <"${rows_file}"

if [[ -n "${APT_DIAG_URL_FILE:-}" ]]; then
  if [[ -r "${APT_DIAG_URL_FILE}" ]]; then
    while IFS= read -r extra_url || [[ -n "${extra_url}" ]]; do
      case "${extra_url}" in
        http://*|https://*) printf '%s\n' "${extra_url}" >>"${urls_file}" ;;
      esac
    done <"${APT_DIAG_URL_FILE}"
  else
    echo "EXTRA_URL_FILE_ERROR\t${APT_DIAG_URL_FILE}\tunreadable"
  fi
fi
sort -u -o "${urls_file}" "${urls_file}"

check_deadline() {
  local elapsed="$(( $(date +%s) - started_epoch ))"
  (( elapsed < MAX_TOTAL_SECONDS )) || die "diagnostic exceeded ${MAX_TOTAL_SECONDS} seconds"
}

classify_curl() {
  local rc="$1"
  local http_code="$2"
  if (( rc == 0 )); then
    case "${http_code}" in
      2*|3*) echo OK ;;
      401|403) echo REACHABLE_AUTH_OR_POLICY ;;
      404) echo REACHABLE_BUT_INRELEASE_MISSING ;;
      *) echo "HTTP_${http_code:-UNKNOWN}" ;;
    esac
    return
  fi
  case "${rc}" in
    5) echo PROXY_DNS_FAIL ;;
    6) echo DNS_FAIL ;;
    7) echo CONNECT_FAIL ;;
    28|124) echo TIMEOUT ;;
    35) echo TLS_HANDSHAKE_FAIL ;;
    47) echo REDIRECT_LOOP ;;
    56) echo RECV_FAIL ;;
    60) echo TLS_CERT_FAIL ;;
    *) echo "CURL_RC_${rc}" ;;
  esac
}

curl_probe() {
  local mode="$1"
  local url="$2"
  local error_file metrics rc http_code remote_ip connect_s tls_s total_s result error_text
  local -a flags=(-4)
  [[ "${mode}" == *ipv6* ]] && flags=(-6)
  [[ "${mode}" == *insecure* ]] && flags+=(-k)
  error_file="$(mktemp "${work_dir}/curl-error.XXXXXX")"
  set +e
  metrics="$(timeout 20s curl -sS -L --connect-timeout 5 --max-time "${CURL_MAX_SECONDS}" \
    --range 0-0 -o /dev/null \
    -w $'%{http_code}\t%{remote_ip}\t%{time_connect}\t%{time_appconnect}\t%{time_total}' \
    "${flags[@]}" "${url}" 2>"${error_file}")"
  rc=$?
  set -e
  IFS=$'\t' read -r http_code remote_ip connect_s tls_s total_s <<<"${metrics}"
  result="$(classify_curl "${rc}" "${http_code:-}")"
  error_text="$(tr '\n' ' ' <"${error_file}" | head -c 240)"
  error_text="${error_text//"${url}"/<url>}"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${mode}" "${result}" "${rc}" "${http_code:-}" "${remote_ip:-}" \
    "${total_s:-}" "$(redact_url "${url}")" "${error_text}"
}

echo
echo "=== bounded curl probes ==="
echo $'mode\tresult\trc\thttp\tremote_ip\ttotal_s\turl\terror'
while IFS= read -r configured; do
  [[ -n "${configured}" ]] || continue
  check_deadline
  curl_probe configured_ipv4_secure "${configured}"
  case "${configured}" in
    http://*) https_url="https://${configured#http://}" ;;
    https://*) https_url="${configured}" ;;
    *) continue ;;
  esac
  check_deadline
  curl_probe https_ipv4_secure "${https_url}"
  check_deadline
  curl_probe https_ipv4_insecure "${https_url}"
  check_deadline
  curl_probe https_ipv6_insecure "${https_url}"
done <"${urls_file}"

echo
echo "=== wget HTTPS insecure cross-check ==="
echo $'mode\tresult\trc\turl'
while IFS= read -r configured; do
  [[ -n "${configured}" ]] || continue
  case "${configured}" in
    http://*) https_url="https://${configured#http://}" ;;
    https://*) https_url="${configured}" ;;
    *) continue ;;
  esac
  check_deadline
  set +e
  timeout 15s wget --spider --quiet --timeout=10 --tries=1 \
    --no-check-certificate "${https_url}"
  wget_rc=$?
  set -e
  if (( wget_rc == 0 )); then
    wget_result=OK
  else
    wget_result="WGET_RC_${wget_rc}"
  fi
  printf 'wget_https_insecure\t%s\t%s\t%s\n' \
    "${wget_result}" "${wget_rc}" "$(redact_url "${https_url}")"
done < <(
  while IFS= read -r url; do
    case "${url}" in
      http://*) echo "https://${url#http://}" ;;
      https://*) echo "${url}" ;;
    esac
  done <"${urls_file}" | sort -u
)
