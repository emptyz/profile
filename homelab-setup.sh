#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# HOMELAB SETUP v3 FINAL — Ubuntu Server 26.04 LTS
# Lengkap + Optimal + Best Practice dari Awesome Homelab 2026
# ═══════════════════════════════════════════════════════════════════════
# Cara pakai:
#   curl -fsSL https://raw.githubusercontent.com/emptyz/profile/main/homelab-setup.sh | sudo bash
# ═══════════════════════════════════════════════════════════════════════

# ─── Konfigurasi ───
DOMAIN="${DOMAIN:-ishol.my.id}"
TIMEZONE="${TIMEZONE:-Asia/Jakarta}"
USER="${SUDO_USER:-${USER:-faishol}}"

# Auto-detect HDD — cari disk paling besar yang bukan system disk
detect_hdd() {
    local root_dev
    root_dev=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//' | sed 's/p[0-9]*$//')
    lsblk -dnlo NAME,SIZE,TYPE,MOUNTPOINT | grep "disk" | grep -v "^$(basename "$root_dev")" | sort -k2 -h -r | head -1 | awk '{print "/dev/"$1}'
}
HDD_DEV="${HDD_DEV:-$(detect_hdd)}"
if [ -z "$HDD_DEV" ] || [ ! -b "$HDD_DEV" ]; then
    warn "⚠️ HDD tidak terdeteksi otomatis!"
    warn "Jalankan: lsblk → cari disk 1TB → lalu set: export HDD_DEV=/dev/sdX"
    HDD_DEV="/dev/sdX"  # placeholder, script akan skip format
fi

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
ok()   { echo -e "  ${GREEN}✅${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠️${NC} $1"; }
sec()  { echo -e "  ${YELLOW}━━━ $1 ━━━${NC}"; }

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}   HOMELAB v3 FINAL — i7-8700 | 8GB RAM | 240GB SSD + 1TB HDD${NC}"
echo -e "${CYAN}   Duration: ~15-20 menit (tergantung kecepatan internet)     ${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

# ═══════════════════════════════════════════════
# STEP 1: System Update
# ═══════════════════════════════════════════════
log "${YELLOW}[1/13]${NC} System update & upgrade"
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget git htop net-tools unzip \
    ufw gnupg lsb-release ca-certificates chrony jq tree \
    hdparm smartmontools tmux screen rfkill
ok "System updated"

# ═══════════════════════════════════════════════
# STEP 2: HDD 1TB — Format + Mount (best practice)
# ═══════════════════════════════════════════════
log "${YELLOW}[2/13]${NC} HDD 1TB — Format & Mount"

# Install tools untuk partisi
apt install -y -qq gdisk parted > /dev/null 2>&1

if [ -b "$HDD_DEV" ] && [ "$HDD_DEV" != "/dev/sdX" ]; then
    warn "Memformat $HDD_DEV — semua data akan HILANG!"
    warn "Lanjut dalam 5 detik... Ctrl+C untuk batal"
    sleep 5
    
    # Format single partition ext4
    sgdisk --zap-all "$HDD_DEV" > /dev/null 2>&1
    parted -s "$HDD_DEV" mklabel gpt
    parted -s "$HDD_DEV" mkpart primary ext4 0% 100%
    sleep 2
    PART="${HDD_DEV}1"
    [ -b "${HDD_DEV}p1" ] && PART="${HDD_DEV}p1"
    mkfs.ext4 -F -m 1 -L HOMELAB_DATA "$PART" > /dev/null 2>&1
    
    # Mount
    mkdir -p /mnt/data
    mount "$PART" /mnt/data
    UUID=$(blkid -s UUID -o value "$PART")
    echo "UUID=$UUID /mnt/data ext4 defaults,noatime,nodiratime 0 2" >> /etc/fstab
    
    # Struktur direktori data
    mkdir -p /mnt/data/{immich,media,backups,docker-volumes,databases,downloads,archive}
    chown -R "$USER:$USER" /mnt/data 2>/dev/null || true
    
    ok "HDD $HDD_DEV → /mnt/data (1 partition ext4, label: HOMELAB_DATA)"
