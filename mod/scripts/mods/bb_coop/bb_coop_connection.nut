this.bb_coop_connection <- ::inherit("scripts/mods/msu/js_connection", {
	m = {},

	function create()
	{
		this.m.ID = "BBCoopConnection";
	}

	function connect()
	{
		this.m.JSHandle = ::UI.connect(this.m.ID, this);
		this.m.JSHandle.asyncCall("start", this.getConfig());
	}

	function getConfig()
	{
		return {
			relayURL = ::BBCoop.getSetting("RelayURL"),
			playerName = ::BBCoop.getSetting("PlayerName"),
			modVersion = ::BBCoop.Version,
			gameVersion = ::GameInfo.getVersionNumber()
		};
	}

	function runPing()
	{
		if (!this.isConnected()) return;
		// settings may have changed since the main menu, so send them again
		this.m.JSHandle.asyncCall("start", this.getConfig());
	}

	function sendHello()
	{
		if (!this.isConnected()) return;
		this.m.JSHandle.asyncCall("sendHello", {
			type = "hello",
			payload = { text = "Hello from " + ::BBCoop.getSetting("PlayerName") }
		});
	}

	function showToast( _text )
	{
		if (!this.isConnected()) return;
		this.m.JSHandle.asyncCall("showToast", _text);
	}

	// ---- called from JS ----

	function onLog( _text )
	{
		::BBCoop.log(_text);
	}

	function onNotify( _text )
	{
		::BBCoop.notify(_text);
	}

	// JS polls this about once a second; returns null when not on the world map
	function getWorldPosition()
	{
		if (!::MSU.Utils.hasState("world_state")) return null;
		try
		{
			local player = ::MSU.Utils.getState("world_state").getPlayer();
			if (player == null) return null;
			local pos = player.getPos();
			local brushes = ::BBCoop.Ghosts.getOwnBrushes();
			return {
				x = pos.X,
				y = pos.Y,
				seed = ::BBCoop.Ghosts.getSeed(),
				base = brushes.base,
				body = brushes.body
			};
		}
		catch (error)
		{
			return null;
		}
	}

	function onMessage( _msg )
	{
		switch (_msg.type)
		{
			case "hello":
				::BBCoop.notify(_msg.from + " says: " + _msg.payload.text);
				break;
			case "pos":
				::BBCoop.Ghosts.onPosition(_msg.from, _msg.payload);
				break;
			case "join":
				::BBCoop.notify(_msg.from + " joined the session (mod " + _msg.payload.modVersion + ", game " + _msg.payload.gameVersion + ")");
				break;
			default:
				::BBCoop.log("Unknown message type from " + _msg.from + ": " + _msg.type);
		}
	}
});
