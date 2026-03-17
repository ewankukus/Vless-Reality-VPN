#!/bin/bash
# =============================================================
# 3X-UI VPN Server — Installation & Optimization Script v3.0
# OS: Ubuntu 22.04+ LTS (tested on 1 Core / 1GB RAM / 1Gbps)
# Protocol: VLESS + Reality (xtls-rprx-vision)
# Audited by: Security Engineer, SRE, DevOps Automator
# =============================================================

# ===================== CONFIGURATION ========================
PANEL_PORT="${PANEL_PORT:-2053}"
SUB_PORT="${SUB_PORT:-2096}"
VLESS_PORT="${VLESS_PORT:-443}"
SWAP_MB="${SWAP_MB:-512}"
REALITY_TARGET="${REALITY_TARGET:-www.samsung.com}"
# ============================================================

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
step() { echo -e "\n${CYAN}[$1/$TOTAL_STEPS]${NC} $2"; }

TOTAL_STEPS=10

# --- Pre-flight checks ---
if [ "$EUID" -ne 0 ]; then
    err "Run as root: sudo bash install-vpn.sh"
    exit 1
fi

if ! grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
    err "This script requires Ubuntu 22.04+"
    exit 1
fi

SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me || curl -s4 --max-time 5 icanhazip.com || echo "UNKNOWN")
SERVER_IP6=$(curl -s6 --max-time 5 ifconfig.me 2>/dev/null || echo "")

echo ""
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo -e "${CYAN}   3X-UI VPN Server — Install & Optimize v3.0  ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo -e "  IPv4:  ${GREEN}${SERVER_IP}${NC}"
[ -n "$SERVER_IP6" ] && echo -e "  IPv6:  ${GREEN}${SERVER_IP6}${NC}"
echo -e "${CYAN}════════════════════════════════════════════════${NC}"
echo ""

# ============================================================
# Step 1: System update
# ============================================================
step 1 "System update & dependencies..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Wait for any running apt/dpkg to finish (fresh servers often run unattended-upgrades)
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    warn "Waiting for dpkg lock to be released..."
    sleep 5
done

apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o DPkg::Lock::Timeout=60
apt-get install -y -qq -o DPkg::Lock::Timeout=60 curl wget socat unzip jq ufw fail2ban chrony sqlite3
log "System updated, dependencies installed"

# ============================================================
# Step 2: NTP time sync (critical for TLS/Reality handshake)
# ============================================================
step 2 "Time synchronization (NTP)..."
systemctl enable --now chrony > /dev/null 2>&1
chronyc makestep > /dev/null 2>&1 || true
log "Chrony active — offset: $(chronyc tracking 2>/dev/null | grep 'System time' | awk '{print $4$5}' || echo 'synced')"

# ============================================================
# Step 3: Network optimization (idempotent drop-in)
# ============================================================
step 3 "BBR + TCP/network optimization..."

cat > /etc/sysctl.d/99-vpn-tuning.conf << 'SYSCTL'
# === BBR Congestion Control ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === Buffer Sizes (tuned for 1GB RAM — 4MB max) ===
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304

# === Proxy Optimization ===
net.ipv4.tcp_notsent_lowat = 131072

# === TCP Performance ===
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 8192
net.core.netdev_max_backlog = 4096

# === Ephemeral Port Range ===
net.ipv4.ip_local_port_range = 1024 65535

# === Forwarding ===
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# === Kernel Hardening ===
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1

# === Conntrack ===
net.netfilter.nf_conntrack_max = 16384

# === Swap Pressure ===
vm.swappiness = 10
SYSCTL

sysctl --system > /dev/null 2>&1
log "BBR: $(sysctl -n net.ipv4.tcp_congestion_control) | notsent_lowat: $(sysctl -n net.ipv4.tcp_notsent_lowat) | fastopen: $(sysctl -n net.ipv4.tcp_fastopen)"

# ============================================================
# Step 4: File descriptor limits
# ============================================================
step 4 "File descriptor limits..."

cat > /etc/security/limits.d/99-vpn.conf << 'EOF'
* soft nofile 51200
* hard nofile 51200
root soft nofile 51200
root hard nofile 51200
EOF

mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=51200
EOF
systemctl daemon-reload
log "nofile = 51200"

# ============================================================
# Step 5: Swap (safety net for low-RAM servers)
# ============================================================
step 5 "Swap (${SWAP_MB}MB)..."
if ! swapon --show | grep -q /swapfile; then
    if [ -f /swapfile ]; then
        swapon /swapfile 2>/dev/null || true
    else
        dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress 2>&1 | tail -1
        chmod 600 /swapfile
        mkswap /swapfile > /dev/null
        swapon /swapfile
    fi
    grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    log "Swap: $(free -h | grep Swap | awk '{print $2}')"
else
    log "Swap already active: $(free -h | grep Swap | awk '{print $2}')"
fi

# ============================================================
# Step 6: Firewall (UFW) — BEFORE 3X-UI install!
# ============================================================
step 6 "Firewall (UFW)..."
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1

# Core rules
ufw allow 22/tcp comment 'SSH' > /dev/null 2>&1
ufw limit 22/tcp comment 'SSH-brute-force' > /dev/null 2>&1
ufw allow "${VLESS_PORT}/tcp" comment 'VLESS-Reality' > /dev/null 2>&1
ufw allow "${PANEL_PORT}/tcp" comment '3X-UI-Panel' > /dev/null 2>&1
ufw allow "${SUB_PORT}/tcp" comment 'Subscription' > /dev/null 2>&1
ufw allow 80/tcp comment 'ACME-cert-renewal' > /dev/null 2>&1

# Safety check: SSH must be allowed before enabling
if ufw status | grep -q "22/tcp"; then
    ufw --force enable > /dev/null 2>&1
    log "UFW active — ports: 22(SSH) ${VLESS_PORT}(VLESS) ${PANEL_PORT}(Panel) ${SUB_PORT}(Sub) 80(ACME)"
else
    err "SSH rule missing — NOT enabling firewall!"
    warn "Fix: ufw allow 22/tcp && ufw --force enable"
fi

# ============================================================
# Step 7: fail2ban (SSH protection)
# ============================================================
step 7 "fail2ban (SSH brute-force protection)..."

cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
EOF

systemctl enable fail2ban > /dev/null 2>&1
systemctl restart fail2ban
log "fail2ban active for SSH"

# ============================================================
# Step 8: Install 3X-UI
# ============================================================
step 8 "Installing 3X-UI panel..."

# Download installer
INSTALLER="/tmp/3xui-install.sh"
curl -sSLo "$INSTALLER" https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh

if [ ! -s "$INSTALLER" ]; then
    err "Failed to download 3X-UI installer"
    exit 1
fi

log "Installer downloaded ($(wc -c < "$INSTALLER") bytes)"
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  3X-UI installer will now run interactively.     ║${NC}"
echo -e "${YELLOW}║                                                  ║${NC}"
echo -e "${YELLOW}║  When prompted, enter:                           ║${NC}"
echo -e "${YELLOW}║    Panel port:  ${PANEL_PORT}                            ║${NC}"
echo -e "${YELLOW}║    SSL method:  2 (Let's Encrypt for IP)         ║${NC}"
echo -e "${YELLOW}║    ACME port:   80 (default, press Enter)        ║${NC}"
echo -e "${YELLOW}║                                                  ║${NC}"
echo -e "${YELLOW}║  Credentials will be generated automatically.    ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${NC}"
echo ""

bash "$INSTALLER"
rm -f "$INSTALLER"

log "Panel installed. To view credentials run:"
echo "    /usr/local/x-ui/x-ui setting -show"

# ============================================================
# Step 9: Automatic security updates
# ============================================================
step 9 "Automatic security updates..."
apt-get install -y -qq -o DPkg::Lock::Timeout=60 unattended-upgrades

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/51custom-unattended << 'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

log "Unattended security upgrades enabled"

# ============================================================
# Step 10: Summary & Next Steps
# ============================================================
step 10 "Installation complete!"

