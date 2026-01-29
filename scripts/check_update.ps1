# scripts/check_update.ps1
<#
.SYNOPSIS
    Проверяет и устанавливает обновления Ollama.
.DESCRIPTION
    Проверяет локальную версию, скачивает OllamaSetup.exe,
    останавливает службу, устанавливает, запускает, проверяет API.
.NOTES
    Требует curl.exe и права администратора для установки.
#>

$ErrorActionPreference = "SilentlyContinue"

# --- Проверка прав администратора (в самом начале!) ---
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "[-] Для выполнения этого скрипта требуется запуск от имени АДМИНИСТРАТОРА"
    Write-Host "Запустите PowerShell как администратор и повторите попытку."
    exit 1
}

$curlPath = Join-Path $PSScriptRoot "..\bin\curl.exe"
$downloadDir = Join-Path $PSScriptRoot "..\downloads"
$nssmPath = Join-Path $PSScriptRoot "..\bin\nssm.exe"
$serviceName = "OllamaService"

New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

if (-not (Test-Path $curlPath)) {
    Write-Error "[-] Не найден curl.exe: $curlPath"
    Write-Host "Поместите curl.exe в папку bin"
    exit 1
}

# --- Определение пути к ollama.exe ---
$envPath = Join-Path $PSScriptRoot "..\config\.env"
$defaultOllama = "C:\Users\Павел\AppData\Local\Programs\Ollama\ollama.exe"

$ollamaExe = Get-Content $envPath -Raw | Select-String '\\ollama\.exe' | ForEach-Object { $_.Line.Trim() } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ollamaExe) { $ollamaExe = $defaultOllama }

# --- Проверка наличия ollama.exe ---
if (-not (Test-Path $ollamaExe)) {
    Write-Warning "[-] ollama.exe не найден: $ollamaExe"
    Write-Host "[*] Можно скачать и установить последнюю версию." -ForegroundColor Yellow
    $confirm = Read-Host "Скачать установщик? (y/N)"
    if ($confirm -inotmatch '^y$|^yes$') {
        Write-Host "[-] Выход." -ForegroundColor Yellow
        exit 0
    }
    goto DownloadOnly
} else {
    # --- Получение локальной версии ---
    try {
        $localVersion = & $ollamaExe --version 2>&1 | Out-String
        if ($localVersion -match '(\d+\.\d+\.\d+)') {
            $localVersion = $matches[1]
        } else {
            Write-Warning "Не удалось распознать версию: $localVersion"
            $localVersion = "unknown"
        }
    } catch {
        Write-Warning "Ошибка при получении версии: $_"
        $localVersion = "unknown"
    }

    Write-Host "`n[+] Локальная версия: $localVersion" -ForegroundColor Green
}

# --- Получение последней версии ---
Write-Host "[*] Проверка последней версии..." -ForegroundColor Cyan

$url = "https://api.github.com/repos/ollama/ollama/releases/latest"
$json = & $curlPath -s $url

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($json)) {
    Write-Error "[-] Не удалось получить данные с GitHub"
    exit 1
}

try {
    $release = $json | ConvertFrom-Json
} catch {
    Write-Error "[-] Не удалось разобрать JSON ответ"
    exit 1
}

$tagName = $release.tag_name.TrimStart('v')
$releaseUrl = $release.html_url

Write-Host "[+] Последняя версия: $tagName" -ForegroundColor Green

if ($localVersion -ne "unknown") {
    try {
        $localVer = [version]$localVersion.Split('-')[0]
        $remoteVer = [version]$tagName.Split('-')[0]
    } catch {
        Write-Error "[-] Ошибка разбора версии: $_"
        $remoteVer = $null
    }

    if ($remoteVer -gt $localVer) {
        Write-Host "`n[!] ДОСТУПНО ОБНОВЛЕНИЕ!" -ForegroundColor Red
        Write-Host "    $localVersion > $tagName" -ForegroundColor Yellow
    } elseif ($remoteVer -eq $localVer) {
        Write-Host "`n[+] Установлена актуальная версия." -ForegroundColor Green
        $confirm = Read-Host "`nВсё равно скачать и переустановить? (y/N)"
        if ($confirm -inotmatch '^y$|^yes$') {
            exit 0
        }
    } else {
        Write-Host "`n[?] Установлена более новая версия? $localVersion > $tagName" -ForegroundColor Yellow
        $confirm = Read-Host "`nВсё равно скачать и переустановить? (y/N)"
        if ($confirm -inotmatch '^y$|^yes$') {
            exit 0
        }
    }
}

