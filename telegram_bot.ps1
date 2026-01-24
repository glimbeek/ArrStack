# --- Global Configuration ---
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$botToken = "1878834395:AAFGDpYLWkg-OelD78jvBVXSe6UrqYAXHvo" # Do NOT Share This Key!!
$TelegramApiUri = "https://api.telegram.org/bot" + $botToken
$ChatID = "-1001218488253"
$AllowedIDs = 1847215214, 1337 # 1847215214 ID van George
$DockerServerLocation = "/home/glimby/docker" # "C:\DockerServer"
$LogFile = "/home/glimby/docker/bot_log.txt"

# --- NZBGet Configuration ---
$NZBGetUrl = "http://127.0.0.1:6789/jsonrpc"
$NZBGetUsername = "nzbget"
$NZBGetPassword = "tegbzn6789"

# --- If something in the script fails we want to log this --- 
Function SendToLog
{
    param
    (
        [Parameter(Mandatory)] [ValidateSet("Error","Warning","Information")] [string]$LogType,
        [Parameter(Mandatory)] [string]$LogMessage
    )

    # Log Rotation Logic
    if (Test-Path $LogFile) {
        $fileInfo = Get-Item $LogFile
        # 10MB = 10485760 bytes
        if ($fileInfo.Length -gt 10MB) {
            $OldLog = "$LogFile.old"
            Move-Item -Path $LogFile -Destination $OldLog -Force
            # Start the new log with a rotation note
            $initMsg = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [Information] Old log reached 10MB and was rotated."
            $initMsg | Out-File -FilePath $LogFile
        }
    }

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$Timestamp] [$LogType] $LogMessage" | Add-Content -Path $LogFile
}

# --- To send messages to Telegram --- 
Function Send-TelegramMessage {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [Parameter(Mandatory)] [string]$ChatID
    )

    # Clean up the URI (Remove chat_id and text from here)
    $Uri = "$TelegramApiUri/sendMessage"

    # Create a clean JSON body
    $Body = @{
        chat_id = $ChatID
        text    = $Message
    } | ConvertTo-Json

    # Send the request
    $Result = Invoke-WebRequest -Method Post -ContentType "application/json;charset=utf-8" -Uri $Uri -Body $Body -UseBasicParsing -ErrorAction SilentlyContinue

    # Check results using the corrected SendToLog logic
    if ($Result.StatusDescription -eq "OK") {
        Write-Host -ForegroundColor Green "$Message has been sent"
        SendToLog -LogType Information -LogMessage "Telegram: '$Message' sent to $ChatID."
    }
    else {
        $ErrorMsg = "Telegram failed! Status: $($Result.StatusCode) $($Result.StatusDescription)"
        Write-Host -ForegroundColor Red $ErrorMsg
        SendToLog -LogType Warning -LogMessage $ErrorMsg
    }
}

# --- To check if their are updates for the Telgram bot --- 
Function Get-TelegramUpdates() {
    $OffsetPath = "/home/glimby/docker/tg_offset.txt"

    if (!(Test-Path $OffsetPath)) {
        New-Item -Path $OffsetPath -ItemType File
    }

    $Offset = Get-Content -Path $OffsetPath
    $Uri = $TelegramApiUri + "/getUpdates"
    $ResultJson = Invoke-WebRequest -Uri $Uri -UseBasicParsing -Body @{offset = $Offset } | ConvertFrom-Json
    $Offset = $ResultJson.result[0].update_id

    Write-Host "Offset before increment: $Offset"

    if ($offset -gt 1000) {
        $Offset + 1 | Set-Content -Path $OffsetPath -Force
        Write-Host "Offset after increment: $($Offset + 1)"
    }

    return $ResultJson.result[0]

    Write-Host "JSON Returned"
}


