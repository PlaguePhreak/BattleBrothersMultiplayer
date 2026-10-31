// Battle Brothers Co-op: network layer.
// Squirrel has no sockets, but the game's UI browser can make HTTP requests,
// so all traffic to the relay goes through here. ES5 only (old embedded browser).

var BBCoopConnection = function ()
{
	MSUBackendConnection.call(this);
	this.mConfig = null;
	this.mSessionId = 0;      // bumped on each start() so old poll loops stop
	this.mLastSeq = 0;
	this.mLastPos = null;
	this.mLastPosSent = 0;
	this.mPollTimer = null;
	this.mPosTimer = null;
};

BBCoopConnection.prototype = Object.create(MSUBackendConnection.prototype);
Object.defineProperty(BBCoopConnection.prototype, 'constructor', {
	value: BBCoopConnection,
	enumerable: false,
	writable: true
});

BBCoopConnection.prototype.log = function (_text)
{
	if (this.mSQHandle !== null) SQ.call(this.mSQHandle, 'onLog', _text);
};

// Logs on the Squirrel side and shows an on-screen toast (if enabled in settings)
BBCoopConnection.prototype.notify = function (_text)
{
	if (this.mJoinWaiting && /Could not reach|failed|password/.test(_text)) this.setJoinStatus(_text, true);
	if (this.mSQHandle !== null) SQ.call(this.mSQHandle, 'onNotify', _text);
};

// Small self-contained notification stack, top right, visible on every screen
BBCoopConnection.prototype.showToast = function (_text)
{
	var stack = $('#bbcoop-toasts');
	if (stack.length === 0)
	{
		stack = $('<div id="bbcoop-toasts"/>').css({
			position: 'fixed', top: '9rem', right: '2rem', width: '40rem',
			'z-index': 100000, 'pointer-events': 'none'
		}).appendTo($('body'));
	}
	var toast = $('<div class="text-font-normal"/>').text('Co-op: ' + _text).css({
		background: 'rgba(0, 0, 0, 0.85)', border: '0.1rem solid #8a6d3b', color: '#e8dcc0',
		padding: '0.8rem 1.2rem', 'margin-bottom': '0.6rem', 'font-size': '1.6rem'
	}).appendTo(stack);
	setTimeout(function () { toast.fadeOut(600, function () { toast.remove(); }); }, 6000);
};

BBCoopConnection.prototype.sendHello = function (_msg)
{
	var self = this;
	if (this.mConfig === null) { this.notify('Not connected to the relay yet.'); return; }
	this.send(_msg, function (_ok)
	{
		self.notify(_ok ? 'Hello sent.' : 'Sending hello failed. Is the relay running?');
	});
};

BBCoopConnection.prototype.request = function (_method, _path, _body, _callback)
{
	var xhr = new XMLHttpRequest();
	var done = false;
	xhr.onreadystatechange = function ()
	{
		if (xhr.readyState !== 4 || done) return;
		done = true;
		var data = null;
		try { data = JSON.parse(xhr.responseText); } catch (e) {}
		_callback(xhr.status, data);
	};
	if (_path !== '/ping' && this.mConfig.password)
		_path += (_path.indexOf('?') === -1 ? '?' : '&') + 'key=' + encodeURIComponent(this.mConfig.password);
	xhr.open(_method, this.mConfig.relayURL.replace(/\/+$/, '') + _path, true);
	xhr.timeout = 10000;
	xhr.ontimeout = function () { if (!done) { done = true; _callback(0, null); } };
	// text/plain keeps this a "simple" request, so no CORS preflight is needed
	if (_body !== null) xhr.setRequestHeader('Content-Type', 'text/plain');
	xhr.send(_body !== null ? JSON.stringify(_body) : null);
};

// Called from Squirrel on main menu load and from the "run connection test" keybind
BBCoopConnection.prototype.start = function (_config)
{
	var self = this;
	this.mConfig = _config;
	this.mSessionId++;
	var session = this.mSessionId;
	if (this.mPollTimer !== null) { clearTimeout(this.mPollTimer); this.mPollTimer = null; }
	if (this.mPosTimer !== null) { clearInterval(this.mPosTimer); this.mPosTimer = null; }

	this.log('Connecting to relay ' + _config.relayURL + ' as ' + _config.playerName);
	var started = new Date().getTime();
	this.request('GET', '/ping', null, function (_status, _data)
	{
		if (session !== self.mSessionId) return;
		if (_status !== 200 || _data === null)
		{
			self.notify('Could not reach the co-op relay at ' + _config.relayURL + ' (status ' + _status + '). Is relay.js running?');
			return;
		}
		var ms = new Date().getTime() - started;
		self.notify('Relay reachable (' + ms + ' ms round trip, relay v' + _data.version + ').');
		self.join(session);
		self.testWebSocket();
	});
};

BBCoopConnection.prototype.join = function (_session)
{
	var self = this;
	this.request('POST', '/join', {
		player: this.mConfig.playerName,
		modVersion: this.mConfig.modVersion,
		gameVersion: this.mConfig.gameVersion
	}, function (_status, _data)
	{
		if (_session !== self.mSessionId) return;
		if (_status === 401)
		{
			self.notify(self.mConfig.password ? 'Wrong session password for this relay.' : 'This relay needs a session password. Enter it in the Multiplayer window or Mod Options.');
			return;
		}
		if (_status !== 200 || _data === null)
		{
			self.notify('Joining the relay failed (status ' + _status + ').');
			return;
		}
		self.mLastSeq = _data.seq;
		self.mBoot = _data.boot || null;
		SQ.call(self.mSQHandle, 'setBotEnabled', _data.bot === true);
		var others = _data.players.filter(function (p) { return p !== self.mConfig.playerName; });
		self.notify('Joined co-op session. Other players: ' + (others.length ? others.join(', ') : 'none yet'));
		self.poll(_session);
		if (self.mJoinWaiting) self.requestSession();
		self.mPosTimer = setInterval(function () { self.sendPosition(_session); }, 1000);
	});
};

