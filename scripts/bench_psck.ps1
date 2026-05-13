#Requires -Version 5.1
<#
.SYNOPSIS
    Automated PSCKangaroo benchmark - Windows / PowerShell port of bench_psck.sh

.DESCRIPTION
    Tests combinations of V45_OCCUPANCY x V45_PNT_GROUP_CNT to find the
    configuration that maximizes GKey/s on the current hardware.

    For each combination:
      1. Edits defs.h to set V45_OCCUPANCY and V45_PNT_GROUP_CNT
      2. Cleans and rebuilds via MSBuild (Release|x64)
      3. Runs the binary for RUN_SECONDS, parses speed samples
      4. Records results to CSV
    Restores original defs.h and rebuilds at the end.

.PARAMETER PSCKDir
    Path to PSCKangaroo source directory. Defaults to %USERPROFILE%\Desafios\rck\PSCKangaroo
    or environment variable PSCK_DIR.

.PARAMETER OccList
    Space-separated list of V45_OCCUPANCY values to test. Default: "1 2"

.PARAMETER PntList
    Space-separated list of V45_PNT_GROUP_CNT values to test. Default: "12 16 24 32 48"

.PARAMETER RunSeconds
    How long to run each test. Default: 90

.PARAMETER WarmupSeconds
    Discard speed samples taken before this many seconds. Default: 30

.EXAMPLE
    .\bench_psck.ps1

.EXAMPLE
    .\bench_psck.ps1 -PntList "24 48 64" -RunSeconds 120

.NOTES
    Requires Visual Studio 2019+ with C++/CUDA build tools, or
    Build Tools for Visual Studio. MSBuild is located automatically via
    vswhere.exe if not in PATH.
#>

param(
    [string]$PSCKDir      = $(if ($env:PSCK_DIR)       { $env:PSCK_DIR }       else { Join-Path $env:USERPROFILE "Desafios\rck\PSCKangaroo" }),
    [string]$OccList      = $(if ($env:OCC_LIST)       { $env:OCC_LIST }       else { "1 2" }),
    [string]$PntList      = $(if ($env:PNT_LIST)       { $env:PNT_LIST }       else { "12 16 24 32 48" }),
    [int]   $RunSeconds   = $(if ($env:RUN_SECONDS)    { [int]$env:RUN_SECONDS }    else { 90 }),
    [int]   $WarmupSeconds = $(if ($env:WARMUP_SECONDS) { [int]$env:WARMUP_SECONDS } else { 30 })
)

# Force invariant culture so floats use '.' not ',' regardless of system locale
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
$ErrorActionPreference = "Stop"
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

