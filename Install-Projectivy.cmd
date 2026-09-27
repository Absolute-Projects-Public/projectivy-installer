@echo off
rem Double-click this file to run the Projectivy setup wizard on Windows.
rem It bypasses the PowerShell execution policy for this one script only.
title Projectivy Launcher setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Projectivy.ps1"
if errorlevel 1 pause