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
