#Requires -Version 5.1
<#
    Offline checks for the filename and CSV rules. Does not download the Gallery
    script and does not talk to a tenant.
#>
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'AutopilotInfo.ps1')

$failures = New-Object System.Collections.Generic.List[string]
function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -cne $Expected) {
        $script:failures.Add("$Label`n  expected: [$Expected]`n  actual:   [$Actual]")
    }
}
function Assert-Throw {
    param([scriptblock]$Script, [string]$Label)
    $threw = $false
    try {
        & $Script
    }
    catch {
        $threw = $true
    }
    if (-not $threw) {
        $script:failures.Add("$Label did not throw.")
    }
}

$WarningPreference = 'SilentlyContinue'

Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial 'PF2ABCDE' -FallbackName 'BENCH') -Expected 'PF2ABCDE' -Label 'normal serial'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial '  PF2ABCDE  ' -FallbackName 'BENCH') -Expected 'PF2ABCDE' -Label 'trimmed serial'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial 'To Be Filled By O.E.M.' -FallbackName 'BENCH01') -Expected 'BENCH01' -Label 'OEM placeholder'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial 'to be filled by o.e.m.' -FallbackName 'BENCH01') -Expected 'BENCH01' -Label 'OEM placeholder case'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial '0' -FallbackName 'WHITEBOX') -Expected 'WHITEBOX' -Label 'zero serial'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial '000000' -FallbackName 'WHITEBOX') -Expected 'WHITEBOX' -Label 'zero run'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial 'Default string' -FallbackName 'WHITEBOX') -Expected 'WHITEBOX' -Label 'default string'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial 'System Serial Number' -FallbackName 'WHITEBOX') -Expected 'WHITEBOX' -Label 'system serial'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial '' -FallbackName 'WHITEBOX') -Expected 'WHITEBOX' -Label 'empty serial'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial $null -FallbackName 'WHITEBOX') -Expected 'WHITEBOX' -Label 'null serial'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial 'ABC/DEF:GHI' -FallbackName 'BENCH') -Expected 'ABC-DEF-GHI' -Label 'invalid filename characters'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial 'ABC[1]' -FallbackName 'BENCH') -Expected 'ABC-1-' -Label 'wildcard brackets'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial "ABC`r`nDEF" -FallbackName 'BENCH') -Expected 'ABC--DEF' -Label 'control characters'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial 'CON' -FallbackName 'BENCH') -Expected 'Autopilot-BENCH' -Label 'reserved device name'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial 'CON.1' -FallbackName 'BENCH') -Expected 'Autopilot-BENCH' -Label 'reserved device name with a dot'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial 'serial.' -FallbackName 'BENCH') -Expected 'serial' -Label 'trailing dot'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial '   ' -FallbackName $null) -Expected 'Autopilot-device' -Label 'no serial and no computer name'
Assert-Equal -Actual (Get-AutopilotCsvFileName -Serial 'CON' -FallbackName 'CON') -Expected 'Autopilot-device' -Label 'reserved computer name'

$hash = ('A' * 1000)
$good = "Device Serial Number,Windows Product ID,Hardware Hash`r`nPF2ABCDE,,$hash`r`n"
$utf16 = New-Object byte[] (2 + ([Text.Encoding]::Unicode.GetByteCount($good)))
$utf16[0] = 0xFF
$utf16[1] = 0xFE
[Text.Encoding]::Unicode.GetBytes($good, 0, $good.Length, $utf16, 2) | Out-Null

$temp = Join-Path ([IO.Path]::GetTempPath()) ('autopilot-test-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $csv = Join-Path $temp 'device.csv'
    [IO.File]::WriteAllBytes($csv, $utf16)
    ConvertTo-AutopilotAnsiCsv -Path $csv
    $out = [IO.File]::ReadAllBytes($csv)
    if ($out.Length -ge 2 -and $out[0] -eq 0xFF -and $out[1] -eq 0xFE) {
        $failures.Add('CSV is still UTF-16.')
    }
    if ($out.Length -ge 3 -and $out[0] -eq 0xEF -and $out[1] -eq 0xBB -and $out[2] -eq 0xBF) {
        $failures.Add('CSV has a UTF-8 BOM.')
    }
    $text = [Text.Encoding]::GetEncoding(1252).GetString($out)
    Assert-Equal -Actual $text -Expected $good -Label 'ANSI round-trip of a UTF-16 Autopilot CSV'

    $quoted = Join-Path $temp 'quoted.csv'
    [IO.File]::WriteAllText($quoted, "Device Serial Number,Windows Product ID,Hardware Hash`r`n`"PF2`",,`"$hash`"`r`n")
    Assert-Throw -Script { ConvertTo-AutopilotAnsiCsv -Path $quoted } -Label 'quoted csv'

    $short = Join-Path $temp 'short.csv'
    [IO.File]::WriteAllText($short, "Device Serial Number,Windows Product ID,Hardware Hash`r`nPF2,,$('A' * 40)`r`n")
    Assert-Throw -Script { ConvertTo-AutopilotAnsiCsv -Path $short } -Label 'short hash'

    $headerOnly = Join-Path $temp 'header.csv'
    [IO.File]::WriteAllText($headerOnly, "Device Serial Number,Windows Product ID,Hardware Hash`r`n")
    Assert-Throw -Script { ConvertTo-AutopilotAnsiCsv -Path $headerOnly } -Label 'header only'

    $badHeader = Join-Path $temp 'bad-header.csv'
    [IO.File]::WriteAllText($badHeader, "device serial number,Windows Product ID,Hardware Hash`r`nPF2,,$hash`r`n")
    Assert-Throw -Script { ConvertTo-AutopilotAnsiCsv -Path $badHeader } -Label 'header case'

    $nonAnsi = Join-Path $temp 'non-ansi.csv'
    # U+4E2D is not in Windows-1252. Kept as a code point so this file stays ASCII.
    $unicodeSerial = "Device Serial Number,Windows Product ID,Hardware Hash`r`nSERIAL-$([char]0x4E2D),,$hash`r`n"
    $unicodeBytes = New-Object byte[] (2 + ([Text.Encoding]::Unicode.GetByteCount($unicodeSerial)))
    $unicodeBytes[0] = 0xFF
    $unicodeBytes[1] = 0xFE
    [Text.Encoding]::Unicode.GetBytes($unicodeSerial, 0, $unicodeSerial.Length, $unicodeBytes, 2) | Out-Null
    [IO.File]::WriteAllBytes($nonAnsi, $unicodeBytes)
    Assert-Throw -Script { ConvertTo-AutopilotAnsiCsv -Path $nonAnsi } -Label 'non-ANSI serial'

    $withTag = Join-Path $temp 'tag.csv'
    [IO.File]::WriteAllText($withTag, "Device Serial Number,Windows Product ID,Hardware Hash,Group Tag`r`nPF2ABCDE,,$hash,Kiosk`r`n")
    ConvertTo-AutopilotAnsiCsv -Path $withTag
    $tagText = [Text.Encoding]::GetEncoding(1252).GetString([IO.File]::ReadAllBytes($withTag))
    if ($tagText -notlike 'Device Serial Number,Windows Product ID,Hardware Hash,Group Tag*Kiosk*') {
        $failures.Add("Group tag row was not preserved.`n$tagText")
    }
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    throw ($failures -join "`n")
}

Write-Output 'AutopilotInfo tests passed.'
