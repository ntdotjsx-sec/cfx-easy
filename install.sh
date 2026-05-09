#!/bin/bash
# ============================================================
#  FiveM Server Auto-Installer for Ubuntu
#  Usage: bash <(curl -sSL https://raw.githubusercontent.com/YOUR/REPO/main/install.sh)
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
header() { echo -e "\n${CYAN}══════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════${NC}"; }

# ── Config ──────────────────────────────────────────────────
INSTALL_DIR="/home/fivem/FXServer"
SERVER_DIR="$INSTALL_DIR/server"
DATA_DIR="$INSTALL_DIR/server-data"
CHANGELOG_API="https://changelogs-live.fivem.net/api/changelog/versions/linux/server"
# ────────────────────────────────────────────────────────────

header "FiveM Server Installer"

# ── Root check ──────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Please run as root: sudo bash install.sh"
fi

# ── Dependencies ─────────────────────────────────────────────
header "Installing Dependencies"
apt-get update -qq
apt-get install -y -qq \
  curl wget git xz-utils \
  screen tar jq > /dev/null
log "Dependencies installed"

# ── Create fivem user ────────────────────────────────────────
header "Setting Up User & Directories"
if ! id "fivem" &>/dev/null; then
  useradd -m -s /bin/bash fivem
  log "User 'fivem' created"
else
  warn "User 'fivem' already exists"
fi
mkdir -p "$SERVER_DIR" "$DATA_DIR"
log "Directories created: $INSTALL_DIR"

# ── Resolve artifact download URL ────────────────────────────
header "Resolving Latest FiveM Artifacts"

# Allow override via environment variable
if [[ -n "$FIVEM_BUILD_URL" ]]; then
  DOWNLOAD_URL="$FIVEM_BUILD_URL"
  warn "Using manually set FIVEM_BUILD_URL: $DOWNLOAD_URL"
else
  warn "Fetching build info from changelog API..."
  CHANGELOG_JSON=$(curl -sSL --max-time 15 "$CHANGELOG_API" 2>/dev/null)

  if [[ -z "$CHANGELOG_JSON" ]]; then
    error "Could not reach $CHANGELOG_API\nManually set the URL and retry:\n  export FIVEM_BUILD_URL='https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/XXXXX-hash/fx.tar.xz'"
  fi

  # Use jq if available (installed above), otherwise grep fallback
  if command -v jq &>/dev/null; then
    RECOMMENDED_BUILD=$(echo "$CHANGELOG_JSON" | jq -r '.recommended')
    DOWNLOAD_URL=$(echo "$CHANGELOG_JSON"       | jq -r '.recommended_download')
  else
    RECOMMENDED_BUILD=$(echo "$CHANGELOG_JSON" | grep -oP '"recommended"\s*:\s*"\K[^"]+' | head -1)
    DOWNLOAD_URL=$(echo "$CHANGELOG_JSON"       | grep -oP '"recommended_download"\s*:\s*"\K[^"]+' | head -1)
  fi

  if [[ -z "$DOWNLOAD_URL" || "$DOWNLOAD_URL" == "null" ]]; then
    error "Could not parse recommended_download from changelog API.\nJSON snippet:\n$(echo "$CHANGELOG_JSON" | head -c 500)"
  fi

  log "Recommended build : $RECOMMENDED_BUILD"
fi

warn "Downloading: $DOWNLOAD_URL"
wget -q --show-progress -O /tmp/fx.tar.xz "$DOWNLOAD_URL" \
  || error "Download failed. Check URL:\n  $DOWNLOAD_URL"

tar -xJf /tmp/fx.tar.xz -C "$SERVER_DIR"
rm /tmp/fx.tar.xz
chmod +x "$SERVER_DIR/run.sh" 2>/dev/null || true
log "FiveM artifacts extracted"

# ── Clone cfx-server-data ────────────────────────────────────
header "Cloning Server Data"
if [[ -d "$DATA_DIR/.git" ]]; then
  warn "server-data already exists, pulling latest..."
  git -C "$DATA_DIR" pull -q
else
  git clone -q https://github.com/citizenfx/cfx-server-data.git "$DATA_DIR"
fi
log "server-data ready"

# ── Create server.cfg ────────────────────────────────────────
header "Creating server.cfg"
CFG="$DATA_DIR/server.cfg"

if [[ -f "$CFG" ]]; then
  warn "server.cfg already exists — skipping"
else
cat > "$CFG" << 'CFG_EOF'
# ── Basic Settings ──────────────────────────────
endpoint_add_tcp "0.0.0.0:30120"
endpoint_add_udp "0.0.0.0:30120"

sv_maxclients 32
sv_hostname "My FiveM Server"

# ── License Key (required) ──────────────────────
# Get yours: https://keymaster.fivem.net
sv_licenseKey "YOUR_LICENSE_KEY_HERE"

# ── Resources ───────────────────────────────────
ensure mapmanager
ensure chat
ensure spawnmanager
ensure sessionmanager
ensure basic-gamemode
ensure hardcap
ensure rconlog
CFG_EOF
  log "server.cfg created: $CFG"
fi

# ── Start scripts ────────────────────────────────────────────
header "Creating Start Scripts"

cat > "$INSTALL_DIR/start.sh" << STARTEOF
#!/bin/bash
cd "$SERVER_DIR"
exec bash run.sh +exec "$DATA_DIR/server.cfg"
STARTEOF
chmod +x "$INSTALL_DIR/start.sh"

cat > "$INSTALL_DIR/screen-start.sh" << SCREENEOF
#!/bin/bash
screen -dmS fivem bash "$INSTALL_DIR/start.sh"
echo "Started in screen 'fivem' — attach: screen -r fivem"
SCREENEOF
chmod +x "$INSTALL_DIR/screen-start.sh"
log "start.sh and screen-start.sh created"

# ── Fix ownership ────────────────────────────────────────────
chown -R fivem:fivem "$INSTALL_DIR"

# ── systemd service ──────────────────────────────────────────
header "Creating systemd Service"
cat > /etc/systemd/system/fivem.service << SVCEOF
[Unit]
Description=FiveM Server
After=network.target

[Service]
Type=simple
User=fivem
WorkingDirectory=$SERVER_DIR
ExecStart=$SERVER_DIR/run.sh +exec $DATA_DIR/server.cfg
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable fivem
log "systemd service enabled (fivem.service)"

# ── Done ─────────────────────────────────────────────────────
header "Installation Complete"
echo -e "${GREEN}"
echo "  Install dir : $INSTALL_DIR"
echo "  server.cfg  : $CFG"
echo ""
echo "  ⚠  EDIT server.cfg → add your license key first!"
echo "     https://keymaster.fivem.net"
echo ""
echo "  ── Start commands ──────────────────────────"
echo "  systemd : sudo systemctl start fivem"
echo "  screen  : sudo -u fivem $INSTALL_DIR/screen-start.sh"
echo "  logs    : sudo journalctl -u fivem -f"
echo -e "${NC}"
