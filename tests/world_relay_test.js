// Shared world through the relay: world updates replace older copies, and the bot keeps the
// last world a host sent and hosts it for a joiner (destroyed parties and camps are removed).
// Usage: node tests/world_relay_test.js   (exits non-zero on failure). Runs a relay copy in a temp folder.
const http = require('http'); const fs = require('fs'); const os = require('os'); const path = require('path');
const { spawn } = require('child_process');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bbcoop-'));
fs.copyFileSync(path.join(__dirname, '..', 'relay', 'relay.js'), path.join(dir, 'relay.js'));
const PORT = 18000 + Math.floor(Math.random() * 1000);
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
const full = (n) => ({ seed: '123', day: 7, parties: [{ id: '11', x: 100, y: 100, n: 'Brigand Raiders', hp: true, t: [[1, 0, 10, 0, '', 5]] }, { id: '12', x: 300, y: 300, n: 'Caravan', hp: false, t: [] }, { id: '13', x: 900, y: 600, n: 'Wolves', hp: true, t: [] }], locations: [{ k: 500, at: false, ty: 'location.bandit_camp', n: 'Camp ' + n, t: [] }], settlements: [] });

(async () => {
  await sleep(500);
  await req('POST', '/join', { player: 'A', modVersion: 'x', gameVersion: 'y' });
  await send('A', 'pos', { x: 100, y: 100, seed: '123' });
  await send('A', 'world_full', full(1));
  await send('A', 'world_full', full(2));
  let poll = await req('GET', '/poll?player=C&since=0');
  const fulls = poll.messages.filter((m) => m.type === 'world_full' && m.from === 'A');
  check(fulls.length === 1 && fulls[0].payload.locations[0].n === 'Camp 2', 'only the newest world_full is kept');

  await req('POST', '/join', { player: 'B', modVersion: 'x', gameVersion: 'y' });
  const since = poll.seq;
  await send('B', 'world_request', { to: 'Bot' });
  await sleep(300);
  poll = await req('GET', `/poll?player=B&since=${since}`);
  const fromBot = poll.messages.find((m) => m.type === 'world_full' && m.from === 'Bot');
  check(fromBot && fromBot.payload.to === 'B' && fromBot.payload.parties.length === 3, 'bot hosts the stored world for a joiner');

  await send('B', 'world_party_destroyed', { to: 'Bot', id: '11' });
  await send('B', 'world_location_troops', { to: 'Bot', k: 500, ty: 'location.bandit_camp', t: [[2, 0, 5, 0, '', 6]] });
  await sleep(2500);
  poll = await req('GET', `/poll?player=B&since=${poll.seq}`);
  const parties = poll.messages.filter((m) => m.type === 'world_parties' && m.from === 'Bot');
  check(parties.length === 1 && parties[0].payload.p.join(',') === '12,300,300,13,900,600', 'destroyed party is gone from the bot\'s positions (and only the latest positions are kept)');
  const state = JSON.parse(fs.readFileSync(path.join(dir, 'bot-state.json'), 'utf8'));
  check(state.full.parties.length === 2 && state.full.locations[0].t.length === 1, 'bot-state.json keeps the changed world');
  // hunting: B stands 300 units from the wolves (45 units per 2s); they walk over and attack
  await send('B', 'pos', { x: 900, y: 900, seed: '123' });
  let ambush = null;
  for (let i = 0; i < 25 && !ambush; i++) {
    await sleep(1000);
    poll = await req('GET', `/poll?player=B&since=${poll.seq}`);
    ambush = poll.messages.find((m) => m.type === 'world_ambush' && m.payload.to === 'B');
  }
  check(ambush && ambush.payload.id === '13', 'hostile party walks to the joiner and attacks');
  console.log('PASS');
  relay.kill(); process.exit(0);
})().catch((e) => { console.log('FAIL', e); console.log(out); relay.kill(); process.exit(1); });
