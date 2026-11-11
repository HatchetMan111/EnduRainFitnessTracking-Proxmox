# Endurain auf Proxmox – Einzeiler-Installation (Community-Scripts-Stil)

> Upstream-App (kein Teil dieses Repos): `https://github.com/endurain-project/endurain`
> Dieses Repo enthält **nur den Proxmox-Installer**: Install-Script + systemd-Unit.
> Die App läuft nativ (Python/FastAPI via `uv` (nur localhost:8080) + Vue-3-SPA via Node-24-Build, PostgreSQL + Redis lokal,
> Caddy als HTTPS-Reverse-Proxy auf :443, ohne Docker) – vollständig lokal, keine Cloud nötig.
> Zertifikat wahlweise self-signed (Default) oder **Let's Encrypt via DNS-01** (`--domain`) –
> letzteres macht die **offizielle Mobile-App (iOS-TestFlight)** verbindungsfähig, ohne Port-Forwarding.

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

# Mobile-App-tauglich (Let's Encrypt via DuckDNS, Server bleibt LAN-only – siehe "Mobile-App verbinden"):
bash endurain.sh --domain endurain.duckdns.org --dns-provider duckdns --dns-token <DUCKDNS-TOKEN>
# ... funktioniert auch als Env: DOMAIN=... DNS_PROVIDER=... DNS_TOKEN=... bash endurain.sh
```

**Interaktiv statt Flags:** Lässt du alle Domain-Flags weg und startest in einem Terminal,
fragt der Installer direkt ab (die Gratis-Subdomain + Token legst du vorher auf
[duckdns.org](https://www.duckdns.org) an – Schritt für Schritt in
[Weg A](#weg-a-empfohlen-domain--lets-encrypt-via-dns-01--server-bleibt-im-lan)):

1. **Domain** (z.B. `endurain.duckdns.org`, Enter = überspringen → self-signed-Modus),
2. **DNS-Provider** (1 = duckdns, 2 = cloudflare),
3. **Token** (Eingabe versteckt, landet nicht im Log),
4. falls übersprungen: ob der **Plain-HTTP-Fallback-Port** für die App aktiviert werden soll.

`NONINTERACTIVE=1` schaltet die Abfrage ab (Automatisierung/Pipes fragen ohnehin nicht).

> Die systemd-Unit liegt unter `systemd/endurain.service` desselben Repos und wird
> vom Installer von dort geladen (Fallback: Inline-Unit im Script).

| Eigenschaft | Wert |
|---|---|
| App-Name / Hostname | `endurain` |
| Zweck | Self-hosted Fitness-Tracking (Strava-Alternative): Aktivitäten via .gpx/.tcx/.fit, Strava-/Garmin-Sync, Karten, Statistiken – volle Datenhoheit |
| Tech-Stack | Python 3.13/FastAPI (uv, `uvicorn main:app` nur auf `127.0.0.1:8080` mit `--proxy-headers`) + Vue 3 SPA (`npm ci` + `npm run build` nach `/opt/endurain/frontend/dist`) + PostgreSQL (+PostGIS) + Redis (installiert; App-State läuft per Upstream-Default `memory://` im Prozess – Redis wäre erst für den Multi-Node-„distributed"-Modus relevant) + Caddy v2.11.7 (Binary von GitHub Releases, `:443`, HTTP→HTTPS-Redirect; Zertifikat: `tls internal` self-signed **oder** Let's Encrypt via acme.sh DNS-01) |
| GitHub-Repo (Upstream) | `https://github.com/endurain-project/endurain` |
| Web UI | `https://<LXC-IP>` (HTTP auf Port 80 leitet um; Health: `/api/v1/about`; Browser-Warnung wegen self-signed einmal bestätigen) – im Domain-Modus zusätzlich `https://<domain>` ohne Warnung |
| Mobile-App | self-signed: **geht nicht** (App akzeptiert keine self-signed Zertifikate) → Domain-Modus (`--domain`, Let's Encrypt via DNS-01) oder Plain-HTTP-Fallback (`--app-http-port 8081`) – siehe [Mobile-App verbinden](#mobile-app-verbinden-offizielle-app--ios-testflight) |
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
   (`tls internal`, Reverse-Proxy auf `127.0.0.1:8080`, Port-80-Redirect auf HTTPS);
   im Domain-Modus zusätzlich: acme.sh + Let's-Encrypt-Zert via DNS-01, DuckDNS-A-Record
   auf die Container-IP, Caddy-Site für die Domain (optional `--app-http-port` als App-Fallback),
5. verifiziert `systemctl is-active endurain` (+ postgresql + redis + caddy) + HTTP auf
   `localhost:8080/api/v1/about` **und** HTTPS durch den Proxy (`curl -k https://localhost/api/v1/about`);
   im Domain-Modus zusätzlich **ohne `-k`** gegen `https://<domain>` (der harte Beweis, dass die
   Mobile-App verbinden kann) + DNS-Check, und gibt die finale URL + Container-IP aus.

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

## HTTPS / Zertifikate (wichtig!)

Ohne HTTPS geht im Browser kein Login (Upstream setzt im `production`-Modus `Secure`-Cookies:
*„Endurain must be served over HTTPS for login, session refresh, and SSO to work"*).
Darum läuft Caddy vor dem Backend, und das Backend kennt den Proxy
(`BEHIND_PROXY=true`, `TRUSTED_PROXIES=127.0.0.1`). Zwei Modi:

- **Standard (ohne `--domain`):** Caddy mit self-signed Zertifikat (`tls internal`).
  Browser: Warnung einmal bestätigen. **Mobile-App: funktioniert nicht** (siehe unten).
- **Domain-Modus (`--domain`):** Let's-Encrypt-Zertifikat via **DNS-01-Challenge** (acme.sh im
  Container, Auto-Renewal per cron). Der A-Record der Domain zeigt auf die **LAN-IP** des
  Containers – der Server bleibt komplett lokal, **kein Port-Forwarding**, kein Cloud-Zugriff.
  Browser **und** Mobile-App verbinden sich ohne Zertifikatswarnung. Bonus: erfüllt die
  Voraussetzung für Strava-OAuth (öffentlich vertrauenswürdige https-Domain); der Browser muss
  die Domain dafür erreichen können (im Heimnetz gegeben). Garmin-Sync und Datei-Uploads
  laufen unabhängig davon.

- **Feste IP empfohlen:** Das self-signed Zertifikat wird auf die aktuelle Container-IP
  ausgestellt, und im Domain-Modus zeigt der DNS-A-Record auf diese IP. Im Router eine
  DHCP-Reservierung für den LXC anlegen – nach einem IP-Wechsel den Installer erneut laufen
  lassen (setzt Caddyfile, `.env` und DuckDNS-A-Record neu).

## Mobile-App verbinden (offizielle App / iOS-TestFlight)

**Warum es mit self-signed nicht geht:** Die offizielle Endurain-App
([endurain-flutter](https://github.com/endurain-project/endurain-flutter), iOS aktuell als
[TestFlight-Beta](https://testflight.apple.com/join/BjZ4DWPa), Android in Entwicklung) hat
**keinen** „self-signed akzeptieren"-Schalter (kein `badCertificateCallback` im App-Code) und
ignoriert auch als Profil/Nutzer-CA installierte Zertifikate – ein bekanntes, offenes Thema
([endurain#727](https://github.com/endurain-project/endurain/issues/727)). Die App akzeptiert
nur **öffentlich vertraute** Zertifikate (Let's Encrypt & Co.). Als Profil installierte
Caddy-CAs bringen der App nichts. Es gibt drei Wege:

### Weg A (empfohlen): Domain + Let's Encrypt via DNS-01 – Server bleibt im LAN

Gratis-Option **DuckDNS** (einmalig ca. 5 Minuten):

1. **DuckDNS einrichten:**
   - Auf [duckdns.org](https://www.duckdns.org) anmelden – geht über ein bestehendes
     Konto (GitHub, Google, Reddit, …), kein eigenes Passwort nötig.
   - Nach dem Login steht **ganz oben auf der Seite** dein persönlicher
     **Konto-Token** (lange Zeichenkette, daneben „copy") – den **kopierst du dir**,
     genau den fragt der Installer später ab (Eingabe versteckt).
   - Im Feld **„add domain"** oben einen Namen eintragen (z. B. `endurain`) und
     **add domain** klicken → deine Domain heißt komplett `endurain.duckdns.org`.
     Die dort angezeigte IP kannst du ignorieren – der Installer setzt den
     A-Record automatisch auf die Container-IP.
2. **Installer laufen lassen – mit Flags** (bei bestehendem CT einfach erneut laufen lassen = Update):

   ```bash
   bash endurain.sh --ctid <ID> --domain endurain.duckdns.org --dns-provider duckdns --dns-token <TOKEN>
   ```

   **Oder ohne Flags:** der Installer fragt dann interaktiv ab – in dieser Reihenfolge:

   ```text
   Domain eintragen (z.B. endurain.duckdns.org, Enter = überspringen): endurain.duckdns.org
   DNS-Provider für die Zertifikats-Challenge: [1] duckdns (Default)  [2] cloudflare
   Provider [1]: 1
   DuckDNS-Token (Eingabe versteckt): <einfügen, z.B. mit Rechtsklick/Shift+Einfg>
   ```

   Der Installer stellt automatisch das Let's-Encrypt-Zertifikat aus (DNS-01, braucht **keinen**
   offenen Port 80/443 im Router!) und **setzt den DuckDNS-A-Record auf die LAN-IP des
   Containers** – die Domain löst also im Heimnetz direkt auf deinen Server auf, von außen ist
   nichts erreichbar. Am Ende bestätigt die Zeile
   `Mobile-App-tauglich: https://endurain.duckdns.org/… → HTTP 200 ohne -k`, dass die App verbinden kann.
3. **In der App:** **Protokoll `https`**, Server-Adresse **`endurain.duckdns.org`**
   (ohne `https://` davor). Handy muss im Heimnetz sein (oder du richtest VPN/WireGuard ein).

Alternativ `--dns-provider cloudflare --dns-token <CF-API-Token>` (Token mit Zone:Read + DNS:Edit,
optional `--cf-zone-id`); dort den A-Record auf die LAN-IP selbst setzen (DNS-only, kein Proxy!).

Troubleshooting: liefert DuckDNS `KO` (der Installer bricht dann mit einer Schritt-für-Schritt-
Anleitung ab), stimmt fast immer das **Token nicht** oder die **Subdomain steht nicht im
DuckDNS-Konto** – auf duckdns.org einloggen, Token oben auf der Seite kopieren und prüfen, dass
die Subdomain in der Liste steht, dann den Installer erneut laufen lassen. Wer den A-Record selbst
verwaltet (Split-DNS): `DUCKDNS_SKIP_A_RECORD=1` überspringt das DuckDNS-Update.

### Weg B (Fallback ohne Domain): Plain-HTTP-Port nur für die App

Die App hat einen Protokoll-Umschalter und akzeptiert `http` für self-hosted Server
(Login läuft token-basiert/PKCE, nicht über die Secure-Cookies des Browsers):

```bash
bash endurain.sh --ctid <ID> --app-http-port 8081
```

In der App: **Protokoll `http`**, Server-Adresse **`<LXC-IP>:8081`**.
Nachteile: unverschlüsselt im LAN, Web-Login im Browser weiterhin nur über HTTPS (Port 443).

### Weg C (nur Browser): self-signed akzeptieren

Für den Browser reicht die Warnung einmal zu bestätigen bzw. die Caddy-CA aus
`/root/.local/share/caddy/pki/authorities/local/root.crt` im Container zu importieren.
Für die Mobile-App hilft das **nicht** (siehe oben).

### App-Details

- **Server-Adresse:** nur den Host (Domain oder `IP:Port`) eintragen, **ohne** `https://`
  davor – Protokoll per Umschalter wählen, sonst meldet die App „Bitte gib eine gültige URL ein".
- iOS: Beta-Builds aus TestFlight laufen ab → App aktuell halten.
- Die GPS-Aufzeichnung selbst funktioniert offline; hochgeladen wird bei Verbindung zum Server.

## Nutzung: Strava-Pflicht? Nein — 3 Wege zu Aktivitäten

Strava zu verbinden ist **optional**. Aktivitäten kommen auf drei Wegen rein:

1. **Mobile App (aufzeichnen wie bei Strava):** Die Endurain-App
   ([endurain-flutter](https://github.com/endurain-project/endurain-flutter), Flutter)
   läuft live mit Karte mit (Run, Ride, Walk, Hike), arbeitet offline und lädt bei
   Verbindung auf deinen Server. **Wichtig:** Mit dem Default (self-signed) kann sich die
   App **nicht** verbinden — siehe [Mobile-App verbinden](#mobile-app-verbinden-offizielle-app--ios-testflight)
   (Weg A: Domain/Let's Encrypt, Weg B: `--app-http-port`). iOS: öffentliche Beta über
   [TestFlight](https://testflight.apple.com/join/BjZ4DWPa). Android: in Entwicklung, Play folgt.
2. **Datei-Upload (geht immer, ohne alles):** `.gpx`/`.tcx`/`.fit` (bevorzugt `.fit`) über die
   Web-UI importieren — z. B. von Radcomputer, Uhr oder anderen Apps exportiert.
3. **Sync (optional):** Strava- oder Garmin-Connect-Konto in den User-Einstellungen
   (Integrationen) verbinden. Strava braucht zusätzlich Client-ID/Secret und eine öffentliche
   https-Domain — geht mit self-signed LAN-Zertifikat nicht.

Erste Schritte: als `admin` einloggen → Passwort ändern → ggf. `signup_enabled` einschalten →
App verbinden oder erste Datei hochladen.

## Erster Login / Registrierung

- Default-Zugang laut Upstream-Doku: `admin` / `admin` — nach dem Login sofort Passwort ändern
  (Admin-Passwörter brauchen mind. 12 Zeichen).
- Kein Registrierungs-Link auf der Login-Seite? `signup_enabled` ist eine Server-Einstellung:
  als Admin einloggen → Settings → Server settings → Signup einschalten
  (optional mit E-Mail-Verifizierung und Admin-Freigabe).

## Reboot-Test (Reboot-sicher belegen)

```bash
CT=100
pct reboot $CT
sleep 60
pct exec $CT -- systemctl is-active endurain postgresql redis-server caddy cron
curl -kfs https://<LXC-IP>/api/v1/about >/dev/null && echo WEB_UI_OK
# Domain-Modus (ohne -k, exakt der Mobile-App-Pfad):
curl -fs --resolve endurain.duckdns.org:443:<LXC-IP> https://endurain.duckdns.org/api/v1/about >/dev/null && echo APP_OK
```

## Update / Deinstall

```bash
bash endurain.sh --ctid 100            # Update: idempotent (git pull + rebuild + restart)
# im Domain-Modus (Zertifikat + A-Record + Caddyfile werden erneuert):
bash endurain.sh --ctid 100 --domain endurain.duckdns.org --dns-provider duckdns --dns-token <TOKEN>
pct stop 100 && pct destroy 100       # Deinstall
```

Zertifikat-Erneuerung läuft automatisch (acme.sh-cron im Container, `--reloadcmd` lädt Caddy neu);
manuell testen: `pct exec 100 -- /root/.acme.sh/acme.sh --renew -d endurain.duckdns.org --force --ecc`.

## Debugging

- Jeder Fehler gibt Befehl + Zeile + Exit-Code aus, Voll-Log unter `/tmp/endurain-install-*.log`.
- `bash endurain.sh --debug` für `bash -x`-Trace.
- Im Container: `systemctl status endurain --no-pager`, `journalctl -u endurain -n 100`.
- DB-Encoding muss UTF8 sein (SQL_ASCII lässt psycopg3 bytes liefern → SQLAlchemy-Crash-Loop,
  erkennbar an `TypeError: cannot use a string pattern on a bytes-like object`).
  Prüfen: `pct exec <CT> -- su postgres -c "psql -Atc \"SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='enduraindb'\""`.
  Der Installer legt fehlende/SQL_ASCII-DBs automatisch als UTF8 neu an; bestehende UTF8-DBs tastet er nie an.
- uv-Pinne: der Installer liest `required-version` aus `backend/pyproject.toml` (**nach** dem
  Code-Pull) und installiert exakt diese Version (Operator-Präfixe wie `==` werden abgestreift).
  Scheitert `uv sync` mit `Required uv version ... does not match`, ist die Upstream-Pinne
  gestiegen → einfach den Installer erneut laufen lassen (installiert dann die neue uv-Version).
- Backend-Start mit `limits.errors.ConfigurationError: 'redis' prerequisite not available`:
  die `.env` enthält `REDIS_URL`, aber redis-py ist im Default-Venv nicht enthalten
  (0.20.x: Redis gibt es nur als `--extra distributed` für Multi-Node). Einzelknoten:
  `REDIS_URL`-Zeile aus `/opt/endurain/.env` entfernen → App nutzt Upstreams
  `memory://`-Default (macht der Installer seit dem Fix automatisch).
- Erster Start dauert: Alembic-Migrationen laufen beim ersten Boot automatisch.

## Dateien

- `install/endurain.sh` – Proxmox-Einzeiler (Host, root).
- `systemd/endurain.service` – Uvicorn-Unit (nur `127.0.0.1:8080` mit `--proxy-headers`, `After=network-online.target postgresql+redis`, `Restart=always`; öffentlich ist nur Caddy auf `:443`).
