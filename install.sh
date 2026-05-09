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

# ── Root check ───────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Please run as root: sudo bash install.sh"
fi

# ── Config ───────────────────────────────────────────────────
CURRENT_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$CURRENT_USER" | cut -d: -f6)
INSTALL_DIR="$USER_HOME/FXServer"
SERVER_DIR="$INSTALL_DIR/server"
DATA_DIR="$INSTALL_DIR/server-data"
CHANGELOG_API="https://changelogs-live.fivem.net/api/changelog/versions/linux/server"
# ────────────────────────────────────────────────────────────

header "FiveM Server Installer"
warn "Install location: $INSTALL_DIR  (user: $CURRENT_USER)"

# ── FTP check ────────────────────────────────────────────────
header "Checking FTP Server"
if command -v vsftpd &>/dev/null || command -v proftpd &>/dev/null || command -v pure-ftpd &>/dev/null; then
  log "FTP server already installed — skipping"
else
  warn "No FTP server detected"
  echo -ne "${YELLOW}  ติดตั้ง vsftpd (FTP server) ด้วยไหม? [y/N]: ${NC}"
  read -r FTP_ANSWER </dev/tty
  if [[ "$FTP_ANSWER" =~ ^[Yy]$ ]]; then
    apt-get install -y -qq vsftpd > /dev/null

    # config vsftpd — local users, write enabled, no anonymous
    cat > /etc/vsftpd.conf << 'FTPCFG'
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
secure_chroot_dir=/var/run/vsftpd/empty
pam_service_name=vsftpd
FTPCFG

    systemctl enable vsftpd --now > /dev/null
    log "vsftpd installed and started (port 21)"
    warn "เปิด port 21 ใน firewall ด้วย: sudo ufw allow 21/tcp"
  else
    warn "Skipping FTP installation"
  fi
fi

# ── Dependencies ─────────────────────────────────────────────
header "Installing Dependencies"
apt-get update -qq
apt-get install -y -qq curl wget git xz-utils tar jq > /dev/null
log "Dependencies installed"

# ── Create directories ───────────────────────────────────────
header "Setting Up Directories"
mkdir -p "$SERVER_DIR" "$DATA_DIR"
log "Directories created: $INSTALL_DIR"

# ── Resolve artifact download URL ────────────────────────────
header "Resolving Latest FiveM Artifacts"

if [[ -n "$FIVEM_BUILD_URL" ]]; then
  DOWNLOAD_URL="$FIVEM_BUILD_URL"
  warn "Using manually set FIVEM_BUILD_URL: $DOWNLOAD_URL"
else
  warn "Fetching build info from changelog API..."
  CHANGELOG_JSON=$(curl -sSL --max-time 15 "$CHANGELOG_API" 2>/dev/null)

  if [[ -z "$CHANGELOG_JSON" ]]; then
    error "Could not reach $CHANGELOG_API\nManually set the URL and retry:\n  export FIVEM_BUILD_URL='https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/XXXXX-hash/fx.tar.xz'"
  fi

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

# ── start.sh (auto-restart) ──────────────────────────────────
header "Creating start.sh"

cat > "$INSTALL_DIR/start.sh" << STARTEOF
#!/bin/bash
# ── FiveM Auto-Restart Wrapper ──────────────────
CRASHES=0
MAX_CRASHES=10
CRASH_WINDOW=300

cd "$SERVER_DIR"

while true; do
  START_TIME=\$(date +%s)
  echo "[FiveM] Starting server... (crashes so far: \$CRASHES)"

  bash run.sh +exec "$DATA_DIR/server.cfg"
  EXIT_CODE=\$?

  END_TIME=\$(date +%s)
  UPTIME=\$((END_TIME - START_TIME))

  echo "[FiveM] Server exited (code: \$EXIT_CODE, uptime: \${UPTIME}s)"

  if [[ \$UPTIME -ge \$CRASH_WINDOW ]]; then
    CRASHES=0
  fi

  CRASHES=\$((CRASHES + 1))

  if [[ \$CRASHES -ge \$MAX_CRASHES ]]; then
    echo "[FiveM] Too many crashes (\$CRASHES). Giving up."
    exit 1
  fi

  echo "[FiveM] Restarting in 5 seconds..."
  sleep 5
done
STARTEOF
chmod +x "$INSTALL_DIR/start.sh"
log "start.sh created"

# ── Fix ownership ────────────────────────────────────────────
chown -R "$CURRENT_USER":"$CURRENT_USER" "$INSTALL_DIR"
log "Ownership set to $CURRENT_USER"

# ── systemd service ──────────────────────────────────────────
header "Creating systemd Service"
cat > /etc/systemd/system/fivem.service << SVCEOF
[Unit]
Description=FiveM Server
After=network.target

[Service]
Type=simple
User=$CURRENT_USER
WorkingDirectory=$SERVER_DIR
ExecStart=$INSTALL_DIR/start.sh
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
echo "  start  : sudo systemctl start fivem"
echo "  stop   : sudo systemctl stop fivem"
echo "  logs   : sudo journalctl -u fivem -f"
echo -e "${NC}"
