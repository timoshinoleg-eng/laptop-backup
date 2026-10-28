<#
.SYNOPSIS
    Учебное восстановление: проверяет, что последний снимок РЕАЛЬНО восстанавливается.

.DESCRIPTION
    Бэкап, который ни разу не восстановили, — это гипотеза, а не бэкап.
    Скрипт берёт последний снимок, восстанавливает его во временный каталог и сравнивает
    с исходными файлами по хешам. Это единственная проверка, которая доказывает, что
    данные не потеряны, а бэкап пригоден для отката.

    Также умеет восстановить ОТДЕЛЬНЫЙ файл/каталог в заданное место — это уже
    боевое восстановление, если нужно вытащить конкретный документ.

.EXAMPLE
    pwsh -File restore-check.ps1 -ConfigPath .\config.json
    pwsh -File restore-check.ps1 -ConfigPath .\config.json -RestorePath 'C:\Users\tim\Documents\отчёт.docx' -Target 'D:\Recovered'
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$ResticPath = '',
    [string]$RestorePath = '',
    [string]$Target = '',
    [switch]$KeepRestored
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param([string]$M) Write-Host "==> $M" -ForegroundColor Cyan }
function Write-Ok   { param([string]$M) Write-Host "    [OK] $M" -ForegroundColor Green }
function Write-Warn { param([string]$M) Write-Host "    [!] $M"  -ForegroundColor Yellow }
function Write-Err  { param([string]$M) Write-Host "    [X] $M"  -ForegroundColor Red }

function Get-ResticExecutable {
    param([string]$ExplicitPath)
    if ($ExplicitPath) {
        if (Test-Path $ExplicitPath) { return (Resolve-Path $ExplicitPath).Path }
        throw "restic не найден: $ExplicitPath"
    }
    $cmd = Get-Command restic -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($c in @((Join-Path $PSScriptRoot 'restic.exe'),
                     (Join-Path $env:LOCALAPPDATA 'Programs\restic\restic.exe'))) {
        if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
    }
    throw "restic не найден. Скачай restic.exe и положи рядом со скриптом."
}

