@echo off
rem Violet Rescue launcher. Opens the button app; falls back to the CLI, then to plain cmd scripts.
rem WinRE does not put the PowerShell folder on PATH even when the package is installed.
set "PATH=%PATH%;%SystemRoot%\System32\WindowsPowerShell\v1.0"
rem Test the file itself: WinRE may lack where.exe, and a missing where.exe also reads as "no PowerShell".
if not exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" goto nops
rem The glass window first. It exits non-zero only when it cannot start (no font, no window),
rem and then the classic PowerShell window opens instead.
if not exist "%~dp0gui\VioletRescueUI.exe" goto classic
start "" /wait "%~dp0gui\VioletRescueUI.exe"
if not errorlevel 1 goto end
echo The new window could not open. Opening the classic one.
:classic
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0gui\RescueGUI.ps1"
if not errorlevel 1 goto end
echo The window could not open. Using the text version.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cli\rescue.ps1" help
echo.
echo Type:  powershell -File %~dp0cli\rescue.ps1 ^<command^> -Drive C
cmd /k
goto end

:nops
echo This environment has no PowerShell (a plain Windows setup USB).
echo Build the Violet Rescue media for the full app. Plain fixes available here:
if exist "%~dp0fallback\fix.cmd" echo   %~dp0fallback\fix.cmd          remove the bad update
if exist "%~dp0fallback\repair-boot.cmd" echo   %~dp0fallback\repair-boot.cmd  rebuild boot files
cmd /k
:end
