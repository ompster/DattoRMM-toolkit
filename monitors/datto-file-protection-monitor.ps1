#Requires -Version 5.1
<#
.SYNOPSIS
    Datto File Protection - Health Monitor

.DESCRIPTION
    Monitors Datto File Protection (Desktop and Server editions) by parsing the
    official Datto status XML file that the agent writes on every check-in.

    Addresses two problems with the ComStore monitor:
      1. False positives -- transient connection states (connecting, authenticating,
         retry) and active backups no longer trigger alerts.
      2. Alerts not auto-resolving -- exit 0 when healthy so Datto RMM clears the
         alert automatically.

    Detection logic:
      - Server mode XML (ProgramData) is always evaluated if present.
      - Desktop/user mode: evaluates ONLY the logged-in user's XML. If no user
        is logged in, falls back to the most recently modified XML across all
        profiles. This avoids false positives from unlicensed users -- DFP is
        licensed per-user, so a new/different user's instance won't connect.
      - ONLY alerts on agent-online = "disconnected" (not transient states).
      - Suppresses all connection and staleness alerts while a backup is active.
      - Alerts if account is quarantined or deleted (not just disabled).
      - Alerts if last backup is older than MaxHoursSinceBackup (default 72 h).
      - Checks XML last-modified time -- if XML is stale, DFP likely not running.
      - Checks fileprotection.exe is actually running as a process.
      - Drops a heartbeat file in the user's Documents folder each run to ensure
        DFP always has something to back up (prevents "nothing new" false stale).
      - Falls back to a Datto service presence check when no XML exists yet.

.COMPONENT
    Category: Monitors
    Output Variable: Status
    Timeout: 120s (hard limit)
    Target: <200ms execution

.INPUTS
    Environment Variables:
    - $env:MaxHoursSinceBackup  [Integer]  Hours since last backup before staleness
                                           alert fires. Default: 72 (3 days).
    - $env:MaxXmlAgeHours      [Integer]  Hours since XML was last modified before
                                           alerting DFP is not running. Default: 4.

.NOTES
    Author: Nathan Ash
    Version: 1.4.0
    IMPORTANT: Monitors use Write-Host exclusively. Never Write-Output.
    IMPORTANT: Monitors embed all functions. Never dot-source external files.
#>

[CmdletBinding()]
param()

#region ================= EMBEDDED FUNCTIONS =======================

function Get-RMMVariable {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [ValidateSet('String', 'Integer', 'Boolean', 'Double')][string]$Type = 'String',
        $Default = $null
    )
    $envValue = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($envValue)) { return $Default }
    switch ($Type) {
        'Integer' { try { return [int]$envValue } catch { return $Default } }
        'Boolean' { return ($envValue -eq 'true' -or $envValue -eq '1' -or $envValue -eq 'yes') }
        'Double'  { try { return [double]$envValue } catch { return $Default } }
        default   { return $envValue }
    }
}

function Write-MonitorDiagnostic {
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    Write-Host $Message
}

function Write-MonitorAlert {
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    Write-Host '<-End Diagnostic->'
    Write-Host '<-Start Result->'
    Write-Host "Status=$Message"
    Write-Host '<-End Result->'
    exit 1
}

function Write-MonitorSuccess {
    param([Parameter(Mandatory, Position = 0)][string]$Message)
    Write-Host '<-End Diagnostic->'
    Write-Host '<-Start Result->'
    Write-Host "Status=$Message"
    Write-Host '<-End Result->'
    exit 0
}

#endregion

#region ================= DIAGNOSTIC PHASE =========================

Write-Host '<-Start Diagnostic->'
Write-MonitorDiagnostic "Monitor: Datto File Protection"
Write-MonitorDiagnostic "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC"

