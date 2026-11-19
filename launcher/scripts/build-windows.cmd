@echo off
rem Builds the launcher installer with the Windows tools.
rem Optional argument: a folder holding portable node\ and toolchain\ (else node\
rem and toolchain\ next to this project, else whatever is on PATH).
setlocal
cd /d "%~dp0.."
set "TOOLS=%~1"
if "%TOOLS%"=="" set "TOOLS=%CD%"

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo Visual Studio Build Tools not found.
  exit /b 1
)
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSDIR=%%i"
if not defined VSDIR (
  echo Visual Studio C++ tools not found.
  exit /b 1
)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1

if exist "%TOOLS%\node\node.exe" set "PATH=%TOOLS%\node;%PATH%"
if exist "%TOOLS%\toolchain\bin\rustc.exe" (
  set "PATH=%TOOLS%\toolchain\bin;%PATH%"
  set "CARGO_HOME=%CD%\.cargo"
  set "RUSTC=%TOOLS%\toolchain\bin\rustc.exe"
  set "RUSTDOC=%TOOLS%\toolchain\bin\rustdoc.exe"
)
set "npm_config_cache=%CD%\.npm-cache"

call npm.cmd ci
if errorlevel 1 exit /b 1
rem Without the updater key the installer is built unsigned and cannot be served as an update.
if defined TAURI_SIGNING_PRIVATE_KEY (
  call npm.cmd run tauri -- build
) else (
  call npm.cmd run tauri -- build --no-sign
)
exit /b %ERRORLEVEL%
