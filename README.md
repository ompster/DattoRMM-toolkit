# Datto RMM Toolkit

Reusable PowerShell functions for Datto RMM components. Drop these into your components or dot-source the toolkit.

## Structure

```
DattoRMM-Toolkit/
├── DattoRMM-Toolkit.ps1          # All functions in one file (paste into components)
├── functions/                     # Individual function files (grab what you need)
│   ├── Write-Log.ps1
│   ├── Write-LogSection.ps1
│   ├── Exit-Component.ps1
│   ├── Exit-Success.ps1
│   ├── Exit-Failure.ps1
│   ├── Exit-NotApplicable.ps1
│   ├── Exit-RebootRequired.ps1
│   ├── Set-DattoUDF.ps1
│   ├── Get-DattoUDF.ps1
│   ├── Set-DattoUDFTimestamp.ps1
│   ├── Get-LoggedOnUser.ps1
│   ├── Invoke-AsLoggedOnUser.ps1
│   ├── Get-UserRegistryPaths.ps1
│   ├── Invoke-UserRegistryAction.ps1
│   ├── Get-DattoVariable.ps1
│   └── Test-DattoAgent.ps1
├── monitors/                      # Ready-to-use monitor scripts
│   └── datto-file-protection-monitor.ps1
├── templates/
│   ├── Component-Template.ps1    # Standard component starter
│   └── Monitor-Template.ps1      # Monitor with 5 examples
├── LICENSE
└── README.md
```

**Two ways to use it:**
- **Full toolkit** — paste `DattoRMM-Toolkit.ps1` into your component for everything
- **Pick and choose** — grab individual files from `functions/` for just what you need

## What's Included

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

## Monitors

### Datto File Protection - Health Monitor

Monitors Datto File Protection (Desktop and Server editions) by parsing the official Datto status XML file. Fixes two common problems with the ComStore monitor:

1. **False positives** -- transient connection states (connecting, authenticating, retry) and active backups no longer trigger alerts
2. **Alerts not auto-resolving** -- exits 0 when healthy so Datto RMM clears the alert automatically

**Features:**
- Smart XML selection for multi-user machines — only checks the logged-in user's XML to avoid false positives from unlicensed DFP instances (DFP is licensed per-user). Falls back to the most recently modified XML when nobody is logged in.
- Parses Server mode (ProgramData) and Desktop/user mode (per-profile) status XML
- Only alerts on genuine `disconnected` state, not transient states
- Suppresses connection and staleness alerts during active backups
- Alerts on quarantined or deleted accounts
- Configurable backup staleness threshold (default: 72 hours)
- Falls back to Datto service presence check when no XML exists

**Variable:** `MaxHoursSinceBackup` (Integer, default: 72)

Import as a Component Monitor in Datto RMM, set Output Variable to `Status`.

> Originally developed using the [datto-rmm-agent-skill](https://github.com/ompster/datto-rmm-agent-skill) — an AI agent skill for building production-ready Datto RMM components and monitors.

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

## Blog Post

Read the full writeup: **[Datto RMM Toolkit: Reusable PowerShell Functions for Better Components](https://me.ashnet.online/blog/datto-rmm-toolkit/)**

## License

MIT
