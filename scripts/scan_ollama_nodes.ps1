# scripts/scan_ollama_nodes.ps1
<#
.SYNOPSIS
    Сканирует Ollama-узлы, использует домены в балансировщике.
.DESCRIPTION
    - Ввод: IP, домены, CIDR
    - Проверяет доступность по IP
    - Только для активных узлов запрашивает домен (reverse-DNS)
    - Генерирует --server "http://domain:port=alias"
.NOTES
    Сохраняет результат в config/ollama_hosts.json
#>

$ErrorActionPreference = "Stop"

$Port = 11434
$TimeoutMs = 1000
$ConfigPath = Join-Path $PSScriptRoot "..\config\ollama_hosts.json"
$ScriptDir = Split-Path $MyInvocation.MyCommand.Path

# --- Функция: получение IP из CIDR ---
function Get-IPRangeFromCIDR {
    param([string]$CIDR)

    $CIDR = $CIDR.Trim()
    if ($CIDR -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$') {
        throw "Формат: x.x.x.x/y (напр., 10.0.55.0/24)"
    }

    $Octets = $matches[1..4] | ForEach-Object { [int]$_ }
    $Prefix = [int]$matches[5]

    foreach ($o in $Octets) { if ($o -lt 0 -or $o -gt 255) { throw "Ошибка в IP" } }
    if ($Prefix -lt 8 -or $Prefix -gt 30) { throw "Маска: /8 – /30" }

    $BaseIP = [System.Net.IPAddress]::Parse("$($Octets[0]).$($Octets[1]).$($Octets[2]).$($Octets[3])")
    $BaseBytes = $BaseIP.GetAddressBytes()
    [Array]::Reverse($BaseBytes)
    $BaseInt = [BitConverter]::ToUInt32($BaseBytes, 0)

    $Mask = [Convert]::ToUInt32(("1" * $Prefix + "0" * (32 - $Prefix)), 2)
    $NetworkInt = $BaseInt -band $Mask

    $HostBits = 32 - $Prefix
    $TotalHosts = [Math]::Pow(2, $HostBits) - 2

    if ($TotalHosts -le 0) { throw "Слишком маленькая подсеть" }

    $FirstHost = $NetworkInt + 1
    $LastHost = $NetworkInt + $TotalHosts

    $IPList = @()
    for ($i = $FirstHost; $i -le $LastHost; $i++) {
        $Bytes = [BitConverter]::GetBytes([uint32]$i)
        [Array]::Reverse($Bytes)
        $IPList += "$($Bytes[0]).$($Bytes[1]).$($Bytes[2]).$($Bytes[3])"
    }

    return $IPList
}

# --- Функция: разбор ввода ---
function Get-HostsFromInput {
    param([string]$InputString)

    $AllHosts = @()

    $Items = $InputString -split ',' | ForEach-Object { $_.Trim() }

    foreach ($item in $Items) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }

        if ($item -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
            Write-Host "[*] Обработка подсети: $item" -ForegroundColor Cyan
            $AllHosts += Get-IPRangeFromCIDR $item
        }
        elseif ($item -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            $AllHosts += $item
        }
        elseif ($item -match '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') {
            $AllHosts += $item
        }
        else {
            Write-Warning "Пропущено: $item"
        }
    }

    return $AllHosts | Sort-Object -Unique
}

# --- Загрузка сохранённых хостов ---
$SavedHosts = @()
if (Test-Path $ConfigPath) {
    try {
        $SavedHosts = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        Write-Host "`n[+] Найден сохранённый список узлов: $($SavedHosts.Count) шт." -ForegroundColor Green
        $UseSaved = Read-Host "Использовать сохранённые узлы? (y/N)"
        if ($UseSaved -match '^y$|^yes$') {
            $OllamaNodes = $SavedHosts
            Write-Host "[*] Используем сохранённые данные..." -ForegroundColor Yellow
            # Переходим к генерации — просто продолжаем выполнение
        } else {
            # Перейдём к сканированию
        }
    } catch {
        Write-Warning "Не удалось загрузить конфиг: $_"
    }
}

