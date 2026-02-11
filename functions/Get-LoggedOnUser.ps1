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