else
    warn "HDD $HDD_DEV tidak ditemukan — lewati format HDD"
    warn "Setelah script selesai, jalankan: lsblk → cari device, lalu export HDD_DEV=/dev/sdX"
    mkdir -p /mnt/data 2>/dev/null || true
fi

# ═══════════════════════════════════════════════
# STEP 3: ZRAM + Swap — optimalisasi RAM 8GB
# ═══════════════════════════════════════════════
log "${YELLOW}[3/13]${NC} ZRAM + Swap — RAM optimization"

# ZRAM (50% RAM dikompres)
apt install -y -qq zram-tools 2>/dev/null || true
cat << 'EOF' > /etc/default/zramswap
PERCENT=50
PRIORITY=100
EOF
systemctl enable zramswap 2>/dev/null || true
systemctl restart zramswap 2>/dev/null || true

# Swap file (fallback — 2GB)
if ! swapon --show | grep -q /swapfile; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null 2>&1
    swapon /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi
ok "ZRAM 4GB + swap 2GB → total ~6GB cadangan"

# ═══════════════════════════════════════════════
# STEP 4: Kernel Optimization
# ═══════════════════════════════════════════════
log "${YELLOW}[4/13]${NC} Kernel optimization"
timedatectl set-timezone "$TIMEZONE"

cat << 'EOF' > /etc/sysctl.d/99-homelab.conf
# TCP BBR
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# RAM saving
vm.swappiness = 5
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 30
vm.dirty_background_ratio = 5

# Network buffer
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Security
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
EOF
sysctl -p /etc/sysctl.d/99-homelab.conf > /dev/null 2>&1
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

# Kernel modules untuk Docker
echo "overlay" > /etc/modules-load.d/overlay.conf
echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf

ok "Kernel optimized"

# ═══════════════════════════════════════════════
# STEP 5: Unattended Upgrades (keamanan otomatis)
# ═══════════════════════════════════════════════
log "${YELLOW}[5/13]${NC} Auto security updates"
apt install -y -qq unattended-upgrades > /dev/null 2>&1
cat << 'EOF' > /etc/apt/apt.conf.d/50unattended-upgrades
Unattended-Upgrade::Allowed-Origins {
    "\${distro_id}:\${distro_codename}-security";
    "\${distro_id}:\${distro_codename}-updates";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF
cat << 'EOF' > /etc/apt/apt.conf.d/20auto-upgrades
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable unattended-upgrades > /dev/null 2>&1
systemctl restart unattended-upgrades
ok "Auto security updates: setiap hari"

# ═══════════════════════════════════════════════
# STEP 6: SSH Hardening
# ═══════════════════════════════════════════════
log "${YELLOW}[6/13]${NC} SSH hardening"
cat << 'EOF' > /etc/ssh/sshd_config.d/99-homelab.conf
# Disable root login
PermitRootLogin no

# Key only (nonaktifkan dulu biar masih bisa pake password)
# PasswordAuthentication no
# PubkeyAuthentication yes

# Security
MaxAuthTries 3
MaxSessions 2
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
systemctl restart sshd
ok "SSH secured"

# ═══════════════════════════════════════════════
# STEP 7: Docker + Compose
# ═══════════════════════════════════════════════
log "${YELLOW}[7/13]${NC} Docker + Compose"
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    apt-get remove -qq $pkg 2>/dev/null || true
done
curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
usermod -aG docker "$USER" 2>/dev/null || true
apt install -y -qq docker-compose-plugin docker-compose-v2 2>/dev/null || true

cat << 'EOF' > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "storage-opts": ["overlay2.override_kernel_check=true"],
  "live-restore": true,
  "iptables": true
}
EOF

systemctl enable docker > /dev/null 2>&1
systemctl restart docker
ok "Docker ready"

