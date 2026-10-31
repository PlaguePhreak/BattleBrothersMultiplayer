#!/usr/bin/env node
// Battle Brothers Co-op relay. No dependencies: needs only Node.js 16+.
// Usage: node relay.js [port] [--bot]   (default port 7777)
//   --bot  adds a fake second player ("Bot") whose company circles yours on the
//          world map and answers hellos, so you can test alone.
// Both players point the mod's "Relay URL" setting at this machine.

'use strict';
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');

const VERSION = '0.8.0';
const args = process.argv.slice(2);
const BOT = args.includes('--bot');
const PORT = parseInt(args.find((a) => /^\d+$/.test(a)) || process.env.PORT || '7777', 10);
const POLL_HOLD_MS = 8000;      // must stay below the mod's 10s request timeout
const MAX_MESSAGES = 500;       // keep a short history in memory

let seq = 0;
// Changes every time the relay starts, so games notice a restart and catch up
const BOOT = crypto.randomBytes(4).toString('hex');
const messages = [];            // { seq, from, type, payload, time }
const players = new Map();      // name -> { lastSeen, modVersion, gameVersion }
const waiting = new Set();      // pending long-poll requests

function cors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
}

function sendJSON(res, status, obj) {
  cors(res);
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', (c) => {
      data += c;
      if (data.length > 8e6) { reject(new Error('body too large')); req.destroy(); }
    });
    req.on('end', () => {
      try { resolve(data ? JSON.parse(data) : {}); } catch (e) { reject(e); }
    });
  });
}

function touch(name) {
  if (!name) return;
  const p = players.get(name) || {};
  p.lastSeen = Date.now();
  players.set(name, p);
}

function activePlayers() {
  const cutoff = Date.now() - 30000;
  return [...players.entries()].filter(([, p]) => p.lastSeen >= cutoff).map(([n]) => n);
}

function pushMessage(from, type, payload) {
  const msg = { seq: ++seq, from, type, payload, time: Date.now() };
  messages.push(msg);
  if (messages.length > MAX_MESSAGES) messages.shift();
  if (type !== 'pos') {
    let text = JSON.stringify(payload);
    if (text.length > 300) text = text.slice(0, 300) + `... (${text.length} chars)`;
    console.log(`[${new Date().toISOString()}] ${from}: ${type} ${text}`);
  }
  for (const w of [...waiting]) w.flush();
  if (BOT && from !== BOT_NAME) botHear(msg);
  return msg;
}

// ---- fake second player for solo testing ----
const BOT_NAME = 'Bot';
// Join the bot's clan (Ctrl+K in game) and it fights on your side; otherwise it joins against you
const BOT_CLAN = 'Bot Clan';
const bot = { target: null, seed: '', angle: 0 };

// The bot remembers the last world it saw, so it can act as a host for the Multiplayer
// join test: play a campaign once, then use Multiplayer from the main menu.
const BOT_STATE_FILE = path.join(__dirname, 'bot-state.json');
let botWorld = null;
try { botWorld = JSON.parse(fs.readFileSync(BOT_STATE_FILE, 'utf8')); } catch (e) {}
let botWorldSaved = 0;
// The bot's one company origin (the game rolls brothers to match), kept between relay runs
const BOT_ORIGINS = { mercenaries: 'Mercenaries', deserters: 'Deserters', militia: 'Peasant Militia', beast_slayers: 'Beast Slayers', caravan: 'Trading Caravan', lone_wolf: 'Lone Wolf' };
const originArg = args.find((a) => a.startsWith('--origin='));
let botOrigin = originArg ? originArg.slice(9) : (botWorld && botWorld.origin) || Object.keys(BOT_ORIGINS)[Math.floor(Math.random() * Object.keys(BOT_ORIGINS).length)];
if (!BOT_ORIGINS[botOrigin]) botOrigin = 'mercenaries';
function rememberWorld(p) {
  if (!p.seed) return;
  botWorld = { seed: p.seed, x: p.x, y: p.y, origin: botOrigin };
  const now = Date.now();
  if (now - botWorldSaved < 10000) return;
  botWorldSaved = now;
  try { fs.writeFileSync(BOT_STATE_FILE, JSON.stringify(botWorld)); } catch (e) {}
}

