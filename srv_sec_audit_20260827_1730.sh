#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# srv_sec_audit_20260827_1730.sh
#
# Read-only server security review collector for the 6-item DMZ checklist.
# Run on each candidate server. The host list lives in servers.conf, which is
# git-ignored; run_all.sh reads it and drives this script over SSH.
#
#   1. DMZ server usage status
#   2. Active services (ports) and communication status
#   3. Unauthorized accounts (UID >= 1000)
#   4. Long-term unaccessed (idle) accounts
#   5. Security log review (abnormal access attempts)
#   6. Command history review
#
# This script NEVER changes the system. It only reads and reports.
#
# Usage:
#   sudo ./srv_sec_audit_20260827_1730.sh                 # full run
#   IDLE_DAYS=60 sudo ./srv_sec_audit_20260827_1730.sh    # stricter idle rule
#   OUT_DIR=/tmp/rev sudo ./srv_sec_audit_20260827_1730.sh
#
# Output:
#   <OUT_DIR>/<host>_<ts>/report_<host>_<ts>.txt   summary + findings
#   <OUT_DIR>/<host>_<ts>/evidence/*.txt           raw command output (attach to form)
# ---------------------------------------------------------------------------

set -uo pipefail

IDLE_DAYS="${IDLE_DAYS:-90}"
OUT_DIR="${OUT_DIR:-$HOME/secreview}"
TS="$(date +%Y%m%d_%H%M)"
HOST="$(hostname -s 2>/dev/null || hostname)"
BASE="$OUT_DIR/${HOST}_${TS}"
EVID="$BASE/evidence"
REPORT="$BASE/report_${HOST}_${TS}.txt"

mkdir -p "$EVID" || { echo "cannot create $EVID"; exit 1; }

# ---- privilege -------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    SUDO="sudo"
  elif command -v sudo >/dev/null 2>&1; then
    echo "Some checks need root. Caching sudo credentials..."
    sudo -v && SUDO="sudo"
  fi
fi
[ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ] && \
  echo "WARNING: running without root - items 2, 5 and 6 will be incomplete."

# ---- helpers ---------------------------------------------------------------
C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_BAD=$'\033[31m'; C_H=$'\033[1m'; C_0=$'\033[0m'
[ -t 1 ] || { C_OK=""; C_WARN=""; C_BAD=""; C_H=""; C_0=""; }

declare -A ST      # per-item status: O / T (triangle) / X
declare -a NOTES   # findings, prefixed with item number

say()  { printf '%s\n' "$*" | tee -a "$REPORT"; }
hdr()  { say ""; say "${C_H}=== $* ===${C_0}"; }
ok()   { say "  ${C_OK}[OK]${C_0}   $*"; }
warn() { say "  ${C_WARN}[WARN]${C_0} $*"; NOTES+=("$1"); }
bad()  { say "  ${C_BAD}[FAIL]${C_0} $*"; NOTES+=("$1"); }
info() { say "  [info] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# capture raw evidence: cap <file> <command string>
cap() {
  local f="$EVID/$1"; shift
  { printf '$ %s\n' "$*"; eval "$*" 2>&1; printf '\n'; } >> "$f"
}

setst() { # setst <item> <status>  - only downgrades, never upgrades
  local i="$1" s="$2" cur="${ST[$1]:-O}"
  case "$cur/$s" in
    */X|X/*) ST[$i]="X" ;;
    O/T|T/*) ST[$i]="T" ;;
    *)       ST[$i]="$cur" ;;
  esac
}
for i in 1 2 3 4 5 6; do ST[$i]="O"; done

REG_USERS="$(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd)"

say "Server Security Review - $HOST"
say "Date: $(date '+%Y-%m-%d %H:%M:%S %z')   Idle threshold: ${IDLE_DAYS} days"
say "Evidence: $EVID"

# ===========================================================================
# 1. Usage status
# ===========================================================================
hdr "1. DMZ Server Usage Status Review"
cap 01_usage.txt "uptime; echo; who; echo; last -n 15 -F"
UP="$(uptime)"
info "$UP"
SESS="$(who | wc -l)"
LOAD1="$(awk '{print $1}' /proc/loadavg)"
info "Active sessions: $SESS   Load(1m): $LOAD1"
if [ "$SESS" -gt 0 ]; then
  ok "Server is in use (${SESS} active session(s))."
else
  info "No interactive session at review time (host is powered on; confirm it is still required)."
fi

# ===========================================================================
# 2. Services / ports
# ===========================================================================
hdr "2. Active Services (Ports) and Communication Status"
if have ss; then
  cap 02_ports.txt "$SUDO ss -nltup"
  LISTEN="$($SUDO ss -Hnltp 2>/dev/null)"
else
  cap 02_ports.txt "$SUDO netstat -nltup"
  LISTEN="$($SUDO netstat -nltp 2>/dev/null | tail -n +3)"
fi
cap 02_ports.txt "$SUDO lsof -nP -iTCP -sTCP:LISTEN"
cap 02_ports.txt "$SUDO iptables -L -n; $SUDO ufw status verbose; $SUDO nft list ruleset"

say "  Listening TCP sockets (non-loopback are reachable from the network):"
EXPOSED=0
while read -r line; do
  [ -z "$line" ] && continue
  addr="$(printf '%s' "$line" | awk '{print $4}')"
  proc="$(printf '%s' "$line" | sed -n 's/.*users:((\("[^"]*"\).*/\1/p' | tr -d '"')"
  [ -z "$proc" ] && proc="(unknown - run as root)"
  port="${addr##*:}"
  case "$addr" in
    127.*|\[::1\]*) info "loopback   ${addr} -> ${proc}" ;;
    0.0.0.0:*|\[::\]:*|\*:*)
      say "  ${C_WARN}ALL IFACES${C_0} ${addr} -> ${proc}"
      EXPOSED=$((EXPOSED+1))
      case "$port" in
        21|23|69|512|513|514) bad "2: legacy cleartext service on port ${port} (${proc}) - must be disabled." ;;
        111|2049) warn "2: NFS/rpcbind exposed on all interfaces (port ${port}) - restrict to the lab subnet." ;;
        9100|9090|3000) warn "2: metrics/dashboard port ${port} open without authentication - bind to localhost or firewall it." ;;
        5000|8000|8080|8888) warn "2: web/dev application port ${port} open to all interfaces - put behind a reverse proxy with TLS+auth or restrict it." ;;
        1080|3128) warn "2: proxy port ${port} reachable from the network - confirm it is not an egress bypass." ;;
      esac ;;
    *) say "  ${C_WARN}IFACE${C_0}      ${addr} -> ${proc}"; EXPOSED=$((EXPOSED+1)) ;;
  esac
