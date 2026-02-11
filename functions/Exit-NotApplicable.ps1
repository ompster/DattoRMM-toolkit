function Exit-NotApplicable {
    <#
    .SYNOPSIS
        Exit with code 2 (not applicable / prereq not met).
    .PARAMETER Message
        Message explaining why the component doesn't apply.
    #>
    param([string]$Message = 'Component not applicable to this device.')
    Exit-Component -ExitCode 2 -Message $Message
}
