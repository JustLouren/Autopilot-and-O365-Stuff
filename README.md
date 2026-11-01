# Autopilot-and-O365-Stuff

Scripts for Windows Autopilot device enrolment and related Microsoft 365 admin work.

## AutopilotInfo.ps1

Collects a device's **hardware hash** and writes it to a CSV named after the machine's
serial number. That CSV is what you upload to Intune to register the device for
Windows Autopilot.

The hash is collected on the device by a pinned copy of Microsoft's
[`Get-WindowsAutopilotInfo`](https://www.powershellgallery.com/packages/Get-WindowsAutopilotInfo)
3.9 (the current Gallery release, published 6 July 2023). This wrapper does not
change that script. It checks the download, then fixes the CSV so Intune will
accept it. Nothing is sent to a tenant. The only network call is the package
download from the PowerShell Gallery.

### Requirements

- **64-bit Windows PowerShell 5.1** (the version built into Windows) or 64-bit PowerShell 7, **run as Administrator**.
  A 32-bit host cannot read the hash. If you start the 32-bit host anyway, the script re-launches the 64-bit one.
- **Internet access** to `www.powershellgallery.com`, once, to download the pinned package.
- Run it *on* the device you want to enrol. The hash is specific to that hardware.

A default Windows install has execution policy `Restricted`, so `.\AutopilotInfo.ps1`
will not start until you launch it as below. The script does not change the machine
or process execution policy. `Bypass` on the command line lasts for that process only.
The Gallery script is unsigned; do not rely on `RemoteSigned` or `AllSigned` for it.
After the SHA-256 check, the downloaded file is unblocked so a later `RemoteSigned`
session can run that one file.

### Usage

From an elevated 64-bit PowerShell prompt on the target device, or from the OOBE
command prompt (Shift+F10):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutopilotInfo.ps1
```

The result is `C:\scripts\<SERIAL>.csv`. To put it somewhere else:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutopilotInfo.ps1 -OutputPath D:\autopilot
```

### What it does

1. Refuses to run unless it is on Windows and elevated. On a 64-bit OS, a 32-bit process is re-launched as 64-bit Windows PowerShell, because the hardware-hash WMI class is empty in the 32-bit host.
2. Enables TLS 1.2. Server 2016 and older Windows 10 builds default to TLS 1.0, which the Gallery refuses.
3. Creates the output directory if it is not already there.
4. Reads the serial from `Win32_BIOS` for the **file name**. Blank and placeholder serials (`To Be Filled By O.E.M.`, `Default string`, `0`, and the usual white-box values) use the computer name so two machines do not overwrite one file. Characters that are illegal in a Windows file name are replaced. The serial **inside** the CSV is whatever the firmware reports; Autopilot matches on that, not on the file name.
5. Downloads `Get-WindowsAutopilotInfo` **3.9** from its Gallery nupkg URL, extracts `Get-WindowsAutopilotInfo.ps1`, and refuses to run it unless the SHA-256 is `60C13CF3A63E0E38D41D075C85E95C7EB4A8EF301E0C605DE6DE29E5A552170D`.
6. Runs that script. A missing hash is a failure, not an empty file left behind for someone to import. A previous good CSV in the output folder is left in place if this run fails.
7. Rewrites the CSV as **ANSI (Windows-1252) with no BOM**. Windows PowerShell's `Out-File` writes UTF-16, and [Intune rejects Unicode](https://learn.microsoft.com/en-us/autopilot/add-devices) and rejects quotation marks. The header has to match one of the three documented headers exactly, and the hardware hash has to look like a 4K hash.

It does **not** install the NuGet provider, trust PSGallery, or change execution policy. Those steps are what a fresh machine prompts on, and trusting the Gallery then running `-Force` the latest script is the wrong check: 3.9 is unsigned and has not been updated since 2023.

Re-running downloads the pinned package again and replaces `<SERIAL>.csv` only after the new file validates.

### What to do with the CSV

1. Sign in to the [Intune admin center](https://intune.microsoft.com).
2. **Devices → Windows → Enrollment** (under Device onboarding) **→ Windows Autopilot → Devices**.
3. **Import**, and select the CSV.
4. After the import finishes, **Sync**, then assign a deployment profile. A group tag can be set on the imported device; this script does not put one in the file.

Intune's rules for the file, which the script already enforces:

- Header exactly `Device Serial Number,Windows Product ID,Hardware Hash` (optional `,Group Tag` and `,Assigned User`). Case-sensitive.
- No quotation marks, no extra columns.
- ANSI text, not Unicode. A blank Windows Product ID is normal and is accepted.
- Up to 500 data rows per import.

**Do not open the CSV in Excel.** Excel rewrites the encoding and adds quotes, and the import then fails.

For several machines, build one file that has a single header and one row per device. Do not concatenate the CSVs as they stand: that repeats the header, and a UTF-16 file from an older run will not merge cleanly with an ANSI one. Stay under 500 rows.

**Don't commit these CSVs**, or a renamed copy of one. A hardware hash identifies a specific physical device and is what Autopilot uses to claim it. `.gitignore` excludes `*.csv` and the usual export names for that reason.

### Capturing the hash from OOBE

At the out-of-box experience press **Shift+F10**, then run the launch command above from the folder that contains this script (a USB stick is fine). The device needs a network path to the PowerShell Gallery for the one download. Shift+F10 on 64-bit Windows opens a 64-bit command prompt; if a tool has started 32-bit PowerShell, the script switches to the 64-bit host itself.

This script does not turn on WinRM. If hash collection fails because `MDM_DevDetail_Ext01` is missing, `winrm qc` is a known repair, but it opens a remote-management listener. That is a machine change, so it is left to you.

### Registering directly, without a CSV

`Get-WindowsAutopilotInfo -Online` is **not** wrapped here. Version 3.6 and later use Microsoft Graph rather than the retired MSOnline / AzureAD modules, but 3.9 itself has not moved since July 2023 and the online path is a poor default:

- The import-status loop reads `$device` instead of the pipeline object, so the success count and the sync wait are wrong.
- `-AddToGroup` calls Graph cmdlets that have since changed (`New-MgGroupMember` URL handling).
- `Connect-MgGraph` is missing `-ContextScope Process`, which is what current Web Account Manager prompts need when the window is hidden (the usual OOBE failure).
- `-AppSecret` takes a client secret on the command line and still calls the old app-auth helper. Do not use it.

Import the CSV, or register the device from Partner Center / the OEM. If you do run `-Online` yourself, sign in as an Intune Administrator, expect a Graph consent prompt, and do not put a client secret in the command.

## Tests

`tests/AutopilotInfo.Tests.ps1` covers file names and the CSV encoding rules. It does not download the Gallery script and it does not contact a tenant. Run it with Windows PowerShell 5.1 or PowerShell 7.

## License

[MIT](LICENSE) — use it, change it, ship it. Attribution appreciated, not required.
