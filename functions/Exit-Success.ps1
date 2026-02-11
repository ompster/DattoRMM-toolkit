function Exit-Success {
    <#
    .SYNOPSIS
        Exit with code 0 (success).
    .PARAMETER Message
        Success message to log.
    #>
    param([string]$Message = 'Component completed successfully.')
    Exit-Component -ExitCode 0 -Message $Message
}
