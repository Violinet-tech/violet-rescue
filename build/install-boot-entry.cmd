@echo off
rem Puts Violet Rescue on a partition Windows' boot manager can read and adds it to the boot menu.
rem It also becomes the recovery target: when Windows fails to start twice in a row, the PC
rem boots into Violet Rescue instead of looping. Run as administrator on the working Windows.
rem
rem   install-boot-entry.cmd <boot.wim from build-media> [partition letter]
rem
rem Best: a separate small NTFS partition (2 GB is enough) or another internal drive, so it
rem still works if the Windows partition is damaged. Default is C:.
setlocal EnableDelayedExpansion
if "%~1"=="" ( echo Usage: install-boot-entry.cmd ^<boot.wim^> [partition letter] & exit /b 1 )
set "WIM=%~1"
set "P=%~2"
if "%P%"=="" set "P=C"
set "P=%P::=%"

if not exist "%WIM%" ( echo %WIM% not found. & exit /b 1 )
if not exist "%SystemRoot%\Boot\DVD\EFI\boot.sdi" ( echo boot.sdi not found in Windows\Boot\DVD\EFI. & exit /b 1 )

echo Copying to %P%:\Rescue ...
mkdir "%P%:\Rescue" 2>nul
copy /y "%WIM%" "%P%:\Rescue\boot.wim" || exit /b 1
copy /y "%SystemRoot%\Boot\DVD\EFI\boot.sdi" "%P%:\Rescue\boot.sdi" || exit /b 1

bcdedit /create {ramdiskoptions} /d "Violet Rescue" >nul 2>&1
bcdedit /set {ramdiskoptions} ramdisksdidevice partition=%P%:
bcdedit /set {ramdiskoptions} ramdisksdipath \Rescue\boot.sdi

set "GUID="
for /f "tokens=2 delims={}" %%g in ('bcdedit /create /d "Violet Rescue" /application osloader') do set "GUID={%%g}"
if "!GUID!"=="" ( echo Could not create the boot entry. & exit /b 1 )

bcdedit /set !GUID! device ramdisk=[%P%:]\Rescue\boot.wim,{ramdiskoptions}
bcdedit /set !GUID! osdevice ramdisk=[%P%:]\Rescue\boot.wim,{ramdiskoptions}
bcdedit /set !GUID! path \windows\system32\boot\winload.efi
bcdedit /set !GUID! systemroot \windows
bcdedit /set !GUID! winpe yes
bcdedit /set !GUID! detecthal yes
bcdedit /displayorder !GUID! /addlast
bcdedit /timeout 5

rem Failed boots go to Violet Rescue instead of the stock recovery screen.
bcdedit /set {default} recoverysequence !GUID!
bcdedit /set {default} recoveryenabled yes

echo.
echo Installed. Entry !GUID! shows in the boot menu for 5 seconds, and opens by itself after failed boots.
echo To remove it:  bcdedit /delete !GUID!   then   reagentc /enable
endlocal
