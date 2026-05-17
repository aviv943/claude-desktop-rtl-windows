@echo off
setlocal
cd /d "%~dp0"

echo Claude Desktop RTL Patcher for Windows
echo.

where node >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Node.js was not found. Install it from https://nodejs.org and retry.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0patch.ps1" -Install
if %errorlevel% neq 0 (
    echo.
    echo Installation failed. See output above for details.
    pause
    exit /b 1
)
