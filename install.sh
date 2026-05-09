#!/bin/bash
# ============================================================
#  FiveM Server Auto-Installer for Ubuntu
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
INSTALL_DIR="$HOME/FXServer"
SERVER_DIR="$INSTALL_DIR/server"
DATA_DIR="$INSTALL_DIR/server-data"
ARTIFACTS_BASE="https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master"
API_URL="https://changelogs-live.fivem.net/api/changelog/versions/linux/server"
# ────────────────────────────────────────────────────────────

header "FiveM Server Installer"

if [[ $EUID -eq 0 ]]; then
  warn "Running as root. Recommended to run as a normal user."
fi

# ── Dependencies ─────────────────────────────────────────────
header "Installing Dependencies"
apt-get update -qq
apt-get install -y -qq \
  curl wget git xz-utils \
  screen tar jq \
  lib32gcc-s1 libssl-dev > /dev/null
log "Dependencies installed"

# ── Create directories ───────────────────────────────────────
header "Setting Up Directories"
mkdir -p "$SERVER_DIR" "$DATA_DIR"
log "Directories created: $INSTALL_DIR"

# ── Get latest artifact ──────────────────────────────────────
header "Downloading Latest FiveM Artifacts"

# วิธีที่ 1: ดึงจาก FiveM API (เร็วและแม่นยำ)
LATEST=$(curl -sSL --max-time 15 "$API_URL" 2>/dev/null | jq -r '.latest // empty' 2>/dev/null)

# วิธีที่ 2: fallback — scrape HTML พร้อม User-Agent
if [[ -z "$LATEST" ]]; then
  warn "API method failed, trying HTML scrape..."
  LATEST=$(curl -sSL --max-time 15 -A "Mozilla/5.0 (X11; Linux x86_64)" "$ARTIFACTS_BASE/" 2>/dev/null \
    | grep -oP '(?<=href=")[0-9]+-[a-f0-9]+(?=/server\.tar\.xz)' \
    | sort -t- -k1 -n \
    | tail -1)
fi

# วิธีที่ 3: fallback — ดึงจาก recommend endpoint
if [[ -z "$LATEST" ]]; then
  warn "Scrape failed, trying recommend endpoint..."
  LATEST=$(curl -sSL --max-time 15 "$ARTIFACTS_BASE/LATEST_RECOMMENDED" 2>/dev/null | tr -d '[:space:]')
fi

if [[ -z "$LATEST" ]]; then
  error "Could not find latest artifact. Please check https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/ and run again with BUILD variable:\n  BUILD=12345-abcdef bash install.sh"
fi

# รองรับกรณีที่ผู้ใช้กำหนด BUILD เองจากภายนอก
if [[ -n "$BUILD" ]]; then
  warn "Using manually specified build: $BUILD"
  LATEST="$BUILD"
fi

log "Latest build: $LATEST"
DOWNLOAD_URL="$ARTIFACTS_BASE/$LATEST/server.tar.xz"

log "Downloading from: $DOWNLOAD_URL"
wget --max-redirect=5 --show-progress -O /tmp/fx-server.tar.xz "$DOWNLOAD_URL" || \
  error "Download failed. Try manually: wget -O /tmp/fx-server.tar.xz \"$DOWNLOAD_URL\""

tar -xJf /tmp/fx-server.tar.xz -C "$SERVER_DIR"
rm /tmp/fx-server.tar.xz
chmod +x "$SERVER_DIR/run.sh"
log "FiveM artifacts extracted"

# ── Clone cfx-server-data ────────────────────────────────────
header "Cloning Server Data (cfx-server-data)"
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
  warn "server.cfg already exists — skipping. Edit manually: $CFG"
else
cat > "$CFG" << 'CFG_EOF'
# ── Basic Settings ───────────────────────────────
endpoint_add_tcp "0.0.0.0:30120"
endpoint_add_udp "0.0.0.0:30120"

sv_maxclients 32
sv_hostname "My FiveM Server"

# ── License Key (required) ───────────────────────
# Get yours at: https://keymaster.fivem.net
sv_licenseKey "YOUR_LICENSE_KEY_HERE"

# ── Steam API (optional) ─────────────────────────
# steam_webApiKey "YOUR_STEAM_API_KEY"

# ── Resources ────────────────────────────────────
ensure mapmanager
ensure chat
ensure spawnmanager
ensure sessionmanager
ensure basic-gamemode
ensure hardcap
ensure rconlog

# ── Permissions ──────────────────────────────────
add_ace group.admin command allow
add_ace group.admin command.quit allow
add_principal identifier.steam:YOUR_STEAM_ID group.admin

# ── RCON (optional) ──────────────────────────────
# sets sv_rconPassword "CHANGE_ME"
CFG_EOF
  log "server.cfg created at $CFG"
fi

# ── Create start script ──────────────────────────────────────
header "Creating Start Script"
cat > "$INSTALL_DIR/start.sh" << STARTEOF
#!/bin/bash
cd "$SERVER_DIR"
bash run.sh +exec "$DATA_DIR/server.cfg"
STARTEOF
chmod +x "$INSTALL_DIR/start.sh"
log "Start script: $INSTALL_DIR/start.sh"

# ── Create screen helper ─────────────────────────────────────
cat > "$INSTALL_DIR/screen-start.sh" << SCREENEOF
#!/bin/bash
screen -dmS fivem bash "$INSTALL_DIR/start.sh"
echo "Server started in screen session 'fivem'"
echo "Attach with: screen -r fivem"
SCREENEOF
chmod +x "$INSTALL_DIR/screen-start.sh"
log "Screen helper: $INSTALL_DIR/screen-start.sh"

# ── systemd service (optional) ───────────────────────────────
header "systemd Service (optional)"
read -rp "Create systemd service for auto-start on boot? [y/N]: " CREATE_SERVICE
if [[ "$CREATE_SERVICE" =~ ^[Yy]$ ]]; then
  SERVICE_FILE="/etc/systemd/system/fivem.service"
  tee "$SERVICE_FILE" > /dev/null << SVCEOF
[Unit]
Description=FiveM Server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$SERVER_DIR
ExecStart=$SERVER_DIR/run.sh +exec $DATA_DIR/server.cfg
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF
  systemctl daemon-reload
  systemctl enable fivem
  log "systemd service created. Start with: systemctl start fivem"
else
  warn "Skipped systemd. Use $INSTALL_DIR/screen-start.sh to launch manually."
fi

# ── Done ─────────────────────────────────────────────────────
header "Installation Complete"
echo -e "${GREEN}"
echo "  Install dir : $INSTALL_DIR"
echo "  server.cfg  : $DATA_DIR/server.cfg"
echo "  Start server: $INSTALL_DIR/start.sh"
echo "  With screen : $INSTALL_DIR/screen-start.sh"
echo ""
echo "  ⚠  Edit server.cfg and set your license key first!"
echo "     https://keymaster.fivem.net"
echo -e "${NC}"
