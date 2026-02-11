function Write-LogSection {
    <#
    .SYNOPSIS
        Visual separator in logs for readability.
    .PARAMETER Title
        Section title to display.
    #>
    param([string]$Title)
    Write-Log "========== $Title =========="
}
