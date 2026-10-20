# OrbStack reverse SSH setup

Creates or reuses an Ubuntu OrbStack VM and manages a reverse SSH tunnel with a boot-enabled systemd service. Repeated runs preserve a healthy managed tunnel. The service retries dropped connections automatically.

## Requirements

- Run on the Mac hosting the OrbStack VM, with OrbStack already running.
- Enable SSH on the receiving computer and allow remote port forwarding for the target user.
- Keep `authorized_keys`, `id_ed25519`, and `id_ed25519.pub` in the source Mac's SSH directory. The target user on the receiving computer must trust this public key, and the VM's authorized keys must permit the receiving computer to connect back.
- Authentication must work without password prompts. Keep key contents and machine-specific configuration outside this repository.

The script links these SSH files into a new VM without replacing existing files. Setup runs as root inside the VM; the tunnel service runs as the configured VM user.

## Usage

On the Mac hosting the VM:

```sh
TUNNEL_TARGET='user@receiving-host' ./orb-ubuntu.sh
```

Successful setup prints:

```text
Reverse SSH is UP (port 2222; automatic recovery enabled).
```

A terminal shows a short progress line during setup. Detailed output goes to the log file. Failures return a nonzero exit code with the setup phase and log path.

On the receiving computer, connect through the tunnel:

```sh
ssh -p 2222 dev@localhost
```

The first run may replace an old tunnel matching the same VM user, receiving target, and reverse port. A healthy managed tunnel is reused on later runs.

## Configuration

Pass settings as environment variables; no personal destination is embedded in the script.

| Variable | Default |
| --- | --- |
| `TUNNEL_TARGET` | Required: receiving SSH user and hostname or IP |
| `NAME` | `ubuntu` |
| `DISTRO` | `ubuntu` |
| `VM_USER` | `dev` |
| `TUNNEL_PORT` | `2222` |
| `MAC_SSH_DIR` | `$HOME/.ssh` |
| `CREATE_TIMEOUT` | `180` seconds |
| `SETUP_TIMEOUT` | `300` seconds |
| `LOG_FILE` | `$HOME/Library/Logs/orb-ubuntu.log` |

The receiving SSH server uses port 22. The reverse listener uses localhost on the receiving computer and forwards to port 22 inside the VM. Change the SSH login command above if you override `VM_USER` or `TUNNEL_PORT`.

VM creation and VM setup have separate deadlines. Initial package downloads may take longer on a slow network; adjust the timeout settings when necessary. The service itself keeps retrying after a tunnel readiness check fails.

To inspect service logs from the source Mac, using your configured VM name:

```sh
orb -m ubuntu -u root journalctl -u reverse-ssh.service -n 30 --no-pager
```
