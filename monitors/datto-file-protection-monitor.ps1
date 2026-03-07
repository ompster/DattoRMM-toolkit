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
      - Desktop/user mode: searches ALL profile paths (C:\Users\*, SYSTEM
        profile, service account profiles) and evaluates the MOST RECENTLY
        MODIFIED XML. This handles all DFP configurations:
          * Standard/unified mode: XML in logged-in user's profile
          * Service mode (deployed under named account): XML in deployment
            user's profile (e.g. C:\Users\DeployUser\...)
          * Service mode (LocalSystem): XML in SYSTEM profile
      - ONLY alerts on agent-online = "disconnected" (not transient states).
      - Suppresses all connection and staleness alerts while a backup is active.
      - Alerts if account is quarantined or deleted (not just disabled).
      - Alerts if last backup is older than MaxHoursSinceBackup (default 72 h).
      - Checks XML last-modified time -- if XML is stale, DFP likely not running.
      - Checks fileprotection.exe process AND DFP service (excludes shadow copy).
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
    Version: 2.1.0
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

function Set-DattoUDF {
    param(
        [Parameter(Mandatory)][ValidateRange(1, 30)][int]$UDF,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value
    )
    try {
        $regPath = 'HKLM:\SOFTWARE\CentraStage'
        $regName = "Custom$UDF"
        if (-not (Test-Path $regPath)) { return $false }
        Set-ItemProperty -Path $regPath -Name $regName -Value $Value -Force -ErrorAction Stop
        return $true
    } catch { return $false }
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

    # Desktop XML -- search ALL profile paths and pick the most recently modified.
    # DFP desktop can write its XML to different locations depending on config:
    #   - Standard/unified mode: logged-in user's profile (C:\Users\<user>\...)
    #   - Service mode (named account): deployment user's profile (e.g. C:\Users\DeployUser\...)
    #   - Service mode (LocalSystem): SYSTEM profile (C:\Windows\System32\config\systemprofile\...)
    # The correct XML is always the most recently modified one -- it's the one
    # DFP is actively updating. Stale XMLs from old unified-mode installs or
    # unlicensed users are naturally deprioritised by recency.

    $allProfilePaths = [System.Collections.Generic.List[string]]::new()

    # SYSTEM profile
    $systemProfile = "$env:SystemRoot\System32\config\systemprofile"
    if (Test-Path -LiteralPath $systemProfile -PathType Container) {
        $allProfilePaths.Add($systemProfile)
    }

    # Service account profiles
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

    # Find all desktop XMLs across every profile
    $allDesktopXmls = @()
    foreach ($profilePath in $allProfilePaths) {
        $candidate = Join-Path $profilePath $desktopRel
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $allDesktopXmls += Get-Item -LiteralPath $candidate -ErrorAction SilentlyContinue
        }
    }

    if ($allDesktopXmls.Count -gt 0) {
        # Pick the most recently modified XML -- this is the one DFP is actively updating
        $newest = $allDesktopXmls | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $foundXmls.Add($newest.FullName)
        Write-MonitorDiagnostic "Using most recent desktop XML: $($newest.FullName) (modified: $($newest.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))"
        if ($allDesktopXmls.Count -gt 1) {
            Write-MonitorDiagnostic "  Found $($allDesktopXmls.Count) desktop XML(s) total -- using newest"
        }
    }
    else {
        Write-MonitorDiagnostic "No desktop XML found in any profile"
    }

    Write-MonitorDiagnostic "XMLs to evaluate: $($foundXmls.Count)"

    # ------------------------------------------------------------------
    # 3a. Check DFP is actually running (process OR service)
    #     Desktop edition runs as fileprotection.exe (user process).
    #     Server edition runs as a Windows service -- the process name
    #     may differ, so we check both the process and the service.
    # ------------------------------------------------------------------
    $dfpProcess = Get-Process -Name 'fileprotection' -ErrorAction SilentlyContinue
    # Exclude shadow copy and other auxiliary services -- only match the core DFP service.
    # Known false matches: "Datto File Protection Shadow Copy Service"
    $dfpService = Get-Service -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.DisplayName -like '*Datto File Protection*' -or
             $_.DisplayName -like '*File Protection*' -or
             $_.Name -like '*FileProtection*' -or
             $_.Name -like '*DFP*') -and
            $_.DisplayName -notlike '*Shadow Copy*' -and
            $_.DisplayName -notlike '*Shadow*' -and
            $_.DisplayName -notlike '*VSS*' -and
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
        # Use the profile from whichever XML we selected
        foreach ($xmlPath in $foundXmls) {
            if ($xmlPath -like 'C:\Users\*') {
                $heartbeatProfile = ($xmlPath -split '\\')[0..2] -join '\'
                break
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
    # 7. Build UDF 4 summary and final decision
    # ------------------------------------------------------------------
    Write-MonitorDiagnostic "Execution time: $($stopwatch.ElapsedMilliseconds)ms"

    # Build UDF summary parts
    $udfParts = [System.Collections.Generic.List[string]]::new()
    foreach ($part in $summaryParts) {
        $udfParts.Add($part)
    }
    if ($dfpProcess) {
        $udfParts.Add("pid:$($dfpProcess.Id)")
    }
    elseif ($dfpService) {
        $udfParts.Add("svc:$($dfpService.Name)")
    }

    # Write UDF 4
    if ($alertReasons.Count -gt 0) {
        $shortAlerts = foreach ($reason in $alertReasons) {
            $reason -replace '\s*--\s*C:\\.*$', ''
        }
        $udfValue = "WARNING: $($shortAlerts -join ' | ')"
    }
    else {
        $udfValue = "OK: $($udfParts -join ' | ')"
    }
    if ($udfValue.Length -gt 255) { $udfValue = $udfValue.Substring(0, 252) + '...' }
    $udfResult = Set-DattoUDF -UDF 4 -Value $udfValue
    if ($udfResult) {
        Write-MonitorDiagnostic "UDF 4: $udfValue"
    }
    else {
        Write-MonitorDiagnostic "UDF 4 write failed"
    }

    # Final decision
    if ($alertReasons.Count -gt 0) {
        $alertMsg = $alertReasons -join ' | '
        Write-MonitorAlert $alertMsg
    }

    # Add process/service info to monitor summary
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
