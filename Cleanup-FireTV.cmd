@echo off
rem Double-click this file to run the full cleanup wizard on Windows.
rem It bypasses the PowerShell execution policy for this one script only.
title Fire TV cleanup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Cleanup.ps1"
if errorlevel 1 pause