# --- If there are updates, check if their are commands we need to process --- 
Function Get-TelegramMessages {
    param (
        [Parameter(Mandatory)] $AllowedID,
        [Parameter(Mandatory)] [string]$TelegramApiUri
    )

    $result = Get-TelegramUpdates

    # If no new message, stop here
    if ($null -eq $result) { 
        return 
    } 

    Write-Host "Result: " $result 
    
    $TelegramUserId = $result.message.from.id
    $TelegramUserFirstName = $result.message.from.first_name
    $UserMessage = $result.message.text
    $ChatID = $result.message.chat.id # Do we need this?
        
    # Security Check
    if ($AllowedID -notcontains $TelegramUserId) {
        SendToLog -LogType Warning -LogMessage "Unauthorized access attempt by ID: $TelegramUserId"
        return
    }
    Else {
        # Split command from arguments (e.g., "/restart radarr" -> "/restart" and "radarr")
        $command = $UserMessage.Split(" ")[0].ToLower()

        Write-Host "Processing command: $command from $TelegramUserFirstName"

        switch($command) {
            "/commands" { Get-BotCommands }
            "/hello"    { Send-TelegramMessage -Message "Hello $TelegramUserFirstName!" -ChatID $ChatID }
            "/stats"    { Get-DockerStats }
            "/disk"     { Get-DiskSpace }
            "/logs" {
                # Handles "/logs sonarr"
                $args = $UserMessage.Split(" ")
                if ($args[1]) { 
                    $logOutput = Get-ContainerLogs -ContainerName $args[1]
                    Send-TelegramMessage -Message $logOutput -ChatID $ChatID 
                } 
                else { 
                    Send-TelegramMessage -Message "Please specify a container name. Usage: /logs [container_name]" -ChatID $ChatID 
                }   
            }
            "/nzb"      { $msg = Get-NZBGetStatus; Send-TelegramMessage -Message $msg -ChatID $ChatID }
            "/uptime"   { Get-Uptime }
            "/reboot"   { Check-Reboot }
            "/rebootnow" { Restart-Server -UserID $TelegramUserId -UserName $TelegramUserFirstName }
            "/restartall" { Restart-Docker }
            "/restart" {
                # Handles "/restart sonarr"
                $args = $UserMessage.Split(" ")
                if ($args[1]) 
                { 
                    Restart-SingleContainer $args[1] 
                } 
                else 
                { 
                    Send-TelegramMessage -Message "Please specify a container name to restart. Usage: /restart [container_name]" -ChatID $ChatID 
                }   
            }
        }
    }
}

# --- Return a list of commands to Telegram --- 
Function Get-BotCommands
{
$helpText = "Available Commands:`n" +
                "/hello - Hello`n" +
                "/stats - Container resource usage`n" +
                "/disk - Disk space usage`n" +
                "/logs [name] - View container logs`n" +
                "/nzb - NZBGet Download/Unpack status`n" +
                "/restartall - Restart ALL containers`n" +
                "/restart [name] - Restart one container`n" +
                "/uptime - Host system uptime`n" +
                "/reboot - Reboot the host server"
    
    Send-TelegramMessage -ChatID $ChatID -Message $helpText
}

# --- Returns the system up-time to Telegram --- 
Function Get-Uptime {
   Try
   {
        $up = uptime -p
        $message = $up      
        Write-Output "displayUptime : $($uptime.Days) Days, $($uptime.Hours) Hours, $($uptime.Minutes) Minutes"
        Send-TelegramMessage -ChatID $ChatID -Message $message 
        }
    Catch
        {
            $ErrorMessage = $_.Exception.Message
            Write-Warning "Exception: $ErrorMessage"
            SendToLog -LogTYpe Warning -LogMessage "Warning: Failed to get uptime. Exception: $ErrorMessage" 
            Send-TelegramMessage -ChatID $ChatID -Message "Failed to get up time. Don't panic."  
        }
}

# --- Check if we really want to reboot... --- 
Function Check-Reboot
{
    Send-TelegramMessage -ChatID $ChatID -Message "Are you sure, if so, type: /rebootnow"
}

