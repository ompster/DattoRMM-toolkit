function Get-UserRegistryPaths {
    <#
    .SYNOPSIS
        Get registry hive paths for modifying user registries.
    .PARAMETER Target
        'Current' = logged-on user only
        'All'     = all user profiles (loads offline hives)
    .OUTPUTS
        Array of objects with SID, Username, HivePath, MountPoint, NeedsMount properties.
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