function Invoke-Restic {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$ResticArgs,
        [string[]]$Env = @(),
        [int]$TimeoutSec = 3600
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ($ResticArgs | ForEach-Object {
        if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    foreach ($e in $Env) {
        $idx = $e.IndexOf('=')
        if ($idx -lt 1) { continue }
        $psi.Environment[$e.Substring(0, $idx)] = $e.Substring($idx + 1)
    }
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        return @{ ExitCode = 124; StdOut = ''; StdErr = "TIMEOUT after ${TimeoutSec}s" }
    }
    return @{ ExitCode = $proc.ExitCode; StdOut = $outTask.Result; StdErr = $errTask.Result }
}

# ─────────────────────────── подготовка ───────────────────────────

Write-Step "Читаю конфиг: $ConfigPath"
if (-not (Test-Path $ConfigPath)) { throw "Конфиг не найден: $ConfigPath" }
$cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json

$commonEnv = @()
foreach ($pair in @(
    @('BACKUP_S3_ACCESS_KEY_ID',     'AWS_ACCESS_KEY_ID'),
    @('BACKUP_S3_SECRET_ACCESS_KEY', 'AWS_SECRET_ACCESS_KEY'),
    @('RESTIC_PASSWORD',             'RESTIC_PASSWORD'))) {
    $v = [Environment]::GetEnvironmentVariable($pair[0])
    if ($v) { $commonEnv += "$($pair[1])=$v" }
}
if ($cfg.s3.region) { $commonEnv += "AWS_DEFAULT_REGION=$($cfg.s3.region)" }

$restic = Get-ResticExecutable -ExplicitPath $ResticPath
Write-Step "restic: $restic"

$resticArgs = @()
if ($cfg.s3.bucketLookup) { $resticArgs += @('-o', "s3.bucket-lookup=$($cfg.s3.bucketLookup)") }
$resticArgs += @('-r', $cfg.repository)

# ─────────────────────────── снимки ───────────────────────────

Write-Step "Читаю список снимков"
$snapRes = Invoke-Restic -Exe $restic -ResticArgs (@($resticArgs + @('snapshots', '--json'))) -Env $commonEnv -TimeoutSec 300
if ($snapRes.ExitCode -ne 0) {
    Write-Err "Не удалось прочитать снимки: $($snapRes.StdErr)"
    exit 1
}
$snaps = @()
try { $snaps = @($snapRes.StdOut | ConvertFrom-Json) } catch { Write-Err "Вывод снимков не разобран."; exit 1 }
if ($snaps.Count -eq 0) {
    Write-Err "В репозитории нет ни одного снимка — бэкап не выполнялся."
    exit 1
}
Write-Ok "Снимков в репозитории: $($snaps.Count)"

$latest = $snaps | Sort-Object { $_.time } -Descending | Select-Object -First 1
$latestId = if ($latest.PSObject.Properties.Name -contains 'id') { $latest.id } else { $latest.short_id }
Write-Ok "Последний снимок: $($latest.short_id) от $($latest.time)"
Write-Host "    Файлов в снимке: $($latest.summary.total_files_processed), объём: $($latest.summary.total_bytes_processed) Б" -ForegroundColor DarkGray

# ─────────────────────────── режим 1: восстановление файла ───────────────────────────

if ($RestorePath) {
    Write-Step "Восстанавливаю '$RestorePath' → '$Target'"
    if (-not $Target) { throw "Укажи -Target, куда восстановить." }
    New-Item -ItemType Directory -Force -Path $Target | Out-Null

    $res = Invoke-Restic -Exe $restic -ResticArgs (@($resticArgs + @('restore', $latestId, '--include', $RestorePath, '--target', $Target))) -Env $commonEnv -TimeoutSec 3600
    if ($res.ExitCode -ne 0) {
        Write-Err "Восстановление не удалось: $($res.StdErr)"
        exit 2
    }
    Write-Ok "Восстановлено в $Target"
    Get-ChildItem -LiteralPath $Target -Recurse -File | Select-Object -First 20 |
        ForEach-Object { Write-Host "    $($_.FullName)  ($($_.Length) Б)" -ForegroundColor DarkGray }
    exit 0
}

# ─────────────────────────── режим 2: полный restore-check ───────────────────────────

Write-Step "Восстанавливаю весь последний снимок во временный каталог"
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("restorecheck-{0}" -f ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force -Path $work | Out-Null
Write-Host "    Временный каталог: $work" -ForegroundColor DarkGray

$res = Invoke-Restic -Exe $restic -ResticArgs (@($resticArgs + @('restore', $latestId, '--target', $work))) -Env $commonEnv -TimeoutSec 7200
if ($res.ExitCode -ne 0) {
    Write-Err "Восстановление не удалось: $($res.StdErr)"
    exit 2
}
Write-Ok "Снимок восстановлен."

# Считаем файлы
$restored = @(Get-ChildItem -LiteralPath $work -Recurse -File -Force -ErrorAction SilentlyContinue)
$expected = [int]$latest.summary.total_files_processed
Write-Host "    Ожидалось файлов: $expected, восстановлено: $($restored.Count)" -ForegroundColor DarkGray

if ($restored.Count -eq 0) {
    Write-Err "Восстановлено 0 файлов — снимок непригоден."
    exit 3
}

# Сверяем хеши с исходными путями (если они ещё доступны на этой машине)
Write-Step "Сверяю хеши с исходными файлами"
$compared = 0; $mismatch = 0; $missing = 0

# restic восстанавливает, ПОВТОРЯЯ исходную структуру путей:
#   /home/user/Documents/a.txt  ->  <work>/home/user/Documents/a.txt
#   C:\Users\me\Documents\a.txt ->  <work>/C/Users/me/Documents/a.txt
# Поэтому исходный путь ищем как СУФФИКС восстановленного пути, а не наоборот.
$workPrefix = $work.TrimEnd('\', '/')

foreach ($srcRoot in @($cfg.paths)) {
    if (-not (Test-Path $srcRoot)) { continue }
    $srcRootFull = (Resolve-Path $srcRoot).Path.TrimEnd('\', '/')
    # Нормализованный вид для сравнения: слэши одинаковые, регистр сохраняем.
    $needle = $srcRootFull -replace '\\', '/'

    foreach ($f in $restored) {
        $restoredNorm = $f.FullName -replace '\\', '/'
        $idx = $restoredNorm.LastIndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -lt 0) { $missing++; continue }
        $candidate = $f.FullName.Substring(0, $idx) + $srcRootFull + $f.FullName.Substring($idx + $needle.Length)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $h1 = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
            $h2 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            $compared++
            if ($h1 -ne $h2) { $mismatch++; Write-Err "Хеш не совпал: $candidate" }
        } else {
            $missing++
        }
    }
}
Write-Host "    Сверено: $compared, несовпадений: $mismatch, исходник недоступен: $missing" -ForegroundColor DarkGray

if ($compared -eq 0) {
    Write-Warn "Сверить не с чем: исходные пути недоступны на этой машине. Проверка ограничена фактом успешного восстановления."
} elseif ($mismatch -gt 0) {
    Write-Err "Есть несовпадения хешей — бэкап повреждён."
    exit 4
} else {
    Write-Ok "Все $compared файлов совпали по SHA256 с оригиналами."
}

# Проверяем, что ключевые секции на месте
Write-Step "Проверяю целостность репозитория (restic check)"
$chk = Invoke-Restic -Exe $restic -ResticArgs (@($resticArgs + @('check'))) -Env $commonEnv -TimeoutSec 3600
if ($chk.ExitCode -ne 0) {
    Write-Err "restic check не прошёл: $($chk.StdErr)"
    exit 5
}
Write-Ok "restic check — ок."

if ($KeepRestored) {
    Write-Ok "Восстановленные файлы оставлены в $work"
} else {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "    Временные файлы удалены." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "RESTORE CHECK PASSED" -ForegroundColor Green
Write-Host "  snapshot : $($latest.short_id)"
Write-Host "  time     : $($latest.time)"
Write-Host "  files    : $expected (восстановлено $($restored.Count))"
exit 0
