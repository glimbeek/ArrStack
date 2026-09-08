#!/usr/bin/env bash
#
# sync_backup_nas.sh — kopieert de lokale restic-repo naar de NAS.
#
# Draait elk kwartier via nas-sync.timer. Staat de NAS uit (normaal het geval),
# dan stopt het script meteen en kost het niets. Staat hij aan, dan synct het.
# Zo lift de sync mee op élk moment dat de NAS toevallig aan staat, in plaats
# van te wachten op een vast tijdstip dat de NAS misschien uit is.
#
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

ls "$NAS_MOUNT" >/dev/null 2>&1 || true   # triggert de systemd automount
sleep 3

mountpoint -q "$NAS_MOUNT" || { log "NAS pingt maar mount niet"; exit 1; }

log "Synchroniseren naar NAS"
mkdir -p "$NAS_REPO"

# -rlptD i.p.v. -a: dat is -a zonder -o en -g (owner/group).
# De NFS-share van de Synology doet root squash, dus chown naar root wordt
# geweigerd en rsync -a faalt met exit 23. Restic heeft eigenaarschap niet
# nodig — het leest zijn eigen bestanden ongeacht wie de eigenaar is.
rsync -rlptD --delete "${RESTIC_REPOSITORY}/" "${NAS_REPO}/"

log "Klaar ($(du -sh "$NAS_REPO" | cut -f1))"