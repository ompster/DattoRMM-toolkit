#Requires -Version 5.1
<#
.SYNOPSIS
    Datto RMM Component Toolkit - Reusable helper functions
.DESCRIPTION
    Drop this at the top of your components or dot-source it.
    Covers: UDF writing, structured logging, exit codes, 
    run-as-user, and registry manipulation (current user + all users).
.AUTHOR
    Nathan Ash
.VERSION
    1.0.0
#>

#region ========================= LOGGING =========================

# Global log path - Datto components run from a temp dir, so we log to a known location
$script:LogPath = "$env:ProgramData\CentraStage\Logs\component-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-Log {
    <#
    .SYNOPSIS
        Structured logging with severity levels. Outputs to file + stdout (which Datto captures).
    .PARAMETER Message
        Log message text.
    .PARAMETER Level
        Severity: INFO, WARN, ERROR, DEBUG. Default: INFO.
    .PARAMETER LogFile
        Override the default log path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',

        [string]$LogFile = $script:LogPath
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"

    # Ensure log directory exists
    $logDir = Split-Path $LogFile -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    # Write to file
    Add-Content -Path $LogFile -Value $entry -Encoding UTF8

    # Write to stdout/stderr (Datto captures this in component output)
    switch ($Level) {
        'ERROR' { Write-Error $Message }
        'WARN'  { Write-Warning $Message }
        'DEBUG' { Write-Verbose $Message -Verbose }
        default { Write-Output $entry }
    }
}

function Write-LogSection {
    <#
    .SYNOPSIS
        Visual separator in logs for readability.
    #>
    param([string]$Title)
    Write-Log "========== $Title =========="
}

#endregion

#region ========================= EXIT CODES =========================

<#
    Datto RMM Exit Code Conventions:
    0   = Success
    1   = Failure (generic)
    
    For MONITORS (Component Monitor type):
    The exit code determines alert state. Convention:
    0   = Healthy / OK
    1   = Alert / Failed
    
    Custom exit codes for your own tracking:
    0   = Success
    1   = General failure
    2   = Prereq not met / not applicable
    3   = Timeout
    4   = Reboot required
    5   = Partial success (some items failed)
    10  = Access denied / insufficient permissions
    20  = Network/connectivity failure
#>

function Exit-Component {
    <#
    .SYNOPSIS
        Clean exit with logging. Use this instead of raw 'exit'.
    .PARAMETER ExitCode
        Exit code (0 = success, non-zero = failure).
    .PARAMETER Message
        Final message to log before exiting.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$ExitCode,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $level = if ($ExitCode -eq 0) { 'INFO' } else { 'ERROR' }
    Write-Log $Message -Level $level
    Write-Log "Exiting with code: $ExitCode"

    # Flush any remaining output
    [Console]::Out.Flush()

    exit $ExitCode
}

# Convenience wrappers
function Exit-Success { 
    param([string]$Message = 'Component completed successfully.')
    Exit-Component -ExitCode 0 -Message $Message 
}

function Exit-Failure { 
    param([string]$Message = 'Component failed.', [int]$ExitCode = 1)
    Exit-Component -ExitCode $ExitCode -Message $Message 
}

function Exit-NotApplicable {
    param([string]$Message = 'Component not applicable to this device.')
    Exit-Component -ExitCode 2 -Message $Message
}

function Exit-RebootRequired {
    param([string]$Message = 'Reboot required to complete.')
    Exit-Component -ExitCode 4 -Message $Message
}

#endregion

#region ========================= UDF WRITING =========================

<#
    Datto RMM User Defined Fields (UDFs):
    - UDF 1-30 available per device
    - Written via environment variables: $env:UDF_1 through $env:UDF_30
    - BUT you must use the Datto API or registry to persist them
    - The agent picks up UDF values from the registry
    
    Registry location:
    HKLM:\SOFTWARE\CentraStage\Custom<N> where N = UDF number
#>

function Set-DattoUDF {
    <#
    .SYNOPSIS
        Write a value to a Datto RMM User Defined Field (UDF 1-30).
    .PARAMETER UDF
        UDF number (1-30).
    .PARAMETER Value
        Value to write. Max ~255 chars recommended for UI display.
    .EXAMPLE
        Set-DattoUDF -UDF 1 -Value "Windows 11 23H2"
        Set-DattoUDF -UDF 15 -Value "BitLocker: Enabled | TPM: 2.0"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 30)]
        [int]$UDF,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    try {
        $regPath = 'HKLM:\SOFTWARE\CentraStage'
        $regName = "Custom$UDF"

        if (-not (Test-Path $regPath)) {
            Write-Log "CentraStage registry path not found — is the Datto agent installed?" -Level ERROR
            return $false
        }

        Set-ItemProperty -Path $regPath -Name $regName -Value $Value -Force
        
        # Also set the env var for same-session reads
        [Environment]::SetEnvironmentVariable("UDF_$UDF", $Value, 'Process')
        
        Write-Log "UDF $UDF set to: $Value"
        return $true
    }
    catch {
        Write-Log "Failed to set UDF $UDF — $_" -Level ERROR
        return $false
    }
}

