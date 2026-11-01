#!/usr/bin/env node
// Battle Brothers Co-op relay. No dependencies: needs only Node.js 16+.
// Usage: node relay.js [port] [--bot] [--tunnel] [--password=...] [--address=...]   (default port 7777)
//   --tunnel  starts cloudflared's free tunnel and builds the invite code from its address
//   --bot  adds a fake second player ("Bot") whose company circles yours on the
//          world map and answers hellos, so you can test alone.
// Both players point the mod's "Relay URL" setting at this machine.

'use strict';
const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { URL } = require('url');
const os = require('os');
const { spawn } = require('child_process');

const VERSION = '0.39.0';
// Bumped only when the messages between games change; games with a different protocol can't play together
const PROTOCOL = 7;
const MAX_PLAYERS = 8;
const args = process.argv.slice(2);
const BOT = args.includes('--bot');
// --password=... (or the BBCOOP_PASSWORD environment variable): players must enter it to connect
const pwArg = args.find((a) => a.startsWith('--password='));
let PASSWORD = (pwArg ? pwArg.slice(11) : process.env.BBCOOP_PASSWORD || '').trim();
function passwordOK(given) {
  if (!PASSWORD) return true;
  const a = crypto.createHash('sha256').update(String(given || '')).digest();
  const b = crypto.createHash('sha256').update(PASSWORD).digest();
  return crypto.timingSafeEqual(a, b);
}
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

// The host's session card (v0.14.0): sent by the host's game on this PC, shown to anyone who pings
let hostCard = null;   // { host, name, company, day, max, modVersion, gameVersion, protocol, dlcs, time }

// ---- invite codes (v0.16.0) ----
// The address friends use to reach this relay: --address=..., BBCOOP_ADDRESS, or set from the
// host's game (Ctrl+I). Without one, the relay suggests its Tailscale and home network addresses.
const addrArg = args.find((a) => a.startsWith('--address='));
let publicAddress = normalizeAddress(addrArg ? addrArg.slice(10) : process.env.BBCOOP_ADDRESS || '');

function normalizeAddress(a) {
  a = String(a || '').trim().replace(/\/+$/, '');
  if (!a) return '';
  if (a.indexOf('://') === -1) {
    a = 'http://' + a;
    if (!/:\d+$/.test(a)) a += ':' + PORT;
  }
  return a;
}

function detectedAddresses() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const i of list || []) {
      if (i.family !== 'IPv4' && i.family !== 4) continue;
      if (i.internal) continue;
      const [a, b] = i.address.split('.').map(Number);
      if (a === 100 && b >= 64 && b <= 127) out.push({ kind: 'tailscale', url: `http://${i.address}:${PORT}` });
      else if (a === 10 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31)) out.push({ kind: 'home network', url: `http://${i.address}:${PORT}` });
    }
  }
  return out;
}

// ---- free tunnel (v0.17.0) ----
// --tunnel starts cloudflared's quick tunnel next to the relay and uses its https address, so the
// host needs one window. cloudflared-windows-amd64.exe (or cloudflared.exe) goes in the relay
// folder, or cloudflared on the PATH. A new tunnel run means a new address, so a new invite code.
const TUNNEL = args.includes('--tunnel') || process.env.BBCOOP_TUNNEL === '1';
let tunnelAddress = '';
let tunnelState = TUNNEL ? 'starting' : 'off'; // off | starting | up | missing | down
let tunnelProc = null, tunnelRestarts = 0;

function findCloudflared() {
  if (process.env.BBCOOP_CLOUDFLARED) return process.env.BBCOOP_CLOUDFLARED;
  for (const name of ['cloudflared-windows-amd64.exe', 'cloudflared.exe', 'cloudflared']) {
    const p = path.join(__dirname, name);
    if (fs.existsSync(p)) return p;
  }
  return 'cloudflared'; // maybe on the PATH
}

