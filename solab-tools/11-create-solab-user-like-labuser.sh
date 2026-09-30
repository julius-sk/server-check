#!/usr/bin/env bash
# Author: Lei Zhao <lei1.zhao@sk.com>
# Purpose: Create a Solab user with labuser's groups except the labuser group.
set -Eeuo pipefail
export LC_ALL=C

apply=1
username=""
full_name=""
set_password=1

usage() {
  cat <<'USAGE'
Create one regular Solab user with labuser's supplementary groups, excluding
the group named labuser. The new account receives its own primary group.

This script must be launched directly by labuser, not by root:
  bash 11-create-solab-user-like-labuser.sh --username NAME [--full-name NAME]
  bash 11-create-solab-user-like-labuser.sh --username NAME --plan

Options:
  --username NAME   Required account name.
  --full-name NAME  Optional GECOS/display name.
  --plan            Preview the account and copied groups without creating it.
  --apply           Create the account explicitly; this is the default.
  --no-password     Do not run the interactive passwd step after creation.
  -h, --help        Show this help.

Review the printed group list carefully: copying labuser's groups may also
grant sudo, device, storage, or other privileged access.
USAGE
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --username) username="${2:?missing value for --username}"; shift 2 ;;
    --full-name) full_name="${2:?missing value for --full-name}"; shift 2 ;;
    --apply) apply=1; shift ;;
    --plan) apply=0; shift ;;
    --no-password) set_password=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ "$(id -un)" == "labuser" && "$EUID" -ne 0 ]] || \
  die "run this script directly as labuser; do not sudo the whole script"
[[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || \
  die "invalid username: ${username:-<empty>}"
[[ "$username" != "labuser" && "$username" != "root" ]] || \
  die "refusing reserved username: $username"
getent passwd labuser >/dev/null || die "reference account labuser is missing"

mapfile -t reference_groups < <(id -nG labuser | tr ' ' '\n' | awk 'NF && $0 != "labuser"' | sort -u)
[[ "${#reference_groups[@]}" -gt 0 ]] || die "labuser has no supplementary groups to copy"
groups_csv="$(IFS=,; echo "${reference_groups[*]}")"

echo "MODE=$([[ "$apply" -eq 1 ]] && echo APPLY || echo PLAN)"
echo "REQUESTED_BY=$(id -un)"
echo "USERNAME=$username"
echo "FULL_NAME=${full_name:-<empty>}"
echo "PRIMARY_GROUP=$username"
echo "SUPPLEMENTARY_GROUPS=$groups_csv"
echo "EXCLUDED_GROUP=labuser"
echo "SET_PASSWORD=$set_password"

if getent passwd "$username" >/dev/null; then
  die "account already exists: $username"
fi
if getent group "$username" >/dev/null; then
  die "a group already exists with the requested username: $username"
fi

if [[ "$apply" -ne 1 ]]; then
  echo "PLAN_ONLY=1"
  echo "NEXT_COMMAND=bash $0 --username $username${full_name:+ --full-name '$full_name'}"
  exit 0
fi

command -v sudo >/dev/null 2>&1 || die "sudo is required"
sudo -v
useradd_args=(--create-home --user-group --shell /bin/bash)
[[ -z "$full_name" ]] || useradd_args+=(--comment "$full_name")
useradd_args+=(--groups "$groups_csv" "$username")
sudo useradd "${useradd_args[@]}"

if [[ "$set_password" -eq 1 ]]; then
  echo "Set the initial password for $username:"
  sudo passwd "$username"
fi

actual_primary="$(id -gn "$username")"
actual_groups="$(id -nG "$username")"
[[ "$actual_primary" == "$username" ]] || die "unexpected primary group: $actual_primary"
if tr ' ' '\n' <<<"$actual_groups" | grep -Fxq labuser; then
  die "new account unexpectedly belongs to the labuser group"
fi

echo "CREATED_USER=$username"
echo "ACTUAL_PRIMARY_GROUP=$actual_primary"
echo "ACTUAL_GROUPS=$actual_groups"

echo "ACCESS_REVIEW_BEGIN=1"
for access_group in shared docker; do
  if tr ' ' '\n' <<<"$actual_groups" | grep -Fxq "$access_group"; then
    echo "ACCESS_GROUP_PRESENT=$access_group"
    continue
  fi

  echo "ACCESS_GROUP_MISSING=$access_group"
  case "$access_group" in
    shared)
      echo "OPTIONAL_COMMAND=bash 04-add-regular-users-to-shared-group.sh"
      echo "OPTIONAL_COMMAND_SCOPE=adds every regular interactive user to shared"
      ;;
    docker)
      echo "OPTIONAL_COMMAND=bash 06-grant-docker-access-to-regular-users.sh --grant-root-equivalent-access"
      echo "OPTIONAL_COMMAND_SCOPE=adds every regular interactive user to docker"
      echo "WARNING=docker membership grants effective root access"
      ;;
  esac
done
echo "ACCESS_REVIEW_NOTE=run only the missing access command that matches the user's role"
echo "LOGIN_NOTE=the new user must start a new login session before group access is active"
echo "PER_USER_SETUP_COMMAND=bash 10-setup-user-opencode-kilocode.sh"
echo "PER_USER_SETUP_NOTE=$username must run the command above once in their own login session"
echo "USER_CREATE_OK=1"
