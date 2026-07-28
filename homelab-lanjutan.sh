#!/bin/bash
# ─────────────────────────────────────────────────────────────
# HOMELAB SETUP — Lanjutan dari Step 8 (Docker sudah OK)
# ─────────────────────────────────────────────────────────────
# Jalankan:
#   curl -fsSLk https://raw.githubusercontent.com/emptyz/profile/main/homelab-lanjutan.sh | sudo bash
# ─────────────────────────────────────────────────────────────

DOMAIN="${DOMAIN:-ishol.my.id}"
USER="${SUDO_USER:-${USER:-faishol}}"

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
ok()   { echo -e "  ${GREEN}✅${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠️${NC} $1"; }

IP=$(hostname -I | awk '{print $1}')
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"
echo -e "${CYAN}   HOMELAB LANJUTAN — Step 8 sd 13              ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════${NC}"

# ─────────── STEP 8: CrowdSec ───────────
log "${YELLOW}[8/13]${NC} CrowdSec — IPS modern"
curl -s https://install.crowdsec.net | sudo bash > /dev/null 2>&1
apt install -y crowdsec > /dev/null 2>&1 || true
cscli collections install crowdsecurity/linux crowdsecurity/nginx crowdsecurity/ssh crowdsecurity/http-cve > /dev/null 2>&1
systemctl enable crowdsec > /dev/null 2>&1
systemctl restart crowdsec
cscli dashboard setup --listen 127.0.0.1:8088 --password "crowdsecadmin123" > /dev/null 2>&1 || true
ok "CrowdSec active + dashboard :8088"

# ─────────── STEP 9: Firewall ───────────
log "${YELLOW}[9/13]${NC} Firewall UFW"
ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow ssh > /dev/null
ufw allow 80/tcp > /dev/null
ufw allow 443/tcp > /dev/null
ufw allow 81/tcp > /dev/null
ufw allow 8080/tcp > /dev/null
ufw allow 9090/tcp > /dev/null
ufw allow 9443/tcp > /dev/null
ufw --force enable > /dev/null
ok "Firewall active"

# ─────────── STEP 10: Cockpit ───────────
log "${YELLOW}[10/13]${NC} Cockpit — Dashboard server"
apt install -y -qq cockpit > /dev/null 2>&1
systemctl enable cockpit.socket > /dev/null 2>&1
systemctl start cockpit.socket
ufw allow 9090/tcp > /dev/null 2>&1
ok "Cockpit → https://$IP:9090"

# ─────────── STEP 11: Direktori ───────────
log "${YELLOW}[11/13]${NC} Directory structure"
mkdir -p ~/homelab/{services,data,backup,mount}
chown -R "$USER:$USER" ~/homelab 2>/dev/null || true
ok "~/homelab/ ready"

# ─────────── STEP 12: Docker Services ───────────
log "${YELLOW}[12/13]${NC} Deploying 17 Docker services..."

# Network
docker network create traefik-net > /dev/null 2>&1 || true

deploy() {
    local name="$1" msg="$2" cmd="$3"
    log "  → $msg"
    eval "$cmd" > /dev/null 2>&1
}

# --- 1. Portainer ---
deploy "portainer" "Portainer" \
'docker volume create portainer_data; docker run -d --name portainer --restart always -p 9443:9443 -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest'

# --- 2. Traefik ---
deploy "traefik" "Traefik" \
'mkdir -p ~/homelab/data/traefik
cat << "EOF" > ~/homelab/data/traefik/traefik.yml
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
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@'$DOMAIN'
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web
log:
  level: INFO
EOF
touch ~/homelab/data/traefik/acme.json; chmod 600 ~/homelab/data/traefik/acme.json
docker run -d --name traefik --restart always -p 80:80 -p 443:443 -p 8082:8080 -v ~/homelab/data/traefik:/etc/traefik -v /var/run/docker.sock:/var/run/docker.sock --network traefik-net traefik:latest'

