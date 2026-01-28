# #!/bin/bash

# # --- CONFIGURATION ---
# SOURCE_DIR="/home/glimby/docker"
# BACKUP_DEST="/mnt/nas_streaming/Backups/DockerContainers"
# DATE=$(date +%Y-%m-%d_%H%M)
# RETENTION_DAYS=30

# echo "Starting Docker backup: $DATE"

# # 1. Stop containers (ensures database integrity)
# cd "$SOURCE_DIR"
# docker compose stop

# # 2. Sync the raw files (Excluding Cache & Transcodes)
# # --exclude uses relative paths from the source
# rsync -av --delete \
#     --exclude='**/cache' \
#     --exclude='**/Transcodes' \
#     --exclude='nzbget/intermediate' \
#     "$SOURCE_DIR/" "$BACKUP_DEST/latest_sync/"

# # 3. Create a compressed archive (Excluding Cache & Transcodes)
# tar -czf "$BACKUP_DEST/docker_backup_$DATE.tar.gz" \
#     --exclude='*/cache' \
#     --exclude='*/Transcodes' \
#     --exclude='nzbget/intermediate' \
#     -C "$SOURCE_DIR" .

# # 4. Restart containers
# docker compose start

# # 5. Cleanup: Delete archives older than 30 days
# find "$BACKUP_DEST" -name "docker_backup_*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete

# echo "Backup complete. Containers restarted."

#!/bin/bash

# --- CONFIGURATION ---
SOURCE_DIR="/home/glimby/docker"
BACKUP_DEST="/mnt/nas_streaming/Backups/DockerContainers"
DATE=$(date +%Y-%m-%d_%H%M)
RETENTION_DAYS=30

# Define exclusions (Cache, temp folders, and heavy Immich thumbnails)
# Excluding these from the .tar.gz keeps the archive small and fast.
# They are still synced via rsync to the 'latest_sync' folder.
EXCLUDES=(
    --exclude='**/cache'
    --exclude='**/Transcodes'
    --exclude='nzbget/intermediate'
    --exclude='tailscale'
    --exclude='immich/model-cache'
    --exclude='immich/thumbs'
)

echo "---------------------------------------------------"
echo "Starting Docker Backup: $DATE"
echo "---------------------------------------------------"

# 1. Stop containers to ensure database integrity (Postgres/Immich)
echo "Step 1: Stopping all Docker containers..."
cd "$SOURCE_DIR" || { echo "Source directory not found"; exit 1; }
docker compose stop

# 2. Sync raw files to the NAS (Incremental Sync)
# This provides a 1:1 copy. Only changes are transferred, making it very fast.
echo "Step 2: Syncing raw files to latest_sync..."
rsync -av --delete "${EXCLUDES[@]}" "$SOURCE_DIR/" "$BACKUP_DEST/latest_sync/"

# 3. Create a compressed archive for versioned history
# We only compress the core configs and DB files to save CPU and storage.
echo "Step 3: Creating compressed tarball (Config & DB only)..."
tar -czf "$BACKUP_DEST/docker_core_config_$DATE.tar.gz" \
    "${EXCLUDES[@]}" \
    -C "$SOURCE_DIR" .

# 4. Restart containers as soon as possible
echo "Step 4: Restarting containers..."
docker compose start

# 5. Cleanup: Delete archives older than X days
echo "Step 5: Cleaning up archives older than $RETENTION_DAYS days..."
find "$BACKUP_DEST" -name "docker_core_config_*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete

echo "---------------------------------------------------"
echo "Backup Process Finished Successfully."
echo "---------------------------------------------------"