// Long-poll: the relay holds the request until a message arrives or ~8s pass (under the 10s request timeout)
BBCoopConnection.prototype.poll = function (_session)
{
	var self = this;
	if (_session !== this.mSessionId) return;
	var path = '/poll?player=' + encodeURIComponent(this.mConfig.playerName) + '&since=' + this.mLastSeq;
	this.request('GET', path, null, function (_status, _data)
	{
		if (_session !== self.mSessionId) return;
		var delay = 0;
		if (_status === 200 && _data !== null && _data.boot && self.mBoot && _data.boot !== self.mBoot)
		{
			// the relay restarted: its message numbers start over, so fetch everything from the new run
			self.mBoot = _data.boot;
			self.mLastSeq = 0;
			self.notify('The relay restarted. Reconnected.');
			self.mPollTimer = setTimeout(function () { self.poll(_session); }, 0);
			return;
		}
		if (_status === 200 && _data !== null)
		{
			self.mPollFails = 0;
			if (self.mRelayDown) { self.mRelayDown = false; self.notify('Connection to the relay is back.'); }
			self.mLastSeq = _data.seq;
			for (var i = 0; i < _data.messages.length; i++)
			{
				var msg = _data.messages[i];
				if (msg.from === self.mConfig.playerName) continue;
				// world updates can be big: don't hand someone else's to the game
				if (msg.type.indexOf('world_') === 0 && msg.payload && msg.payload.to && msg.payload.to !== self.mConfig.playerName) continue;
				self.notePlayer(msg);
				if (self.handleBattleMessage(msg)) continue;
				SQ.call(self.mSQHandle, 'onMessage', msg);
			}
		}
		else
		{
			delay = 3000; // relay down or timed out: back off a bit
			self.mPollFails = (self.mPollFails || 0) + 1;
			if (self.mPollFails >= 3 && !self.mRelayDown) { self.mRelayDown = true; self.notify('Lost the connection to the relay. Retrying...'); }
		}
		self.mPollTimer = setTimeout(function () { self.poll(_session); }, delay);
	});
};

BBCoopConnection.prototype.send = function (_msg, _callback)
{
	var self = this;
	if (this.mConfig === null) return;
	this.request('POST', '/send', {
		from: this.mConfig.playerName,
		type: _msg.type,
		payload: _msg.payload
	}, function (_status)
	{
		if (_status !== 200) self.log('Send failed (status ' + _status + ')');
		if (_callback) _callback(_status === 200);
	});
};

BBCoopConnection.prototype.sendPosition = function (_session)
{
	var self = this;
	if (_session !== this.mSessionId || this.mSQHandle === null) return;
	SQ.call(this.mSQHandle, 'getWorldPosition', null, function (_pos)
	{
		var now = new Date().getTime();
		if (_pos === null || _pos === undefined)
		{
			// in battle or in a menu: a heartbeat so the other players know we are still here
			if (now - self.mLastPosSent >= 5000) { self.mLastPosSent = now; self.send({ type: 'alive', payload: {} }); }
			return;
		}
		// send when the company moved, and at least every 5s so the other side knows we're still here
		var moved = self.mLastPos === null || Math.abs(self.mLastPos.x - _pos.x) >= 1 || Math.abs(self.mLastPos.y - _pos.y) >= 1;
		if (!moved && now - self.mLastPosSent < 5000) return;
		self.mLastPos = _pos;
		self.mLastPosSent = now;
		self.send({ type: 'pos', payload: _pos });
	});
};

// Not used for gameplay yet; tells us whether we can switch from polling to WebSockets later
BBCoopConnection.prototype.testWebSocket = function ()
{
	var self = this;
	if (typeof WebSocket === 'undefined')
	{
		this.log('WebSocket test: WebSocket is not available in this browser.');
		return;
	}
	var url = this.mConfig.relayURL.replace(/^http/, 'ws').replace(/\/+$/, '') + '/ws';
	var ws;
	try { ws = new WebSocket(url); }
	catch (e) { this.log('WebSocket test: could not create socket: ' + e); return; }
	var timer = setTimeout(function () { self.log('WebSocket test: timed out.'); try { ws.close(); } catch (e) {} }, 5000);
	ws.onopen = function () { ws.send('bbcoop-ws-test'); };
	ws.onmessage = function (_e)
	{
		clearTimeout(timer);
		self.log('WebSocket test: OK (echo "' + _e.data + '").');
		ws.close();
	};
	ws.onerror = function () { clearTimeout(timer); self.log('WebSocket test: error while connecting to ' + url); };
};

// ---------------------------------------------------------------------------
// Battle panel (shared battles part 2): when our brothers fight in someone else's
// battle, the host sends a view of the battlefield on every turn change. On our
// brothers' turns we pick a skill and a tile here, and the order goes back to the host.

// Returns true when the message was handled here (not passed on to Squirrel)
BBCoopConnection.prototype.handleBattleMessage = function (_msg)
{
	var p = _msg.payload;
	var forMe = p && typeof p === 'object' && p.to === this.mConfig.playerName;
	if (_msg.type === 'chat')
	{
		if (p && typeof p.text === 'string') this.addChatLine(_msg.from, p.text);
		return true;
	}
	if (_msg.type === 'battle_view')
	{
		if (forMe) this.showBattleView(_msg.from, p);
		return true;
	}
	if (_msg.type === 'battle_order_error')
	{
		if (forMe) { this.mBattleBusy = false; this.setBattleStatus(p.text, true); this.renderBattleSidebar(); }
		return true;
	}
	if (_msg.type === 'session_info')
	{
		if (forMe) this.onSessionInfo(_msg.from, p);
		return true;
	}
	if (_msg.type === 'battle_result' && forMe) this.closeBattlePanel();
	return false;
};

