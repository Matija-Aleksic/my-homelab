#!/bin/bash
REPO_DIR="/root/homelab-git"
LOG_FILE="/var/log/homelab-backup.log"
exec > >(tee -i "$LOG_FILE") 2>&1
echo "=== Backup started: $(date +'%Y-%m-%d %H:%M:%S') ==="

cd "$REPO_DIR" || { echo "Directory $REPO_DIR not found!"; exit 1; }
git pull origin main

echo "Pulling fresh configurations from LXCs..."

echo "Syncing LXC 102 (Network) configs..."
pct pull 102 /root/adguard/docker-compose.yml "$REPO_DIR/lxc-network/adguard/docker-compose.yml"
pct pull 102 /etc/unbound/unbound.conf "$REPO_DIR/lxc-network/unbound/unbound.conf"
pct pull 102 /root/cloudflare/docker-compose.yml "$REPO_DIR/lxc-network/cloudflare/docker-compose.yml"
pct pull 102 /root/tailscale/docker-compose.yml "$REPO_DIR/lxc-network/tailscale/docker-compose.yml"
pct pull 102 /root/wyl/docker-compose.yml "$REPO_DIR/lxc-network/wyl/docker-compose.yml"
pct pull 102 /root/watchtower/docker-compose.yml "$REPO_DIR/lxc-network/watchtower/docker-compose.yml"
pct pull 102 /root/portainer/docker-compose.yml "$REPO_DIR/lxc-network/portainer/docker-compose.yml"

echo "Syncing LXC 100 (Apps) configs..."
pct pull 100 /opt/apps/traefik/docker-compose.yml "$REPO_DIR/lxc-apps/traefik/docker-compose.yml"
pct pull 100 /opt/apps/traefik/traefik.yml "$REPO_DIR/lxc-apps/traefik/traefik.yml"
pct pull 100 /opt/apps/immich/docker-compose.yml "$REPO_DIR/lxc-apps/immich/docker-compose.yml"
pct pull 100 /opt/apps/paperless/docker-compose.yml "$REPO_DIR/lxc-apps/paperless/docker-compose.yml"
pct pull 100 /opt/mediastack/docker-compose.yml "$REPO_DIR/lxc-apps/mediastack/docker-compose.yml"
pct pull 100 /opt/apps/sparkyfitness/docker-compose.yml "$REPO_DIR/lxc-apps/sparkyfitness/docker-compose.yml"
pct pull 100 /opt/apps/uptimeKuma/docker-compose.yml "$REPO_DIR/lxc-apps/uptimeKuma/docker-compose.yml"
pct pull 100 /opt/apps/portainer/docker-compose.yml "$REPO_DIR/lxc-apps/portainer/docker-compose.yml"
pct pull 100 /opt/apps/watchtower/docker-compose.yml "$REPO_DIR/lxc-apps/watchtower/docker-compose.yml"

echo "Syncing LXC 104 (LLM) configs..."
pct pull 104 /root/odysseus/docker-compose.yml "$REPO_DIR/lxc-llm/docker-compose.yml"

echo "Scanning for leaked secrets..."
if ! gitleaks detect --source "$REPO_DIR" --no-git -v; then
    echo "Gitleaks detected a potential secret! Aborting commit and push."
    exit 1
fi

git add .

if [ -n "$(git status --porcelain)" ]; then
    echo "Changes detected! Committing and pushing..."
    git commit -m "auto: homelab config backup $(date +'%Y-%m-%d %H:%M')"
    git push origin main
    echo "Push complete."
else
    echo "No configuration changes detected. Working tree is clean."
fi

echo "=== Backup completed: $(date +'%Y-%m-%d %H:%M:%S') ==="