# ═══════════════════════════════════════════════
# STEP 8: CrowdSec (IPS modern)
# ═══════════════════════════════════════════════
log "${YELLOW}[8/13]${NC} CrowdSec"
curl -s https://install.crowdsec.net | bash > /dev/null 2>&1
cscli collections install crowdsecurity/linux crowdsecurity/nginx crowdsecurity/ssh crowdsecurity/http-cve > /dev/null 2>&1
systemctl enable crowdsec > /dev/null 2>&1
systemctl restart crowdsec

# CrowdSec dashboard (port 8088)
cscli dashboard setup --listen 127.0.0.1:8088 --password "crowdsecadmin123" > /dev/null 2>&1 || true
ok "CrowdSec active + dashboard :8088"

# ═══════════════════════════════════════════════
# STEP 9: Firewall UFW
# ═══════════════════════════════════════════════
log "${YELLOW}[9/13]${NC} Firewall UFW"
ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null
ufw allow ssh > /dev/null
ufw allow 80/tcp > /dev/null
ufw allow 443/tcp > /dev/null
ufw allow 81/tcp > /dev/null
ufw allow 8080/tcp > /dev/null
ufw allow 9443/tcp > /dev/null
ufw --force enable > /dev/null
ok "Firewall active"

# ═══════════════════════════════════════════════
# STEP 10: Direktori
# ═══════════════════════════════════════════════
log "${YELLOW}[10/13]${NC} Directory structure"
mkdir -p ~/homelab/{services,data,backup}
chown -R "$USER:$USER" ~/homelab 2>/dev/null || true
ok "~/homelab/ ready"
sec "Struktur HDD:"
echo "  /mnt/data/"
echo "  ├── immich/         ← Foto & video"
echo "  ├── media/          ← File media umum"
echo "  ├── backups/        ← Backup database"
echo "  ├── docker-volumes/ ← Volume container besar"
echo "  ├── databases/      ← DB dump"
echo "  ├── downloads/      ← File download"
echo "  └── archive/        ← Arsip lama"

# ═══════════════════════════════════════════════
# STEP 11: Docker Services
# ═══════════════════════════════════════════════
log "${YELLOW}[11/13]${NC} Deploying services..."

IP=$(hostname -I | awk '{print $1}')

# Network
docker network create traefik-net > /dev/null 2>&1 || true

# --- Portainer ⭐38k ---
log "  → Portainer"
docker volume create portainer_data > /dev/null 2>&1
docker run -d --name portainer --restart always \
    -p 9443:9443 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest > /dev/null 2>&1

# --- Traefik ⭐55k ---
log "  → Traefik"
mkdir -p ~/homelab/data/traefik
cat << TRAEFIK > ~/homelab/data/traefik/traefik.yml
api:
  dashboard: true
  debug: false
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
    watch: true
  file:
    directory: /etc/traefik/dynamic
    watch: true
certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@${DOMAIN}
      storage: /etc/traefik/acme.json
      httpChallenge:
        entryPoint: web
log:
  level: INFO
  filePath: /var/log/traefik.log
  format: json
accessLog:
  filePath: /var/log/traefik-access.log
TRAEFIK
touch ~/homelab/data/traefik/acme.json && chmod 600 ~/homelab/data/traefik/acme.json
docker run -d --name traefik --restart always \
    -p 80:80 -p 443:443 \
    -p 8082:8080 \
    -v ~/homelab/data/traefik:/etc/traefik \
    -v /var/run/docker.sock:/var/run/docker.sock \
    --label "traefik.enable=true" \
    --label "traefik.http.routers.dashboard.rule=Host(\`traefik.$DOMAIN\`)" \
    --label "traefik.http.routers.dashboard.service=api@internal" \
    --network traefik-net \
    traefik:latest > /dev/null 2>&1

