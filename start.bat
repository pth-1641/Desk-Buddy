@echo off
title Desk-Buddy
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" -NoMenu %*
pause
