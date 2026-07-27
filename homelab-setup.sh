#!/bin/bash
# ════════════════════════════════════════════════════════════════
# HOMELAB SETUP v2 — Ubuntu Server 26.04 LTS
# Rekomendasi terbaik dari Awesome Homelab 2026
# ════════════════════════════════════════════════════════════════
# Jalankan:
#   curl -fsSL https://raw.githubusercontent.com/emptyz/profile/main/homelab-setup.sh | bash
# ════════════════════════════════════════════════════════════════

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
ok()   { echo -e "  ${GREEN}✅${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠️${NC} $1"; }

DOMAIN="${DOMAIN:-ishol.my.id}"
TIMEZONE="${TIMEZONE:-Asia/Jakarta}"
USER="${USER:-faishol}"

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}   HOMELAB v2 — i7-8700 | 8GB RAM                    ${NC}"
echo -e "${CYAN}   Stack: CrowdSec + Traefik + Immich + N8N + dll    ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo ""

# ─────── STEP 1: System ───────
log "${YELLOW}[1/8]${NC} System update & tools"
sudo apt update -qq && sudo apt upgrade -y -qq
sudo apt install -y -qq curl wget git htop net-tools unzip \
    ufw gnupg lsb-release ca-certificates chrony jq tree
ok "System ready"

# ─────── STEP 2: Optimasi ───────
log "${YELLOW}[2/8]${NC} System optimization"
sudo timedatectl set-timezone "$TIMEZONE"
cat << 'EOF' | sudo tee /etc/sysctl.d/99-homelab.conf > /dev/null
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
vm.swappiness = 5
vm.vfs_cache_pressure = 50
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sudo sysctl -p /etc/sysctl.d/99-homelab.conf > /dev/null 2>&1
echo "tcp_bbr" | sudo tee /etc/modules-load.d/bbr.conf > /dev/null
ok "Kernel optimized (BBR, swappiness=5)"

# ─────── STEP 3: Docker ───────
log "${YELLOW}[3/8]${NC} Docker + Compose"
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    sudo apt-get remove -qq $pkg 2>/dev/null || true
done
curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
sudo usermod -aG docker "$USER" 2>/dev/null || true
sudo apt install -y -qq docker-compose-plugin 2>/dev/null || \
    sudo apt install -y -qq docker-compose-v2 2>/dev/null || true
