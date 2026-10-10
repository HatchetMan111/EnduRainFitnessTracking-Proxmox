# Endurain auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Repos): `https://github.com/endurain-project/endurain`
> Dieses Repo enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit.
> Die App läuft nativ (Python/FastAPI via `uv` (nur localhost:8080) + Vue-3-SPA via Node-24-Build, PostgreSQL + Redis lokal,
> Caddy als HTTPS-Reverse-Proxy mit self-signed Zertifikat auf :443, ohne Docker) – vollständig lokal, keine Cloud nötig.

## Einzeiler (auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/EnduRainFitnessTracking-Proxmox/main/install/endurain.sh)"
```

> Installer-Repo: `HatchetMan111/EnduRainFitnessTracking-Proxmox`.

Anpassungen per Umgebungsvariable oder Flag (ID immer **nächste freie**, außer gesetzt):

```bash
CT_ID=150 CORES=2 RAM=4096 DISK=8 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/EnduRainFitnessTracking-Proxmox/main/install/endurain.sh)"
bash endurain.sh --ctid 150 --cores 2 --memory 4096 --disk 8 --bridge vmbr0 --storage local-lvm
bash endurain.sh --debug   # = bash -x, komplette Fehlermeldungskette + Log unter /tmp/endurain-install-*.log
```

> Die systemd-Unit liegt unter `systemd/endurain.service` desselben Repos und wird
> vom Installer von dort geladen (Fallback: Inline-Unit im Script).

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `endurain` |
| Zweck | Self-hosted Fitness-Tracking (Strava-Alternative): Aktivitäten via .gpx/.tcx/.fit, Strava-/Garmin-Sync, Karten, Statistiken – volle Datenhoheit |
| Tech-Stack | Python 3.13/FastAPI (uv, `uvicorn main:app` nur auf `127.0.0.1:8080` mit `--proxy-headers`) + Vue 3 SPA (`npm ci` + `npm run build` nach `/opt/endurain/frontend/dist`) + PostgreSQL (+PostGIS) + Redis lokal + Caddy v2.11.7 (Binary von GitHub Releases, `tls internal`, self-signed, `:443`, HTTP→HTTPS-Redirect) |
| GitHub-Repo (Upstream) | `https://github.com/endurain-project/endurain` |
| Web UI | `https://<LXC-IP>` (HTTP auf Port 80 leitet um; Health: `/api/v1/about`; Browser-Warnung wegen self-signed einmal bestätigen) |
| Standard-Ressourcen | 2 vCPU / 4096 MB RAM / 8 GB Disk (Frontend-Build + Backend + DB brauchen das; offizielles `ct/endurain.sh`: 2/4096/5) |
| CT-ID | immer die **nächste freie ID** (`pvesh get /cluster/nextid`), außer `--ctid` gesetzt |
| Template | `debian-13-standard` (neuestes auf Storage `local`, Python 3.13 nativ) |
| LXC-Features | **unprivilegiert** (`--unprivileged 1`), `nesting=1`, `onboot: 1` |

Das Skript (`set -euo pipefail`, idempotent, `trap ERR` mit Befehl+Zeile+Exit-Code):
1. prüft Host/Tools, nimmt die nächste freie CT-ID, erkennt RootFS-Storage
   (bevorzugt `local-lvm`), lädt das neueste `debian-13-standard`-Template falls nötig,
2. erstellt den LXC `endurain` (`onboot: 1`, unprivilegiert),
3. installiert im Container Node 24 + uv (gepinnt aus `pyproject.toml`) + PostgreSQL/PostGIS + Redis,
   legt User `endurain` an, klont/pullt Upstream nach `/opt/endurain`,
   schreibt `/opt/endurain/.env` (Secrets `DB_PASSWORD`/`SECRET_KEY`/`FERNET_KEY` werden generiert
   und bei Updates wiederverwendet), baut das Frontend, `uv sync --frozen --no-dev`,
   schreibt `endurain.service`, `systemctl enable --now endurain`,
4. installiert Caddy, schreibt `/etc/caddy/Caddyfile` für die aktuelle Container-IP
   (`tls internal`, Reverse-Proxy auf `127.0.0.1:8080`, Port-80-Redirect auf HTTPS),
5. verifiziert `systemctl is-active endurain` (+ postgresql + redis + caddy) + HTTP auf
   `localhost:8080/api/v1/about` **und** HTTPS durch den Proxy (`curl -k https://localhost/api/v1/about`)
   und gibt die finale URL + Container-IP aus.