done <<< "$LISTEN"

if printf '%s' "$LISTEN" | grep -qE '(^|[^0-9])(:21|:23)\b'; then
  bad "2: Telnet or FTP is running."
else
  ok "No Telnet/FTP listener found."
fi
if printf '%s' "$LISTEN" | grep -q 'unknown\|users:((' ; then :; fi
if [ -z "$SUDO" ] && [ "$(id -u)" -ne 0 ]; then
  warn "2: process names unavailable without root - re-run with sudo to attribute every listener."
fi
[ "$EXPOSED" -gt 0 ] && setst 2 T

# sshd effective config
if have sshd; then
  cap 02_sshd.txt "$SUDO sshd -T"
  SSHDT="$($SUDO sshd -T 2>/dev/null)"
  PRL="$(printf '%s' "$SSHDT" | awk '/^permitrootlogin/{print $2}')"
  PWA="$(printf '%s' "$SSHDT" | awk '/^passwordauthentication/{print $2}')"
  SPORT="$(printf '%s' "$SSHDT" | awk '/^port /{print $2}' | tr '\n' ',' | sed 's/,$//')"
  info "sshd: port=${SPORT:-?}  PermitRootLogin=${PRL:-?}  PasswordAuthentication=${PWA:-?}"
  case "$PRL" in
    no|prohibit-password|forced-commands-only) ok "Root SSH login restricted (${PRL})." ;;
    yes) bad "2: PermitRootLogin=yes - direct root SSH login must be disabled." ;;
  esac
  if [ "$PWA" = "yes" ]; then
    warn "2: PasswordAuthentication=yes - shared/weak passwords are directly exploitable; move to key-only auth."
  else
    ok "Password authentication disabled (key-only)."
  fi
fi

# NFS export scope
if [ -s /etc/exports ]; then
  cap 02_nfs.txt "cat /etc/exports; $SUDO exportfs -v; showmount -e localhost"
  if grep -vE '^\s*#' /etc/exports | grep -q '\*'; then
    bad "2: /etc/exports contains a wildcard host (*) - any client can mount."
  fi
  if grep -q 'no_root_squash' /etc/exports; then
    bad "2: /etc/exports uses no_root_squash - remote root gets local root on the share."
  fi
fi

