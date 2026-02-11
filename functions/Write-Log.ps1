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
