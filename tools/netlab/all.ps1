<#
.SYNOPSIS
    Everything that needs no game, in one command: builds, then the logic, the processes over real sockets, and two relays
    through a clean and a bad connection. The last line is PASS or FAIL. Takes about 3 minutes; exit code 1 on FAIL.

.EXAMPLE
    .\tools\netlab\all.ps1
    .\tools\netlab\all.ps1 -NoBuild
#>
param([switch]$NoBuild, [switch]$NoRestart, [int]$Port = 0)
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Port) { $Port = 48000 + ($PID % 40) * 40 }     # several runs at once mustn't meet on a port
$failed = [System.Collections.ArrayList]::new()

function Step($name, [scriptblock]$body) {
    "`n=== $name"
    $start = Get-Date
    try {
        & $body
    } catch {
        "  FAIL $_"
        [void]$failed.Add($name)
    }
    "    ($([int]((Get-Date) - $start).TotalSeconds) s)"
}

# Tests run from a copy of their own: another build can't pull the file away, and they can't hold up another build.
$private = Join-Path $env:TEMP "pp-all-$PID"
New-Item -ItemType Directory -Force $private | Out-Null
$cli = Join-Path $private 'relay_cli.exe'

Step 'build' {
    if (-not $NoBuild) {
        # build-native.ps1 ends without releasing its lock, which leaves it "abandoned": the next wait on it throws.
        $lock = New-Object System.Threading.Mutex($false, 'Global\PhantomPactBuild')
        try { [void]$lock.WaitOne() } catch [System.Threading.AbandonedMutexException] {}
        $lock.ReleaseMutex()
        & (Join-Path $root 'tools\build-native.ps1') 2>&1 | Where-Object { $_ -match 'error|warning C|KB$' } | ForEach-Object { "  $_" }
    }
    Copy-Item (Join-Path $root 'native\build\relay_cli.exe') $cli -Force
}

Step 'lua check' {
    python -I (Join-Path $PSScriptRoot 'lualint.py')
    if ($LASTEXITCODE -ne 0) { [void]$failed.Add('lua check') }
}

Step 'events' {
    python -I (Join-Path $PSScriptRoot 'eventcheck.py') | ForEach-Object { "  $_" }
    if ($LASTEXITCODE -ne 0) { [void]$failed.Add('events') }
}

Step 'lua, four players' {
    # Skipped on a PC with no Lua DLL (luasim.py says which it looks for).
    $out = python -I (Join-Path $PSScriptRoot 'luasim.py') four
    $code = $LASTEXITCODE
    $out | Where-Object { $_ -match 'FAIL|No Lua DLL' } | ForEach-Object { "  $_" }
    "  $(($out | Where-Object { $_ -match '^\s+ok ' }).Count) checks passed"
    if ($code -ne 0 -and ($out -notmatch 'No Lua DLL')) { [void]$failed.Add('lua, four players') }
}

Step 'lua, a PvP match' {
    $out = python -I (Join-Path $PSScriptRoot 'luasim.py') pvp
    $code = $LASTEXITCODE
    $out | Where-Object { $_ -match 'FAIL|No Lua DLL' } | ForEach-Object { "  $_" }
    "  $(($out | Where-Object { $_ -match '^\s+ok ' }).Count) checks passed"
    if ($code -ne 0 -and ($out -notmatch 'No Lua DLL')) { [void]$failed.Add('lua, a PvP match') }
}

Step 'relay_cli test' {
    $out = & $cli test --port ($Port + 30)
    $code = $LASTEXITCODE
    $out | Where-Object { $_ -match 'FAIL' } | ForEach-Object { $_ }
    "  $(($out | Where-Object { $_ -match '^\s+ok ' }).Count) checks passed"
    if ($code -ne 0) { [void]$failed.Add('relay_cli test') }
}

