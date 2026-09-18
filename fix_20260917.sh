#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fix_20260917.sh  -  apply the safe, reversible fixes from the 2026-09-16 review.
#
# Supersedes quickfix_20260827_1800.sh, which this extends with password expiry,
# log retention and a clearer account-locking rule.
#
# WHAT IT CHANGES (all reversible, undo printed for each):
#   1. the administrator password                        (interactive, never stored)
#   2. locks idle / never-used collaborator accounts     (usermod -L + nologin)
#   3. sets password expiry on every account that stays  (chage -M 180 -W 14)
#   4. extends btmp / wtmp retention to 12 months        (logrotate)
#
# WHAT IT REFUSES TO CHANGE, and why:
#   - sshd_config (PasswordAuthentication, PermitRootLogin). Getting this wrong
#     locks everyone out of a machine reachable only over SSH, and the review is
#     not worth an outage. The exact commands are printed at the end, to be run
#     with a second session already open.
#   - NFS exports and firewall rules. Narrowing an export or adding a rule can
#     silently break a running job on another host; someone has to know which
#     mounts are live.
#   - Docker-published metrics ports (9100, 9090, 3000). The fix is a one-line
#     edit in the compose file plus a container restart, which belongs to
#     whoever owns the stack.
#   Each of these is printed with the command to run, so nothing is lost -- it
#   is just not done behind your back.
#
# NOT covered, on purpose: locking an account disables its PASSWORD. If the
# account also has an authorized_keys file, key login still works. Check with
#   sudo find /home -name authorized_keys -exec ls -la {} \;
# and remove or rename the file for anyone whose access is meant to end.
#
# SAFETY RULES BUILT IN:
#   - the administrator account is never locked
#   - an account with a live session is never locked, even if it looks idle
#   - every change prints its own undo line
#   - --dry-run shows everything and changes nothing
#
# Usage:
#   sudo ADMIN_USER=labuser ./fix_20260917.sh              # prompts before each step
#   sudo ADMIN_USER=labuser ./fix_20260917.sh --dry-run    # show, change nothing
#   sudo ADMIN_USER=labuser ./fix_20260917.sh -y           # no prompts
#   IDLE_DAYS=60 sudo -E ADMIN_USER=labuser ./fix_20260917.sh
#
# The new password is read interactively and never appears in a file, in the
# environment, or in your shell history. Do not pass it on the command line.
# ---------------------------------------------------------------------------
set -uo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

IDLE_DAYS="${IDLE_DAYS:-90}"
ADMIN="${ADMIN_USER:?set ADMIN_USER=<admin account name>, e.g. ADMIN_USER=labuser}"
getent passwd "$ADMIN" >/dev/null || { echo "no such account: $ADMIN"; exit 1; }

YES=0; DRY=0
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    -n|--dry-run) DRY=1 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"; SSH_PORT="${SSH_PORT:-22}"
HOST="$(hostname -s 2>/dev/null || hostname)"
USERS="$(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd)"
LOGGED_IN="$(who | awk '{print $1}' | sort -u)"

ask() { [ "$DRY" -eq 1 ] && return 1; [ "$YES" -eq 1 ] && return 0
        read -rp "  -> $1 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ]; }
run() { if [ "$DRY" -eq 1 ]; then echo "     DRY-RUN: $*"; else eval "$@"; fi; }

echo "=== fix on ${HOST} ==="
echo "    admin=${ADMIN}  ssh port=${SSH_PORT}  idle threshold=${IDLE_DAYS}d"
[ "$DRY" -eq 1 ] && echo "    DRY RUN - nothing will be changed"
echo

# --- 1. administrator password --------------------------------------------
echo "[1] Administrator password for '${ADMIN}'"
if [ "$DRY" -eq 1 ]; then
  echo "     DRY-RUN: would prompt for a new password and apply it with chpasswd"
elif ask "change the '${ADMIN}' password now?"; then
  # read -s so it is never echoed; chpasswd via stdin so it never becomes an
  # argument, which would put it in the process list for every user to see.
  printf '     new password: '; read -rs P1; echo
  printf '     repeat      : '; read -rs P2; echo
  if [ -z "$P1" ]; then
    echo "     empty - skipped"
  elif [ "$P1" != "$P2" ]; then
    echo "     they do not match - skipped"
  else
    printf '%s:%s\n' "$ADMIN" "$P1" | chpasswd && echo "     changed"
  fi
  unset P1 P2
fi
echo

# --- 2. idle and never-used accounts ---------------------------------------
echo "[2] Idle / never-used collaborator accounts"
LOCKED=""
for u in $USERS; do
  [ "$u" = "$ADMIN" ] && continue
  case " $LOGGED_IN " in
    *" $u "*) echo "  $u: has a live session - not touched"; continue ;;
  esac
  line="$(lastlog -u "$u" 2>/dev/null | tail -n +2)"
  why=""
  printf '%s' "$line" | grep -q 'Never logged in' && why="never logged in"
  if [ -z "$why" ] && lastlog -b "$IDLE_DAYS" -u "$u" 2>/dev/null | tail -n +2 | grep -q .; then
    why="idle > ${IDLE_DAYS}d"
  fi
  [ -z "$why" ] && continue
  echo "  $u: $why"
  printf '%s\n' "$line" | sed 's/^/       /'
  if ask "lock '$u'?"; then
    run "usermod -L '$u'"
    run "usermod -s /usr/sbin/nologin '$u'"
    run "chage -E 0 '$u'"
    LOCKED="$LOCKED $u"
    echo "       undo: usermod -U $u; chage -E -1 $u; usermod -s /bin/bash $u"
  fi
