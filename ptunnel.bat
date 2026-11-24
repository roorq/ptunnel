@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ptunnel.ps1" %*
if "%~1"=="" pause
