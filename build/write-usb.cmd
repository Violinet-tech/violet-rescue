@echo off
rem Writes the already built Violet Rescue image to a USB stick. The stick is ERASED.
rem Run as administrator, after build-media.cmd has built the image (it leaves it in %TEMP%).
rem
rem   write-usb.cmd <USB drive letter, e.g. K:>
setlocal
if "%~1"=="" ( echo Usage: write-usb.cmd ^<USB drive letter, e.g. K:^> & exit /b 1 )
set "DRV=%~1"
set "WORK=%TEMP%\violet-rescue-build"
set "ADK=%ProgramFiles(x86)%\Windows Kits\10\Assessment and Deployment Kit"

net session >nul 2>&1
if errorlevel 1 ( echo This needs an administrator window. & exit /b 1 )
if not exist "%WORK%\media\sources\boot.wim" ( echo No built image in %WORK%. Run build-media.cmd first. & exit /b 1 )
if not exist "%ADK%\Deployment Tools\DandISetEnv.bat" ( echo Windows ADK not found. Run get-adk.cmd first. & exit /b 1 )

rem Only ever write to a removable drive.
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "(Get-Volume -DriveLetter '%DRV:~0,1%' -ErrorAction SilentlyContinue).DriveType"`) do set "DT=%%T"
if /i not "%DT%"=="Removable" ( echo %DRV% is not a removable drive ^(%DT%^). Not writing. & exit /b 1 )

call "%ADK%\Deployment Tools\DandISetEnv.bat" >nul
echo About to ERASE %DRV% and write Violet Rescue to it.
call MakeWinPEMedia /UFD "%WORK%" %DRV%
echo exit=%errorlevel%
endlocal
