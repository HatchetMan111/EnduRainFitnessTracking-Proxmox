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
# Mobile-App (offizielle App / iOS-TestFlight) braucht ein ÖFFENTLICH vertrautes
# Zertifikat (kein badCertificateCallback in der App → self-signed unmöglich, vgl.
# endurain-project/endurain#727). Weg dorthin OHNE Port-Forwarding: Let's Encrypt
# via DNS-01-Challenge (Default: DuckDNS) – A-Record zeigt auf die LAN-IP:
#   DOMAIN=endurain.duckdns.org DNS_TOKEN=<duckdns-token> bash endurain.sh --ctid 150
#   bash endurain.sh --ctid 150 --domain endurain.duckdns.org --dns-provider duckdns --dns-token <token>
# Alternativ ohne Domain: --app-http-port 8081 (Plain-HTTP nur für die App).
# Ohne --domain fragt das Script im interaktiven Terminal nach Domain/Provider/Token
# (Enter = überspringen; NONINTERACTIVE=1 unterdrückt die Abfrage).
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

# Domain-Modus (Mobile-App-tauglich): Let's Encrypt via DNS-01, Server bleibt LAN-only
DOMAIN_ARG="${DOMAIN:-}"
DNS_PROVIDER_ARG="${DNS_PROVIDER:-}"
DNS_TOKEN_ARG="${DNS_TOKEN:-}"
CF_ZONE_ID_ARG="${CF_ZONE_ID:-}"
APP_HTTP_PORT_ARG="${APP_HTTP_PORT:-}"   # z.B. 8081: Plain-HTTP-Listener als App-Fallback ohne Domain

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
  --ssh-key PATH        SSH Public Key in den Container übernehmen (optional)
  --domain NAME        DNS-Name (z.B. endurain.duckdns.org) → Let's-Encrypt-Zertifikat via
                       DNS-01-Challenge: offizielle Mobile-App (TestFlight) verbindet sich,
                       Server bleibt LAN-only (kein Port-Forwarding nötig;
                       ohne Angabe interaktiv im Terminal abgefragt)
  --dns-provider P     duckdns (Default) oder cloudflare – DNS-Provider für --domain
  --dns-token TOKEN    DuckDNS-/Cloudflare-API-Token (Pflicht bei --domain)
  --cf-zone-id ID      optional: Cloudflare Zone-ID (bei --dns-provider cloudflare)
  --app-http-port N    zusätzlicher Plain-HTTP-Port (z.B. 8081): Mobile-App-Fallback ohne
                       Domain (App: Protokoll http, Adresse <CT-IP>:<PORT>)
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
    --domain) DOMAIN_ARG="$2"; shift 2;;
    --dns-provider) DNS_PROVIDER_ARG="$2"; shift 2;;
    --dns-token) DNS_TOKEN="$2"; DNS_TOKEN_ARG="$2"; shift 2;;
    --cf-zone-id) CF_ZONE_ID_ARG="$2"; shift 2;;
    --app-http-port) APP_HTTP_PORT_ARG="$2"; shift 2;;
    --debug) DEBUG="1"; set -x; shift;;
    -h|--help) usage; exit 0;;
    *) msg_error "Unbekannte Option: $1"; usage; exit 1;;
  esac
done

# ---------------------------------------------------------------------------
# Domain-Modus validieren (offizielle Mobile-App braucht öffentlich vertrautes Zertifikat)
# ---------------------------------------------------------------------------
normalize_domain() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^[a-z]+://##; s#/+$##'
}
valid_domain() {
  [[ "$1" == *.* && "$1" != *' '* ]]
}
APP_DOMAIN=""
DNS_PROVIDER=""
APP_HTTP_PORT="$APP_HTTP_PORT_ARG"
if [[ -n "$DOMAIN_ARG" ]]; then
  APP_DOMAIN="$(normalize_domain "$DOMAIN_ARG")"
  valid_domain "$APP_DOMAIN" || { msg_error "--domain sieht nicht wie einen DNS-Namen aus: '$APP_DOMAIN'"; exit 1; }
  case "$DNS_PROVIDER_ARG" in
    duckdns|cloudflare) DNS_PROVIDER="$DNS_PROVIDER_ARG";;
    "") DNS_PROVIDER="duckdns";;
    *) msg_error "Unbekannter --dns-provider '$DNS_PROVIDER_ARG' (erlaubt: duckdns, cloudflare)."; exit 1;;
  esac
  [[ -n "$DNS_TOKEN_ARG" ]] || { msg_error "--domain benötigt --dns-token (DuckDNS-Token bzw. Cloudflare-API-Token)."; exit 1; }
