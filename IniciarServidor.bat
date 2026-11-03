@echo off
chcp 65001 >nul
title Iniciar Servidor Terraria (tModLoader)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\gerenciador_windows.ps1" -Action Start
pause
