# Docker Homelab – Bare Metal Setup (Ubuntu)

## Table of Contents
1. Installation Requirements
2. System Preparation
3. Install Docker & Docker Compose
4. Project Directory Setup
5. Intel Media Drivers (Optional)
6. Telegram Docker Control Bot
7. Docker Backup (systemd + timer)
8. Useful Commands

---

## 1. System Preparation

### 1.1 Update the System

    sudo apt update && sudo apt upgrade -y

### 1.2 Install Core Utilities

    sudo apt install -y \
      openssh-server \
      unzip \
      nfs-common \
      sysstat

### 1.3 Hardware Monitoring & Intel GPU Support

Required for Glances and Intel GPU visibility.  
intel-gpu-tools replaces intel-media-va-driver for monitoring only.

    sudo apt install -y intel-gpu-tools lm-sensors
    sudo sensors-detect

Run sensors-detect once and answer YES to all questions.

### 1.4 Install PowerShell

Download the Microsoft repository GPG-keys
    wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb"

Register the Microsoft repository GPG-keys
    sudo dpkg -i packages-microsoft-prod.deb

Remove the downloaded file
    rm packages-microsoft-prod.deb

Update the package list
    
    sudo apt update

Install PowerShell

    sudo apt install -y powershell

### 1.5 Setup the USB port to receive incoming data from the P1 port

Check if the USB connected

    ls -l /dev/ttyUSB*

Remove braille-service that might hijack the USB

    sudo apt remove brltty -y

Set the correct permissions on the USB port

    sudo chmod 666 /dev/ttyUSB0


### 1.6 Disable bluetooth and Wi-Fi to reduce power consumption

Stop and disable bluetooth
    
    sudo systemctl stop bluetooth && sudo systemctl disable bluetooth

Disable Wi-Fi

    sudo nmcli radio wifi off

## 2. Install Docker & Docker Compose

### 2.1 Add Docker GPG Key

    sudo apt update
    sudo apt install -y ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

### 2.2 Add Docker Repository

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

### 2.3 Install Docker Engine & Compose Plugin

    sudo apt update
    sudo apt install -y \
      docker-ce \
      docker-ce-cli \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin

### 2.4 Docker Post-Install Steps

    sudo usermod -aG docker $USER

Log out and back in for this to take effect.

### 2.5 NZBget intermediate folder and permissions
Ensure the directory exists

    mkdir -p /home/glimby/docker/nzbget/intermediate

Grant ownership to your user ID (1000)

    sudo chown -R 1000:1000 /home/glimby/docker/nzbget/intermediate

Set read/write permissions

    sudo chmod -R 775 /home/glimby/docker/nzbget/intermediate
---

## 3. Project Directory Setup

    mkdir -p ~/docker
    sudo chown -R $USER:$USER ~/docker

---

## 4. Intel Media Drivers (Optional)

Only required if Jellyfin hardware transcoding is used.

    sudo apt install -y intel-media-va-driver-non-free vainfo

Verify GPU visibility:

    ls -l /dev/dri

Expected output includes renderD128.

---

## 5. Telegram Docker Control Bot

Create the systemd service:

    sudo nano /etc/systemd/system/tgbot.service

Service contents:

    [Unit]
    Description=Telegram Docker Control Bot
    After=docker.service

    [Service]
    Type=simple
    ExecStart=/opt/microsoft/powershell/7/pwsh -File /home/glimby/docker/arrstack/telegram_bot.ps1
    Restart=always
    RestartSec=10
    User=glimby
    WorkingDirectory=/home/glimby/docker/arrstack

    [Install]
    WantedBy=multi-user.target

Enable and start:

    sudo systemctl daemon-reload
    sudo systemctl enable --now tgbot

---

Create mount to media share

    sudo apt update
    sudo apt install cifs-utils -y
    sudo nano /etc/fstab

Paste the following at the bottom of the file:

    <!-- 192.168.0.11:/volume1/StreamingData /mnt/nas_streaming nfs defaults,timeo=900,retrans=5,_netdev,nofail,x-systemd.automount,x-systemd.device-timeout=10 0 0 -->
    192.168.0.11:/volume1/StreamingData /mnt/nas_streaming nfs noauto,nofail,_netdev,x-systemd.automount,x-systemd.mount-timeout=10,x-systemd.idle-timeout=60,soft,timeo=50,retrans=2 0 0

Run
    
    systemctl daemon-reload

Run

    sudo mount -a
    df

And it should return the following:

    192.168.0.11:/volume1/StreamingData 3836208768 1738826752 2097279616  46% /mnt/nas_streaming

Make sure Docker starts AFTER the mount is made

    sudo systemctl edit docker.service

Contents:

    [Unit]
    After=mnt-nas_streaming.mount
    Requires=mnt-nas_streaming.mount

sudo systemctl daemon-reload

