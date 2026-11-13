<#
.SYNOPSIS
    The relay over bad connections in simulated time, no game and no sockets: builds netsim.cpp against one or two versions
    of native\ and runs the same sessions on each, seed for seed, so a change shows as numbers on the same connections.
    An hour of play takes seconds. Prints every run's lines, then a table of the numbers named in -Show, old against new.

.EXAMPLE
    .\tools\netlab\netsim.ps1 -Set links
    .\tools\netlab\netsim.ps1 -Old ..\old\native -Set links -Seconds 1800
    .\tools\netlab\netsim.ps1 -Old ..\old\native -Run '--players 6 --enemies 30 --rtt 80 --jitter 10 --loss 2'
    .\tools\netlab\netsim.ps1 -Set links -OldArgs '--enemy-rule 0' -NewArgs '--enemy-rule 1'      (one build, two rules)
#>
param(
    [string]$Old = '', [string]$New = (Join-Path $PSScriptRoot '..\..\native'),
    [string]$Set = '', [string[]]$Run = @(), [double]$Seconds = 600, [int[]]$Seeds = @(1),
    [string]$OldArgs = '', [string]$NewArgs = '', [string]$Out = '',
    [string[]]$Show = @('sure.host_to_guest:p50', 'sure.host_to_guest:p95', 'sure.host_to_guest:p99', 'sure.host_to_guest:late_pct',
        'quick.host_to_guest:p95', 'enemy:stop_p95', 'enemy:stop_max', 'enemy.health:p95', 'enemy.health:p99',
        'partner.host_to_guest:behind_p50', 'bytes:host_up_kb_s', 'bytes:guest_up_kb_s'),
    [string]$Work = (Join-Path $env:TEMP "pp-netsim-$PID")
)
$ErrorActionPreference = 'Stop'
$New = (Resolve-Path $New).Path
if ($Old) { $Old = (Resolve-Path $Old).Path }
New-Item -ItemType Directory -Force $Work | Out-Null
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$source = Join-Path $PSScriptRoot 'netsim.cpp'
$flags = '/nologo /std:c++20 /O2 /MT /EHsc /W3 /utf-8 /D_WINSOCK_DEPRECATED_NO_WARNINGS'
$libs = 'ws2_32.lib bcrypt.lib winmm.lib user32.lib'

# Each side: a name, the native folder it's built against, and what's added to every run's arguments.
$sides = @()
if ($Old) { $sides += @{ name = 'old'; native = $Old; extra = $OldArgs } }
elseif ($OldArgs -or $NewArgs) { $sides += @{ name = 'old'; native = $New; extra = $OldArgs } }
$sides += @{ name = 'new'; native = $New; extra = $NewArgs }
$built = @{}
foreach ($side in $sides) {
    if (-not $built[$side.native]) {
        $dir = Join-Path $Work "build$($built.Count)"
        New-Item -ItemType Directory -Force $dir | Out-Null
        $bat = Join-Path $dir 'build.bat'
        @"
@echo off
call "$vcvars" >nul 2>nul
cd /d "$dir"
cl $flags /I"$($side.native)" "$source" /Fe:netsim.exe /link /NOLOGO $libs || exit /b 1
"@ | Set-Content $bat -Encoding ascii
        & cmd /c $bat | Where-Object { $_ -match 'error|warning C' }
        if ($LASTEXITCODE -ne 0) { throw "netsim didn't build against $($side.native)" }
        $built[$side.native] = Join-Path $dir 'netsim.exe'
    }
    $side.exe = $built[$side.native]
}

# The sets: connections two players meet, then parties.
$runs = @()
switch ($Set) {
    'links' {
        $runs += '--rtt 30 --jitter 3 --loss 0'
        $runs += '--rtt 30 --jitter 3 --loss 2'
        $runs += '--rtt 80 --jitter 10 --loss 1'
        $runs += '--rtt 80 --jitter 10 --loss 2'
        $runs += '--rtt 80 --jitter 10 --loss 5'
        $runs += '--rtt 150 --jitter 10 --loss 2'
        $runs += '--rtt 150 --jitter 30 --loss 5'
        $runs += '--rtt 250 --jitter 30 --loss 2'
        $runs += '--rtt 80 --jitter 10 --burst-loss 3 --burst-ms 60'       # Wi-Fi: everything for about 60 ms, 3% of the time
        $runs += '--rtt 150 --jitter 10 --burst-loss 2 --burst-ms 100'
        $runs += '--rtt 80 --jitter 20 --loss 2 --stall-every 7 --stall-ms 250'
    }
    'party' {
        foreach ($n in 2, 3, 4, 5, 6) { $runs += "--players $n --enemies 8 --rtt 80 --jitter 10 --loss 1" }
        foreach ($n in 2, 4, 6) { $runs += "--players $n --enemies 30 --rtt 80 --jitter 10 --loss 1" }
    }
    'lone' {
        # A fight's events at the rate the Lua sim counts them: one at a time, a second or two apart.
        foreach ($link in '--rtt 30 --jitter 3 --loss 2', '--rtt 80 --jitter 10 --loss 2', '--rtt 150 --jitter 10 --loss 2', '--rtt 150 --jitter 30 --loss 5',
            '--rtt 250 --jitter 30 --loss 2', '--rtt 80 --jitter 10 --burst-loss 3 --burst-ms 60', '--rtt 150 --jitter 10 --burst-loss 2 --burst-ms 100') {
            $runs += "$link --lone 1 --enemies 0"
        }
    }
    '' { }
    default { throw "No set '$Set': links, party or lone." }
}
$runs += $Run
if (-not $runs) { throw 'Nothing to run: give -Set links|party|lone or -Run "<netsim options>".' }

$table = [System.Collections.ArrayList]::new()
$raw = [System.Collections.ArrayList]::new()
foreach ($run in $runs) {
    foreach ($seed in $Seeds) {
        $row = [ordered]@{ run = $run; seed = $seed }
        foreach ($side in $sides) {
            $argv = "$run --seconds $Seconds --seed $seed $($side.extra)".Trim() -split '\s+'
            $lines = & $side.exe @argv
            if ($LASTEXITCODE -ne 0) { throw "netsim failed: $run" }
            foreach ($line in $lines) { [void]$raw.Add("$($side.name) $line") }
            $values = @{}
            foreach ($line in $lines) {
                $parts = $line -split ' '
                foreach ($part in $parts[1..($parts.Count - 1)]) {
                    if ($part -match '^([^=]+)=(-?[\d.]+)$') { $values["$($parts[0]):$($Matches[1])"] = [double]$Matches[2] }
                }
            }
            $row[$side.name] = $values
        }
        [void]$table.Add($row)
    }
}
if ($Out) { $raw | Set-Content $Out -Encoding utf8 }
$raw
''
foreach ($row in $table) {
    "== $($row.run)  (seed $($row.seed), $Seconds s)"
    foreach ($key in $Show) {
        $new = $row['new'][$key]
        if ($null -eq $new) { continue }
        if ($row.Contains('old')) {
            $old = $row['old'][$key]
            '  {0,-36} {1,9:0.0} -> {2,9:0.0}' -f $key, $old, $new
        } else {
            '  {0,-36} {1,9:0.0}' -f $key, $new
        }
    }
}
Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
