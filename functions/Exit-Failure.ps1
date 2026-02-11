function Exit-Failure {
    <#
    .SYNOPSIS
        Exit with a failure code.
    .PARAMETER Message
        Failure message to log.
    .PARAMETER ExitCode
        Exit code. Default: 1.
    #>
    param(
        [string]$Message = 'Component failed.',
        [int]$ExitCode = 1
    )
    Exit-Component -ExitCode $ExitCode -Message $Message
}
