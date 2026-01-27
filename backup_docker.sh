#!/bin/bash

# --- CONFIGURATION ---
SOURCE_DIR="/home/glimby/docker"
BACKUP_DEST="/mnt/nas_streaming/Backups/DockerContainers"
DATE=$(date +%Y-%m-%d_%H%M)
RETENTION_DAYS=30

echo "Starting Docker backup: $DATE"

# 1. Stop containers (ensures database integrity)
cd "$SOURCE_DIR"
docker compose stop

# 2. Sync the raw files (Excluding Cache & Transcodes)
# --exclude uses relative paths from the source
rsync -av --delete \
    --exclude='**/cache' \
    --exclude='**/Transcodes' \
    --exclude='nzbget/intermediate' \
    "$SOURCE_DIR/" "$BACKUP_DEST/latest_sync/"

# 3. Create a compressed archive (Excluding Cache & Transcodes)
tar -czf "$BACKUP_DEST/docker_backup_$DATE.tar.gz" \
    --exclude='*/cache' \
    --exclude='*/Transcodes' \
    --exclude='nzbget/intermediate' \
    -C "$SOURCE_DIR" .

# 4. Restart containers
docker compose start

# 5. Cleanup: Delete archives older than 30 days
find "$BACKUP_DEST" -name "docker_backup_*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete

echo "Backup complete. Containers restarted."