fi
if [[ -n "$APP_HTTP_PORT" ]] && ! [[ "$APP_HTTP_PORT" =~ ^[0-9]+$ ]]; then
  msg_error "--app-http-port muss numerisch sein (z.B. 8081)."; exit 1
fi

# ---------------------------------------------------------------------------
# Interaktive Abfrage (nur wenn Flags/Env nichts gesetzt haben UND ein Terminal
# da ist): Domain für die Mobile-App + optional Plain-HTTP-Fallback. Enter =
# überspringen. NONINTERACTIVE=1 unterdrückt die Abfrage (CI/Pipes: kein TTY).
# Läuft vor den Host-Prüfungen, damit der Einzeiler sofort geführt durchgeht.
# ---------------------------------------------------------------------------
if [[ -z "$APP_DOMAIN" && "${NONINTERACTIVE:-0}" != "1" ]] && { [[ -t 0 ]] || [[ -t 2 ]]; }; then
  echo ""
  msg_info "Mobile-App: die offizielle App (iOS-TestFlight) verbindet sich nur mit öffentlich"
  msg_info "vertrautem Zertifikat. Gratis-Subdomain auf https://www.duckdns.org anlegen und hier"
  msg_info "eintragen – der Server bleibt LAN-only (DNS-01-Challenge, kein Port-Forwarding)."
  ASK_DOMAIN=""
  printf '%s' "  Domain eintragen (z.B. endurain.duckdns.org, Enter = überspringen): "
  read -r ASK_DOMAIN </dev/tty || ASK_DOMAIN=""
  ASK_DOMAIN="${ASK_DOMAIN// }"
  while [[ -n "$ASK_DOMAIN" ]]; do
    APP_DOMAIN="$(normalize_domain "$ASK_DOMAIN")"
    if valid_domain "$APP_DOMAIN"; then break; fi
    APP_DOMAIN=""
    msg_warn "'$ASK_DOMAIN' sieht nicht wie ein DNS-Name aus (Beispiel: endurain.duckdns.org)."
    printf '%s' "  Domain (Enter = überspringen): "
    read -r ASK_DOMAIN </dev/tty || ASK_DOMAIN=""
    ASK_DOMAIN="${ASK_DOMAIN// }"
  done
  if [[ -n "$APP_DOMAIN" ]]; then
    echo "  DNS-Provider für die Zertifikats-Challenge: [1] duckdns (Default)  [2] cloudflare"
    printf '%s' "  Provider [1]: "
    ASK_PROV=""
    read -r ASK_PROV </dev/tty || ASK_PROV=""
    case "${ASK_PROV// }" in
      2|cloudflare) DNS_PROVIDER="cloudflare";;
      *)            DNS_PROVIDER="duckdns";;
    esac
    _TOKEN_LABEL="DuckDNS-Token"
    [[ "$DNS_PROVIDER" == "cloudflare" ]] && _TOKEN_LABEL="Cloudflare-API-Token (Zone:Read + DNS:Edit)"
    printf '%s' "  $_TOKEN_LABEL (Eingabe versteckt): "
    ASK_TOKEN=""
    read -rs ASK_TOKEN </dev/tty || ASK_TOKEN=""
    echo ""
    if [[ -z "${ASK_TOKEN// }" ]]; then
      msg_warn "Kein Token eingegeben → Domain-Modus übersprungen (self-signed-Modus)."
      APP_DOMAIN=""
      DNS_PROVIDER=""
    else
      DNS_TOKEN_ARG="${ASK_TOKEN// }"
      if [[ "$DNS_PROVIDER" == "cloudflare" ]]; then
        printf '%s' "  Cloudflare Zone-ID (optional, Enter = automatisch ermitteln): "
        ASK_ZONE=""
        read -r ASK_ZONE </dev/tty || ASK_ZONE=""
        CF_ZONE_ID_ARG="${ASK_ZONE// }"
      fi
      msg_ok "Domain-Modus aktiv: $APP_DOMAIN ($DNS_PROVIDER) – App verbindet sich nach der Installation."
    fi
  fi
  if [[ -z "$APP_DOMAIN" && -z "$APP_HTTP_PORT" ]]; then
    printf '%s' "  Ohne Domain: Plain-HTTP-Fallback für die Mobile-App aktivieren? Port (z.B. 8081, Enter = nein): "
    ASK_HTTP=""
    read -r ASK_HTTP </dev/tty || ASK_HTTP=""
    ASK_HTTP="${ASK_HTTP// }"
    if [[ "$ASK_HTTP" =~ ^[0-9]+$ ]]; then
      APP_HTTP_PORT="$ASK_HTTP"
    fi
  fi
