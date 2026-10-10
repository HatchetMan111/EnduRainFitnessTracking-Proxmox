#!/usr/bin/env bash
#
# Endurain Proxmox LXC Installer – im Stil der Proxmox VE Community Scripts
#
# App:      Endurain – self-hosted Fitness-Tracking (Strava-Alternative, lokal)
# Upstream: https://github.com/endurain-project/endurain
# Stack:    Python/FastAPI (uv, nur localhost:8080) + Vue 3 SPA (Node 24 Build)
#           + PostgreSQL + Redis + Caddy als HTTPS-Reverse-Proxy (self-signed,
#           tls internal) auf :443 mit HTTP→HTTPS-Redirect, nativ im LXC,
#           ohne Docker, ohne Cloud. BEHIND_PROXY=true, damit Login/SSO
#           (Secure-Cookies) und die Mobile-App funktionieren.
# Läuft:    vollständig lokal im LXC, keine externen Cloud-Dienste nötig
# Host:     DAS SKRIPT LÄUFT AUF DEM PROXMOX-HOST (nicht im Container!)
# Usage:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/EnduRainFitnessTracking-Proxmox/main/install/endurain.sh)"
#   CT_ID=150 CORES=2 RAM=4096 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/EnduRainFitnessTracking-Proxmox/main/install/endurain.sh)"
#   bash endurain.sh --ctid 150 --cores 2 --memory 4096 --disk 8 --bridge vmbr0 --debug
#
# Installer-Repo: https://github.com/HatchetMan111/EnduRainFitnessTracking-Proxmox
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Variablen (oben, Community-Scripts-konform – alles hier anpassbar)
# ---------------------------------------------------------------------------
APP="endurain"                                # Container-Hostname + Service-Name
APP_PORT="8080"                               # Endurain Web-UI + API
UPSTREAM_REPO="https://github.com/endurain-project/endurain"
INSTALLER_REPO="https://github.com/HatchetMan111/EnduRainFitnessTracking-Proxmox"
SERVICE_URL="https://raw.githubusercontent.com/HatchetMan111/EnduRainFitnessTracking-Proxmox/main/systemd/endurain.service"

DEFAULT_CORES="2"                             # vCPU (Frontend-Build + Backend brauchen 2)
DEFAULT_RAM="4096"                            # RAM in MB (offizielles ct/endurain.sh: 4096)
DEFAULT_SWAP="512"                            # Swap (MB)
DEFAULT_DISK="8"                              # Disk in GB (5 offiziell, 8 mit Reserve)
DEFAULT_BRIDGE="vmbr0"
DEFAULT_TEMPLATE_STORE="local"                # Storage für CT-Templates
DEFAULT_OS="debian-13-standard"               # Template-Familie (Debian 13, Python 3.13 nativ)
UNPRIVILEGED="1"                              # 1 = unprivilegiert
FEATURES="nesting=1"                          # nesting für Node/npm/uv Robustheit

APP_USER="endurain"
APP_DIR="/opt/endurain"
DATA_BASE="/opt/endurain_data"
PG_DB_NAME="enduraindb"
PG_DB_USER="endurain"

# Umgebungs-Overrides: CT_ID=150 CORES=2 RAM=4096 DISK=8 ./endurain.sh
CT_ID_ARG="${CT_ID:-${CTID:-}}"
CORES_ARG="${CORES:-$DEFAULT_CORES}"
RAM_ARG="${RAM:-$DEFAULT_RAM}"
DISK_ARG="${DISK:-$DEFAULT_DISK}"

DEBUG="${DEBUG:-0}"
LOG_FILE="/tmp/${APP}-install-$(date +%F-%H%M%S).log"

# ---------------------------------------------------------------------------
# Logging / Farben (Community-Scripts-Stil)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' \
  C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_CYAN=""
fi