done
[ -z "$LOCKED" ] && echo "  nothing to lock"
echo

# --- 3. password expiry (Medium finding, every host) ------------------------
echo "[3] Password expiry on the accounts that stay"
for u in $USERS; do
  case " $LOCKED " in *" $u "*) continue ;; esac
  exp="$(chage -l "$u" 2>/dev/null | awk -F: '/Password expires/{print $2}' | xargs)"
  [ "$exp" != "never" ] && continue
  if ask "set 180-day expiry with 14-day warning on '$u'?"; then
    run "chage -M 180 -W 14 '$u'"
    echo "       undo: chage -M 99999 -W 7 $u"
  fi
done
echo

# --- 4. log retention (Low finding, but it is why item 5 carries no assurance) --
echo "[4] Log retention - the review found 5 to 15 days, short of the audit period"
for f in /etc/logrotate.d/btmp /etc/logrotate.d/wtmp; do
  [ -f "$f" ] || continue
  cur="$(awk '/rotate/{print $2; exit}' "$f")"
  echo "  $f: rotate ${cur:-?}"
  if [ "${cur:-0}" -lt 12 ] 2>/dev/null && ask "raise $(basename "$f") retention to 12 months?"; then
    run "cp -n '$f' '$f.bak-20260917'"
    run "sed -i 's/^\([[:space:]]*\)rotate .*/\1rotate 12/' '$f'"
    echo "       undo: mv $f.bak-20260917 $f"
  fi
done
echo "  note: auth.log rotates via /etc/logrotate.d/rsyslog - review that separately"
echo

# --- what this script will not do -------------------------------------------
cat <<'MANUAL'
=== NOT done by this script - run these yourself, with a second SSH session open ===

A. Key-only SSH authentication  (Medium, every host)
   Verify your key works FIRST, in another session, then:
     sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
     sudo sshd -t && sudo systemctl reload ssh
   Undo: set it back to yes and reload. Do not close the working session until a
   new one has been opened successfully.

B. NFS / rpcbind on all interfaces  (Medium; ports 111 and 2049)
     cat /etc/exports          # check every entry is scoped to the lab subnet
     sudo exportfs -v          # confirm root_squash, no wildcard host
   Then firewall 111 and 2049 to the lab subnet. Check for live mounts first:
     showmount -a localhost

C. Unauthenticated metrics and dashboards  (Medium; node_exporter 9100,
   Prometheus 9090, Grafana 3000)
     sudo ss -ltnp 'sport = :9100'        # identify the container
     sudo docker ps --format '{{.Names}}\t{{.Ports}}'
   Fix in the compose file by binding to localhost, e.g. "127.0.0.1:9100:9100",
   then recreate the container. Grafana on 3000 additionally needs a real
   admin password.

D. Web applications open to all interfaces  (High; e.g. Flask on 5000, 8080)
     sudo ss -ltnp 'sport = :5000'        # substitute the port the audit named
   Put behind a reverse proxy with TLS and authentication, or bind to localhost.

E. Shell history that needs an explanation  (Medium, every host)
   Read evidence/06_history.txt and record why each flagged command was run.
   Watch in particular for 'curl --insecure ... | bash' and hand-added
   authorized_keys entries, both of which were findings in the August review.

F. Empty GECOS fields  (Low, every host)
     sudo chfn -f "Full Name, Affiliation" <user>
   Cannot be automated - only you know who each account belongs to.
MANUAL

echo
echo "=== done on ${HOST} ==="
[ -n "$LOCKED" ] && echo "    locked:$LOCKED"
echo "    re-run srv_sec_audit_20260827_1730.sh to confirm items 3, 4, 5 and 6 improve."