BBCoopConnection.prototype.showBattleView = function (_host, _view)
{
	this.mBattle = { host: _host, view: _view, skill: null };
	this.mBattleBusy = false;
	if (this.mBattlePanel === undefined || this.mBattlePanel === null) this.createBattlePanel();
	if (_view.turn !== null && this.mBattleHidden) this.setBattleHidden(false); // our turn: bring it up
	this.renderBattleMap();
	this.renderBattleSidebar();
	this.setBattleStatus(_view.turn !== null ? 'Your turn: ' + _view.turn.name : 'Waiting for ' + (_view.waitingFor || 'the next turn') + '...', false);
};

BBCoopConnection.prototype.createBattlePanel = function ()
{
	var self = this;
	var panel = $('<div id="bbcoop-battle"/>').css({
		position: 'fixed', left: '0', top: '0', right: '0', bottom: '0', 'z-index': 99000,
		background: 'rgba(10, 8, 5, 0.94)', color: '#e8dcc0', 'font-size': '1.5rem'
	}).appendTo($('body'));
	this.mBattleMap = $('<div/>').css({ position: 'absolute', left: '1rem', top: '1rem', bottom: '1rem', right: '36rem' }).appendTo(panel);
	this.mBattleSide = $('<div class="text-font-normal"/>').css({
		position: 'absolute', top: '1rem', bottom: '1rem', right: '1rem', width: '33rem',
		border: '0.1rem solid #8a6d3b', padding: '1rem', background: 'rgba(0,0,0,0.6)', overflow: 'auto'
	}).appendTo(panel);
	this.mBattleReopen = $('<div class="text-font-normal">Co-op battle</div>').css({
		position: 'fixed', left: '2rem', top: '9rem', 'z-index': 99000, display: 'none', cursor: 'pointer',
		background: 'rgba(0,0,0,0.85)', border: '0.1rem solid #8a6d3b', padding: '0.6rem 1rem', 'font-size': '1.6rem'
	}).appendTo($('body')).click(function () { self.setBattleHidden(false); });
	this.mBattlePanel = panel;
	this.mBattleHidden = false;
};

BBCoopConnection.prototype.setBattleHidden = function (_hidden)
{
	this.mBattleHidden = _hidden;
	this.mBattlePanel.css('display', _hidden ? 'none' : 'block');
	this.mBattleReopen.css('display', _hidden ? 'block' : 'none');
};

BBCoopConnection.prototype.closeBattlePanel = function ()
{
	if (this.mBattlePanel) { this.mBattlePanel.remove(); this.mBattleReopen.remove(); }
	this.mBattlePanel = null;
	this.mBattle = null;
};

BBCoopConnection.prototype.setBattleStatus = function (_text, _isError)
{
	this.mBattleStatus = { text: _text, error: _isError };
	if (this.mBattleStatusEl) this.mBattleStatusEl.text(_text).css('color', _isError ? '#e07060' : '#e8dcc0');
};

BBCoopConnection.prototype.battleTileCenter = function (_x, _y, _s, _oddDown)
{
	var shift = (_x % 2 === 1) ? (_oddDown ? 0.5 : -0.5) : 0;
	var h = Math.sqrt(3) * _s;
	return { x: _s + _x * 1.5 * _s, y: h / 2 + (_y + shift + (_oddDown ? 0 : 0.5)) * h };
};

BBCoopConnection.prototype.renderBattleMap = function ()
{
	var self = this;
	var view = this.mBattle.view, map = view.map;
	var area = this.mBattleMap;
	area.empty();
	var w = area.width() || (window.innerWidth * 0.7), h = area.height() || (window.innerHeight * 0.9);
	var s = Math.min(w / (1.5 * map.w + 0.5), h / (Math.sqrt(3) * (map.h + 0.5)));
	var d = Math.max(4, Math.floor(s * 1.7));

	var unitAt = {};
	for (var i = 0; i < view.units.length; i++) unitAt[view.units[i].x + ',' + view.units[i].y] = view.units[i];
	var targets = {};
	if (this.mBattle.skill !== null)
		for (var t = 0; t < this.mBattle.skill.targets.length; t++) targets[this.mBattle.skill.targets[t][0] + ',' + this.mBattle.skill.targets[t][1]] = true;

	var colors = { '.': ['#3e4a2a', '#4d5a33', '#5d6a3c', '#6d7a46'], '-': ['#36566a'], '~': ['#203650'], '#': ['#1c1a17'] };
	for (var y = 0; y < map.h; y++)
	{
		for (var x = 0; x < map.w; x++)
		{
			var idx = y * map.w + x;
			var ch = map.terrain.charAt(idx);
			if (ch === ' ') continue;
			var level = parseInt(map.levels.charAt(idx), 10) || 0;
			var pal = colors[ch] || colors['.'];
			var c = this.battleTileCenter(x, y, s, map.oddDown);
			var key = x + ',' + y;
			var u = unitAt[key];
			var tile = $('<div/>').css({
				position: 'absolute', left: (c.x - d / 2) + 'px', top: (c.y - d / 2) + 'px', width: d + 'px', height: d + 'px',
				'border-radius': '50%', background: pal[Math.min(level, pal.length - 1)], 'box-sizing': 'border-box',
				border: targets[key] ? '0.25rem solid #f0d060' : '0.1rem solid rgba(0,0,0,0.35)',
				color: '#fff', 'font-size': Math.max(8, Math.floor(d * 0.32)) + 'px', 'text-align': 'center', 'line-height': d + 'px',
				overflow: 'hidden', cursor: 'pointer'
			});
			if (u)
			{
				var unitColor = u.side === 'mine' ? '#3f8f3f' : (u.side === 'ally' ? '#3a6fb0' : '#a83a32');
				tile.css({ background: unitColor, border: u.active ? '0.3rem solid #ffffff' : (targets[key] ? '0.25rem solid #f0d060' : '0.1rem solid #000') });
				var initials = u.name.split(' ').map(function (p) { return p.charAt(0); }).join('').substr(0, 2);
				tile.text(initials);
			}
			(function (_x, _y, _u)
			{
				tile.click(function () { self.onBattleTileClicked(_x, _y, _u); });
				tile.mouseenter(function ()
				{
					if (self.mBattleHoverEl) self.mBattleHoverEl.text(_u ? _u.name + ' (' + _u.side + '): ' + _u.hp + ' / ' + _u.hpMax + ' HP' : '');
				});
			})(x, y, u);
			area.append(tile);
		}
	}
};

