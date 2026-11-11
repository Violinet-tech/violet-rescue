@echo off
rem Builds the glass window (ui-rs) and puts VioletRescueUI.exe into gui\, where build-media.cmd
rem picks it up for the boot image. No admin needed. Needs the Rust toolchain (rustup, msvc).
setlocal
set "ROOT=%~dp0.."
pushd "%ROOT%\ui-rs" || exit /b 1
rem Rewrite the build machine's folders out of the exe (panic messages carry source paths),
rem so a published build names no user folder. RUSTFLAGS replaces .cargo\config.toml's flags,
rem so the static C runtime that WinRE needs is repeated here. The encoded form keeps folder
rem names with spaces in one piece (plain RUSTFLAGS splits on spaces).
if not defined CARGO_HOME set "CARGO_HOME=%USERPROFILE%\.cargo"
powershell -NoProfile -Command "$env:CARGO_ENCODED_RUSTFLAGS = @('-Ctarget-feature=+crt-static', ('--remap-path-prefix=' + $env:CARGO_HOME + '=cargo'), ('--remap-path-prefix=' + (Get-Location).Path + '=ui-rs')) -join [char]0x1f; cargo build --release; exit $LASTEXITCODE" || (popd & exit /b 1)
copy /y "target\release\VioletRescueUI.exe" "%ROOT%\gui\VioletRescueUI.exe" >nul || (popd & exit /b 1)
popd
echo Built: gui\VioletRescueUI.exe
