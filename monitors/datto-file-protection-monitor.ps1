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
      - Finds status XML for Server mode (ProgramData) and/or Desktop/user mode
        (all profiles under C:\Users\) since the monitor runs as SYSTEM.
      - ONLY alerts on agent-online = "disconnected" (not transient states).
      - Suppresses all connection and staleness alerts while a backup is active.
      - Alerts if account is quarantined or deleted (not just disabled).
      - Alerts if last backup is older than MaxHoursSinceBackup (default 72 h).
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

.NOTES
    Author: Nathan Ash
    Version: 1.0.0
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
    Write-MonitorDiagnostic "Config: MaxHoursSinceBackup=$maxHours"

    # ------------------------------------------------------------------
    # 2. Build candidate XML paths
    #    - Server mode: single well-known ProgramData path
    #    - Desktop/user mode: one file per user profile under C:\Users\
    #      (SYSTEM cannot use $env:USERPROFILE; must enumerate explicitly)
    # ------------------------------------------------------------------
    $serverXml  = 'C:\ProgramData\Datto\Common\Status Report - Datto File Protection Server.xml'
    $desktopRel = 'AppData\Local\Datto\Common\Status Report - Datto File Protection.xml'

    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($serverXml)

    if (Test-Path -LiteralPath 'C:\Users' -PathType Container) {
        foreach ($profile in (Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue)) {
            $candidates.Add((Join-Path $profile.FullName $desktopRel))
        }
    }

    Write-MonitorDiagnostic "XML candidates to check: $($candidates.Count)"

    # ------------------------------------------------------------------
    # 3. Locate existing XML files
    # ------------------------------------------------------------------
    $foundXmls = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $foundXmls.Add($path)
            Write-MonitorDiagnostic "Found XML: $path"
        }
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
    # 6. Single decision point
    # ------------------------------------------------------------------
    Write-MonitorDiagnostic "Execution time: $($stopwatch.ElapsedMilliseconds)ms"

    if ($alertReasons.Count -gt 0) {
        $alertMsg = $alertReasons -join ' | '
        Write-MonitorAlert $alertMsg
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