# ----------------------------------------------------------------------------
# Locate MSBuild (try PATH first, then vswhere)
# ----------------------------------------------------------------------------
function Find-MSBuild {
    $cmd = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        $vswhere = Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe"
    }
    if (Test-Path $vswhere) {
        $found = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild `
                            -find "MSBuild\**\Bin\MSBuild.exe" 2>$null | Select-Object -First 1
        if ($found -and (Test-Path $found)) { return $found }
    }
    return $null
}

$MSBuild = Find-MSBuild
if (-not $MSBuild) {
    Write-Host "ERROR: MSBuild not found." -ForegroundColor Red
    Write-Host "Either:"
    Write-Host "  - Run this from 'Developer Command Prompt for VS' / 'Developer PowerShell for VS', or"
    Write-Host "  - Install Visual Studio Build Tools with C++ workload."
    exit 1
}

# ----------------------------------------------------------------------------
# Validate paths
# ----------------------------------------------------------------------------
if (-not (Test-Path $PSCKDir)) {
    Write-Host "ERROR: PSCKDir not found: $PSCKDir" -ForegroundColor Red
    exit 1
}
Set-Location $PSCKDir

$DefsH        = Join-Path $PSCKDir "defs.h"
$SolutionFile = Join-Path $PSCKDir "PSCKangaroo.sln"
$ExePath      = Join-Path $PSCKDir "x64\Release\PSCKangaroo.exe"

foreach ($f in @($DefsH, $SolutionFile)) {
    if (-not (Test-Path $f)) {
        Write-Host "ERROR: Required file not found: $f" -ForegroundColor Red
        exit 1
    }
}

# ----------------------------------------------------------------------------
# Setup output dir
# ----------------------------------------------------------------------------
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$OutDir    = Join-Path $env:USERPROFILE "bench_results\$Timestamp"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$ResultsCsv = Join-Path $OutDir "results.csv"
$SummaryTxt = Join-Path $OutDir "summary.txt"

"occupancy,pnt_group_cnt,registers,spill_bytes,compile_ok,gkey_s,samples,run_ok" | Set-Content $ResultsCsv

# Backup defs.h (will be restored at end, even on Ctrl+C)
$DefsBackup = Join-Path $OutDir "defs.h.orig"
Copy-Item $DefsH $DefsBackup

# ----------------------------------------------------------------------------
# Parse input lists
# ----------------------------------------------------------------------------
$OccArray = $OccList.Trim() -split '\s+' | ForEach-Object { [int]$_ }
$PntArray = $PntList.Trim() -split '\s+' | ForEach-Object { [int]$_ }
$TotalTests = $OccArray.Count * $PntArray.Count
$TestNum    = 0
$StartTime  = Get-Date

# ----------------------------------------------------------------------------
# Header
# ----------------------------------------------------------------------------
$estimatedMin = [math]::Round($TotalTests * ($RunSeconds + 45) / 60)
@"

================================================================================
PSCKangaroo Benchmark Sweep (Windows / PowerShell)
================================================================================
Directory:       $PSCKDir
Output:          $OutDir
OCC_LIST:        $OccList
PNT_LIST:        $PntList
Duration/test:   ${RunSeconds}s (discarding first ${WarmupSeconds}s as warmup)
Total tests:    $TotalTests
Estimated time: ~$estimatedMin minutes
MSBuild:         $MSBuild
================================================================================
"@ | Write-Host

# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------
function Update-DefsH {
    param([string]$Path, [int]$Occ, [int]$Pnt)
    # Read whole file, replace ALL '#define V45_OCCUPANCY N' / '#define V45_PNT_GROUP_CNT N' lines.
    # Multiline mode so '^' matches start of each line.
    # Doesn't touch '#ifndef V45_*' lines.
    $content = Get-Content $Path -Raw
    # Capture leading whitespace ($1) since these defines sit inside indented #if/#else blocks
    $content = [regex]::Replace($content, '(?m)^(\s*)#define\s+V45_OCCUPANCY\s+\d+',     "`${1}#define V45_OCCUPANCY $Occ")
    $content = [regex]::Replace($content, '(?m)^(\s*)#define\s+V45_PNT_GROUP_CNT\s+\d+', "`${1}#define V45_PNT_GROUP_CNT $Pnt")
    # Preserve original line endings: use [IO.File]::WriteAllText to avoid PowerShell appending an extra CRLF.
    [System.IO.File]::WriteAllText($Path, $content)
}

function Get-CompileMetrics {
    param([string]$LogPath)
    $regs = "?"; $spill = "0"
    if (Test-Path $LogPath) {
        $log = Get-Content $LogPath -Raw
        if ($log -match 'Used\s+(\d+)\s+registers')        { $regs  = $Matches[1] }
        if ($log -match '(\d+)\s+bytes\s+spill\s+stores')  { $spill = $Matches[1] }
    }
    return @{ Regs = $regs; Spill = $spill }
}