fi

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
# Domain-Modus: ENDURAIN_HOST (Backend-Links/SSO) auf die Domain, nicht die IP
if [[ -n "$APP_DOMAIN" ]]; then
  ENDURAIN_HOST="https://${APP_DOMAIN}"
  msg_info "Domain-Modus: $APP_DOMAIN (DNS-01 über $DNS_PROVIDER, A-Record -> $CT_IP)"
else
  ENDURAIN_HOST="https://${CT_IP}"
fi

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
APP_DOMAIN="$APP_DOMAIN"
DNS_PROVIDER="$DNS_PROVIDER"
DNS_TOKEN="$DNS_TOKEN_ARG"
CF_ZONE_ID="$CF_ZONE_ID_ARG"
APP_HTTP_PORT="$APP_HTTP_PORT"

echo "[PROV] apt update ..."
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
# pct exec liefert ein minimales PATH ohne /usr/local/bin — dort liegt aber uv.
export PATH="/usr/local/bin:/usr/local/sbin:\$PATH"
# Altlast entfernen: defektes Cloudsmith-Caddy-Apt-Repo (402 Payment Required)
# aus älterem Installer-Run — sonst scheitert jedes apt-get update.
rm -f /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg
apt-get update -qq
apt-get install -y -qq curl wget git sudo openssl ca-certificates build-essential \
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

# --- Service-User + Verzeichnisse ---
id -u "$APP_USER" >/dev/null 2>&1 || useradd -r -m -d "/home/$APP_USER" -s /bin/bash "$APP_USER"
mkdir -p "\$DATA_BASE/data" "\$DATA_BASE/logs"
chown -R "$APP_USER:$APP_USER" "\$DATA_BASE"

# --- App-Code (Clone oder Pull = idempotent) ---
# /opt/endurain gehört APP_USER, Provision läuft als root → git braucht safe.directory.
git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "\$APP_DIR" \
  || git config --global --add safe.directory "\$APP_DIR"
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

# --- uv (deterministisch gepinnt auf die pyproject.toml-Version) ---
# WICHTIG: steht bewusst NACH dem App-Code-Pull – sonst wird die Pinne aus der
# ALTEN Code-Version gelesen (Fehlbild: Re-Run las uv 0.12.23 stehen, während
# Upstream auf 0.12.24 gegangen war → "Required uv version ==0.12.24" in uv sync).
# Operator-Präfixe (==, >= …) werden abgestreift – Release-Tag und Versions-Check
# brauchen die nackte Version. Primär: GitHub-Release-Tarball; Fallback:
# astral.sh-VERSIONIERTE install.sh (die unversionierte lud mal 0.13.0 statt der
# gepinnten Version und landete nicht im PATH).
UV_WANT="0.12.24"
if [[ -f "\$APP_DIR/backend/pyproject.toml" ]]; then
  _uv_want="\$(grep -Po 'required-version\\s*=\\s*\"\\K[^\"]+' "\$APP_DIR/backend/pyproject.toml" 2>/dev/null || true)"
  _uv_want="\$(printf '%s' "\${_uv_want:-}" | sed -E 's/^[=<>!~^]+//' | tr -d '[:space:]')"
  [[ -n "\${_uv_want:-}" ]] && UV_WANT="\$_uv_want"
fi
if ! command -v uv >/dev/null 2>&1 || ! uv --version 2>/dev/null | grep -q "\$UV_WANT"; then
  echo "[PROV] installiere uv \$UV_WANT ..."
  # Karteileiche aus fehlgeschlagenem install.sh-Versuch (falsche Version, nicht im PATH)
  rm -f /root/.local/bin/uv /root/.local/bin/uvx 2>/dev/null || true
  if ! curl -LsSf "https://github.com/astral-sh/uv/releases/download/\${UV_WANT}/uv-x86_64-unknown-linux-gnu.tar.gz" -o /tmp/uv.tgz \
    || ! tar xzf /tmp/uv.tgz -C /tmp \
    || ! install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv; then
    echo "[PROV] Direkt-Download fehlgeschlagen, Fallback: versionierte install.sh ..."
    # ||-Abfangen nötig: unter set -euo pipefail würde ein fehlender Fallback-Download
    # das Script sonst ohne die klare Fehlermeldung der Verifikation darunter abbrechen.
    curl -LsSf "https://astral.sh/uv/\${UV_WANT}/install.sh" | sh >/dev/null \
      || echo "[PROV] WARNUNG: Fallback-Install fehlgeschlagen – Details in der Verifikation unten."
    export PATH="\$HOME/.local/bin:\$HOME/.cargo/bin:\$PATH"
    _uv_bin="\$(command -v uv 2>/dev/null || find /root/.local /root/.cargo /usr/local -name uv -type f 2>/dev/null | head -n1 || true)"
    [[ -n "\${_uv_bin:-}" ]] && ln -sf "\$_uv_bin" /usr/local/bin/uv
  fi
  rm -rf /tmp/uv.tgz /tmp/uv-x86_64-unknown-linux-gnu
  hash -r 2>/dev/null || true
