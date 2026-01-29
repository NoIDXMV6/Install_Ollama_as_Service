# scripts/install.ps1
<#
.SYNOPSIS
    Установка Ollama как службы с настройкой брандмауэра.

.DESCRIPTION
    Настраивает ollama.exe как службу через nssm.
    Создаёт переменные окружения.
    Добавляет правила в брандмауэр для порта 11434.

.NOTES
    Требует запуска от имени администратора.
#>

$ErrorActionPreference = "Stop"

# --- Проверка прав администратора ---
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "[-] Запустите PowerShell от имени АДМИНИСТРАТОРА"
    exit 1
}

$rootDir = Join-Path $PSScriptRoot ".."
$logDir = Join-Path $rootDir "logs"
$configDir = Join-Path $rootDir "config"
$nssmPath = Join-Path $PSScriptRoot "..\bin\nssm.exe"
$curlPath = Join-Path $PSScriptRoot "..\bin\curl.exe"

Write-Host "`n[+] Установка Ollama как службы" -ForegroundColor Green

# --- Создание папок ---
New-Item -ItemType Directory -Path $logDir, $configDir -Force | Out-Null

# --- Проверка зависимостей ---
foreach ($tool in @($nssmPath, $curlPath)) {
    if (-not (Test-Path $tool)) {
        Write-Error "[-] Не найден: $tool"
        Write-Warning "Поместите nssm.exe и curl.exe в папку bin"
        exit 1
    }
}

# --- Выбор путей ---
Write-Host "`n[*] Настройка путей" -ForegroundColor Cyan

$defaultOllama = "C:\Users\Павел\AppData\Local\Programs\Ollama\ollama.exe"
$customOllama = Read-Host "Путь к ollama.exe (Enter для $defaultOllama)"
$ollamaExe = if ($customOllama.Trim()) { $customOllama.Trim() } else { $defaultOllama }

if (-not (Test-Path $ollamaExe)) {
    Write-Error "[-] Файл не найден: $ollamaExe"
    exit 1
}
Write-Host "[+] Используется: $ollamaExe"

$defaultModels = "E:\Ollama\models"
$customModels = Read-Host "Путь к моделям (Enter для $defaultModels)"
$modelDir = if ($customModels.Trim()) { $customModels.Trim() } else { $defaultModels }

New-Item -ItemType Directory -Path $modelDir -Force | Out-Null
Write-Host "[+] Модели: $modelDir"

$tmpDir = Join-Path $modelDir "tmp"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
Write-Host "[+] Временная папка: $tmpDir"

# --- Сохранение в .env ---
$envPath = Join-Path $configDir ".env"
$envContent = @"
OLLAMA_MODELS=$modelDir
OLLAMA_TMPDIR=$tmpDir
"@
Set-Content -Path $envPath -Value $envContent -Encoding UTF8
Write-Host "[+] Переменные сохранены: $envPath"

# --- Удаление старой службы ---
$serviceName = "OllamaService"
if (Get-Service $serviceName -ErrorAction SilentlyContinue) {
    Write-Host "[*] Остановка и удаление старой службы..."
    & $nssmPath stop $serviceName
    & $nssmPath remove $serviceName confirm
}

# --- Установка службы ---
Write-Host "`n[*] Настройка службы через nssm..." -ForegroundColor Cyan

& $nssmPath install $serviceName "$ollamaExe"
& $nssmPath set $serviceName AppParameters serve
& $nssmPath set $serviceName AppDirectory (Split-Path $ollamaExe)
& $nssmPath set $serviceName ObjectName LocalSystem
& $nssmPath set $serviceName Start SERVICE_AUTO_START
& $nssmPath set $serviceName AppStdout "$logDir\ollama.log"
& $nssmPath set $serviceName AppStdoutCreationDisposition 2
& $nssmPath set $serviceName AppStderr "$logDir\error.log"
& $nssmPath set $serviceName AppStderrCreationDisposition 2
& $nssmPath set $serviceName AppRotateFiles 1
& $nssmPath set $serviceName AppRotateBytes 4000000
& $nssmPath set $serviceName AppTimestampLog 1
& $nssmPath set $serviceName AppEnvironmentExtra "OLLAMA_MODELS=$modelDir" "OLLAMA_TMPDIR=$tmpDir"
& $nssmPath start $serviceName

Start-Sleep -Seconds 3

# --- Добавление правил в брандмауэр ---
Write-Host "`n[*] Настройка брандмауэра Windows..." -ForegroundColor Cyan

$port = 11434
$ruleNameTcp = "Ollama API (TCP-In-Out)"
$ruleNameApp = "Ollama (ollama.exe)"

# Удалить старые правила
Remove-NetFirewallRule -DisplayName $ruleNameTcp -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName $ruleNameApp -ErrorAction SilentlyContinue

# Правило для порта TCP
New-NetFirewallRule -DisplayName $ruleNameTcp -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName $ruleNameTcp -Direction Outbound -Protocol TCP -LocalPort $port -Action Allow -Profile Any | Out-Null

# Правило для исполняемого файла
New-NetFirewallRule -DisplayName $ruleNameApp -Direction Inbound -Program "$ollamaExe" -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName $ruleNameApp -Direction Outbound -Program "$ollamaExe" -Action Allow -Profile Any | Out-Null

Write-Host "[+] Правила брандмауэра добавлены для порта $port и ollama.exe" -ForegroundColor Green

# --- Проверка API ---
Write-Host "`n[*] Проверка API..." -ForegroundColor Cyan
try {
    $version = & $curlPath -s http://localhost:11434/api/version
    if ($version) {
        Write-Host "[+] API доступен: $version" -ForegroundColor Green
    }
} catch {
    Write-Warning "API недоступен: $_"
}

# --- Список моделей ---
Write-Host "`n[*] Установленные модели:" -ForegroundColor Cyan
try {
    $list = & $ollamaExe list 2>$null
    $models = $list | Select-Object -Skip 1
    if ($models) {
        $models | ForEach-Object { Write-Host " • $_" }
    } else {
        Write-Host " • нет установленных моделей" -ForegroundColor Gray
    }
} catch {
    Write-Warning "Не удалось получить список моделей"
}

# --- Информация о подключении ---
$hostname = $env:COMPUTERNAME
if (-not $hostname) { $hostname = try { [System.Net.Dns]::GetHostName() } catch { "localhost" } }

$ip = $null
try {
    $ip = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter "IPEnabled=true" |
          Select-Object -ExpandProperty IPAddress |
          Where-Object { $_ -like "*.*.*.*" -and $_ -notlike "127.*" } |
          Select-Object -First 1
} catch {}

if (-not $ip) {
    try {
        $addr = [System.Net.Dns]::GetHostEntry([System.Net.Dns]::GetHostName()).AddressList
        $ip = $addr | Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notlike "127.*" } |
              Select-Object -First 1 | ForEach-Object { $_.ToString() }
    } catch {}
}

# --- Финальное сообщение ---
Write-Host "`n[+] Установка завершена!" -ForegroundColor Green
Write-Host "    Локальный доступ: http://localhost:11434"
if ($hostname) { Write-Host "    По имени: http://${hostname}:11434" }
if ($ip)       { Write-Host "    По IP: http://${ip}:11434" }
Write-Host "    Папка моделей: $modelDir"
Write-Host "    Логи: $logDir\ollama.log"
Write-Host "    Служба: $serviceName"
Write-Host "    Для обновления моделей используйте update_models.ps1" -ForegroundColor Yellow
Write-Host "    Брандмауэр настроен — доступ из локальной сети разрешён." -ForegroundColor Gray
