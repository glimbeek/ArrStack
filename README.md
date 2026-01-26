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
    ExecStart=/opt/microsoft/powershell/7/pwsh -File /home/glimby/docker/telegram_bot.ps1
    Restart=always
    RestartSec=10
    User=glimby
    WorkingDirectory=/home/glimby/docker

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

    192.168.0.11:/volume1/StreamingData /mnt/nas_streaming nfs defaults,timeo=900,retrans=5,_netdev 0 0

Run
    
    systemctl daemon-reload

Run

    sudo mount -a
    df

And it should return the following:

    192.168.0.11:/volume1/StreamingData 3836208768 1738826752 2097279616  46% /mnt/nas_streaming

## 6. Docker Backup (systemd + timer)

### Backup Script

    nano /home/glimby/docker/backup_docker.sh

Script contents:

    #!/bin/bash
    SOURCE_DIR="/home/glimby/docker"
    BACKUP_DEST="/mnt/nas_streaming/Backups/DockerContainers"
    DATE=$(date +%Y-%m-%d_%H%M)
    RETENTION_DAYS=30

    echo "Starting Docker backup: $DATE"

    cd "$SOURCE_DIR"
    docker compose stop

    rsync -av --delete \
      --exclude='**/cache' \
      --exclude='**/Transcodes' \
      --exclude='nzbget/intermediate' \
      "$SOURCE_DIR/" "$BACKUP_DEST/latest_sync/"

    tar -czf "$BACKUP_DEST/docker_backup_$DATE.tar.gz" \
      --exclude='*/cache' \
      --exclude='*/Transcodes' \
      --exclude='nzbget/intermediate' \
      -C "$SOURCE_DIR" .

    docker compose start

    find "$BACKUP_DEST" -name "docker_backup_*.tar.gz" -mtime +30 -delete

    echo "Backup complete."

Make executable:

    chmod +x /home/glimby/docker/backup_docker.sh

Test the script:

    sudo systemctl start docker-backup.service # Since the script stops your containers, your media stack will go offline for a minute or two.

To watch exactly what's happening open a second terminal window and run:

    journalctl -u docker-backup.service -f

### systemd Service

    sudo nano /etc/systemd/system/docker-backup.service

Script Contents:

    [Unit]
    Description=Daily Docker Backup to NAS
    After=network-online.target mnt-nas_streaming.mount

    [Service]
    Type=oneshot
    User=glimby
    ExecStart=/home/glimby/docker/backup_docker.sh

    [Install]
    WantedBy=multi-user.target

### Timer

    sudo nano /etc/systemd/system/docker-backup.timer

Script Contents:

    [Unit]
    Description=Run Docker Backup Daily at 03:00

    [Timer]
    OnCalendar=*-*-* 03:00:00
    Persistent=true

    [Install]
    WantedBy=timers.target

Activate:

    sudo systemctl daemon-reload
    sudo systemctl enable --now docker-backup.timer

---

### Restore script

    nano /home/glimby/docker/restore_docker.sh

Script contents:

    #!/bin/bash

    SOURCE_DIR="/home/glimby/docker"
    BACKUP_DEST="/mnt/nas_streaming/Backups/DockerContainers"

    # 1. List available backups so you can choose
    echo "Available backups in $BACKUP_DEST:"
    ls -lh "$BACKUP_DEST"/*.tar.gz
    echo ""
    read -p "Enter the full filename of the backup you want to restore (e.g., docker_backup_2024-01-20_0300.tar.gz): " SELECTED_BACKUP

    # 2. Safety Check
    if [ ! -f "$BACKUP_DEST/$SELECTED_BACKUP" ]; then
        echo "Error: Backup file not found!"
        exit 1
    fi

    read -p "WARNING: This will stop your containers and overwrite $SOURCE_DIR. Proceed? (y/n): " CONFIRM
    if [[ $CONFIRM != "y" ]]; then
        echo "Restore cancelled."
        exit 1
    fi

    # 3. Stop Docker
    echo "Stopping Docker containers..."
    cd "$SOURCE_DIR"
    docker compose stop

    # 4. Clear current config (Optional but recommended to prevent mixing old/new files)
    # We keep the backup script itself and the .env if they exist outside the archive
    echo "Cleaning up current directory..."
    find "$SOURCE_DIR" -mindepth 1 -not -name 'restore_docker.sh' -not -name 'backup_docker.sh' -delete

    # 5. Extract the backup
    echo "Restoring files from $SELECTED_BACKUP..."
    tar -xzf "$BACKUP_DEST/$SELECTED_BACKUP" -C "$SOURCE_DIR"

    # 6. Restart Docker
    echo "Starting Docker containers..."
    docker compose up -d

    echo "Restore complete."

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