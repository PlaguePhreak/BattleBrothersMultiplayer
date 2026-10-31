# Battle Brothers Multiplayer (BB Co-op)

A mod that aims to let two players share one Battle Brothers world map, each running their own company, and fight together as allies.

Battle Brothers has no networking, but the game's UI browser can make HTTP requests. This mod uses that to talk to a small **relay server** that both players connect to.

**Status: v0.3.0, shared battles (part 1).** Each player sees the other's company on the world map, and can join the other's battle as reinforcements. For now the host controls the reinforcements; letting each player control their own brothers is next. Target is the vanilla game first; Legends and other mods come later.

## What v0.3.0 does

- **Join a battle as reinforcements:** when another player's battle starts and your company is within the join range (Mod Options, default 600), you get a notification. Press `Ctrl+B` to send your frontline brothers (up to 12). They arrive on free tiles along the map edge nearest the host's company and fight on the host's side. When the battle ends, each brother comes back to your roster with their new wounds, XP and gear, or is buried with an obituary entry if they fell.

- **Ghost companies:** while you are on the world map, your company's position is sent about once a second. The other player's game shows your company there as a friendly party that follows you smoothly. It never fights, is never saved, and disappears 20 seconds after you go quiet (closing the game, going to the main menu).
- For positions to line up, both players must start a **new campaign with the same map seed** (copy the seed from the new-campaign screen). You get a warning if the seeds differ. Campaigns started before installing v0.2.0 don't know their seed, so no check happens there.

- On the main menu, pings the relay and shows an on-screen notification (top right) saying whether it is reachable.
- Joins a session and shows which other players are connected.
- Tests whether the game's browser supports WebSockets (result in `log.html`).
- `Ctrl+H` (world map or battle) sends a "hello" notification to the other player (you get a "Hello sent" confirmation).
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
4. Start campaigns with the same map seed, then press `Ctrl+H`. The other player should get a notification, and each of you should see the other's company on the map.

**Testing alone:** start the relay with `relay/start-relay-with-bot.bat` (or `node relay/relay.js --bot`). It adds a fake player called "Bot" whose company circles yours on the world map and answers your hellos. When you start a battle, Bot joins 3 seconds later as reinforcements, using copies of your own frontline brothers named "Bot's ...".

If something goes wrong, send the `[BBCoop]` lines from `Documents/Battle Brothers/log.html`.

## Layout

- `mod/`: the mod, zipped as-is into `mod_bb_coop.zip`
  - `scripts/!mods_preload/mod_bb_coop.nut`: registers with Modern Hooks and MSU
  - `bb_coop/load.nut`: settings, keybinds, connection setup
  - `bb_coop/ghosts.nut`: ghost companies on the world map, map seed tracking
  - `bb_coop/roster.nut`: brothers to network data and back (MSU serialization emulator)
  - `bb_coop/battle.nut`: shared battles: invites, reinforcements at the map edge, results
  - `scripts/mods/bb_coop/bb_coop_connection.nut`: Squirrel side of the bridge
  - `ui/mods/bb_coop/bb_coop_connection.js`: network layer (HTTP to the relay)
- `relay/relay.js`: relay server, no dependencies (`--bot` adds a fake player)
- `tests/js_client_harness.js`: runs two simulated clients' JS against the relay: `node tests/js_client_harness.js`

## Roadmap

1. **Connection prototype** (done: works in-game, WebSockets supported)
2. **Ghost companies** (done)
3. **Fighting together:** part 1, join as reinforcements (this version); part 2, each player controls their own brothers
4. **Selective world sync:** share chosen world events (destroyed camps, etc.)
5. **Mod compatibility:** Legends, then others