BBCoopConnection.prototype.renderBattleSidebar = function ()
{
	var self = this;
	var side = this.mBattleSide;
	if (!side || !this.mBattle) return;
	var view = this.mBattle.view, turn = view.turn;
	side.empty();
	$('<div/>').text(this.mBattle.host + "'s battle, round " + view.round).css({ 'font-size': '2rem', color: '#d8b56a', 'margin-bottom': '0.8rem' }).appendTo(side);
	this.mBattleStatusEl = $('<div/>').css({ 'margin-bottom': '0.8rem', 'min-height': '2rem' }).appendTo(side);
	if (this.mBattleStatus) this.setBattleStatus(this.mBattleStatus.text, this.mBattleStatus.error);

	var button = function (_label, _enabled, _onClick, _selected)
	{
		var b = $('<div/>').text(_label).css({
			padding: '0.5rem 0.8rem', margin: '0.3rem 0', border: '0.1rem solid ' + (_selected ? '#f0d060' : '#8a6d3b'),
			background: _selected ? 'rgba(240,208,96,0.2)' : 'rgba(255,255,255,0.05)', color: _enabled ? '#e8dcc0' : '#777',
			cursor: _enabled ? 'pointer' : 'default'
		});
		if (_enabled) b.click(_onClick);
		return b.appendTo(side);
	};

	if (turn !== null)
	{
		$('<div/>').text(turn.name + ': ' + turn.ap + ' AP, fatigue ' + turn.fatigue + ' / ' + turn.fatigueMax).css('margin-bottom', '0.6rem').appendTo(side);
		$('<div/>').text('Click a tile to move, or pick a skill and then a highlighted tile.').css({ color: '#a89c80', 'margin-bottom': '0.6rem' }).appendTo(side);
		for (var i = 0; i < turn.skills.length; i++)
		{
			(function (_skill)
			{
				var label = _skill.name + ' (' + _skill.ap + ' AP, ' + _skill.fat + ' fat)';
				var usable = _skill.usable && !self.mBattleBusy && (!_skill.targeted || _skill.targets.length > 0);
				var selected = self.mBattle.skill !== null && self.mBattle.skill.id === _skill.id;
				button(label, usable, function () { self.onBattleSkillClicked(_skill); }, selected);
			})(turn.skills[i]);
		}
		$('<div/>').css('height', '0.8rem').appendTo(side);
		button('Wait (act later this round)', !this.mBattleBusy, function () { self.sendBattleOrder({ action: 'wait' }); });
		button('End turn', !this.mBattleBusy, function () { self.sendBattleOrder({ action: 'end' }); });
	}
	$('<div/>').css('height', '0.8rem').appendTo(side);
	button('Hide battle', true, function () { self.setBattleHidden(true); });
	this.mBattleHoverEl = $('<div/>').css({ 'margin-top': '1rem', color: '#a89c80' }).appendTo(side);
	$('<div/>').html('<span style="color:#3f8f3f">&#9679;</span> yours &nbsp; <span style="color:#3a6fb0">&#9679;</span> allies &nbsp; <span style="color:#a83a32">&#9679;</span> enemies').css('margin-top', '1rem').appendTo(side);
};

BBCoopConnection.prototype.onBattleSkillClicked = function (_skill)
{
	if (!_skill.targeted)
	{
		this.sendBattleOrder({ action: 'skill', skill: _skill.id, x: -1, y: -1 });
		return;
	}
	this.mBattle.skill = (this.mBattle.skill !== null && this.mBattle.skill.id === _skill.id) ? null : _skill;
	this.renderBattleMap();
	this.renderBattleSidebar();
};

BBCoopConnection.prototype.onBattleTileClicked = function (_x, _y, _unit)
{
	if (!this.mBattle || this.mBattle.view.turn === null || this.mBattleBusy) return;
	var skill = this.mBattle.skill;
	if (skill !== null)
	{
		for (var i = 0; i < skill.targets.length; i++)
		{
			if (skill.targets[i][0] === _x && skill.targets[i][1] === _y)
			{
				this.sendBattleOrder({ action: 'skill', skill: skill.id, x: _x, y: _y });
				return;
			}
		}
		this.setBattleStatus("That tile isn't a valid target for " + skill.name + '.', true);
		return;
	}
	if (_unit) { this.setBattleStatus('Pick a skill first to act on ' + _unit.name + '.', true); return; }
	this.sendBattleOrder({ action: 'move', x: _x, y: _y });
};

BBCoopConnection.prototype.sendBattleOrder = function (_order)
{
	var self = this;
	var b = this.mBattle;
	if (!b || b.view.turn === null) return;
	_order.to = b.host;
	_order.battleID = b.view.battleID;
	_order.key = b.view.turn.key;
	this.mBattleBusy = true;
	b.skill = null;
	this.setBattleStatus('Order sent, waiting for ' + b.host + "'s game...", false);
	this.renderBattleSidebar();
	this.send({ type: 'battle_order', payload: _order }, function (_ok)
	{
		if (!_ok) { self.mBattleBusy = false; self.setBattleStatus('Sending the order failed. Is the relay running?', true); self.renderBattleSidebar(); }
	});
};

