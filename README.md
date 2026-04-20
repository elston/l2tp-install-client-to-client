# l2tp-setup

Automated L2TP/IPsec VPN client setup for Ubuntu 24.04 and AlmaLinux 9 — configured to **never hijack the default route**, so your SSH session stays alive.

## Why this exists

Setting up L2TP/IPsec on a headless Linux server is painful: mixed docs, distro differences (Ubuntu uses `ipsec.conf`, AlmaLinux 9 EPEL ships only `swanctl`), kernel module quirks, and the ever-present risk of losing your SSH session the moment the VPN comes up. This script handles all of it in one go.

## Features

- 🔒 **IPsec (strongSwan) + L2TP (xl2tpd) + PPP** — complete client stack
- 🛡️ **No `defaultroute`** — VPN never steals your default gateway, SSH connection survives
- 🛣️ **Per-subnet routing** — only traffic to specified networks (e.g. `192.168.11.0/24`) goes through the tunnel
- 🐧 **Cross-distro** — detects OS and uses the right config format:
  - Ubuntu 24.04 → legacy `ipsec.conf` + `ipsec` command
  - AlmaLinux 9 → modern `swanctl` config
- 🔁 **Auto-routing on reconnect** — routes re-apply via `/etc/ppp/ip-up.d/` hooks
- 🗑️ **Clean uninstall** — removes all configs, services, and optionally packages
- ⚠️ **Cyrillic-in-username detection** — catches the classic "typed login with Russian keyboard" mistake
- 🧩 **Container-aware** — warns if running in LXC/OpenVZ where kernel modules can't be loaded

## Requirements

- **Ubuntu 24.04** or **AlmaLinux 9** (Rocky Linux and RHEL 9 should also work)
- Root access
- Real virtualization (KVM, VMware, bare metal) — not LXC/OpenVZ
- On AlmaLinux 9: a reboot may be needed after `kernel-modules-extra` install if the running kernel is older than the installed one

## Usage

### Install

```bash
chmod +x l2tp-setup.sh
sudo ./l2tp-setup.sh
```

You'll be asked for:
- VPN server (IP or hostname)
- Username
- Password
- Pre-shared key (PSK)
- Routes to push through VPN (comma-separated, e.g. `192.168.11.0/24,10.10.0.0/16`)
- Connection name

### Uninstall

```bash
sudo ./l2tp-setup.sh uninstall
```

Removes all configs, PPP peers, routing hooks, systemd service links, and the `vpn-*` commands. Package removal is optional (asked interactively).

### Non-interactive modes

```bash
sudo ./l2tp-setup.sh install      # go straight to install
sudo ./l2tp-setup.sh uninstall    # go straight to uninstall
```

## Management commands

After installation, three commands are available globally:

| Command | What it does |
|---|---|
| `sudo vpn-up` | Establish IPsec SA, start L2TP tunnel, bring up `ppp0`, add routes |
| `sudo vpn-down` | Tear down L2TP and IPsec |
| `sudo vpn-status` | Show IPsec SA state, `ppp0` interface, active routes, external IP |

## What gets configured

### Ubuntu 24.04
- `/etc/ipsec.conf` — IPsec connection (IKEv1, transport mode, PSK)
- `/etc/ipsec.secrets` — PSK storage (mode 600)
- Service: `strongswan-starter.service`

### AlmaLinux 9
- `/etc/strongswan/swanctl/conf.d/<name>.conf` — swanctl connection + secrets
- `/etc/modules-load.d/l2tp.conf` — auto-load `l2tp_ppp` kernel module
- Package: `kernel-modules-extra` (contains `l2tp_ppp`)
- Service: `strongswan.service`

### Both distros
- `/etc/xl2tpd/xl2tpd.conf` — L2TP client config
- `/etc/ppp/peers/<name>` — PPP settings (MSCHAPv2, **no** `defaultroute`, **no** `usepeerdns`)
- `/etc/ppp/ip-up.d/<name>-routes` — adds routes when tunnel comes up
- `/etc/ppp/ip-down.d/<name>-routes` — removes routes when tunnel goes down
- `/etc/l2tp-setup/installed.conf` — install metadata (used by uninstall)

## How the "no SSH loss" guarantee works

Standard L2TP setups include `defaultroute` in the PPP config, which replaces the system's default gateway with the VPN peer — cutting off the SSH session you're connected on.

This script explicitly **omits `defaultroute` and `usepeerdns`**. Only routes you specify (e.g. `192.168.11.0/24`) are added via `ip route add ... dev ppp0`. Everything else — including your SSH traffic — keeps using the original gateway.

## Troubleshooting

**`MS-CHAP authentication failed: bad username or password`**
Check the credentials you got from the VPN admin. Watch for Cyrillic lookalikes (`с`/`s`, `е`/`e`, `о`/`o`) — the script warns about these in the username but doesn't inspect the password. You can check the PPP peer file for non-ASCII bytes:
```bash
sudo grep -P '[^\x00-\x7F]' /etc/ppp/peers/<name>
```

**`modprobe: FATAL: Module l2tp_ppp not found` on AlmaLinux**
`kernel-modules-extra` was installed but matches a newer kernel than the one running. Reboot:
```bash
sudo reboot
# then:
sudo modprobe l2tp_ppp
```

**`ipsec: command not found` on AlmaLinux**
Expected — EPEL 9's strongSwan ships `swanctl` only, not the legacy `ipsec` wrapper. The script handles this automatically; if you see this error, you may have an older version of the script.

**`plugin 'sqlite': failed to load`**
Harmless warning. Ignore, or install `strongswan-sqlite` to silence it.

**`ppp0 flickers up and down`**
Auth succeeded with PPP briefly but something dropped the connection. Check:
```bash
sudo journalctl -u xl2tpd --since "5 minutes ago"
```

**IPsec works but L2TP times out**
Check with `sudo swanctl --list-sas` (AlmaLinux) or `sudo ipsec status` (Ubuntu). If IPsec is `ESTABLISHED`/`INSTALLED` with byte counters moving, the tunnel is encrypting fine — problem is on the PPP layer (usually credentials).

## License

MIT

## Contributing

PRs welcome, especially for:
- Additional distro support (Debian, Fedora, openSUSE)
- IKEv2 support alongside IKEv1
- Multiple simultaneous VPN profiles