msg_info()  { echo -e "${C_BLUE}[INFO]${C_RESET}  $*"; }
msg_ok()    { echo -e "${C_GREEN}[OK]${C_RESET}    $*"; }
msg_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
msg_error() { echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; }

# Vollständige Ausgabe ins Log (komplette Kette, nicht nur letzte Zeile)
exec > >(tee -i "$LOG_FILE") 2>&1
msg_info "Logdatei: $LOG_FILE"
[[ "$DEBUG" == "1" ]] && { echo "--- DEBUG: set -x aktiv ---"; set -x; }

# Bei Fehlern: komplette Kette ausgeben (Befehl, Zeile, Exit-Code, Log-Verweis)
trap 'ec=$?; msg_error "FEHLER: Befehl »${BASH_COMMAND}« scheiterte in Zeile ${LINENO} (Exit ${ec})."; msg_error "Vollständiges Log: ${LOG_FILE} – bei Bedarf erneut mit --debug laufen lassen."; exit ${ec}' ERR

usage() {
  cat <<EOF
${APP} Proxmox LXC Installer

Usage:
  bash endurain.sh [OPTIONEN]
  CT_ID=150 bash endurain.sh
  bash -c "\$(wget -qLO - ${INSTALLER_REPO%/}/raw/main/install/endurain.sh)"

Optionen:
  --ctid ID            Container-ID (Default: nächste freie ID via 'pvesh get /cluster/nextid')
  --hostname NAME      Hostname (Default: ${APP})
  --cores N            vCPU (Default: ${DEFAULT_CORES})
  --memory MB          RAM in MB (Default: ${DEFAULT_RAM})
  --disk GB            Disk in GB (Default: ${DEFAULT_DISK})
  --storage NAME       RootFS-Storage (Default: auto, bevorzugt local-lvm)
  --template-store N   Template-Storage (Default: ${DEFAULT_TEMPLATE_STORE})
  --bridge NAME        Netzwerk-Bridge (Default: ${DEFAULT_BRIDGE})
  --password PW        Root-Passwort (Default: zufällig generiert, wird angezeigt)
  --ssh-key PATH       SSH Public Key in den Container übernehmen (optional)
  --debug              bash -x + maximale Fehlermeldungskette
  -h, --help           diese Hilfe
EOF
}

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
CT_ID="$CT_ID_ARG" HOSTNAME_ARG="$APP" CORES="$CORES_ARG" RAM="$RAM_ARG" DISK="$DISK_ARG"
STORAGE_ARG="" TEMPLATE_STORE="$DEFAULT_TEMPLATE_STORE" BRIDGE="$DEFAULT_BRIDGE"
PASSWORD_ARG="" SSH_KEY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctid) CT_ID="$2"; shift 2;;
    --hostname) HOSTNAME_ARG="$2"; shift 2;;
    --cores) CORES="$2"; shift 2;;
    --memory|--ram) RAM="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --storage) STORAGE_ARG="$2"; shift 2;;
    --template-store) TEMPLATE_STORE="$2"; shift 2;;
    --bridge) BRIDGE="$2"; shift 2;;
    --password) PASSWORD_ARG="$2"; shift 2;;
    --ssh-key) SSH_KEY_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# Host-Prüfungen
# ---------------------------------------------------------------------------
msg_info "Prüfe Proxmox-Host ..."
[[ "$(id -u)" -eq 0 ]] || { msg_error "Bitte als root auf dem Proxmox-Host laufen lassen."; exit 1; }
for bin in pct pvesh pveam openssl wget; do
  command -v "$bin" >/dev/null 2>&1 || { msg_error "Benötigtes Tool fehlt: $bin (Proxmox-Host nötig)."; exit 1; }
done
msg_ok "Host-Tools OK."

# CT-ID: immer nächste freie, außer gesetzt
if [[ -z "$CT_ID" ]]; then
  CT_ID="$(pvesh get /cluster/nextid)"
  msg_info "CT-ID: nächste freie = $CT_ID"