fi
# Früh und laut scheitern, statt sich erst tief im uv sync zu verheddern:
if ! command -v uv >/dev/null 2>&1 || ! uv --version 2>/dev/null | grep -q "\$UV_WANT"; then
  echo "[PROV] FEHLER: uv ist nicht Version \$UV_WANT (gefunden: \$(command -v uv 2>/dev/null || echo fehlt) → \$(uv --version 2>/dev/null || echo '-'))."
  echo "[PROV] Manuell: curl -LsSf https://github.com/astral-sh/uv/releases/download/\${UV_WANT}/uv-x86_64-unknown-linux-gnu.tar.gz -o /tmp/uv.tgz && tar xzf /tmp/uv.tgz -C /tmp && install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv"
  exit 1
fi
echo "[PROV] uv=\$(uv --version) (pyproject-Pinne: \$UV_WANT)"

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
# DB-Encoding prüfen: SQL_ASCII lässt psycopg3 bytes statt str liefern →
# Upstream-Crash in SQLAlchemy (_get_server_version_info), Crash-Loop.
# Nur SQL_ASCII- oder fehlende DBs als UTF8 (template0, C.UTF-8) neu anlegen;
# existierende UTF8-DBs (ggf. mit Nutzdaten) werden nie angefasst.
DB_ENC="\$(su postgres -c "psql -Atc \"SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='\$PG_DB_NAME'\"" | tr -d '[:space:]')"
if [[ "\$DB_ENC" == "SQL_ASCII" ]]; then
  echo "[PROV] DB-Encoding SQL_ASCII erkannt -> lege DB als UTF8 neu an (Installer-DB: App konnte nie verbinden, keine Nutzdaten möglich) ..."
  su postgres -c "psql -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='\$PG_DB_NAME' AND pid <> pg_backend_pid();\"" || true
  su postgres -c "psql -c \"DROP DATABASE \$PG_DB_NAME\""
  su postgres -c "psql -c \"CREATE DATABASE \$PG_DB_NAME OWNER \$PG_DB_USER ENCODING 'UTF8' LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8' TEMPLATE template0\""
elif [[ -z "\$DB_ENC" ]]; then
  su postgres -c "psql -c \"CREATE DATABASE \$PG_DB_NAME OWNER \$PG_DB_USER ENCODING 'UTF8' LC_COLLATE 'C.UTF-8' LC_CTYPE 'C.UTF-8' TEMPLATE template0\""
else
  echo "[PROV] DB-Encoding ist \$DB_ENC - OK."
fi
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
# 0.20.x: RATE_LIMIT_STORAGE_URI/AUTH_SECURITY_STORAGE_URI sind entfernt – die App
# verweigert sonst den Start (check_deprecated_env_vars). Redis-State ist jetzt die
# optionale 'distributed'-Extra-Gruppe (uv sync --extra distributed + REDIS_URL);
# redis-py ist im Default-Venv NICHT enthalten → mit REDIS_URL bräuchte der Start
# 'redis' prerequisite. Für den lokalen Einzelknoten gilt upstreams Default memory://:
# bewusst KEINE REDIS_URL-Zeile setzen.
# Redis-server bleibt installiert/aktiv (unkritisch, für späteren Distributed-Modus).

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

