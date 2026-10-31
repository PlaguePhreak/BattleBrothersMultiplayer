@echo off
cd /d "%~dp0"
echo Pick a session password for this game (your friend enters the same one).
set /p BBCOOP_PASSWORD=Password, or press Enter for none: 
node relay.js
pause
