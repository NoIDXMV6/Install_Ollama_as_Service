# scripts/update_models.ps1
<#
.SYNOPSIS
    Обновляет модели Ollama.

.DESCRIPTION
    Скрипт показывает установленные модели, позволяет выбрать,
    удалить и перезагрузить их. Учитывает отсутствие save/load в Windows.
    Выводит прогресс загрузки в реальном времени.

.NOTES
    Требует ollama.exe и .env с путями.
#>

$logFile = Join-Path $PSScriptRoot "..\logs\model_update_$(Get-Date -Format 'yyyy-MM-dd').log"
Start-Transcript -Path $logFile -Append

$envPath = Join-Path $PSScriptRoot "..\config\.env"

# --- Проверка .env ---
if (-not (Test-Path $envPath)) {
    Write-Error "[-] Не найден .env: $envPath"
    Write-Error "Запустите install.ps1 для настройки."
    Stop-Transcript; exit 1
}

$content = Get-Content $envPath -Raw -Encoding UTF8
if ($content -match 'OLLAMA_MODELS=(.+?)(\r?\n|$)') {
    $modelDir = $matches[1].Trim()
} else {
    Write-Error "[-] Переменная OLLAMA_MODELS не найдена в .env"
    Stop-Transcript; exit 1
}

if (-not (Test-Path $modelDir)) {
    Write-Error "[-] Папка с моделями не существует: $modelDir"
    Stop-Transcript; exit 1
}

# --- Определение пути к ollama.exe ---
$defaultOllama = "C:\Users\Павел\AppData\Local\Programs\Ollama\ollama.exe"
$ollamaExe = $content | Select-String '\\ollama\.exe' | ForEach-Object { $_.Line.Trim() } | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $ollamaExe) { $ollamaExe = $defaultOllama }

if (-not (Test-Path $ollamaExe)) {
    Write-Error "[-] ollama.exe не найден: $ollamaExe"
    Stop-Transcript; exit 1
}

Write-Host "[?] Получение списка моделей..." -ForegroundColor Cyan

try {
    $rawOutput = & $ollamaExe list 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
} catch {
    $rawOutput = $_.Exception.Message
    $exitCode = 1
}

if ($exitCode -ne 0) {
    Write-Error "[-] Не удалось выполнить ollama list"
    Stop-Transcript; exit 1
}

# --- Парсинг вывода ---
$lines = $rawOutput -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$headerIndex = $lines | Where-Object { $_ -match '^NAME\s+ID\s+SIZE\s+MODIFIED' } | ForEach-Object { $lines.IndexOf($_) }

if ($headerIndex -ge 0) {
    $bodyLines = $lines | Select-Object -Skip ($headerIndex + 1)
} else {
    $bodyLines = $lines | Where-Object { $_ -notmatch '^(NAME|ID|SIZE|MODIFIED)' -and $_ -match '\S' }
}

$parsedModels = @()
foreach ($line in $bodyLines) {
    $parts = $line -split '\s{2,}' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($parts.Count -lt 4) { continue }

    $fullName = $parts[0]
    $id       = $parts[1]
    $size     = $parts[2]
    $modified = ($parts[3..($parts.Length-1)] -join ' ').Trim()

    if ($fullName -notmatch ':') {
        $name = $fullName
        $tag  = "latest"
    } else {
        $nameParts = $fullName -split ':'
        $tag  = $nameParts[-1]
        $name = $nameParts[0..($nameParts.Length-2)] -join ':'
    }

    $parsedModels += [PSCustomObject]@{
        Name      = $name
        Tag       = $tag
        FullTag   = "${name}:$tag"
        Size      = $size
        Modified  = $modified
        Id        = $id
    }
}

$models = $parsedModels | Where-Object { $_ }

if (-not $models) {
    Write-Host "[-] Модели не найдены." -ForegroundColor Yellow
    Stop-Transcript
    exit 0
}

Write-Host "`n[+] Установленные модели:" -ForegroundColor Green
$models | Format-Table -Property Name, Tag, Size, Modified -AutoSize | Out-String | Write-Host

Read-Host "Нажмите Enter, чтобы продолжить..."

# --- Все модели доступны для обновления (ручной выбор) ---
Write-Host "`n[*] Доступны для обновления:" -ForegroundColor Yellow

