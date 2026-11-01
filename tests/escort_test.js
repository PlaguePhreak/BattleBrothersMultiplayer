// Caravan escorts with the relay bot (v0.19.0): when a player the bot helps is tied to a caravan
// ("pos" carries escort = contract id) the bot rides close by, and the bot's own test contract
// walks its company off with escort = 'bot_1' so a helper's game can be checked moving along.
// Usage: node tests/escort_test.js   (exits non-zero on failure, takes about 15s).
const http = require('http'); const fs = require('fs'); const os = require('os'); const path = require('path');
const { spawn } = require('child_process');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bbcoop-'));
fs.copyFileSync(path.join(__dirname, '..', 'relay', 'relay.js'), path.join(dir, 'relay.js'));
const PORT = 19000 + Math.floor(Math.random() * 1000);
const relay = spawn(process.execPath, [path.join(dir, 'relay.js'), String(PORT), '--bot'], { stdio: ['ignore', 'pipe', 'inherit'] });
let out = ''; relay.stdout.on('data', (d) => { out += d; });
function req(method, p, body) {
  return new Promise((res, rej) => {
    const r = http.request({ host: '127.0.0.1', port: PORT, path: p, method, headers: { 'Content-Type': 'application/json' } }, (resp) => {
      let d = ''; resp.on('data', (c) => d += c); resp.on('end', () => res(JSON.parse(d)));
    });
    r.on('error', rej); if (body) r.write(JSON.stringify(body)); r.end();
  });
}
const send = (from, type, payload) => req('POST', '/send', { from, type, payload });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function check(cond, text) { if (!cond) { console.log('FAIL: ' + text); console.log(out); relay.kill(); process.exit(1); } console.log('ok: ' + text); }
async function botPositions(since) {
  const poll = await req('GET', `/poll?player=A&since=${since}`);
  return { seq: poll.seq, pos: poll.messages.filter((m) => m.type === 'pos' && m.from === 'Bot').map((m) => m.payload) };
}

(async () => {
  await sleep(500);
  await req('POST', '/join', { player: 'A', modVersion: 'x', gameVersion: 'y' });
  await send('A', 'pos', { x: 1000, y: 1000, seed: '1', clan: 'A clan', escort: '' });
  // A's contract: the bot helps, then A is tied to a caravan
  await send('A', 'contract_share', { to: 'Bot', id: 'c1', title: 'Escort', employer: '', objectives: [], dest: '' });
  await sleep(2500);
  let r = await botPositions(0);
  await send('A', 'pos', { x: 1000, y: 1000, seed: '1', clan: 'A clan', escort: 'c1' });
  await sleep(2200);
  r = await botPositions(r.seq);
  const near = r.pos.length > 0 && r.pos.every((p) => Math.hypot(p.x - 1000, p.y - 1000) <= 50);
  check(near, 'bot rides next to a player escorting a caravan for a contract it helps with');
  check(out.includes("travelling with A's caravan"), 'relay window says the bot travels with the caravan');
  await send('A', 'pos', { x: 1000, y: 1000, seed: '1', clan: 'A clan', escort: '' });
  await sleep(2200);
  r = await botPositions(r.seq);
  check(r.pos.length > 0 && Math.hypot(r.pos[r.pos.length - 1].x - 1000, r.pos[r.pos.length - 1].y - 1000) > 200, 'bot circles wide again when the escort is over');
  // the bot's test contract: A helps; 11s later the bot escorts a caravan with escort = 'bot_1'
  await send('A', 'contract_join', { to: 'Bot', id: 'bot_1', join: true });
  await sleep(13500);
  r = await botPositions(r.seq);
  const esc = r.pos.filter((p) => p.escort === 'bot_1');
  check(esc.length >= 2 && esc[esc.length - 1].x > esc[0].x, 'bot\'s own escort sends escort = bot_1 and moves its company');
  relay.kill(); process.exit(0);
})().catch((e) => { console.log('FAIL: ' + e); console.log(out); relay.kill(); process.exit(1); });