sudo mkdir -p /etc/docker
cat << 'EOF' | sudo tee /etc/docker/daemon.json > /dev/null
{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"},"storage-driver":"overlay2"}
EOF
sudo systemctl enable docker > /dev/null 2>&1
sudo systemctl restart docker
ok "Docker ready"

# ─────── STEP 4: CrowdSec (pengganti fail2ban) ───────
log "${YELLOW}[4/8]${NC} CrowdSec — modern IPS/IDS"
curl -s https://install.crowdsec.net | sudo bash > /dev/null 2>&1
sudo cscli collections install crowdsecurity/linux crowdsecurity/nginx crowdsecurity/ssh > /dev/null 2>&1
sudo systemctl enable crowdsec > /dev/null 2>&1
sudo systemctl restart crowdsec
ok "CrowdSec active — global threat intelligence"

# ─────── STEP 5: Firewall ───────
log "${YELLOW}[5/8]${NC} Firewall UFW"
sudo ufw --force reset > /dev/null 2>&1
sudo ufw default deny incoming > /dev/null
sudo ufw default allow outgoing > /dev/null
sudo ufw allow ssh > /dev/null
sudo ufw allow 80/tcp > /dev/null
sudo ufw allow 443/tcp > /dev/null
sudo ufw allow 81/tcp > /dev/null
sudo ufw allow 9443/tcp > /dev/null
sudo ufw --force enable > /dev/null
ok "Firewall active"

# ─────── STEP 6: Direktori ───────
log "${YELLOW}[6/8]${NC} Creating directories"
mkdir -p ~/homelab/{services,data,backup}
ok "~/homelab/ ready"

# ─────── STEP 7: Docker Services ───────
log "${YELLOW}[7/8]${NC} Deploying services from Awesome Homelab..."

IP=$(hostname -I | awk '{print $1}')

# --- Portainer ⭐38k — UI Docker ---
log "  → Portainer"
docker volume create portainer_data > /dev/null 2>&1
docker run -d --name portainer --restart always \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest > /dev/null 2>&1

# --- Traefik ⭐55k — Reverse proxy modern ---
log "  → Traefik (auto-SSL + auto-detect)"
docker network create traefik-net > /dev/null 2>&1 || true
mkdir -p ~/homelab/data/traefik
cat << 'TRAEFIK' > ~/homelab/data/traefik/traefik.yml
api:
  dashboard: true
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
  websecure:
    address: ":443"
providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
  file:
    directory: /etc/traefik/dynamic
    watch: true
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@example.com
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web
TRAEFIK
touch ~/homelab/data/traefik/acme.json
chmod 600 ~/homelab/data/traefik/acme.json
docker run -d --name traefik --restart always \
    -p 80:80 -p 443:443 \
    -v ~/homelab/data/traefik/traefik.yml:/etc/traefik/traefik.yml \
    -v ~/homelab/data/traefik/acme.json:/etc/traefik/acme.json \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --network traefik-net \
    traefik:latest > /dev/null 2>&1

# --- Glance ⭐36k — Dashboard ---
log "  → Glance dashboard"
docker run -d --name glance --restart always \
    -p 8085:8080 \
    -v ~/homelab/data/glance:/app/config \
    --network traefik-net \
    glanceapp/glance:latest > /dev/null 2>&1

# --- Pi-hole ⭐51k — DNS ad-blocker ---
log "  → Pi-hole"
mkdir -p ~/homelab/data/pihole ~/homelab/data/pihole-dnsmasq
docker run -d --name pihole --restart always \
    -p 53:53/tcp -p 53:53/udp -p 8053:80 \
    -e TZ="$TIMEZONE" -e WEBPASSWORD="homelab123" \
    -e PIHOLE_DNS_="1.1.1.1;1.0.0.1" \
    -v ~/homelab/data/pihole:/etc/pihole \
    -v ~/homelab/data/pihole-dnsmasq:/etc/dnsmasq.d \
    pihole/pihole:latest > /dev/null 2>&1

# --- AdGuard Home ⭐28k (DNS alternatif — nonaktif dulu, pilih salah satu) ---
# Uncomment kalau mau pake AdGuard sebagai ganti Pi-hole
# docker run -d --name adguard --restart always \
#     -p 8054:80 -p 3000:3000 \
#     -v ~/homelab/data/adguard:/opt/adguardhome/work \
#     adguard/adguardhome:latest

# --- Uptime Kuma ⭐63k — Monitoring ---
log "  → Uptime Kuma"
docker run -d --name uptime-kuma --restart always \
    -p 3001:3001 \
    -v ~/homelab/data/uptime-kuma:/app/data \
    louislam/uptime-kuma:latest > /dev/null 2>&1

# --- Beszel ⭐23k — Monitoring ringan (alternatif Grafana) ---
log "  → Beszel (lightweight monitoring)"
docker run -d --name beszel --restart always \
    -p 8086:8090 \
    -v ~/homelab/data/beszel:/opt/beszel/data \
    henrygd/beszel:latest > /dev/null 2>&1

# --- Vaultwarden ⭐42k — Password manager ---
log "  → Vaultwarden"
docker run -d --name vaultwarden --restart always \
    -p 8080:80 \
    -e SIGNUPS_ALLOWED=false \
    -v ~/homelab/data/vaultwarden:/data \
    vaultwarden/server:latest > /dev/null 2>&1

# --- N8N (⭐60k) — Automasi ---
log "  → N8N"
docker run -d --name n8n --restart always \
    -p 5678:5678 \
    -e N8N_SECURE_COOKIE=false \
    -e DB_TYPE=sqlite \
    -v ~/homelab/data/n8n:/home/node/.n8n \
    n8nio/n8n:latest > /dev/null 2>&1

# --- Immich ⭐57k — Google Photos ---
log "  → Immich"
mkdir -p ~/homelab/data/immich/{db,upload,library}
docker run -d --name immich-pg --restart always \
    -e POSTGRES_USER=immich -e POSTGRES_PASSWORD=immich \
    -e POSTGRES_DB=immich \
    -v ~/homelab/data/immich/db:/var/lib/postgresql/data \
    --network traefik-net \
    tensorchord/pgvecto-rs:pg14-v0.2.0 > /dev/null 2>&1
sleep 3
docker run -d --name immich-server --restart always \
    -p 2283:3001 \
    -e DB_HOSTNAME=immich-pg -e DB_USERNAME=immich \
    -e DB_PASSWORD=immich -e DB_DATABASE_NAME=immich \
    -e REDIS_HOSTNAME=immich-redis \
    -v ~/homelab/data/immich/upload:/usr/src/app/upload \
    -v ~/homelab/data/immich/library:/usr/src/app/library \
    --network traefik-net \
    ghcr.io/immich-app/immich-server:release > /dev/null 2>&1
docker run -d --name immich-redis --restart always \
    --network traefik-net \
    redis:7-alpine > /dev/null 2>&1

# --- FileBrowser ⭐27k — File manager web ---
log "  → FileBrowser"
docker run -d --name filebrowser --restart always \
    -p 8081:80 \
    -v /:/srv \
    -v ~/homelab/data/filebrowser:/database \
    filebrowser/filebrowser:latest > /dev/null 2>&1

# --- Watchtower ⭐20k — Auto-update ---
log "  → Watchtower"
docker run -d --name watchtower --restart always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower:latest \
    --cleanup --schedule "0 4 * * *" > /dev/null 2>&1

ok "All services deployed"

# ─────── STEP 8: Info ───────
log "${YELLOW}[8/8]${NC} Finalizing"

cat << 'EOF' >> ~/.bashrc 2>/dev/null || true
alias hl='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias hlog='docker logs -f'
alias hup='cd ~/homelab && docker compose up -d'
alias hdown='cd ~/homelab && docker compose down'
EOF

echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   🎉 HOMELAB SIAP!                                  ${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
echo ""
echo -e " ${CYAN}Service${NC}           ${CYAN}Akses Lokal${NC}              ${CYAN}Domain${NC}"
echo -e " ─────────────────────────────────────────────────────"
echo -e " Portainer          https://$IP:9443              p.$DOMAIN"
echo -e " Traefik            http://$IP:8080/dashboard    *.$DOMAIN"
echo -e " Pi-hole            http://$IP:8053              dns.$DOMAIN"
echo -e " Glance             http://$IP:8085              start.$DOMAIN"
echo -e " Uptime Kuma        http://$IP:3001              status.$DOMAIN"
echo -e " Beszel             http://$IP:8086              monitor.$DOMAIN"
echo -e " Vaultwarden        http://$IP:8080              pass.$DOMAIN"
echo -e " N8N                http://$IP:5678              n8n.$DOMAIN"
echo -e " Immich (foto)      http://$IP:2283              foto.$DOMAIN"
echo -e " FileBrowser        http://$IP:8081              files.$DOMAIN"
echo ""
echo -e " ${YELLOW}🔥 Akses dari luar ${NC}"
echo -e " Setup Cloudflare Tunnel:"
echo -e "   ${CYAN}cloudflared tunnel login${NC}"
echo -e "   ${CYAN}cloudflared tunnel create homelab${NC}"
echo -e "   ${CYAN}cloudflared tunnel route dns homelab *.ishol.my.id${NC}"
echo ""
echo -e " ${YELLOW}🛡️  Keamanan:${NC}"
echo -e "   CrowdSec aktif — cek: ${CYAN}cscli alerts list${NC}"
echo -e "   Ubah password Pi-hole: ${CYAN}docker exec -it pihole pihole -a -p${NC}"
echo ""
