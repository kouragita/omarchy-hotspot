# Security

Treat every device that joins the hotspot as **untrusted**. The whole point of
this feature is to let someone else use your internet, which means assuming
they may probe whatever you expose.

The design goal is simple:

> **A hotspot hands out internet, not a login prompt.**

## What a client on the hotspot can reach

| Port | Proto | Purpose | Default |
| ---- | ----- | ------- | ------- |
| 53 | UDP/TCP | DNS, served by dnsmasq on `10.42.0.1` | **open** (required) |
| 67 | UDP | DHCP, served by dnsmasq | **open** (required) |
| 22 | TCP | SSH, for optional phone tunnels | **CLOSED** |

Everything else on the host is blocked by the firewall's default `deny`
incoming policy. There is no file share, no web admin panel, no API.

SSH is opt-in. To enable it deliberately:

```bash
touch ~/.config/omarchy-hotspot/allow-ssh
systemctl restart omarchy-hotspot.service
```

Only do that if you want a tunnel to a loopback-only service (see
`runtime/phone-tunnel`). It is the one inbound port with an authentication
boundary, and it is still just SSH — key or password, your `sshd_config`.

## Why clients cannot get administrative access

- **No privileged surface is exposed.** The hotspot forwards packets. It does
  not run a control service, an RPC port, or a second management interface on
  `ap0`. The only privileged actors are `hostapd` and `dnsmasq`, both bound to
  the AP interface and neither offering a remote control channel.
- **The polkit rule is session-scoped.** It permits managing *one* systemd unit
  and requires `subject.local && subject.active` — an active **local** session.
  A device on the hotspot has no local session, so it cannot use that rule even
  if it could somehow speak to the system bus (it cannot; that is a local
  socket).
- **The polkit rule names one unit.** It does not grant
  `org.freedesktop.systemd1.manage-units` generally, and it cannot be used to
  start arbitrary services, edit units, or read files.
- **No `NOPASSWD` sudoers entries.** The project ships none. The only
  escalation path is a narrow polkit rule, and only for the local desktop user.
- **The config is mode `600`.** It holds the Wi-Fi key; no other local user can
  read it, and `install.sh` re-applies the mode on every run.
- **Loopback-only services stay loopback.** Anything bound to `127.0.0.1`
  (a local dev server, a bridge process, an admin socket) is **not** reachable
  from the hotspot. Use an SSH tunnel if you need one; do not rebind a service
  that was deliberately bound to loopback.

## Client-to-client isolation

`hostapd.conf` sets:

```text
ap_isolate=1
```

Stations cannot send frames to each other; they can only reach the gateway.
This stops one guest from probing another guest's device (open ports, ARP
spoofing, mDNS snooping) and is the single most important hardening step on a
shared hotspot.

If you need two of your own devices to talk to each other, set
`ap_isolate=0` and accept that every guest can then reach every other guest.

## What an attacker on the hotspot *can* still do

Be honest about the limits:

- **Consume your bandwidth.** There is no per-client quota or rate limit. The
  panel shows per-device traffic so you can see it happening; it does not stop
  it.
- **Send traffic that looks like it came from your machine's public IP.** That
  is what NAT means. Your ISP sees the uplink address, not the client.
- **Reach the internet freely.** This is not a captive portal — there is no
  authentication, no splash page, no per-client accounting.
- **Try to guess the password.** WPA2-PSK offline attack applies if someone
  captures the handshake. Use a long random key; the installer generates a
  16-character one.

If you need guest accounting or a captive portal, put something in front of it.
This tool deliberately does not.

## Reporting

Open an issue for anything that looks like a real exposure — especially
anything that would let a hotspot client reach the host beyond DNS/DHCP, or
reach another client despite `ap_isolate=1`.
