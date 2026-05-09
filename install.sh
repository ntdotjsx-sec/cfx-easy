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
ARTIFACTS_BASE="https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master"
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

# ── Get latest artifact (parse href list) ────────────────────
header "Downloading Latest FiveM Artifacts"

# ดึง HTML list แล้ว grep เอา build number
LATEST=$(curl -sSL "$ARTIFACTS_BASE/" \
  | grep -oP '\d{4,6}-[0-9a-f]+' \
  | sort -t- -k1 -n \
  | tail -1)

# fallback: ลอง .json endpoint
if [[ -z "$LATEST" ]]; then
  warn "HTML parse failed, trying JSON endpoint..."
  LATEST=$(curl -sSL "$ARTIFACTS_BASE/latest.json" 2>/dev/null \
    | grep -oP '"version"\s*:\s*"\K[^"]+' | head -1)
fi

# fallback2: hardcode recommended build
if [[ -z "$LATEST" ]]; then
  warn "JSON failed too, using known-good build..."
  # ดึง recommended จาก artifacts page text
  LATEST=$(curl -sSL "https://changelogs-live.fivem.net/api/changelog/versions/linux/server" 2>/dev/null \
    | grep -oP '"recommended"\s*:\s*"\K[^"]+' | head -1)
fi

if [[ -z "$LATEST" ]]; then
  error "Could not resolve latest build. Set FIVEM_BUILD env var manually:\n  export FIVEM_BUILD=21547-xxxxx && bash install.sh"
fi

log "Latest build: $LATEST"
DOWNLOAD_URL="$ARTIFACTS_BASE/$LATEST/fx.tar.xz"
warn "Downloading: $DOWNLOAD_URL"

wget -q --show-progress -O /tmp/fx.tar.xz "$DOWNLOAD_URL" \
  || error "Download failed. Check URL: $DOWNLOAD_URL"

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
echo "  ⚠  EDIT server.cfg → ใส่ license key ก่อน!"
echo "     https://keymaster.fivem.net"
echo ""
echo "  ── Start commands ──────────────────────────"
echo "  systemd : sudo systemctl start fivem"
echo "  screen  : sudo -u fivem $INSTALL_DIR/screen-start.sh"
echo "  logs    : sudo journalctl -u fivem -f"
echo -e "${NC}"
