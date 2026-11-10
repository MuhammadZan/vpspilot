#!/usr/bin/env bash
# ==============================================================================
# vps-pilot | 1-Line Standalone VPS Installer
# ==============================================================================
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}"
cat << "EOF"
  __   __ ___  ___        ___ _ _     _   
  \ \ / /| _ \/ __| ___  | _ (_) |___| |_ 
   \ V / |  _/\__ \|___| |  _/ | / _ \  _|
    \_/  |_|  |___/      |_| |_|_\___/\__|
  Lightweight       Self-Hosted       PaaS
EOF
echo -e "${NC}"

# 1. Verify Root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Please run this installer as root: sudo bash install.sh${NC}"
  exit 1
fi

echo -e "${GREEN}[1/5] Checking Host Architecture & Dependencies...${NC}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)
    GO_ARCH="amd64"
    ;;
  aarch64|arm64)
    GO_ARCH="arm64"
    ;;
  *)
    echo -e "${RED}[ERROR] Unsupported architecture: $ARCH${NC}"
    exit 1
    ;;
esac
echo "Detected architecture: $ARCH ($GO_ARCH)"

# 1.1 Ensure core tools (git, curl)
if ! command -v git &> /dev/null || ! command -v curl &> /dev/null; then
  echo -e "${YELLOW}[1/5] Installing core dependencies (git, curl)...${NC}"
  if command -v apt-get &> /dev/null; then
    apt-get update -y && apt-get install -y git curl
  elif command -v dnf &> /dev/null; then
    dnf install -y git curl
  elif command -v yum &> /dev/null; then
    yum install -y git curl
  fi
fi

# 2. Verify / Install Docker Engine
if ! command -v docker &> /dev/null; then
  echo -e "${YELLOW}[2/5] Docker not found. Installing Docker Engine...${NC}"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
else
  echo -e "${GREEN}[2/5] Docker is already installed.${NC}"
fi

# 2.1 Use Docker's classic image store. The containerd image store (the default on new
# installs) gzips every new layer when a build is saved, which takes many minutes for a
# large node_modules layer on a small VPS. Switching hides existing images and
# containers, so it is only done automatically while Docker has none.
if docker info 2>/dev/null | grep -q 'driver-type: io.containerd.snapshotter'; then
  if [ ! -s /etc/docker/daemon.json ] && [ -z "$(docker ps -aq 2>/dev/null)" ]; then
    mkdir -p /etc/docker
    echo '{ "features": { "containerd-snapshotter": false } }' > /etc/docker/daemon.json
    systemctl restart docker
    echo -e "${GREEN}[2/5] Docker switched to the classic image store (faster builds).${NC}"
  else
    echo -e "${YELLOW}Docker uses the containerd image store, which makes saving builds slow on small servers."
    echo -e "To switch: add \"features\": { \"containerd-snapshotter\": false } to /etc/docker/daemon.json,"
    echo -e "run 'systemctl restart docker', then redeploy your services (volumes are kept).${NC}"
  fi
fi

# 3. Verify / Install Caddy Reverse Proxy
if ! command -v caddy &> /dev/null; then
  echo -e "${YELLOW}[3/5] Caddy not found. Installing Caddy...${NC}"
  if command -v apt-get &> /dev/null; then
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update
    apt-get install -y caddy
  else
    # Binary direct download fallback
    curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${GO_ARCH}" -o /usr/local/bin/caddy
    chmod +x /usr/local/bin/caddy
  fi
  systemctl enable --now caddy
else
  echo -e "${GREEN}[3/5] Caddy is already installed.${NC}"
fi

# 4. Verify / Install Railpack (pinned) and its BuildKit frontend
RAILPACK_VERSION="0.43.0"
if ! command -v railpack &> /dev/null || ! railpack --version 2>/dev/null | grep -qF "${RAILPACK_VERSION}"; then
  echo -e "${YELLOW}[4/5] Installing Railpack ${RAILPACK_VERSION} build engine...${NC}"
  curl -sSL https://railpack.com/install.sh | RAILPACK_VERSION="${RAILPACK_VERSION}" sh || true
  if ! command -v railpack &> /dev/null || ! railpack --version 2>/dev/null | grep -qF "${RAILPACK_VERSION}"; then
    echo -e "${RED}Railpack ${RAILPACK_VERSION} install failed. Install manually: curl -sSL https://railpack.com/install.sh | RAILPACK_VERSION=${RAILPACK_VERSION} sh${NC}"
  fi
else
  echo -e "${GREEN}[4/5] Railpack ${RAILPACK_VERSION} is already installed.${NC}"
fi
docker pull "ghcr.io/railwayapp/railpack-frontend:v${RAILPACK_VERSION}" || \
  echo -e "${YELLOW}Could not pre-pull the Railpack frontend image; it will be pulled on the first build.${NC}"
if ! docker buildx version &> /dev/null; then
  echo -e "${RED}Docker buildx is missing; Railpack builds will fail. Fix: apt-get install -y docker-buildx-plugin${NC}"
fi

# 5. Configure Systemd Service for vps-pilot
echo -e "${GREEN}[5/5] Configuring systemd service...${NC}"
mkdir -p /var/lib/vps-pilot
mkdir -p /usr/local/bin

# Locate and install vps-pilot binary
if [ -f "/usr/local/bin/vps-pilot" ]; then
  echo -e "${GREEN}Found existing /usr/local/bin/vps-pilot${NC}"
