function Get-DattoVariable {
    <#
    .SYNOPSIS
        Read a Datto RMM site or component variable.
        Datto injects these as environment variables with specific prefixes.
    .PARAMETER Name
        Variable name (without prefix). Datto vars are usually CS_*, env:CS_PROFILE_*, or userdefined_*.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Datto component variables come through as env vars
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) {
        # Try common prefixes
        foreach ($prefix in @('CS_', 'cs_', 'userdefined_', 'env:')) {
            $value = [Environment]::GetEnvironmentVariable("$prefix$Name")
            if ($null -ne $value) { break }
        }
    }
    return $value
}