try {
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # ------------------------------------------------------------------
    # 1. Config
    # ------------------------------------------------------------------
    $maxHours = Get-RMMVariable -Name 'MaxHoursSinceBackup' -Type Integer -Default 72
    $maxXmlAge = Get-RMMVariable -Name 'MaxXmlAgeHours' -Type Integer -Default 4
    Write-MonitorDiagnostic "Config: MaxHoursSinceBackup=$maxHours, MaxXmlAgeHours=$maxXmlAge"

    # ------------------------------------------------------------------
    # 2. Build XML paths
    #    - Server mode: always check ProgramData path
    #    - Desktop/user mode: check ONLY the logged-in user's profile.
    #      If nobody is logged in, use the most recently modified XML.
    #      This avoids false positives from unlicensed user profiles --
    #      DFP is licensed per-user, so other users' instances won't
    #      connect and would falsely trigger disconnection alerts.
    # ------------------------------------------------------------------
    $serverXml  = 'C:\ProgramData\Datto\Common\Status Report - Datto File Protection Server.xml'
    $desktopRel = 'AppData\Local\Datto\Common\Status Report - Datto File Protection.xml'

    $foundXmls = [System.Collections.Generic.List[string]]::new()

    # Server XML -- always include if present
    if (Test-Path -LiteralPath $serverXml -PathType Leaf) {
        $foundXmls.Add($serverXml)
        Write-MonitorDiagnostic "Found server XML: $serverXml"
    }

    # Desktop XML -- determine which profile to use
    # Step 1: Get the currently logged-in interactive user
    #         Uses explorer.exe process owner (same approach as toolkit's Get-LoggedOnUser)
    $loggedInUser = $null
    $loggedInProfile = $null
    try {
        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
            Select-Object -First 1

        if ($explorer) {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
            $loggedInUser = $owner.User
            $domain = $owner.Domain
            Write-MonitorDiagnostic "Logged-in user: $domain\$loggedInUser"

            # Get profile path from registry (reliable, no guessing folder names)
            try {
                $userObj = New-Object System.Security.Principal.NTAccount($domain, $loggedInUser)
                $sid = $userObj.Translate([System.Security.Principal.SecurityIdentifier]).Value
                $loggedInProfile = Get-ItemPropertyValue "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -Name ProfileImagePath -ErrorAction Stop
            }
            catch {
                # Fallback: match by username in C:\Users
                $profilePath = Join-Path 'C:\Users' $loggedInUser
                if (Test-Path -LiteralPath $profilePath -PathType Container) {
                    $loggedInProfile = $profilePath
                }
                else {
                    $match = Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -eq $loggedInUser } |
                        Select-Object -First 1
                    if ($match) { $loggedInProfile = $match.FullName }
                }
            }

            if ($loggedInProfile) {
                Write-MonitorDiagnostic "Profile path: $loggedInProfile"
            }
        }
        else {
            Write-MonitorDiagnostic "No explorer.exe found -- no interactive user logged in"
        }
    }
    catch {
        Write-MonitorDiagnostic "Could not determine logged-in user: $($_.Exception.Message)"
    }

    # Step 2: Select the desktop XML
    # When DFP desktop runs as a service, the XML may be under the service
    # account's profile (e.g. SYSTEM profile at
    # C:\Windows\System32\config\systemprofile) rather than C:\Users\*.
    # We search all possible locations to handle both interactive and service modes.

    # Build a list of all profile paths to search (not just C:\Users)
    $allProfilePaths = [System.Collections.Generic.List[string]]::new()

    # SYSTEM profile -- DFP desktop running as a service often runs as SYSTEM
    $systemProfile = "$env:SystemRoot\System32\config\systemprofile"
    if (Test-Path -LiteralPath $systemProfile -PathType Container) {
        $allProfilePaths.Add($systemProfile)
    }

    # LocalService and NetworkService profiles
    $serviceProfiles = @(
        "$env:SystemRoot\ServiceProfiles\LocalService"
        "$env:SystemRoot\ServiceProfiles\NetworkService"
    )
    foreach ($sp in $serviceProfiles) {
        if (Test-Path -LiteralPath $sp -PathType Container) {
            $allProfilePaths.Add($sp)
        }
    }

    # All user profiles under C:\Users
    if (Test-Path -LiteralPath 'C:\Users' -PathType Container) {
        foreach ($profile in (Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
            $allProfilePaths.Add($profile.FullName)
        }
    }

    if ($loggedInProfile) {
        # Use the logged-in user's XML first
        $desktopXml = Join-Path $loggedInProfile $desktopRel
        if (Test-Path -LiteralPath $desktopXml -PathType Leaf) {
            $foundXmls.Add($desktopXml)
            Write-MonitorDiagnostic "Using logged-in user XML: $desktopXml"
        }
        else {
            Write-MonitorDiagnostic "Logged-in user has no DFP XML at: $desktopXml"
            # Fall through to search all profiles (DFP may be running as service)
            $loggedInProfile = $null
        }
    }

    if (-not $loggedInProfile) {
        # No logged-in user or their profile had no XML
        # Search all profile paths (including service accounts)
        Write-MonitorDiagnostic "Searching all profile paths for desktop XML (including service accounts)"
        $allDesktopXmls = @()
        foreach ($profilePath in $allProfilePaths) {
            $candidate = Join-Path $profilePath $desktopRel
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $allDesktopXmls += Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
            }
        }

        if ($allDesktopXmls.Count -gt 0) {
            $newest = $allDesktopXmls | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $foundXmls.Add($newest.FullName)
            Write-MonitorDiagnostic "Using most recent desktop XML: $($newest.FullName) (modified: $($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))"
            if ($allDesktopXmls.Count -gt 1) {
                Write-MonitorDiagnostic "  Skipped $($allDesktopXmls.Count - 1) other XML(s) to avoid unlicensed user false positives"
            }
        }
        else {
            Write-MonitorDiagnostic "No desktop XML found in any profile (including service accounts)"
        }
    }

    Write-MonitorDiagnostic "XMLs to evaluate: $($foundXmls.Count)"

    # ------------------------------------------------------------------
    # 3a. Check DFP is actually running (process OR service)
    #     Desktop edition runs as fileprotection.exe (user process).
    #     Server edition runs as a Windows service -- the process name
    #     may differ, so we check both the process and the service.
    # ------------------------------------------------------------------
    $dfpProcess = Get-Process -Name 'fileprotection' -ErrorAction SilentlyContinue
    $dfpService = Get-Service -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.DisplayName -like '*Datto File Protection*' -or
             $_.DisplayName -like '*File Protection*' -or
             $_.Name -like '*FileProtection*' -or
             $_.Name -like '*DFP*') -and
            $_.Status -eq 'Running'
        } | Select-Object -First 1
    $dfpRunning = $null -ne $dfpProcess -or $null -ne $dfpService

    if ($dfpProcess) {
        Write-MonitorDiagnostic "fileprotection.exe is running (PID: $($dfpProcess.Id))"
    }
    if ($dfpService) {
        Write-MonitorDiagnostic "DFP service is running: '$($dfpService.DisplayName)' [$($dfpService.Name)]"
    }
    if (-not $dfpRunning) {
        Write-MonitorDiagnostic "DFP is NOT running (no process, no service)"
    }

    # ------------------------------------------------------------------
    # 3b. Drop heartbeat file in user's Documents folder
    #     Ensures DFP always has something new to back up, preventing
    #     false "stale backup" alerts when no user files have changed.
    # ------------------------------------------------------------------
    try {
        $heartbeatProfile = $null
        if ($loggedInProfile) {
            $heartbeatProfile = $loggedInProfile
        }
        else {
            # No logged-in user -- use the same profile we picked for XML
            foreach ($xmlPath in $foundXmls) {
                if ($xmlPath -like 'C:\Users\*') {
                    $heartbeatProfile = ($xmlPath -split '\\')[0..2] -join '\'
                    break
                }
            }
        }

        if ($heartbeatProfile) {
            $docsFolder = Join-Path $heartbeatProfile 'Documents'
            if (Test-Path -LiteralPath $docsFolder -PathType Container) {
                $heartbeatFile = Join-Path $docsFolder '.datto-monitor-heartbeat'
                $heartbeatContent = "DFP Monitor Heartbeat - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                [System.IO.File]::WriteAllText($heartbeatFile, $heartbeatContent)
                Write-MonitorDiagnostic "Heartbeat file updated: $heartbeatFile"
                $summaryParts.Add("heartbeat:ok")
            }
            else {
                Write-MonitorDiagnostic "Documents folder not found at: $docsFolder -- skipping heartbeat"
            }
        }
        else {
            Write-MonitorDiagnostic "No profile available for heartbeat file -- skipping"
        }
    }
    catch {
        Write-MonitorDiagnostic "Heartbeat file write failed: $($_.Exception.Message)"
    }

    # ------------------------------------------------------------------
    # 4. No XML found -- fall back to service presence check
    # ------------------------------------------------------------------
    if ($foundXmls.Count -eq 0) {
        Write-MonitorDiagnostic "No status XML found. Checking for Datto service..."
        $dattoService = Get-Service -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Datto*' -or $_.Name -like '*Datto*' } |
            Select-Object -First 1

        if ($dattoService) {
            Write-MonitorDiagnostic "Datto service found: '$($dattoService.DisplayName)' [$($dattoService.Status)]"
            Write-MonitorDiagnostic "Execution time: $($stopwatch.ElapsedMilliseconds)ms"
            Write-MonitorSuccess "OK: Datto service '$($dattoService.DisplayName)' found; status XML not yet created (agent may be initializing)"
        }
        else {
            Write-MonitorDiagnostic "No Datto service found."
            Write-MonitorDiagnostic "Execution time: $($stopwatch.ElapsedMilliseconds)ms"
            Write-MonitorAlert "CRITICAL: Datto File Protection not installed or not initialized -- no status XML and no Datto service detected"
        }
    }

    # ------------------------------------------------------------------
    # 5. Parse each XML and evaluate health
    # ------------------------------------------------------------------

    # Transient agent-online states that must NOT trigger an alert.
    # Only "disconnected" is a genuine failure state.
    $transientStates = @('connecting', 'authenticating', 'retry', 'low-disk-space')

    $alertReasons = [System.Collections.Generic.List[string]]::new()
    $summaryParts  = [System.Collections.Generic.List[string]]::new()

    # Helper: read a named field from a Datto status XML element.
    # Datto stores monitoring values as <value name="field-name">content</value>.
    # Root-level metadata (now, platform, version) are XML attributes on <status-report>.
    function Get-DattoXmlField {
        param(
            [System.Xml.XmlElement]$Node,
            [string]$Field
        )
        # Root-level XML attributes (e.g. "now", "platform", "version")
        $attr = $Node.GetAttribute($Field)
        if (![string]::IsNullOrEmpty($attr)) { return $attr }
        # Monitoring values: <value name="field-name">content</value>
        $child = $Node.SelectSingleNode("value[@name='$Field']")
        if ($child) { return $child.InnerText }
        return $null
    }

    foreach ($xmlPath in $foundXmls) {
        Write-MonitorDiagnostic "--- Evaluating: $xmlPath ---"

        # Check XML file age -- if DFP isn't running, the XML goes stale
        try {
            $xmlFile = Get-Item -LiteralPath $xmlPath -ErrorAction Stop
            $xmlAgeHours = [Math]::Round(([DateTime]::Now - $xmlFile.LastWriteTime).TotalHours, 1)
            Write-MonitorDiagnostic "  XML last modified  : $($xmlFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) ($xmlAgeHours h ago)"

            $summaryParts.Add("xml-age:${xmlAgeHours}h")

            if ($xmlAgeHours -gt $maxXmlAge) {
                $staleMsg = "STALE XML: Status file not updated in $xmlAgeHours h (threshold: $maxXmlAge h) -- DFP likely not running -- $xmlPath"
                if (-not $dfpRunning) {
                    $alertReasons.Add("$staleMsg (DFP confirmed NOT running)")
                }
                else {
                    Write-MonitorDiagnostic "  XML is stale but DFP is running -- possible issue"
                    $alertReasons.Add($staleMsg)
                }
            }
        }
        catch {
            Write-MonitorDiagnostic "  Could not check XML age: $($_.Exception.Message)"
        }

        # Parse XML -- catch per-file so one bad file doesn't block others
        try {
            $raw = Get-Content -LiteralPath $xmlPath -Raw -Encoding UTF8 -ErrorAction Stop
            [xml]$doc = $raw
        }
        catch {
            Write-MonitorDiagnostic "  Parse error: $($_.Exception.Message)"
            $alertReasons.Add("XML parse error for '${xmlPath}': $($_.Exception.Message)")
            continue
        }

        $root = $doc.DocumentElement

        $agentOnline          = Get-DattoXmlField $root 'agent-online'
        $subscriptionStatus   = Get-DattoXmlField $root 'agent-subscription-status'
        $backupActive         = Get-DattoXmlField $root 'backup-active'
        $backupPct            = Get-DattoXmlField $root 'backup-percent-complete'
        $backupLastComplete   = Get-DattoXmlField $root 'backup-last-complete'
        $agentVersion         = Get-DattoXmlField $root 'agent-version'

        # Normalise
        $agentOnline        = if ($agentOnline)        { $agentOnline.Trim().ToLower() }        else { 'unknown' }
        $subscriptionStatus = if ($subscriptionStatus) { $subscriptionStatus.Trim().ToLower() } else { 'unknown' }
        $isBackupActive     = ($backupActive -eq 'true' -or $backupActive -eq '1')

        Write-MonitorDiagnostic "  Agent version      : $(if ($agentVersion) { $agentVersion } else { 'N/A' })"
        Write-MonitorDiagnostic "  Subscription status: $subscriptionStatus"
        Write-MonitorDiagnostic "  Agent online       : $agentOnline"
        Write-MonitorDiagnostic "  Backup active      : $isBackupActive$(if ($isBackupActive -and $backupPct) { " ($backupPct%)" })"

        # ---- 5a. Subscription status ----
        # Alert on quarantined (ransomware lockdown) or deleted (account removed).
        # Do NOT alert on disabled (intentional suspension).
        if ($subscriptionStatus -eq 'quarantined') {
            $alertReasons.Add("QUARANTINED: Device is in ransomware lockdown (subscription quarantined) -- $xmlPath")
        }
        elseif ($subscriptionStatus -eq 'deleted') {
            $alertReasons.Add("DELETED: Datto account/subscription has been deleted -- $xmlPath")
        }

        # ---- 5b. Connection state ----
        # Only alert on explicit "disconnected". Transient states are normal during
        # network changes, reboots, or credential refreshes. If a backup is active
        # the connection is clearly working -- suppress to avoid race-condition alerts.
        if ($agentOnline -eq 'disconnected' -and -not $isBackupActive) {
            $alertReasons.Add("DISCONNECTED: Agent is disconnected from Datto cloud -- $xmlPath")
        }
        elseif ($agentOnline -in $transientStates) {
            Write-MonitorDiagnostic "  Connection state '$agentOnline' is transient -- not alerting"
        }

        # ---- 5c. Backup staleness ----
        # Convert Unix epoch to UTC DateTime. Skip if backup is active right now.
        if ($backupLastComplete -and $backupLastComplete -ne '0') {
            try {
                $epochSecs  = [long]$backupLastComplete
                $lastBackup = [DateTimeOffset]::FromUnixTimeSeconds($epochSecs).UtcDateTime
                $hoursAgo   = [Math]::Round(([DateTime]::UtcNow - $lastBackup).TotalHours, 1)
                Write-MonitorDiagnostic "  Last backup        : $($lastBackup.ToString('yyyy-MM-dd HH:mm:ss')) UTC ($hoursAgo h ago)"

                if ($isBackupActive) {
                    Write-MonitorDiagnostic "  Staleness check skipped -- backup currently in progress"
                }
                elseif ($hoursAgo -gt $maxHours) {
                    $alertReasons.Add("STALE BACKUP: Last backup was $hoursAgo h ago (threshold: $maxHours h) -- $xmlPath")
                }

                $summaryParts.Add("last backup ${hoursAgo}h ago")
            }
            catch {
                Write-MonitorDiagnostic "  Could not parse backup-last-complete value '$backupLastComplete': $($_.Exception.Message)"
            }
        }
        else {
            Write-MonitorDiagnostic "  Last backup        : N/A (no completed backup recorded yet)"
            # Do not alert: agent may be newly installed with no backup run yet.
        }

        # Build per-file summary for success message
        $summaryParts.Add("agent:$agentOnline")
        $summaryParts.Add("sub:$subscriptionStatus")
    }

    # ------------------------------------------------------------------
    # 6. DFP-not-running check (if XML exists but neither process nor service is alive)
    # ------------------------------------------------------------------
    if (-not $dfpRunning -and $foundXmls.Count -gt 0) {
        # Only alert if we haven't already flagged it via stale XML
        $alreadyFlagged = $alertReasons | Where-Object { $_ -like '*NOT running*' -or $_ -like '*STALE XML*' }
        if (-not $alreadyFlagged) {
            $alertReasons.Add("DFP DOWN: Neither fileprotection.exe process nor DFP service is running (XML exists but DFP is dead)")
        }
    }

    # ------------------------------------------------------------------
    # 7. Single decision point
    # ------------------------------------------------------------------
    Write-MonitorDiagnostic "Execution time: $($stopwatch.ElapsedMilliseconds)ms"

    if ($alertReasons.Count -gt 0) {
        $alertMsg = $alertReasons -join ' | '
        Write-MonitorAlert $alertMsg
    }

    # Add process/service and heartbeat info to summary
    if ($dfpProcess) {
        $summaryParts.Add("process:running(PID:$($dfpProcess.Id))")
    }
    elseif ($dfpService) {
        $summaryParts.Add("service:running($($dfpService.Name))")
    }
    else {
        $summaryParts.Add("dfp:NOT RUNNING")
    }

    $summary = if ($summaryParts.Count -gt 0) { $summaryParts -join ', ' } else { 'agent healthy' }
    Write-MonitorSuccess "OK: $summary"
}
catch {
    Write-MonitorDiagnostic "ERROR: $($_.Exception.Message)"
    Write-MonitorDiagnostic "Stack: $($_.ScriptStackTrace)"
    Write-MonitorAlert "CRITICAL: Monitor exception -- $($_.Exception.Message)"
}

#endregion
