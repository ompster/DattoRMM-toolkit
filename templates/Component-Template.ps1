#Requires -Version 5.1
<#
.SYNOPSIS
    Datto RMM Component Template
.DESCRIPTION
    Use this as a starting point for standard components (one-off or scheduled jobs).
    
    How Components work in Datto RMM:
    - Run on-demand or on a schedule via policies
    - Exit 0 = success, non-zero = failure (logged in activity feed)
    - stdout/stderr captured as component output
    - Can accept site variables and component variables as input
    
.NOTES
    Component Type: Script
    Run As: System (default) — use Invoke-AsLoggedOnUser for user-context tasks
#>

#region ========================= TOOLKIT =========================
# Paste the functions you need from DattoRMM-Toolkit.ps1

$script:LogPath = "$env:ProgramData\CentraStage\Logs\component-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

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

#region ====================== VARIABLES ==========================

# Site variables (defined in Datto site settings, injected as env vars)
# $SiteVar = $env:CS_PROFILE_DATA   # Example — check your site variable names

# Component variables (defined when creating the component in Datto UI)
# $InputVar = $env:userdefined_MyVariable

#endregion

#region ========================= MAIN ============================

Write-Log "========== Component Starting =========="
Write-Log "Computer: $env:COMPUTERNAME"
Write-Log "User context: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

try {
    # ╔══════════════════════════════════════════════════════════╗
    # ║  YOUR COMPONENT LOGIC GOES HERE                          ║
    # ╚══════════════════════════════════════════════════════════╝



    # ╔══════════════════════════════════════════════════════════╗
    # ║  END OF COMPONENT LOGIC                                  ║
    # ╚══════════════════════════════════════════════════════════╝

    Write-Output "Component completed successfully"
    Write-Log "Component completed successfully"
    exit 0
}
catch {
    $err = $_.Exception.Message
    $line = $_.InvocationInfo.ScriptLineNumber
    Write-Output "FAILED: $err (line $line)"
    Write-Log "EXCEPTION at line $line - $err" -Level ERROR
    Write-Log $_.ScriptStackTrace -Level ERROR
    exit 1
}

#endregion
