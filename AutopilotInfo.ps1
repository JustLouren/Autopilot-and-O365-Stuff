#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Collects this device's Autopilot hardware hash into a CSV named after its serial.

.DESCRIPTION
    Wrapper around Microsoft's Get-WindowsAutoPilotInfo. Handles the things that
    normally make that script prompt or fail on a fresh machine: TLS 1.2, the NuGet
    provider, and PSGallery trust. Re-runnable, and it leaves no permanent changes
    to the machine's execution policy.

.PARAMETER OutputPath
    Directory for the downloaded script and the resulting CSV. Default C:\scripts.

.EXAMPLE
    .\AutopilotInfo.ps1
.EXAMPLE
    .\AutopilotInfo.ps1 -OutputPath D:\autopilot
#>
[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\scripts'
)

$ErrorActionPreference = 'Stop'

# Process scope only: this reverts when the window closes, needs no policy change on
# the machine, and cannot be blocked the way a LocalMachine change can.
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force

# Server 2016 and older Win10 builds default to TLS 1.0, which PSGallery refuses.
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# -Force makes this a no-op when the directory already exists, so the script re-runs.
$dir = New-Item -Path $OutputPath -ItemType Directory -Force

# Get-CimInstance replaces the deprecated Get-WmiObject and works on PowerShell 7 too.
$serial = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber

# Some OEMs ship blank or placeholder serials, and a serial can contain characters
# that are illegal in a filename. Fall back to the computer name rather than
# producing an unusable file.
if ([string]::IsNullOrWhiteSpace($serial) -or
    $serial -match '^(To Be Filled By O\.E\.M\.|Default string|System Serial Number|None)$') {
    Write-Warning "BIOS reports no usable serial ('$serial'); using the computer name."
    $serial = $env:COMPUTERNAME
}
# Cast to string so this binds String.Replace(string,string); passing a char and a
# string leaves the overload ambiguous.
foreach ($c in [IO.Path]::GetInvalidFileNameChars()) {
    $serial = $serial.Replace([string]$c, '-')
}
$serial = $serial.Trim()

$csv = Join-Path $dir.FullName "$serial.csv"

# Bootstrap the gallery quietly. Without these two, a clean machine stops and asks.
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Write-Verbose 'Installing the NuGet package provider.'
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
}

$gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
$restorePolicy = $null
if ($gallery -and $gallery.InstallationPolicy -ne 'Trusted') {
    $restorePolicy = $gallery.InstallationPolicy
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

try {
    Save-Script -Name Get-WindowsAutoPilotInfo -Path $dir.FullName -Force

    $autopilotScript = Join-Path $dir.FullName 'Get-WindowsAutoPilotInfo.ps1'
    if (-not (Test-Path -LiteralPath $autopilotScript)) {
        throw "Download reported success but $autopilotScript is not there."
    }

    & $autopilotScript -OutputFile $csv

    if (-not (Test-Path -LiteralPath $csv)) {
        throw "Get-WindowsAutoPilotInfo did not produce $csv."
    }
    Write-Host "Hardware hash written to $csv" -ForegroundColor Green
    Write-Host 'Import it at Intune > Devices > Enrollment > Devices > Import.'
}
finally {
    # Always hand the machine back the way we found it.
    if ($restorePolicy) {
        Set-PSRepository -Name PSGallery -InstallationPolicy $restorePolicy
    }
}
