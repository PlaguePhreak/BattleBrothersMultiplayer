// Real battlefield for joiners (v0.18.0), JS side: views go to the game, the old battle panel
// stays away while the game shows the real battlefield, and comes back for our turns in fallback.
// Usage: node tests/mirror_panel_test.js
const vm = require('vm'); const fs = require('fs'); const path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'mod/ui/mods/bb_coop/bb_coop_connection.js'), 'utf8');

// jQuery stand-in: every call chains, nothing renders
function chain() {
  const f = function () { return p; };
  const p = new Proxy(f, { get: (t, k) => (k === 'width' || k === 'height') ? () => 800 : chain(), apply: () => p });
  return p;
}
const $ = new Proxy(function () { return chain(); }, { get: () => chain() });

let screen; const toSQ = [];
const ctx = { console, Math, Date, JSON, Object, setTimeout, clearTimeout, setInterval, clearInterval, encodeURIComponent, $, jQuery: $,
  MSUBackendConnection: function () { this.mSQHandle = null; }, registerScreen: (n, s) => { screen = s; } };
ctx.MSUBackendConnection.prototype = { isConnected() { return this.mSQHandle !== null; }, onConnection(h) { this.mSQHandle = h; } };
ctx.SQ = { call: (h, fn, arg) => { toSQ.push([fn, arg]); } };
ctx.window = ctx; vm.createContext(ctx); vm.runInContext(src, ctx);
screen.onConnection({});
screen.mConfig = { playerName: 'Ben' };

let failed = 0;
const check = (ok, what) => { console.log((ok ? 'ok   ' : 'FAIL ') + what); if (!ok) failed++; };
const view = (turn) => ({ to: 'Ben', battleID: 'Aaron_1', round: 1, map: { w: 2, h: 2, oddDown: true, terrain: '....', levels: '0000' },
  units: [{ x: 0, y: 0, name: 'Hans', hp: 50, hpMax: 50, side: 'mine', id: 7 }, { x: 1, y: 1, name: '?', hp: 40, hpMax: 40, side: 'enemy', hid: true, id: 9 }], turn });
const turn = { key: 'Ben_0', name: 'Hans', x: 0, y: 0, ap: 9, fatigue: 0, fatigueMax: 100, skills: [] };

// old behaviour without a scene: panel opens, the game still gets the view
let handled = screen.handleBattleMessage({ from: 'Aaron', type: 'battle_view', payload: view(null) });
check(handled === true && screen.mBattlePanel, 'no scene: the battle panel opens');
check(toSQ.some(c => c[0] === 'onMessage' && c[1].type === 'battle_view'), 'the view is passed to the game too');

// the scene arrives: panel goes away, message continues to the game
handled = screen.handleBattleMessage({ from: 'Aaron', type: 'battle_scene', payload: { to: 'Ben', battleID: 'Aaron_1', setup: {} } });
check(handled === false, 'battle_scene goes on to the game');
check(!screen.mBattlePanel && screen.mMirror === true, 'scene: the panel closes');

// views while mirrored: no panel, even on our turn
screen.handleBattleMessage({ from: 'Aaron', type: 'battle_view', payload: view(turn) });
check(!screen.mBattlePanel, 'real battlefield: no panel on our turn');

// no panel ever while mirrored, not even when the game reports trouble; the action strip instead
screen.setBattleMirror({ on: true, fallback: true });
check(!screen.mBattlePanel, 'mirrored: the panel never comes back');
screen.setMirrorTurn({ turn: turn, busy: false, selected: null });
check(!!screen.mMirrorStrip, 'our turn off the turn bar: action strip shows');
screen.setMirrorTurn(null);
check(!screen.mMirrorStrip, 'action strip goes away');
screen.setMirrorTurn({ turn: turn, busy: false, selected: null });

// order errors reach the game
toSQ.length = 0;
screen.handleBattleMessage({ from: 'Aaron', type: 'battle_order_error', payload: { to: 'Ben', text: 'No path to that tile.' } });
check(toSQ.some(c => c[0] === 'onMessage' && c[1].type === 'battle_order_error'), 'order errors are passed to the game');

// the battle ends: result closes everything, later views and mirror-off don't reopen it
screen.handleBattleMessage({ from: 'Aaron', type: 'battle_result', payload: { to: 'Ben', battleID: 'Aaron_1', bros: [] } });
screen.setBattleMirror({ on: false, fallback: false });
screen.handleBattleMessage({ from: 'Aaron', type: 'battle_view', payload: view(null) });
check(!screen.mBattlePanel, 'after the result the panel stays closed');
check(!screen.mMirrorStrip, 'after the result the action strip is gone');

// turn notice in the top right
screen.setTurnNotice("It's your turn");
check(!!screen.mTurnNotice, 'turn notice shows');
screen.setTurnNotice(null);
check(!screen.mTurnNotice, 'turn notice goes away');

console.log(failed ? 'FAILED: ' + failed : 'PASS');
process.exit(failed ? 1 : 0);
