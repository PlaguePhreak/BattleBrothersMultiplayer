@echo off
cd /d "%~dp0"
echo Pick a session password for this game (your friend enters the same one).
set /p BBCOOP_PASSWORD=Password, or press Enter for none (you can also set it in the game's Host window): 
node relay.js
pause