Secrets-Hinweis: `FERNET_KEY` wird per Python-stdlib als valides urlsafe-base64 generiert
(Upstream validiert das Format und startet sonst nicht). `.env` hat `600` und gehört `endurain`.

Erwartete Schlussausgabe (Beispiel):

```text
[OK]    Service läuft (systemctl is-active endurain = active).
[OK]    HTTPS-Proxy antwortet (HTTP 200 via Caddy auf https://localhost/api/v1/about, -k wegen self-signed).

════════════════ INSTALLATION ERFOLGREICH ════════════════
  App          : Endurain – self-hosted Fitness-Tracking
  Container    : CT 100 (Hostname: endurain, unprivilegiert, onboot=1)
  Ressourcen   : 2 vCPU / 4096 MB RAM / 8 GB Disk
  Web UI       : https://192.168.1.100  (self-signed – Browser-Warnung einmal bestätigen)
  ...
  Log          : /tmp/endurain-install-2026-....log
══════════════════════════════════════════════════════════
```

## HTTPS / GPS-Aufzeichnung (wichtig!)

Ohne HTTPS geht im Browser kein Login (Upstream setzt im `production`-Modus `Secure`-Cookies:
*„Endurain must be served over HTTPS for login, session refresh, and SSO to work"*).
Darum läuft Caddy mit self-signed Zertifikat (`tls internal`) vor dem Backend, und das Backend
kennt den Proxy (`BEHIND_PROXY=true`, `TRUSTED_PROXIES=127.0.0.1`).

- **Browser:** Warnung „unsicher / self-signed" einmal bestätigen (oder die Caddy-CA aus
  `/root/.local/share/caddy/pki/authorities/local/root.crt` im Container ins System importieren).
- **Mobile-App (GPS-Runs wie bei Strava):** Die Aufzeichnung selbst braucht kein HTTPS
  (native App, offline-fähig) – aber **Login + Sync zum Server schon**. Ggf. muss das
  self-signed Zertifikat auf dem Handy akzeptiert/installiert werden (Android: Nutzer-CA,
  iOS: Profil). App-Stand: Android in Entwicklung, iOS als TestFlight-Beta (siehe endurain.com).
- **Feste IP empfohlen:** Das Zertifikat wird auf die aktuelle Container-IP ausgestellt.
  Im Router eine DHCP-Reservierung für den LXC anlegen – nach einem IP-Wechsel sonst
  `bash endurain.sh --ctid <ID>` erneut laufen lassen (stellt Caddyfile + `.env` neu aus).
- **Grenze:** Strava-OAuth verlangt eine **öffentlich vertrauenswürdige** `https`-Domain –
  mit self-signed LAN-Zert geht der Strava-Sync nicht. Dafür bräuchtest du die
  „Domain + Caddy (Let's Encrypt)"-Variante. Garmin-Sync und Datei-Uploads (.gpx/.tcx/.fit)
  funktionieren im LAN auch so.

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active endurain postgresql redis-server caddy
curl -kfs https://<LXC-IP>/api/v1/about >/dev/null && echo WEB_UI_OK
```

## Update / Deinstall

```bash
bash endurain.sh --ctid 100            # Update: idempotent (git pull + rebuild + restart)
pct stop 100 && pct destroy 100       # Deinstall
```

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/endurain-install-*.log`.
- `bash endurain.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status endurain --no-pager`, `journalctl -u endurain -n 100`.
- DB-Encoding muss UTF8 sein (SQL_ASCII lässt psycopg3 bytes liefern → SQLAlchemy-Crash-Loop,
  erkennbar an `TypeError: cannot use a string pattern on a bytes-like object`).
  Prüfen: `pct exec <CT> -- su postgres -c "psql -Atc \"SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='enduraindb'\""`.
  Der Installer legt fehlende/SQL_ASCII-DBs automatisch als UTF8 neu an; bestehende UTF8-DBs tastet er nie an.
- Erster Start dauert: Alembic-Migrationen laufen beim ersten Boot automatisch.

## Dateien

- `install/endurain.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/endurain.service` – Uvicorn-Unit (nur `127.0.0.1:8080` mit `--proxy-headers`, `After=network-online.target postgresql+redis`, `Restart=always`; öffentlich ist nur Caddy auf `:443`).