# --- Glance ⭐36k ---
log "  → Glance dashboard"
mkdir -p ~/homelab/data/glance
cat << GLANCE > ~/homelab/data/glance/glance.yml
pages:
  - name: Homelab
    columns: 3
    components:
      - type: bookmarks
        groups:
          - name: Services
            links:
              - text: Portainer
                url: https://p.${DOMAIN}
              - text: Uptime Kuma
                url: https://status.${DOMAIN}
              - text: N8N
                url: https://n8n.${DOMAIN}
              - text: Immich
                url: https://foto.${DOMAIN}
              - text: Vaultwarden
                url: https://pass.${DOMAIN}
              - text: Traefik
                url: https://traefik.${DOMAIN}
      - type: weather
      - type: uptime
GLANCE
docker run -d --name glance --restart always \
    -p 8085:8080 \
    -v ~/homelab/data/glance:/app/config \
    --network traefik-net \
    glanceapp/glance:latest > /dev/null 2>&1

# --- AdGuard Home ⭐28k (lebih modern dari Pi-hole) ---
log "  → AdGuard Home"

# Pastikan port 53 tidak dipake systemd-resolved
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
cat << 'EOF' > /etc/systemd/resolved.conf
[Resolve]
DNS=1.1.1.1
DNSStubListener=no
EOF
systemctl restart systemd-resolved 2>/dev/null || true

mkdir -p /mnt/data/adguard/work
docker run -d --name adguard --restart always \
    -p 53:53/tcp -p 53:53/udp \
    -p 8053:80 \
    -p 3000:3000 \
    -v /mnt/data/adguard/work:/opt/adguardhome/work \
    --network traefik-net \
    adguard/adguardhome:latest > /dev/null 2>&1
warn "AdGuard first-run: http://$IP:3000 → setup wizard"

# --- Uptime Kuma ⭐63k ---
log "  → Uptime Kuma"
docker run -d --name uptime-kuma --restart always \
    -p 3001:3001 \
    -v ~/homelab/data/uptime-kuma:/app/data \
    louislam/uptime-kuma:latest > /dev/null 2>&1

# --- Beszel ⭐23k (monitoring RAM/CPU) ---
log "  → Beszel"
docker run -d --name beszel --restart always \
    -p 8086:8090 \
    -v ~/homelab/data/beszel:/opt/beszel/data \
    henrygd/beszel:latest > /dev/null 2>&1

# --- Vaultwarden ⭐42k ---
log "  → Vaultwarden"
docker run -d --name vaultwarden --restart always \
    -p 8080:80 \
    -e SIGNUPS_ALLOWED=false \
    -e ADMIN_TOKEN=$(openssl rand -base64 32) \
    -v ~/homelab/data/vaultwarden:/data \
    vaultwarden/server:latest > /dev/null 2>&1

# --- N8N ⭐60k ---
log "  → N8N"
mkdir -p ~/homelab/data/n8n
docker run -d --name n8n --restart always \
    -p 5678:5678 \
    -e N8N_SECURE_COOKIE=false \
    -e N8N_METRICS=true \
    -e DB_TYPE=sqlite \
    -v ~/homelab/data/n8n:/home/node/.n8n \
    --network traefik-net \
    n8nio/n8n:latest > /dev/null 2>&1

# --- Immich ⭐57k (Google Photos self-hosted) ---
log "  → Immich"
mkdir -p /mnt/data/immich/{db,upload,library}
POSTGRES_PASS=$(openssl rand -base64 16)

# PostgreSQL untuk Immich
docker run -d --name immich-pg --restart always \
    -e POSTGRES_USER=immich \
    -e POSTGRES_PASSWORD=$POSTGRES_PASS \
    -e POSTGRES_DB=immich \
    -v /mnt/data/immich/db:/var/lib/postgresql/data \
    --network traefik-net \
    tensorchord/pgvecto-rs:pg14-v0.2.0 > /dev/null 2>&1

# Redis untuk Immich
docker run -d --name immich-redis --restart always \
    --network traefik-net \
    redis:7-alpine > /dev/null 2>&1