# ===========================================================================
# 3. Accounts
# ===========================================================================
hdr "3. Server Account Status Review (UID >= 1000)"
cap 03_accounts.txt "cat /etc/passwd"
cap 03_accounts.txt "awk -F: '\$3>=1000 && \$3<65534 {print \$1, \$3, \$5, \$7}' /etc/passwd"
cap 03_accounts.txt "getent group sudo adm admin wheel"
cap 03_accounts.txt "$SUDO cat /etc/sudoers; $SUDO ls -la /etc/sudoers.d/; $SUDO cat /etc/sudoers.d/*"
cap 03_accounts.txt "$SUDO find /home /root -maxdepth 3 -name authorized_keys -exec ls -la {} \;"
cap 03_accounts.txt "$SUDO find /home -xdev \( -nouser -o -nogroup \) -maxdepth 3"

say "  UID >= 1000 accounts:"
NUSERS=0
for u in $REG_USERS; do
  NUSERS=$((NUSERS+1))
  ent="$(getent passwd "$u")"
  uid="$(printf '%s' "$ent" | cut -d: -f3)"
  gec="$(printf '%s' "$ent" | cut -d: -f5 | tr -d ',')"
  sh="$(printf '%s' "$ent" | cut -d: -f7)"
  st="$($SUDO passwd -S "$u" 2>/dev/null | awk '{print $2}')"
  info "$(printf '%-12s uid=%-6s shell=%-16s pwstatus=%-3s gecos=%s' "$u" "$uid" "$sh" "${st:-?}" "${gec:-<empty>}")"
  [ -z "$gec" ] && warn "3: account '$u' has an empty GECOS field - record the owner's real name and affiliation."
  [ "$st" = "NP" ] && bad "3: account '$u' has NO PASSWORD set."
done
info "Total UID>=1000 accounts: $NUSERS"

DUP0="$(awk -F: '$3==0 {print $1}' /etc/passwd | grep -vx root)"
if [ -n "$DUP0" ]; then
  bad "3: non-root account(s) with UID 0: $DUP0"
else
  ok "No non-root UID 0 account."
fi

SUDOERS="$(getent group sudo 2>/dev/null | cut -d: -f4)"
info "sudo group members: ${SUDOERS:-<none>}"

# UID gaps -> previously deleted accounts
GAPS="$(awk -F: '$3>=1000 && $3<65534 {print $3}' /etc/passwd | sort -n | \
  awk 'NR==1{p=$1;next}{ if ($1>p+1) for(i=p+1;i<$1;i++) printf "%d ", i; p=$1 }')"
[ -n "$GAPS" ] && warn "3: UID gap(s) ${GAPS}- an account was probably deleted; confirm it was approved and that its home directory and SSH keys were removed."

ORPH="$($SUDO find /home -xdev \( -nouser -o -nogroup \) -maxdepth 3 2>/dev/null | head -5)"
[ -n "$ORPH" ] && warn "3: files owned by a deleted user remain under /home: $(printf '%s' "$ORPH" | tr '\n' ' ')"

# ===========================================================================
# 4. Idle accounts
# ===========================================================================
hdr "4. Long-term Unaccessed (Idle) Accounts  [threshold ${IDLE_DAYS}d]"
cap 04_idle.txt "lastlog"
cap 04_idle.txt "lastlog -b $IDLE_DAYS"
for u in $REG_USERS; do cap 04_idle.txt "$SUDO chage -l $u"; done

IDLE_LIST=""; NEVER_LIST=""
for u in $REG_USERS; do
  line="$(lastlog -u "$u" 2>/dev/null | tail -n +2)"
  if printf '%s' "$line" | grep -q 'Never logged in'; then
    NEVER_LIST="$NEVER_LIST $u"
  elif lastlog -b "$IDLE_DAYS" -u "$u" 2>/dev/null | tail -n +2 | grep -q .; then
    IDLE_LIST="$IDLE_LIST $u"
    info "IDLE   $line"
  else
    ok "active $u"
  fi
  exp="$($SUDO chage -l "$u" 2>/dev/null | awk -F: '/Password expires/{print $2}' | xargs)"
  [ "$exp" = "never" ] && warn "4: account '$u' has no password expiry set."
done
[ -n "$NEVER_LIST" ] && bad "4: account(s) never logged in but still enabled:$NEVER_LIST"
[ -n "$IDLE_LIST" ]  && bad "4: account(s) idle for more than ${IDLE_DAYS} days:$IDLE_LIST"
[ -z "$NEVER_LIST" ] && [ -z "$IDLE_LIST" ] && ok "No idle account beyond ${IDLE_DAYS} days."

