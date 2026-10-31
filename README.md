# Battle Brothers Multiplayer (BB Co-op)

A mod that aims to let two players share one Battle Brothers world map, each running their own company, and fight together as allies.

Battle Brothers has no networking, but the game's UI browser can make HTTP requests. This mod uses that to talk to a small **relay server** that both players connect to.

**Status: v0.1.1, connection prototype.** It proves the game can talk to the relay. It does not add gameplay yet. Target is the vanilla game first; Legends and other mods come later.

## What v0.1.1 does

- On the main menu, pings the relay and shows an on-screen notification (top right) saying whether it is reachable.
- Joins a session and shows which other players are connected.
- Tests whether the game's browser supports WebSockets (result in `log.html`).
- `Ctrl+H` (world map or battle) sends a "hello" notification to the other player (you get a "Hello sent" confirmation).
- While on the world map, sends your company's position about once a second. The other player's game writes it to `log.html`.
- `Ctrl+J` re-runs the connection test (use it after changing settings).

## Requirements

- Battle Brothers (vanilla, with or without DLCs)
- [Modern Hooks](https://github.com/MSUTeam/Modern-Hooks) and [MSU](https://github.com/MSUTeam/MSU) (MSU requires Modern Hooks)
- [Node.js](https://nodejs.org/) 16 or newer, only on the PC that runs the relay

## Install

1. Build the mod zip: `python build.py` (writes `dist/mod_bb_coop.zip`), or download it from the release/PR.
2. Copy `mod_bb_coop.zip` into `Battle Brothers/data/` next to the MSU and Modern Hooks zips.
3. On one PC, start the relay: double-click `relay/start-relay.bat` on Windows, or run `node relay/relay.js` (default port 7777). Keep its window open while playing.

## Testing with two players

1. Player 1 runs the relay. Player 2 must be able to reach that PC on port 7777 (same network, a port forward, or a VPN like Tailscale/ZeroTier/Hamachi).
2. In game, open **Mod Options > Battle Brothers Co-op**:
   - **Relay URL:** player 1 keeps `http://127.0.0.1:7777`; player 2 uses `http://<player 1's IP>:7777`.
   - **Player name:** each player picks a different name.
3. Press `Ctrl+J` (or restart) to reconnect with the new settings.
4. Start or load a campaign and press `Ctrl+H`. The other player should get a popup.

You can also test alone: run the relay and start the game on the same PC. You should see "Relay reachable" and "Joined co-op session" popups.

**Please send back** the `[BBCoop]` lines from `Documents/Battle Brothers/log.html`, especially the WebSocket test line.

## Layout

- `mod/`: the mod, zipped as-is into `mod_bb_coop.zip`
  - `scripts/!mods_preload/mod_bb_coop.nut`: registers with Modern Hooks and MSU
  - `bb_coop/load.nut`: settings, keybinds, connection setup
  - `scripts/mods/bb_coop/bb_coop_connection.nut`: Squirrel side of the bridge
  - `ui/mods/bb_coop/bb_coop_connection.js`: network layer (HTTP to the relay)
- `relay/relay.js`: relay server, no dependencies
- `tests/js_client_harness.js`: runs two simulated clients' JS against the relay: `node tests/js_client_harness.js`

## Roadmap

1. **Connection prototype** (this version)
2. **Ghost companies:** same map seed for both players; each sees the other's company on the world map
3. **Fighting together:** one player's battle spawns the other's brothers as allies; results go back to their roster
4. **Selective world sync:** share chosen world events (destroyed camps, etc.)
5. **Mod compatibility:** Legends, then others
