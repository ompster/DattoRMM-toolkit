function Invoke-AsLoggedOnUser {
    <#
    .SYNOPSIS
        Execute a script block as the currently logged-on user.
        Uses scheduled task trick — creates a task, runs it in the user's session, captures output.
    .PARAMETER ScriptBlock
        The code to run as the user.
    .PARAMETER ArgumentList
        Arguments to pass to the script block.
    .PARAMETER Timeout
        Max seconds to wait for completion. Default: 120.
    .EXAMPLE
        Invoke-AsLoggedOnUser -ScriptBlock {
            [System.Windows.Forms.MessageBox]::Show("Hello from $env:USERNAME!")
        }
    .EXAMPLE
        $result = Invoke-AsLoggedOnUser -ScriptBlock {
            param($AppName)
            Get-Process $AppName -ErrorAction SilentlyContinue | Select-Object Name, CPU
        } -ArgumentList 'chrome'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [object[]]$ArgumentList,

        [int]$Timeout = 120
    )

    $user = Get-LoggedOnUser
    if (-not $user) {
        Write-Log "No logged-on user found — cannot run as user" -Level ERROR
        return $null
    }

    $taskName = "DattoRMM_RunAsUser_$(Get-Random)"
    $outputFile = "$env:TEMP\$taskName.xml"
    $errorFile = "$env:TEMP\$taskName.err"
    $exitCodeFile = "$env:TEMP\$taskName.exit"

    try {
        # Build the script to execute
        $argString = if ($ArgumentList) {
            ($ArgumentList | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ','
        } else { '' }

        $encodedScript = @"
try {
    `$output = & { $ScriptBlock } $argString
    `$output | Export-Clixml -Path '$outputFile' -Force
    `$LASTEXITCODE | Out-File -FilePath '$exitCodeFile' -Force
} catch {
    `$_.Exception.Message | Out-File -FilePath '$errorFile' -Force
    1 | Out-File -FilePath '$exitCodeFile' -Force
}
"@

        $bytes = [System.Text.Encoding]::Unicode.GetBytes($encodedScript)
        $encoded = [Convert]::ToBase64String($bytes)

        # Create and run scheduled task as the logged-on user
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
        $principal = New-ScheduledTaskPrincipal -UserId $user.FullName -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds $Timeout)

        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
        Write-Log "Running script as $($user.FullName) via scheduled task"

        Start-ScheduledTask -TaskName $taskName

        # Wait for completion
        $elapsed = 0
        do {
            Start-Sleep -Seconds 2
            $elapsed += 2
            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            $taskState = (Get-ScheduledTask -TaskName $taskName).State
        } while ($taskState -eq 'Running' -and $elapsed -lt $Timeout)

        if ($taskState -eq 'Running') {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Write-Log "Task timed out after $Timeout seconds" -Level WARN
        }

        # Collect output
        if (Test-Path $errorFile) {
            $err = Get-Content $errorFile -Raw
            Write-Log "User-context error: $err" -Level ERROR
            return $null
        }

        if (Test-Path $outputFile) {
            $result = Import-Clixml $outputFile
            Write-Log "User-context script completed successfully"
            return $result
        }

        Write-Log "No output captured from user-context script" -Level WARN
        return $null
    }
    finally {
        # Cleanup
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $outputFile, $errorFile, $exitCodeFile -Force -ErrorAction SilentlyContinue
    }
}