:DownloadOnly
# --- Поиск установщика ---
Write-Host "`n[*] Поиск установщика для Windows..." -ForegroundColor Cyan

$asset = $release.assets | Where-Object { $_.name -match "(?i)^OllamaSetup\.exe$" } | Select-Object -First 1
if (-not $asset) {
    Write-Host "[*] OllamaSetup.exe не найден. Ищем альтернативу..." -ForegroundColor Yellow
    $asset = $release.assets | Where-Object {
        $_.name -match "(?i)^ollama.*windows.*amd64.*\.(zip|msi|exe)$" -and `
        $_.name -notmatch "(?i)rocm|cuda|metal|opencl"
    } | Select-Object -First 1
}

if (-not $asset) {
    Write-Warning "Не удалось найти установщик."
    Write-Host "Проверьте: $releaseUrl"
    exit 1
}

$downloadUrl = $asset.browser_download_url
$fileName = $asset.name
$targetPath = Join-Path $downloadDir $fileName

Write-Host "[+] Найден установщик:" -ForegroundColor Green
Write-Host "    $fileName"
Write-Host "    $downloadUrl"

$confirm = Read-Host "`nСкачать и установить? (y/N)"
if ($confirm -inotmatch '^y$|^yes$') {
    Write-Host "[-] Отменено." -ForegroundColor Yellow
    exit 0
}

# --- Скачивание ---
Write-Host "`n[*] Скачивание... Подождите" -ForegroundColor Cyan
& $curlPath -L -o "$targetPath" "$downloadUrl"
if ($LASTEXITCODE -ne 0) {
    Write-Error "[-] Ошибка скачивания"
    exit 1
}
Write-Host "[+] Скачано: $targetPath" -ForegroundColor Green

# --- Проверка существования службы OllamaService ---
$serviceName = "OllamaService"
$serviceExists = Get-Service $serviceName -ErrorAction SilentlyContinue

if ($serviceExists) {
    Write-Host "`n[*] Обнаружена служба: $serviceName" -ForegroundColor Cyan
    Write-Host "[*] Остановка перед установкой..." -ForegroundColor Cyan
    Stop-Service $serviceName -Force
    Start-Sleep -Seconds 3
} else {
    Write-Host "`n[!] Служба $serviceName не найдена." -ForegroundColor Yellow
    Write-Host "    Установка ollama произойдёт без управления службой." -ForegroundColor Gray
}

# --- Установка ---
Write-Host "[*] Запуск установки Ollama..." -ForegroundColor Cyan
Write-Host "[!] После установки закройте запущенное приложение Ollama и закройте приложение Ollama в трее! " -ForegroundColor Yellow
Write-Host "    Только после полного закрытия Ollama установщик продолжит работу!" -ForegroundColor Yellow
Start-Process -FilePath $targetPath -ArgumentList "/S" -Wait
Write-Host "[+] Установка Ollama завершена." -ForegroundColor Green

# --- Завершение ---
if ($serviceExists) {
    Write-Host "[*] Запуск службы $serviceName..." -ForegroundColor Cyan
    Start-Service $serviceName
    Start-Sleep -Seconds 5

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
    Write-Host "`n[*] Доступные модели:" -ForegroundColor Cyan
    $modelList = try { & $ollamaExe list 2>$null } catch { $null }
    if ($modelList) {
        $modelList | Select-Object -Skip 1 | ForEach-Object { Write-Host " • $_" }
    } else {
        Write-Host " • нет установленных моделей" -ForegroundColor Gray
    }
} else {
    # --- Нет службы > предложить install.ps1 ---
    Write-Host "`n[!] Служба $serviceName не была создана." -ForegroundColor Yellow
    Write-Host "    Для настройки Ollama как службы выполните:" -ForegroundColor Gray
    Write-Host ""
    Write-Host "    .\install.ps1" -ForegroundColor White -BackgroundColor DarkGray
    Write-Host ""
    Write-Host "    Это настроит:" -ForegroundColor Gray
    Write-Host "     • Службу Windows" -ForegroundColor Gray
    Write-Host "     • Переменные окружения" -ForegroundColor Gray
    Write-Host "     • Брандмауэр" -ForegroundColor Gray
    Write-Host "     • Автозагрузку и логирование" -ForegroundColor Gray
}

Write-Host "`n[+] Проверка обновления завершена." -ForegroundColor Green
