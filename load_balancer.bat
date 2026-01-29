@echo off
REM =============================================
REM    Ollama Load Balancer (автосгенерировано)
REM    Узлов: 1
REM    Моделей: 27
REM =============================================

echo.
echo ?? Запуск Ollama Load Balancer...
echo.
echo ???  Серверы:
echo     node-331 - 10.0.55.59
echo.
echo ?? Нажмите Ctrl+C для остановки.
echo.

%~dp0ollama_load_balancer.exe --server "http://10.0.55.59:11434=node-331" --timeout 30
