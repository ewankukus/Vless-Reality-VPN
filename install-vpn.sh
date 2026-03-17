#!/bin/bash
# =============================================================
# 3X-UI VPN Server — Установка и оптимизация v3.1
# ОС: Ubuntu 22.04+ LTS (проверено на 1 Core / 1GB RAM / 1Gbps)
# Протокол: VLESS + Reality (xtls-rprx-vision)
# Аудит: Security Engineer, SRE, DevOps Automator
# =============================================================

# ===================== КОНФИГУРАЦИЯ =========================
PANEL_PORT="${PANEL_PORT:-2053}"
SUB_PORT="${SUB_PORT:-2096}"
VLESS_PORT="${VLESS_PORT:-443}"
SWAP_MB="${SWAP_MB:-512}"
REALITY_TARGET="${REALITY_TARGET:-www.samsung.com}"
# ============================================================

# --- Цвета ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
step() { echo -e "\n${CYAN}[$1/$TOTAL_STEPS]${NC} $2"; }

TOTAL_STEPS=10

# --- Предварительные проверки ---
if [ "$EUID" -ne 0 ]; then
    err "Запустите от root: sudo bash install-vpn.sh"
    exit 1
fi

if ! grep -qi 'ubuntu' /etc/os-release 2>/dev/null; then
    err "Скрипт требует Ubuntu 22.04+"
    exit 1
fi

SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me || curl -s4 --max-time 5 icanhazip.com || echo "UNKNOWN")
SERVER_IP6=$(curl -s6 --max-time 5 ifconfig.me 2>/dev/null || echo "")

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}   3X-UI VPN — Установка и оптимизация v3.1        ${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "  IPv4:  ${GREEN}${SERVER_IP}${NC}"
[ -n "$SERVER_IP6" ] && echo -e "  IPv6:  ${GREEN}${SERVER_IP6}${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo ""

# ============================================================
# Шаг 1: Обновление системы
# ============================================================
step 1 "Обновление системы и установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# Останавливаем unattended-upgrades (блокирует apt на свежих серверах)
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true

# Ожидание снятия блокировки dpkg (макс. 120 сек)
WAIT=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    if [ $WAIT -eq 0 ]; then warn "Ожидание снятия блокировки dpkg..."; fi
    sleep 3
    WAIT=$((WAIT + 3))
    if [ $WAIT -ge 120 ]; then
        warn "Принудительное снятие блокировки через ${WAIT}с"
        kill -9 "$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null)" 2>/dev/null || true
        rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock
        dpkg --configure -a 2>/dev/null || true
        break
    fi
done

apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o DPkg::Lock::Timeout=60
apt-get install -y -qq -o DPkg::Lock::Timeout=60 curl wget socat unzip jq ufw fail2ban chrony sqlite3
log "Система обновлена, зависимости установлены"

# ============================================================
# Шаг 2: Синхронизация времени (критично для TLS/Reality)
# ============================================================
step 2 "Синхронизация времени (NTP)..."
systemctl enable --now chrony > /dev/null 2>&1
chronyc makestep > /dev/null 2>&1 || true
log "Chrony активен — смещение: $(chronyc tracking 2>/dev/null | grep 'System time' | awk '{print $4$5}' || echo 'синхронизирован')"

# ============================================================
# Шаг 3: Оптимизация сети (идемпотентный drop-in файл)
# ============================================================
step 3 "BBR + оптимизация TCP/сети..."

cat > /etc/sysctl.d/99-vpn-tuning.conf << 'SYSCTL'
# === BBR Congestion Control ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === Буферы (оптимально для 1GB RAM — макс. 4MB) ===
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304

# === Оптимизация прокси ===
net.ipv4.tcp_notsent_lowat = 131072

# === TCP производительность ===
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

# === Диапазон портов ===
net.ipv4.ip_local_port_range = 1024 65535

# === Форвардинг ===
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# === Защита ядра ===
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

# === Swap ===
vm.swappiness = 10
SYSCTL

sysctl --system > /dev/null 2>&1
log "BBR: $(sysctl -n net.ipv4.tcp_congestion_control) | notsent_lowat: $(sysctl -n net.ipv4.tcp_notsent_lowat) | fastopen: $(sysctl -n net.ipv4.tcp_fastopen)"

# ============================================================
# Шаг 4: Лимиты файловых дескрипторов
# ============================================================
step 4 "Лимиты файловых дескрипторов..."

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
# Шаг 5: Swap (подстраховка для серверов с малым RAM)
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
    log "Swap уже активен: $(free -h | grep Swap | awk '{print $2}')"
fi

# ============================================================
# Шаг 6: Файрвол (UFW) — ДО установки 3X-UI!
# ============================================================
step 6 "Файрвол (UFW)..."
ufw default deny incoming > /dev/null 2>&1
ufw default allow outgoing > /dev/null 2>&1

# Правила
ufw allow 22/tcp comment 'SSH' > /dev/null 2>&1
ufw limit 22/tcp comment 'SSH-brute-force' > /dev/null 2>&1
ufw allow "${VLESS_PORT}/tcp" comment 'VLESS-Reality' > /dev/null 2>&1
ufw allow "${PANEL_PORT}/tcp" comment '3X-UI-Panel' > /dev/null 2>&1
ufw allow "${SUB_PORT}/tcp" comment 'Subscription' > /dev/null 2>&1
ufw allow 80/tcp comment 'ACME-cert-renewal' > /dev/null 2>&1

# Включаем UFW
ufw --force enable > /dev/null 2>&1
log "UFW активен — порты: 22(SSH) ${VLESS_PORT}(VLESS) ${PANEL_PORT}(Панель) ${SUB_PORT}(Подписка) 80(ACME)"

# ============================================================
# Шаг 7: fail2ban (защита SSH)
# ============================================================
step 7 "fail2ban (защита от брутфорса SSH)..."

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
log "fail2ban активен для SSH"

# ============================================================
# Шаг 8: Установка 3X-UI
# ============================================================
step 8 "Установка панели 3X-UI..."

# Скачиваем установщик
INSTALLER="/tmp/3xui-install.sh"
curl -sSLo "$INSTALLER" https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh

if [ ! -s "$INSTALLER" ]; then
    err "Не удалось скачать установщик 3X-UI"
    exit 1
fi

log "Установщик скачан ($(wc -c < "$INSTALLER") байт)"
echo ""
echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  Сейчас запустится установщик 3X-UI.                ║${NC}"
echo -e "${YELLOW}║                                                      ║${NC}"
echo -e "${YELLOW}║  Customize Panel Port? — нажмите: y                  ║${NC}"
echo -e "${YELLOW}║  Panel port:  2053                                   ║${NC}"
echo -e "${YELLOW}║  SSL method:  2 (Let's Encrypt for IP)               ║${NC}"
echo -e "${YELLOW}║  IPv6:        Enter (пропустить)                     ║${NC}"
echo -e "${YELLOW}║  ACME port:   Enter (по умолчанию 80)               ║${NC}"
echo -e "${YELLOW}║                                                      ║${NC}"
echo -e "${YELLOW}║  Логин/пароль сгенерируются автоматически.           ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

bash "$INSTALLER"
rm -f "$INSTALLER"

# Читаем реальные настройки панели (порт может отличаться)
ACTUAL_PORT=$(grep -oP 'port:\s*\K\d+' <<< "$(/usr/local/x-ui/x-ui setting -show 2>/dev/null)" || echo "$PANEL_PORT")
ACTUAL_BASE=$(grep -oP 'webBasePath:\s*\K\S+' <<< "$(/usr/local/x-ui/x-ui setting -show 2>/dev/null)" || echo "/")

# Открываем реальный порт панели в UFW если отличается
if [ "$ACTUAL_PORT" != "$PANEL_PORT" ]; then
    ufw allow "${ACTUAL_PORT}/tcp" comment '3X-UI-Panel' > /dev/null 2>&1
    log "Порт панели ${ACTUAL_PORT} открыт в UFW"
fi

log "Панель установлена. Для просмотра доступов:"
echo "    /usr/local/x-ui/x-ui setting -show"

# ============================================================
# Шаг 9: Автоматические обновления безопасности
# ============================================================
step 9 "Автоматические обновления безопасности..."
apt-get install -y -qq -o DPkg::Lock::Timeout=60 unattended-upgrades

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/51custom-unattended << 'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

log "Автообновления безопасности включены"

# ============================================================
# Шаг 10: Итоги
# ============================================================
step 10 "Установка завершена!"

# Используем реальные настройки
WEB_BASE="${ACTUAL_BASE:-/}"
PANEL_PORT="${ACTUAL_PORT:-$PANEL_PORT}"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}     УСТАНОВКА ЗАВЕРШЕНА — ВСЕ ОПТИМИЗАЦИИ ПРИМЕНЕНЫ   ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "  ${CYAN}Сервер${NC}"
echo -e "    IPv4:           ${GREEN}${SERVER_IP}${NC}"
[ -n "$SERVER_IP6" ] && echo -e "    IPv6:           ${GREEN}${SERVER_IP6}${NC}"
echo ""
echo -e "  ${CYAN}Оптимизации${NC}"
echo -e "    BBR:            ${GREEN}$(sysctl -n net.ipv4.tcp_congestion_control)${NC}"
echo -e "    notsent_lowat:  ${GREEN}$(sysctl -n net.ipv4.tcp_notsent_lowat)${NC}"
echo -e "    FastOpen:       ${GREEN}$(sysctl -n net.ipv4.tcp_fastopen)${NC}"
echo -e "    Swap:           ${GREEN}$(free -h | grep Swap | awk '{print $2}')${NC}"
echo -e "    fail2ban:       ${GREEN}активен${NC}"
echo -e "    Chrony/NTP:     ${GREEN}активен${NC}"
echo -e "    UFW:            ${GREEN}активен${NC}"
echo -e "    nofile:         ${GREEN}51200${NC}"
echo ""
echo -e "  ${CYAN}Доступ к панели${NC}"
echo -e "    URL:            ${GREEN}https://${SERVER_IP}:${PANEL_PORT}${WEB_BASE}${NC}"
echo -e "    Доступы:        ${YELLOW}/usr/local/x-ui/x-ui setting -show${NC}"
echo ""
echo -e "  ${CYAN}Настройки VLESS + Reality (создайте Inbound в панели)${NC}"
echo -e "    Порт:           ${GREEN}${VLESS_PORT}${NC}"
echo -e "    Протокол:       ${GREEN}vless${NC}"
echo -e "    Транспорт:      ${GREEN}TCP (RAW)${NC}"
echo -e "    Безопасность:   ${GREEN}Reality${NC}"
echo -e "    Flow:           ${GREEN}xtls-rprx-vision${NC}"
echo -e "    Target/SNI:     ${GREEN}${REALITY_TARGET}:443${NC}"
echo -e "    uTLS:           ${GREEN}chrome${NC}"
echo -e "    Sniffing:       ${GREEN}HTTP + TLS + QUIC + FAKEDNS${NC}"
echo ""
echo -e "  ${CYAN}Альтернативные Reality-цели${NC}"
echo -e "    ${GREEN}www.samsung.com${NC}   — мало фингерпринтов, глобальный CDN"
echo -e "    ${GREEN}www.mozilla.org${NC}   — Mozilla, TLS 1.3"
echo -e "    ${GREEN}www.asus.com${NC}      — низкий профиль, TLS 1.3"
echo -e "    ${GREEN}dl.google.com${NC}     — CDN загрузок Google"
echo ""
echo -e "  ${CYAN}Настройки клиента${NC}"
echo -e "    Адрес:          ${GREEN}${SERVER_IP}${NC} (только IP, НЕ домен)"
echo -e "    DNS:            ${GREEN}77.88.8.8${NC} (Яндекс — работает при блокировках РФ)"
echo -e "                    ${GREEN}8.8.8.8${NC} (Google — быстрее глобально)"
echo ""
echo -e "  ${CYAN}Клиентские приложения${NC}"
echo -e "    iOS/Mac:        Streisand, V2Box"
echo -e "    Android:        V2rayNG, NekoBox"
echo -e "    Windows:        Hiddify, V2rayN"
echo ""
echo -e "  ${YELLOW}БЕЗОПАСНОСТЬ ПОСЛЕ УСТАНОВКИ (рекомендуется):${NC}"
echo -e "    1. Сменить пароль root:"
echo -e "       ${GREEN}passwd${NC}"
echo -e "    2. Отключить вход по паролю SSH (после настройки ключей):"
echo -e "       ${GREEN}sed -i 's/#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config${NC}"
echo -e "       ${GREEN}sed -i 's/#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config${NC}"
echo -e "       ${GREEN}systemctl restart sshd${NC}"
echo -e "    3. Ограничить панель только вашим IP:"
echo -e "       ${GREEN}ufw delete allow ${PANEL_PORT}/tcp${NC}"
echo -e "       ${GREEN}ufw allow from ВАШ_IP to any port ${PANEL_PORT} proto tcp${NC}"
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