// ---------------------------------------------------------------------------
// Joining another player's world: Multiplayer button on the main menu, join window,
// and the host's map seed filled into the new campaign screen.

BBCoopConnection.prototype.openJoinWindow = function ()
{
	var self = this;
	if (this.mJoinWindow) return;
	var cfg = this.mConfig || { relayURL: 'http://127.0.0.1:7777', playerName: 'Player' };
	var overlay = $('<div class="text-font-normal"/>').css({
		position: 'fixed', left: '0', top: '0', right: '0', bottom: '0', 'z-index': 99500,
		background: 'rgba(0,0,0,0.7)', color: '#e8dcc0', 'font-size': '1.7rem'
	}).appendTo($('body'));
	var box = $('<div/>').css({
		position: 'absolute', left: '50%', top: '30%', width: '56rem', 'margin-left': '-28rem',
		background: 'rgba(20,16,10,0.97)', border: '0.2rem solid #8a6d3b', padding: '2rem'
	}).appendTo(overlay);
	$('<div/>').text('Multiplayer: join a world').css({ 'font-size': '2.4rem', color: '#d8b56a', 'margin-bottom': '1.4rem' }).appendTo(box);
	var field = function (_label, _value)
	{
		$('<div/>').text(_label).css({ 'margin-bottom': '0.4rem', color: '#a89c80' }).appendTo(box);
		return self.makeInput(box, _value, '100%', function () { connect(); }, function () { self.closeJoinWindow(); }).css('margin-bottom', '1.2rem');
	};
	var urlInput = field("Host's address (relay)", cfg.relayURL);
	var nameInput = field('Your name', cfg.playerName);
	var passwordInput = field('Session password (if the host set one)', cfg.password || '');
	passwordInput.attr('type', 'password');
	this.mJoinStatus = $('<div/>').css({ 'min-height': '2.4rem', 'margin-bottom': '1rem' }).appendTo(box);
	var row = $('<div/>').appendTo(box);
	var button = function (_label, _onClick)
	{
		return $('<div/>').text(_label).css({
			display: 'inline-block', padding: '0.6rem 1.6rem', 'margin-right': '1rem', cursor: 'pointer',
			border: '0.1rem solid #8a6d3b', background: 'rgba(255,255,255,0.06)'
		}).click(_onClick).appendTo(row);
	};
	var connect = function ()
	{
		var url = $.trim(urlInput.val()), name = $.trim(nameInput.val());
		// a bare address ("100.1.2.3") gets the relay's default port; a full URL
		// (e.g. an https tunnel address) is used exactly as typed
		if (url.indexOf('://') === -1)
		{
			url = 'http://' + url.replace(/\/+$/, '');
			if (!/:\d+$/.test(url)) url += ':7777';
		}
		if (name === '') { self.setJoinStatus('Pick a name first.', true); return; }
		self.setJoinStatus('Connecting to ' + url + '...', false);
		SQ.call(self.mSQHandle, 'applyJoinSettings', { relayURL: url, playerName: name, password: passwordInput.val() }, function (_config)
		{
			self.mJoinWaiting = true;
			self.start(_config);
		});
	};
	button('Connect', connect);
	button('Cancel', function () { self.closeJoinWindow(); });
	this.mJoinWindow = overlay;
};

BBCoopConnection.prototype.closeJoinWindow = function ()
{
	if (this.mJoinWindow) this.mJoinWindow.remove();
	this.mJoinWindow = null;
	this.setTyping(false);
	this.mJoinStatus = null;
	this.mJoinWaiting = false;
	if (this.mJoinTimer) { clearTimeout(this.mJoinTimer); this.mJoinTimer = null; }
};

BBCoopConnection.prototype.setJoinStatus = function (_text, _isError)
{
	if (this.mJoinStatus) this.mJoinStatus.text(_text).css('color', _isError ? '#e07060' : '#e8dcc0');
};

// Called once we are connected while the join window waits
BBCoopConnection.prototype.requestSession = function ()
{
	var self = this;
	this.setJoinStatus('Connected. Asking the host for its world...', false);
	this.send({ type: 'session_request', payload: {} });
	if (this.mJoinTimer) clearTimeout(this.mJoinTimer);
	this.mJoinTimer = setTimeout(function ()
	{
		self.mJoinTimer = null;
		if (self.mJoinWaiting) self.setJoinStatus('No host answered. The host must be connected and on the world map.', true);
	}, 10000);
};

BBCoopConnection.prototype.onSessionInfo = function (_from, _info)
{
	if (!this.mJoinWaiting) return;
	if (_info.error) { this.setJoinStatus(_from + ': ' + _info.error, true); return; }
	if (_info.dlcs && this.mConfig.dlcs)
	{
		var mine = this.mConfig.dlcs.join(', ') || 'none', theirs = _info.dlcs.join(', ') || 'none';
		if (mine !== theirs)
		{
			this.setJoinStatus('Your DLCs differ from ' + _from + "'s, so your maps would not match. " + _from + ': ' + theirs + '. You: ' + mine + '.', true);
			return;
		}
	}
	this.closeJoinWindow();
	window.BBCoopPendingJoin = { host: _from, seed: _info.seed, x: _info.x, y: _info.y };
	this.showToast('Joining ' + _from + "'s world. Pick your origin; the map seed is set to theirs.");
	SQ.call(this.mSQHandle, 'startJoin', window.BBCoopPendingJoin);
};

