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
		if (_status !== 200 || _data === null)
		{
			self.notify('Joining the relay failed (status ' + _status + ').');
			return;
		}
		self.mLastSeq = _data.seq;
		var others = _data.players.filter(function (p) { return p !== self.mConfig.playerName; });
		self.notify('Joined co-op session. Other players: ' + (others.length ? others.join(', ') : 'none yet'));
		self.poll(_session);
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
		if (_status === 200 && _data !== null)
		{
			self.mLastSeq = _data.seq;
			for (var i = 0; i < _data.messages.length; i++)
			{
				var msg = _data.messages[i];
				if (msg.from === self.mConfig.playerName) continue;
				SQ.call(self.mSQHandle, 'onMessage', msg);
			}
		}
		else
		{
			delay = 3000; // relay down or timed out: back off a bit
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
		if (_pos === null || _pos === undefined) return;
		// only send when the company actually moved
		if (self.mLastPos !== null && Math.abs(self.mLastPos.x - _pos.x) < 1 && Math.abs(self.mLastPos.y - _pos.y) < 1) return;
		self.mLastPos = _pos;
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

registerScreen("BBCoopConnection", new BBCoopConnection());