Create Reboot Trigger ACTION Service

    sudo nano /etc/systemd/system/reboot-trigger.service

Service contents:

    [Unit]
    Description=Reboot Service triggered by file
    After=network.target

    [Service]
    Type=oneshot
    ExecStartPre=/usr/bin/rm -f /home/glimby/docker/arrstack/reboot.trigger
    ExecStart=/usr/sbin/reboot

Create Reboot Trigger WATCHER Service

    sudo nano /etc/systemd/system/reboot-trigger.path

Service contents:

    [Unit]
    Description=Monitor for reboot trigger file

    [Path]
    PathExists=/home/glimby/docker/arrstack/reboot.trigger
    Unit=reboot-trigger.service

    [Install]
    WantedBy=multi-user.target

Active the config

    sudo systemctl daemon-reload
    sudo systemctl enable --now reboot-trigger.path

## 6. Docker Backup (systemd + timer)

sudo apt install restic

sudo mkdir -p /var/backups/restic-docker /var/backups/dumps
openssl rand -base64 32 | sudo tee /root/.restic-pass
sudo chmod 600 /root/.restic-pass

Safe the password somewhere safe

sudo RESTIC_REPOSITORY=/var/backups/restic-docker \
     RESTIC_PASSWORD_FILE=/root/.restic-pass \
     restic init


### Backup Script

Script contents:



sudo cp backup_docker.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/backup_docker.sh
sudo /usr/local/bin/backup_docker.sh

#!/usr/bin/env bash
#
# backup_docker.sh — backup van beide Docker-stacks naar een lokale restic-repo,
# met opportunistische sync naar de NAS zodra die aan staat.
#
set -euo pipefail

# ---------------- configuratie ----------------
ARRSTACK="/home/glimby/docker/arrstack/compose.yaml"
WEBHOSTING="/home/glimby/docker/webhosting/compose.yaml"
SOURCE_DIR="/home/glimby/docker"

RESTIC_REPOSITORY="/var/backups/restic-docker"
RESTIC_PASSWORD_FILE="/root/.restic-pass"
export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE

DUMP_DIR="/var/backups/dumps"

NAS_IP="192.168.0.11"
NAS_MOUNT="/mnt/nas_streaming"
NAS_REPO="${NAS_MOUNT}/Backups/restic-docker"

KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=3

LOG_TAG="docker-backup"
# ----------------------------------------------

log()  { echo "[$(date '+%F %T')] $*"; logger -t "$LOG_TAG" "$*"; }
fail() { log "FOUT: $*"; exit 1; }

RUNNING_ARR=""
RUNNING_WEB=""

# Draait bij elke exit, ook bij een crash halverwege.
# Zonder dit blijven je containers uit als het script sneuvelt.
cleanup() {
    local rc=$?
    if [[ -n "$RUNNING_ARR" ]]; then
        log "Herstarten arrstack"
        # shellcheck disable=SC2086
        docker compose -f "$ARRSTACK" start $RUNNING_ARR || log "FOUT: arrstack niet herstart"
    fi
    if [[ -n "$RUNNING_WEB" ]]; then
        log "Herstarten webhosting"
        # shellcheck disable=SC2086
        docker compose -f "$WEBHOSTING" start $RUNNING_WEB || log "FOUT: webhosting niet herstart"
    fi
    rm -rf "$DUMP_DIR"
    if (( rc != 0 )); then log "Script eindigde met fout (exit $rc)"; fi
    exit $rc
}
trap cleanup EXIT

# ---------------- preflight ----------------
command -v restic >/dev/null || fail "restic niet geïnstalleerd (apt install restic)"
[[ -f "$RESTIC_PASSWORD_FILE" ]] || fail "wachtwoordbestand ontbreekt: $RESTIC_PASSWORD_FILE"
[[ -f "$ARRSTACK" ]]   || fail "compose niet gevonden: $ARRSTACK"
[[ -f "$WEBHOSTING" ]] || fail "compose niet gevonden: $WEBHOSTING"

restic cat config >/dev/null 2>&1 || fail "restic-repo niet bereikbaar. Eerst: restic init"

# De ongecomprimeerde Immich-dump is ~6 GB, dus ruime marge eisen.
FREE_GB=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
(( FREE_GB > 20 )) || fail "te weinig vrije ruimte: ${FREE_GB}G"

mkdir -p "$DUMP_DIR"
chmod 700 "$DUMP_DIR"

log "===== Backup gestart ====="

# ---------------- 1. Dumps, terwijl alles nog draait ----------------

