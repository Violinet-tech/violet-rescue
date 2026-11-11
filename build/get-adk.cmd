@echo off
rem Installs the Windows ADK (Assessment and Deployment Kit) and its WinPE add-on,
rem which build-media.cmd needs. Downloaded from Microsoft through winget; not bundled
rem because Microsoft's licence does not allow redistributing it. Run as administrator.
rem
rem The add-on must be the same version as the ADK. winget carries the add-on only at
rem 10.1.26100.x (Windows 11 24H2), so the ADK is pinned to the same version. That is
rem also the version to use when repairing 24H2 (builds 26100/26200). If a newer ADK is
rem already installed it is removed first, because the add-on will not install on it.
setlocal
set "VER=10.1.26100.9457"
where winget >nul 2>&1
if errorlevel 1 (
  echo winget is not installed. Get the ADK and the WinPE add-on from:
  echo   https://learn.microsoft.com/windows-hardware/get-started/adk-install
  exit /b 1
)

net session >nul 2>&1
if errorlevel 1 (
  echo This needs an administrator window. Right-click Command Prompt, Run as administrator.
  exit /b 1
)

set "CUR="
for /f "tokens=1-4 delims= " %%A in ('winget list --id Microsoft.WindowsADK -e --accept-source-agreements 2^>nul ^| findstr /i "Microsoft.WindowsADK"') do set "CUR=%%C"
if defined CUR if /i not "%CUR%"=="%VER%" (
  echo Found ADK %CUR%, which does not match the add-on ^(%VER%^). Removing it first...
  winget uninstall --id Microsoft.WindowsADK -e --accept-source-agreements || ( echo Could not remove ADK %CUR%. Remove it in Settings ^> Apps, then run this again. & exit /b 1 )
)

winget install --id Microsoft.WindowsADK -e -v %VER% --accept-package-agreements --accept-source-agreements || exit /b 1
winget install --id Microsoft.WindowsADK.WinPEAddon -e -v %VER% --accept-package-agreements --accept-source-agreements || exit /b 1

echo.
echo Done. ADK and WinPE add-on %VER% installed. Next: build\build-media.cmd winpe C:\path\rescue.iso
endlocal