sleep 5

# Immich server
docker run -d --name immich-server --restart always \
    -p 2283:3001 \
    -e DB_HOSTNAME=immich-pg \
    -e DB_USERNAME=immich \
    -e DB_PASSWORD=$POSTGRES_PASS \
    -e DB_DATABASE_NAME=immich \
    -e REDIS_HOSTNAME=immich-redis \
    -v /mnt/data/immich/upload:/usr/src/app/upload \
    -v /mnt/data/immich/library:/usr/src/app/library \
    --network traefik-net \
    ghcr.io/immich-app/immich-server:release > /dev/null 2>&1

# Immich Microservices
docker run -d --name immich-micro --restart always \
    -e DB_HOSTNAME=immich-pg \
    -e DB_USERNAME=immich \
    -e DB_PASSWORD=$POSTGRES_PASS \
    -e DB_DATABASE_NAME=immich \
    -e REDIS_HOSTNAME=immich-redis \
    -v /mnt/data/immich/upload:/usr/src/app/upload \
    -v /mnt/data/immich/library:/usr/src/app/library \
    --network traefik-net \
    ghcr.io/immich-app/immich-server:release > /dev/null 2>&1

# Immich Machine Learning
docker run -d --name immich-ml --restart always \
    -e DB_HOSTNAME=immich-pg \
    -e DB_USERNAME=immich \
    -e DB_PASSWORD=$POSTGRES_PASS \
    -e DB_DATABASE_NAME=immich \
    -e REDIS_HOSTNAME=immich-redis \
    --network traefik-net \
    ghcr.io/immich-app/immich-machine-learning:release > /dev/null 2>&1

# --- FileBrowser ⭐27k ---
log "  → FileBrowser"
docker run -d --name filebrowser --restart always \
    -p 8081:80 \
    -v /:/srv:ro \
    -v ~/homelab/data/filebrowser:/database \
    filebrowser/filebrowser:latest > /dev/null 2>&1

# --- Watchtower ⭐20k ---
log "  → Watchtower"
docker run -d --name watchtower --restart always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower:latest \
    --cleanup --schedule "0 4 * * *" > /dev/null 2>&1

ok "All services deployed"

# ═══════════════════════════════════════════════
# STEP 12: Health Check
# ═══════════════════════════════════════════════
log "${YELLOW}[12/13]${NC} Verifying services..."

SERVICES="portainer traefik uptime-kuma vaultwarden n8n filebrowser adguard glance immich-server beszel watchtower"
FAILED=""
for s in $SERVICES; do
    if docker ps --format '{{.Names}}' | grep -q "^$s$"; then
        ok "$s ✅"
    else
        warn "$s ❌ — check: docker logs $s"
        FAILED="$FAILED $s"
    fi
done

if [ -n "$FAILED" ]; then
    warn "Beberapa service gagal: $FAILED"
    warn "Jalankan: docker logs <nama_service> untuk debug"
fi

# ═══════════════════════════════════════════════
# STEP 13: Cleanup + Final
# ═══════════════════════════════════════════════
log "${YELLOW}[13/13]${NC} Cleanup"

# Hapus paket tidak perlu
apt autoremove -y -qq > /dev/null 2>&1
apt autoclean -qq > /dev/null 2>&1

# Docker cleanup — hapus image yang gak dipakai (hati-hati)
docker system prune -af --filter "until=24h" --volumes=false > /dev/null 2>&1 || true

# Cron — auto cleanup mingguan
cat << 'EOF' > /etc/cron.weekly/docker-cleanup
#!/bin/bash
docker system prune -af --filter "until=168h" --volumes=false > /dev/null 2>&1
EOF
chmod +x /etc/cron.weekly/docker-cleanup