else
  msg_info "CT-ID: vorgegeben = $CT_ID"
fi

UPDATE_MODE=0
if pct status "$CT_ID" >/dev/null 2>&1; then
  UPDATE_MODE=1
  msg_warn "CT $CT_ID existiert bereits → Update-Modus (idempotent: git pull + rebuild + restart)."
fi

# RootFS-Storage: bevorzugt local-lvm, sonst erstes mit rootdir-Content
pick_storage() {
  if [[ -n "$STORAGE_ARG" ]]; then echo "$STORAGE_ARG"; return; fi
  local stor
  if pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "local-lvm"; then
    echo "local-lvm"; return
  fi
  stor="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}' | head -n1)"
  [[ -n "$stor" ]] || { msg_error "Kein Storage mit Content 'rootdir' gefunden."; exit 1; }
  echo "$stor"
}
STORAGE="$(pick_storage)"
msg_info "Storage: rootfs=$STORAGE, templates=$TEMPLATE_STORE, bridge=$BRIDGE"

# Template: neuestes debian-13-standard (ggf. Fallback), ggf. laden
# Hinweis: aktuelle Proxmox-Templates sind .tar.zst (zstd), nicht .tar.gz!
pveam update >/dev/null 2>&1 || msg_warn "pveam update scheiterte – nutze vorhandene Template-Liste."
AVAILABLE_TEMPLATES="$(pveam available --section system 2>/dev/null || true)"
TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "${DEFAULT_OS}[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_warn "Kein ${DEFAULT_OS}-Template gefunden – versuche Fallback (neuestes debian-*-standard) ..."
  TEMPLATE="$(printf '%s' "$AVAILABLE_TEMPLATES" | grep -oP "debian-[0-9]+-standard[^ ]*amd64[^ ]*\.tar\.(gz|xz|zst)" | sort -V | tail -n1 || true)"
fi
if [[ -z "${TEMPLATE:-}" ]]; then
  msg_error "Kein Debian-Standard-Template gefunden (weder ${DEFAULT_OS} noch Fallback)."
  msg_error "Verfügbare Templates (erste 20 Zeilen):"
  printf '%s\n' "$AVAILABLE_TEMPLATES" | head -n 20 >&2 || true
  msg_error "Bitte 'pveam update' manuell prüfen (Netz/DNS auf dem Host)."
  exit 1
fi
if ! pveam list "$TEMPLATE_STORE" 2>/dev/null | grep -Fq "$TEMPLATE"; then
  msg_info "Lade Template $TEMPLATE_STORE:vztmpl/$TEMPLATE ..."
  pveam download "$TEMPLATE_STORE" "$TEMPLATE"
fi
msg_ok "Template: $TEMPLATE_STORE:vztmpl/$TEMPLATE"

# Root-Passwort
if [[ -z "$PASSWORD_ARG" ]]; then
  PASSWORD_ARG="$(openssl rand -hex 12)"
  GENERATED_PW=1
else
  GENERATED_PW=0
fi

# ---------------------------------------------------------------------------
# Container erstellen (nur Neuinstallation)
# ---------------------------------------------------------------------------
if [[ "$UPDATE_MODE" -eq 0 ]]; then
  msg_info "Erstelle LXC $CT_ID (Hostname: $HOSTNAME_ARG, ${CORES}vCPU/${RAM}MB/${DISK}GB, onboot=1, unprivilegiert) ..."
  pct create "$CT_ID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname "$HOSTNAME_ARG" \
    --cores "$CORES" --memory "$RAM" --swap "$DEFAULT_SWAP" \
    --rootfs "${STORAGE}:${DISK}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
    --unprivileged "$UNPRIVILEGED" --features "$FEATURES" \
    --onboot 1 --start 1 \
    --password "$PASSWORD_ARG"
  if [[ -n "$SSH_KEY_ARG" ]]; then
    [[ -f "$SSH_KEY_ARG" ]] || { msg_error "SSH-Key nicht gefunden: $SSH_KEY_ARG"; exit 1; }
    pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys 2>/dev/null || {
      pct exec "$CT_ID" -- mkdir -p /root/.ssh
      pct push "$CT_ID" "$SSH_KEY_ARG" /root/.ssh/authorized_keys
    }
  fi
  msg_ok "Container $CT_ID erstellt und gestartet."