function Get-SpeedAverage {
    param([string]$LogPath, [int]$WarmupSec)
    if (-not (Test-Path $LogPath)) { return @{ Avg = "0.000"; Samples = 0 } }
    # Match lines like: "CONC: Speed: 2.70 GKeys/s | Time: 0d 00h 01m"
    $pattern = 'Speed:\s+([\d.]+)\s+GKeys.*?Time:\s+(\d+)d\s+(\d+)h\s+(\d+)m'
    $sum = 0.0; $n = 0
    foreach ($line in (Get-Content $LogPath)) {
        if ($line -match $pattern) {
            $speed   = [double]::Parse($Matches[1], $InvariantCulture)
            $totalSec = ([int]$Matches[2] * 86400) + ([int]$Matches[3] * 3600) + ([int]$Matches[4] * 60)
            if ($totalSec -ge $WarmupSec -and $speed -gt 0) { $sum += $speed; $n++ }
        }
    }
    if ($n -gt 0) {
        return @{ Avg = ($sum / $n).ToString("F3", $InvariantCulture); Samples = $n }
    }
    return @{ Avg = "0.000"; Samples = 0 }
}

# ----------------------------------------------------------------------------
# Main loop (wrapped in try/finally to guarantee defs.h restore)
# ----------------------------------------------------------------------------
try {
    foreach ($occ in $OccArray) {
        foreach ($pnt in $PntArray) {
            $TestNum++
            $tag        = "occ${occ}_pnt${pnt}"
            $compileLog = Join-Path $OutDir "compile_${tag}.log"
            $runLog     = Join-Path $OutDir "run_${tag}.log"

            Write-Host ""
            Write-Host "[Test $TestNum/$TotalTests] OCC=$occ PNT=$pnt"

            # Edit defs.h
            Update-DefsH -Path $DefsH -Occ $occ -Pnt $pnt

            # Clean + build
            Write-Host "    Compiling..."
            & $MSBuild $SolutionFile /p:Configuration=Release /p:Platform=x64 /t:Clean /v:m | Out-Null
            & $MSBuild $SolutionFile /p:Configuration=Release /p:Platform=x64 /m /v:m > $compileLog 2>&1
            $compileOk = if ($LASTEXITCODE -eq 0) { 1 } else { 0 }

            if ($compileOk -eq 0) {
                Write-Host "    [FAIL] Compile error (see $compileLog)" -ForegroundColor Red
                "$occ,$pnt,?,?,0,0.000,0,0" | Add-Content $ResultsCsv
                continue
            }
            $cm = Get-CompileMetrics -LogPath $compileLog
            Write-Host "    Compile OK: $($cm.Regs) regs, $($cm.Spill)B spill"

            if (-not (Test-Path $ExePath)) {
                Write-Host "    [FAIL] Executable not found: $ExePath" -ForegroundColor Red
                "$occ,$pnt,$($cm.Regs),$($cm.Spill),1,0.000,0,0" | Add-Content $ResultsCsv
                continue
            }

            # Run with timeout
            Write-Host "    Running ${RunSeconds}s..."
            $runArgs = @(
                "-gpu", "0",
                "-dp", "16",
                "-range", "134",
                "-pubkey", "02145d2611c823a396ef6712ce0f712f09b9b4f3135e3e0aa3230fb9b6d08d1e16",
                "-start", "4000000000000000000000000000000000",
                "-ramlimit", "8",
                "-concurrent", "1",
                "-wwbuffer", "1",
                "-checkpoint", "999"
            )
            $errLog = "$runLog.err"
            $proc = Start-Process -FilePath $ExePath -ArgumentList $runArgs -NoNewWindow -PassThru `
                                   -RedirectStandardOutput $runLog -RedirectStandardError $errLog `
                                   -WorkingDirectory $PSCKDir
            $finished = $proc.WaitForExit($RunSeconds * 1000)
            $runOk = 1
            if (-not $finished) {
                try { $proc.Kill() } catch {}
                $proc.WaitForExit()
            }
            if (Test-Path $errLog) {
                Get-Content $errLog | Add-Content $runLog
                Remove-Item $errLog -ErrorAction SilentlyContinue
            }

            $sp = Get-SpeedAverage -LogPath $runLog -WarmupSec $WarmupSeconds
            if ($sp.Samples -gt 0) {
                Write-Host "    [OK] $($sp.Avg) GKeys/s ($($sp.Samples) stable samples)"
            } else {
                Write-Host "    [WARN] No stable samples (ran too short?)" -ForegroundColor Yellow
            }
            "$occ,$pnt,$($cm.Regs),$($cm.Spill),1,$($sp.Avg),$($sp.Samples),$runOk" | Add-Content $ResultsCsv
        }
    }
}
finally {
    Write-Host ""
    Write-Host "Restoring original defs.h..."
    Copy-Item $DefsBackup $DefsH -Force
    & $MSBuild $SolutionFile /p:Configuration=Release /p:Platform=x64 /t:Clean /v:m | Out-Null
    & $MSBuild $SolutionFile /p:Configuration=Release /p:Platform=x64 /m /v:m > (Join-Path $OutDir "restore.log") 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [OK] Default build restored"
    } else {
        Write-Host "    [WARN] Failed to restore default build (see restore.log)" -ForegroundColor Yellow
    }
}

