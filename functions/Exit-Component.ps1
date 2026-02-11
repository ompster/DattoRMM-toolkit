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
