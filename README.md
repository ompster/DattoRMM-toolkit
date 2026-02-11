# Datto RMM Toolkit

Reusable PowerShell functions for Datto RMM components. Drop these into your components or dot-source the toolkit.

## What's Included

### `DattoRMM-Toolkit.ps1`

| Function | Description |
|---|---|
| **Logging** | |
| `Write-Log` | Structured logging with severity (INFO/WARN/ERROR/DEBUG), file + stdout |
| `Write-LogSection` | Visual separators in logs |
| **Exit Codes** | |
| `Exit-Component` | Clean exit with logging |
| `Exit-Success` | Exit 0 with message |
| `Exit-Failure` | Exit 1 (or custom) with message |
| `Exit-NotApplicable` | Exit 2 — device doesn't meet prereqs |
| `Exit-RebootRequired` | Exit 4 — reboot needed |
| **UDF Writing** | |
| `Set-DattoUDF` | Write to UDF 1-30 via registry |
| `Get-DattoUDF` | Read current UDF value |
| `Set-DattoUDFTimestamp` | Write UDF with auto timestamp prefix |
| **Run as Logged-In User** | |
| `Get-LoggedOnUser` | Get interactive user (username, SID, profile path) |
| `Invoke-AsLoggedOnUser` | Run a script block in the user's session via scheduled task |
| **User Registry** | |
| `Get-UserRegistryPaths` | Get registry hive paths for current or all users |
| `Invoke-UserRegistryAction` | Run code against user hives (auto-mounts offline NTUSER.DAT) |
| **Datto Environment** | |
| `Get-DattoVariable` | Read Datto site/component variables |
| `Test-DattoAgent` | Verify CagService is running |

## Usage

### In a Datto RMM Component

Paste the functions you need at the top of your component, or include the full toolkit:

```powershell
# === YOUR COMPONENT ===

# Paste toolkit functions here (or the ones you need)
# ...

Write-LogSection "Starting My Component"

if (-not (Test-DattoAgent)) {
    Exit-Failure "Datto agent not running"
}

# Do work...
$user = Get-LoggedOnUser
Set-DattoUDFTimestamp -UDF 5 -Value "Last run by $($user.Username)"

# Modify registry for all users
Invoke-UserRegistryAction -Target All -Action {
    param($HivePath, $UserInfo)
    Set-ItemProperty -Path "$HivePath\SOFTWARE\MyApp" -Name 'Configured' -Value 1 -Force
}

Exit-Success "Component completed"
```

## Exit Code Conventions

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | General failure |
| 2 | Not applicable / prereq not met |
| 3 | Timeout |
| 4 | Reboot required |
| 5 | Partial success |
| 10 | Access denied |
| 20 | Network failure |

For **Component Monitors**: exit 0 = healthy, exit 1 = alert.

## License

MIT
