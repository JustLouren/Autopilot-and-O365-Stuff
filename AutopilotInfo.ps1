#Requires -Version 5.1
<#
.SYNOPSIS
    Collects this device's Autopilot hardware hash into an Intune-importable CSV.

.DESCRIPTION
    Downloads a pinned copy of Microsoft's Get-WindowsAutopilotInfo 3.9, checks its
    SHA-256, and runs it locally. The Gallery script is not modified. This wrapper
    fixes the things around it that produce a CSV Intune will not import, or that
    run code without checking what was downloaded.

    The hardware hash never leaves the machine. The only network call is the
    package download from the PowerShell Gallery.

.PARAMETER OutputPath
    Directory for the verified script and the resulting CSV. Default C:\scripts.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutopilotInfo.ps1

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\AutopilotInfo.ps1 -OutputPath D:\autopilot

.NOTES
    Get-WindowsAutopilotInfo 3.9 (6 July 2023) is the current Gallery release and is
    unsigned. Execution policy is intentionally not changed: a default Windows install
    is Restricted, so launch this file with -ExecutionPolicy Bypass. Bypass on the
    command line applies to that process only.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = 'C:\scripts'
)

# Windows invalid-name set, not [IO.Path]::GetInvalidFileNameChars().
# That API returns a different set on non-Windows hosts, and this name is always
# used on Windows. Control characters 0-31 plus " < > | : * ? \ /
function Get-WindowsInvalidFileNameCharacter {
    $chars = New-Object 'System.Collections.Generic.List[char]'
    foreach ($code in 0..31) {
        $chars.Add([char]$code)
    }
    # " < > [ ] | : * ? \ /
    # Brackets are legal NTFS names but PowerShell wildcards, and the Gallery
    # script does not pass -LiteralPath when it writes the CSV.
    foreach ($code in 34, 60, 62, 91, 93, 124, 58, 42, 63, 92, 47) {
        $chars.Add([char]$code)
    }
    return $chars
}

function Get-AutopilotCsvFileName {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Serial,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$FallbackName
    )

    $trimmed = ''
    if ($null -ne $Serial) {
        $trimmed = $Serial.Trim()
    }

    # Filename only. The CSV keeps whatever serial the firmware actually reports,
    # including placeholders, because that is the serial Autopilot matches.
    $unusable = [string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -match '^(?i)(0+|n/?a|none|oem|invalid|default\s*string|system serial number|chassis serial number|not specified|not available|not applicable|fill by oem|to be filled by o\.?\s*e\.?\s*m\.?|123456789|0123456789)$'
    $stemSource = $trimmed
    if ($unusable) {
        Write-Warning "BIOS serial '$trimmed' is blank or a placeholder. The CSV will still contain it; the file is named after this computer instead."
        $stemSource = $FallbackName
    }

    $stem = [string]$stemSource
    if ($null -eq $stem) {
        $stem = ''
    }
    # String.Replace(string, string). A char and a string is an ambiguous overload.
    foreach ($c in (Get-WindowsInvalidFileNameCharacter)) {
        $stem = $stem.Replace([string]$c, '-')
    }
    $stem = $stem.Trim().TrimEnd('.')
    if ($stem.Length -gt 240) {
        $stem = $stem.Substring(0, 240).TrimEnd('.')
    }

    $reserved = @('CON', 'PRN', 'AUX', 'NUL', 'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9', 'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9')
    # Windows treats CON.csv and CON.anything.csv as the reserved device CON.
    $baseName = $stem
    $dot = $stem.IndexOf('.')
    if ($dot -ge 0) {
        $baseName = $stem.Substring(0, $dot)
    }
    if ([string]::IsNullOrWhiteSpace($stem) -or $stem -eq '.' -or $stem -eq '..' -or $reserved -contains $baseName) {
        $fallback = [string]$FallbackName
        if ([string]::IsNullOrWhiteSpace($fallback)) {
            $fallback = 'device'
        }
        foreach ($c in (Get-WindowsInvalidFileNameCharacter)) {
            $fallback = $fallback.Replace([string]$c, '-')
        }
        $fallback = $fallback.Trim().TrimEnd('.')
        if ([string]::IsNullOrWhiteSpace($fallback) -or $reserved -contains $fallback) {
            $fallback = 'device'
        }
        $stem = "Autopilot-$fallback"
    }

    return $stem
}