function Get-DattoUDF {
    <#
    .SYNOPSIS
        Read the current value of a UDF.
    .PARAMETER UDF
        UDF number (1-30).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 30)]
        [int]$UDF
    )

    try {
        $regPath = 'HKLM:\SOFTWARE\CentraStage'
        $regName = "Custom$UDF"
        $value = Get-ItemPropertyValue -Path $regPath -Name $regName -ErrorAction SilentlyContinue
        return $value
    }
    catch {
        return $null
    }
}

function Set-DattoUDFTimestamp {
    <#
    .SYNOPSIS
        Write a UDF with a timestamp prefix for tracking when it was last updated.
    .EXAMPLE
        Set-DattoUDFTimestamp -UDF 20 -Value "Disk Cleanup: 4.2GB freed"
        # Result: "2026-02-11 17:30 | Disk Cleanup: 4.2GB freed"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 30)]
        [int]$UDF,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $timestamped = "$(Get-Date -Format 'yyyy-MM-dd HH:mm') | $Value"
    Set-DattoUDF -UDF $UDF -Value $timestamped
}

#endregion

#region =================== RUN AS LOGGED-IN USER ===================

function Get-LoggedOnUser {
    <#
    .SYNOPSIS
        Get the currently logged-on console user (interactive session).
    .OUTPUTS
        PSObject with Username, Domain, SID, SessionId, ProfilePath properties.
        Returns $null if no interactive user is logged in.
    #>
    [CmdletBinding()]
    param()

    try {
        # Get explorer.exe owner — most reliable way to find the interactive user
        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
            Select-Object -First 1

        if (-not $explorer) {
            Write-Log "No explorer.exe found — no interactive user logged in" -Level WARN
            return $null
        }

        $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
        $username = $owner.User
        $domain = $owner.Domain

        # Get SID
        $userObj = New-Object System.Security.Principal.NTAccount($domain, $username)
        $sid = $userObj.Translate([System.Security.Principal.SecurityIdentifier]).Value

        # Get profile path
        $profilePath = (Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -Name ProfileImagePath -ErrorAction SilentlyContinue)

        $sessionId = $explorer.SessionId

        $result = [PSCustomObject]@{
            Username    = $username
            Domain      = $domain
            FullName    = "$domain\$username"
            SID         = $sid
            SessionId   = $sessionId
            ProfilePath = $profilePath
        }

        Write-Log "Logged-on user: $($result.FullName) (SID: $sid, Session: $sessionId)"
        return $result
    }
    catch {
        Write-Log "Failed to get logged-on user: $_" -Level ERROR
        return $null
    }
}

