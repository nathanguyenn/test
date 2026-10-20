#!/usr/bin/env bash
# Run on the Mac hosting the OrbStack VM. Repeated runs reuse the supervised reverse SSH tunnel.
# Override defaults with NAME=ubuntu TUNNEL_TARGET=user@host TUNNEL_PORT=2222.
set -euo pipefail
umask 077

DISTRO="${DISTRO:-ubuntu}"
NAME="${NAME:-ubuntu}"
VM_USER="${VM_USER:-dev}"
TUNNEL_TARGET="${TUNNEL_TARGET:-}"
TUNNEL_PORT="${TUNNEL_PORT:-2222}"
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
if [[ -z "$TUNNEL_TARGET" ]]; then
  echo "Set TUNNEL_TARGET=user@receiving-host before running this script." >&2
  exit 2
fi
if [[ ! "$VM_USER" =~ ^[a-z_][a-z0-9_-]*$ ||
      ! "$TUNNEL_TARGET" =~ ^[A-Za-z0-9_.-]+@[A-Za-z0-9_.-]+$ ||
      ! "$TUNNEL_PORT" =~ ^[0-9]{1,5}$ ]]; then
  echo "Invalid VM_USER, TUNNEL_TARGET, or TUNNEL_PORT." >&2
  exit 2
