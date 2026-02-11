function Get-DattoUDF {
    <#
    .SYNOPSIS
        Read the current value of a UDF.
    .PARAMETER UDF
        UDF number (1-30).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 30)]
        [int]$UDF
    )

    try {
        $regPath = 'HKLM:\SOFTWARE\CentraStage'
        $regName = "Custom$UDF"
        $value = Get-ItemPropertyValue -Path $regPath -Name $regName -ErrorAction SilentlyContinue
        return $value
    }
    catch {
        return $null
    }
}
