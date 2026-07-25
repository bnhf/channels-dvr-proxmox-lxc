# channels-dvr-proxmox-lxc
Install Channels DVR in a unprivileged Debian 13 Proxmox LXC with optional Chrome (not Chromium), Samba and Tailscale.

## Usage

Run as root inside the LXC:

```bash
bash -c "$(wget -qO- https://raw.githubusercontent.com/bnhf/channels-dvr-proxmox-lxc/main/install-channels-tve.sh)"
```

Use `bash -c "$(...)"` rather than piping directly into `bash` (`wget -qO- ... | bash`) — piping consumes the script's stdin, which breaks the interactive prompts (timezone, port, Samba password, etc.).

The script is idempotent, so it's safe to re-run after fixing an issue or to reconfigure.