function Invoke-AsLoggedOnUser {
    <#
    .SYNOPSIS
        Execute a script block as the currently logged-on user.
        Uses scheduled task trick — creates a task, runs it in the user's session, captures output.
    .PARAMETER ScriptBlock
        The code to run as the user.
    .PARAMETER ArgumentList
        Arguments to pass to the script block.
    .PARAMETER Timeout
        Max seconds to wait for completion. Default: 120.
    .EXAMPLE
        Invoke-AsLoggedOnUser -ScriptBlock {
            [System.Windows.Forms.MessageBox]::Show("Hello from $env:USERNAME!")
        }
    .EXAMPLE
        $result = Invoke-AsLoggedOnUser -ScriptBlock {
            param($AppName)
            Get-Process $AppName -ErrorAction SilentlyContinue | Select-Object Name, CPU
        } -ArgumentList 'chrome'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList,

        [int]$Timeout = 120
    )

    $user = Get-LoggedOnUser
    if (-not $user) {
        Write-Log "No logged-on user found — cannot run as user" -Level ERROR
        return $null
    }

    $taskName = "DattoRMM_RunAsUser_$(Get-Random)"
    $outputFile = "$env:TEMP\$taskName.xml"
    $errorFile = "$env:TEMP\$taskName.err"
    $exitCodeFile = "$env:TEMP\$taskName.exit"

    try {
        # Build the script to execute
        $argString = if ($ArgumentList) {
            ($ArgumentList | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ','
        } else { '' }

        $encodedScript = @"
try {
    `$output = & { $ScriptBlock } $argString
    `$output | Export-Clixml -Path '$outputFile' -Force
    `$LASTEXITCODE | Out-File -FilePath '$exitCodeFile' -Force
} catch {
    `$_.Exception.Message | Out-File -FilePath '$errorFile' -Force
    1 | Out-File -FilePath '$exitCodeFile' -Force
}
"@

        $bytes = [System.Text.Encoding]::Unicode.GetBytes($encodedScript)
        $encoded = [Convert]::ToBase64String($bytes)

        # Create and run scheduled task as the logged-on user
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
        $principal = New-ScheduledTaskPrincipal -UserId $user.FullName -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds $Timeout)

        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Running script as $($user.FullName) via scheduled task"

        Start-ScheduledTask -TaskName $taskName

        # Wait for completion
        $elapsed = 0
        do {
            Start-Sleep -Seconds 2
            $elapsed += 2
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            $taskState = (Get-ScheduledTask -TaskName $taskName).State
        } while ($taskState -eq 'Running' -and $elapsed -lt $Timeout)

        if ($taskState -eq 'Running') {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Write-Log "Task timed out after $Timeout seconds" -Level WARN
        }

        # Collect output
        if (Test-Path $errorFile) {
            $err = Get-Content $errorFile -Raw
            Write-Log "User-context error: $err" -Level ERROR
            return $null
        }

        if (Test-Path $outputFile) {
            $result = Import-Clixml $outputFile
            Write-Log "User-context script completed successfully"
            return $result
        }

        Write-Log "No output captured from user-context script" -Level WARN
        return $null
    }
    finally {
        # Cleanup
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $outputFile, $errorFile, $exitCodeFile -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region ================= REGISTRY - LOGGED-IN USER =================

function Get-UserRegistryPaths {
    <#
    .SYNOPSIS
        Get registry hive paths for modifying user registries.
    .PARAMETER Target
        'Current' = logged-on user only
        'All'     = all user profiles (loads offline hives)
    .OUTPUTS
        Array of objects with SID, Username, HivePath, MountPoint, NeedsUnload properties.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Current', 'All')]
        [string]$Target
    )

    $results = @()

    if ($Target -eq 'Current') {
        $user = Get-LoggedOnUser
        if (-not $user) {
            Write-Log "No logged-on user for registry operation" -Level ERROR
            return @()
        }

        # Logged-in user's hive is already mounted under HKU\<SID>
        $results += [PSCustomObject]@{
            SID          = $user.SID
            Username     = $user.FullName
            HivePath     = "Registry::HKEY_USERS\$($user.SID)"
            NtUserDat    = "$($user.ProfilePath)\NTUSER.DAT"
            NeedsMount   = $false
            MountPoint   = $null
        }
    }
    else {
        # All users — enumerate profile list
        $profileList = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' |
            Where-Object { $_.PSChildName -match '^S-1-5-21-' }

        foreach ($profile in $profileList) {
            $sid = $profile.PSChildName
            $profilePath = $profile.GetValue('ProfileImagePath')
            $ntuser = "$profilePath\NTUSER.DAT"
            $username = try { 
                ([System.Security.Principal.SecurityIdentifier]$sid).Translate([System.Security.Principal.NTAccount]).Value 
            } catch { $sid }

            # Check if hive is already loaded (user is logged in)
            $loaded = Test-Path "Registry::HKEY_USERS\$sid"

            $results += [PSCustomObject]@{
                SID          = $sid
                Username     = $username
                HivePath     = if ($loaded) { "Registry::HKEY_USERS\$sid" } else { $null }
                NtUserDat    = $ntuser
                NeedsMount   = -not $loaded
                MountPoint   = if (-not $loaded) { "HKU\DattoRMM_$($sid.Split('-')[-1])" } else { $null }
            }
        }
    }

    return $results
}