Step 'netsim' {
    # The relay over a lossy connection in simulated time (netsim.ps1): what a lost packet costs a sure event. The slowest
    # 1% took 347 ms at ping 150 with 2% loss before each went again a frame later, and 114 since (docs/NETCODE.md).
    $out = & (Join-Path $PSScriptRoot 'netsim.ps1') -Run '--rtt 150 --jitter 10 --loss 2' -Seconds 900 -Work (Join-Path $private 'netsim')
    $sure = $out | Where-Object { $_ -match '^new sure\.host_to_guest' } | Select-Object -First 1
    $quick = $out | Where-Object { $_ -match '^new quick\.lost' } | Select-Object -First 1
    $bytes = $out | Where-Object { $_ -match '^new bytes ' } | Select-Object -First 1
    $p99 = if ($sure -match ' p99=([\d.]+)') { [double]$Matches[1] } else { -1 }
    $wrong = if ($quick -match 'wrong_order=(\d+)') { [int]$Matches[1] } else { -1 }
    $good = $p99 -ge 0 -and $p99 -lt 160 -and $wrong -eq 0
    "  $(if ($good) { 'ok  ' } else { 'FAIL' }) ping 150 with 2% loss, 15 minutes: the slowest 1% of sure events $p99 ms after they were sent (limit 160), $wrong out of order"
    if (-not $good) { [void]$failed.Add('netsim') }
    # The copies add no packets: they ride in the frame's packet, and their acknowledgement waits for the next. 1.7.3 sends
    # 103.3 and 73.7 packets a second here; with a copy in a packet of its own, or its acknowledgement hurried, 109.5 and 81.1.
    $hostPackets = if ($bytes -match 'host_packets_s=([\d.]+)') { [double]$Matches[1] } else { -1 }
    $guestPackets = if ($bytes -match 'guest_packets_s=([\d.]+)') { [double]$Matches[1] } else { -1 }
    $good = $hostPackets -gt 0 -and $hostPackets -lt 105 -and $guestPackets -gt 0 -and $guestPackets -lt 75.5
    "  $(if ($good) { 'ok  ' } else { 'FAIL' }) and no more packets for it: $hostPackets a second from the host (limit 105), $guestPackets from the guest (limit 75.5)"
    if (-not $good) { [void]$failed.Add('netsim, packets') }
    # A party above 60 FPS: each guest's place goes on to the others 60 times a second at most. Six players at 120 FPS upload
    # 174 KB/s from the host on 1.7.3 and 175 here; with every place passed on it was 205.
    $out = & (Join-Path $PSScriptRoot 'netsim.ps1') -Run '--players 6 --enemies 8 --rtt 80 --jitter 10 --loss 1 --fps 120' -Seconds 120 -Work (Join-Path $private 'netsim')
    $bytes = $out | Where-Object { $_ -match '^new bytes ' } | Select-Object -First 1
    $upload = if ($bytes -match 'host_up_kb_s=([\d.]+)') { [double]$Matches[1] } else { -1 }
    $good = $upload -gt 0 -and $upload -lt 185
    "  $(if ($good) { 'ok  ' } else { 'FAIL' }) six players at 120 FPS: the host uploads $upload KB/s (limit 185)"
    if (-not $good) { [void]$failed.Add('netsim, party') }
    # Three players above 60 FPS: a place held for its budget rides the host's next packet. Sent by itself a few ms before
    # that packet, it was a fifth more lone places: 387 packets a second from the host in this run, 365 now.
    $out = & (Join-Path $PSScriptRoot 'netsim.ps1') -Run '--players 3 --enemies 8 --rtt 80 --jitter 10 --loss 1 --fps 120' -Seconds 120 -Work (Join-Path $private 'netsim')
    $bytes = $out | Where-Object { $_ -match '^new bytes ' } | Select-Object -First 1
    $hostPackets = if ($bytes -match 'host_packets_s=([\d.]+)') { [double]$Matches[1] } else { -1 }
    $good = $hostPackets -gt 0 -and $hostPackets -lt 376
    "  $(if ($good) { 'ok  ' } else { 'FAIL' }) three players at 120 FPS: $hostPackets packets a second from the host (limit 376)"
    if (-not $good) { [void]$failed.Add('netsim, three players') }
}

if (-not $NoRestart) { Step 'restart-test' {
    $out = & (Join-Path $PSScriptRoot 'restart-test.ps1') -Cli $cli -Port $Port
    $code = $LASTEXITCODE
    $out | Where-Object { $_ -match 'FAIL|^==' } | ForEach-Object { $_ }
    "  $(($out | Where-Object { $_ -match '^\s+ok ' }).Count) checks passed"
    if ($code -ne 0) { [void]$failed.Add('restart-test') }
} }

function Bench($name, $limit_ms, [hashtable]$link) {
    $out = & (Join-Path $PSScriptRoot 'bench.ps1') @link -Seconds 8 -Cli $cli -Port ($Port + 34) -Work (Join-Path $private 'bench')
    $line = $out | Where-Object { $_ -match '^ghost behind real' } | Select-Object -First 1
    $sure = $out | Where-Object { $_ -match '^sure_lane' } | Select-Object -First 1
    $p95 = if ($line -match 'p95\s+([\d.]+)') { [double]$Matches[1] } else { -1 }
    $wrong = if ($sure -match 'wrong_order=(\d+)') { [int]$Matches[1] } else { -1 }
    $got = if ($sure -match 'got=(\d+)') { [int]$Matches[1] } else { 0 }
    $good = $p95 -ge 0 -and $p95 -lt $limit_ms -and $wrong -eq 0 -and $got -gt 40
    "  $(if ($good) { 'ok  ' } else { 'FAIL' }) $name`: ghost $p95 ms behind at the 95th percentile (limit $limit_ms), $got sure events, $wrong out of order"
    if (-not $good) { [void]$failed.Add("bench: $name") }
}

Step 'bench' {
    Bench 'clean link' 60 @{ Delay = 2; Jitter = 0 }
    Bench 'bad link' 320 @{ Delay = 40; Jitter = 20; Loss = 2; StallEvery = 3; StallMs = 250 }
}

Step 'bench, four players' {
    $out = & (Join-Path $PSScriptRoot 'party-bench.ps1') -Seconds 8 -Cli $cli -Port ($Port + 38) -Work (Join-Path $private 'party')
    $out | Where-Object { $_ -match '^(ok|FAIL)|^\s+(ok|FAIL)' } | ForEach-Object { "  $_" }
    if ($LASTEXITCODE -ne 0) { [void]$failed.Add('bench, four players') }
}

Remove-Item -Recurse -Force $private -ErrorAction SilentlyContinue
if ($failed.Count) {
    "`nFAIL: $($failed -join ', ')"
    exit 1
}
"`nPASS: build, relay_cli test, $(if ($NoRestart) { 'bench (restart-test skipped)' } else { 'restart-test and bench' })"
exit 0
