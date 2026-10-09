@echo off
echo outer started
cmd /c "%~dp0test_quit.bat" < nul
echo outer finished
