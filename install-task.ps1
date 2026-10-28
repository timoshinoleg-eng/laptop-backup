<#
.SYNOPSIS
    Ставит ежедневную задачу Windows на бэкап файлов ноутбука.

.DESCRIPTION
    Ключевое отличие от задачи OFELIYA-S3-DailyBackup, из-за которой бэкап может
    молча пропускаться: эта задача запускается **независимо от того, залогинен ли
    пользователь** (S4U), и пропущенный запуск догоняется при следующем старте
    (StartWhenAvailable). То есть выключил ноут на выходные — бэкап всё равно
    выполнится, как только машина проснётся.

    Почему S4U, а не просто "при входе пользователя":
      - задача "при логоне" молчит, если пользователь не входит в систему;
      - S4U даёт запуск от имени пользователя без хранения его пароля, машина
        заблокирована/спит — задача всё равно отработает.

.EXAMPLE
    pwsh -File install-task.ps1
    pwsh -File install-task.ps1 -Time "03:30" -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Time = '02:00',
    [string]$TaskName = 'LaptopDailyBackup',
    [string]$ScriptDir = $PSScriptRoot,
    [switch]$Uninstall,
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Ok  { param([string]$M) Write-Host "  [OK] $M" -ForegroundColor Green }
function Write-Warn{ param([string]$M) Write-Host "  [!] $M"  -ForegroundColor Yellow }
function Write-Err { param([string]$M) Write-Host "  [X] $M"  -ForegroundColor Red }

if (-not $Uninstall) {
    Write-Host "Установка задачи '$TaskName' (ежедневно в $Time)" -ForegroundColor Cyan
}

# ─────────────────────────── удаление ───────────────────────────

if ($Uninstall) {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Ok "Задача '$TaskName' удалена."
    } else {
        Write-Warn "Задача '$TaskName' не найдена — ничего не делаю."
    }
    exit 0
}

# ─────────────────────────── проверки ───────────────────────────

$backupScript = Join-Path $ScriptDir 'backup-files.ps1'
if (-not (Test-Path $backupScript)) { throw "Не найден backup-files.ps1 рядом с установщиком: $backupScript" }

$restic = Get-Command restic -ErrorAction SilentlyContinue
$resticLocal = Join-Path $ScriptDir 'restic.exe'
if (-not $restic -and -not (Test-Path $resticLocal)) {
    throw "restic не найден. Скачай restic.exe и положи его рядом со скриптом: https://github.com/restic/restic/releases"
}
Write-Ok "restic найден."

$configPath = Join-Path $ScriptDir 'config.json'
if (-not (Test-Path $configPath)) { throw "Не найден config.json рядом с установщиком." }
Write-Ok "config.json найден."

# Разбор времени: HH:mm
try {
    $parts = $Time -split ':'
    $hour = [int]$parts[0]; $minute = [int]$parts[1]
    if ($hour -lt 0 -or $hour -gt 23 -or $minute -lt 0 -or $minute -gt 59) { throw "время вне диапазона" }
} catch {
    throw "Некорректное время '$Time'. Ожидается HH:mm (например, 02:00)."
}

# ─────────────────────────── задача ───────────────────────────

$pwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue)
if ($pwshExe) {
    $exe = $pwshExe.Source
    Write-Ok "Используется pwsh: $exe"
} else {
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (-not (Test-Path $exe)) { throw "Не найден ни pwsh, ни Windows PowerShell." }
    Write-Warn "Используется Windows PowerShell 5.1: $exe"
}

$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$backupScript`" -ConfigPath `"$configPath`""

$action = New-ScheduledTaskAction -Execute $exe -Argument $arguments

# Ежедневный триггер + догон пропущенных запусков.
$trigger = New-ScheduledTaskTrigger -Daily -At $Time
$triggerSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours 6) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 15)

# S4U: запуск от имени пользователя без сохранения пароля, работает и без активной сессии.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Warn "Задача '$TaskName' уже существовала — переустанавливаю."
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $triggerSettings -Principal $principal -Description 'Ежедневный бэкап файлов ноутбука в Cloud.ru Object Storage (restic).' | Out-Null
Write-Ok "Задача '$TaskName' зарегистрирована (ежедневно в $Time, S4U, догон пропусков)."

# ─────────────────────────── проверка запуска ───────────────────────────

$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ""
Write-Host "Проверка:" -ForegroundColor Cyan
Write-Host "  LastRunTime : $($info.LastRunTime)"
Write-Host "  LastResult  : $($info.LastTaskResult)   (0 = успех)"
Write-Host "  NextRunTime : $($info.NextRunTime)"
Write-Host "  State       : $((Get-ScheduledTask -TaskName $TaskName).State)"
Write-Host ""

if ($RunNow) {
    Write-Host "Запускаю задачу вручную (RunNow)..." -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 20
    $info2 = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host "  После запуска: LastRunTime=$($info2.LastRunTime) LastResult=$($info2.LastTaskResult)" -ForegroundColor Cyan
    Write-Host "  (Проверь лог: $ScriptDir\backup.log)" -ForegroundColor Cyan
} else {
    Write-Host "Запустить проверку сразу:  pwsh -File install-task.ps1 -RunNow" -ForegroundColor DarkGray
}
