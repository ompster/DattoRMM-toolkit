function Set-DattoUDFTimestamp {
    <#
    .SYNOPSIS
        Write a UDF with a timestamp prefix for tracking when it was last updated.
    .EXAMPLE
        Set-DattoUDFTimestamp -UDF 20 -Value "Disk Cleanup: 4.2GB freed"
        # Result: "2026-02-11 17:30 | Disk Cleanup: 4.2GB freed"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 30)]
        [int]$UDF,

        [Parameter(Mandatory)]
        [string]$Value
    )

    $timestamped = "$(Get-Date -Format 'yyyy-MM-dd HH:mm') | $Value"
    Set-DattoUDF -UDF $UDF -Value $timestamped
}
