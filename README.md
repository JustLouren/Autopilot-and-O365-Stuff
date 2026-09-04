# Autopilot-and-O365-Stuff

Scripts for Windows Autopilot device enrolment and related Microsoft 365 admin work.

## AutopilotInfo.ps1

Collects a device's **hardware hash** and writes it to a CSV named after the machine's
serial number. That CSV is what you upload to Intune to register the device for
Windows Autopilot, so it picks up its assigned configuration the first time an end
user signs in — no imaging, no manual setup.

It wraps Microsoft's official
[`Get-WindowsAutoPilotInfo`](https://www.powershellgallery.com/packages/Get-WindowsAutoPilotInfo)
script and handles the things that normally make that script stop and ask on a fresh
machine: TLS 1.2, the NuGet provider, and PowerShell Gallery trust.

### Requirements

- **Windows PowerShell 5.1** (the version built into Windows) or PowerShell 7.
- **Run as Administrator** — reading the hardware hash requires it.
- **Internet access** to `www.powershellgallery.com`.
- Run it *on* the device you want to enrol; the hash is specific to that hardware.

### Usage

From an elevated PowerShell prompt on the target device:

```powershell
.\AutopilotInfo.ps1
```

The result is `C:\scripts\<SERIAL>.csv`. To put it somewhere else:

```powershell
.\AutopilotInfo.ps1 -OutputPath D:\autopilot
```

If PowerShell refuses to run the file at all, launch it in a way that doesn't depend
on the saved policy:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\AutopilotInfo.ps1
```

### What it does

1. Sets the execution policy to `RemoteSigned` **for the current process only**, so
   nothing about the machine's configuration is changed permanently.
2. Enables TLS 1.2 — Server 2016 and older Windows 10 builds default to TLS 1.0,
   which the PowerShell Gallery refuses.
3. Creates the output directory if it isn't already there.
4. Reads the serial from `Win32_BIOS`, falling back to the computer name if the BIOS
   reports a blank or placeholder value, and strips any characters that aren't legal
   in a filename.
5. Installs the NuGet provider and temporarily trusts the PSGallery **if needed**,
   so an unattended run doesn't stall on a prompt.
6. Downloads `Get-WindowsAutoPilotInfo` and runs it, verifying at each step that the
   thing it expects actually exists.
7. Restores your original PSGallery trust setting on the way out, including on failure.

It is safe to re-run: existing directories are reused, and the downloaded script is
refreshed rather than duplicated.

### What to do with the CSV

1. Sign in to the [Intune admin center](https://intune.microsoft.com).
2. **Devices → Enrollment → Devices** (under Windows Autopilot Deployment Program).
3. **Import**, and select the CSV.
4. Wait for the import to finish, then assign a deployment profile and group tag.

For several machines, concatenate the CSVs and keep a single header row at the top.
Intune accepts up to 500 rows per import.

**Don't commit these CSVs.** A hardware hash identifies a specific physical device and
is what Autopilot uses to claim it. `.gitignore` excludes `*.csv` for that reason.

### Capturing the hash from OOBE

You can collect the hash without completing Windows setup — the usual approach for
devices you're enrolling before handing over. At the out-of-box experience press
**Shift+F10** for a command prompt, then:

```
powershell
```

and run the script from there.

### Registering directly, without a CSV

If you'd rather skip the upload step entirely, Microsoft's script can register the
device straight into Intune:

```powershell
Install-Script -Name Get-WindowsAutoPilotInfo -Force
Get-WindowsAutoPilotInfo -Online
```

`-Online` prompts for credentials and needs the appropriate Graph permissions, but it
removes the CSV round-trip. Good for one device; the CSV path is still better when
you're collecting hashes in bulk or handing them to someone else to import.

## License

No license is specified, which means all rights reserved by default — others can read
this but not legally reuse it. If that isn't the intent, add a `LICENSE` file; MIT is
the usual choice for scripts like these.
