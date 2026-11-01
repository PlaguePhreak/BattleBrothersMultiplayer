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
	if (this.mHostTimer) { clearInterval(this.mHostTimer); this.mHostTimer = null; }

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
		if (self.mJoinWaiting && _data.session) self.setJoinStatus('Found ' + self.describeSession(_data) + '. Joining...', false);
		self.testWebSocket();
		if (!_config.hosting) { self.join(session); return; }
		// the host describes its session to its own relay first (this also sets the password
		// typed in the Host window), then joins like everyone else
		self.sendHostCard(session, function () { self.join(session); });
		self.mHostTimer = setInterval(function () { self.sendHostCard(session, null); }, 10000);
	});
};

BBCoopConnection.prototype.join = function (_session)
{
	var self = this;
	this.request('POST', '/join', {
		player: this.mConfig.playerName,
		modVersion: this.mConfig.modVersion,
		gameVersion: this.mConfig.gameVersion,
		protocol: this.mConfig.protocol
	}, function (_status, _data)
	{
		if (_session !== self.mSessionId) return;
		if (_status === 403 && _data && _data.error === 'full')
		{
			self.notify('The session is full (' + _data.players + ' / ' + _data.max + ' players).');
			if (self.mJoinWaiting) self.setJoinStatus('The session is full (' + _data.players + ' / ' + _data.max + ' players). Try again when someone leaves.', true);
			return;
		}
		if (_status === 409 && _data && _data.error === 'version')
		{
			var text = 'The host runs co-op mod ' + _data.hostVersion + ', which does not work with yours (' + self.mConfig.modVersion + '). Both players need the same version.';
			self.notify(text);
			if (self.mJoinWaiting) self.setJoinStatus(text, true);
			return;
		}
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

// "Aaron's company, day 34, 2 / 8 players" from a /ping answer
BBCoopConnection.prototype.describeSession = function (_ping)
{
	var c = _ping.session;
	var text = c.name + (c.host && c.name.indexOf(c.host) === -1 ? ' (hosted by ' + c.host + ')' : '');
	if (c.day) text += ', day ' + c.day;
	return text + ', ' + _ping.players + ' / ' + _ping.max + ' players';
};

// Host only: sends the session card (name, day, max players, versions, DLCs) to the relay on this PC
BBCoopConnection.prototype.sendHostCard = function (_session, _done)
{
	var self = this;
	if (_session !== this.mSessionId || this.mSQHandle === null) return;
	SQ.call(this.mSQHandle, 'getHostCard', null, function (_card)
	{
		// not on the world map yet (main menu, campaign screens): announce what we know
		var card = _card || self.mLastHostCard || {
			host: self.mConfig.playerName, name: self.mConfig.sessionName || (self.mConfig.playerName + "'s company"),
			max: self.mConfig.maxPlayers, modVersion: self.mConfig.modVersion, gameVersion: self.mConfig.gameVersion,
			protocol: self.mConfig.protocol, dlcs: self.mConfig.dlcs, day: 0, company: ''
		};
		if (_card) self.mLastHostCard = _card;
		card.password = self.mConfig.password || '';
		self.request('POST', '/host', card, function (_status, _data)
		{
			// a new tunnel run means a new address: tell the host their invite code changed
			if (_status === 200 && _data && _data.code && self.mInviteCode && _data.code !== self.mInviteCode)
				self.showToast('Your invite code changed (the tunnel restarted). Press Ctrl+I and send friends the new one.');
			if (_status === 200 && _data && _data.code) self.mInviteCode = _data.code;
			if (_status === 200 && !self.mInviteHinted)
			{
				self.mInviteHinted = true;
				self.showToast('Hosting. Press Ctrl+I on the world map for the invite code to send your friends.');
			}
			if (_status !== 200 && !self.mHostCardFailed)
			{
				self.mHostCardFailed = true;
				self.log('Could not describe the session to the relay (status ' + _status + ').');
			}
			if (_done) _done();
		});
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
		var moved = self.mLastPos === null || Math.abs(self.mLastPos.x - _pos.x) >= 1 || Math.abs(self.mLastPos.y - _pos.y) >= 1 || self.mLastPos.escort !== _pos.escort;
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

// ---- invite codes and saved hosts (v0.16.0) ----
// An invite code is "BB1-" + base64url(encodeURIComponent(address) + "|" + encodeURIComponent(host)).
// A plain address works too ("100.1.2.3" gets http:// and the relay's port 7777).
var BBCOOP_B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

BBCoopConnection.prototype.decodeBase64Url = function (_text)
{
	var out = '', bits = 0, value = 0;
	for (var i = 0; i < _text.length; i++)
	{
		var v = BBCOOP_B64.indexOf(_text.charAt(i));
		if (v === -1) return null;
		value = (value << 6) | v;
		bits += 6;
		if (bits >= 8) { bits -= 8; out += String.fromCharCode((value >> bits) & 0xff); }
	}
	return out;
};

BBCoopConnection.prototype.normalizeAddress = function (_address)
{
	var url = $.trim(_address || '').replace(/\/+$/, '');
	if (url === '') return '';
	if (url.indexOf('://') === -1)
	{
		url = 'http://' + url;
		if (!/:\d+$/.test(url)) url += ':7777';
	}
	return url;
};

// returns { url, host } or null when the text is neither a code nor an address
BBCoopConnection.prototype.parseInvite = function (_text)
{
	var text = $.trim(_text || '');
	if (text === '') return null;
	if (/^BB1-/i.test(text))
	{
		var raw = this.decodeBase64Url(text.substr(4));
		if (raw === null || raw.indexOf('|') === -1) return null;
		try
		{
			var parts = raw.split('|');
			var url = this.normalizeAddress(decodeURIComponent(parts[0]));
			return url === '' ? null : { url: url, host: decodeURIComponent(parts[1] || '') };
		}
		catch (e) { return null; }
	}
	if (/\s/.test(text)) return null;
	return { url: this.normalizeAddress(text), host: '' };
};

// Saved hosts live in the SavedHosts setting: entries joined by "|", each "host~url" (both URI-encoded)
BBCoopConnection.prototype.getSavedHosts = function ()
{
	var text = (this.mConfig && this.mConfig.savedHosts) || '', list = [];
	if (text === '') return list;
	var entries = text.split('|');
	for (var i = 0; i < entries.length; i++)
	{
		var f = entries[i].split('~');
		try { if (f.length === 2 && f[1] !== '') list.push({ host: decodeURIComponent(f[0]), url: decodeURIComponent(f[1]) }); } catch (e) {}
	}
	return list;
};

BBCoopConnection.prototype.setSavedHosts = function (_list)
{
	var parts = [];
	for (var i = 0; i < _list.length && i < 30; i++)
		parts.push(encodeURIComponent(_list[i].host || '') + '~' + encodeURIComponent(_list[i].url));
	var text = parts.join('|');
	if (this.mConfig) this.mConfig.savedHosts = text;
	if (this.mSQHandle !== null) SQ.call(this.mSQHandle, 'setSavedHosts', text);
};

// Adds a host or updates it: same name (a tunnel host's new address) or same address is the same entry
BBCoopConnection.prototype.rememberHost = function (_url, _host)
{
	var list = this.getSavedHosts(), entry = null;
	for (var i = 0; i < list.length; i++)
	{
		if ((_host && list[i].host === _host) || list[i].url === _url) { entry = list.splice(i, 1)[0]; break; }
	}
	entry = entry || { host: '', url: _url };
	entry.url = _url;
	if (_host) entry.host = _host;
	list.unshift(entry); // newest first
	// another entry with the same address is now a duplicate
	for (var j = list.length - 1; j > 0; j--) if (list[j].url === _url) list.splice(j, 1);
	this.setSavedHosts(list);
	return entry;
};

BBCoopConnection.prototype.forgetHost = function (_url)
{
	var list = this.getSavedHosts();
	for (var i = list.length - 1; i >= 0; i--) if (list[i].url === _url) list.splice(i, 1);
	this.setSavedHosts(list);
};

// GET <url>/ping with its own short timeout; _callback(data or null, ms)
BBCoopConnection.prototype.pingAddress = function (_url, _callback)
{
	var xhr = new XMLHttpRequest(), done = false, started = new Date().getTime();
	var finish = function (_data) { if (done) return; done = true; _callback(_data, new Date().getTime() - started); };
	xhr.onreadystatechange = function ()
	{
		if (xhr.readyState !== 4) return;
		var data = null;
		if (xhr.status === 200) { try { data = JSON.parse(xhr.responseText); } catch (e) {} }
		finish(data);
	};
	try
	{
		xhr.open('GET', _url.replace(/\/+$/, '') + '/ping', true);
		xhr.timeout = 5000;
		xhr.ontimeout = function () { finish(null); };
		xhr.send(null);
	}
	catch (e) { finish(null); }
};

// Why this player can't join a host, from its /ping answer, or null
BBCoopConnection.prototype.joinProblem = function (_ping)
{
	var cfg = this.mConfig || {};
	if (_ping.protocol !== undefined && cfg.protocol !== undefined && _ping.protocol !== cfg.protocol)
		return 'Needs a different co-op version (host has ' + ((_ping.session && _ping.session.modVersion) || _ping.version) + ', you have ' + cfg.modVersion + ')';
	var c = _ping.session;
	if (c && c.dlcs && cfg.dlcs && c.dlcs.join(', ') !== cfg.dlcs.join(', '))
		return 'Different DLCs (host: ' + (c.dlcs.join(', ') || 'none') + ')';
	if (_ping.max && _ping.players >= _ping.max) return 'Full (' + _ping.players + ' / ' + _ping.max + ')';
	return null;
};

// Join window: your saved hosts, checked live, plus adding one by invite code or address
BBCoopConnection.prototype.openJoinWindow = function ()
{
	var self = this;
	if (this.mJoinWindow) return;
	var cfg = this.mConfig || { playerName: 'Player' };
	var w = this.makeWindow('Multiplayer: join a world', 64);
	w.box.css({ top: '12%' });
	var overlay = w.overlay, box = w.box;
	this.mJoinWindow = overlay;
	var label = function (_text) { return $('<div/>').text(_text).css({ 'margin-bottom': '0.4rem', color: '#a89c80' }).appendTo(box); };

	label('Your name');
	var nameInput = this.makeInput(box, cfg.playerName, '100%', null, function () { self.closeJoinWindow(); }).css('margin-bottom', '1rem');
	label('Session password (if the host set one)');
	var passwordInput = this.makeInput(box, cfg.password || '', '100%', null, function () { self.closeJoinWindow(); }).css('margin-bottom', '1.2rem');
	passwordInput.attr('type', 'password');

	label('Your hosts');
	var listBox = $('<div/>').css({ 'max-height': '28rem', 'overflow-y': 'auto', 'margin-bottom': '1rem', border: '0.1rem solid #4a3c22' }).appendTo(box);

	label('Add a host: paste their invite code or address');
	var addRow = $('<div/>').css('margin-bottom', '0.6rem').appendTo(box);
	var addInput = this.makeInput(addRow, '', '44rem', function () { add(); }, function () { self.closeJoinWindow(); });
	this.makeButton(addRow, 'Add', function () { add(); }).css('margin-left', '1rem');

	this.mJoinStatus = $('<div/>').css({ 'min-height': '2.4rem', 'margin-bottom': '0.6rem' }).appendTo(box);
	var row = $('<div/>').appendTo(box);

	var connect = function (_url)
	{
		var name = $.trim(nameInput.val());
		if (!_url) { self.setJoinStatus('Pick a host first.', true); return; }
		if (name === '') { self.setJoinStatus('Pick a name first.', true); return; }
		self.setJoinStatus('Connecting to ' + _url + '...', false);
		SQ.call(self.mSQHandle, 'applyJoinSettings', { relayURL: _url, playerName: name, password: passwordInput.val() }, function (_config)
		{
			self.mJoinWaiting = true;
			self.start(_config);
		});
	};

	var render = function ()
	{
		listBox.empty();
		var hosts = self.getSavedHosts();
		if (hosts.length === 0)
		{
			$('<div/>').text('No hosts yet. Ask your host for their invite code (they press Ctrl+I) and paste it below.')
				.css({ padding: '1rem', color: '#a89c80' }).appendTo(listBox);
			return;
		}
		for (var i = 0; i < hosts.length; i++) (function (_h)
		{
			var entry = $('<div/>').css({ padding: '0.8rem 1rem', 'border-bottom': '0.1rem solid #3a2f1a', position: 'relative' }).appendTo(listBox);
			var title = $('<div/>').text(_h.host || _h.url).css({ color: '#f0e6cc', 'font-size': '1.8rem' }).appendTo(entry);
			var status = $('<div/>').text('Checking...').css({ color: '#a89c80', 'font-size': '1.45rem', 'margin-right': '20rem' }).appendTo(entry);
			var buttons = $('<div/>').css({ position: 'absolute', right: '0.6rem', top: '0.8rem' }).appendTo(entry);
			var joinButton = self.makeButton(buttons, 'Join', function () { connect(_h.url); });
			self.makeButton(buttons, 'Remove', function () { self.forgetHost(_h.url); render(); });
			self.pingAddress(_h.url, function (_ping, _ms)
			{
				if (!self.mJoinWindow) return;
				if (_ping === null)
				{
					status.text('Offline (no answer from ' + _h.url + ')').css('color', '#a07060');
					joinButton.css('opacity', '0.5');
					return;
				}
				var c = _ping.session;
				// the relay says whose it is: keep the saved name up to date
				if (c && c.host && c.host !== _h.host) { self.rememberHost(_h.url, c.host); title.text(c.host); }
				var parts = [];
				if (c) parts.push(c.name + (c.day ? ', day ' + c.day : ''));
				else parts.push('Relay online, host not in a world yet');
				parts.push(_ping.players + ' / ' + _ping.max + ' players');
				if (_ping.password) parts.push('password');
				parts.push(_ms + ' ms');
				var problem = self.joinProblem(_ping);
				status.text((problem ? problem + '. ' : 'Online: ') + parts.join(', ')).css('color', problem ? '#e07060' : '#9fc08a');
				if (problem) joinButton.css('opacity', '0.5');
			});
		})(hosts[i]);
	};

	var add = function ()
	{
		var invite = self.parseInvite(addInput.val());
		if (invite === null) { self.setJoinStatus('That is not an invite code or an address.', true); return; }
		self.rememberHost(invite.url, invite.host);
		addInput.val('');
		self.setJoinStatus('Added ' + (invite.host || invite.url) + '.', false);
		render();
	};

	if (cfg.lastServerURL)
	{
		this.makeButton(row, 'Rejoin last server', function () { connect(cfg.lastServerURL); })
			.attr('title', (cfg.lastServerHost ? cfg.lastServerHost + ': ' : '') + cfg.lastServerURL);
	}
	this.makeButton(row, 'Refresh', render);
	this.makeButton(row, 'Cancel', function () { self.closeJoinWindow(); });
	render();
};

// Host: Ctrl+I shows the invite code to send to friends
BBCoopConnection.prototype.openInviteWindow = function ()
{
	var self = this;
	if (this.mInviteWindow) { this.mInviteWindow.remove(); this.mInviteWindow = null; this.setTyping(false); return; }
	if (!this.mConfig || !this.mConfig.hosting)
	{
		this.notify('Invite codes are for the host: use Multiplayer > Host a world with start-host.bat (or start-relay.bat) running.');
		return;
	}
	var w = this.makeWindow('Invite friends', 64);
	this.mInviteWindow = w.overlay;
	var box = w.box;
	var close = function () { if (self.mInviteWindow) self.mInviteWindow.remove(); self.mInviteWindow = null; self.setTyping(false); };
	var info = $('<div/>').text('Asking your relay...').css({ color: '#a89c80', 'margin-bottom': '1rem' }).appendTo(box);
	$('<div/>').text('Invite code (select it and press Ctrl+C, or use Copy)').css({ color: '#a89c80', 'margin-bottom': '0.4rem' }).appendTo(box);
	var codeInput = this.makeInput(box, '', '100%', null, close).css('margin-bottom', '1rem');
	codeInput.attr('readonly', 'readonly');
	$('<div/>').text('Address friends use (tunnel URL, Tailscale or your public IP)').css({ color: '#a89c80', 'margin-bottom': '0.4rem' }).appendTo(box);
	var addressInput = this.makeInput(box, '', '100%', function () { setAddress(addressInput.val()); }, close).css('margin-bottom', '0.6rem');
	var detectedRow = $('<div/>').css('margin-bottom', '1rem').appendTo(box);
	var status = $('<div/>').css({ 'min-height': '2.2rem', 'margin-bottom': '0.6rem' }).appendTo(box);
	var row = $('<div/>').appendTo(box);

	var show = function (_status, _data)
	{
		if (_status !== 200 || !_data)
		{
			info.text('Your relay did not answer. Is start-host.bat (or start-relay.bat) running?').css('color', '#e07060');
			return;
		}
		codeInput.val(_data.code || '');
		addressInput.val(_data.address || '');
		if (_data.code) self.mInviteCode = _data.code;
		if (!_data.code && _data.tunnel === 'starting')
		{
			info.text('The free tunnel is starting. Its address arrives in a few seconds...').css('color', '#e0b060');
			setTimeout(function () { if (self.mInviteWindow) self.request('GET', '/invite', null, show); }, 3000);
			return;
		}
		if (!_data.code && _data.tunnel === 'missing')
		{
			info.text('cloudflared was not found next to relay.js. Put cloudflared-windows-amd64.exe in the relay folder, or paste another address below.').css('color', '#e07060');
		}
		else info.text(_data.code ? 'Send this code to your friends. They paste it under Multiplayer > Join a world.'
			: 'No address yet. Paste the address your friends use below and press Enter, or pick one found on this PC.')
			.css('color', _data.code ? '#9fc08a' : '#e0b060');
		detectedRow.empty();
		for (var i = 0; i < (_data.detected || []).length; i++) (function (_d)
		{
			self.makeButton(detectedRow, 'Use ' + _d.kind + ' (' + _d.url + ')', function () { setAddress(_d.url); });
		})(_data.detected[i]);
	};
	var setAddress = function (_address)
	{
		self.request('POST', '/address', { address: _address }, show);
	};
	this.makeButton(row, 'Copy', function ()
	{
		codeInput.removeAttr('readonly').focus().select();
		var ok = false;
		try { ok = document.execCommand('copy'); } catch (e) {}
		codeInput.attr('readonly', 'readonly');
		status.text(ok ? 'Copied.' : 'Select the code and press Ctrl+C.');
	});
	this.makeButton(row, 'Close', close);
	this.request('GET', '/invite', null, show);
};

// Multiplayer button: host a world or join one
BBCoopConnection.prototype.openMultiplayerWindow = function ()
{
	var self = this;
	if (this.mJoinWindow || this.mHostWindow || this.mMultiplayerWindow) return;
	var w = this.makeWindow('Multiplayer', 44);
	this.mMultiplayerWindow = w.overlay;
	var close = function () { w.overlay.remove(); self.mMultiplayerWindow = null; };
	$('<div/>').text('Host a world on this PC (run start-host.bat first), or join a friend\'s.').css({ color: '#a89c80', 'margin-bottom': '1.2rem' }).appendTo(w.box);
	this.makeButton(w.box, 'Host a world', function () { close(); self.openHostWindow(); });
	this.makeButton(w.box, 'Join a world', function () { close(); self.openJoinWindow(); });
	this.makeButton(w.box, 'Cancel', close);
};

// Host window: the host names the session, picks how many can join and which world is played
BBCoopConnection.prototype.openHostWindow = function ()
{
	var self = this;
	if (this.mHostWindow) return;
	var cfg = this.mConfig || { playerName: 'Player', maxPlayers: 8 };
	var w = this.makeWindow('Multiplayer: host a world', 56);
	this.mHostWindow = w.overlay;
	var box = w.box;
	var close = function () { if (self.mHostWindow) self.mHostWindow.remove(); self.mHostWindow = null; self.setTyping(false); };
	var label = function (_text) { $('<div/>').text(_text).css({ 'margin-bottom': '0.4rem', color: '#a89c80' }).appendTo(box); };
	var field = function (_label, _value)
	{
		label(_label);
		return self.makeInput(box, _value, '100%', null, close).css('margin-bottom', '1.2rem');
	};
	var nameInput = field('Your name', cfg.playerName);
	var sessionInput = field('Session name (empty: "<your name>\'s company")', cfg.sessionName || '');
	var passwordInput = field('Session password (optional; friends enter the same one)', cfg.password || '');
	passwordInput.attr('type', 'password');

	label('Max players, you included (2 to 8)');
	var max = Math.max(2, Math.min(8, parseInt(cfg.maxPlayers, 10) || 8));
	var maxRow = $('<div/>').css('margin-bottom', '1.2rem').appendTo(box);
	var stepper = function (_text, _delta)
	{
		return $('<div/>').text(_text).css({
			display: 'inline-block', width: '3rem', 'text-align': 'center', cursor: 'pointer',
			border: '0.1rem solid #8a6d3b', background: 'rgba(255,255,255,0.06)'
		}).click(function () { max = Math.max(2, Math.min(8, max + _delta)); maxText.text(max); }).appendTo(maxRow);
	};
	stepper('-', -1);
	var maxText = $('<div/>').text(max).css({ display: 'inline-block', width: '4rem', 'text-align': 'center', 'font-size': '2rem' }).appendTo(maxRow);
	stepper('+', 1);

	var status = $('<div/>').css({ 'min-height': '2.4rem', 'margin-bottom': '1rem' }).appendTo(box);
	label('World');
	var host = function (_which)
	{
		var name = $.trim(nameInput.val());
		if (name === '') { status.text('Pick a name first.').css('color', '#e07060'); return; }
		SQ.call(self.mSQHandle, 'applyHostSettings', {
			playerName: name, sessionName: $.trim(sessionInput.val()), maxPlayers: max, password: $.trim(passwordInput.val())
		}, function (_config)
		{
			close();
			self.start(_config);
			self.showToast(_which === 'load' ? 'Hosting. Pick the save to play.' : 'Hosting. Set up the new campaign.');
			SQ.call(self.mSQHandle, 'openHostWorld', _which);
		});
	};
	this.makeButton(box, 'New campaign', function () { host('new'); });
	this.makeButton(box, 'Load a save', function () { host('load'); });
	this.makeButton(box, 'Cancel', close);
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
	SQ.call(this.mSQHandle, 'setLastServer', { url: this.mConfig.relayURL, host: _from });
	this.mConfig.lastServerURL = this.mConfig.relayURL;
	this.mConfig.lastServerHost = _from;
	this.rememberHost(this.mConfig.relayURL, _from);
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
					if (window.BBCoopScreen) window.BBCoopScreen.openMultiplayerWindow();
				}, '', 4);
				// right below "New Campaign"
				var first = this.mButtonContainer.children('.row').first();
				if (first.length) row.insertAfter(first); else this.mButtonContainer.append(row);
			}
			catch (e) { console.error('BBCoop: could not add the Multiplayer button: ' + e); }
		};
	}

	// Load screen: saves used in multiplayer say so under their name
	if (typeof LoadCampaignMenuModule !== 'undefined')
	{
		var addEntry = LoadCampaignMenuModule.prototype.addCampaignEntryToList;
		LoadCampaignMenuModule.prototype.addCampaignEntryToList = function (_data)
		{
			try
			{
				var screen = window.BBCoopScreen;
				var saves = screen && screen.mConfig && screen.mConfig.coopSaves;
				var ids = (typeof CampaignMenuModulesIdentifier !== 'undefined') ? CampaignMenuModulesIdentifier.Campaign : {};
				var fileKey = ids.FileName || 'fileName', dayKey = ids.DayName || 'dayName';
				if (saves && _data && saves.indexOf(_data[fileKey]) !== -1 && !_data.isIncompatibleVersion)
					_data[dayKey] = (_data[dayKey] || '') + ' - Co-op save, host it from Multiplayer';
			}
			catch (e) { console.error('BBCoop: could not label a co-op save: ' + e); }
			return addEntry.apply(this, arguments);
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