elif [ -f "./bin/vps-pilot-linux-${GO_ARCH}" ]; then
  cp "./bin/vps-pilot-linux-${GO_ARCH}" /usr/local/bin/vps-pilot
elif [ -f "./vps-pilot-linux-${GO_ARCH}" ]; then
  cp "./vps-pilot-linux-${GO_ARCH}" /usr/local/bin/vps-pilot
elif [ -f "./bin/vps-pilot" ]; then
  cp "./bin/vps-pilot" /usr/local/bin/vps-pilot
elif [ -f "./vps-pilot" ]; then
  cp "./vps-pilot" /usr/local/bin/vps-pilot
elif [ -f "/tmp/vps-pilot" ]; then
  cp "/tmp/vps-pilot" /usr/local/bin/vps-pilot
else
  # No local binary: download the release build for this architecture.
  # Set VPS_PILOT_VERSION (e.g. v0.2.0) to pin a release instead of the latest.
  BIN_NAME="vps-pilot-linux-${GO_ARCH}"
  DOWNLOAD_BASE="https://vpspilot.online/download/${VPS_PILOT_VERSION:-latest}"
  if ! command -v sha256sum &> /dev/null; then
    echo -e "${RED}[ERROR] sha256sum is required to verify the download but was not found. Install coreutils (e.g. apt-get install -y coreutils) and run the installer again.${NC}"
    exit 1
  fi
  # The binary is staged next to its final path (same filesystem), so the move
  # into place is an atomic rename; only the checksums go to a temp dir.
  STAGED=/usr/local/bin/vps-pilot.tmp
  DL_DIR=$(mktemp -d)
  cleanup_download() { rm -f "$STAGED"; rm -rf "$DL_DIR"; }
  # Also covers an unexpected exit (set -e) between here and the move.
  trap cleanup_download EXIT
  echo "Downloading vps-pilot from ${DOWNLOAD_BASE}/${BIN_NAME}"
  if ! curl -fsSL --retry 3 "${DOWNLOAD_BASE}/${BIN_NAME}" -o "$STAGED" ||
     ! curl -fsSL --retry 3 "${DOWNLOAD_BASE}/checksums.txt" -o "${DL_DIR}/checksums.txt"; then
    cleanup_download
    echo -e "${RED}[ERROR] Could not download the vps-pilot binary or its checksums from ${DOWNLOAD_BASE}. Check your connection (and VPS_PILOT_VERSION if set), or copy the binary to /usr/local/bin/vps-pilot.${NC}"
    exit 1
  fi
  # Verify against the line for this file only; a missing line is an error too.
  EXPECTED_LINE=$(grep -E "[[:space:]]\*?${BIN_NAME}\$" "${DL_DIR}/checksums.txt" | head -n 1 || true)
  EXPECTED_SUM=$(echo "$EXPECTED_LINE" | awk '{print tolower($1)}')
  if [ -z "$EXPECTED_LINE" ] || ! echo "$EXPECTED_SUM" | grep -qE '^[0-9a-f]{64}$'; then
    cleanup_download
    echo -e "${RED}[ERROR] checksums.txt has no valid entry for ${BIN_NAME}. Refusing to install an unverified binary.${NC}"
    exit 1
  fi
  ACTUAL_SUM=$(sha256sum "$STAGED" | awk '{print tolower($1)}')
  if [ "$ACTUAL_SUM" != "$EXPECTED_SUM" ]; then
    cleanup_download
    echo -e "${RED}[ERROR] Checksum mismatch for ${BIN_NAME}. The download is corrupt or has been tampered with; nothing was installed.${NC}"
    exit 1
  fi
  echo -e "${GREEN}Checksum verified.${NC}"
  chmod +x "$STAGED"
  mv -f "$STAGED" /usr/local/bin/vps-pilot
  trap - EXIT
  rm -rf "$DL_DIR"
fi
chmod +x /usr/local/bin/vps-pilot

cat << 'EOF' > /etc/systemd/system/vps-pilot.service
[Unit]
Description=vps-pilot Standalone PaaS Daemon
After=network.target docker.service caddy.service
Wants=docker.service caddy.service

[Service]
Type=simple
User=root
WorkingDirectory=/var/lib/vps-pilot
ExecStart=/usr/local/bin/vps-pilot --port 8080 --data-dir /var/lib/vps-pilot
Restart=always
RestartSec=3s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vps-pilot

# Fetch public IP
PUBLIC_IP=$(curl -s https://api.ipify.org || echo "YOUR-SERVER-IP")

# The panel's automatic HTTPS address (empty if a panel domain is set). The first
# start creates the database, so retry briefly.
PANEL_URL=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  PANEL_URL=$(/usr/local/bin/vps-pilot panel-url 2>/dev/null || true)
  [ -n "$PANEL_URL" ] && break
  sleep 1
done

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  vps-pilot installed and running successfully!${NC}"
echo -e "${GREEN}================================================================${NC}"
if [ -n "$PANEL_URL" ]; then
  echo -e "Dashboard URL: ${BLUE}${PANEL_URL}${NC}  (HTTPS; first visit may take a minute while the certificate is issued)"
  echo -e "Direct access: ${BLUE}http://${PUBLIC_IP}:8080${NC}"
else
  echo -e "Dashboard URL: ${BLUE}http://${PUBLIC_IP}:8080${NC}"
fi
echo -e "Data Directory: ${YELLOW}/var/lib/vps-pilot${NC}"
echo -e "Check Logs    : journalctl -u vps-pilot -f"
echo -e "Reset Admin   : vps-pilot update admin  (new email/password, run as root)"
echo ""