# ----------------------------------------------------------------------------
# Summary table
# ----------------------------------------------------------------------------
$Elapsed = (Get-Date) - $StartTime
$sep = ("=" * 80)
$line = ("-" * 60)

$rows = Get-Content $ResultsCsv | Select-Object -Skip 1 | ForEach-Object {
    $f = $_.Split(",")
    [PSCustomObject]@{
        Occ = $f[0]; Pnt = $f[1]; Regs = $f[2]; Spill = $f[3]
        CompileOk = $f[4]
        GkeyS = [double]::Parse($f[5], $InvariantCulture)
        Samples = [int]$f[6]; RunOk = $f[7]
    }
} | Sort-Object GkeyS -Descending

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("")
[void]$sb.AppendLine($sep)
[void]$sb.AppendLine("RESULTS - ranked by GKeys/s")
[void]$sb.AppendLine($sep)
[void]$sb.AppendLine("")
[void]$sb.AppendLine(("{0,-4} {1,-5} {2,-7} {3,-7} {4,-8} {5,-9} {6,-12}" -f "OCC","PNT","REGS","SPILL","GKEY/S","SAMPLES","STATUS"))
[void]$sb.AppendLine($line)

foreach ($r in $rows) {
    $status = if     ($r.CompileOk -eq "0") { "COMPILE FAIL" }
              elseif ($r.Samples   -eq  0)  { "NO SAMPLES" }
              elseif ($r.RunOk     -eq "0") { "PARTIAL" }
              else { "OK" }
    [void]$sb.AppendLine(("{0,-4} {1,-5} {2,-7} {3,-7} {4,-8} {5,-9} {6,-12}" -f `
        $r.Occ, $r.Pnt, $r.Regs, $r.Spill, $r.GkeyS.ToString("F3", $InvariantCulture), $r.Samples, $status))
}
[void]$sb.AppendLine($line)

$best = $rows | Where-Object { $_.CompileOk -eq "1" -and $_.Samples -gt 0 } | Select-Object -First 1
if ($best) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("BEST: OCC=$($best.Occ) PNT=$($best.Pnt) -> $($best.GkeyS.ToString('F3', $InvariantCulture)) GKeys/s")
    [void]$sb.AppendLine("To use: edit defs.h and set V45_OCCUPANCY=$($best.Occ), V45_PNT_GROUP_CNT=$($best.Pnt), then rebuild.")
}

$baseline = $rows | Where-Object { $_.Occ -eq "1" -and $_.Pnt -eq "24" -and $_.CompileOk -eq "1" -and $_.Samples -gt 0 } | Select-Object -First 1
if ($best -and $baseline) {
    $improvement = (($best.GkeyS / $baseline.GkeyS) - 1) * 100
    [void]$sb.AppendLine("Baseline (OCC=1, PNT=24): $($baseline.GkeyS.ToString('F3', $InvariantCulture)) GKeys/s")
    [void]$sb.AppendLine("Improvement vs baseline:  $($improvement.ToString('F1', $InvariantCulture))%")
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine(("Total time: {0}m {1}s" -f [math]::Floor($Elapsed.TotalMinutes), $Elapsed.Seconds))
[void]$sb.AppendLine("Logs in:    $OutDir")
[void]$sb.AppendLine($sep)

$output = $sb.ToString()
Write-Host $output
$output | Set-Content $SummaryTxt