else
  msg_info "Update-Modus: Container wird nicht neu erstellt."
  if ! pct status "$CT_ID" | grep -q "status: running"; then
    msg_info "Starte CT $CT_ID ..."
    pct start "$CT_ID"
  fi
fi

# Auf Netzwerk warten (DHCP)
msg_info "Warte auf Container-Netzwerk ..."
CT_IP=""
for _ in $(seq 1 30); do
  CT_IP="$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$CT_IP" ]] && break
  sleep 2
done
[[ -n "$CT_IP" ]] || { msg_error "Keine Container-IP erhalten (DHCP/Bridge $BRIDGE prüfen)."; exit 1; }
msg_ok "Container-IP: $CT_IP"
ENDURAIN_HOST="https://${CT_IP}"

# ---------------------------------------------------------------------------
# Provisionierung im Container (idempotentes Inline-Script via pct push)
# ---------------------------------------------------------------------------
PROV_HOST_TMP="$(mktemp /tmp/endurain-prov-XXXX.sh)"
cat > "$PROV_HOST_TMP" <<PROV_EOF
#!/usr/bin/env bash
set -euo pipefail
APP_DIR="$APP_DIR"
DATA_BASE="$DATA_BASE"
PG_DB_NAME="$PG_DB_NAME"
PG_DB_USER="$PG_DB_USER"
CT_IP="$CT_IP"
ENDURAIN_HOST="$ENDURAIN_HOST"
UPSTREAM_REPO="$UPSTREAM_REPO"

echo "[PROV] apt update ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget git openssl ca-certificates build-essential \
  python3 python3-venv python3-dev libpq-dev \
  postgresql postgresql-contrib redis-server >/dev/null

# --- PostGIS (optional, best effort) ---
apt-get install -y -qq postgis postgresql-postgis 2>/dev/null \
  || apt-get install -y -qq postgresql-*-postgis-3 2>/dev/null || true

systemctl enable --now postgresql >/dev/null 2>&1 || service postgresql start || true
systemctl enable --now redis-server >/dev/null 2>&1 || service redis-server start || true

# --- Node.js 24 (nodesource, idempotent) ---
if ! command -v node >/dev/null 2>&1 || ! node --version | grep -Eq "v(22|24|25|26)"; then
  echo "[PROV] installiere Node.js 24 ..."
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash - >/dev/null
  apt-get install -y -qq nodejs >/dev/null
fi
echo "[PROV] node=\$(node --version) npm=\$(npm --version)"

# --- uv (gepinnt aus pyproject, Fallback 0.12.23) ---
want_uv() {
  local v=""
  if [[ -f "\$APP_DIR/backend/pyproject.toml" ]]; then
    v="\$(grep -Po 'required-version\\s*=\\s*\"\\K[^\"]+' "\$APP_DIR/backend/pyproject.toml" 2>/dev/null || true)"
  fi
  [[ -n "\$v" ]] || v="0.12.23"
  echo "\$v"
}
UV_WANT="\$(want_uv)"
if ! command -v uv >/dev/null 2>&1 || ! uv --version | grep -q "\$UV_WANT"; then
  echo "[PROV] installiere uv \$UV_WANT ..."
  curl -LsSf https://astral.sh/uv/install.sh | env UV_VERSION="\$UV_WANT" sh >/dev/null
  ln -sf /root/.local/bin/uv /usr/local/bin/uv
fi
echo "[PROV] uv=\$(uv --version)"