# ===========================================================================
# 5. Security logs
# ===========================================================================
hdr "5. Server Security Log Review"
cap 05_logs.txt "$SUDO lastb"
cap 05_logs.txt "last -F -n 50"
cap 05_logs.txt "$SUDO grep -hE 'Failed password|Invalid user|Accepted ' /var/log/auth.log /var/log/auth.log.1 /var/log/secure 2>/dev/null | tail -300"
cap 05_logs.txt "$SUDO ls -la /var/log/btmp /var/log/wtmp /var/log/auth.log*"

BTMP="$($SUDO lastb 2>/dev/null)"
FAILN="$(printf '%s' "$BTMP" | grep -vc 'btmp begins\|^$' 2>/dev/null)"
BEGIN="$(printf '%s' "$BTMP" | grep 'btmp begins' | sed 's/btmp begins //')"
info "Failed logins in btmp: ${FAILN:-0}   (btmp begins: ${BEGIN:-unknown})"
if [ "${FAILN:-0}" -gt 0 ]; then
  say "  Failures by user:";  printf '%s' "$BTMP" | grep -v 'btmp begins' | awk 'NF{print "    "$1}' | sort | uniq -c | sort -rn | head -10 | tee -a "$REPORT"
  say "  Failures by source:"; printf '%s' "$BTMP" | grep -v 'btmp begins' | awk 'NF{print "    "$3}' | sort | uniq -c | sort -rn | head -10 | tee -a "$REPORT"
fi
# failures for usernames that do not exist locally
if [ -n "$BTMP" ]; then
  for n in $(printf '%s' "$BTMP" | grep -v 'btmp begins' | awk 'NF{print $1}' | sort -u); do
    getent passwd "$n" >/dev/null 2>&1 || warn "5: failed login for non-existent user '$n' - identify the source host/owner."
  done
fi
if [ "${FAILN:-0}" -gt 100 ]; then
  bad "5: ${FAILN} failed logins - check for brute-force from a single source."
elif [ "${FAILN:-0}" -eq 0 ]; then
  ok "No failed login attempts recorded."
fi
INVAL="$($SUDO grep -hc 'Invalid user' /var/log/auth.log 2>/dev/null)"
[ -n "${INVAL:-}" ] && [ "${INVAL:-0}" -gt 0 ] && warn "5: ${INVAL} 'Invalid user' entries in auth.log - review the sources."
# retention
if [ -n "$BEGIN" ]; then
  bsec="$(date -d "$BEGIN" +%s 2>/dev/null)"
  if [ -n "$bsec" ]; then
    days=$(( ( $(date +%s) - bsec ) / 86400 ))
    info "btmp retention: ~${days} days"
    [ "$days" -lt 90 ] && warn "5: btmp only covers ~${days} days - extend log retention to cover the audit period."
  fi
fi

# ===========================================================================
# 6. Command history
# ===========================================================================
hdr "6. Command History Review"
cap 06_history.txt "$SUDO ls -la /root/"
cap 06_history.txt "$SUDO cat /root/.bash_history"
for u in $REG_USERS; do cap 06_history.txt "$SUDO ls -la /home/$u/.bash_history; $SUDO tail -n 100 /home/$u/.bash_history"; done
cap 06_history.txt "$SUDO crontab -l; for u in $REG_USERS; do echo \"--- \$u\"; $SUDO crontab -l -u \$u; done"
cap 06_history.txt "ls -la /etc/cron.d /etc/cron.daily; $SUDO systemctl list-timers --all"
cap 06_history.txt "$SUDO grep -rh HISTTIMEFORMAT /etc/profile /etc/profile.d/ /root/.bashrc 2>/dev/null"

RH=/root/.bash_history
if $SUDO test -L "$RH" 2>/dev/null; then
  bad "6: /root/.bash_history is a SYMLINK ($($SUDO readlink -f $RH)) - history suppression; investigate."
elif $SUDO test -e "$RH" 2>/dev/null; then
  n="$($SUDO wc -l < "$RH" 2>/dev/null)"
  ok "/root/.bash_history present (${n} lines) - reviewed in evidence/06_history.txt."
else
  warn "6: /root/.bash_history does not exist - item 6 cannot be evidenced from root history; use sudo entries in auth.log instead."
fi

# suspicious patterns (informational - every hit needs human judgement)
PAT='curl .*\|.*sh|wget .*\|.*sh|base64 -d|nc -l|/dev/tcp/|chattr \+i|history -c|shred |authorized_keys|useradd |userdel |passwd |chmod 777|perf_event_paranoid|insmod |setenforce 0|iptables -F'
HITS="$($SUDO grep -nEh "$PAT" "$RH" /home/*/.bash_history 2>/dev/null | head -40)"
if [ -n "$HITS" ]; then
  warn "6: commands worth explaining were found in shell history (see below and evidence/06_history.txt):"
  printf '%s\n' "$HITS" | sed 's/^/      /' | tee -a "$REPORT" >/dev/null
  printf '%s\n' "$HITS" | sed 's/^/      /'
