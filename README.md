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

## Installation Requirements

Before running docker compose up -d, ensure the following components are installed on the Ubuntu bare metal host.

---

## 1. System Preparation

### 1.1 Update the System

    sudo apt update && sudo apt upgrade -y

### 1.2 Install Core Utilities

    sudo apt install -y \
      openssh-server \
      unzip \
      nfs-common \
      sysstat \
      lm-sensors

### 1.3 Hardware Monitoring & Intel GPU Support

Required for Glances and Intel GPU visibility.  
intel-gpu-tools replaces intel-media-va-driver for monitoring only.

    sudo apt install -y intel-gpu-tools lm-sensors
    sudo sensors-detect

Run sensors-detect once and answer YES to all questions.

### 1.4 Install PowerShell

    sudo apt install -y powershell

---

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

Enable SMART monitoring:

    sudo systemctl enable --now smartd

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
      "$SOURCE_DIR/" "$BACKUP_DEST/latest_sync/"

    tar -czf "$BACKUP_DEST/docker_backup_$DATE.tar.gz" \
      --exclude='*/cache' \
      --exclude='*/Transcodes' \
      -C "$SOURCE_DIR" .

    docker compose start

    find "$BACKUP_DEST" -name "docker_backup_*.tar.gz" -mtime +30 -delete

    echo "Backup complete."

Make executable:

    chmod +x /home/glimby/docker/backup_docker.sh

### systemd Service

    sudo nano /etc/systemd/system/docker-backup.service

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

## 7. Useful Commands

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