# --- Reboot the host machine --- 
Function Restart-Server
{
    param (
        [Parameter(Mandatory)] [string]$UserID,
        [Parameter(Mandatory)] [string]$UserName
    )
    Try
    {
        SendToLog -LogTYpe Warning -LogMessage "Reboot initiated by user: $UserName (ID: $UserID)"
        Write-Warning "Reboot initiated by user: $UserName (ID: $UserID)"
        Send-TelegramMessage -ChatID $ChatID -Message "Host server is being rebooted."  
        
        # Create an empty file acting as the "switch"
        New-Item -Path "/home/glimby/docker/reboot.trigger" -ItemType File -Force

        # This file is triggers a cronjob
        # * * * * * [ -f /home/glimby/docker/reboot.trigger ] && /usr/bin/rm /home/glimby/docker/reboot.trigger && /usr/sbin/reboot
            # [ -f ... ]: Checks if the file exists.
            # && /usr/bin/rm ...: Deletes the file only if it was found.
            # && /usr/sbin/reboot: Reboots only if the file was successfully deleted (this prevents a "reboot loop" where the system reboots but the file is still there).
        # To edit the cronjob: sudo crontab -e
    }
    Catch
    {
        $ErrorMessage = $_.Exception.Message
        Write-Warning "Exception: $ErrorMessage"
        SendToLog -LogTYpe Warning -LogMessage "Warning: Failed to reboot server. Exception: $ErrorMessage" 
        Send-TelegramMessage -ChatID $ChatID -Message "Warning: Failed to reboot server."  
    }

}

