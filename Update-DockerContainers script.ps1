Step 2: Install Docker & Intel DriversOnce the PC reboots, log in (or SSH in from your main computer) and run these:Docker Official Install:Bashsudo apt update && sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
Intel GPU Drivers:Bashsudo apt install -y intel-opencl-icd intel-media-va-driver-non-free vainfo
# Add your user to the video/render groups so Docker can use the GPU
sudo usermod -aG docker,video,render $USER
Restart the PC after this step.Step 3: Migration (Old VM to New PC)We want to move your "Settings" so you don't have to re-configure Jellyfin or your Telegram bot.On Old VM: Zip your config folders.Bashtar -cvzf homelab_backup.tar.gz ~/docker
Transfer: Send the file to the new PC's IP address.Bashscp homelab_backup.tar.gz youruser@new-pc-ip:~/
On New PC: Unzip and launch.Bashtar -xvzf ~/homelab_backup.tar.gz -C ~/
cd ~/docker && docker compose up -d
Step 4: The /update Command for your Telegram BotNow that you're on a "Real" server, you'll want an easy way to update your apps. Add this to your telegram_bot.ps1 script:PowerShell# --- Updates Docker Images and Restarts Containers ---
Function Update-DockerContainers {
    try {
        Send-TelegramMessage -ChatID $ChatID -Message "🔄 *Starting Update...*`nPulling latest images..."
        
        # Pull new images, recreate containers, and remove old 'dangling' images
        docker compose pull | Out-String
        $status = docker compose up -d --remove-orphans | Out-String
        docker image prune -f | Out-String
        
        Send-TelegramMessage -ChatID $ChatID -Message "✅ *Update Complete!*`n$status"
    }
    catch {
        Send-TelegramMessage -ChatID $ChatID -Message "❌ *Update Failed!* Check logs."
    }
}
Add this to your switch block:"/update" { Update-DockerContainers }Summary Checklist for your new PCTaskVerification CommandGPU Accessvainfo (Should list HEVC/H264)Docker Statusdocker ps (Should show your containers)CPU Tempsensors (Should show real thermal data)Transcodingintel_gpu_top (Run while playing a movie)This Guide to Intel QuickSync in Docker explains exactly why Intel's hardware is so much better than software for 4K streaming.