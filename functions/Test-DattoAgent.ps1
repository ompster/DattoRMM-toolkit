function Test-DattoAgent {
    <#
    .SYNOPSIS
        Verify the Datto RMM agent is installed and running.
    .OUTPUTS
        $true if CagService is running, $false otherwise.
    #>
    $service = Get-Service -Name 'CagService' -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-Log "Datto RMM agent service (CagService) not found" -Level ERROR
        return $false
    }
    if ($service.Status -ne 'Running') {
        Write-Log "Datto RMM agent service is $($service.Status)" -Level WARN
        return $false
    }
    Write-Log "Datto RMM agent is running"
    return $true
}