function botHear(msg) {
  if (msg.type === 'pos' && msg.payload) {
    bot.target = { x: msg.payload.x, y: msg.payload.y };
    bot.seed = msg.payload.seed || '';
    rememberWorld(msg.payload);
  } else if (msg.type === 'hello') {
    setTimeout(() => pushMessage(BOT_NAME, 'hello', { text: `Hello back, ${msg.from}!` }), 500);
  } else if (msg.type === 'battle_start' && msg.payload) {
    // join with the company the host's game rolled for the bot
    const bros = (msg.payload.company || []).map((b, i) => ({ key: `bot_${i}`, name: `Bot's ${b.name}`, raw: b.raw, look: b.look }));
    if (!bros.length) return console.log('Bot: battle started, but no company copy was sent');
    const side = msg.payload.clan === BOT_CLAN ? 'ally' : 'enemy';
    setTimeout(() => pushMessage(BOT_NAME, 'battle_join', { battleID: msg.payload.battleID, to: msg.from, bros, side }), 3000);
    console.log(`Bot: joining ${msg.from}'s battle ${side === 'ally' ? 'as an ally' : 'AGAINST them (not in ' + BOT_CLAN + ')'} with ${bros.length} brothers in 3s`);
  } else if (msg.type === 'battle_result' && msg.payload && msg.payload.to === BOT_NAME) {
    const dead = msg.payload.bros.filter((b) => b.dead).map((b) => b.name);
    console.log(`Bot: battle over, ${msg.payload.bros.length - dead.length} survived, fallen: ${dead.join(', ') || 'none'}`);
  } else if (msg.type === 'session_request') {
    // stand in as the host: offer the last world we saw, with the bot's company sitting where the player was
    const info = botWorld
      ? { to: msg.from, seed: botWorld.seed, x: botWorld.x, y: botWorld.y }
      : { to: msg.from, error: "Bot hasn't seen a world yet. Play a campaign for a few seconds first so it learns the seed, then try again." };
    console.log(`Bot: ${msg.from} asked to join, ${botWorld ? 'offering seed ' + botWorld.seed : 'no world known yet'}`);
    if (botWorld) Object.assign(bot, { target: { x: botWorld.x, y: botWorld.y }, seed: botWorld.seed });
    setTimeout(() => pushMessage(BOT_NAME, 'session_info', info), 500);
  } else if (msg.type === 'battle_loot' && msg.payload && msg.payload.to === BOT_NAME) {
    const items = msg.payload.items || [];
    const crowns = items.filter((i) => i.name === 'Crowns').reduce((n, i) => n + (i.amount || 0), 0);
    const names = items.filter((i) => i.name !== 'Crowns').map((i) => i.name);
    console.log(`Bot: got its share of the loot from ${msg.from}: ${names.join(', ') || 'no items'}${crowns ? `, ${crowns} crowns` : ''}`);
  } else if (msg.type === 'battle_view' && msg.payload && msg.payload.to === BOT_NAME) {
    botBattleView(msg.from, msg.payload);
  } else if (msg.type === 'battle_order_error' && msg.payload && msg.payload.to === BOT_NAME) {
    console.log(`Bot: order refused (${msg.payload.text}), ending the turn`);
    if (botBattle.view && botBattle.view.turn) botOrder(msg.from, botBattle.view, { action: 'end' });
  } else if (msg.type === 'join') {
    setTimeout(() => pushMessage(BOT_NAME, 'join', { modVersion: 'bot', gameVersion: 'bot' }), 300);
  }
}

// The bot plays its own brothers in a shared battle: attack an enemy in reach,
// otherwise step towards the nearest enemy once, then end the turn.
const botBattle = { view: null, turnId: null, moved: false, steps: 0 };

function hexDistance(map, ax, ay, bx, by) {
  // square (offset) coordinates to axial, columns offset
  const toAxial = (x, y) => ({ q: x, r: map.oddDown ? y - (x - (x & 1)) / 2 : y - (x + (x & 1)) / 2 });
  const a = toAxial(ax, ay), b = toAxial(bx, by);
  const dq = a.q - b.q, dr = a.r - b.r;
  return (Math.abs(dq) + Math.abs(dr) + Math.abs(dq + dr)) / 2;
}

