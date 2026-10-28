# Бэкап файлов ноутбука (Windows) — restic + Cloud.ru Object Storage

Ежедневный бэкап файлов Windows-ноутбука в S3-совместимое хранилище Cloud.ru
(бесплатный free-tier: 15 ГБ). Инструмент — **restic**: дедупликация,
шифрование на клиенте, инкрементальные снимки, встроенная проверка целостности.

## Почему restic, а не robocopy/zip

| | restic | robocopy + zip |
|---|---|---|
| Повторные копии | не дублируются (дедупликация) | съедают место целиком |
| Шифрование | на клиенте, ключ не в бакете | нет |
| Инкрементальность | секунды | пересобирает всё |
| Проверка целостности | `restic check` | нет |
| История версий | снимки с политикой хранения | нет |

## Быстрый старт

### 1. Скачать restic

<https://github.com/restic/restic/releases> → `restic_*_windows_amd64.zip` →
`restic.exe` положить **рядом со скриптами** (в эту папку).

### 2. Скачать эти скрипты

```powershell
git clone https://github.com/timoshinoleg-eng/laptop-backup.git
cd laptop-backup
```

### 3. Править `config.json`

Обязательно заменить `paths` на свои:

```json
"paths": [
  "C:\\Users\\ТВОЁ_ПРОФИЛЬ\\Documents",
  "C:\\Users\\ТВОЁ_ПРОФИЛЬ\\Desktop",
  "C:\\Users\\ТВОЁ_ПРОФИЛЬ\\Downloads"
]
```

### 4. Задать секреты (в переменных окружения, НЕ в конфиге)

```powershell
# Ключи Cloud.ru Object Storage: в личном кабинете → Object Storage → API.
# Access Key ID пишется в формате <tenant_id>:<key_id>.
[Environment]::SetEnvironmentVariable('BACKUP_S3_ACCESS_KEY_ID',     '<tenant_id>:<key_id>', 'User')
[Environment]::SetEnvironmentVariable('BACKUP_S3_SECRET_ACCESS_KEY', '<secret_key>',        'User')

# Пароль репозитория restic. ПОТЕРЯ ПАРОЛЯ = ПОТЕРЯ ДАННЫХ НАВСЕГДА.
$pw = Read-Host 'Пароль репозитория' -AsSecureString
$plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
[Environment]::SetEnvironmentVariable('RESTIC_PASSWORD', $plain, 'User')
Remove-Variable plain, pw
```

> **Пароль репозитория сохрани в менеджере паролей.** Он не восстанавливается.

### 5. Инициализировать репозиторий (один раз)

```powershell
.\restic.exe -r s3:https://s3.cloud.ru/backups/laptop init
```

### 6. Проверить, что всё работает

```powershell
pwsh -File backup-files.ps1 -ConfigPath .\config.json -DryRun   # что будет сделано
pwsh -File backup-files.ps1 -ConfigPath .\config.json           # реальный прогон
pwsh -File restore-check.ps1 -ConfigPath .\config.json          # проверка восстановления
```

### 7. Установить ежедневную задачу

```powershell
pwsh -File install-task.ps1 -Time 02:00 -RunNow
```

Готово. Дальше задача сама отрабатывает ежедневно.

## Почему это не повторит судьбу `OFELIYA-S3-DailyBackup`

Старая задача на ноуте работала **только при залогиненной сессии Windows** —
пропустил вход, бэкап молча не состоялся, и никто об этом не узнал.

Эта задача настроена иначе:

- **S4U** — запуск от имени пользователя **без сохранения пароля**, работает и без
  активной сессии (машина залогинена в фоне, сессия заблокирована — неважно);
- **StartWhenAvailable** — пропущенный запуск догоняется при следующем старте
  машины, а не теряется;
- **RestartCount 3 / RestartInterval 15 мин** — при сбое (закрыт Wi-Fi, спит
  ноут) задача перезапустится сама;
- **MultipleInstances IgnoreNew** — два прогона одновременно не стартуют;
- **ExecutionTimeLimit 6 ч** — зависший прогон не будет висеть вечно;
- **Алерт в Telegram** при сбое + **heartbeat** в бакете, по которому внешний
  сторож видит, что бэкап жив.

## Политика хранения

По умолчанию: 14 ежедневных + 8 недельных + 6 месячных снимков, старые
удаляются (`forget` + `prune`). Место не растёт бесконечно.

## Проверка восстановления

```powershell
# Полная проверка: снимок восстанавливается, хеши сверяются с оригиналами
pwsh -File restore-check.ps1 -ConfigPath .\config.json

# Вытащить конкретный файл (боевое восстановление)
pwsh -File restore-check.ps1 -ConfigPath .\config.json `
  -RestorePath 'C:\Users\me\Documents\важный.docx' -Target 'D:\Recovered'
```

`restore-check.ps1` — не формальность: он реально разворачивает снимок во
временный каталог, сверяет SHA256 каждого файла с оригиналом и прогоняет
`restic check`. Бэкап, который нельзя восстановить, бесполезен.

## Файлы

| Файл | Назначение |
|---|---|
| `backup-files.ps1` | основной прогон: backup → check → forget/prune → heartbeat → алерт |
| `install-task.ps1` | регистрация ежедневной задачи Windows (S4U, догон пропусков) |
| `restore-check.ps1` | проверка восстановления + восстановление отдельного файла |
| `config.json` | что копировать, куда, политика хранения, параметры алерта |

## Отладка

```powershell
Get-ScheduledTask -TaskName 'LaptopDailyBackup' | Select-Object State
Get-ScheduledTaskInfo -TaskName 'LaptopDailyBackup' |
  Select-Object LastRunTime, LastTaskResult, NextRunTime
```

`LastTaskResult`: `0` — успех, `267009` — задача ещё выполняется, другое — код ошибки.

Убрать задачу: `pwsh -File install-task.ps1 -Uninstall`