# --- Service-User + Verzeichnisse ---
id -u "$APP_USER" >/dev/null 2>&1 || useradd -r -m -d "/home/$APP_USER" -s /bin/bash "$APP_USER"
mkdir -p "\$DATA_BASE/data" "\$DATA_BASE/logs"
chown -R "$APP_USER:$APP_USER" "\$DATA_BASE"

# --- App-Code (Clone oder Pull = idempotent) ---
if [[ ! -d "\$APP_DIR/.git" ]]; then
  echo "[PROV] klone \$UPSTREAM_REPO ..."
  rm -rf "\$APP_DIR"
  git clone --depth 1 "\$UPSTREAM_REPO" "\$APP_DIR"
else
  echo "[PROV] aktualisiere \$APP_DIR (git pull) ..."
  git -C "\$APP_DIR" fetch --depth 1 origin 2>/dev/null || git -C "\$APP_DIR" fetch origin || true
  git -C "\$APP_DIR" reset --hard origin/master 2>/dev/null || git -C "\$APP_DIR" reset --hard origin/main || true
fi
rm -rf "\$APP_DIR/docs" "\$APP_DIR/screenshot_01.png" "\$APP_DIR/docker-compose.yml.example" 2>/dev/null || true
chown -R "$APP_USER:$APP_USER" "\$APP_DIR"

# --- PostgreSQL Rolle + DB (idempotent) ---
echo "[PROV] richte PostgreSQL ein ..."
if [[ -f "\$APP_DIR/.env" ]]; then
  # shellcheck disable=SC1090
  DB_PASSWORD="\$(grep -E '^DB_PASSWORD=' "\$APP_DIR/.env" | cut -d= -f2-)"
fi
if [[ -z "\${DB_PASSWORD:-}" ]]; then
  DB_PASSWORD="\$(openssl rand -hex 24)"
fi
export DB_PASSWORD
su postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='\$PG_DB_USER'\"" | grep -q 1 \
  || su postgres -c "psql -c \"CREATE ROLE \$PG_DB_USER LOGIN PASSWORD '\$DB_PASSWORD'\""
su postgres -c "psql -c \"ALTER ROLE \$PG_DB_USER WITH PASSWORD '\$DB_PASSWORD'\""
su postgres -c "psql -tc \"SELECT 1 FROM pg_database WHERE datname='\$PG_DB_NAME'\"" | grep -q 1 \
  || su postgres -c "psql -c \"CREATE DATABASE \$PG_DB_NAME OWNER \$PG_DB_USER\""
su postgres -c "psql -d \$PG_DB_NAME -c 'CREATE EXTENSION IF NOT EXISTS postgis'" >/dev/null 2>&1 || true
echo "[PROV] DB \$PG_DB_NAME + Rolle \$PG_DB_USER OK."

# --- .env (Secrets wiederverwenden, sonst generieren) ---
if [[ -f "\$APP_DIR/.env" ]]; then
  # shellcheck disable=SC1090
  SECRET_KEY="\$(grep -E '^SECRET_KEY=' "\$APP_DIR/.env" | cut -d= -f2- || true)"
  FERNET_KEY="\$(grep -E '^FERNET_KEY=' "\$APP_DIR/.env" | cut -d= -f2- || true)"
fi
[[ -n "\${SECRET_KEY:-}" ]] || SECRET_KEY="\$(openssl rand -hex 32)"
if [[ -z "\${FERNET_KEY:-}" ]]; then
  FERNET_KEY="\$(python3 -c 'import base64,secrets; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode())')"
fi
cat > "\$APP_DIR/.env" <<ENV_EOF2
DB_PASSWORD=\$DB_PASSWORD
POSTGRES_PASSWORD=\$DB_PASSWORD
SECRET_KEY=\$SECRET_KEY
FERNET_KEY=\$FERNET_KEY

