@echo off
REM =============================================
REM    Ollama Load Balancer (автосгенерировано)
REM    Узлов: 3
REM    Моделей: 28
REM =============================================

echo.
echo [+] Запуск Ollama Load Balancer...
echo.
echo [!] Серверы:
echo     OLTYAN-303-1 - OLTYAN-303-1.vniigochs.ru
echo     4NIC-404-1 - 4NIC-404-1.vniigochs.ru
echo     node-93 - 10.0.55.59
echo.
echo [!] Нажмите Ctrl+C для остановки.
echo.

%~dp0ollama_load_balancer.exe --server "http://OLTYAN-303-1.vniigochs.ru:11434=OLTYAN-303-1" --server "http://4NIC-404-1.vniigochs.ru:11434=4NIC-404-1" --server "http://10.0.55.59:11434=node-93" --timeout 30