(function ()
{
	if (typeof MainMenuModule !== 'undefined')
	{
		var createButtons = MainMenuModule.prototype.createMainMenuButtons;
		MainMenuModule.prototype.createMainMenuButtons = function ()
		{
			createButtons.apply(this, arguments);
			try
			{
				var row = $('<div class="row"></div>');
				var layout = $('<div class="l-center"></div>');
				row.append(layout);
				layout.createTextButton('Multiplayer', function ()
				{
					if (window.BBCoopScreen) window.BBCoopScreen.openJoinWindow();
				}, '', 4);
				// right below "New Campaign"
				var first = this.mButtonContainer.children('.row').first();
				if (first.length) row.insertAfter(first); else this.mButtonContainer.append(row);
			}
			catch (e) { console.error('BBCoop: could not add the Multiplayer button: ' + e); }
		};
	}

	if (typeof NewCampaignMenuModule !== 'undefined')
	{
		var show = NewCampaignMenuModule.prototype.show;
		NewCampaignMenuModule.prototype.show = function ()
		{
			show.apply(this, arguments);
			var pending = window.BBCoopPendingJoin;
			if (pending && this.mSeed)
			{
				this.mSeed.setInputText(pending.seed);
				this.mSeed.attr('readonly', 'readonly');
			}
		};
		var hide = NewCampaignMenuModule.prototype.hide;
		NewCampaignMenuModule.prototype.hide = function ()
		{
			window.BBCoopPendingJoin = null;
			if (this.mSeed) this.mSeed.removeAttr('readonly');
			return hide.apply(this, arguments);
		};
	}
})();
// ---------------------------------------------------------------------------
// Text fields. The game's global CSS turns off text selection for every element
// (* { user-select: none }), which also stops typing in a plain <input>; vanilla's own
// inputs switch it back on, and so do ours. While a field has focus the game is told to
// ignore keys, so typing a name doesn't open the character screen or pause the game.
// Enter runs _onEnter, Escape runs _onEscape.

BBCoopConnection.prototype.makeInput = function (_parent, _value, _width, _onEnter, _onEscape)
{
	var self = this;
	var input = $('<input type="text"/>').val(_value).css({
		width: _width, 'font-size': '1.8rem', padding: '0.5rem', 'box-sizing': 'border-box',
		background: '#0d0b08', color: '#f0e6cc', border: '0.1rem solid #8a6d3b', outline: 'none',
		'-webkit-user-select': 'text', 'user-select': 'text', cursor: 'text'
	}).appendTo(_parent);
	input.on('focus', function () { self.setTyping(true); });
	input.on('blur', function () { self.setTyping(false); });
	input.on('mousedown click', function (_event) { _event.stopPropagation(); input.focus(); });
	input.on('keydown', function (_event)
	{
		_event.stopPropagation();
		var code = _event.which || _event.keyCode;
		if (code === 13 && _onEnter) { _event.preventDefault(); _onEnter(); }
		else if (code === 27 && _onEscape) { _event.preventDefault(); _onEscape(); }
	});
	input.on('keyup keypress', function (_event) { _event.stopPropagation(); });
	return input;
};

BBCoopConnection.prototype.setTyping = function (_typing)
{
	if (this.mTyping === _typing) return;
	this.mTyping = _typing;
	if (this.mSQHandle !== null) SQ.call(this.mSQHandle, 'setTyping', _typing);
};

// ---------------------------------------------------------------------------
// Prompts (join a nearby battle, pick a side) and the clan window.

BBCoopConnection.prototype.makeWindow = function (_title, _width)
{
	var overlay = $('<div class="text-font-normal"/>').css({
		position: 'fixed', left: '0', top: '0', right: '0', bottom: '0', 'z-index': 99600,
		background: 'rgba(0,0,0,0.55)', color: '#e8dcc0', 'font-size': '1.7rem'
	}).appendTo($('body'));
	var box = $('<div/>').css({
		position: 'absolute', left: '50%', top: '25%', width: _width + 'rem', 'margin-left': (-_width / 2) + 'rem',
		background: 'rgba(20,16,10,0.97)', border: '0.2rem solid #8a6d3b', padding: '2rem'
	}).appendTo(overlay);
	$('<div/>').text(_title).css({ 'font-size': '2.4rem', color: '#d8b56a', 'margin-bottom': '1.2rem' }).appendTo(box);
	return { overlay: overlay, box: box };
};

BBCoopConnection.prototype.makeButton = function (_parent, _label, _onClick, _block)
{
	return $('<div/>').text(_label).css({
		display: _block ? 'block' : 'inline-block', padding: '0.6rem 1.4rem', margin: '0.4rem 1rem 0.4rem 0', cursor: 'pointer',
		border: '0.1rem solid #8a6d3b', background: 'rgba(255,255,255,0.06)'
	}).click(_onClick).appendTo(_parent);
};

// _prompt: { id, title, text, options: [{ id, label }] }; the choice goes back to Squirrel
BBCoopConnection.prototype.showPrompt = function (_prompt)
{
	var self = this;
	this.closePrompt(null);
	var w = this.makeWindow(_prompt.title, 60);
	$('<div/>').text(_prompt.text).css('margin-bottom', '1.4rem').appendTo(w.box);
	for (var i = 0; i < _prompt.options.length; i++)
	{
		(function (_option)
		{
			self.makeButton(w.box, _option.label, function ()
			{
				self.closePrompt(null);
				SQ.call(self.mSQHandle, 'onPromptChoice', { id: _prompt.id, choice: _option.id });
			}, true);
		})(_prompt.options[i]);
	}
	this.mPrompt = { id: _prompt.id, window: w.overlay };
};

// _id null closes whatever prompt is open
BBCoopConnection.prototype.closePrompt = function (_id)
{
	if (!this.mPrompt) return;
	if (_id !== null && this.mPrompt.id !== _id) return;
	this.mPrompt.window.remove();
	this.mPrompt = null;
	if (_id !== null && _id.indexOf('join:') === 0) this.showToast('That battle is over.');
};