function Get-AutopilotAnsiEncoding {
    $strict = {
        param([int]$CodePage)
        return [Text.Encoding]::GetEncoding(
            $CodePage,
            (New-Object Text.EncoderExceptionFallback),
            (New-Object Text.DecoderExceptionFallback))
    }

    try {
        return & $strict 1252
    }
    catch {
        if (-not ('System.Text.CodePagesEncodingProvider' -as [type])) {
            throw 'Windows-1252 encoding is not available. Intune requires an ANSI Autopilot CSV, so the file was not written.'
        }
        [Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
        return & $strict 1252
    }
}

function ConvertTo-AutopilotAnsiCsv {
    <#
        Intune requires an ANSI file, a case-sensitive header, and no quotation marks.
        Get-WindowsAutopilotInfo writes the CSV with Out-File and no -Encoding, which
        on Windows PowerShell 5.1 is UTF-16 LE. The import docs call that Unicode and
        reject it.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    $text = $null
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $text = [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $utf8 = New-Object Text.UTF8Encoding $false
        $text = $utf8.GetString($bytes, 3, $bytes.Length - 3)
    }
    else {
        $utf8Strict = New-Object Text.UTF8Encoding $false, $true
        try {
            $text = $utf8Strict.GetString($bytes)
        }
        catch {
            $text = (Get-AutopilotAnsiEncoding).GetString($bytes)
        }
    }

    if ($null -eq $text) {
        $text = ''
    }
    $text = $text.TrimStart([char]0xFEFF)
    $text = $text -replace "`r`n", "`n" -replace "`n", "`r`n"

    $lines = @($text -split "`r`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -lt 2) {
        throw 'The hardware hash was not collected, so there is no device row to import. Run this from 64-bit PowerShell, elevated, on the device itself. The hash is read from the MDM_DevDetail_Ext01 WMI class. This script does not enable WinRM.'
    }

    if ($text.Contains('"')) {
        throw 'The CSV contains quotation marks. Intune rejects those. Do not edit the file in Excel.'
    }

    $allowedHeaders = @(
        'Device Serial Number,Windows Product ID,Hardware Hash'
        'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag'
        'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User'
    )
    if ($allowedHeaders -cnotcontains $lines[0]) {
        throw "The CSV header is not an Intune Autopilot header (headers are case-sensitive): $($lines[0])"
    }

    # Base64, and long enough to be the 4K hardware hash rather than a serial or an error string.
    $hashPattern = '^[A-Za-z0-9+/]{1000,}={0,2}$'
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $found = $false
        foreach ($field in $lines[$i].Split(',')) {
            if ($field.Trim() -cmatch $hashPattern) {
                $found = $true
                break
            }
        }
        if (-not $found) {
            throw "CSV row $i has no hardware hash long enough to import. An empty hash usually means the MDM WMI class did not respond. 32-bit PowerShell cannot read it."
        }
    }

    $encoding = Get-AutopilotAnsiEncoding
    try {
        $outBytes = $encoding.GetBytes($text)
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) {
            $inner = $inner.InnerException
        }
        if ($inner -is [Text.EncoderFallbackException]) {
            throw 'The CSV contains a character that ANSI (Windows-1252), the encoding Intune requires, cannot store. The Unicode file from Windows PowerShell was not kept.'
        }
        throw
    }

    [IO.File]::WriteAllBytes($Path, $outBytes)
}

