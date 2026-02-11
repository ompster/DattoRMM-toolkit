function Exit-RebootRequired {
    <#
    .SYNOPSIS
        Exit with code 4 (reboot required).
    .PARAMETER Message
        Message about why a reboot is needed.
    #>
    param([string]$Message = 'Reboot required to complete.')
    Exit-Component -ExitCode 4 -Message $Message
}
