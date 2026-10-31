// Built-in tunnel (v0.17.0): relay.js --tunnel starts cloudflared, reads its https address,
// builds the invite code from it, and starts it again (new address) when it stops.
// A fake cloudflared stands in for the real one. Usage: node tests/tunnel_test.js
const http = require('http'); const fs = require('fs'); const os = require('os'); const path = require('path');
const { spawn } = require('child_process');
const root = path.join(__dirname, '..');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'bbcoop-tunnel-'));
const fake = path.join(dir, 'cloudflared');
// first run: prints an address after 300ms and exits after 1.5s; later runs keep a new address
fs.writeFileSync(path.join(dir, 'runs'), '0');
fs.writeFileSync(fake, `#!${process.execPath}
const fs = require('fs'); const f = ${JSON.stringify(path.join(dir, 'runs'))};
const n = Number(fs.readFileSync(f, 'utf8')) + 1; fs.writeFileSync(f, String(n));
setTimeout(() => process.stderr.write('INF |  https://run-' + n + '-words.trycloudflare.com  |\\n'), 300);
setTimeout(() => process.exit(n === 1 ? 1 : 0), n === 1 ? 1500 : 60000);
`);
fs.chmodSync(fake, 0o755);
const PORT = 20000 + Math.floor(Math.random() * 1000);
const relay = spawn(process.execPath, [path.join(root, 'relay/relay.js'), String(PORT), '--tunnel'], { stdio: 'ignore', env: Object.assign({}, process.env, { BBCOOP_CLOUDFLARED: fake }) });
const get = (p) => new Promise((ok) => http.get(`http://127.0.0.1:${PORT}${p}`, (res) => { let d = ''; res.on('data', (c) => d += c); res.on('end', () => ok(JSON.parse(d))); }));
const decode = (code) => decodeURIComponent(Buffer.from(code.slice(4).replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('ascii').split('|')[0]);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const fails = [];
function check(ok, what) { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) fails.push(what); }
(async () => {
  await wait(150);
  const early = await get('/invite');
  check(early.tunnel === 'starting' || early.tunnel === 'up', 'tunnel is starting: ' + early.tunnel);
  await wait(700);
  const up = await get('/invite');
  check(up.tunnel === 'up' && up.address === 'https://run-1-words.trycloudflare.com', 'tunnel address is used: ' + up.address);
  check(up.code && decode(up.code) === up.address, 'invite code holds the tunnel address');
  await wait(7000); // the first run exits after 1.5s, the relay starts it again 5s later
  const again = await get('/invite');
  check(again.address === 'https://run-2-words.trycloudflare.com' && again.code !== up.code, 'restarted tunnel: new address, new code');
  relay.kill('SIGTERM');
  await wait(300);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log(fails.length ? `FAILED: ${fails.length}` : 'PASS');
  process.exit(fails.length ? 1 : 0);
})();
