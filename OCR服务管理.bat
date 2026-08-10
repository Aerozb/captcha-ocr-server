@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\ocr-service-menu.ps1"
set "MENU_EXIT_CODE=%ERRORLEVEL%"
if not "%MENU_EXIT_CODE%"=="0" pause
endlocal & exit /b %MENU_EXIT_CODE%