function botOrder(host, view, order) {
  const payload = Object.assign({ to: host, battleID: view.battleID, key: view.turn.key }, order);
  setTimeout(() => pushMessage(BOT_NAME, 'battle_order', payload), 700);
}

function botBattleView(host, view) {
  botBattle.view = view;
  if (!view.turn) return;
  const t = view.turn, map = view.map;
  const turnId = `${t.key}@${view.round}`;
  if (botBattle.turnId !== turnId) Object.assign(botBattle, { turnId, moved: false, steps: 0 });
  if (++botBattle.steps > 8) return botOrder(host, view, { action: 'end' });

  const enemies = view.units.filter((u) => u.side === 'enemy');
  const enemyAt = (x, y) => enemies.some((e) => e.x === x && e.y === y);
  const attack = t.skills.find((s) => s.attack && s.usable && s.targets.some(([x, y]) => enemyAt(x, y)));
  if (attack) {
    const [x, y] = attack.targets.find(([tx, ty]) => enemyAt(tx, ty));
    console.log(`Bot: ${t.name} uses ${attack.name}`);
    return botOrder(host, view, { action: 'skill', skill: attack.id, x, y });
  }
  if (!botBattle.moved && enemies.length) {
    const nearest = (x, y) => Math.min(...enemies.map((e) => hexDistance(map, x, y, e.x, e.y)));
    const occupied = new Set(view.units.map((u) => `${u.x},${u.y}`));
    let best = null, bestScore = nearest(t.x, t.y);
    for (let y = 0; y < map.h; y++) {
      for (let x = 0; x < map.w; x++) {
        const ch = map.terrain[y * map.w + x];
        if ((ch !== '.' && ch !== '-') || occupied.has(`${x},${y}`)) continue;
        if (hexDistance(map, t.x, t.y, x, y) > 3) continue;
        const score = nearest(x, y);
        if (score < bestScore) { best = { x, y }; bestScore = score; }
      }
    }
    if (best) {
      botBattle.moved = true;
      console.log(`Bot: ${t.name} moves to ${best.x},${best.y}`);
      return botOrder(host, view, { action: 'move', x: best.x, y: best.y });
    }
  }
  console.log(`Bot: ${t.name} ends the turn`);
  botOrder(host, view, { action: 'end' });
}

let botAliveSent = 0;
function botTick() {
  touch(BOT_NAME);
  if (!bot.target) {
    // no world position yet (e.g. the relay restarted mid-battle): still tell games the bot is here
    if (Date.now() - botAliveSent > 5000) { botAliveSent = Date.now(); pushMessage(BOT_NAME, 'alive', {}); }
    return;
  }
  bot.angle += 0.15;
  const r = 250;
  pushMessage(BOT_NAME, 'pos', {
    x: bot.target.x + Math.cos(bot.angle) * r,
    y: bot.target.y + Math.sin(bot.angle) * r,
    seed: bot.seed,
    clan: BOT_CLAN,
    origin: botOrigin,
    baseBrush: '',
    bodyBrush: 'figure_mercenary_02',
  });
}

