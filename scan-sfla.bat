@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM Generic Semgrep scan helper for SFLA repositories.
REM Place this script in the repository root.
REM Usage:
REM   scan-sfla.bat
REM   scan-sfla.bat tgg-grid.html
REM   scan-sfla.bat tgds-data-scope.html
REM 
REM If not in PATH: set "PATH=%APPDATA%\Python\Python310\Scripts;%PATH%"

set "REPO_ROOT=%~dp0"
pushd "%REPO_ROOT%" >nul

set "SOURCE=%~1"
if not defined SOURCE set "SOURCE=tgg-grid.html"

set "SCAN_DIR=scan-results"

REM Prefer Semgrep already available on PATH.
set "SEMGREP="
for /f "delims=" %%I in ('where semgrep.exe 2^>nul') do (
  if not defined SEMGREP set "SEMGREP=%%I"
)

REM If Semgrep is not on PATH, look beneath the current user's Python installs.
if not defined SEMGREP (
  for /d %%D in ("%APPDATA%\Python\Python*") do (
    if exist "%%D\Scripts\semgrep.exe" (
      if not defined SEMGREP set "SEMGREP=%%D\Scripts\semgrep.exe"
    )
  )
)

if not defined SEMGREP (
  echo.
  echo ERROR: Semgrep was not found.
  echo Install Semgrep or add semgrep.exe to PATH.
  echo.
  popd >nul
  exit /b 1
)

if not exist "%SOURCE%" (
  echo.
  echo ERROR: File was not found:
  echo   %SOURCE%
  echo.
  echo Usage:
  echo   %~nx0 filename.html
  echo.
  popd >nul
  exit /b 1
)

if not exist "%SCAN_DIR%" mkdir "%SCAN_DIR%"

for %%F in ("%SOURCE%") do set "SOURCE_NAME=%%~nF"

set "TEXT_OUT=%SCAN_DIR%\%SOURCE_NAME%-semgrep.txt"
set "RAW_JSON_OUT=%SCAN_DIR%\%SOURCE_NAME%-semgrep-raw.json"
set "JSON_OUT=%SCAN_DIR%\%SOURCE_NAME%-semgrep.json"

echo.
echo ============================================================
echo Semgrep Security Scan
echo ============================================================
echo Repository:
echo   %REPO_ROOT%
echo File:
echo   %SOURCE%
echo Semgrep:
echo   %SEMGREP%
echo.

echo Semgrep version:
"%SEMGREP%" --version
if errorlevel 1 (
  popd >nul
  exit /b 1
)

echo.
echo Running text scan...
"%SEMGREP%" scan --config auto "%SOURCE%" > "%TEXT_OUT%"
set "TEXT_RC=%ERRORLEVEL%"

echo Running JSON scan...
"%SEMGREP%" scan --config auto --json "%SOURCE%" > "%RAW_JSON_OUT%"
set "JSON_RC=%ERRORLEVEL%"

if "%JSON_RC%"=="0" (
  where python.exe >nul 2>&1
  if errorlevel 1 (
    echo WARNING: Python was not found on PATH, so JSON was not pretty-printed.
    echo Raw JSON retained at:
    echo   %RAW_JSON_OUT%
  ) else (
    python -m json.tool "%RAW_JSON_OUT%" "%JSON_OUT%"
    set "FORMAT_RC=%ERRORLEVEL%"

    if "!FORMAT_RC!"=="0" (
      del "%RAW_JSON_OUT%"
    ) else (
      echo WARNING: Semgrep completed, but JSON formatting failed.
      echo Raw JSON retained at:
      echo   %RAW_JSON_OUT%
    )
  )
) else (
  echo WARNING: Semgrep JSON scan returned exit code %JSON_RC%.
  echo Raw output, if any, retained at:
  echo   %RAW_JSON_OUT%
)

echo.
echo ============================================================
echo Scan complete
echo ============================================================
echo Results:
echo   %TEXT_OUT%
if exist "%JSON_OUT%" echo   %JSON_OUT%
if exist "%RAW_JSON_OUT%" echo   %RAW_JSON_OUT%
echo.
echo Exit codes: text=%TEXT_RC% json=%JSON_RC%
echo.

popd >nul
endlocal
