## Installation Requirements (Bare Metal Host)
Before running `docker compose up -d`, ensure the following are installed on the Ubuntu host:

### 1. Update and Install Core Tools
# 1. Update package list
sudo apt update && sudo apt upgrade -y

# 2. Install essential system tools
sudo apt install -y openssh-server unzip nfs-common sysstat lm-sensors

# 3. Hardware Monitoring & GPU Support (Crucial for Glances/Jellyfin)
# intel-gpu-tools replaces 'intel-media-va-driver' for monitoring
sudo apt install -y intel-gpu-tools lm-sensors
sudo sensors-detect  # Run this once and answer YES to all

# 4. PowerShell
sudo apt install -y powershell

### 2. Install Docker
# 1. Add Docker's official GPG key:
sudo apt update
sudo apt install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# 2. Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 3. Install Docker Engine and the Compose Plugin
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# 4. Add your user to the docker group (so you don't need 'sudo' for every command)
sudo usermod -aG docker $USER
# NOTE: Log out and log back in for this to take effect!

# 5. Start and enable the SMART daemon for drive health monitoring
sudo systemctl enable --now smartd

# Create the project directory
mkdir -p ~/docker

# Set ownership to your user (PUID 1000)
sudo chown -R $USER:$USER ~/docker

### 5. Install drivers <-- I this needed?
# Install Intel Media drivers
sudo apt install -y intel-media-va-driver-non-free vainfo

# Verify the GPU is visible (You should see 'renderD128' in the output)
ls -l /dev/dri

### 3. Setup the Telegram Bot
# 1. Create the service
sudo nano /etc/systemd/system/tgbot.service

# 2. Add the script
[Unit]
Description=Telegram Docker Control Bot
After=docker.service

[Service]
Type=simple
ExecStart=/opt/microsoft/powershell/7/pwsh -File /home/glimby/docker/telegram_bot.ps1
Restart=always
RestartSec=10
User=glimby
WorkingDirectory=/home/glimby/docker

[Install]
WantedBy=multi-user.target

# 3. Reload the systemd daemon to see the new file
sudo systemctl daemon-reload

# 4. Start the bot
sudo systemctl start tgbot

### 4. Create a backup cronjob
# To run the job manually run the following command
# Since the script stops your containers, your media stack will go offline for a minute or two.
sudo systemctl start docker-backup.service
# To watch exactly what's happening open a second terminal window and run:
journalctl -u docker-backup.service -f

# 1. Create the .sh file for the backup script:
nano /home/glimby/docker/backup_docker.sh

# 2. Copy paste this in the file
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
    "$SOURCE_DIR/" "$BACKUP_DEST/latest_sync/"

# 3. Create a compressed archive (Excluding Cache & Transcodes)
tar -czf "$BACKUP_DEST/docker_backup_$DATE.tar.gz" \
    --exclude='*/cache' \
    --exclude='*/Transcodes' \
    -C "$SOURCE_DIR" .

# 4. Restart containers
docker compose start

# 5. Cleanup: Delete archives older than 30 days
find "$BACKUP_DEST" -name "docker_backup_*.tar.gz" -type f -mtime +$RETENTION_DAYS -delete

echo "Backup complete. Containers restarted."

# 2. Copy paste this in the file
[Unit]
Description=Daily Docker Backup to NAS
After=network-online.target mnt-nas_streaming.mount

[Service]
Type=oneshot
User=glimby
ExecStart=/home/glimby/docker/backup_docker.sh

[Install]
WantedBy=multi-user.target

# 5. Create the timer job
# 1. Create the .timer file
sudo nano /etc/systemd/system/docker-backup.timer

# 2. Copy paste this in the file
[Unit]
Description=Run Docker Backup Daily at 03:00:00

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target

# 5. Activate the service
sudo systemctl daemon-reload
sudo systemctl enable --now docker-backup.timer

### Useful commands
# Get Docker container versions based on common label keys
for container in $(docker ps --format "{{.Names}}"); do 
    echo -n "$container: "; 
    docker inspect -f '{{if index .Config.Labels "org.opencontainers.image.version"}}{{index .Config.Labels "org.opencontainers.image.version"}}{{else if index .Config.Labels "version"}}{{index .Config.Labels "version"}}{{else if index .Config.Labels "build_version"}}{{index .Config.Labels "build_version"}}{{else}}No version label found{{end}}' "$container"; 
done

# Get Docker container IP addresses
for container in $(docker ps --format "{{.Names}}"); do
    echo -n "$container: "; 
    docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container";
done