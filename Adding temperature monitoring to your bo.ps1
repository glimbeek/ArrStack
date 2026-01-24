Adding temperature monitoring to your bot is a great way to keep an eye on your new hardware's health, especially when it's crunching through high-bitrate 4K transcodes.

Since you'll be on Ubuntu Server, we can use the sensors command (part of the lm-sensors package). It’s the standard way to talk to physical hardware sensors on Linux.

1. Install the "Thermometer" on Ubuntu
Run this on your new machine once it's set up:

Bash
sudo apt update && sudo apt install lm-sensors -y
# Run the detection (press ENTER for all defaults)
sudo sensors-detect
2. Add the Get-CPUTemp Function
Add this to your telegram_bot.ps1. This code runs the sensors command, grabs the "Package id 0" (which is the overall CPU temperature), and cleans up the text for Telegram.

PowerShell
# --- Returns CPU Temperature ---
Function Get-CPUTemp {
    try {
        # Get sensors output and find the Package temperature line
        $tempOutput = sensors | Select-String "Package id 0" | Out-String
        
        if (-not $tempOutput) {
            # Fallback for some AMD systems or different sensor names
            $tempOutput = sensors | Select-String "Tdie|Core 0" | Select-Object -First 1 | Out-String
        }

        # Clean up the string to look nice
        $cleanTemp = $tempOutput.Trim()
        
        $msg = "🌡️ *CPU Temperature Report*`n"
        $msg += "````$cleanTemp````"

        # Alert if it's getting too hot (over 80°C)
        if ($cleanTemp -match "\+([8-9][0-9])") {
            $msg += "`n🔥 *Warning: CPU is running hot! Check ventilation.*"
        }

        Send-TelegramMessage -ChatID $ChatID -Message $msg
    }
    catch {
        Send-TelegramMessage -ChatID $ChatID -Message "❌ Error: Could not read hardware sensors."
    }
}
3. Update the Bot Logic
In the switch($command) block:

PowerShell
"/temp" { Get-CPUTemp }
In the Get-BotCommands function (help text):

PowerShell
"/temp - Check CPU hardware temperature`n"