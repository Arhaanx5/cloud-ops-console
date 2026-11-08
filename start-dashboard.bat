@echo off
title FMCG Cloud Operations Dashboard
echo =========================================================
echo  Starting FMCG Cloud Operations Control Dashboard...
echo =========================================================
echo.

start "" cmd /c "timeout /t 1 /nobreak >nul && start http://localhost:4040"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"

pause

