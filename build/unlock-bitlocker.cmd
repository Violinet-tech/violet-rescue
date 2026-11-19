@echo off
rem Unlocks every locked BitLocker drive using the recovery keys in unlock-keys.txt sitting in the
rem same folder as this script. Only the 48-digit keys (8 groups of 6 digits) are picked out, so the
rem file may also hold the PC name and Key ID lines. It tries each key on each locked drive, so the
rem order does not matter. The keys are never printed. Delete unlock-keys.txt when you are done.
rem Needs PowerShell in the rescue image (the Violet Rescue stick has it).
rem Run it from the rescue stick's command prompt:   E:\unlock-bitlocker.cmd   (use the stick's letter)
setlocal
set "KEYS=%~dp0unlock-keys.txt"
if not exist "%KEYS%" (
  echo Put your BitLocker recovery keys in this file, one per line, then run this again:
  echo   %KEYS%
  exit /b 1
)
set "ANY="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
  manage-bde -status %%D: 2>nul | find "Lock Status" | find /v "Unlocked" >nul
  if not errorlevel 1 (
    set "ANY=1"
    echo %%D: is locked. Trying your keys...
    set "DONE="
    for /f "usebackq delims=" %%K in (`powershell -NoProfile -Command "Select-String -Path '%KEYS%' -Pattern '\d{6}(-\d{6}){7}' -AllMatches | ForEach-Object { $_.Matches.Value }"`) do (
      if not defined DONE (
        manage-bde -unlock %%D: -RecoveryPassword %%K >nul 2>&1
        if not errorlevel 1 (
          echo   %%D: UNLOCKED
          set "DONE=1"
        )
      )
    )
    if not defined DONE echo   %%D: none of the keys fit this drive.
  )
)
if not defined ANY echo No locked drive was found.
echo.
echo Finished. Delete unlock-keys.txt from the stick when you are done.
endlocal