else
  ok "No pattern-matched suspicious command found in available histories."
fi
if ! $SUDO grep -rqh HISTTIMEFORMAT /etc/profile /etc/profile.d/ 2>/dev/null; then
  warn "6: HISTTIMEFORMAT is not set - shell history has no timestamps."
fi
CRON="$($SUDO crontab -l 2>/dev/null | grep -vc '^#')"
[ "${CRON:-0}" -gt 0 ] && info "root crontab has ${CRON} entries - verify each in evidence/06_history.txt."
PRELOAD=/etc/ld.so.preload
$SUDO test -e "$PRELOAD" && bad "6: ${PRELOAD} exists - classic rootkit hook, investigate immediately."

# ===========================================================================
# Summary
# ===========================================================================
# derive statuses from findings
for n in "${NOTES[@]:-}"; do
  case "$n" in
    1:*) setst 1 T ;; 2:*) setst 2 T ;; 3:*) setst 3 T ;;
    4:*) setst 4 X ;; 5:*) setst 5 T ;; 6:*) setst 6 T ;;
  esac
done
sym() { case "$1" in O) printf 'O';; T) printf '△';; X) printf 'X';; esac; }

hdr "SUMMARY - paste into the review form"
say "  Host: $HOST   Date: $(date '+%Y-%m-%d')"
say ""
say "  No  Check item                                      Status"
say "  1   DMZ server usage                                $(sym "${ST[1]}")"
say "  2   Active services (ports)                         $(sym "${ST[2]}")"
say "  3   Unauthorized accounts (UID>=1000)               $(sym "${ST[3]}")"
say "  4   Long-term unaccessed (idle) accounts            $(sym "${ST[4]}")"
say "  5   Abnormal access attempts                        $(sym "${ST[5]}")"
say "  6   Suspicious command history                      $(sym "${ST[6]}")"
say ""
say "  Legend: O = compliant, △ = action recommended, X = non-compliant"
say ""
if [ "${#NOTES[@]}" -gt 0 ]; then
  say "  Findings (${#NOTES[@]}):"
  i=1; for n in "${NOTES[@]}"; do say "   $i. $n"; i=$((i+1)); done
else
  say "  No findings."
fi
say ""
# One machine-readable line per host, so run_all.sh can assemble the Summary
# matrix without re-parsing the human report. O/T/X are kept as letters because
# the spreadsheet renders them as O / triangle / X.
printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$HOST" "$(date +%Y-%m-%d)" "${ST[1]}" "${ST[2]}" "${ST[3]}" "${ST[4]}" "${ST[5]}" "${ST[6]}" \
  "${#NOTES[@]}" > "$BASE/summary.csv"

say "  Report:   $REPORT"
say "  Summary:  $BASE/summary.csv  (host,date,item1..6,findings)"
say "  Evidence: $EVID  (attach these as the Evidence column screenshots)"

# ---------------------------------------------------------------------------
# Paste-safe transport for the report.
#
# Copying the console output above out of a terminal damages it: every line
# longer than the window is padded to the window width, and that padding lands
# inside the line rather than starting a new one. "PasswordAuthenticati<pad>on"
# and "restrict to the<pad>lab subnet" then look identical to a parser, but one
# needs a space restored and the other does not.
#
# Base64 sidesteps it completely, because any wrapping the terminal adds is
# whitespace that the decoder strips. The block below carries the report and the
# summary row exactly as written to disk, and is a few KB - small enough to
# paste into a chat or an email.
# ---------------------------------------------------------------------------
if command -v base64 >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
  PACK="$(tar -czf - -C "$BASE" "$(basename "$REPORT")" summary.csv 2>/dev/null \
          | base64 2>/dev/null | tr -d '\n')"
  if [ -n "$PACK" ]; then
    printf '%s\n' "$PACK" > "$BASE/report_pack.b64"
    echo
    echo "=== BEGIN REPORT PACK (${HOST}) - copy this whole block ==="
    # Printed in 100-character rows so it is readable; the decoder ignores the
    # line breaks, and so does any further wrapping the terminal applies.
    printf '%s' "$PACK" | fold -w 100
    echo
    echo "=== END REPORT PACK (${HOST}) ==="
    echo "(also saved to $BASE/report_pack.b64)"
  fi
fi
say ""
say "  Reminder: this script changes nothing. Apply fixes with the remediation"
say "  guide, then re-run to confirm the status improves."
