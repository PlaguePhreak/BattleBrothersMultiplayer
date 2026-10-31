// Simulates two game clients running the mod's JS layer against a real relay.
// Usage: node tests/js_client_harness.js   (exits non-zero on failure)
const http = require('http'); const vm = require('vm'); const fs = require('fs'); const path = require('path');
const { spawn } = require('child_process');
const root = path.join(__dirname, '..');
const src = fs.readFileSync(path.join(root, 'mod/ui/mods/bb_coop/bb_coop_connection.js'), 'utf8');
const PORT = 17000 + Math.floor(Math.random() * 1000);
const relay = spawn(process.execPath, [path.join(root, 'relay/relay.js'), String(PORT)], { stdio: 'ignore' });
const seen = [];
function record(line) { console.log(line); seen.push(line); }
function FakeXHR(){ this.readyState=0; this.status=0; this.responseText=''; this.headers={}; }
FakeXHR.prototype.open=function(m,u){this.m=m;this.u=new URL(u);};
FakeXHR.prototype.setRequestHeader=function(k,v){this.headers[k]=v;};
FakeXHR.prototype.send=function(body){ const self=this;
  const r=http.request({host:this.u.hostname,port:this.u.port,path:this.u.pathname+this.u.search,method:this.m,headers:this.headers},res=>{let d='';res.on('data',c=>d+=c);res.on('end',()=>{self.status=res.statusCode;self.responseText=d;self.readyState=4;self.onreadystatechange();});});
  r.on('error',()=>{self.status=0;self.readyState=4;self.onreadystatechange();}); if(body)r.write(body); r.end(); };
function makeClient(name, pos){
  let screen; const ctx = { XMLHttpRequest: FakeXHR, WebSocket: globalThis.WebSocket, setTimeout, clearTimeout, setInterval, clearInterval, console, Math, Date, JSON, encodeURIComponent, Object,
    MSUBackendConnection: function(){ this.mSQHandle=null; },
    registerScreen: (n, s) => { screen = s; } };
  ctx.MSUBackendConnection.prototype = { isConnected(){return this.mSQHandle!==null;}, onConnection(h){this.mSQHandle=h;} };
  const sq = { onLog: t=>record(`[${name} log] ${t}`), onNotify: t=>record(`[${name} POPUP] ${t}`),
    onMessage: m=>record(`[${name} recv] ${m.from} ${m.type} ${JSON.stringify(m.payload)}`), getWorldPosition: ()=>pos(), setBotEnabled: ()=>null };
  ctx.SQ = { call: (h, fn, arg, cb) => { const r = sq[fn](arg); if (cb) cb(r); } };
  vm.createContext(ctx); vm.runInContext(src, ctx);
  screen.onConnection({}); return screen;
}
setTimeout(run, 500);
function run() {
let ax=100;
const A = makeClient('A', ()=>({x:ax+=5,y:200}));
const B = makeClient('B', ()=>null);
const cfg = n => ({relayURL:'http://127.0.0.1:' + PORT + '/', playerName:n, modVersion:'0.1.0', gameVersion:'1.5.1.7'});
A.start(cfg('A')); setTimeout(()=>B.start(cfg('B')), 300);
setTimeout(()=>B.sendHello({type:'hello', payload:{text:'Hello from B'}}), 1500);
setTimeout(() => {
  relay.kill();
  const expect = ['[A POPUP] Relay reachable', '[B POPUP] Joined co-op session. Other players: A', '[B recv] A pos', '[A recv] B hello {"text":"Hello from B"}', 'WebSocket test: OK', '[B POPUP] Hello sent.'];
  const missing = expect.filter(e => !seen.some(l => l.includes(e)));
  if (missing.length) { console.error('FAIL, missing:', missing); process.exit(1); }
  console.log('PASS'); process.exit(0);
}, 3500);
}
