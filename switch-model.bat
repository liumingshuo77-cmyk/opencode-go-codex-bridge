@echo off
rem One-click: switch which opencode-go subscription model Codex uses
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0switch-model.ps1"
pause
