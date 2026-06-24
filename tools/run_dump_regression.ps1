param(
    [string]$MemNixFS = "",
    [string]$DumpDir = "",
    [string]$OutDir = "",
    [int]$CaseTimeoutSec = 180,
    [string]$CaseFilter = "",
    [switch]$IncludeHttp
)

$ErrorActionPreference = "Stop"

$repo = Resolve-Path (Join-Path $PSScriptRoot "..")
if (-not $MemNixFS) {
    $candidate = Join-Path $repo "build\msvc-x64\Release\memnixfs.exe"
    if (-not (Test-Path $candidate)) {
        $candidate = Join-Path $repo "build\msvc-x64-mount\Release\memnixfs.exe"
    }
    if (-not (Test-Path $candidate)) {
        $candidate = Join-Path $repo "build\msvc-x64-debug\Debug\memnixfs.exe"
    }
    $MemNixFS = $candidate
}
if (-not (Test-Path $MemNixFS)) {
    throw "memnixfs executable not found: $MemNixFS"
}

if (-not $DumpDir) {
    $DumpDir = Join-Path $repo "..\Test dumps"
}
if (-not (Test-Path $DumpDir)) {
    throw "dump directory not found: $DumpDir"
}

if (-not $OutDir) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $OutDir = Join-Path $repo "build\dump-regression-$stamp"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$cache = Join-Path $OutDir "symbols"
New-Item -ItemType Directory -Force -Path $cache | Out-Null

$common = @("--symbol-cache", $cache)
if (-not $IncludeHttp) {
    $common += "--no-http-cache"
}

$cases = @(
    @{ Name = "list"; Args = @("list") },
    @{ Name = "tree"; Args = @("tree") },
    @{ Name = "banner"; Args = @("cat", "/sys/banner.txt") },
    @{ Name = "users"; Args = @("cat", "/sys/users.txt") },
    @{ Name = "pagecache"; Args = @("cat", "/sys/pagecache/index.txt") },
    @{ Name = "recovery"; Args = @("cat", "/sys/pagecache/recovery.txt") },
    @{ Name = "path-quality"; Args = @("cat", "/sys/pagecache/path_quality.txt") },
    @{ Name = "fs-etc-passwd"; Args = @("cat", "/fs/etc/passwd") },
    @{ Name = "fs-os-release"; Args = @("cat", "/fs/etc/os-release") },
    @{ Name = "fs-hostname"; Args = @("cat", "/fs/etc/hostname") },
    @{ Name = "fs-bash"; Args = @("cat", "/fs/usr/bin/bash") },
    @{ Name = "kallsyms-init-task"; Args = @("kallsyms", "init_task"); NoCommon = $true }
)

$summary = Join-Path $OutDir "summary.tsv"
"dump`tcase`texit_code`tstdout_bytes`tstderr_bytes`tzero_bytes`tnonzero_bytes`tprintable_bytes`tdiagnostic" |
    Set-Content -Path $summary -Encoding UTF8

function Measure-OutputFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return @{ Zero = 0; NonZero = 0; Printable = 0; Diagnostic = "missing-output" }
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $zero = 0
    $nonzero = 0
    $printable = 0
    foreach ($b in $bytes) {
        if ($b -eq 0) { $zero++ } else { $nonzero++ }
        if (($b -eq 9) -or ($b -eq 10) -or ($b -eq 13) -or ($b -ge 32 -and $b -le 126)) {
            $printable++
        }
    }
    $text = ""
    if ($bytes.Length -gt 0) {
        $take = [Math]::Min($bytes.Length, 4096)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $take)
    }
    $diagnostic = if ($text -match "^(unavailable|partial|unsupported):") { "yes" } else { "no" }
    return @{ Zero = $zero; NonZero = $nonzero; Printable = $printable; Diagnostic = $diagnostic }
}

Get-ChildItem -LiteralPath $DumpDir -File | Sort-Object Name | ForEach-Object {
    $dump = $_
    $safe = ($dump.Name -replace '[^A-Za-z0-9_.-]', '_')
    foreach ($case in $cases) {
        if ($CaseFilter -and (($CaseFilter -split ",") -notcontains $case.Name)) {
            continue
        }
        $prefix = Join-Path $OutDir "$safe.$($case.Name)"
        $stdout = "$prefix.out.txt"
        $stderr = "$prefix.err.txt"
        $procArgs = @("--dump", $dump.FullName)
        if (-not $case.NoCommon) {
            $procArgs += $common
        }
        $procArgs += $case.Args
        $argLine = ($procArgs | ForEach-Object {
            if ($_ -match '[\s"]') {
                '"' + ($_ -replace '"', '\"') + '"'
            } else {
                $_
            }
        }) -join " "

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = (Resolve-Path $MemNixFS).Path
        $psi.Arguments = $argLine
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $outStream = [System.IO.File]::Create($stdout)
        $errStream = [System.IO.File]::Create($stderr)
        $outTask = $p.StandardOutput.BaseStream.CopyToAsync($outStream)
        $errTask = $p.StandardError.BaseStream.CopyToAsync($errStream)
        if (-not $p.WaitForExit($CaseTimeoutSec * 1000)) {
            $p.Kill()
            $p.WaitForExit()
            $exitCode = 124
        } else {
            $exitCode = $p.ExitCode
        }
        $outTask.Wait()
        $errTask.Wait()
        $outStream.Dispose()
        $errStream.Dispose()

        $outBytes = if (Test-Path $stdout) { (Get-Item $stdout).Length } else { 0 }
        $errBytes = if (Test-Path $stderr) { (Get-Item $stderr).Length } else { 0 }
        $metrics = Measure-OutputFile -Path $stdout
        "$($dump.Name)`t$($case.Name)`t$exitCode`t$outBytes`t$errBytes`t$($metrics.Zero)`t$($metrics.NonZero)`t$($metrics.Printable)`t$($metrics.Diagnostic)" |
            Add-Content -Path $summary -Encoding UTF8
    }
}

Write-Host "Regression summary: $summary"