# --- 3. Glance ---
deploy "glance" "Glance Dashboard" \
'mkdir -p ~/homelab/data/glance
cat << "EOF" > ~/homelab/data/glance/glance.yml
pages:
  - name: Homelab
    columns: 3
    components:
      - type: bookmarks
        groups:
          - name: Services
            links:
              - text: Portainer
                url: https://p.'$DOMAIN'
              - text: Uptime Kuma
                url: https://status.'$DOMAIN'
              - text: N8N
                url: https://n8n.'$DOMAIN'
              - text: Immich
                url: https://foto.'$DOMAIN'
              - text: Vaultwarden
                url: https://pass.'$DOMAIN'
              - text: Traefik
                url: https://traefik.'$DOMAIN'
      - type: weather
      - type: uptime
EOF
docker run -d --name glance --restart always -p 8085:8080 -v ~/homelab/data/glance:/app/config --network traefik-net glanceapp/glance:latest'

# --- 4. AdGuard ---
deploy "adguard" "AdGuard Home" \
'systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
cat << "EOF" > /etc/systemd/resolved.conf
[Resolve]
DNS=1.1.1.1
DNSStubListener=no
EOF
systemctl restart systemd-resolved 2>/dev/null || true
mkdir -p /mnt/data/adguard/work 2>/dev/null || mkdir -p ~/homelab/data/adguard
docker run -d --name adguard --restart always -p 53:53/tcp -p 53:53/udp -p 8053:80 -p 3000:3000 -v /mnt/data/adguard/work:/opt/adguardhome/work --network traefik-net adguard/adguardhome:latest'

# --- 5. Uptime Kuma ---
deploy "uptime-kuma" "Uptime Kuma" \
'docker run -d --name uptime-kuma --restart always -p 3001:3001 -v ~/homelab/data/uptime-kuma:/app/data louislam/uptime-kuma:latest'

# --- 6. Beszel ---
deploy "beszel" "Beszel Monitoring" \
'docker run -d --name beszel --restart always -p 8086:8090 -v ~/homelab/data/beszel:/opt/beszel/data henrygd/beszel:latest'

# --- 7. Vaultwarden ---
deploy "vaultwarden" "Vaultwarden" \
'docker run -d --name vaultwarden --restart always -p 8080:80 -e SIGNUPS_ALLOWED=false -e ADMIN_TOKEN=$(openssl rand -base64 32) -v ~/homelab/data/vaultwarden:/data vaultwarden/server:latest'

# --- 8. N8N ---
deploy "n8n" "N8N" \
'docker run -d --name n8n --restart always -p 5678:5678 -e N8N_SECURE_COOKIE=false -e DB_TYPE=sqlite -v ~/homelab/data/n8n:/home/node/.n8n --network traefik-net n8nio/n8n:latest'

# --- 9. Stirling PDF ---
deploy "stirling-pdf" "Stirling PDF" \
'docker run -d --name stirling-pdf --restart always -p 8083:8080 -v ~/homelab/data/stirling-pdf:/usr/share/tesseract-ocr/4.00/tessdata -e DOCKER_ENABLE_SECURITY=false --network traefik-net frooodle/s-pdf:latest'

# --- 10. ntfy ---
deploy "ntfy" "ntfy Push Notif" \
'mkdir -p ~/homelab/data/ntfy
cat << "EOF" > ~/homelab/data/ntfy/server.yml
base-url: https://notif.'$DOMAIN'
cache-file: /var/lib/ntfy/cache.db
behind-proxy: true
EOF
docker run -d --name ntfy --restart always -p 8084:80 -v ~/homelab/data/ntfy/server.yml:/etc/ntfy/server.yml -v ~/homelab/data/ntfy/cache:/var/lib/ntfy --network traefik-net binwiederhier/ntfy:latest'

