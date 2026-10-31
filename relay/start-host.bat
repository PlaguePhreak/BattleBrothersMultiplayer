@echo off
cd /d "%~dp0"
echo Hosting a co-op world. This window runs the relay and the free tunnel: keep it open while you play.
if not exist cloudflared-windows-amd64.exe if not exist cloudflared.exe (
  echo.
  echo cloudflared-windows-amd64.exe is not in this folder, so there will be no tunnel.
  echo Download it from https://github.com/cloudflare/cloudflared/releases/latest and put it here,
  echo or use Tailscale and start-relay.bat instead.
  echo.
)
set /p BBCOOP_PASSWORD=Session password, or press Enter for none (you can also set it in the game's Host window): 
node relay.js --tunnel
pause