fi
TUNNEL_PORT=$((10#$TUNNEL_PORT))
if (( TUNNEL_PORT < 1024 || TUNNEL_PORT > 65535 )); then
  echo "TUNNEL_PORT must be between 1024 and 65535." >&2
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
    printf 'Reverse SSH is UP (port %s; automatic recovery enabled).\n' "$TUNNEL_PORT" >&3
  else
    if (( result == 124 )); then phase="$phase timed out"; fi
    printf 'Reverse SSH could not be verified (%s). Log: %s\n' "$phase" "$LOG_FILE" >&4
  fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '\n--- %s ---\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# The Mac has no built-in GNU timeout. Bound Orb commands with a watchdog,
# explicitly preserving stdin so the VM setup heredoc still reaches Bash.
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
  if [[ -t 3 ]]; then printf '\r\033[2KReverse SSH: %s...' "$phase" >&3; fi
}

command -v orbctl
command -v orb
orb_status=$(run_bounded 10 orbctl status)
if [[ "$orb_status" != Running ]]; then
  echo "OrbStack is not running. Start it on the Mac hosting the VM first."
  exit 1
fi

# Refuse to provision a VM on the receiving Mac by accident.
target_host="${TUNNEL_TARGET#*@}"
if ifconfig | awk '$1 == "inet" {print $2}' | grep -Fx "$target_host" >/dev/null; then
  echo "This is the receiving Mac ($target_host). Run the script on the Mac hosting the VM."
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

stage "installing SSH and starting tunnel"
run_bounded "$((SETUP_TIMEOUT + 10))" orb -m "$NAME" -u root timeout --kill-after=5 "$SETUP_TIMEOUT" bash -s -- "$VM_USER" "$MAC_SSH_DIR" "$TUNNEL_TARGET" "$TUNNEL_PORT" <<'VM_SCRIPT'
set -euo pipefail
umask 077
vm_user=$1
mac_ssh_dir=$2
target=$3
port=$4
service=reverse-ssh.service
socket=/run/reverse-ssh/control
forward="localhost:$port:localhost:22"

# Serialize setup, including simultaneous invocations from two Mac terminals.
exec 9>/run/lock/reverse-ssh.lock
flock -w 60 9
vm_home=$(getent passwd "$vm_user" | cut -d: -f6)
vm_group=$(id -gn "$vm_user")
vm_uid=$(id -u "$vm_user")
if [[ -z "$vm_home" || "$vm_home" != /home/* || "$vm_home" =~ [[:space:]%] ]]; then
  echo "Unsupported home directory for $vm_user: $vm_home"
  exit 1
fi

if [[ ! -x /usr/bin/ssh || ! -x /usr/sbin/sshd ]]; then
  apt-get -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 install -y --no-install-recommends openssh-client openssh-server
fi
systemctl enable --now ssh.service

# Reuse the source Mac's keys when setting up a new VM; preserve existing files.
install -d -o "$vm_user" -g "$vm_group" -m 700 "$vm_home/.ssh"
for key in authorized_keys id_ed25519 id_ed25519.pub; do
  shared="/mnt/mac$mac_ssh_dir/$key"
  dest="$vm_home/.ssh/$key"
  if [[ -f "$shared" && ! -e "$dest" && ! -L "$dest" ]]; then
    ln -s "$shared" "$dest"
    chown -h "$vm_user:$vm_group" "$dest"
  fi
done
if [[ ! -r "$vm_home/.ssh/authorized_keys" || ! -r "$vm_home/.ssh/id_ed25519" ]]; then
  echo "Missing source Mac authorized_keys or id_ed25519; check $vm_home/.ssh symlinks."
  exit 1
fi

unit=$(mktemp)
trap 'rm -f "$unit"' EXIT
cat >"$unit" <<UNIT
[Unit]
Description=Reverse SSH tunnel
# Retry SSH until networking is usable; do not wait for DNS readiness at boot.
After=network.target ssh.service
StartLimitIntervalSec=0

[Service]
# -f plus ExitOnForwardFailure waits for the remote port to be bound.
# SSH leaves exactly one child, which systemd tracks as the main process.
Type=forking
GuessMainPID=yes
User=$vm_user
RuntimeDirectory=reverse-ssh
RuntimeDirectoryMode=0700
ExecStart=/usr/bin/ssh -fNT -M -S $socket -R $forward -i $vm_home/.ssh/id_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o ServerAliveInterval=30 -o ServerAliveCountMax=3 $target
Restart=always
RestartSec=5
TimeoutStartSec=25
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
UNIT

changed=false
if ! cmp -s "$unit" "/etc/systemd/system/$service"; then
  install -m 644 "$unit" "/etc/systemd/system/$service"
  systemctl daemon-reload
  changed=true
fi
systemctl enable "$service"

# One-time migration: replace only the old, single reverse-forward command for
# this user and receiving Mac. Preserve other SSH connections and login sessions.
if ! systemctl is-active --quiet "$service"; then
  while read -r pid; do
    [[ -r "/proc/$pid/cmdline" ]] || continue
    args=()
    while IFS= read -r -d '' arg; do args+=("$arg"); done <"/proc/$pid/cmdline"
    has_target=false
    has_no_command=false
    matching_forward=false
    reverse_count=0
    other_forward=false
    for ((i=1; i<${#args[@]}; i++)); do
      case "${args[$i]}" in
        "$target") has_target=true ;;
        -N|-NT|-TN) has_no_command=true ;;
        -L*|-D*|-W*) other_forward=true ;;
        -R)
          reverse_count=$((reverse_count + 1))
          next="${args[$((i+1))]:-}"
          if [[ "$next" == "$port:localhost:22" || "$next" == "$forward" ]]; then
            matching_forward=true
          fi
          ;;
        -R*) reverse_count=$((reverse_count + 1)) ;;
      esac
    done
    if $has_target && $has_no_command && $matching_forward && ! $other_forward && (( reverse_count == 1 )); then
      echo "Replacing legacy tunnel PID $pid with $service."
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done < <(pgrep -u "$vm_uid" -x ssh || true)
fi

if $changed || ! timeout 3 runuser -u "$vm_user" -- ssh -S "$socket" -O check "$target"; then
  systemctl restart --no-block "$service"
else
  systemctl start --no-block "$service"
fi

for ((attempt=0; attempt<45; attempt++)); do
  # A pending restart may still expose the old control socket. Wait for its job.
  job=$(systemctl show "$service" -p Job --value)
  if [[ -z "$job" || "$job" == 0 ]] &&
     systemctl is-active --quiet "$service" &&
     timeout 3 runuser -u "$vm_user" -- ssh -S "$socket" -O check "$target"; then
    exit 0
  fi
  sleep 1
done
echo "Tunnel is not ready. The enabled service will keep retrying."
journalctl -u "$service" -n 30 --no-pager
exit 1
VM_SCRIPT