// Everyone's clan, learned from their position updates
BBCoopConnection.prototype.notePlayer = function (_msg)
{
	if (!this.mPlayers) this.mPlayers = {};
	if (_msg.type === 'pos' && _msg.payload) this.mPlayers[_msg.from] = { clan: _msg.payload.clan || '', seen: new Date().getTime() };
};

BBCoopConnection.prototype.openClanWindow = function (_myClan)
{
	var self = this;
	if (this.mClanWindow) { this.mClanWindow.remove(); this.mClanWindow = null; this.setTyping(false); return; }
	var w = this.makeWindow('Clan', 60);
	this.mClanWindow = w.overlay;
	var close = function () { if (self.mClanWindow) self.mClanWindow.remove(); self.mClanWindow = null; self.setTyping(false); };
	var setClan = function (_name) { SQ.call(self.mSQHandle, 'setClan', _name); close(); };

	$('<div/>').text(_myClan ? 'Your clan: ' + _myClan : "You're not in a clan.").css('margin-bottom', '1rem').appendTo(w.box);
	$('<div/>').text('Clanmates always fight on the same side. Anyone else gets to choose a side when joining your battles.').css({ color: '#a89c80', 'margin-bottom': '1.2rem' }).appendTo(w.box);

	var create = function () { var n = $.trim(input.val()); if (n !== '') setClan(n); };
	var input = this.makeInput(w.box, _myClan || '', '60%', create, close).attr('placeholder', 'Clan name');
	this.makeButton(w.box, _myClan ? 'Rename' : 'Create', create);
	if (_myClan) this.makeButton(w.box, 'Leave clan', function () { setClan(''); });

	$('<div/>').text('Players online').css({ 'font-size': '2rem', color: '#d8b56a', margin: '1.6rem 0 0.6rem 0' }).appendTo(w.box);
	var now = new Date().getTime(), any = false;
	for (var name in (this.mPlayers || {}))
	{
		var p = this.mPlayers[name];
		if (now - p.seen > 30000 || name === (this.mConfig && this.mConfig.playerName)) continue;
		any = true;
		var row = $('<div/>').css('margin', '0.4rem 0').appendTo(w.box);
		$('<span/>').text(name + (p.clan ? ' (clan ' + p.clan + ')' : ' (no clan)') + '  ').appendTo(row);
		if (p.clan && p.clan !== _myClan)
			(function (_clan) { self.makeButton(row, 'Join ' + _clan, function () { setClan(_clan); }); })(p.clan);
	}
	if (!any) $('<div/>').text('Nobody else is on the world map right now.').css('color', '#a89c80').appendTo(w.box);
	$('<div/>').css('height', '1rem').appendTo(w.box);
	this.makeButton(w.box, 'Close', close);
};

// ---------------------------------------------------------------------------
// Trade window (Ctrl+T): pick a nearby player, then items, brothers and crowns to send.
// _data: { players, items: [{ id, name, icon, value, amount }], bros: [{ id, name, level, background }], crowns }
// or { error }

BBCoopConnection.prototype.openTradeWindow = function (_data)
{
	var self = this;
	if (this.mTradeWindow) { this.closeTradeWindow(); return; }
	if (_data.error) { this.showToast(_data.error); return; }
	var w = this.makeWindow('Trade', 80);
	w.box.css({ top: '10%' });
	this.mTradeWindow = w.overlay;
	var chosen = { items: {}, bros: {} };
	var to = _data.players[0];

	// recipient
	var who = $('<div/>').css('margin-bottom', '1rem').appendTo(w.box);
	var whoButtons = [];
	$('<span/>').text('Send to: ').appendTo(who);
	for (var p = 0; p < _data.players.length; p++)
	{
		(function (_name)
		{
			var b = self.makeButton(who, _name, function ()
			{
				to = _name;
				for (var i = 0; i < whoButtons.length; i++) whoButtons[i].css('background', 'rgba(255,255,255,0.06)');
				b.css('background', 'rgba(216,181,106,0.35)');
			});
			if (_name === to) b.css('background', 'rgba(216,181,106,0.35)');
			whoButtons.push(b);
		})(_data.players[p]);
	}

	var total = $('<div/>').css({ color: '#a89c80', 'margin-bottom': '0.6rem' });
	var updateTotal = function ()
	{
		var n = 0, value = 0, b = 0;
		for (var k in chosen.items) { n++; value += chosen.items[k]; }
		for (var k2 in chosen.bros) b++;
		total.text('Chosen: ' + n + ' items (worth ' + value + ' crowns), ' + b + ' brothers');
	};

	var makeList = function (_title, _entries, _label, _bucket, _worth)
	{
		$('<div/>').text(_title).css({ 'font-size': '2rem', color: '#d8b56a', margin: '0.8rem 0 0.4rem 0' }).appendTo(w.box);
		var list = $('<div/>').css({ 'max-height': '22rem', 'overflow-y': 'auto', border: '0.1rem solid #5a4a2a', padding: '0.4rem' }).appendTo(w.box);
		if (_entries.length === 0) $('<div/>').text('None.').css('color', '#a89c80').appendTo(list);
		for (var i = 0; i < _entries.length; i++)
		{
			(function (_e)
			{
				var row = $('<div/>').css({ padding: '0.3rem 0.6rem', cursor: 'pointer', display: 'flex', 'align-items': 'center' }).appendTo(list);
				if (_e.icon) $('<img/>').attr('src', 'coui://gfx/ui/items/' + _e.icon).css({ width: '3.6rem', height: '3.6rem', 'margin-right': '0.8rem' }).appendTo(row);
				$('<span/>').text(_label(_e)).appendTo(row);
				row.click(function ()
				{
					if (_e.id in chosen[_bucket]) { delete chosen[_bucket][_e.id]; row.css('background', 'transparent'); }
					else { chosen[_bucket][_e.id] = _worth(_e); row.css('background', 'rgba(216,181,106,0.3)'); }
					updateTotal();
				});
			})(_entries[i]);
		}
	};
	makeList('Items in your stash (click to pick)', _data.items,
		function (_e) { return _e.name + (_e.amount ? ' (' + _e.amount + ')' : '') + ' - ' + _e.value + ' crowns'; }, 'items',
		function (_e) { return _e.value; });
	makeList('Brothers (click to pick)', _data.bros,
		function (_e) { return _e.name + ', ' + _e.background + ', level ' + _e.level; }, 'bros',
		function () { return 0; });

	var send = function ()
	{
		var crowns = parseInt(crownsInput.val(), 10);
		if (isNaN(crowns) || crowns < 0) crowns = 0;
		var data = { to: to, items: [], bros: [], crowns: crowns };
		for (var k in chosen.items) data.items.push(parseInt(k, 10));
		for (var k2 in chosen.bros) data.bros.push(parseInt(k2, 10));
		SQ.call(self.mSQHandle, 'sendTrade', data, function (_error)
		{
			if (_error) { status.text(_error).css('color', '#e07060'); return; }
			self.closeTradeWindow();
		});
	};
	var close = function () { self.closeTradeWindow(); };

	var crownsRow = $('<div/>').css('margin', '1rem 0').appendTo(w.box);
	$('<span/>').text('Crowns (you have ' + _data.crowns + '): ').appendTo(crownsRow);
	var crownsInput = this.makeInput(crownsRow, '0', '14rem', send, close);
	total.appendTo(w.box);
	updateTotal();
	var status = $('<div/>').css({ 'min-height': '2.2rem', 'margin-bottom': '0.6rem' }).appendTo(w.box);
	this.makeButton(w.box, 'Send offer', send);
	this.makeButton(w.box, 'Cancel', close);
};

