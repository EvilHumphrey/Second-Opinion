@echo off
title Second Opinion - PC health check
echo.
echo   ============================================================
echo     Second Opinion - read-only PC health check
echo   ============================================================
echo.
echo   This ONLY reads your Windows logs and drive info, then writes
echo   a report into the "out" folder. It does not change any Windows
echo   settings, install anything, or connect to the internet.
echo.
echo   Working... a report will open in your web browser shortly.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Invoke-SecondOpinion.ps1" -Days 90 -OpenReport
echo.
echo   ------------------------------------------------------------
echo   Done. If a report opened in your browser, you can close this.
echo.
echo   To get help: open the "out" folder (in this same folder) and
echo   send BOTH files to the person helping you:
echo       report.html   and   ai-prompt.txt
echo   ------------------------------------------------------------
echo.
pause
