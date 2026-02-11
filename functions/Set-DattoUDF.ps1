function Set-DattoUDF {
    <#
    .SYNOPSIS
        Write a value to a Datto RMM User Defined Field (UDF 1-30).
    .PARAMETER UDF
        UDF number (1-30).
    .PARAMETER Value
        Value to write. Max ~255 chars recommended for UI display.
    .EXAMPLE
        Set-DattoUDF -UDF 1 -Value "Windows 11 23H2"
        Set-DattoUDF -UDF 15 -Value "BitLocker: Enabled | TPM: 2.0"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 30)]
        [int]$UDF,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    try {
        $regPath = 'HKLM:\SOFTWARE\CentraStage'
        $regName = "Custom$UDF"

        if (-not (Test-Path $regPath)) {
            Write-Log "CentraStage registry path not found — is the Datto agent installed?" -Level ERROR
            return $false
        }

        Set-ItemProperty -Path $regPath -Name $regName -Value $Value -Force

        # Also set the env var for same-session reads
        [Environment]::SetEnvironmentVariable("UDF_$UDF", $Value, 'Process')

        Write-Log "UDF $UDF set to: $Value"
        return $true
    }
    catch {
        Write-Log "Failed to set UDF $UDF — $_" -Level ERROR
        return $false
    }
}
