// Invite codes and saved hosts (v0.16.0): the relay builds a code from its address and the host's
// name, the joiner's game decodes it, keeps a host list and checks each host with /ping.
// Usage: node tests/invite_test.js   (exits non-zero on failure)
const http = require('http'); const vm = require('vm'); const fs = require('fs'); const path = require('path');
const { spawn } = require('child_process');
const root = path.join(__dirname, '..');
const src = fs.readFileSync(path.join(root, 'mod/ui/mods/bb_coop/bb_coop_connection.js'), 'utf8');
const PORT = 19000 + Math.floor(Math.random() * 1000);
const relay = spawn(process.execPath, [path.join(root, 'relay/relay.js'), String(PORT), '--address=https://brave-wolves.trycloudflare.com'], { stdio: 'ignore' });
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
function makeClient(card, cfg) {
  let screen; const saved = [];
  const ctx = { XMLHttpRequest: FakeXHR, setTimeout, clearTimeout, setInterval, clearInterval, console, Math, Date, JSON, encodeURIComponent, decodeURIComponent, Object, parseInt, String,
    $: { trim: (t) => String(t).trim() },
    MSUBackendConnection: function () { this.mSQHandle = null; }, registerScreen: (n, s) => { screen = s; } };
  ctx.MSUBackendConnection.prototype = { isConnected() { return this.mSQHandle !== null; }, onConnection(h) { this.mSQHandle = h; } };
  const sq = { onLog: () => null, onNotify: () => null, onMessage: () => null, getWorldPosition: () => null, setBotEnabled: () => null,
    getHostCard: () => card, setSavedHosts: (t) => saved.push(t) };
  ctx.SQ = { call: (h, fn, arg, cb) => { const r = sq[fn](arg); if (cb) cb(r); } };
  ctx.window = ctx; vm.createContext(ctx); vm.runInContext(src, ctx);
  screen.onConnection({}); screen.mConfig = cfg; screen.saved = saved; return screen;
}
const get = (p) => new Promise((ok) => http.get(`http://127.0.0.1:${PORT}${p}`, (res) => { let d = ''; res.on('data', (c) => d += c); res.on('end', () => ok(JSON.parse(d))); }));
const post = (p, body) => new Promise((ok) => { const r = http.request({ host: '127.0.0.1', port: PORT, path: p, method: 'POST' }, (res) => { let d = ''; res.on('data', (c) => d += c); res.on('end', () => ok(JSON.parse(d))); }); r.end(JSON.stringify(body)); });
const fails = [];
function check(ok, what) { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) fails.push(what); }

setTimeout(async () => {
  await post('/host', { host: 'Ärön', name: "Aaron's company", day: 3, max: 4, protocol: 3, modVersion: '0.16.0', dlcs: ['Wildmen'] });
  const inv = await get('/invite');
  check(/^BB1-[A-Za-z0-9_-]+$/.test(inv.code), 'relay makes a BB1- code: ' + inv.code);
  check(inv.address === 'https://brave-wolves.trycloudflare.com', '--address is used');

  const me = makeClient(null, { playerName: 'Ben', protocol: 3, modVersion: '0.16.0', dlcs: ['Wildmen'], savedHosts: '' });
  const parsed = me.parseInvite(inv.code);
  check(parsed && parsed.url === 'https://brave-wolves.trycloudflare.com' && parsed.host === 'Ärön', 'code decodes to address and host name (non-ASCII too)');
  check(me.parseInvite('100.101.2.3').url === 'http://100.101.2.3:7777', 'plain address gets http:// and :7777');
  check(me.parseInvite('BB1-%%%') === null && me.parseInvite('hello there') === null, 'junk is rejected');

  me.rememberHost(parsed.url, parsed.host);
  me.rememberHost('http://127.0.0.1:' + PORT, '');
  // a tunnel host's new address replaces the old entry with the same name
  me.rememberHost('https://other-words.trycloudflare.com', 'Ärön');
  const list = me.getSavedHosts();
  check(list.length === 2 && list[0].host === 'Ärön' && list[0].url === 'https://other-words.trycloudflare.com', 'same host, new address: one entry, updated');
  check(me.saved.length === 3, 'every change is saved through Squirrel');
  me.forgetHost('https://other-words.trycloudflare.com');
  check(me.getSavedHosts().length === 1, 'remove works');

  await new Promise((ok) => me.pingAddress('http://127.0.0.1:' + PORT, (ping, ms) => {
    check(ping && ping.session && ping.session.host === 'Ärön' && ping.max === 4, 'ping reads the session card');
    check(me.joinProblem(ping) === null, 'compatible host: no problem');
    me.mConfig.dlcs = [];
    check(/Different DLCs/.test(me.joinProblem(ping)), 'different DLCs are reported');
    me.mConfig.dlcs = ['Wildmen']; me.mConfig.protocol = 1;
    check(/different co-op version/.test(me.joinProblem(ping)), 'different protocol is reported');
    ok();
  }));
  await new Promise((ok) => me.pingAddress('http://127.0.0.1:1', (ping) => { check(ping === null, 'an offline host answers null'); ok(); }));

  const changed = await post('/address', { address: '100.80.1.2' });
  check(changed.address === `http://100.80.1.2:${PORT}` && me.parseInvite(changed.code).url === changed.address, 'host can set the address from the game');
  relay.kill();
  console.log(fails.length ? `FAILED: ${fails.length}` : 'PASS');
  process.exit(fails.length ? 1 : 0);
}, 500);
