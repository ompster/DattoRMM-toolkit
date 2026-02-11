#Requires -Version 5.1
<#
.SYNOPSIS
    Datto RMM Component Monitor Template
.DESCRIPTION
    Use this as a starting point for Component Monitors.
    
    How Component Monitors work in Datto RMM:
    - Runs on a schedule (e.g. every 15/30/60 min)
    - Exit 0 = HEALTHY (no alert)
    - Exit 1 = ALERT (triggers response actions)
    - stdout is captured as the monitor's output/detail text
    
    The monitor checks a condition and exits with the appropriate code.
    Keep it fast — monitors run frequently and shouldn't take long.

.NOTES
    Component Type: Monitor
    Suggested Schedule: Every 30 minutes (adjust per use case)
#>

#region ========================= TOOLKIT =========================
# Paste the functions you need from DattoRMM-Toolkit.ps1, or copy the whole thing.
# At minimum you want: Write-Log, Exit-Component, Set-DattoUDF

$script:LogPath = "$env:ProgramData\CentraStage\Logs\monitor-$(Get-Date -Format 'yyyyMMdd').log"

function Write-Log {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    $logDir = Split-Path $script:LogPath -Parent
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    Add-Content -Path $script:LogPath -Value $entry -Encoding UTF8
    switch ($Level) {
        'ERROR' { Write-Error $Message }
        'WARN'  { Write-Warning $Message }
        default { Write-Output $entry }
    }
}

function Set-DattoUDF {
    param(
        [Parameter(Mandatory)][ValidateRange(1, 30)][int]$UDF,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    try {
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\CentraStage' -Name "Custom$UDF" -Value $Value -Force
        [Environment]::SetEnvironmentVariable("UDF_$UDF", $Value, 'Process')
    } catch {
        Write-Log "Failed to set UDF $UDF - $_" -Level ERROR
    }
}

#endregion

#region ====================== CONFIGURATION ======================

# --- EDIT THESE FOR YOUR MONITOR ---

$MonitorName = 'Example Monitor'

# UDF to write results to (set to $null to skip)
$ResultUDF = $null  # e.g. 10

# Thresholds
$WarningThreshold = 80   # Adjust per monitor
$CriticalThreshold = 90  # Triggers alert (exit 1)

#endregion

#region ========================= CHECK ===========================

Write-Log "=== $MonitorName starting ==="

try {
    # ╔══════════════════════════════════════════════════════════╗
    # ║  REPLACE THIS SECTION WITH YOUR ACTUAL CHECK LOGIC      ║
    # ╠══════════════════════════════════════════════════════════╣
    # ║  Examples below — uncomment one or write your own        ║
    # ╚══════════════════════════════════════════════════════════╝

    # --- Example 1: Disk space check ---
    # $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    # $pctUsed = [math]::Round((($disk.Size - $disk.FreeSpace) / $disk.Size) * 100, 1)
    # $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
    # $detail = "C: drive ${pctUsed}% used (${freeGB}GB free)"
    # $currentValue = $pctUsed

    # --- Example 2: Service running check ---
    # $serviceName = 'Spooler'
    # $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    # if (-not $svc) {
    #     Write-Output "ALERT: Service '$serviceName' not found"
    #     exit 1
    # }
    # if ($svc.Status -ne 'Running') {
    #     Write-Output "ALERT: Service '$serviceName' is $($svc.Status)"
    #     exit 1
    # }
    # Write-Output "OK: Service '$serviceName' is running"
    # exit 0

    # --- Example 3: Pending reboot check ---
    # $rebootPending = $false
    # if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -EA SilentlyContinue) { $rebootPending = $true }
    # if (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -EA SilentlyContinue) { $rebootPending = $true }
    # if (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -EA SilentlyContinue) { $rebootPending = $true }
    # if ($rebootPending) {
    #     Write-Output "ALERT: Reboot pending"
    #     exit 1
    # }
    # Write-Output "OK: No reboot pending"
    # exit 0

    # --- Example 4: Event log error check (last hour) ---
    # $cutoff = (Get-Date).AddHours(-1)
    # $errors = Get-WinEvent -FilterHashtable @{LogName='Application'; Level=2; StartTime=$cutoff} -MaxEvents 10 -EA SilentlyContinue
    # if ($errors) {
    #     Write-Output "ALERT: $($errors.Count) application errors in last hour"
    #     $errors | ForEach-Object { Write-Output "  - $($_.TimeCreated): $($_.Message.Substring(0, [Math]::Min(100, $_.Message.Length)))" }
    #     exit 1
    # }
    # Write-Output "OK: No application errors in last hour"
    # exit 0

    # --- Example 5: Certificate expiry check ---
    # $daysWarning = 30
    # $expiring = Get-ChildItem Cert:\LocalMachine\My | Where-Object {
    #     $_.NotAfter -lt (Get-Date).AddDays($daysWarning) -and $_.NotAfter -gt (Get-Date)
    # }
    # if ($expiring) {
    #     $expiring | ForEach-Object { Write-Output "ALERT: Certificate '$($_.Subject)' expires $($_.NotAfter.ToString('yyyy-MM-dd'))" }
    #     exit 1
    # }
    # Write-Output "OK: No certificates expiring within $daysWarning days"
    # exit 0

    # --- Placeholder (remove this and uncomment an example or write your own) ---
    $currentValue = 50
    $detail = "Placeholder check: value is $currentValue"

    # ╔══════════════════════════════════════════════════════════╗
    # ║  END OF CHECK LOGIC                                      ║
    # ╚══════════════════════════════════════════════════════════╝

    Write-Log $detail

    # Write to UDF if configured
    if ($ResultUDF) {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
        Set-DattoUDF -UDF $ResultUDF -Value "$timestamp | $detail"
    }

    # Evaluate against thresholds
    if ($currentValue -ge $CriticalThreshold) {
        Write-Output "ALERT: $detail"
        Write-Log "Monitor ALERT: $detail" -Level ERROR
        exit 1
    }
    elseif ($currentValue -ge $WarningThreshold) {
        # Warning — still exit 0 (no alert) but log it
        # Change to exit 1 if you want warnings to alert
        Write-Output "WARNING: $detail"
        Write-Log "Monitor WARNING: $detail" -Level WARN
        exit 0
    }
    else {
        Write-Output "OK: $detail"
        Write-Log "Monitor OK: $detail"
        exit 0
    }
}
catch {
    # Unhandled error — alert so someone investigates
    $err = $_.Exception.Message
    Write-Output "ALERT: $MonitorName failed - $err"
    Write-Log "Monitor EXCEPTION: $err" -Level ERROR
    exit 1
}

#endregion
