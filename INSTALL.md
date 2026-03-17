# VPN Server Installation Guide

## Requirements

| Parameter | Value |
|-----------|-------|
| OS | Ubuntu 22.04+ LTS |
| RAM | 1 GB minimum |
| CPU | 1 core minimum |
| Network | 100 Mbps+ |
| Access | Root SSH |

## Quick Start (1 command)

```bash
bash <(curl -sL https://raw.githubusercontent.com/YOUR_REPO/install-vpn.sh)
```

## Step-by-Step Installation

### 1. Connect to server

```bash
ssh root@YOUR_SERVER_IP
```

### 2. Upload and run the script

**Option A** — from local machine (PowerShell/Terminal):
```bash
scp install-vpn.sh root@SERVER_IP:/root/
ssh root@SERVER_IP -t "bash /root/install-vpn.sh"
```

**Option B** — directly on server:
```bash
curl -O https://raw.githubusercontent.com/YOUR_REPO/install-vpn.sh
bash install-vpn.sh
```

### 3. Interactive prompts during 3X-UI install

The script will pause for 3X-UI installer input:

| Prompt | Enter |
|--------|-------|
| Customize panel port? | `y` |
| Panel port | `2053` |
| SSL certificate method | `2` (Let's Encrypt for IP) |
| IPv6 address | Press Enter (skip) or enter your IPv6 |
| ACME port | Press Enter (default 80) |

> **Important:** Port 80 must be reachable from the internet for SSL certificate issuance. The script opens it in UFW before 3X-UI runs.

### 4. Save your credentials

After installation, the script shows auto-generated credentials. Save them!
To view again:

```bash
/usr/local/x-ui/x-ui setting -show
```

To reset credentials:

```bash
/usr/local/x-ui/x-ui setting -username NEW_USER -password NEW_PASS
systemctl restart x-ui
```

## Configure VLESS + Reality Inbound

### Open the panel

```
https://SERVER_IP:2053/YOUR_BASE_PATH/
```

### Create inbound: Panel → Inbounds → Add Inbound

| Field | Value |
|-------|-------|
| Remark | `vless-reality` |
| Protocol | `vless` |
| Port | `443` |
| Transmission | `TCP (RAW)` |
| Security | `Reality` |
| uTLS | `chrome` |
| Target | `www.samsung.com:443` |
| SNI | `www.samsung.com` |
| SpiderX | `/` |

Click **Get New Keys** to generate Reality keypair.
Click **Get New Cert** if available.

### Client section:

| Field | Value |
|-------|-------|
| Email | any name (e.g., `user1`) |
| Flow | `xtls-rprx-vision` **(required!)** |

### Sniffing section:

| Field | Value |
|-------|-------|
| Enabled | ON |
| HTTP | ON |
| TLS | ON |
| QUIC | ON |
| FAKEDNS | ON |
| Metadata Only | OFF |
| Route Only | OFF |

Click **Create**.

## Get Client Connection Link

1. In Inbounds list, click **≡** next to your inbound
2. Click the **QR code** or **info** icon next to the client
3. Copy the `vless://...` link or scan QR

## Client Apps

| Platform | App |
|----------|-----|
| iOS / macOS | Streisand, V2Box |
| Android | V2rayNG, NekoBox |
| Windows | Hiddify, V2rayN |

Paste the `vless://` link into the app.

### Client DNS Settings

| DNS | When to use |
|-----|-------------|
| `77.88.8.8` (Yandex) | During Russian operator restrictions (white lists) |
| `8.8.8.8` (Google) | Standard use, faster globally |

### Client Address

Always use **server IP**, not a domain:
```
82.39.86.192
```

## Alternative Reality Targets

If `www.samsung.com` gets blocked, switch to:

| Target | Notes |
|--------|-------|
| `www.mozilla.org` | Firefox org, TLS 1.3, H2 |
| `www.asus.com` | Low profile, TLS 1.3 |
| `dl.google.com` | Download CDN, high trust |
| `www.logitech.com` | Low profile hardware vendor |

Requirements for Reality target: TLS 1.3, H2, not on same server, not a CDN that checks headers aggressively.

### For Russian operators (white list mode)

Best targets when only white-listed domains work:

| Target | Why |
|--------|-----|
| `tunnel.vk.com` | VK infra, always white-listed |
| `ps.userapi.com` | VK CDN |
| `yandex.ru` | Core Yandex, never blocked |
| `www.sberbank.ru` | Banking, always accessible |

## Post-Install Security Hardening

### 1. Change root password

```bash
passwd
```

### 2. Disable SSH password authentication

> Only after SSH key is configured!

```bash
sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart sshd
```

### 3. Restrict panel access to your IP

```bash
ufw delete allow 2053/tcp
ufw allow from YOUR_HOME_IP to any port 2053 proto tcp
```

### 4. Monitor

```bash
# Server status
x-ui status

# fail2ban bans
fail2ban-client status sshd

# Active connections
ss -tlnp

# System resources
htop
free -h

# Firewall rules
ufw status numbered
```

## What the Script Optimizes

| Optimization | Value | Why |
|-------------|-------|-----|
| BBR | `fq` + `bbr` | Best congestion control for long-distance |
| TCP buffers | 4MB max | Optimal for 1GB RAM (8MB wastes memory) |
| tcp_notsent_lowat | 131072 | Reduces latency for proxied connections |
| TCP FastOpen | 3 (client+server) | Faster connection setup |
| MTU Probing | enabled | Avoids packet fragmentation |
| Ephemeral ports | 1024-65535 | More outbound connections for proxy |
| Swap | 512MB | OOM protection on 1GB servers |
| fail2ban | SSH, 5 retries, 1h ban | Brute-force protection |
| Chrony/NTP | auto | Critical for TLS/Reality time accuracy |
| UFW | deny all + allow list | Minimal attack surface |
| File limits | 51200 | Enough for thousands of connections |
| Unattended upgrades | security only | Auto-patches vulnerabilities |
| Kernel hardening | rp_filter, no redirects | Standard server hardening |

## Configurable Variables

Set before running the script to override defaults:

```bash
PANEL_PORT=9999 REALITY_TARGET=www.mozilla.org bash install-vpn.sh
```

| Variable | Default | Description |
|----------|---------|-------------|
| `PANEL_PORT` | 2053 | 3X-UI web panel port |
| `SUB_PORT` | 2096 | Subscription server port |
| `VLESS_PORT` | 443 | VLESS Reality listen port |
| `SWAP_MB` | 512 | Swap file size in MB |
| `REALITY_TARGET` | www.samsung.com | Reality masquerade domain |

## Troubleshooting

### SSL certificate fails

```bash
# Check port 80 is open
ufw status | grep 80
# Test from outside
curl -v http://SERVER_IP/.well-known/acme-challenge/test

# Re-issue manually
~/.acme.sh/acme.sh --issue -d SERVER_IP --standalone --listen-v4
```

### Panel not accessible

```bash
# Check service
systemctl status x-ui
# Check port
ss -tlnp | grep 2053
# Check firewall
ufw status | grep 2053
# Restart
systemctl restart x-ui
```

### Slow speed

```bash
# Verify BBR
sysctl net.ipv4.tcp_congestion_control
# Should be: bbr

# Check CPU/RAM load
top -bn1 | head -5
free -h

# Check network
iperf3 -c speedtest.uzt.lt -p 5201
```
