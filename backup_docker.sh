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