@echo off
setlocal EnableExtensions
title KIZZIMO Daemon Companion v3
cd /d "%~dp0"
echo ==================================================
echo  KIZZIMO Daemon Companion for iPhone - v3
echo  Validates and stages plist drafts, NOT live daemons
echo ==================================================
set "PY="
where python >nul 2>&1
if not errorlevel 1 set "PY=python"
if not defined PY if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" set "PY=%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
if not defined PY if exist "%LOCALAPPDATA%\Programs\Python\Python313\python.exe" set "PY=%LOCALAPPDATA%\Programs\Python\Python313\python.exe"
if not defined PY (
  where py >nul 2>&1
  if not errorlevel 1 set "PY=py -3"
)
if not defined PY (
  echo ERROR: Python 3 not found. Install Python from python.org.
  pause
  exit /b 1
)
echo Python command: %PY%
echo.
%PY% "%~dp0DaemonCompanion.py"
echo.
echo Companion closed. Errorlevel: %ERRORLEVEL%
pause
