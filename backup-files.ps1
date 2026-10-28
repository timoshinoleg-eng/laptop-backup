<#
.SYNOPSIS
    Ежедневный бэкап файлов ноутбука в S3-совместимое хранилище (Cloud.ru Object Storage).

.DESCRIPTION
    Инструмент — restic: дедупликация, шифрование на клиенте, инкрементальные снимки.
    Почему restic, а не robocopy/zip:
      - дедупликация: повторные бэкапы почти не съедают место (в 15 ГБ free-tier влезает годами);
      - шифрование: содержимое файлов никто не прочитает, даже имея доступ к бакету;
      - инкрементальность: ежедневный прогон занимает минуты, а не часы;
      - ВСТРОЕННАЯ проверка целостности (restic check) — бэкап, который нельзя прочитать,
        бесполезен, и мы проверяем это автоматически.

    Что делает скрипт:
      1. проверяет, что репозиторий доступен;
      2. копирует данные (с исключениями);
      3. проверяет целостность (restic check);
      4. применяет политику хранения (keep-daily/weekly/monthly) и prune — место не растёт;
      5. пишет heartbeat (если есть aws CLI) — по нему внешний сторож видит, что бэкап жив;
      6. при сбое шлёт алерт в Telegram.

    СЕКРЕТЫ НИКОГДА не хранятся в config.json. Они читаются из переменных окружения:
      BACKUP_S3_ACCESS_KEY_ID, BACKUP_S3_SECRET_ACCESS_KEY, RESTIC_PASSWORD,
      BACKUP_TELEGRAM_BOT_TOKEN.

.EXAMPLE
    pwsh -File backup-files.ps1 -ConfigPath .\config.json
    pwsh -File backup-files.ps1 -ConfigPath .\config.json -DryRun
    pwsh -File backup-files.ps1 -ConfigPath .\config.json -SkipPrune
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$ResticPath = '',
    [switch]$DryRun,
    [switch]$SkipPrune,
    [switch]$SkipCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ─────────────────────────── утилиты ───────────────────────────

function Write-Step { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "    [OK] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "    [!] $Message"  -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "    [X] $Message"  -ForegroundColor Red }

function Send-TelegramAlert {
    param([string]$Text, [string]$ChatId, [string]$BotToken)

    if (-not $ChatId -or -not $BotToken) {
        Write-Warn "Telegram-алерт не настроен (нет chatId или токена) — пропускаю."
        return
    }
    try {
        $uri = "https://api.telegram.org/bot$BotToken/sendMessage"
        $body = @{ chat_id = $ChatId; text = $Text }
        # -UseBasicParsing обязателен для Windows PowerShell 5.1
        Invoke-RestMethod -Method Post -Uri $uri -Body $body -UseBasicParsing -TimeoutSec 20 | Out-Null
        Write-Ok "Алерт отправлен в Telegram."
    } catch {
        Write-Warn "Не удалось отправить алерт: $($_.Exception.Message)"
    }
}

function Get-ResticExecutable {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (Test-Path $ExplicitPath) { return (Resolve-Path $ExplicitPath).Path }
        throw "restic не найден по указанному пути: $ExplicitPath"
    }
    $cmd = Get-Command restic -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $PSScriptRoot 'restic.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\restic\restic.exe'),
        (Join-Path $env:ProgramFiles 'restic\restic.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path }
    }
    throw "restic не найден. Скачай restic.exe (https://github.com/restic/restic/releases) и положи рядом со скриптом."
}

function Invoke-Restic {
    <#
      Запускает restic и возвращает @{ ExitCode; StdOut; StdErr }.
      Никогда не бросает — вызывающий сам решает, что делать с ненулевым кодом.
      stdout и stderr разведены: JSON-вывод restic нельзя смешивать с предупреждениями.
    #>
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
    # Асинхронное чтение обоих потоков — иначе рискуем встать на мёртвом pipe.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        return @{ ExitCode = 124; StdOut = ''; StdErr = "TIMEOUT after ${TimeoutSec}s" }
    }
    return @{
        ExitCode = $proc.ExitCode
        StdOut   = $outTask.Result
        StdErr   = $errTask.Result
    }
}

function Get-LastErrorLine {
    param([string]$Text)
    if (-not $Text) { return '' }
    $lines = @($Text -split "`r?`n" | Where-Object { $_ -match '\S' })
    if ($lines.Count -eq 0) { return '' }
    return $lines[-1].Trim()
}

# ─────────────────────────── конфиг ───────────────────────────

Write-Step "Читаю конфиг: $ConfigPath"
if (-not (Test-Path $ConfigPath)) { throw "Конфиг не найден: $ConfigPath" }
$cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json

$repo = $cfg.repository
if (-not $repo) { throw "В конфиге нет repository." }

# ─────────────────────────── окружение ───────────────────────────