# --- Manage Docker Stack (Up/Down) ---
Function Manage-DockerStack
{
    param (
        [Parameter(Mandatory)]
        [ValidateSet("Up", "Down")]
        [string]$Action,
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (!(Test-Path $Path)) {
        $ErrorMsg = "Docker path $Path not found!"
        SendToLog -LogType Error -LogMessage $ErrorMsg
        return
    }

    $message = "Attempting restart of Docker Containers"
    SendToLog -LogTYpe Warning -LogMessage $message
    Write-Warning $message
    Send-TelegramMessage -ChatID $ChatID -Message $message

    Push-Location $path

    Try
    {
        if ($Action -eq "Up")
        {
            Send-TelegramMessage -ChatID $ChatID -Message "Starting containers..."
            docker compose up -d
            SendToLog -LogTYpe Warning -LogMessage "Container start initiated by Telegram Bot"
            Send-TelegramMessage -ChatID $ChatID -Message "Containers are up."
        }
        else
        {         
            Send-TelegramMessage -ChatID $ChatID -Message "Stopping containers..."   
            docker compose down
            SendToLog -LogTYpe Warning -LogMessage "Container shutdown initiated by Telegram Bot"
            Send-TelegramMessage -ChatID $ChatID -Message "Containers are down."
        }
    }
    Catch
    {
        $ErrorMessage = $_.Exception.Message
        Write-Warning "Exception: $ErrorMessage"
        SendToLog -LogTYpe Warning -LogMessage "Warning: Failed to restart Docker Containers. Exception: $ErrorMessage"         
        Send-TelegramMessage -ChatID $ChatID -Message "Warning: Failed to restart Docker Containers."     
    }
}

# --- Restart all Docker containers ---
Function Restart-Docker
{
    Manage-DockerStack -Action Down -Path $DockerServerLocation
    Manage-DockerStack -Action Up -Path $DockerServerLocation
}

# --- Restart a single Docker container ---
Function Restart-SingleContainer {
    param (
        [Parameter(Mandatory)] [string]$ContainerName
    )

    try {
        # Get a list of all container names and see if our target is in there
        # We use --format '{{.Names}}' to get just the plain names
        $allContainers = docker ps -a --format '{{.Names}}'
        
        if ($allContainers -contains $ContainerName) {
            Send-TelegramMessage -ChatID $ChatID -Message "Restarting container: $ContainerName..."
            
            # Perform the restart
            docker restart $ContainerName
            
            Start-Sleep -Seconds 2
            
            # Get the new status
            $status = docker inspect -f '{{.State.Status}}' $ContainerName
            
            $msg = "Container $ContainerName is now $status."
            Send-TelegramMessage -ChatID $ChatID -Message $msg
            SendToLog -LogType Information -LogMessage $msg
        }
        else {
            # If not found, send a helpful list of what IS available
            $msg = "Error: Container '$ContainerName' not found. Available: $($allContainers -join ', ')"
            Send-TelegramMessage -ChatID $ChatID -Message $msg
            SendToLog -LogType Warning -LogMessage $msg
        }
    }
    catch {
        $ErrorMsg = "Failed to restart $ContainerName. Error: $($_.Exception.Message)"
        Send-TelegramMessage -ChatID $ChatID -Message $ErrorMsg
        SendToLog -LogType Error -LogMessage $ErrorMsg
    }
}

# --- Returns a unified list of Docker container stats including Running status.
Function Get-DockerStats {   
    # Get Resource Stats (CPU, Mem) - includes all containers (-a)
    # Note: Stopped containers will show 0% usage.
    $statsRaw = docker stats --no-stream --all --format '{{json .}}' | ConvertFrom-Json

    # Get Status (Running/Exited) from docker ps
    $statusRaw = docker ps -a --format '{{json .}}' | ConvertFrom-Json

    # Merge the data into a custom output
    $results = foreach ($s in $statsRaw) {
        # Find the matching status for this container name
        $currentStatus = $statusRaw | Where-Object { $_.Names -eq $s.Name }
        
        # Create a custom object with the specific fields you requested
        [PSCustomObject]@{
            "Container Name" = $s.Name
            "CPU %"          = $s.CPUPerc
            "Memory Usage"   = ($s.MemUsage -split " / ")[0] # Gets just the used part, e.g. "150MiB"
            "Memory %"       = $s.MemPerc
            "Status"         = if ($currentStatus.Status -like "Up*") { "Running" } else { "Stopped" }
        }
    }

    # We use -Width to prevent PowerShell from cutting off columns
    $tableString = $results | Format-Table -AutoSize | Out-String -Width 100

    Send-TelegramMessage -ChatID $ChatID -Message $tableString 
}

# --- Fetch specific log for an item (e.g., Unpack details) --- 
Function Get-NZBGetItemLog {
    param ([int]$ID)
    # NZBGet requires exact parameter types for loadlog(ID, IDFrom, NumberOfEntries, ViewMode)
    $body = @{ 
        version = "1.1"
        method = "loadlog" 
        params = @($ID, 0, 10, "INFO") 
    } | ConvertTo-Json
    
    try {
        $auth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($NZBGetUsername):$($NZBGetPassword)"))
        $headers = @{ Authorization = "Basic $auth"; "Accept" = "application/json" }
        
        $response = Invoke-RestMethod -Uri $NZBGetUrl -Method Post -Body $body -Headers $headers -ContentType "application/json" -ErrorAction Stop
        
        $unpackLine = $response.result | Where-Object { $_.Text -like "*Unpacking*" } | Select-Object -Last 1
        if ($unpackLine) { return $unpackLine.Text } else { return "Processing..." }
    } catch { 
        return "Log busy..." 
    }
}

# --- Get NZBGet Status Report --- 
Function Get-NZBGetStatus {
    $body = @{ 
        version = "1.1" 
        method = "listgroups" 
        params = @() 
    } | ConvertTo-Json
    
    try {
        $auth = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($NZBGetUsername):$($NZBGetPassword)"))
        $headers = @{ Authorization = "Basic $auth"; "Accept" = "application/json" }

        # Added -ErrorAction Stop to catch the real error in the 'catch' block
        $response = Invoke-RestMethod -Uri $NZBGetUrl -Method Post -Body $body -Headers $headers -ContentType "application/json" -ErrorAction Stop
        
        if ($null -eq $response.result -or $response.result.Count -eq 0) { 
            return "✅ No active downloads in NZBGet." 
        }

        $report = "📥 *NZBGet Active Queue:*`n`n"
        foreach ($item in $response.result) {
            $name = $item.NZBNicename
            $status = $item.Status
            
            # Progress calculation
            $rawProgress = if ($null -ne $item.PostStageProgress) { $item.PostStageProgress } else { 0 }
            $percent = [Math]::Floor($rawProgress / 10)
            
            # Progress Bar logic
            $completed = [Math]::Max(0, [Math]::Min(10, [Math]::Floor($percent / 10)))
            $bar = ("■" * $completed) + ("□" * (10 - $completed))

            $report += "🎥 *$name*`n"
            $report += "⚙️ Status: $status`n"

            if ($status -match "UNPACKING|REPAIRING|VERIFYING") {
                $logMsg = Get-NZBGetItemLog -ID $item.NZBID
                $report += "📦 ``$logMsg`` `n"
                $report += "⏳ Progress: [$bar] $($percent)%`n"
            } elseif ($status -eq "DOWNLOADING") {
                $dlPercent = [Math]::Round(($item.DownloadedSizeMB / $item.FileSizeMB) * 100, 1)
                $report += "⏬ Downloaded: $($dlPercent)%`n"
            }
            $report += "---`n"
        }
        return $report
    } 
    catch { 
        # This will now capture the ACTUAL error if it fails
        $innerError = $_.Exception.Message
        return "❌ NZBGet Error: Check your Username/Password or IP.`n`nDetails: $innerError" 
    }
}

# --- Fetch the last 20 lines of a Docker container's log ---
Function Get-ContainerLogs {
    param (
        [Parameter(Mandatory)] [string]$ContainerName,
        [int]$LineCount = 20
    )

    try {
        # Check if container exists first (using your existing logic)
        $allContainers = docker ps -a --format '{{.Names}}'
        
        if ($allContainers -contains $ContainerName) {
            # Fetch the logs. --tail limits the output, --timestamps adds timing
            $rawLogs = docker logs --tail $LineCount $ContainerName 2>&1 | Out-String
            
            if ([string]::IsNullOrWhiteSpace($rawLogs)) {
                return "ℹ️ No logs found for $ContainerName."
            }

            # Wrap in backticks for a "monospaced" terminal look in Telegram
            # We use [Math]::Min to ensure we don't crash if the log is somehow massive
            $shortLogs = if ($rawLogs.Length -gt 3900) { $rawLogs.Substring($rawLogs.Length - 3900) } else { $rawLogs }
            
            return "📄 *Logs for $ContainerName (Last $LineCount lines):*`n`n``$shortLogs``"
        }
        else {
            return "❌ Error: Container '$ContainerName' not found."
        }
    }
    catch {
        return "❌ Failed to retrieve logs for $ContainerName. Error: $($_.Exception.Message)"
    }
}

# --- Returns Storage info for Local and NAS ---
Function Get-DiskSpace {
    try {
        # Define the mount points we want to check
        # "/" will usually represent your /dev/sda1
        $targets = @("/", "/mnt/nas_streaming")
        
        $diskResults = foreach ($path in $targets) {
            # Get the df info for the specific path, skip the header line
            $dfOutput = df -h $path | Select-Object -Skip 1
            
            # Split the string by whitespace to get individual columns
            # Column 2=Size, 3=Used, 4=Avail, 5=Use%
            $parts = $dfOutput -split '\s+'
            
            [PSCustomObject]@{
                "Drive"     = if ($path -eq "/") { "Local (sda1)" } else { "NAS (NFS)" }
                "Used"      = $parts[2]
                "Available" = $parts[3]
                "Use%"      = $parts[4]
            }
        }

        # Format as a clean table for Telegram
        $tableString = $diskResults | Format-Table -AutoSize | Out-String -Width 100
        $msg = "💾 *Disk Space Report*`n" + "$tableString"

        Send-TelegramMessage -ChatID $ChatID -Message $msg
    }
    catch {
        Send-TelegramMessage -ChatID $ChatID -Message "❌ Error: Could not retrieve disk space info."
    }
}

SendToLog -LogTYpe Information -LogMessage "Bot started."
Send-TelegramMessage -ChatID $ChatID -Message "I'm awake, I'm awake."


# Let's get this show on the road
while ($true)
{    
    Start-Sleep -Seconds 1
    Get-TelegramMessages -AllowedID $AllowedIDs -TelegramApiUri $TelegramApiUri
}