# --- TLS-Zertifikat: Let's Encrypt via DNS-01 (Mobile-App-tauglich) oder self-signed ---
# Die offizielle Mobile-App (iOS-TestFlight/Android) akzeptiert KEINE self-signed
# Zertifikate und keine als Profil installierten CAs (kein badCertificateCallback in
# endurain-flutter, vgl. endurain-project/endurain#727). Weg ohne Port-Forwarding:
# DNS-01-Challenge — der A-Record der Domain zeigt einfach auf die LAN-IP.
CERT_DIR="/etc/caddy/certs"
if [[ -n "\$APP_DOMAIN" ]]; then
  echo "[PROV] Domain-Modus: hole Let's-Encrypt-Zertifikat für \$APP_DOMAIN (DNS-01 via \$DNS_PROVIDER, kein Port-Forwarding) ..."
  apt-get install -y -qq cron >/dev/null 2>&1 || true
  systemctl enable --now cron >/dev/null 2>&1 || true
  if [[ ! -x /root/.acme.sh/acme.sh ]]; then
    # Halbe Klone aus unterbrochenen Läufen entfernen, sonst scheitert der Clone für immer
    rm -rf /root/.acme.sh
    git clone --depth 1 https://github.com/acmesh-official/acme.sh /root/.acme.sh
  fi
  ACME="/root/.acme.sh/acme.sh"
  case "\$DNS_PROVIDER" in
    duckdns)    export DuckDNS_Token="\$DNS_TOKEN"; ACME_DNS="dns_duckdns";;
    cloudflare) export CF_Token="\$DNS_TOKEN";   ACME_DNS="dns_cf";;
    *) echo "[PROV] Unbekannter DNS-Provider: \$DNS_PROVIDER"; exit 1;;
  esac
  [[ -n "\${CF_ZONE_ID:-}" ]] && export CF_Zone_ID="\$CF_ZONE_ID"
  # DuckDNS: A-Record direkt auf die Container-IP setzen (Domain löst im LAN auf den Server auf,
  # obwohl der Server nicht aus dem Internet erreichbar ist — DNS-01 braucht nur TXT-Records).
  if [[ "\$DNS_PROVIDER" == "duckdns" && "\$APP_DOMAIN" == *.duckdns.org ]]; then
    DUCK_SUB="\${APP_DOMAIN%.duckdns.org}"
    echo "[PROV] setze DuckDNS-A-Record: \$APP_DOMAIN -> \$CT_IP ..."
    DUCK_RET="\$(curl -fs --max-time 30 "https://www.duckdns.org/update?domains=\${DUCK_SUB}&token=\${DNS_TOKEN}&ip=\${CT_IP}" || true)"
    if [[ "\$DUCK_RET" == "OK" ]]; then
      echo "[PROV] DuckDNS-A-Record aktuell (\$APP_DOMAIN -> \$CT_IP)."
    else
      echo "[PROV] WARNUNG: DuckDNS-Update lieferte '\${DUCK_RET:-leer}' – A-Record notfalls manuell auf \$CT_IP setzen."
    fi
  fi
  set +e
  "\$ACME" --issue --dns "\$ACME_DNS" -d "\$APP_DOMAIN" --keylength ec-256 --server letsencrypt
  ACME_RC=\$?
  set -e
  # Exit 0 = ausgestellt, Exit 2 = 'Domains not changed' (Zertifikat existiert schon) – beides OK.
  if [[ \$ACME_RC -ne 0 && \$ACME_RC -ne 2 ]]; then
    echo "[PROV] FEHLER: acme.sh --issue scheiterte (Exit \$ACME_RC) – Domain/Token prüfen."
    echo "[PROV] Log: tail -n 50 /root/.acme.sh/acme.sh.log"
    exit 1
  fi
  mkdir -p "\$CERT_DIR"
  # reloadcmd nicht-fatal: acme.sh führt ihn SOFORT aus – hier existiert Caddy noch gar nicht
  # (TLS-Sektion vor Caddy-Sektion); der echte Reload passiert gleich in der Caddy-Sektion.
  # Ohne Abfangen failt acme.sh --install-cert ("Reload error") und reißt die Provision mit.
  "\$ACME" --install-cert -d "\$APP_DOMAIN" --ecc \
    --fullchain-file "\$CERT_DIR/endurain.fullchain.pem" \
    --key-file "\$CERT_DIR/endurain.key.pem" \
    --reloadcmd "systemctl reload caddy 2>/dev/null || systemctl restart caddy 2>/dev/null || true"
  chmod 600 "\$CERT_DIR/endurain.key.pem"
  echo "[PROV] Let's-Encrypt-Zertifikat installiert (Auto-Renewal: acme.sh-cron + Caddy-reload)."
fi