# Immich Postgres. De PGDATA-map (5,8 GB) slaan we over; deze dump
# vervangt hem. Bewust NIET gecomprimeerd: restic doet dat zelf en kan
# dan dedupliceren op de daadwerkelijk gewijzigde delen. Een gzip-bestand
# verandert vanaf de eerste gewijzigde byte volledig, waardoor restic
# elke dag de hele 637 MB opnieuw zou wegschrijven.
if docker compose -f "$ARRSTACK" ps --services --status running 2>/dev/null | grep -qx database; then
    log "pg_dump Immich"
    DB_USER=$(docker compose -f "$ARRSTACK" exec -T database printenv POSTGRES_USER | tr -d '\r')
    docker compose -f "$ARRSTACK" exec -T database \
        pg_dumpall --clean --if-exists -U "$DB_USER" \
        > "${DUMP_DIR}/immich-postgres.sql" \
        || fail "pg_dump mislukt"
    log "  $(du -h "${DUMP_DIR}/immich-postgres.sql" | cut -f1)"
else
    log "WAARSCHUWING: Immich database draait niet, geen dump"
fi

# Named volumes staan in /var/lib/docker/volumes en vallen dus buiten
# een backup van ~/docker.
#
# BEWUST NIET MEEGENOMEN: het anonieme volume van MariaDB (WordPress,
# alexpastoorv4). Tijdelijke site, backup gaat handmatig via WordPress.
for vol in pensioen_api-data helloworld_caddy_data; do
    if docker volume inspect "$vol" >/dev/null 2>&1; then
        log "Volume $vol"
        docker run --rm -v "${vol}:/data:ro" -v "${DUMP_DIR}:/backup" \
            alpine tar -cf "/backup/volume-${vol}.tar" -C /data . \
            || log "WAARSCHUWING: volume $vol mislukt"
    fi
done

# ---------------- 2. Containers stoppen ----------------
# Onthouden wat er draaide, zodat we straks geen media-containers
# starten terwijl de NAS uit is.
RUNNING_ARR=$(docker compose -f "$ARRSTACK"   ps --services --status running | tr '\n' ' ')
RUNNING_WEB=$(docker compose -f "$WEBHOSTING" ps --services --status running | tr '\n' ' ')
log "Draaiend — arrstack: $(wc -w <<<"$RUNNING_ARR"), webhosting: $(wc -w <<<"$RUNNING_WEB")"

log "Stoppen containers"
# shellcheck disable=SC2086
docker compose -f "$ARRSTACK"   stop $RUNNING_ARR >/dev/null 2>&1 || log "WAARSCHUWING: stop arrstack"
# shellcheck disable=SC2086
docker compose -f "$WEBHOSTING" stop $RUNNING_WEB >/dev/null 2>&1 || log "WAARSCHUWING: stop webhosting"

# ---------------- 3. Restic backup ----------------
log "Restic backup"
set +e
restic backup \
    --tag docker --tag automated \
    --exclude "${SOURCE_DIR}/arrstack/config/immich/postgres" \
    --exclude "${SOURCE_DIR}/arrstack/config/immich/model-cache" \
    --exclude "${SOURCE_DIR}/arrstack/config/jellyfin/metadata" \
    --exclude "${SOURCE_DIR}/arrstack/config/jellyfin/cache" \
    --exclude "${SOURCE_DIR}/arrstack/config/jellyfin/log" \
    --exclude "${SOURCE_DIR}/arrstack/config/nzbget/intermediate" \
    --exclude "**/*.sock" \
    --exclude "**/Transcodes" \
    "$SOURCE_DIR" "$DUMP_DIR"
RC=$?
set -e
# exit 1 = klaar met waarschuwingen (bv. een bestand dat verdween). Acceptabel.
(( RC <= 1 )) || fail "restic backup mislukt (exit $RC)"
log "Backup klaar"

# ---------------- 4. Containers terug ----------------
log "Herstarten containers"
# shellcheck disable=SC2086
docker compose -f "$ARRSTACK"   start $RUNNING_ARR >/dev/null 2>&1 || log "FOUT: arrstack niet herstart"
# shellcheck disable=SC2086
docker compose -f "$WEBHOSTING" start $RUNNING_WEB >/dev/null 2>&1 || log "FOUT: webhosting niet herstart"
RUNNING_ARR=""; RUNNING_WEB=""   # trap hoeft niets meer te doen

# ---------------- 5. Retentie ----------------
log "Opruimen oude snapshots"
restic forget \
    --tag docker \
    --keep-daily "$KEEP_DAILY" \
    --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" \
    --prune || log "WAARSCHUWING: forget/prune mislukt"