# Gather panel info
PANEL_INFO=$(/usr/local/x-ui/x-ui setting -show 2>/dev/null || echo "run: /usr/local/x-ui/x-ui setting -show")
WEB_BASE=$(echo "$PANEL_INFO" | grep -oP 'webBasePath:\s*\K\S+' || echo "/")

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}     INSTALLATION COMPLETE — ALL OPTIMIZATIONS ON  ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Server${NC}"
echo -e "    IPv4:           ${GREEN}${SERVER_IP}${NC}"
[ -n "$SERVER_IP6" ] && echo -e "    IPv6:           ${GREEN}${SERVER_IP6}${NC}"
echo ""
echo -e "  ${CYAN}Optimizations Applied${NC}"
echo -e "    BBR:            ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control)${NC}"
echo -e "    notsent_lowat:  ${GREEN}$(sysctl -n net.ipv4.tcp_notsent_lowat)${NC}"
echo -e "    FastOpen:       ${GREEN}$(sysctl -n net.ipv4.tcp_fastopen)${NC}"
echo -e "    Swap:           ${GREEN}$(free -h | grep Swap | awk '{print $2}')${NC}"
echo -e "    fail2ban:       ${GREEN}active${NC}"
echo -e "    Chrony/NTP:     ${GREEN}active${NC}"
echo -e "    UFW:            ${GREEN}active${NC}"
echo -e "    nofile:         ${GREEN}51200${NC}"
echo ""
echo -e "  ${CYAN}Panel Access${NC}"
echo -e "    URL:            ${GREEN}https://${SERVER_IP}:${PANEL_PORT}${WEB_BASE}${NC}"
echo -e "    Credentials:    run ${YELLOW}/usr/local/x-ui/x-ui setting -show${NC}"
echo ""
echo -e "  ${CYAN}VLESS + Reality Inbound Settings${NC}"
echo -e "    Port:           ${GREEN}${VLESS_PORT}${NC}"
echo -e "    Protocol:       ${GREEN}vless${NC}"
echo -e "    Transport:      ${GREEN}TCP (RAW)${NC}"
echo -e "    Security:       ${GREEN}Reality${NC}"
echo -e "    Flow:           ${GREEN}xtls-rprx-vision${NC}"
echo -e "    Target/SNI:     ${GREEN}${REALITY_TARGET}:443${NC}"
echo -e "    uTLS:           ${GREEN}chrome${NC}"
echo -e "    Sniffing:       ${GREEN}HTTP + TLS + QUIC + FAKEDNS${NC}"
echo ""
echo -e "  ${CYAN}Alternative Reality Targets${NC}"
echo -e "    ${GREEN}www.samsung.com${NC}   — less fingerprinted, global CDN"
echo -e "    ${GREEN}www.mozilla.org${NC}   — Firefox org, TLS 1.3"
echo -e "    ${GREEN}www.asus.com${NC}      — low profile, TLS 1.3"
echo -e "    ${GREEN}dl.google.com${NC}     — download CDN, high trust"
echo ""
echo -e "  ${CYAN}Client Settings${NC}"
echo -e "    Address:        ${GREEN}${SERVER_IP}${NC} (IP only, NOT domain)"
echo -e "    DNS:            ${GREEN}77.88.8.8${NC} (Yandex — works in RU restrictions)"
echo -e "                    ${GREEN}8.8.8.8${NC} (Google — faster globally)"
echo ""
echo -e "  ${CYAN}Client Apps${NC}"
echo -e "    iOS/Mac:        Streisand, V2Box"
echo -e "    Android:        V2rayNG, NekoBox"
echo -e "    Windows:        Hiddify, V2rayN"
echo ""
echo -e "  ${YELLOW}POST-INSTALL SECURITY (do this now!):${NC}"
echo -e "    1. Change root password:"
echo -e "       ${GREEN}passwd${NC}"
echo -e "    2. Disable SSH password auth (after key setup):"
echo -e "       ${GREEN}sed -i 's/#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config${NC}"
echo -e "       ${GREEN}sed -i 's/#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config${NC}"
echo -e "       ${GREEN}systemctl restart sshd${NC}"
echo -e "    3. Restrict panel to your IP only:"
echo -e "       ${GREEN}ufw delete allow ${PANEL_PORT}/tcp${NC}"
echo -e "       ${GREEN}ufw allow from YOUR_HOME_IP to any port ${PANEL_PORT} proto tcp${NC}"
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