function Invoke-UserRegistryAction {
    <#
    .SYNOPSIS
        Execute a script block against user registry hives.
        Handles mounting/unmounting offline hives automatically.
    .PARAMETER Target
        'Current' = logged-on user only.
        'All'     = iterate all user profiles.
    .PARAMETER Action
        Script block receiving $HivePath and $UserInfo parameters.
    .EXAMPLE
        # Disable Cortana for all users
        Invoke-UserRegistryAction -Target All -Action {
            param($HivePath, $UserInfo)
            $path = "$HivePath\SOFTWARE\Microsoft\Windows\CurrentVersion\Search"
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            Set-ItemProperty -Path $path -Name 'CortanaConsent' -Value 0 -Type DWord -Force
            Write-Log "Disabled Cortana for $($UserInfo.Username)"
        }
    .EXAMPLE
        # Set default browser homepage for current user
        Invoke-UserRegistryAction -Target Current -Action {
            param($HivePath, $UserInfo)
            $path = "$HivePath\SOFTWARE\Microsoft\Edge\Main"
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            Set-ItemProperty -Path $path -Name 'Start Page' -Value 'https://intranet.company.com' -Force
            Write-Log "Set Edge homepage for $($UserInfo.Username)"
        }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Current', 'All')]
        [string]$Target,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $users = Get-UserRegistryPaths -Target $Target
    $successCount = 0
    $failCount = 0

    foreach ($user in $users) {
        $hivePath = $user.HivePath
        $mounted = $false

        try {
            # Mount offline hive if needed
            if ($user.NeedsMount) {
                if (-not (Test-Path $user.NtUserDat)) {
                    Write-Log "NTUSER.DAT not found for $($user.Username) at $($user.NtUserDat)" -Level WARN
                    $failCount++
                    continue
                }

                Write-Log "Mounting hive for $($user.Username): $($user.MountPoint)"
                $loadResult = & reg.exe load $user.MountPoint $user.NtUserDat 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Failed to mount hive for $($user.Username): $loadResult" -Level ERROR
                    $failCount++
                    continue
                }
                $hivePath = "Registry::$($user.MountPoint -replace '\\','\')"
                $mounted = $true
            }

            # Execute the action
            & $Action $hivePath $user
            $successCount++
        }
        catch {
            Write-Log "Registry action failed for $($user.Username): $_" -Level ERROR
            $failCount++
        }
        finally {
            # Unmount if we mounted it
            if ($mounted) {
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                Start-Sleep -Milliseconds 500
                $unloadResult = & reg.exe unload $user.MountPoint 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "Warning: Failed to unload hive $($user.MountPoint): $unloadResult" -Level WARN
                }
                else {
                    Write-Log "Unloaded hive for $($user.Username)"
                }
            }
        }
    }

    Write-Log "Registry action complete: $successCount succeeded, $failCount failed"
    return @{ Success = $successCount; Failed = $failCount }
}

#endregion

#region =================== DATTO ENVIRONMENT ======================

function Get-DattoVariable {
    <#
    .SYNOPSIS
        Read a Datto RMM site or component variable.
        Datto injects these as environment variables with specific prefixes.
    .PARAMETER Name
        Variable name (without prefix). Datto vars are usually CS_*, env:CS_PROFILE_*, or userdefined_*.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Datto component variables come through as env vars
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) {
        # Try common prefixes
        foreach ($prefix in @('CS_', 'cs_', 'userdefined_', 'env:')) {
            $value = [Environment]::GetEnvironmentVariable("$prefix$Name")
            if ($null -ne $value) { break }
        }
    }
    return $value
}

function Test-DattoAgent {
    <#
    .SYNOPSIS
        Verify the Datto RMM agent is installed and running.
    #>
    $service = Get-Service -Name 'CagService' -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Log "Datto RMM agent service (CagService) not found" -Level ERROR
        return $false
    }
    if ($service.Status -ne 'Running') {
        Write-Log "Datto RMM agent service is $($service.Status)" -Level WARN
        return $false
    }
    Write-Log "Datto RMM agent is running"
    return $true
}

#endregion

#region ===================== EXAMPLE USAGE =========================

<#
    ===== EXAMPLE: Complete component using the toolkit =====

    # Dot-source the toolkit (or paste functions at top of component)
    . "$PSScriptRoot\DattoRMM-Toolkit.ps1"

    Write-LogSection "Starting Disk Usage Check"

    # Verify agent
    if (-not (Test-DattoAgent)) {
        Exit-Failure "Datto agent not running"
    }

    # Get logged-on user info
    $user = Get-LoggedOnUser
    if ($user) {
        Write-Log "Current user: $($user.FullName)"
    }

    # Check disk space
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 1)
    $totalGB = [math]::Round($disk.Size / 1GB, 1)
    $pctFree = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)

    # Write to UDF
    Set-DattoUDFTimestamp -UDF 5 -Value "C: ${freeGB}GB free of ${totalGB}GB ($pctFree%)"

    # Modify registry for all users (example: disable first-run wizard)
    Invoke-UserRegistryAction -Target All -Action {
        param($HivePath, $UserInfo)
        $path = "$HivePath\SOFTWARE\Microsoft\Edge\Main"
        if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
        Set-ItemProperty -Path $path -Name 'PreventFirstRunPage' -Value 1 -Type DWord -Force
        Write-Log "Disabled Edge first-run for $($UserInfo.Username)"
    }

    # Exit based on threshold
    if ($pctFree -lt 10) {
        Exit-Failure "Disk space critical: $pctFree% free"
    } else {
        Exit-Success "Disk space OK: $pctFree% free"
    }
#>

#endregion