$s3Access       = [Environment]::GetEnvironmentVariable('BACKUP_S3_ACCESS_KEY_ID')
$s3Secret       = [Environment]::GetEnvironmentVariable('BACKUP_S3_SECRET_ACCESS_KEY')
$resticPassword = [Environment]::GetEnvironmentVariable('RESTIC_PASSWORD')

$botTokenVar = $null
if ($cfg.telegram -and $cfg.telegram.botTokenEnvVar) { $botTokenVar = $cfg.telegram.botTokenEnvVar }
$botToken = if ($botTokenVar) { [Environment]::GetEnvironmentVariable($botTokenVar) } else { $null }

if ($s3Access -and $s3Secret) {
    Write-Ok "S3-ключи найдены в переменных окружения."
} else {
    Write-Warn "S3-ключи не заданы (BACKUP_S3_ACCESS_KEY_ID / BACKUP_S3_SECRET_ACCESS_KEY)."
}
if ($resticPassword) {
    Write-Ok "Пароль репозитория найден (RESTIC_PASSWORD)."
} else {
    Write-Warn "RESTIC_PASSWORD не задан — без него бэкап невозможен."
}

$commonEnv = @()
if ($s3Access)      { $commonEnv += "AWS_ACCESS_KEY_ID=$s3Access" }
if ($s3Secret)      { $commonEnv += "AWS_SECRET_ACCESS_KEY=$s3Secret" }
if ($resticPassword){ $commonEnv += "RESTIC_PASSWORD=$resticPassword" }
if ($cfg.s3.region) { $commonEnv += "AWS_DEFAULT_REGION=$($cfg.s3.region)" }

# ─────────────────────────── аргументы ───────────────────────────

$resticArgs = @()
if ($cfg.s3.bucketLookup) { $resticArgs += @('-o', "s3.bucket-lookup=$($cfg.s3.bucketLookup)") }
$resticArgs += @('-r', $repo)

$backupArgs = @($resticArgs + @('backup'))
foreach ($p in $cfg.paths) { $backupArgs += $p }
foreach ($e in $cfg.excludes) { $backupArgs += @('--exclude', $e) }
$backupArgs += @('--tag', 'laptop-daily')

$forgetArgs = @($resticArgs + @('forget',
    '--keep-daily',   "$($cfg.retention.keepDaily)",
    '--keep-weekly',  "$($cfg.retention.keepWeekly)",
    '--keep-monthly', "$($cfg.retention.keepMonthly)",
    '--tag', 'laptop-daily'))

$pruneArgs = @($resticArgs + @('prune'))
$checkArgs = @($resticArgs + @('check'))
$snapArgs  = @($resticArgs + @('snapshots', '--latest', '1', '--json'))

# ─────────────────────────── DryRun ───────────────────────────

if ($DryRun) {
    Write-Step "DRY RUN — ничего не выгружаю. Показываю, что будет выполнено:"
    Write-Host "  repository  : $repo"
    Write-Host "  paths       : $($cfg.paths -join ', ')"
    Write-Host "  excludes    : $($cfg.excludes.Count) правил"
    Write-Host "  retention   : daily=$($cfg.retention.keepDaily) weekly=$($cfg.retention.keepWeekly) monthly=$($cfg.retention.keepMonthly)"
    Write-Host "  bucketLookup: $($cfg.s3.bucketLookup)"
    Write-Host ""
    Write-Host "  restic $($backupArgs -join ' ')"
    Write-Host "  restic $($forgetArgs -join ' ')"
    exit 0
}

# ─────────────────────────── 1. доступ к репозиторию ───────────────────────────

$restic = Get-ResticExecutable -ExplicitPath $ResticPath
Write-Step "restic: $restic"

Write-Step "Проверяю доступ к репозиторию"
$snap = Invoke-Restic -Exe $restic -ResticArgs $snapArgs -Env $commonEnv -TimeoutSec 120
if ($snap.ExitCode -ne 0) {
    Write-Err "Репозиторий недоступен: $(Get-LastErrorLine $snap.StdErr)"
    Send-TelegramAlert -Text "🔴 Бэкап ноутбука НЕ РАБОТАЕТ: репозиторий недоступен.`n$(Get-LastErrorLine $snap.StdErr)" -ChatId $cfg.telegram.chatId -BotToken $botToken
    exit 1
}
Write-Ok "Репозиторий доступен."

# ─────────────────────────── 2. бэкап ───────────────────────────

