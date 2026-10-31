#!/usr/bin/env node
// Battle Brothers Co-op relay. No dependencies: needs only Node.js 16+.
// Usage: node relay.js [port] [--bot]   (default port 7777)
//   --bot  adds a fake second player ("Bot") whose company circles yours on the
//          world map and answers hellos, so you can test alone.
// Both players point the mod's "Relay URL" setting at this machine.

'use strict';
const http = require('http');
const crypto = require('crypto');
const { URL } = require('url');

const VERSION = '0.2.0';
const args = process.argv.slice(2);
const BOT = args.includes('--bot');
const PORT = parseInt(args.find((a) => /^\d+$/.test(a)) || process.env.PORT || '7777', 10);
const POLL_HOLD_MS = 8000;      // must stay below the mod's 10s request timeout
const MAX_MESSAGES = 500;       // keep a short history in memory

let seq = 0;
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
      if (data.length > 1e6) { reject(new Error('body too large')); req.destroy(); }
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
  if (type !== 'pos') console.log(`[${new Date().toISOString()}] ${from}: ${type} ${JSON.stringify(payload)}`);
  for (const w of [...waiting]) w.flush();
  if (BOT && from !== BOT_NAME) botHear(msg);
  return msg;
}

// ---- fake second player for solo testing ----
const BOT_NAME = 'Bot';
const bot = { target: null, seed: '', angle: 0 };

function botHear(msg) {
  if (msg.type === 'pos' && msg.payload) {
    bot.target = { x: msg.payload.x, y: msg.payload.y };
    bot.seed = msg.payload.seed || '';
  } else if (msg.type === 'hello') {
    setTimeout(() => pushMessage(BOT_NAME, 'hello', { text: `Hello back, ${msg.from}!` }), 500);
  } else if (msg.type === 'join') {
    setTimeout(() => pushMessage(BOT_NAME, 'join', { modVersion: 'bot', gameVersion: 'bot' }), 300);
  }
}

function botTick() {
  if (!bot.target) return;
  touch(BOT_NAME);
  bot.angle += 0.15;
  const r = 250;
  pushMessage(BOT_NAME, 'pos', {
    x: bot.target.x + Math.cos(bot.angle) * r,
    y: bot.target.y + Math.sin(bot.angle) * r,
    seed: bot.seed,
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
      return sendJSON(res, 200, { ok: true, seq, players: activePlayers() });
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
      const since = parseInt(url.searchParams.get('since') || '0', 10);
      touch(player);
      const pending = messagesSince(since).filter((m) => m.from !== player);
      if (pending.length) return sendJSON(res, 200, { seq, messages: pending });
      // nothing yet: hold the request open until something arrives
      const w = {
        flush() {
          const msgs = messagesSince(since).filter((m) => m.from !== player);
          if (!msgs.length) return;
          clearTimeout(w.timer);
          waiting.delete(w);
          sendJSON(res, 200, { seq, messages: msgs });
        },
      };
      w.timer = setTimeout(() => { waiting.delete(w); sendJSON(res, 200, { seq, messages: [] }); }, POLL_HOLD_MS);
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
  if (BOT) console.log('Bot player enabled: its company will circle yours once you are on the world map.');
});