# --- Caddy HTTPS-Reverse-Proxy (v2.11.7; Domain-Modus: LE-Zert, sonst tls internal) ---
# Hinweis: NICHT via apt/Cloudsmith — dl.cloudsmith.io antwortet mit 402 Payment Required.
# Stattdessen deterministischer Binary-Download von GitHub Releases + eigene systemd-Unit.
CADDY_WANT="2.11.7"
if ! command -v caddy >/dev/null 2>&1 || ! caddy version 2>/dev/null | grep -q "\$CADDY_WANT"; then
  echo "[PROV] installiere Caddy \$CADDY_WANT ..."
  curl -LsSf "https://github.com/caddyserver/caddy/releases/download/v\${CADDY_WANT}/caddy_\${CADDY_WANT}_linux_amd64.tar.gz" -o /tmp/caddy.tgz \
    && tar xzf /tmp/caddy.tgz -C /tmp caddy \
    && install -m 0755 /tmp/caddy /usr/local/bin/caddy
  rm -rf /tmp/caddy.tgz /tmp/caddy
  hash -r 2>/dev/null || true
fi
echo "[PROV] caddy=\$(caddy version)"
mkdir -p /etc/caddy
if [[ -n "\$APP_DOMAIN" ]]; then
cat > /etc/caddy/Caddyfile <<CADDY_EOF
https://\$APP_DOMAIN {
	tls \$CERT_DIR/endurain.fullchain.pem \$CERT_DIR/endurain.key.pem
	reverse_proxy 127.0.0.1:8080
}

# Fallback: Direktzugriff per IP im Browser (self-signed, einmal bestätigen)
https://\$CT_IP {
	tls internal
	reverse_proxy 127.0.0.1:8080
}

http://\$CT_IP, http://\$APP_DOMAIN {
	redir https://{host}{uri}
}
CADDY_EOF
else
cat > /etc/caddy/Caddyfile <<CADDY_EOF
https://\$CT_IP {
	tls internal
	reverse_proxy 127.0.0.1:8080
}

http://\$CT_IP {
	redir https://{host}{uri}
}
CADDY_EOF
fi
# Optional: Plain-HTTP-Listener als Mobile-App-Fallback (App: Protokoll http, Host <CT-IP>:<PORT>)
if [[ -n "\$APP_HTTP_PORT" ]]; then
cat >> /etc/caddy/Caddyfile <<CADDY_HTTP_EOF

http://:\$APP_HTTP_PORT {
	reverse_proxy 127.0.0.1:8080
}
CADDY_HTTP_EOF
echo "[PROV] App-HTTP-Fallback aktiv auf Port \$APP_HTTP_PORT (Plain-HTTP, nur für Mobile-App ohne Domain)."
fi
cat > /etc/systemd/system/caddy.service <<CADDYUNIT_EOF
[Unit]
Description=Caddy HTTPS-Reverse-Proxy (Endurain)
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --force
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
CADDYUNIT_EOF
systemctl daemon-reload
/usr/local/bin/caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl enable --now caddy
/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null || systemctl restart caddy
if [[ -n "\$APP_DOMAIN" ]]; then
  echo "[PROV] Caddy-HTTPS aktiv: https://\$APP_DOMAIN (Let's Encrypt, Mobile-App-tauglich) + https://\$CT_IP (self-signed-Fallback)."
else
  echo "[PROV] Caddy-HTTPS auf https://\$CT_IP aktiv (self-signed, Browser-Warnung einmal bestätigen)."
fi

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
  # "activating" ist beim Erststart normal (Import + Migrationen dauern) —
  # Bereitschaft entscheidet das HTTP-Polling danach.
  if [[ "$state" == "active" || "$state" == "activating" ]]; then
    msg_ok "Service läuft/startet (systemctl is-active $svc = $state)."
  else
    msg_error "Service $svc NICHT aktiv (Status: $state)."
    msg_error "--- journalctl -u $svc (letzte 50 Zeilen, für Diagnose) ---"
    pct exec "$CT_ID" -- journalctl -u "$svc" -n 50 --no-pager || true
    msg_error "Logs: pct exec $CT_ID -- journalctl -u $svc -n 100"
    exit 1
  fi
done

if pct exec "$CT_ID" -- curl -fs "http://localhost:${APP_PORT}/api/v1/about" >/dev/null 2>&1; then
  msg_ok "Backend antwortet (HTTP 200 auf localhost:${APP_PORT}/api/v1/about)."
