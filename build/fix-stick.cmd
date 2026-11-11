@echo off
rem One click: rebuilds Violet Rescue from the Windows 11 Winre.wim and puts it on the SanDisk stick.
rem Asks for administrator once (click Yes). Does not erase the stick. Window stays open at the end.
setlocal
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
title Violet Rescue - rebuilding and writing the stick. Do not unplug it.
rem The Winre.wim copied from a working Windows 11 (see README). Pass another path as the first argument.
set "WIM=%~1"
if "%WIM%"=="" set "WIM=%USERPROFILE%\Winre-win11.wim"
if not exist "%WIM%" ( echo Missing %WIM% & pause & exit /b 1 )
echo Step 1 of 2: building the image. A few minutes.
call "%~dp0build-media.cmd" "%WIM%" "%USERPROFILE%\violet-rescue-win11.iso" > "%USERPROFILE%\fix-stick-build.log" 2>&1
if errorlevel 1 ( echo BUILD FAILED. See %USERPROFILE%\fix-stick-build.log & pause & exit /b 1 )
echo Step 2 of 2: writing to the stick and checking every file. Do not unplug it.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0copy-to-stick.ps1"
echo.
echo Finished. Read the PASS or FAIL line above.
pause
endlocal