$modelsToUpdate = @()
for ($i = 0; $i -lt $models.Count; $i++) {
    $model = $models[$i]
    $modelsToUpdate += [PSCustomObject]@{
        Index   = $i + 1
        FullTag = $model.FullTag
        Size    = $model.Size
    }
}

# Вывод пронумерованного списка
$modelsToUpdate | Format-Table -Property Index, FullTag, Size -AutoSize | Out-String | Write-Host

Write-Host "`n[*] Выберите модели для обновления." -ForegroundColor Cyan
Write-Host "   Введите номера через запятую (например: 1,3)" -ForegroundColor Gray
Write-Host "   'all' — обновить все" -ForegroundColor Gray
Write-Host "   'q' — выйти без обновления" -ForegroundColor Gray

$response = Read-Host "`nВаш выбор"
$response = $response.Trim()

# Проверка на выход
if ($response -eq "q" -or $response -eq "quit") {
    Write-Host "`n[-] Обновление отменено пользователем." -ForegroundColor Yellow
    Stop-Transcript
    exit 0
}

$selectedModels = @()

if ($response -eq "all") {
    $selectedModels = $modelsToUpdate
} else {
    $indices = $response -split ',' | ForEach-Object { $_.Trim() }
    foreach ($idx in $indices) {
        $num = 0
        if ([int]::TryParse($idx, [ref]$num)) {
            $index = $num - 1
            if ($index -ge 0 -and $index -lt $modelsToUpdate.Count) {
                $selectedModels += $modelsToUpdate[$index]
            } else {
                Write-Warning "Неверный номер: $idx"
            }
        } else {
            if ($idx -ne "") {
                Write-Warning "Некорректный ввод: '$idx'. Используйте числа, 'all' или 'q'"
            }
        }
    }
}

if ($selectedModels.Count -eq 0) {
    Write-Host "`n[-] Ничего не выбрано." -ForegroundColor Red
    Write-Host "    Выход." -ForegroundColor Gray
    Stop-Transcript
    exit 0
}

Write-Host "`n[+] Обновление: $($selectedModels.Count) моделей" -ForegroundColor Green
$confirm = Read-Host "Продолжить? (y/N)"
if ($confirm -inotmatch '^y$|^yes$') {
    Write-Host "[-] Отменено." -ForegroundColor Yellow
    Stop-Transcript
    exit 0
}

# --- Цикл обновления ---
foreach ($model in $selectedModels) {
    $fullTag = $model.FullTag

    Write-Host "`n[*] Обновление: $fullTag" -ForegroundColor Yellow
    Write-Host "[!] ВНИМАНИЕ:" -ForegroundColor Red
    Write-Host "    Команды 'ollama save' и 'load' НЕДОСТУПНЫ в Windows." -ForegroundColor Yellow
    Write-Host "    Невозможно создать бэкап модели перед удалением." -ForegroundColor Yellow
    Write-Host "    Если загрузка прервётся — модель будет потеряна." -ForegroundColor Yellow
    Write-Host "    Убедитесь в стабильности сети и места на диске." -ForegroundColor Gray

    $confirm = Read-Host "`nПродолжить обновление? (y/N)"
    if ($confirm -inotmatch '^y$|^yes$') {
        Write-Host "[-] Пропущено: $fullTag" -ForegroundColor Yellow
        continue
    }

    # --- Удаление старой версии ---
    Write-Host "[*] Удаление старой модели: $fullTag"
    & $ollamaExe rm $fullTag | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "[-] Ошибка удаления модели"
        continue
    }

    # --- Загрузка с выводом в реальном времени ---
    Write-Host "[*] Загрузка обновлённой модели..." -ForegroundColor Cyan
    & $ollamaExe pull $fullTag

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[+] Успешно обновлено: $fullTag" -ForegroundColor Green
    } else {
        Write-Error "[-] Ошибка загрузки: $fullTag"
        Write-Warning "Модель была удалена и не восстановлена."
        Write-Host "    Повторите: ollama pull '$fullTag'" -ForegroundColor Gray
    }
}

Write-Host "`n[+] Обновление завершено." -ForegroundColor Green
Stop-Transcript