function messagesSince(since) {
  return messages.filter((m) => m.seq > since);
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (req.method === 'OPTIONS') { cors(res); res.writeHead(204); return res.end(); }

  try {
    if (req.method === 'GET' && url.pathname === '/ping') {
      return sendJSON(res, 200, { ok: true, version: VERSION, time: Date.now() });
    }

    if (req.method === 'POST' && url.pathname === '/join') {
      const body = await readBody(req);
      if (!body.player) return sendJSON(res, 400, { error: 'player required' });
      touch(body.player);
      Object.assign(players.get(body.player), { modVersion: body.modVersion, gameVersion: body.gameVersion });
      // warn about mismatched versions: both players must run the same game and mod versions
      for (const [name, p] of players) {
        if (name === body.player || !p.gameVersion) continue;
        if (p.gameVersion !== body.gameVersion || p.modVersion !== body.modVersion) {
          console.warn(`WARNING: version mismatch between ${name} (${p.gameVersion}, mod ${p.modVersion}) and ${body.player} (${body.gameVersion}, mod ${body.modVersion})`);
        }
      }
      pushMessage(body.player, 'join', { modVersion: body.modVersion, gameVersion: body.gameVersion });
      return sendJSON(res, 200, { ok: true, seq, boot: BOOT, players: activePlayers(), bot: BOT });
    }

    if (req.method === 'POST' && url.pathname === '/send') {
      const body = await readBody(req);
      if (!body.from || !body.type) return sendJSON(res, 400, { error: 'from and type required' });
      touch(body.from);
      const msg = pushMessage(body.from, body.type, body.payload === undefined ? null : body.payload);
      return sendJSON(res, 200, { ok: true, seq: msg.seq });
    }

    if (req.method === 'GET' && url.pathname === '/poll') {
      const player = url.searchParams.get('player');
      let since = parseInt(url.searchParams.get('since') || '0', 10);
      if (since > seq) since = 0; // the client knew an older relay run: send everything from this one
      touch(player);
      const pending = messagesSince(since).filter((m) => m.from !== player);
      if (pending.length) return sendJSON(res, 200, { seq, boot: BOOT, messages: pending });
      // nothing yet: hold the request open until something arrives
      const w = {
        flush() {
          const msgs = messagesSince(since).filter((m) => m.from !== player);
          if (!msgs.length) return;
          clearTimeout(w.timer);
          waiting.delete(w);
          sendJSON(res, 200, { seq, boot: BOOT, messages: msgs });
        },
      };
      w.timer = setTimeout(() => { waiting.delete(w); sendJSON(res, 200, { seq, boot: BOOT, messages: [] }); }, POLL_HOLD_MS);
      req.on('close', () => { clearTimeout(w.timer); waiting.delete(w); });
      waiting.add(w);
      return;
    }

    if (req.method === 'GET' && url.pathname === '/status') {
      return sendJSON(res, 200, { version: VERSION, seq, players: Object.fromEntries(players) });
    }

    sendJSON(res, 404, { error: 'not found' });
  } catch (e) {
    sendJSON(res, 400, { error: String(e.message || e) });
  }
});

// Minimal WebSocket echo on /ws, only so the mod can test whether the game's
// browser supports WebSockets. Handles small unfragmented text frames.
server.on('upgrade', (req, socket) => {
  if (!req.url.startsWith('/ws') || !req.headers['sec-websocket-key']) return socket.destroy();
  const accept = crypto.createHash('sha1')
    .update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11')
    .digest('base64');
  socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
    `Sec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.on('data', (buf) => {
    const opcode = buf[0] & 0x0f;
    if (opcode === 0x8) return socket.end(Buffer.from([0x88, 0x00])); // answer the close frame, then close
    if (opcode !== 0x1) return;                        // only text frames
    let len = buf[1] & 0x7f, off = 2;
    if (len === 126) { len = buf.readUInt16BE(2); off = 4; }
    else if (len === 127) return socket.destroy();     // too big for this test
    const masked = (buf[1] & 0x80) !== 0;
    const mask = masked ? buf.slice(off, off + 4) : null;
    if (masked) off += 4;
    const payload = Buffer.from(buf.slice(off, off + len));
    if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
    console.log(`WebSocket test message received: ${payload.toString()}`);
    const header = payload.length < 126
      ? Buffer.from([0x81, payload.length])
      : Buffer.from([0x81, 126, payload.length >> 8, payload.length & 0xff]);
    socket.write(Buffer.concat([header, payload]));
  });
  socket.on('error', () => {});
});

if (BOT) setInterval(botTick, 1000);

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Battle Brothers Co-op relay v${VERSION} listening on port ${PORT}`);
  console.log(`Same PC: http://127.0.0.1:${PORT}   Other PC on your network: http://<this PC's IP>:${PORT}`);
  if (BOT) console.log(`Bot player enabled (origin: ${BOT_ORIGINS[botOrigin]}, clan: ${BOT_CLAN}). Its company will circle yours once you are on the world map. Pick an origin with --origin=<${Object.keys(BOT_ORIGINS).join('|')}>`);
});
