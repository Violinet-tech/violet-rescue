@echo off
rem Builds Violet Rescue boot media. Run as administrator on a working PC with the
rem Windows ADK + WinPE add-on installed (build\get-adk.cmd).
rem
rem   build-media.cmd <base> <output>
rem     base   = path to a winre.wim (recommended: it includes System Restore), or the word winpe
rem     output = an ISO file path (C:\out\rescue.iso) or a USB drive letter (E:)  -- a USB is ERASED
rem
rem Get winre.wim from a working PC:  reagentc /info  shows its folder (copy Winre.wim, it is hidden),
rem or from Windows install media:  install.wim -> Windows\System32\Recovery\Winre.wim
setlocal
if "%~2"=="" (
  echo Usage: build-media.cmd ^<winre.wim path ^| winpe^> ^<output.iso ^| USB letter^>
  exit /b 1
)
set "BASE=%~1"
set "OUT=%~2"
set "ROOT=%~dp0.."
set "WORK=%TEMP%\violet-rescue-build"
set "ADK=%ProgramFiles(x86)%\Windows Kits\10\Assessment and Deployment Kit"
set "OCS=%ADK%\Windows Preinstallation Environment\amd64\WinPE_OCs"

if not exist "%OCS%" (
  echo Windows ADK WinPE add-on not found. Run build\get-adk.cmd first.
  exit /b 1
)
call "%ADK%\Deployment Tools\DandISetEnv.bat"

if exist "%WORK%" rmdir /s /q "%WORK%"
call copype amd64 "%WORK%" || exit /b 1

if /i not "%BASE%"=="winpe" (
  if not exist "%BASE%" ( echo %BASE% not found. & exit /b 1 )
  echo Using %BASE% as the base image.
  attrib -h -s "%BASE%" 2>nul
  copy /y "%BASE%" "%WORK%\media\sources\boot.wim" || exit /b 1
)

dism /mount-image /imagefile:"%WORK%\media\sources\boot.wim" /index:1 /mountdir:"%WORK%\mount" || exit /b 1

echo Adding PowerShell, .NET, WMI, storage and DISM cmdlets...
for %%P in (WinPE-WMI WinPE-NetFx WinPE-Scripting WinPE-PowerShell WinPE-StorageWMI WinPE-DismCmdlets WinPE-SecureStartup) do (
  dism /image:"%WORK%\mount" /add-package /packagepath:"%OCS%\%%P.cab" >nul
  if errorlevel 1 (echo   %%P: already there or failed) else (echo   %%P added)
  if exist "%OCS%\en-us\%%P_en-us.cab" dism /image:"%WORK%\mount" /add-package /packagepath:"%OCS%\en-us\%%P_en-us.cab" >nul
)

echo Copying the app...
for %%D in (cli gui db drivers helper agent) do xcopy "%ROOT%\%%D" "%WORK%\mount\Rescue\%%D\" /e /i /y /q >nul
copy /y "%ROOT%\Rescue.cmd" "%WORK%\mount\Rescue\" >nul
if exist "%ROOT%\..\repair-win11\fix.cmd" xcopy "%ROOT%\..\repair-win11\*.cmd" "%WORK%\mount\Rescue\fallback\" /i /y /q >nul

echo Starting the app at boot...
(
  echo [LaunchApps]
  echo %%SYSTEMDRIVE%%\Windows\System32\wpeinit.exe
  echo %%SYSTEMDRIVE%%\Windows\System32\cmd.exe, /k %%SYSTEMDRIVE%%\Rescue\Rescue.cmd
) > "%WORK%\mount\Windows\System32\winpeshl.ini"

dism /unmount-image /mountdir:"%WORK%\mount" /commit || exit /b 1

echo %OUT% | findstr /i "\.iso" >nul
if not errorlevel 1 goto iso
echo About to ERASE drive %OUT% and write the rescue media to it.
set /p "OK=Type Y to continue: "
if /i not "%OK%"=="Y" ( echo Cancelled. & exit /b 1 )
call MakeWinPEMedia /UFD "%WORK%" %OUT%
goto built
:iso
call MakeWinPEMedia /ISO "%WORK%" "%OUT%"
:built
echo.
echo Built. boot.wim for install-boot-entry.cmd is at %WORK%\media\sources\boot.wim
endlocal
