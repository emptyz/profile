#!/bin/bash
# ═══════════════════════════════════════════════════════
# HOMELAB SETUP — Ubuntu Server 26.04 LTS
# One-shot script — jalankan sebagai root / sudo
# ═══════════════════════════════════════════════════════
# Cara pakai:
#   wget -qO- https://ishol.web.id/homelab-setup.sh | bash
# atau:
#   curl -fsSL https://ishol.web.id/homelab-setup.sh | bash
# ═══════════════════════════════════════════════════════

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
ok()      { echo -e "  ${GREEN}✅${NC} $1"; }
warn()    { echo -e "  ${YELLOW}⚠️${NC} $1"; }
fail()    { echo -e "  ${RED}❌${NC} $1"; exit 1; }

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${CYAN}     HOMELAB AUTO-SETUP — Ubuntu Server      ${NC}"
echo -e "${CYAN}     PC: i7-8700 | 8GB RAM | 256GB SSD       ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo ""

# ─────────── Konfigurasi Awal ───────────

# Ubah sesuai kebutuhan kamu
DOMAIN="ishol.my.id"
TIMEZONE="Asia/Jakarta"
USERNAME=$(whoami)

# ─────────── Fase 1: System Update ───────────

log "${YELLOW}[1/8]${NC} System update & upgrade..."
sudo apt update -qq && sudo apt upgrade -y -qq
ok "System updated"

# ─────────── Fase 2: Tools Dasar ───────────

log "${YELLOW}[2/8]${NC} Installing essential tools..."
sudo apt install -y -qq \
    curl wget git htop net-tools \
    unzip zip gpg ca-certificates \
    software-properties-common \
    ufw fail2ban \
    gnupg lsb-release \
    tree jq \
    chrony
ok "Tools installed"

# ─────────── Fase 3: System Optimization ───────────

log "${YELLOW}[3/8]${NC} System optimization..."

# Set timezone
sudo timedatectl set-timezone "$TIMEZONE"

# Optimasi kernel
cat << 'EOF' | sudo tee /etc/sysctl.d/99-homelab.conf > /dev/null
# Homelab optimizations
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
vm.swappiness = 10
vm.vfs_cache_pressure = 50
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sudo sysctl -p /etc/sysctl.d/99-homelab.conf > /dev/null 2>&1

# Enable BBR
echo "tcp_bbr" | sudo tee /etc/modules-load.d/bbr.conf > /dev/null

# Disable IPv6 (opsional, untuk kestabilan di beberapa jaringan)
cat << 'EOF' | sudo tee -a /etc/sysctl.conf > /dev/null
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
EOF

# Swap — minimal untuk umur SSD
sudo sysctl vm.swappiness=10 > /dev/null

# ZRAM — kompresi RAM untuk 8GB
sudo apt install -y -qq zram-tools 2>/dev/null || true
cat << 'EOF' | sudo tee /etc/default/zramswap > /dev/null
PERCENT=50
PRIORITY=100
EOF
sudo systemctl restart zramswap 2>/dev/null || true
ok "System optimized"

# ─────────── Fase 4: Docker ───────────

log "${YELLOW}[4/8]${NC} Installing Docker..."

# Uninstall paket lama
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    sudo apt-get remove -qq $pkg 2>/dev/null || true
done

# Install Docker official
curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
sudo usermod -aG docker "$USERNAME" 2>/dev/null || true

# Docker Compose plugin
sudo apt install -y -qq docker-compose-plugin 2>/dev/null || \
    sudo apt install -y -qq docker-compose-v2 2>/dev/null || true

# Docker optimasi
sudo mkdir -p /etc/docker
cat << 'EOF' | sudo tee /etc/docker/daemon.json > /dev/null
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF

sudo systemctl enable docker > /dev/null 2>&1
sudo systemctl restart docker
ok "Docker installed & optimized"