else
  # Erster Start braucht DB-Migrationen + Startup-Syncs → pollen statt einmalig zu prüfen.
  msg_info "Backend noch nicht bereit – warte bis zu 3 Minuten (Erststart inkl. Migrationen) ..."
  BACKEND_OK=0
  for _i in $(seq 1 36); do
    sleep 5
    if pct exec "$CT_ID" -- curl -fs "http://localhost:${APP_PORT}/api/v1/about" >/dev/null 2>&1; then
      BACKEND_OK=1
      break
    fi
    if (( _i % 6 == 0 )); then msg_info "… noch kein Backend nach $((_i*5))s, warte weiter ..."; fi
  done
  if [[ "$BACKEND_OK" -eq 1 ]]; then
    msg_ok "Backend antwortet (HTTP 200 auf localhost:${APP_PORT}/api/v1/about)."
  else
    msg_error "Backend antwortet NICHT auf localhost:${APP_PORT}."
    msg_error "--- journalctl -u $APP (letzte 50 Zeilen, für Diagnose) ---"
    pct exec "$CT_ID" -- journalctl -u "$APP" -n 50 --no-pager || true
    msg_error "--- Neustart-Zähler ---"
    pct exec "$CT_ID" -- systemctl show "$APP" -p NRestarts --no-pager || true
    msg_error "Vollständiges Host-Log: $LOG_FILE"
    exit 1
  fi
fi

# Hinweis: vom Host gegen die CT-IP prüfen = exakt der Pfad, den LAN-Clients
# und Browser nutzen (SNI=CT-IP, Caddy-Zertifikat, Proxy, Backend). In-CT per
# --resolve scheitert reproduzierbar auf TLS-Ebene und wird nicht verwendet.
# Polling: Restarts/Reloads aus der Provisionierung können einzelne Versuche
# ins Leere laufen lassen.
HTTPS_OK=0
HTTPS_LAST="n/a"
for _j in $(seq 1 36); do
  HTTPS_OUT="$(curl -k -s -o /dev/null -w "%{http_code}" "https://${CT_IP}/api/v1/about" 2>&1)"
  HTTPS_EC=$?
  HTTPS_LAST="exit=${HTTPS_EC} http=${HTTPS_OUT}"
  if [[ $HTTPS_EC -eq 0 && "$HTTPS_OUT" == "200" ]]; then
    HTTPS_OK=1
    break
  fi
  sleep 5
  if (( _j % 6 == 0 )); then msg_info "… noch kein HTTPS nach $((_j*5))s (letzter Versuch: $HTTPS_LAST), warte weiter ..."; fi
done
if [[ "$HTTPS_OK" -eq 1 ]]; then
  msg_ok "HTTPS-Proxy antwortet (HTTP 200 via Caddy auf https://${CT_IP}/api/v1/about, -k wegen self-signed)."
else
  msg_error "HTTPS-Proxy antwortet NICHT (letzter Versuch: $HTTPS_LAST)."
  msg_error "Zum manuellen Nachstellen: curl -k -o /dev/null -w \"HTTP:%{http_code}\" \"https://${CT_IP}/api/v1/about\""
  msg_error "--- journalctl -u caddy (letzte 50 Zeilen, für Diagnose) ---"
  pct exec "$CT_ID" -- journalctl -u caddy -n 50 --no-pager || true
  msg_error "--- Listener (443/80/8080) ---"
  pct exec "$CT_ID" -- ss -tlnp 2>/dev/null | grep -E ':443|:80|:8080' || true
  msg_error "Backend direkt prüfen: pct exec $CT_ID -- journalctl -u $APP -n 100"
  exit 1
fi

