@echo off
rem DeskPilot double-click launcher (Windows).
setlocal
where pwsh >nul 2>nul
if %errorlevel%==0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-DeskPilot.ps1" %*
) else (
    echo PowerShell 7 ^(pwsh^) is required. Install it from https://aka.ms/powershell
    pause
)
endlocal