# ─────────── Fase 5: Setup Direktori ───────────

log "${YELLOW}[5/8]${NC} Setting up directories..."

mkdir -p ~/homelab
mkdir -p ~/homelab/services
mkdir -p ~/homelab/data
mkdir -p ~/homelab/backup

ok "Directories created at ~/homelab/"

# ─────────── Fase 6: Docker Services ───────────

log "${YELLOW}[6/8]${NC} Deploying core services..."

SERVICES_DIR="$HOME/homelab/services"
cd "$SERVICES_DIR"

# ---------- 6a: Portainer ----------
log "  → Portainer..."
docker volume create portainer_data > /dev/null 2>&1
docker run -d \
    --name portainer \
    --restart always \
    -p 9000:9000 \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest > /dev/null 2>&1
ok "Portainer → https://localhost:9443"

# ---------- 6b: Uptime Kuma ----------
log "  → Uptime Kuma..."
docker run -d \
    --name uptime-kuma \
    --restart always \
    -p 3001:3001 \
    -v ~/homelab/data/uptime-kuma:/app/data \
    louislam/uptime-kuma:latest > /dev/null 2>&1
ok "Uptime Kuma → http://localhost:3001"

# ---------- 6c: Nginx Proxy Manager ----------
log "  → Nginx Proxy Manager..."
docker volume create npm_data > /dev/null 2>&1
docker volume create npm_letsencrypt > /dev/null 2>&1
docker run -d \
    --name npm \
    --restart always \
    -p 80:80 \
    -p 81:81 \
    -p 443:443 \
    -v npm_data:/data \
    -v npm_letsencrypt:/etc/letsencrypt \
    jc21/nginx-proxy-manager:latest > /dev/null 2>&1
ok "NPM → http://localhost:81"

# ---------- 6d: Watchtower (auto-update) ----------
log "  → Watchtower..."
docker run -d \
    --name watchtower \
    --restart always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower:latest \
    --cleanup --schedule "0 4 * * *" > /dev/null 2>&1
ok "Watchtower auto-update: setiap jam 4 pagi"

# ---------- 6e: Pi-hole ----------
log "  → Pi-hole..."
mkdir -p ~/homelab/data/pihole
IP_ADDR=$(hostname -I | awk '{print $1}')
docker run -d \
    --name pihole \
    --restart always \
    -p 53:53/tcp \
    -p 53:53/udp \
    -p 8053:80/tcp \
    -e TZ="$TIMEZONE" \
    -e WEBPASSWORD="homelab123" \
    -e PIHOLE_DNS_="1.1.1.1;1.0.0.1" \
    -e SERVER_IP="$IP_ADDR" \
    -v ~/homelab/data/pihole:/etc/pihole \
    -v ~/homelab/data/pihole-dnsmasq:/etc/dnsmasq.d \
    pihole/pihole:latest > /dev/null 2>&1
ok "Pi-hole → http://localhost:8053 (admin/homelab123)"

# ---------- 6f: Vaultwarden (password manager) ----------
log "  → Vaultwarden..."
docker run -d \
    --name vaultwarden \
    --restart always \
    -p 8080:80 \
    -e SIGNUPS_ALLOWED=false \
    -v ~/homelab/data/vaultwarden:/data \
    vaultwarden/server:latest > /dev/null 2>&1
ok "Vaultwarden → http://localhost:8080"

# ---------- 6g: N8N (automasi) ----------
log "  → N8N..."
docker run -d \
    --name n8n \
    --restart always \
    -p 5678:5678 \
    -e N8N_SECURE_COOKIE=false \
    -v ~/homelab/data/n8n:/home/node/.n8n \
    n8nio/n8n:latest > /dev/null 2>&1
ok "N8N → http://localhost:5678"

# ---------- 6h: Glance Dashboard ----------
log "  → Glance Dashboard..."
docker run -d \
    --name glance \
    --restart always \
    -p 8085:8080 \
    -v ~/homelab/data/glance:/app/config \
    glanceapp/glance:latest > /dev/null 2>&1