function Save-PinnedAutopilotScript {
    <#
        Package id on the Gallery is Get-WindowsAutopilotInfo (lowercase p).
        Version 3.9, published 6 July 2023, SHA-256 of Get-WindowsAutopilotInfo.ps1
        as stored in that nupkg. A mismatch means the bytes are not the file that
        was reviewed. Do not run them.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    $version = '3.9'
    $expectedSha256 = '60C13CF3A63E0E38D41D075C85E95C7EB4A8EF301E0C605DE6DE29E5A552170D'
    $uri = "https://www.powershellgallery.com/api/v2/package/Get-WindowsAutopilotInfo/$version"
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('autopilotinfo-' + [guid]::NewGuid().ToString('n'))

    # Windows PowerShell 5.1 defaults to TLS 1.0 on older OS builds. The Gallery refuses that.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $previousProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        $nupkg = Join-Path $tempRoot 'Get-WindowsAutopilotInfo.nupkg'
        $extract = Join-Path $tempRoot 'pkg'

        try {
            # -UseBasicParsing: without it, Windows PowerShell 5.1 uses the IE parser and
            # fails on Server Core and in OOBE, and it mishandles this binary nupkg.
            Microsoft.PowerShell.Utility\Invoke-WebRequest -Uri $uri -OutFile $nupkg -UseBasicParsing -ErrorAction Stop
        }
        catch {
            throw "Could not download Get-WindowsAutopilotInfo $version from the PowerShell Gallery ($uri). $($_.Exception.Message)"
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $extract)

        $extracted = Join-Path $extract 'Get-WindowsAutopilotInfo.ps1'
        if (-not (Test-Path -LiteralPath $extracted)) {
            throw "The Gallery package did not contain Get-WindowsAutopilotInfo.ps1."
        }

        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $extracted).Hash
        if ($actual -ne $expectedSha256) {
            throw "Refusing to run Get-WindowsAutopilotInfo. SHA-256 is $actual, not the pinned 3.9 hash $expectedSha256. The Gallery package is not the file that was reviewed."
        }

        $destination = Join-Path $DestinationDirectory 'Get-WindowsAutopilotInfo.ps1'
        Copy-Item -LiteralPath $extracted -Destination $destination -Force
        # The nupkg is downloaded, so Windows marks it as from the internet. The script
        # is unsigned. Unblock only after the hash matches, so RemoteSigned can run
        # this one file without changing execution policy.
        Unblock-File -LiteralPath $destination
        return $destination
    }
    finally {
        $ProgressPreference = $previousProgress
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-AutopilotHardwareHashCollection {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingWriteHost', '',
        Justification = 'Confirmation for the technician at the device. This is not a pipeline tool.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $ErrorActionPreference = 'Stop'

    if ($env:OS -ne 'Windows_NT') {
        throw 'Run AutopilotInfo.ps1 on the Windows device you are enrolling. The hardware hash is collected from that device and is not requested from a tenant.'
    }

    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run AutopilotInfo.ps1 from an elevated PowerShell session. Reading the hardware hash requires administrator rights.'
    }

    # The MDM provider that serves the hash is 64-bit. A 32-bit host (SysWOW64, or an
    # RMM that launches x86 PowerShell) returns no hash and the CSV looks successful
    # if nobody checks the column. Re-launch the same script in 64-bit Windows PowerShell.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $ps64 = Join-Path $env:windir 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $ps64)) {
            throw "32-bit PowerShell cannot read the Autopilot hardware hash. Run $env:windir\System32\WindowsPowerShell\v1.0\powershell.exe instead."
        }
        & $ps64 -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -OutputPath $OutputPath
        $code = $LASTEXITCODE
        if ($null -eq $code) {
            $code = 1
        }
        exit $code
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        throw 'OutputPath is empty.'
    }
    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        throw "OutputPath is a file, not a directory: $OutputPath"
    }

    $dir = New-Item -Path $OutputPath -ItemType Directory -Force
    $bios = Get-CimInstance -ClassName Win32_BIOS | Select-Object -First 1
    $serial = $null
    if ($null -ne $bios) {
        $serial = [string]$bios.SerialNumber
    }
    $stem = Get-AutopilotCsvFileName -Serial $serial -FallbackName $env:COMPUTERNAME
    $csv = Join-Path $dir.FullName ($stem + '.csv')

    $autopilotScript = Save-PinnedAutopilotScript -DestinationDirectory $dir.FullName

    # Write to a temp file, and only replace the final CSV after it validates.
    # A failed run must not destroy a previously good file, and must not leave an
    # empty Unicode file that looks ready to import.
    # The Gallery script reports a missing hash with Write-Error and still creates
    # a file. Under Stop, that Write-Error aborts the script before its End block.
    # Let it finish, then require a real hash below.
    $rawCsv = Join-Path ([IO.Path]::GetTempPath()) ('autopilotinfo-' + [guid]::NewGuid().ToString('n') + '.csv')
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        try {
            & $autopilotScript -OutputFile $rawCsv
        }
        finally {
            $ErrorActionPreference = $savedPreference
        }

        if (-not (Test-Path -LiteralPath $rawCsv)) {
            throw 'Get-WindowsAutopilotInfo did not produce a CSV.'
        }

        ConvertTo-AutopilotAnsiCsv -Path $rawCsv
        Move-Item -LiteralPath $rawCsv -Destination $csv -Force
    }
    catch {
        throw "Autopilot CSV was not kept. $($_.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $rawCsv) {
            Remove-Item -LiteralPath $rawCsv -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "Hardware hash written to $csv" -ForegroundColor Green
    Write-Host 'Import it in the Intune admin center: Devices > Windows > Enrollment (Device onboarding) > Windows Autopilot > Devices > Import.'
    Write-Host 'The file is ANSI text with no quotes. Do not open it in Excel; saving from Excel makes Intune reject it.'
}

# Dot-sourcing defines the helpers (used by tests) and does not collect a hash.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AutopilotHardwareHashCollection -OutputPath $OutputPath
}
