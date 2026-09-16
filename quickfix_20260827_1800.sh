#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# quickfix_20260827_1800.sh   -   the 10-minute version
#
# Does ONLY the safe, reversible fixes. It does NOT touch sshd_config and does
# NOT enable a firewall, so it cannot lock you out of the server.
#
#   1. lock collaborator accounts idle > IDLE_DAYS (reversible)
#   2. set password expiry on the accounts that stay
#   3. install fail2ban for the SSH port
#   4. turn on shell history timestamps + longer retention
#   5. remind you to change the labuser password (interactive)
#
# Usage:  sudo ./quickfix_20260827_1800.sh          # asks before each change
#         sudo ./quickfix_20260827_1800.sh -y       # no prompts
#         IDLE_DAYS=60 sudo ./quickfix_20260827_1800.sh
#
# Undo:   sudo usermod -U <user>; sudo chage -E -1 <user>; sudo usermod -s /bin/bash <user>
# ---------------------------------------------------------------------------
set -uo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

IDLE_DAYS="${IDLE_DAYS:-90}"
SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"; SSH_PORT="${SSH_PORT:-22}"
YES=0; [ "${1:-}" = "-y" ] && YES=1
ask() { [ "$YES" -eq 1 ] && return 0; read -rp "  -> $1 [y/N] " a; [ "$a" = "y" ] || [ "$a" = "Y" ]; }

USERS="$(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd)"
# Required rather than defaulted: the admin account name is site-specific, and
# hard-coding it here would publish it along with the script.
ADMIN="${ADMIN_USER:?set ADMIN_USER=<admin account name>, e.g. ADMIN_USER=adminuser sudo -E ./quickfix...}"

echo "== quickfix on $(hostname -s), ssh port ${SSH_PORT}, idle threshold ${IDLE_DAYS}d =="

# --- 1 + 2. accounts -------------------------------------------------------
echo
echo "[1] Idle / never-used collaborator accounts"
for u in $USERS; do
  [ "$u" = "$ADMIN" ] && continue
  line="$(lastlog -u "$u" | tail -n +2)"
  idle=0
  echo "$line" | grep -q 'Never logged in' && idle=1
  lastlog -b "$IDLE_DAYS" -u "$u" | tail -n +2 | grep -q . && idle=1
  if [ "$idle" -eq 1 ]; then
    echo "  $line"
    if ask "lock '$u'?"; then
      usermod -L "$u"
      usermod -s /usr/sbin/nologin "$u"
      chage -E 0 "$u"
      [ -f "/home/$u/.ssh/authorized_keys" ] && \
        mv "/home/$u/.ssh/authorized_keys" "/home/$u/.ssh/authorized_keys.disabled"
      echo "     locked $u  (undo: usermod -U $u; chage -E -1 $u; usermod -s /bin/bash $u)"
    fi
  else
    if ask "set 180-day password expiry on active account '$u'?"; then
      chage -M 180 -W 14 "$u"; echo "     expiry set on $u"
    fi
  fi
done

# --- 3. fail2ban -----------------------------------------------------------
echo
echo "[2] Brute-force protection"
if systemctl is-active --quiet fail2ban; then
  echo "  fail2ban already running"
elif ask "install and enable fail2ban on port ${SSH_PORT}?"; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban >/dev/null 2>&1
  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1
  fail2ban-client status sshd 2>/dev/null || echo "     check: systemctl status fail2ban"
fi

# --- 4. history evidence ---------------------------------------------------
echo
echo "[3] Shell history timestamps and log retention"
if [ -f /etc/profile.d/99-history.sh ]; then
  echo "  already configured"
elif ask "enable HISTTIMEFORMAT + 10k history for all users?"; then
  cat > /etc/profile.d/99-history.sh <<'EOF'
export HISTTIMEFORMAT="%F %T "
export HISTSIZE=10000
export HISTFILESIZE=20000
shopt -s histappend
export PROMPT_COMMAND="history -a"
EOF
  chmod 644 /etc/profile.d/99-history.sh
  echo "     done (applies to new logins)"
fi
if ask "keep 12 months of btmp/wtmp instead of 4 weeks?"; then
  sed -i 's/^\([[:space:]]*\)rotate .*/\1rotate 12/' /etc/logrotate.d/btmp /etc/logrotate.d/wtmp 2>/dev/null
  echo "     done"
fi

# --- 5. admin password -----------------------------------------------------
echo
echo "[4] Administrator password"
echo "  If the '${ADMIN}' password is weak or shared between hosts, change it now."
echo "  Suggested value: $(openssl rand -base64 24 2>/dev/null || head -c18 /dev/urandom | base64)"
if ask "run 'passwd ${ADMIN}' interactively?"; then passwd "$ADMIN"; fi

echo
echo "== done. Re-run srv_sec_audit_20260827_1730.sh to confirm items 4/5/6. =="
echo "   Still outstanding (do these with a second SSH session open):"
echo "   - SSH key-only auth  (PasswordAuthentication no)"
echo "   - firewall the exposed service on this host"