ok "Glance → http://localhost:8085"

# ---------- 6i: FileBrowser ----------
log "  → FileBrowser..."
docker run -d \
    --name filebrowser \
    --restart always \
    -p 8081:80 \
    -v /:/srv \
    -v ~/homelab/data/filebrowser:/database \
    -e FB_BASEURL=/ \
    filebrowser/filebrowser:latest > /dev/null 2>&1
ok "FileBrowser → http://localhost:8081"

ok "Docker services deployed"

# ─────────── Fase 7: Firewall & Security ───────────

log "${YELLOW}[7/8]${NC} Security setup..."

sudo ufw --force reset > /dev/null 2>&1
sudo ufw default deny incoming > /dev/null
sudo ufw default allow outgoing > /dev/null

# Port untuk akses lokal
sudo ufw allow ssh > /dev/null
sudo ufw allow 80/tcp comment 'HTTP' > /dev/null
sudo ufw allow 443/tcp comment 'HTTPS' > /dev/null
sudo ufw allow 81/tcp comment 'NPM' > /dev/null
sudo ufw allow 9443/tcp comment 'Portainer' > /dev/null

# Aktifkan
sudo ufw --force enable > /dev/null
ok "Firewall configured"

# fail2ban — proteksi SSH
cat << 'EOF' | sudo tee /etc/fail2ban/jail.d/ssh.local > /dev/null
[sshd]
enabled = true
port = ssh
maxretry = 3
bantime = 3600
findtime = 600
EOF
sudo systemctl enable fail2ban > /dev/null 2>&1
sudo systemctl restart fail2ban
ok "fail2ban aktif — 3x gagal login = banned 1 jam"

# ─────────── Fase 8: Selesai ───────────

log "${YELLOW}[8/8]${NC} Finalizing..."

# Buat alias
cat << 'EOF' >> ~/.bashrc

# Homelab shortcuts
alias hlst='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias hlog='docker logs -f'
alias hup='cd ~/homelab && docker compose up -d'
alias hdown='cd ~/homelab && docker compose down'
alias hrestart='cd ~/homelab && docker compose restart'
EOF

# Informasi IP
INTERNAL_IP=$(hostname -I | awk '{print $1}')

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}        🎉 HOMELAB SETUP SELESAI!            ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e " ${CYAN}IP Server:${NC}    $INTERNAL_IP"
echo ""
echo -e " ${GREEN}Service${NC}           ${GREEN}Akses${NC}"
echo -e " ─────────────────────────────────────"
echo -e " Portainer          https://$INTERNAL_IP:9443"
echo -e " Nginx Proxy Mgr    http://$INTERNAL_IP:81"
echo -e " Pi-hole            http://$INTERNAL_IP:8053"
echo -e " Uptime Kuma        http://$INTERNAL_IP:3001"
echo -e " Vaultwarden        http://$INTERNAL_IP:8080"
echo -e " N8N                http://$INTERNAL_IP:5678"
echo -e " Glance Dashboard   http://$INTERNAL_IP:8085"
echo -e " FileBrowser        http://$INTERNAL_IP:8081"
echo ""
echo -e " ${YELLOW}Catatan:${NC}"
echo -e " - Portainer pass: atur saat pertama login"
echo -e " - Pi-hole pass: admin / homelab123"
echo -e " - Vaultwarden: signup dinonaktifkan — buat akun dulu"
echo -e " - Semua service bisa diakses via NPM nanti"
echo -e " - Jalankan: ${CYAN}source ~/.bashrc${NC} buat alias aktif"
echo ""
echo -e " ${YELLOW}⚠️  Jangan lupa setup Cloudflare Tunnel untuk akses luar!${NC}"
echo -e " ${YELLOW}   https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/${NC}"
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
