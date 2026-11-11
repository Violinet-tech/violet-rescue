@echo off
rem Builds the Violet Rescue media and writes it to a USB stick in one step. The stick is ERASED.
rem Run as administrator.
rem
rem   make-stick.cmd <winre.wim path | winpe> <output.iso> <USB drive letter, e.g. K:>
rem
rem The stick is only touched after the build succeeds.
setlocal
if "%~3"=="" ( echo Usage: make-stick.cmd ^<winre.wim path ^| winpe^> ^<output.iso^> ^<USB drive letter, e.g. K:^> & exit /b 1 )
call "%~dp0build-media.cmd" "%~1" "%~2"
if errorlevel 1 ( echo Build failed. The USB stick was not touched. & exit /b 1 )
call "%~dp0write-usb.cmd" %3
endlocal
