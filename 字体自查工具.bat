@echo off
cd /d "%~dp0"
where pwsh >nul 2>nul
if errorlevel 1 goto legacy
start "" pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0font-scanner.ps1"
exit /b

:legacy
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0font-scanner.ps1"