# Domain-Modus: App-taugliches HTTPS verifizieren – OHNE -k und OHNEZA-Zertifikatswarnung,
# exakt der Pfad der Mobile-App (TLS-Handshake + öffentlich vertraute Chain müssen passen).
if [[ -n "$APP_DOMAIN" ]]; then
  msg_info "Prüfe https://${APP_DOMAIN} mit öffentlich vertrautem Zertifikat (ohne -k) ..."
  DOM_OK=0
  DOM_LAST="n/a"
  for _k in $(seq 1 12); do
    DOM_OUT="$(curl -s --resolve "${APP_DOMAIN}:443:${CT_IP}" -o /dev/null -w "%{http_code}" "https://${APP_DOMAIN}/api/v1/about" 2>&1)"
    DOM_EC=$?
    DOM_LAST="exit=${DOM_EC} http=${DOM_OUT}"
    if [[ $DOM_EC -eq 0 && "$DOM_OUT" == "200" ]]; then
      DOM_OK=1
      break
    fi
    sleep 5
  done
  if [[ "$DOM_OK" -eq 1 ]]; then
    msg_ok "Mobile-App-tauglich: https://${APP_DOMAIN}/api/v1/about → HTTP 200 ohne -k (gültiges Zertifikat)."
    ISSUER="$(echo | openssl s_client -connect "$CT_IP:443" -servername "$APP_DOMAIN" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)"
    [[ -n "$ISSUER" ]] && msg_ok "Zertifikat-Aussteller: ${ISSUER#issuer=}"
  else
    msg_error "https://${APP_DOMAIN} antwortet NICHT mit gültigem Zertifikat (letzter Versuch: $DOM_LAST)."
    msg_error "Das ist der Pfad der Mobile-App – Zertifikatsausstellung prüfen:"
    msg_error "  pct exec $CT_ID -- tail -n 50 /root/.acme.sh/acme.sh.log"
    msg_error "  pct exec $CT_ID -- ls -la /etc/caddy/certs/"
    exit 1
  fi
  # DNS-View vom Host: löst die Domain schon auf die Container-IP auf? (nur Warnung –
  # Propagation/Split-DNS kann nachziehen, --resolve-Check oben ist der harte Beweis)
  RESOLVED_IP="$(getent hosts "$APP_DOMAIN" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
  if [[ -n "$RESOLVED_IP" && "$RESOLVED_IP" != "$CT_IP" ]]; then
    msg_warn "DNS: $APP_DOMAIN löst aktuell auf $RESOLVED_IP auf, nicht auf $CT_IP (Propagation/Split-DNS)."
    msg_warn "Handy im LAN muss die Domain auf $CT_IP auflösen können (DuckDNS-A-Record setzt der Installer automatisch)."
  else
    msg_ok "DNS: $APP_DOMAIN → ${RESOLVED_IP:-$CT_IP}"
  fi
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
if [[ -n "$APP_DOMAIN" ]]; then
echo "  Web UI       : https://$APP_DOMAIN  (Let's Encrypt – gültiges Zertifikat)"
echo "  Alt          : https://$CT_IP (self-signed-Fallback, Browser-Warnung)"
echo "  Mobile-App   : Protokoll https, Server-Adresse: $APP_DOMAIN"
echo "                 (offizielle App/TestFlight verbindet sich ohne Zertifikats-Install)"
else
echo "  Web UI       : https://$CT_IP  (self-signed – Browser-Warnung einmal bestätigen)"
echo "  Mobile-App   : mit self-signed NICHT möglich! README: 'Mobile-App verbinden'"
echo "                 (Weg A: --domain + DuckDNS | Weg B: --app-http-port 8081)"
fi
if [[ -n "$APP_HTTP_PORT" ]]; then
echo "  App-Fallback : http://$CT_IP:$APP_HTTP_PORT (Plain-HTTP; App: Protokoll http,"
echo "                 Server-Adresse: $CT_IP:$APP_HTTP_PORT – nur im Heimnetz sinnvoll)"
fi
echo "  API-Check    : https://$CT_IP/api/v1/about"
echo "  Erst-Login   : admin / admin (Upstream-Default – sofort ändern!)"
echo "  Registrieren : als Admin einloggen → Settings → Server settings → signup einschalten"
echo "  Nutzung      : ohne Strava möglich (App-Recording, Datei-Upload, optional Sync) – s. README"
echo "  HTTP         : http://$CT_IP → Redirect auf HTTPS"
if [[ "${GENERATED_PW:-0}" -eq 1 ]]; then
echo "  CT-Root-PW   : $PASSWORD_ARG (nur dieses Mal angezeigt!)"
fi
if [[ -n "$APP_DOMAIN" ]]; then
echo "  Update       : bash endurain.sh --ctid $CT_ID --domain $APP_DOMAIN --dns-provider $DNS_PROVIDER --dns-token <TOKEN>"
else
echo "  Update       : bash endurain.sh --ctid $CT_ID   (idempotent)"
fi
echo "  Deinstall    : pct stop $CT_ID && pct destroy $CT_ID"
echo "  Logs (Host)  : $LOG_FILE"
echo "  Logs (CT)    : pct exec $CT_ID -- journalctl -u $APP -n 100"
if [[ -n "$APP_DOMAIN" ]]; then
echo "  Zertifikat   : Let's Encrypt für $APP_DOMAIN (DNS-01 via $DNS_PROVIDER),"
echo "                 Auto-Renewal über acme.sh-cron im Container."
echo "                 Server bleibt LAN-only – kein Port-Forwarding nötig."
echo "                 Bei IP-Wechsel: Installer erneut laufen lassen (setzt DuckDNS-A-Record neu)."
else
echo "  Hinweis      : Zertifikat ist self-signed (Caddy tls internal)."
echo "                 Bei IP-Wechsel (DHCP): Router-Reservierung empfohlen,"
echo "                 sonst Installer-Update erneut laufen lassen."
fi
echo "                 Strava-Sync braucht eine öffentliche https-Domain"
echo "                 (im Domain-Modus bereits erfüllt, siehe README)."
echo "══════════════════════════════════════════════════════════"