TZ=Europe/Berlin
ENDURAIN_HOST=\$ENDURAIN_HOST
BEHIND_PROXY=true
TRUSTED_PROXIES=127.0.0.1
RATE_LIMIT_STORAGE_URI=redis://localhost:6379/0
AUTH_SECURITY_STORAGE_URI=redis://localhost:6379/0

POSTGRES_DB=\$PG_DB_NAME
POSTGRES_USER=\$PG_DB_USER
PGDATA=/var/lib/postgresql/data/pgdata

DB_DATABASE=\$PG_DB_NAME
DB_USER=\$PG_DB_USER
DB_PORT=5432
DB_HOST=localhost
DATABASE_URL=postgresql+psycopg://\$PG_DB_USER:\$DB_PASSWORD@localhost:5432/\$PG_DB_NAME

BACKEND_DIR="\$APP_DIR/backend/app"
FRONTEND_DIR="\$APP_DIR/frontend/dist"
DATA_DIR="\$DATA_BASE/data"
LOGS_DIR="\$DATA_BASE/logs"
ENV_EOF2
chown "$APP_USER:$APP_USER" "\$APP_DIR/.env"
chmod 600 "\$APP_DIR/.env"
echo "[PROV] .env geschrieben (ENDURAIN_HOST=\$ENDURAIN_HOST)."

# --- Frontend-Build ---
echo "[PROV] baue Frontend (npm ci + build, kann einige Minuten dauern) ..."
cd "\$APP_DIR/frontend"
sudo -u "$APP_USER" npm ci --prefer-offline
sudo -u "$APP_USER" npm run build
cat > "\$APP_DIR/frontend/dist/env.js" <<ENVJS_EOF
window.env = {
  ENDURAIN_HOST: "\$ENDURAIN_HOST"
}
ENVJS_EOF
echo "[PROV] Frontend-Build OK."

# --- Backend ---
echo "[PROV] installiere Backend (uv sync, kann einige Minuten dauern) ..."
cd "\$APP_DIR/backend"
uv sync --frozen --no-dev
chown -R "$APP_USER:$APP_USER" "\$APP_DIR/backend/.venv" 2>/dev/null || true
echo "[PROV] Backend OK."

# --- Caddy HTTPS-Reverse-Proxy (self-signed, tls internal) ---
if ! command -v caddy >/dev/null 2>&1; then
  echo "[PROV] installiere Caddy ..."
  apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg >/dev/null
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -qq
  apt-get install -y -qq caddy >/dev/null
fi
echo "[PROV] caddy=\$(caddy version)"
cat > /etc/caddy/Caddyfile <<CADDY_EOF
https://\$CT_IP {
	tls internal
	reverse_proxy 127.0.0.1:$APP_PORT
}

http://\$CT_IP {
	redir https://{host}{uri}
}
CADDY_EOF
systemctl enable --now caddy >/dev/null 2>&1 || service caddy start || true
caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || systemctl restart caddy
echo "[PROV] Caddy-HTTPS auf https://\$CT_IP aktiv (self-signed, Browser-Warnung einmal bestätigen)."

# --- systemd-Service ---
echo "[PROV] installiere systemd-Service ..."
if curl -fsSL "$SERVICE_URL" -o /etc/systemd/system/$APP.service 2>/dev/null; then
  echo "[PROV] Unit von $SERVICE_URL geladen."
else
  echo "[PROV] Download fehlgeschlagen → Inline-Fallback-Unit."
  cat > /etc/systemd/system/$APP.service <<UNIT_EOF
[Unit]
Description=Endurain – self-hosted Fitness-Tracking (FastAPI Backend + Vue SPA)
Documentation=$UPSTREAM_REPO
After=network-online.target postgresql.service redis-server.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=\$APP_DIR/backend/app
EnvironmentFile=\$APP_DIR/.env
ExecStart=\$APP_DIR/backend/.venv/bin/uvicorn main:app --host 127.0.0.1 --port $APP_PORT --proxy-headers --forwarded-allow-ips=127.0.0.1
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF
fi
systemctl daemon-reload
systemctl enable --now "$APP"
echo "[PROV] Service enabled + gestartet."
PROV_EOF