BBCoopConnection.prototype.closeTradeWindow = function ()
{
	if (this.mTradeWindow) this.mTradeWindow.remove();
	this.mTradeWindow = null;
	this.setTyping(false);
};

// ---------------------------------------------------------------------------
// Text chat: Enter on the world map (Ctrl+Enter in battle) opens a line to type in.
// Messages show bottom left and fade after a while; open the chat to see the history.

BBCoopConnection.prototype.ensureChat = function ()
{
	if (this.mChat) return this.mChat;
	var box = $('<div class="text-font-normal"/>').css({
		position: 'fixed', left: '2rem', bottom: '16rem', width: '56rem', 'z-index': 99000,
		color: '#e8dcc0', 'font-size': '1.7rem', 'pointer-events': 'none'
	}).appendTo($('body'));
	var log = $('<div/>').css({ 'max-height': '30rem', overflow: 'hidden', padding: '0.4rem 0.8rem' }).appendTo(box);
	this.mChat = { box: box, log: log, input: null, open: false, closedAt: 0, lines: [] };
	return this.mChat;
};

BBCoopConnection.prototype.addChatLine = function (_from, _text)
{
	var chat = this.ensureChat();
	var line = $('<div/>').css({ 'margin-bottom': '0.2rem', 'text-shadow': '0.1rem 0.1rem 0.2rem #000', 'word-wrap': 'break-word' });
	$('<span/>').text(_from + ': ').css({ color: _from === (this.mConfig && this.mConfig.playerName) ? '#9fc5e8' : '#d8b56a' }).appendTo(line);
	$('<span/>').text(_text).appendTo(line);
	line.appendTo(chat.log);
	chat.lines.push(line);
	while (chat.lines.length > 30) chat.lines.shift().remove();
	chat.log.scrollTop(chat.log[0].scrollHeight);
	this.log('Chat ' + _from + ': ' + _text);
	if (!chat.open)
	{
		setTimeout(function () { if (!chat.open) line.fadeOut(800); }, 20000);
	}
};

BBCoopConnection.prototype.openChat = function ()
{
	var self = this;
	var chat = this.ensureChat();
	if (chat.open) { chat.input.focus(); return; }
	// the Enter that just sent a message must not open the chat again
	if (new Date().getTime() - chat.closedAt < 500) return;
	chat.open = true;
	chat.box.css({ 'pointer-events': 'auto' });
	chat.log.css({ background: 'rgba(0,0,0,0.6)', 'overflow-y': 'auto' });
	for (var i = 0; i < chat.lines.length; i++) chat.lines[i].stop(true, true).show();
	chat.log.scrollTop(chat.log[0].scrollHeight);
	var send = function ()
	{
		var text = $.trim(chat.input.val()).substring(0, 200);
		if (text !== '' && self.mConfig)
		{
			self.send({ type: 'chat', payload: { text: text } });
			self.addChatLine(self.mConfig.playerName, text);
		}
		else if (!self.mConfig) self.showToast('Not connected to the relay.');
		self.closeChat();
	};
	chat.input = this.makeInput(chat.box, '', '100%', send, function () { self.closeChat(); }).attr('maxlength', 200).attr('placeholder', 'Say something (Enter to send, Escape to close)');
	chat.input.focus();
};

BBCoopConnection.prototype.closeChat = function ()
{
	var chat = this.mChat;
	if (!chat || !chat.open) return;
	chat.open = false;
	chat.closedAt = new Date().getTime();
	if (chat.input) chat.input.remove();
	chat.input = null;
	this.setTyping(false);
	chat.box.css({ 'pointer-events': 'none' });
	chat.log.css({ background: 'transparent', 'overflow-y': 'hidden' });
	// older lines disappear again; the newest ones fade a bit later
	for (var i = 0; i < chat.lines.length; i++)
	{
		(function (_line, _delay) { setTimeout(function () { if (!chat.open) _line.fadeOut(800); }, _delay); })(chat.lines[i], i >= chat.lines.length - 3 ? 8000 : 0);
	}
};

window.BBCoopScreen = new BBCoopConnection();
registerScreen("BBCoopConnection", window.BBCoopScreen);