# ---------------- 6. NAS-sync, alleen als hij aan is ----------------
# Elke nacht proberen in plaats van een vaste woensdag: zo profiteer je
# van élke keer dat de NAS toevallig aan staat.
log "NAS bereikbaar?"
if ping -c1 -W2 "$NAS_IP" >/dev/null 2>&1; then
    ls "$NAS_MOUNT" >/dev/null 2>&1 || true      # triggert de automount
    sleep 2
    if mountpoint -q "$NAS_MOUNT"; then
        log "NAS aan, kopiëren"
        mkdir -p "$NAS_REPO"
        # De repo is versleuteld, dus rsync ervan is veilig.
        rsync -a --delete "${RESTIC_REPOSITORY}/" "${NAS_REPO}/" \
            && log "NAS-sync klaar ($(du -sh "$NAS_REPO" | cut -f1))" \
            || log "WAARSCHUWING: NAS-sync mislukt"
    else
        log "NAS pingt maar mount niet, overgeslagen"
    fi
else
    log "NAS uit, sync overgeslagen"
fi

# ---------------- 7. Integriteit ----------------
# Zondags een steekproef; dagelijks zou te lang duren.
if [[ "$(date +%u)" == "7" ]]; then
    log "Wekelijkse check"
    restic check --read-data-subset=5% || log "WAARSCHUWING: restic check gaf fouten"
fi

log "===== Backup succesvol afgerond ====="

Make executable & run first backup:

    sudo cp backup_docker.sh /usr/local/bin/backup_docker.sh
    sudo chmod +x /usr/local/bin/backup_docker.sh
    sudo /usr/local/bin/backup_docker.sh

sudo tee /usr/local/bin/sync_backup_nas.sh > /dev/null << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

RESTIC_REPOSITORY="/var/backups/restic-docker"
NAS_IP="192.168.0.11"
NAS_MOUNT="/mnt/nas_streaming"
NAS_REPO="${NAS_MOUNT}/Backups/restic-docker"

log() { echo "[$(date '+%F %T')] $*"; logger -t nas-sync "$*"; }

if ! ping -c1 -W2 "$NAS_IP" >/dev/null 2>&1; then
    log "NAS uit, overgeslagen"
    exit 0
fi

ls "$NAS_MOUNT" >/dev/null 2>&1 || true   # triggert de automount
sleep 3
mountpoint -q "$NAS_MOUNT" || { log "NAS pingt maar mount niet"; exit 1; }

log "Synchroniseren naar NAS"
mkdir -p "$NAS_REPO"
rsync -a --delete "${RESTIC_REPOSITORY}/" "${NAS_REPO}/"
log "Klaar ($(du -sh "$NAS_REPO" | cut -f1))"
EOF

sudo chmod +x /usr/local/bin/sync_backup_nas.sh

sudo tee /etc/systemd/system/nas-sync.service > /dev/null << 'EOF'
[Unit]
Description=Restic-repo naar NAS synchroniseren
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync_backup_nas.sh
EOF

sudo tee /etc/systemd/system/nas-sync.timer > /dev/null << 'EOF'
[Unit]
Description=Elk kwartier kijken of de NAS aan staat

[Timer]
OnCalendar=*-*-* *:00,15,30,45:00
Persistent=false

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now nas-sync.timer

## 7. Setup VPN and Reverse Proxy

After launching the tailscale container, run the command:

    docker logs tailscale

Copy the authenticate url, for instance:

    https://login.tailscale.com/a/c30000000000f1asex

Once authenticated, connect the server and your server will have a permanent internal IP (e.g., 100.64.0.5).

Open the NPM admin panel: http://192.168.0.45:81/ and create an admin account.

Add a Proxy Host: Hosts > Proxy Hosts -> Add Proxy Host and enter the details. For example:

Domain Names:

    jellyfin.<Tailnet DNS name>.ts.net

Scheme

    http

Forward Hostname / IP

    jellyfin

Forward Port

    8096

## 8. Useful Commands

Docker container versions:

    for container in $(docker ps --format "{{.Names}}"); do
      echo -n "$container: "
      docker inspect -f '{{if index .Config.Labels "org.opencontainers.image.version"}}{{index .Config.Labels "org.opencontainers.image.version"}}{{else if index .Config.Labels "version"}}{{index .Config.Labels "version"}}{{else if index .Config.Labels "build_version"}}{{index .Config.Labels "build_version"}}{{else}}No version label found{{end}}' "$container"
    done

Docker container IP addresses:

    for container in $(docker ps --format "{{.Names}}"); do
      echo -n "$container: "
      docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container"
    done

Copy .env file to Linux host

    scp .env glimby@192.168.0.45:/home/glimby/docker/

Start / Stop Message Bot service

    sudo systemctl start/stop tgbot.service

Install CURL in a container 

    docker exec -u 0 -it homepage sh
    apk add curl

Do a HTTP request from a container

    docker exec <container_name> curl -I "<URL>"

Create a container back-up

    sudo systemctl start docker-backup.service

Search shell command history

    history | grep "STRING_TO_SEARCH_HERE'

Check GPU Usage: IMC reads/writes

    sudo intel_gpu_top

Check Immich asset count

    docker exec -it immich_postgres psql -U postgres -d immich -c "SELECT count(*) FROM asset;"