pct push "$CT_ID" "$PROV_HOST_TMP" /tmp/endurain-provision.sh
msg_info "Provisioniere im Container (dauert einige Minuten: Node-Build + uv sync) ..."
pct exec "$CT_ID" -- bash /tmp/endurain-provision.sh
rm -f "$PROV_HOST_TMP"
msg_ok "Provisionierung abgeschlossen."

# ---------------------------------------------------------------------------
# Verifikation
# ---------------------------------------------------------------------------
msg_info "Verifiziere Installation ..."
sleep 5
for svc in "$APP" postgresql redis-server caddy; do
  state="$(pct exec "$CT_ID" -- systemctl is-active "$svc" 2>&1 || true)"
  if [[ "$state" == "active" ]]; then
    msg_ok "Service läuft (systemctl is-active $svc = active)."
  else
    msg_error "Service $svc NICHT aktiv (Status: $state). Logs: pct exec $CT_ID -- journalctl -u $svc -n 100"
    exit 1
  fi
done

if pct exec "$CT_ID" -- curl -fs "http://localhost:${APP_PORT}/api/v1/about" >/dev/null 2>&1; then
  msg_ok "Backend antwortet (HTTP 200 auf localhost:${APP_PORT}/api/v1/about)."
else
  msg_error "Backend antwortet NICHT auf localhost:${APP_PORT}. Prüfe: pct exec $CT_ID -- journalctl -u $APP -n 100"
  exit 1
fi

if pct exec "$CT_ID" -- curl -kfs "https://localhost/api/v1/about" >/dev/null 2>&1; then
  msg_ok "HTTPS-Proxy antwortet (HTTP 200 via Caddy auf https://localhost/api/v1/about, -k wegen self-signed)."
else
  msg_error "HTTPS-Proxy antwortet NICHT. Prüfe: pct exec $CT_ID -- journalctl -u caddy -n 100"
  exit 1
fi

# onboot sicherstellen
pct set "$CT_ID" --onboot 1 >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Zusammenfassung
# ---------------------------------------------------------------------------
echo ""
echo "════════════════ INSTALLATION ERFOLGREICH ════════════════"
echo "  App          : Endurain – self-hosted Fitness-Tracking"
echo "  Upstream     : $UPSTREAM_REPO"
echo "  Container    : CT $CT_ID (Hostname: $HOSTNAME_ARG, unprivilegiert, onboot=1)"
echo "  Ressourcen   : $CORES vCPU / $RAM MB RAM / $DISK GB Disk"
echo "  Web UI       : https://$CT_IP  (self-signed – Browser-Warnung einmal bestätigen)"
echo "  API-Check    : https://$CT_IP/api/v1/about"
echo "  HTTP         : http://$CT_IP → Redirect auf HTTPS"
if [[ "${GENERATED_PW:-0}" -eq 1 ]]; then
echo "  CT-Root-PW   : $PASSWORD_ARG (nur dieses Mal angezeigt!)"
fi
echo "  Update       : bash endurain.sh --ctid $CT_ID   (idempotent)"
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Logs (Host)  : $LOG_FILE"
echo "  Logs (CT)    : pct exec $CT_ID -- journalctl -u $APP -n 100"
echo "  Hinweis      : Zertifikat ist self-signed (Caddy tls internal)."
echo "                 Bei IP-Wechsel (DHCP): Router-Reservierung empfohlen,"
echo "                 sonst Installer-Update erneut laufen lassen."
echo "                 Strava-Sync braucht zusätzlich eine öffentliche"
echo "                 https-Domain (siehe README)." 
echo "══════════════════════════════════════════════════════════"
