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
echo   To get help: open the "out" folder (in this same folder).
echo     report.html   = the full report. UNREDACTED (shows your PC name +
echo                     hardware). Send it ONLY to someone you trust.
echo     ai-prompt.txt = key identifiers removed. THIS is the one to paste
echo                     into an AI (ChatGPT / Claude) or to share for help.
echo   ------------------------------------------------------------
echo.
pause
