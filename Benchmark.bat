@echo off
where pwsh >nul 2>nul
if errorlevel 1 (
    echo ERROR: PowerShell 7 ^(pwsh^) is required.
    exit /b 1
)
pwsh -NoLogo -NoProfile -File "%~dp0Benchmark.ps1" %*
exit /b %ERRORLEVEL%