Write-Step "Копирую данные в репозиторий"
$backup = Invoke-Restic -Exe $restic -ResticArgs $backupArgs -Env $commonEnv -TimeoutSec 7200
if ($backup.ExitCode -ne 0) {
    Write-Err "Бэкап не удался (exit $($backup.ExitCode))"
    if ($backup.StdErr) { Write-Host $backup.StdErr }
    Send-TelegramAlert -Text "🔴 Бэкап ноутбука ПРОВАЛИЛСЯ (exit $($backup.ExitCode)).`n$(Get-LastErrorLine $backup.StdErr)" -ChatId $cfg.telegram.chatId -BotToken $botToken
    exit 2
}
Write-Ok "Бэкап завершён."
($backup.StdOut -split "`r?`n" | Where-Object { $_ -match 'snapshot|saved|processed' } | Select-Object -Last 4) | ForEach-Object { Write-Host "    $_" }

# ─────────────────────────── 3. проверка целостности ───────────────────────────

if (-not $SkipCheck) {
    Write-Step "Проверяю целостность репозитория (restic check)"
    $chk = Invoke-Restic -Exe $restic -ResticArgs $checkArgs -Env $commonEnv -TimeoutSec 3600
    if ($chk.ExitCode -ne 0) {
        Write-Err "Проверка целостности не прошла."
        if ($chk.StdErr) { Write-Host $chk.StdErr }
        Send-TelegramAlert -Text "🔴 Бэкап ноутбука: проверка целостности репозитория не прошла." -ChatId $cfg.telegram.chatId -BotToken $botToken
        exit 3
    }
    Write-Ok "Целостность репозитория в порядке."
}

# ─────────────────────────── 4. политика хранения ───────────────────────────

Write-Step "Применяю политику хранения (forget)"
$forget = Invoke-Restic -Exe $restic -ResticArgs $forgetArgs -Env $commonEnv -TimeoutSec 900
if ($forget.ExitCode -ne 0) {
    Write-Warn "forget завершился с кодом $($forget.ExitCode) — старые снимки не удалены, место может закончиться."
    if ($forget.StdErr) { Write-Host $forget.StdErr }
} else {
    Write-Ok "Политика хранения применена."
}

if (-not $SkipPrune) {
    Write-Step "Освобождаю место (prune) — может занять несколько минут"
    $prune = Invoke-Restic -Exe $restic -ResticArgs $pruneArgs -Env $commonEnv -TimeoutSec 7200
    if ($prune.ExitCode -ne 0) {
        Write-Warn "prune завершился с кодом $($prune.ExitCode)."
        if ($prune.StdErr) { Write-Host $prune.StdErr }
    } else {
        Write-Ok "Место освобождено."
    }
}

# ─────────────────────────── 5. heartbeat ───────────────────────────

Write-Step "Публикую heartbeat"
$lastSnap = $null
try {
    $snapJson = $snap.StdOut | ConvertFrom-Json
    if ($snapJson -is [array]) { $lastSnap = $snapJson[0] } else { $lastSnap = $snapJson }
} catch {
    Write-Warn "Не удалось разобрать вывод snapshots: $($_.Exception.Message)"
}

try {
    $hb = [ordered]@{
        timestamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        host      = $env:COMPUTERNAME
        user      = $env:USERNAME
        ok        = $true
        paths     = @($cfg.paths)
    }
    if ($lastSnap) {
        $hb['snapshot'] = if ($lastSnap.PSObject.Properties.Name -contains 'short_id') { $lastSnap.short_id } else { $lastSnap.id }
        $hb['time']     = $lastSnap.time
    }
    $hbJson = $hb | ConvertTo-Json -Depth 4

    $hbFile = Join-Path ([System.IO.Path]::GetTempPath()) ("hb-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    Set-Content -LiteralPath $hbFile -Value $hbJson -Encoding UTF8

    # restic не умеет произвольный PUT — heartbeat грузим aws CLI.
    $aws = Get-Command aws -ErrorAction SilentlyContinue
    if ($aws) {
        $hbArgs = @('s3','cp', $hbFile, "s3://$($cfg.s3.bucket)/$($cfg.heartbeat.s3Key)",
                    '--endpoint-url', $cfg.s3.endpoint,
                    '--region', $cfg.s3.region,
                    '--no-progress')
        $hbRes = Invoke-Restic -Exe $aws.Source -ResticArgs $hbArgs -Env $commonEnv -TimeoutSec 300
        if ($hbRes.ExitCode -eq 0) {
            Write-Ok "Heartbeat загружен (aws cli)."
        } else {
            Write-Warn "Heartbeat не загружен: $(Get-LastErrorLine $hbRes.StdErr)"
        }
    } else {
        Write-Warn "aws CLI не найден — heartbeat пропущен."
    }
    Remove-Item -LiteralPath $hbFile -Force -ErrorAction SilentlyContinue
} catch {
    Write-Warn "Heartbeat не сформирован: $($_.Exception.Message)"
}

# ─────────────────────────── 6. итог ───────────────────────────

Write-Step "Готово."
Write-Ok "Бэкап ноутбука выполнен успешно."
exit 0
