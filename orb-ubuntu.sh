#!/usr/bin/env bash
set -euo pipefail
umask 077

DISTRO="${DISTRO:-ubuntu}"
NAME="${NAME:-ubuntu}"
VM_USER="${VM_USER:-dev}"
LOG_FILE="${LOG_FILE:-$HOME/Library/Logs/orb-ubuntu.log}"
MAC_SSH_DIR="${MAC_SSH_DIR:-$HOME/.ssh}"
CREATE_TIMEOUT="${CREATE_TIMEOUT:-180}"
SETUP_TIMEOUT="${SETUP_TIMEOUT:-300}"

if [[ $# != 0 ]]; then
  echo "Usage: ./orb-ubuntu.sh (run on the Mac hosting the VM)" >&2
  exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Run this script on the Mac hosting the VM, outside the VM." >&2
  exit 1
fi
if [[ ! "$VM_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "Invalid VM_USER." >&2
  exit 2
fi
for limit in "$CREATE_TIMEOUT" "$SETUP_TIMEOUT"; do
  if [[ ! "$limit" =~ ^[1-9][0-9]{0,3}$ ]]; then
    echo "CREATE_TIMEOUT and SETUP_TIMEOUT must be positive seconds (up to 9999)." >&2
    exit 2
  fi
done
if [[ "$MAC_SSH_DIR" != /* ]]; then
  echo "MAC_SSH_DIR must be an absolute path." >&2
  exit 2
fi

mkdir -p "$(dirname "$LOG_FILE")"
exec 3>&1 4>&2
exec >>"$LOG_FILE" 2>&1
phase="checking OrbStack"
active_command=""
active_timer=""
active_temp=""
stop_timer() {
  if [[ -n "$active_timer" ]]; then
    kill -TERM "$active_timer" 2>/dev/null || true
    wait "$active_timer" 2>/dev/null || true
    active_timer=""
  fi
}
finish() {
  local result=$?
  stop_timer
  if [[ -n "$active_command" ]]; then
    kill -TERM "$active_command" 2>/dev/null || true
    wait "$active_command" 2>/dev/null || true
  fi
  [[ -z "$active_temp" ]] || rm -rf "$active_temp"
  if [[ -t 3 ]]; then printf '\r\033[2K' >&3; fi
  if (( result == 0 )); then
    printf 'OPERATION RUNNING\n' >&3
  elif (( result == 10 )); then
    printf 'need initial log in\n' >&4
  else
    if (( result == 124 )); then phase="$phase timed out"; fi
    printf 'OPERATION NOT READY (%s). Log: %s\n' "$phase" "$LOG_FILE" >&4
  fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '\n--- %s ---\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

run_bounded() {
  local seconds=$1
  shift
  active_temp=$(mktemp -d) || return 1
  "$@" <&0 &
  active_command=$!
  (
    trap - EXIT
    sleeper=""
    trap 'kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; exit 0' TERM INT
    sleep "$seconds" & sleeper=$!
    wait "$sleeper" || exit 0
    : >"$active_temp/timed-out"
    echo "Timed out after $seconds seconds during $phase."
    kill -TERM "$active_command" 2>/dev/null || true
    sleep 2 & sleeper=$!
    wait "$sleeper" || exit 0
    kill -KILL "$active_command" 2>/dev/null || true
  ) &
  active_timer=$!
  local result=0
  wait "$active_command" || result=$?
  active_command=""
  stop_timer
  if [[ -f "$active_temp/timed-out" ]]; then result=124; fi
  rm -rf "$active_temp"
  active_temp=""
  return "$result"
}
stage() {
  phase=$1
  printf '%s: %s\n' "$(date -u '+%H:%M:%S')" "$phase"
  if [[ -t 3 ]]; then printf '\r\033[2KOperation: %s...' "$phase" >&3; fi
}

command -v orbctl
command -v orb
orb_status=$(run_bounded 10 orbctl status)
if [[ "$orb_status" != Running ]]; then
  echo "OrbStack is not running. Start it on the Mac hosting the VM first."
  exit 1
fi

if run_bounded 10 orbctl info "$NAME" >/dev/null 2>&1; then
  :
else
  info_result=$?
  if (( info_result == 124 )); then exit 124; fi
  stage "creating VM $NAME"
  run_bounded "$CREATE_TIMEOUT" orb create --user "$VM_USER" "$DISTRO" "$NAME"
fi

stage "configuring VM"
run_bounded "$((SETUP_TIMEOUT + 10))" orb -m "$NAME" -u root timeout --kill-after=5 "$SETUP_TIMEOUT" bash -s -- "$VM_USER" "$MAC_SSH_DIR" <<'VM_SCRIPT'
set -euo pipefail
umask 077
vm_user=$1
mac_ssh_dir=$2

exec 9>/run/lock/reverse-ssh.lock
flock -w 60 9
vm_home=$(getent passwd "$vm_user" | cut -d: -f6)
vm_group=$(id -gn "$vm_user")
if [[ -z "$vm_home" || "$vm_home" != /home/* || "$vm_home" =~ [[:space:]%] ]]; then
  echo "Unsupported home directory for $vm_user: $vm_home"
  exit 1
fi

if [[ ! -x /usr/sbin/sshd ]]; then
  apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 install -y --no-install-recommends openssh-server
fi
systemctl enable --now ssh.service

install -d -o "$vm_user" -g "$vm_group" -m 700 "$vm_home/.ssh"
for key in authorized_keys id_ed25519 id_ed25519.pub; do
  shared="/mnt/mac$mac_ssh_dir/$key"
  dest="$vm_home/.ssh/$key"
  if [[ -f "$shared" && ! -e "$dest" && ! -L "$dest" ]]; then
    ln -s "$shared" "$dest"
    chown -h "$vm_user:$vm_group" "$dest"
  fi
done
if [[ ! -r "$vm_home/.ssh/authorized_keys" || ! -s "$vm_home/.ssh/authorized_keys" ||
      ! -r "$vm_home/.ssh/id_ed25519" || ! -s "$vm_home/.ssh/id_ed25519" ]]; then
  echo "Initial SSH key setup is incomplete."
  exit 10
fi
VM_SCRIPT