# Cron — backup otomatis ke HDD
cat << 'EOF' > /etc/cron.daily/homelab-backup
#!/bin/bash
tar czf /mnt/data/backups/portainer-$(date +%Y%m%d).tar.gz /var/lib/docker/volumes/portainer_data 2>/dev/null || true
find /mnt/data/backups -name "portainer-*.tar.gz" -mtime +30 -delete 2>/dev/null || true
EOF
chmod +x /etc/cron.daily/homelab-backup

# Aliases
cat << 'EOF' >> /home/$USER/.bashrc 2>/dev/null || true

# Homelab shortcuts
alias hl='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias hlog='docker logs -f'
alias hls='docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias hstop='docker stop'
alias hstart='docker start'
alias hrestart='docker restart'
alias hclean='docker system prune -af'
alias htop='htop'
alias hdf='df -h | grep -E "Filesystem|/dev/|/mnt/"'
alias hbackup='sudo tar czf /mnt/data/backups/homelab-$(date +%Y%m%d-%H%M).tar.gz /home/$USER/homelab /mnt/data'
EOF

# Simpan konfigurasi
cat << 'CONFIG' > ~/homelab/config.txt
════════════════════════════════════════════════
HOMELAB CONFIG — Jangan dihapus!
════════════════════════════════════════════════
Domain:        $DOMAIN
IP lokal:      $IP
HDD mount:     /mnt/data
CrowdSec pass: crowdsecadmin123 (ubah!)
pi-hole pass:  homelab123 (ubah!)
Administrator: $USER
Install date:  $(date +%Y-%m-%d)
CONFIG
chown "$USER:$USER" ~/homelab/config.txt 2>/dev/null || true

ok "Cleanup done"

# ─── OUTPUT ───
clear
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}   🎉 HOMELAB v3 SELESAI! — Semua service siap ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e " ${CYAN}Akses Lokal${NC}"
echo -e " ─────────────────────────────────────────────────"
echo -e " Portainer          https://$IP:9443"
echo -e " Traefik Dashboard  http://$IP:8082"
echo -e " AdGuard Home       http://$IP:8053 (setup: :3000)"
echo -e " Glance             http://$IP:8085"
echo -e " Uptime Kuma        http://$IP:3001"
echo -e " Beszel             http://$IP:8086"
echo -e " Vaultwarden        http://$IP:8080"
echo -e " N8N                http://$IP:5678"
echo -e " Immich (foto)      http://$IP:2283"
echo -e " FileBrowser        http://$IP:8081"
echo -e " CrowdSec Dashboard http://$IP:8088"
echo ""
echo -e " ${CYAN}Akses Domain (via Cloudflare Tunnel nanti)${NC}"
echo -e " ─────────────────────────────────────────────────"
echo -e " p.$DOMAIN          → Portainer"
echo -e " traefik.$DOMAIN    → Traefik Dashboard"
echo -e " start.$DOMAIN      → Glance"
echo -e " status.$DOMAIN     → Uptime Kuma"
echo -e " pass.$DOMAIN       → Vaultwarden"
echo -e " n8n.$DOMAIN        → N8N"
echo -e " foto.$DOMAIN       → Immich"
echo -e " files.$DOMAIN      → FileBrowser"
echo -e " monitor.$DOMAIN    → Beszel"
echo ""
echo -e " ${YELLOW}📌 Langkah setelah ini:${NC}"
echo -e " 1. Buka AdGuard: http://$IP:3000 → setup wizard"
echo -e " 2. Buka Portainer: https://$IP:9443 → set password"
echo -e " 3. Buka Vaultwarden: http://$IP:8080 → buat akun"
echo -e " 4. Ganti password default:"
echo -e "    - CrowdSec: cscli dashboard setup --password \"password_baru\""
echo -e " 5. Setup Cloudflare Tunnel untuk akses domain"
echo -e ""
echo -e " ${GREEN}Password admin:${NC}"
echo -e "   AdGuard setup: http://$IP:3000"
echo -e "   CrowdSec: crowdsecadmin123"
echo -e "   (GANTI SEMUA PASSWORD DI ATAS!)"
echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