# --- 11. Gitea ---
deploy "gitea" "Gitea" \
'mkdir -p ~/homelab/data/gitea
docker run -d --name gitea --restart always -p 3002:3000 -v ~/homelab/data/gitea:/data --network traefik-net gitea/gitea:latest'

# --- 12. Vikunja ---
deploy "vikunja" "Vikunja" \
'mkdir -p ~/homelab/data/vikunja
docker run -d --name vikunja --restart always -p 8087:80 -v ~/homelab/data/vikunja:/app/vikunja/files --network traefik-net vikunja/vikunja:latest'

# --- 13. FileBrowser ---
deploy "filebrowser" "FileBrowser" \
'docker run -d --name filebrowser --restart always -p 8081:80 -v /:/srv:ro -v ~/homelab/data/filebrowser:/database filebrowser/filebrowser:latest'

# --- 14. Watchtower ---
deploy "watchtower" "Watchtower" \
'docker run -d --name watchtower --restart always -v /var/run/docker.sock:/var/run/docker.sock containrrr/watchtower:latest --cleanup --schedule "0 4 * * *"'

ok "All services deployed"

# ─────────── Health Check ───────────
log "${YELLOW}Health Check${NC}"
SERVICES="portainer traefik uptime-kuma vaultwarden n8n filebrowser adguard glance beszel watchtower stirling-pdf ntfy gitea vikunja"
FAILED=""
for s in $SERVICES; do
    if docker ps --format '{{.Names}}' | grep -q "^$s$"; then
        ok "$s ✅"
    else
        warn "$s ❌"
        FAILED="$FAILED $s"
    fi
done
[ -n "$FAILED" ] && warn "Gagal: $FAILED — cek: docker logs <nama>"

# ─────────── STEP 13: Cleanup ───────────
log "${YELLOW}[13/13]${NC} Cleanup"
apt autoremove -y -qq > /dev/null 2>&1
apt autoclean -qq > /dev/null 2>&1
docker system prune -af --filter "until=24h" --volumes=false > /dev/null 2>&1 || true

cat << 'EOF' > /etc/cron.weekly/docker-cleanup
#!/bin/bash
docker system prune -af --filter "until=168h" --volumes=false > /dev/null 2>&1
EOF
chmod +x /etc/cron.weekly/docker-cleanup

cat << 'EOF' >> /home/$USER/.bashrc 2>/dev/null || true
alias hl='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias hlog='docker logs -f'
alias hdf='df -h | grep -E "Filesystem|/dev/|/mnt/"'
EOF

ok "Cleanup done. Rekomendasi: sudo reboot"

# ─── OUTPUT ───
clear
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   🎉 HOMELAB LANJUTAN SELESAI!                      ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e " Cockpit (server)    https://$IP:9090"
echo -e " Portainer           https://$IP:9443"
echo -e " AdGuard Home        http://$IP:8053 (setup: :3000)"
echo -e " Glance              http://$IP:8085"
echo -e " Uptime Kuma         http://$IP:3001"
echo -e " Beszel              http://$IP:8086"
echo -e " Vaultwarden         http://$IP:8080"
echo -e " N8N                 http://$IP:5678"
echo -e " Stirling PDF        http://$IP:8083"
echo -e " ntfy                http://$IP:8084"
echo -e " Gitea               http://$IP:3002"
echo -e " Vikunja             http://$IP:8087"
echo -e " FileBrowser         http://$IP:8081"
echo -e " Traefik Dashboard   http://$IP:8082"
echo ""
echo -e " ${YELLOW}Langkah setelah ini:${NC}"
echo -e " 1. sudo reboot (biar semua stabil)"
echo -e " 2. Buka AdGuard: http://$IP:3000 → setup wizard"
echo -e " 3. Buka Portainer: https://$IP:9443 → set password"
echo -e " 4. Ganti password CrowdSec: cscli dashboard setup --password ..."
echo -e " 5. Setup Cloudflare Tunnel untuk akses domain"
echo ""
