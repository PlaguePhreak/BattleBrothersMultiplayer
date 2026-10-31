// Host settings (v0.14.0): the host's game sends its session card to its own relay,
// /ping shows it, the relay turns players away past the host's limit or with another protocol.
// Usage: node tests/host_session_test.js   (exits non-zero on failure)
const http = require('http'); const vm = require('vm'); const fs = require('fs'); const path = require('path');
const { spawn } = require('child_process');
const root = path.join(__dirname, '..');
const src = fs.readFileSync(path.join(root, 'mod/ui/mods/bb_coop/bb_coop_connection.js'), 'utf8');
const PORT = 18000 + Math.floor(Math.random() * 1000);
const relay = spawn(process.execPath, [path.join(root, 'relay/relay.js'), String(PORT)], { stdio: 'ignore' });
const seen = [];
function record(line) { console.log(line); seen.push(line); }
function FakeXHR() { this.readyState = 0; this.status = 0; this.responseText = ''; this.headers = {}; }
FakeXHR.prototype.open = function (m, u) { this.m = m; this.u = new URL(u); };
FakeXHR.prototype.setRequestHeader = function (k, v) { this.headers[k] = v; };
FakeXHR.prototype.send = function (body) {
  const self = this;
  const r = http.request({ host: this.u.hostname, port: this.u.port, path: this.u.pathname + this.u.search, method: this.m, headers: this.headers }, (res) => {
    let d = ''; res.on('data', (c) => d += c);
    res.on('end', () => { self.status = res.statusCode; self.responseText = d; self.readyState = 4; self.onreadystatechange(); });
  });
  r.on('error', () => { self.status = 0; self.readyState = 4; self.onreadystatechange(); });
  if (body) r.write(body); r.end();
};
function makeClient(name, card) {
  let screen;
  const ctx = { XMLHttpRequest: FakeXHR, setTimeout, clearTimeout, setInterval, clearInterval, console, Math, Date, JSON, encodeURIComponent, Object, parseInt,
    MSUBackendConnection: function () { this.mSQHandle = null; }, registerScreen: (n, s) => { screen = s; } };
  ctx.MSUBackendConnection.prototype = { isConnected() { return this.mSQHandle !== null; }, onConnection(h) { this.mSQHandle = h; } };
  const sq = { onLog: (t) => record(`[${name} log] ${t}`), onNotify: (t) => record(`[${name} POPUP] ${t}`),
    onMessage: () => null, getWorldPosition: () => null, setBotEnabled: () => null, getHostCard: () => card };
  ctx.SQ = { call: (h, fn, arg, cb) => { const r = sq[fn](arg); if (cb) cb(r); } };
  ctx.window = ctx; vm.createContext(ctx); vm.runInContext(src, ctx);
  screen.onConnection({}); return screen;
}
function get(p) {
  return new Promise((ok) => http.get(`http://127.0.0.1:${PORT}${p}`, (res) => { let d = ''; res.on('data', (c) => d += c); res.on('end', () => ok({ status: res.statusCode, data: JSON.parse(d) })); }));
}
const cfg = (n, extra) => Object.assign({ relayURL: `http://127.0.0.1:${PORT}`, playerName: n, modVersion: '0.14.0', gameVersion: '1.5.1.7', protocol: 1, dlcs: [] }, extra);
const card = { host: 'Aaron', name: "Aaron's company", company: 'Iron Wolves', day: 34, max: 3, modVersion: '0.14.0', gameVersion: '1.5.1.7', protocol: 1, dlcs: [] };
const fails = [];
function check(ok, what) { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) fails.push(what); }

setTimeout(async () => {
  makeClient('Aaron', card).start(cfg('Aaron', { hosting: true, maxPlayers: 3, password: 'secret' }));
  await new Promise((r) => setTimeout(r, 800));
  const ping = await get('/ping');
  check(ping.data.session && ping.data.session.name === "Aaron's company" && ping.data.session.day === 34, '/ping shows the session card');
  check(ping.data.max === 3 && ping.data.password === true, '/ping shows max 3 and the password from the Host window');
  check(!('password' in ping.data.session), 'the card never carries the password');
  makeClient('Ben', null).start(cfg('Ben', { password: 'secret' }));
  makeClient('Cid', null).start(cfg('Cid', { password: 'secret' }));
  await new Promise((r) => setTimeout(r, 800));
  makeClient('Dan', null).start(cfg('Dan', { password: 'secret' }));
  makeClient('Old', null).start(cfg('Old', { password: 'secret', protocol: 0, modVersion: '0.13.0' }));
  makeClient('Eve', null).start(cfg('Eve', { password: 'wrong' }));
  await new Promise((r) => setTimeout(r, 800));
  check(seen.some((l) => l.includes('[Ben POPUP] Joined co-op session')), 'Ben joins');
  check(seen.some((l) => l.includes('[Cid POPUP] Joined co-op session')), 'Cid joins (3 / 3)');
  check(seen.some((l) => l.includes('[Dan POPUP] The session is full (3 / 3 players)')), 'Dan is turned away: full');
  check(seen.some((l) => l.includes('[Old POPUP] The host runs co-op mod 0.14.0')), 'an older protocol is turned away');
  check(seen.some((l) => l.includes('[Eve POPUP] Wrong session password')), 'a wrong password is refused');
  relay.kill();
  console.log(fails.length ? `FAILED: ${fails.length}` : 'PASS');
  process.exit(fails.length ? 1 : 0);
}, 500);