# Если узлы ещё не загружены — сканируем
if (-not (Get-Variable -Name OllamaNodes -ErrorAction SilentlyContinue)) {

    # --- Ввод ---
    Write-Host "`n[*] Введите хосты для сканирования" -ForegroundColor Yellow
    Write-Host "  • IP: 10.0.55.254" -ForegroundColor Gray
    Write-Host "  • Домены: ollama-pc.vniigochs.ru" -ForegroundColor Gray
    Write-Host "  • Сети: 10.0.55.0/24, 192.168.0.0/16" -ForegroundColor Gray
    Write-Host "  • Список: 10.0.55.254, host.domain.ru" -ForegroundColor Gray

    $HostInput = Read-Host "Хосты (через запятую)"

    if ([string]::IsNullOrWhiteSpace($HostInput)) {
        Write-Warning "Не указаны хосты"
        exit 1
    }

    try {
        $HostList = Get-HostsFromInput $HostInput
        if ($HostList.Count -eq 0) {
            Write-Error "Нет хостов для проверки"
            exit 1
        }
        Write-Host "[*] Готово: $($HostList.Count) хостов для проверки" -ForegroundColor Green
    } catch {
        Write-Error "[-] Ошибка: $_"
        exit 1
    }

    # --- Сканирование ---
    $OllamaNodes = @()
    $Total = $HostList.Count
    $Count = 0

    Write-Host "`n[*] Начинаем сканирование... (Ctrl+C)" -ForegroundColor Yellow

    foreach ($Node in $HostList) {
        $Count++
        $HostStr = $Node.ToString().Trim()

        Write-Host -NoNewline "`r[*] Проверка: $HostStr ($Count/$Total)     "

        # По умолчанию: хост = введённое значение
        $FinalHost = $HostStr
        $Alias = $null

        try {
            $Socket = New-Object Net.Sockets.TcpClient
            $Connect = $Socket.BeginConnect($HostStr, $Port, $null, $null)
            $Success = $Connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

            if ($Success) {
                $VersionUrl = "http://$HostStr`:$Port/api/version"
                $Version = Invoke-RestMethod -Uri $VersionUrl -TimeoutSec 5 -ErrorAction Stop

                $ModelsUrl = "http://$HostStr`:$Port/api/tags"
                $Response = Invoke-RestMethod -Uri $ModelsUrl -TimeoutSec 10 -ErrorAction Stop
                $Models = $Response.models.name

                # Только для активного узла запрашиваем домен
                if ($HostStr -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
                    try {
                        $HostEntry = [System.Net.Dns]::GetHostEntry($HostStr)
                        $FinalHost = $HostEntry.HostName  # например, 4nic-404.vniigochs.ru
                        $Alias = ($FinalHost -split '\.', 2)[0]  # часть до первого '.'
                    } catch {
                        $FinalHost = $HostStr
                        $Alias = "node-$((Get-Random)%1000)"
                    }
                } else {
                    # Уже домен
                    $FinalHost = $HostStr
                    $Alias = ($HostStr -split '\.', 2)[0]
                }

                $OllamaNodes += [PSCustomObject]@{
                    Host   = $FinalHost
                    Alias  = $Alias
                    Models = $Models
                }
                Write-Host " [OK]" -ForegroundColor Green -NoNewline
            }
        } catch {
            # Не Ollama
        } finally {
            if (Get-Variable -Name Socket -ValueOnly -ErrorAction SilentlyContinue) {
                $Socket.Close()
                Remove-Variable Socket -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host "`n`n[+] Сканирование завершено." -ForegroundColor Green

    if ($OllamaNodes.Count -eq 0) {
        Write-Warning "Не найдено ни одного Ollama-узла."
        exit 0
    }

    # --- Сохранение ---
    try {
        $ParentDir = Split-Path $ConfigPath
        if (!(Test-Path $ParentDir)) { New-Item -ItemType Directory -Path $ParentDir -Force | Out-Null }
        $OllamaNodes | ConvertTo-Json -Depth 3 | Set-Content $ConfigPath -Encoding UTF8
        Write-Host "[*] Сохранено: $ConfigPath" -ForegroundColor Green
    } catch {
        Write-Warning "Не удалось сохранить: $_"
    }
}

# --- Анализ моделей ---
$AllModels = ($OllamaNodes.Models | Sort-Object -Unique) -as [string[]]

Write-Host "`n[+] Найдено узлов: $($OllamaNodes.Count)" -ForegroundColor Green

Write-Host "`n[*] Общие модели:" -ForegroundColor Yellow
$AllModels | ForEach-Object { Write-Host "  • $_" }

# --- Отчёт по недостающим ---
$MissingReport = @()
foreach ($node in $OllamaNodes) {
    $missing = $AllModels | Where-Object { $_ -notin $node.Models }
    if ($missing) {
        $MissingReport += [PSCustomObject]@{
            Node    = "$($node.Alias) ($($node.Host))"
            Missing = $missing
        }
    }
}

if ($MissingReport.Count -gt 0) {
    Write-Host "`n[!] Требуется установка:" -ForegroundColor Red
    foreach ($item in $MissingReport) {
        Write-Host "  • Узел: $($item.Node)" -ForegroundColor Yellow
        $item.Missing | ForEach-Object { Write-Host "    - ollama run $_" }
    }
} else {
    Write-Host "`n[+] Все модели установлены." -ForegroundColor Green
}

# --- Генерация load_balancer.bat ---
$BatPath = Join-Path $ScriptDir "..\load_balancer\load_balancer.bat"
$ServerArgs = ($OllamaNodes | ForEach-Object { "--server `"http://$($_.Host):$Port=$($_.Alias)`"" }) -join " "

Set-Content -Path $BatPath -Value @"
@echo off
REM =============================================
REM    Ollama Load Balancer (автосгенерировано)
REM    Узлов: $($OllamaNodes.Count)
REM    Моделей: $($AllModels.Count)
REM =============================================

echo.
echo [+] Запуск Ollama Load Balancer...
echo.
echo [!] Серверы:
"@

$OllamaNodes | ForEach-Object {
    Add-Content -Path $BatPath -Value "echo     $($_.Alias) - $($_.Host)"
}

Add-Content -Path $BatPath -Value @"
echo.
echo [!] Нажмите Ctrl+C для остановки.
echo.

%~dp0ollama_load_balancer.exe $ServerArgs --timeout 30
"@

Write-Host "`n[+] Файл создан:" -ForegroundColor Green
Write-Host "    $BatPath"