// cloudflared prints its address in a box on stderr: "https://some-words.trycloudflare.com"
function tunnelAddressIn(text) {
  const m = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/i.exec(text);
  return m ? m[0] : '';
}

function startTunnel() {
  const exe = findCloudflared();
  tunnelState = 'starting';
  console.log('Starting the free tunnel (cloudflared)...');
  try {
    tunnelProc = spawn(exe, ['tunnel', '--no-autoupdate', '--url', `http://localhost:${PORT}`], { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
  } catch (e) {
    tunnelMissing(e);
    return;
  }
  const onData = (chunk) => {
    const found = tunnelAddressIn(String(chunk));
    if (found && found !== tunnelAddress) {
      tunnelAddress = found;
      tunnelState = 'up';
      console.log(`Tunnel is up: ${tunnelAddress}`);
      printInvite();
    }
  };
  tunnelProc.stdout.on('data', onData);
  tunnelProc.stderr.on('data', onData);
  tunnelProc.on('error', tunnelMissing);
  tunnelProc.on('exit', (code) => {
    if (tunnelState === 'missing') return;
    tunnelProc = null;
    tunnelAddress = '';
    tunnelState = 'down';
    if (shuttingDown) return;
    if (++tunnelRestarts > 5) { console.log(`The tunnel stopped (code ${code}) and keeps failing. Restart this window to try again.`); return; }
    console.log(`The tunnel stopped (code ${code}). Starting it again in 5 seconds; your invite code will change.`);
    setTimeout(startTunnel, 5000);
  });
}

function tunnelMissing(e) {
  tunnelState = 'missing';
  tunnelProc = null;
  console.log(`Could not start cloudflared (${e && e.code || e}). Download cloudflared-windows-amd64.exe from https://github.com/cloudflare/cloudflared/releases/latest and put it in ${__dirname}`);
}

let shuttingDown = false;
function stopTunnel() {
  shuttingDown = true;
  if (tunnelProc) { try { tunnelProc.kill(); } catch (e) {} }
}
process.on('exit', stopTunnel);
process.on('SIGINT', () => { stopTunnel(); process.exit(0); });
process.on('SIGTERM', () => { stopTunnel(); process.exit(0); });

function bestAddress() {
  if (publicAddress) return publicAddress;
  if (tunnelAddress) return tunnelAddress;
  const found = detectedAddresses();
  const ts = found.find((f) => f.kind === 'tailscale');
  return ts ? ts.url : '';
}

// "BB1-" + the address and the host's name, so a joiner's list knows whose it is
function inviteCode(address, host) {
  if (!address) return '';
  const raw = encodeURIComponent(address) + '|' + encodeURIComponent(host || '');
  return 'BB1-' + Buffer.from(raw, 'ascii').toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function printInvite() {
  const code = inviteCode(bestAddress(), hostCard && hostCard.host);
  if (code) console.log(`Invite code for your friends: ${code}   (address ${bestAddress()})`);
  else if (tunnelState === 'starting') console.log('Invite code: waiting for the tunnel address...');
  else console.log('No invite code yet: no address friends can reach was found. Use start-host.bat (free tunnel) or Tailscale, or press Ctrl+I in the game and paste your address.');
}

function isLocal(req) {
  const a = req.socket.remoteAddress || '';
  return a === '127.0.0.1' || a === '::1' || a === '::ffff:127.0.0.1';
}

function maxPlayers() {
  const m = hostCard ? parseInt(hostCard.max, 10) : MAX_PLAYERS;
  return Math.max(2, Math.min(MAX_PLAYERS, isNaN(m) ? MAX_PLAYERS : m));
}

// Players who count towards the cap: connected in the last 30s, the test bot not included
function countedPlayers() {
  return activePlayers().filter((n) => n !== BOT_NAME);
}

function publicCard() {
  if (!hostCard) return null;
  const { host, name, company, day, modVersion, gameVersion, protocol, dlcs } = hostCard;
  return { host, name, company, day, modVersion, gameVersion, protocol, dlcs, max: maxPlayers() };
}

function activePlayers() {
  const cutoff = Date.now() - 30000;
  return [...players.entries()].filter(([, p]) => p.lastSeen >= cutoff).map(([n]) => n);
}

// World updates replace the sender's previous one, so the history doesn't fill up with
// stale copies of the whole world
const LATEST_ONLY = new Set(['world_full', 'world_parties', 'world_time', 'company_save', 'company_restore']);

function pushMessage(from, type, payload) {
  const msg = { seq: ++seq, from, type, payload, time: Date.now() };
  if (LATEST_ONLY.has(type)) {
    const to = payload && payload.to;
    for (let i = messages.length - 1; i >= 0; i--) {
      const m = messages[i];
      if (m.from === from && m.type === type && ((m.payload && m.payload.to) === to)) messages.splice(i, 1);
    }
  }
  messages.push(msg);
  if (messages.length > MAX_MESSAGES) messages.shift();
  if (type === 'world_full' && payload) {
    console.log(`[${new Date().toISOString()}] ${from}: world_full (${(payload.parties || []).length} parties, ${(payload.locations || []).length} locations, day ${payload.day})`);
  } else if (type !== 'pos' && type !== 'world_parties' && type !== 'world_time' && type !== 'busy') {
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
const bot = { target: null, seed: '', angle: 0, following: null };

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
function saveBotWorld(force) {
  const now = Date.now();
  if (!force && now - botWorldSaved < 10000) return;
  botWorldSaved = now;
  try { fs.writeFileSync(BOT_STATE_FILE, JSON.stringify(botWorld)); } catch (e) {}
}
function rememberWorld(p) {
  if (!p.seed) return;
  const full = botWorld && botWorld.seed === p.seed ? botWorld.full : null;
  botWorld = { seed: p.seed, x: p.x, y: p.y, origin: botOrigin, full };
  saveBotWorld(false);
}

// Shared world test: the bot keeps the last whole world a host sent ("world_full") and plays
// host with it for players who joined the bot's world. Its parties stand still; what a joiner
// destroys is taken out of the copy, so the round trip can be tested with one game.
const botFollowers = new Map(); // player -> last time they asked for the world
const playerPos = new Map();    // player -> { x, y } from their position updates
const botOffers = new Set();     // trade offers the bot sent that wait for an answer
const botAmbushed = new Map();  // party id -> time the bot last made it attack
const botContractAsked = new Set(); // clanmates the bot already shared its test contract with
const botHelping = new Map();       // player -> contract id the bot helps them with
let botEscort = null;                // { to, until, x, y } while the bot "escorts a caravan" itself
let botWorldSent = 0, botPartiesSent = 0;
function botWorldMessage(msg) {
  const p = msg.payload || {};
  if (msg.type === 'world_full') {
    if (!botWorld || p.seed !== botWorld.seed) botWorld = Object.assign(botWorld || {}, { seed: p.seed, origin: botOrigin });
    botWorld.full = p;
    saveBotWorld(false);
    return true;
  }
  if (p.to !== BOT_NAME) return msg.type.startsWith('world_');
  const full = botWorld && botWorld.full;
  if (msg.type === 'world_ambush') {
    console.log(`Bot: ${p.n} caught the bot's company on ${msg.from}'s map (a player would fight it now)`);
  } else if (msg.type === 'world_request') {
    if (!full) { console.log(`Bot: ${msg.from} asked for the world, but no host has sent one yet`); return true; }
    botFollowers.set(msg.from, Date.now());
    console.log(`Bot: hosting the world for ${msg.from} (${full.parties.length} parties, ${full.locations.length} locations)`);
    pushMessage(BOT_NAME, 'world_full', Object.assign({}, full, { to: msg.from }));
  } else if (msg.type === 'world_party_destroyed' && full) {
    const i = full.parties.findIndex((x) => x.id === p.id);
    if (i >= 0) { console.log(`Bot: ${msg.from} destroyed ${full.parties[i].n}`); full.parties.splice(i, 1); saveBotWorld(true); }
  } else if (msg.type === 'world_party_troops' && full) {
    const party = full.parties.find((x) => x.id === p.id);
    if (party) { console.log(`Bot: ${party.n} survived ${msg.from}'s attack with ${p.t.length} of ${party.t.length} troops`); party.t = p.t; saveBotWorld(true); }
  } else if (msg.type === 'world_location_destroyed' && full) {
    const i = full.locations.findIndex((x) => x.k === p.k && x.ty === p.ty);
    if (i >= 0) { console.log(`Bot: ${msg.from} destroyed ${full.locations[i].n}`); full.locations.splice(i, 1); saveBotWorld(true); }
  } else if (msg.type === 'world_location_troops' && full) {
    const loc = full.locations.find((x) => x.k === p.k && x.ty === p.ty);
    if (loc) { console.log(`Bot: ${loc.n} held against ${msg.from} with ${p.t.length} defenders left`); loc.t = p.t; saveBotWorld(true); }
  }
  return true;
}
// Hostile parties near a joiner walk towards them and attack when they catch up, the way
// the host's AI would (the host's game sends "world_ambush" when its party reaches the ghost)
function botHunt(full, now) {
  for (const [name] of botFollowers) {
    const pos = playerPos.get(name);
    if (!pos) continue;
    for (const party of full.parties) {
      if (!party.hp) continue;
      const dx = pos.x - party.x, dy = pos.y - party.y;
      const dist = Math.hypot(dx, dy);
      if (dist > 500) continue;
      const last = botAmbushed.get(party.id) || 0;
      if (now - last < 60000) continue;
      if (dist <= 60) {
        botAmbushed.set(party.id, now);
        console.log(`Bot: ${party.n} attacks ${name}`);
        pushMessage(BOT_NAME, 'world_ambush', { to: name, id: party.id, n: party.n });
      } else {
        const step = Math.min(dist - 40, 45);
        party.x = Math.round(party.x + dx / dist * step);
        party.y = Math.round(party.y + dy / dist * step);
      }
    }
  }
}

function botWorldTick() {
  const full = botWorld && botWorld.full;
  if (!full || !botFollowers.size) return;
  const now = Date.now();
  for (const [name] of botFollowers) {
    const p = players.get(name);
    if (!p || now - p.lastSeen > 60000) botFollowers.delete(name);
  }
  if (now - botWorldSent >= 30000) {
    botWorldSent = now;
    for (const [name] of botFollowers) pushMessage(BOT_NAME, 'world_full', Object.assign({}, full, { to: name }));
  } else if (now - botPartiesSent >= 2000) {
    botPartiesSent = now;
    botHunt(full, now);
    const flat = [];
    for (const party of full.parties) flat.push(party.id, party.x, party.y);
    for (const [name] of botFollowers) pushMessage(BOT_NAME, 'world_parties', { to: name, seed: full.seed, p: flat });
  }
}

function botHear(msg) {
  if (msg.type.startsWith('world_') && botWorldMessage(msg)) return;
  if (msg.type === 'pos' && msg.payload) {
    playerPos.set(msg.from, { x: msg.payload.x, y: msg.payload.y });
    // shared contract test: the first time a player shows up in the bot's clan, the bot shares one
    if (msg.payload.clan === BOT_CLAN && !botContractAsked.has(msg.from)) {
      botContractAsked.add(msg.from);
      setTimeout(() => pushMessage(BOT_NAME, 'contract_share', { to: msg.from, id: 'bot_1', title: "The Bot's Test Contract", employer: 'Botsford', objectives: ['Wait about ten seconds.'], dest: '' }), 3000);
      console.log(`Bot: ${msg.from} is in ${BOT_CLAN}; sharing a test contract`);
    }
    // escorts (v0.19.0): a player the bot helps is tied to a caravan; the bot rides along
    const escort = typeof msg.payload.escort === 'string' ? msg.payload.escort : '';
    const following = escort !== '' && botHelping.get(msg.from) === escort;
    if (following !== (bot.following === msg.from)) {
      bot.following = following ? msg.from : null;
      console.log(following ? `Bot: travelling with ${msg.from}'s caravan` : `Bot: ${msg.from}'s escort is over`);
    }
    bot.target = { x: msg.payload.x, y: msg.payload.y };
    bot.seed = msg.payload.seed || '';
    rememberWorld(msg.payload);
  } else if (msg.type === 'chat' && msg.payload && typeof msg.payload.text === 'string') {
    const replies = ['Aye.', 'For coin and glory!', `Heard you, ${msg.from}.`, 'Watch the flanks.', 'Bot agrees.'];
    setTimeout(() => pushMessage(BOT_NAME, 'chat', { text: replies[Math.floor(Math.random() * replies.length)] }), 1200);
  } else if (msg.type === 'hello') {
    setTimeout(() => pushMessage(BOT_NAME, 'hello', { text: `Hello back, ${msg.from}! Here are some crowns.` }), 500);
    // a gift, to test receiving a trade offer
    const id = `Bot_gift_${Date.now()}`;
    botOffers.add(id);
    setTimeout(() => pushMessage(BOT_NAME, 'trade_offer', { to: msg.from, id, items: [], crowns: 100, bros: [] }), 1000);
  } else if (msg.type === 'trade_offer' && msg.payload && msg.payload.to === BOT_NAME) {
    // the bot takes anything, except a few crowns on their own (to test a declined offer)
    const p = msg.payload;
    const stingy = !p.items.length && !p.bros.length && p.crowns < 10;
    const what = [p.crowns ? `${p.crowns} crowns` : '', ...p.items.map((i) => i.name), ...p.bros.map((b) => b.name)].filter(Boolean).join(', ');
    console.log(`Bot: ${msg.from} offers ${what || 'nothing'}; ${stingy ? 'declining (only a few crowns)' : 'accepting'}`);
    setTimeout(() => pushMessage(BOT_NAME, 'trade_answer', { to: msg.from, id: p.id, accepted: !stingy }), 2000);
  } else if (msg.type === 'trade_confirm' && msg.payload && msg.payload.to === BOT_NAME) {
    console.log(`Bot: ${msg.from} handed over the goods`);
  } else if (msg.type === 'trade_answer' && msg.payload && msg.payload.to === BOT_NAME) {
    const known = botOffers.delete(msg.payload.id);
    if (msg.payload.accepted) pushMessage(BOT_NAME, known ? 'trade_confirm' : 'trade_cancel', { to: msg.from, id: msg.payload.id });
    console.log(`Bot: ${msg.from} ${msg.payload.accepted ? 'accepted' : 'declined'} the bot's gift`);
  } else if (msg.type === 'contract_share' && msg.payload && msg.payload.to === BOT_NAME) {
    console.log(`Bot: ${msg.from} shares the contract "${msg.payload.title}"; helping`);
    botHelping.set(msg.from, msg.payload.id);
    setTimeout(() => pushMessage(BOT_NAME, 'contract_join', { to: msg.from, id: msg.payload.id, join: true }), 2000);
  } else if (msg.type === 'contract_pay' && msg.payload && msg.payload.to === BOT_NAME) {
    console.log(`Bot: ${msg.from} paid the bot ${msg.payload.crowns} of ${msg.payload.total} crowns for "${msg.payload.title}"`);
  } else if (msg.type === 'contract_done' && msg.payload && msg.payload.to === BOT_NAME) {
    console.log(`Bot: ${msg.from}'s contract "${msg.payload.title}" ${msg.payload.cancelled ? 'was broken' : 'is finished'}`);
    if (botHelping.get(msg.from) === msg.payload.id) botHelping.delete(msg.from);
    if (bot.following === msg.from) bot.following = null;
  } else if (msg.type === 'contract_join' && msg.payload && msg.payload.to === BOT_NAME && msg.payload.id === 'bot_1') {
    if (!msg.payload.join) { console.log(`Bot: ${msg.from} won't help with the test contract`); return; }
    console.log(`Bot: ${msg.from} helps with the test contract; paying their share in 10s, then a 15s caravan escort`);
    // contract tracker (v0.22.0): the helper's top-right contract panel should show these lines
    const track = (objective) => pushMessage(BOT_NAME, 'contract_track', { to: msg.from, id: 'bot_1', title: "The Bot's Test Contract", helpers: 1, lists: [
      { title: 'Objectives', fixed: true, items: [{ icon: 'ui/icons/money.png', text: objective }] },
      { title: 'Payment', fixed: true, items: [{ icon: 'ui/icons/money.png', text: 'Receive [color=#135213]300[/color] Crowns on completion' }] },
    ] });
    setTimeout(() => track('Wait about ten seconds'), 500);
    setTimeout(() => track('Escort the caravan for fifteen seconds'), 11000);
    setTimeout(() => pushMessage(BOT_NAME, 'contract_pay', { to: msg.from, id: 'bot_1', title: "The Bot's Test Contract", crowns: 150, total: 300 }), 10000);
    // escort test: the bot's company walks off in a straight line as if tied to a caravan; the
    // helper's game should move their company along with it, and let go when the contract ends
    setTimeout(() => {
      const start = playerPos.get(msg.from) || bot.target || { x: 0, y: 0 };
      botEscort = { to: msg.from, until: Date.now() + 15000, x: start.x + 60, y: start.y };
      console.log(`Bot: escorting a caravan for 15s; ${msg.from}'s company should travel with it`);
    }, 11000);
    setTimeout(() => {
      botEscort = null;
      pushMessage(BOT_NAME, 'contract_done', { to: msg.from, id: 'bot_1', title: "The Bot's Test Contract", cancelled: false });
    }, 27000);
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
  botWorldTick();
  if (!bot.target) {
    // no world position yet (e.g. the relay restarted mid-battle): still tell games the bot is here
    if (Date.now() - botAliveSent > 5000) { botAliveSent = Date.now(); pushMessage(BOT_NAME, 'alive', {}); }
    return;
  }
  let x, y, escort = '';
  if (botEscort && Date.now() < botEscort.until) {
    botEscort.x += 12; // the caravan walks east
    x = botEscort.x; y = botEscort.y; escort = 'bot_1';
  } else {
    // circle the player's company, close by while travelling with their caravan
    bot.angle += 0.15;
    const r = bot.following ? 45 : 250;
    x = bot.target.x + Math.cos(bot.angle) * r;
    y = bot.target.y + Math.sin(bot.angle) * r;
  }
  pushMessage(BOT_NAME, 'pos', {
    x, y, escort,
    seed: bot.seed,
    strength: 120, // so the host's enemies go after the bot's company too
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
      return sendJSON(res, 200, {
        ok: true, version: VERSION, protocol: PROTOCOL, time: Date.now(), password: !!PASSWORD,
        players: countedPlayers().length, max: maxPlayers(), session: publicCard(),
      });
    }

    // The host's game on this PC describes its session (only accepted from this PC).
    // A password typed in the game's Host window replaces the one start-relay.bat asked for.
    // The host's invite code and the addresses it could be built from (only for the host PC)
    if (req.method === 'GET' && url.pathname === '/invite') {
      if (!isLocal(req)) return sendJSON(res, 403, { error: 'only the host PC can see the invite' });
      const address = bestAddress();
      return sendJSON(res, 200, { address, code: inviteCode(address, hostCard && hostCard.host), detected: detectedAddresses(), set: !!publicAddress, tunnel: tunnelState });
    }

    // The host pastes the address friends use (e.g. the tunnel URL) in the game
    if (req.method === 'POST' && url.pathname === '/address') {
      if (!isLocal(req)) return sendJSON(res, 403, { error: 'only the host PC can set the address' });
      const body = await readBody(req);
      publicAddress = normalizeAddress(body.address);
      printInvite();
      const address = bestAddress();
      return sendJSON(res, 200, { address, code: inviteCode(address, hostCard && hostCard.host), detected: detectedAddresses(), set: !!publicAddress, tunnel: tunnelState });
    }

    if (req.method === 'POST' && url.pathname === '/host') {
      if (!isLocal(req)) return sendJSON(res, 403, { error: 'only the host PC can set the session' });
      const body = await readBody(req);
      if (!body.host) return sendJSON(res, 400, { error: 'host required' });
      const first = !hostCard || hostCard.name !== body.name || hostCard.max !== body.max;
      hostCard = {
        host: String(body.host).slice(0, 40), name: String(body.name || `${body.host}'s company`).slice(0, 60),
        company: String(body.company || '').slice(0, 60), day: body.day | 0, max: body.max | 0,
        modVersion: body.modVersion, gameVersion: body.gameVersion, protocol: body.protocol | 0,
        dlcs: Array.isArray(body.dlcs) ? body.dlcs.slice(0, 50) : [], time: Date.now(),
      };
      if (typeof body.password === 'string' && body.password.trim() !== '' && body.password.trim() !== PASSWORD) {
        PASSWORD = body.password.trim();
        console.log('Session password set from the host\'s game.');
      }
      if (first) { console.log(`Hosting "${hostCard.name}" for ${hostCard.host}, up to ${maxPlayers()} players.`); printInvite(); }
      return sendJSON(res, 200, { ok: true, max: maxPlayers(), password: !!PASSWORD, code: inviteCode(bestAddress(), hostCard.host), tunnel: tunnelState });
    }

    // everything except /ping needs the session password, when one is set
    if (url.pathname !== '/ping' && url.pathname !== '/ws' && !passwordOK(url.searchParams.get('key'))) {
      return sendJSON(res, 401, { error: 'wrong password' });
    }

    if (req.method === 'POST' && url.pathname === '/join') {
      const body = await readBody(req);
      if (!body.player) return sendJSON(res, 400, { error: 'player required' });
      // a different protocol can't play with the host; old games send none
      if (hostCard && body.player !== hostCard.host && (body.protocol | 0) !== hostCard.protocol) {
        return sendJSON(res, 409, { error: 'version', hostVersion: hostCard.modVersion, protocol: hostCard.protocol });
      }
      // session full: players already connected may come back, nobody new past the host's limit
      const counted = countedPlayers();
      if (body.player !== BOT_NAME && !counted.includes(body.player) && counted.length >= maxPlayers()) {
        console.log(`${body.player} was turned away: session full (${counted.length}/${maxPlayers()}).`);
        return sendJSON(res, 403, { error: 'full', players: counted.length, max: maxPlayers() });
      }
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
      return sendJSON(res, 200, { ok: true, seq, boot: BOOT, players: activePlayers(), bot: BOT, max: maxPlayers(), protocol: PROTOCOL });
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
      return sendJSON(res, 200, { version: VERSION, protocol: PROTOCOL, seq, max: maxPlayers(), session: publicCard(), players: Object.fromEntries(players) });
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
  if (TUNNEL) startTunnel();
  printInvite();
  console.log(PASSWORD ? 'Session password is set: players must enter it in the Multiplayer window or Mod Options.' : 'No session password: anyone who can reach this relay can join.');
  if (BOT) console.log(`Bot player enabled (origin: ${BOT_ORIGINS[botOrigin]}, clan: ${BOT_CLAN}). Its company will circle yours once you are on the world map. Pick an origin with --origin=<${Object.keys(BOT_ORIGINS).join('|')}>`);
});
