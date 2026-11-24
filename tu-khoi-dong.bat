@echo off
chcp 65001 >nul
title Desk-Buddy - tu khoi dong
rem Bam lan 1: bat tu chay ngam moi lan dang nhap Windows + chay ngam ngay.
rem Bam lan 2: tat tu khoi dong + dung server dang chay ngam.
set "LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Desk-Buddy.lnk"
set "OLDLNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Mini Screen.lnk"
set "STOP=Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*%~dp0server.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"

set "WASON="
if exist "%OLDLNK%" (
  del "%OLDLNK%"
  set "WASON=1"
)
if exist "%LNK%" set "WASON=1"
if defined WASON (
  if exist "%LNK%" del "%LNK%"
  powershell -NoProfile -Command "%STOP%"
  echo.
  echo   Da TAT tu khoi dong va dung server.
  echo   Muon chay lai: bam lai file nay, hoac start.bat
  echo.
  pause
  exit /b
)

powershell -NoProfile -Command "$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:LNK); $s.TargetPath = 'powershell.exe'; $s.Arguments = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%~dp0server.ps1\" -NoMenu'; $s.WorkingDirectory = '%~dp0'; $s.WindowStyle = 7; $s.Description = 'Desk-Buddy server'; $s.Save()"
powershell -NoProfile -Command "%STOP%"
start "" powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0server.ps1" -NoMenu
echo.
echo   Da BAT tu khoi dong: server dang chay ngam, va se tu chay moi lan dang nhap Windows
echo   (mo trang dung lan truoc; doi trang = giu man hinh tren dien thoai).
echo   Tat: bam lai file nay.
echo.
timeout /t 6 >nul
