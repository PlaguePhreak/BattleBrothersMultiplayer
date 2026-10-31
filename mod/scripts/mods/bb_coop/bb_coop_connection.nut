this.bb_coop_connection <- ::inherit("scripts/mods/msu/js_connection", {
	m = {
		BotEnabled = false
	},

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
			password = ::BBCoop.getSetting("SessionPassword"),
			modVersion = ::BBCoop.Version,
			clan = ::BBCoop.getClan(),
			dlcs = ::BBCoop.getDLCs(),
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

	function sendMessage( _type, _payload )
	{
		if (!this.isConnected()) return;
		this.m.JSHandle.asyncCall("send", { type = _type, payload = _payload });
	}

	function isBotEnabled()
	{
		return this.m.BotEnabled;
	}

	function setBotEnabled( _bool )
	{
		this.m.BotEnabled = _bool;
	}

	function showToast( _text )
	{
		if (!this.isConnected()) return;
		this.m.JSHandle.asyncCall("showToast", _text);
	}

	// ---- called from JS ----

	// Join window: save the address and name the player typed, return the config to connect with
	function applyJoinSettings( _data )
	{
		try
		{
			::BBCoop.Mod.ModSettings.getSetting("RelayURL").set(_data.relayURL);
			::BBCoop.Mod.ModSettings.getSetting("PlayerName").set(_data.playerName);
			::BBCoop.Mod.ModSettings.getSetting("SessionPassword").set(_data.password);
		}
		catch (error)
		{
			::BBCoop.log("Could not save the join settings: " + error);
		}
		return this.getConfig();
	}

	// The host answered: open the new campaign screen with its seed
	function startJoin( _info )
	{
		::BBCoop.Join.start(_info);
	}

	function closeBattlePanel()
	{
		if (this.isConnected()) this.m.JSHandle.asyncCall("closeBattlePanel", null);
	}

	function showPrompt( _prompt )
	{
		if (this.isConnected()) this.m.JSHandle.asyncCall("showPrompt", _prompt);
	}

	function closePrompt( _id )
	{
		if (this.isConnected()) this.m.JSHandle.asyncCall("closePrompt", _id);
	}

	function onPromptChoice( _data )
	{
		::BBCoop.Battle.onPromptChoice(_data.id, _data.choice);
		::BBCoop.Trade.onPromptChoice(_data.id, _data.choice);
	}

	function openTradeWindow()
	{
		if (this.isConnected()) this.m.JSHandle.asyncCall("openTradeWindow", ::BBCoop.Trade.getWindowData());
	}

	// returns an error text, or null when the offer went out
	function sendTrade( _data )
	{
		try
		{
			return ::BBCoop.Trade.send(_data);
		}
		catch (error)
		{
			::BBCoop.log("Trade failed: " + error);
			return "The trade failed: " + error;
		}
	}

	function openClanWindow()
	{
		if (this.isConnected()) this.m.JSHandle.asyncCall("openClanWindow", ::BBCoop.getClan());
	}

	function setClan( _clan )
	{
		::BBCoop.Mod.ModSettings.getSetting("Clan").set(_clan);
		::BBCoop.notify(_clan == "" ? "You left your clan." : "You are now in the clan " + _clan + ".");
	}

	// A co-op text field has focus: the game ignores keys until it loses focus
	function setTyping( _typing )
	{
		::BBCoop.Typing = _typing == true;
	}

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
			local strength = 0.0;
			try { strength = player.getStrength(); } catch (error) {}
			if (strength <= 0) strength = ::World.getPlayerRoster().getSize() * 10.0;
			return {
				strength = strength,
				x = pos.X,
				y = pos.Y,
				seed = ::BBCoop.Ghosts.getSeed(),
				clan = ::BBCoop.getClan(),
				baseBrush = brushes.baseBrush,
				bodyBrush = brushes.bodyBrush
			};
		}
		catch (error)
		{
			return null;
		}
	}

	function onMessage( _msg )
	{
		// messages meant for one player carry a "to" field
		::BBCoop.Seen[_msg.from] <- ::Time.getRealTimeF();
		if (typeof _msg.payload == "table" && ("to" in _msg.payload) && _msg.payload.to != ::BBCoop.getSetting("PlayerName"))
			return;

		switch (_msg.type)
		{
			case "alive":
				break;
			case "join_refused":
				::BBCoop.Battle.onJoinRefused(_msg.from, _msg.payload);
				break;
			case "battle_start":
				::BBCoop.Battle.onBattleStartMessage(_msg.from, _msg.payload);
				break;
			case "battle_join":
				::BBCoop.Battle.onJoinRequest(_msg.from, _msg.payload);
				break;
			case "session_request":
				::BBCoop.Join.onSessionRequest(_msg.from, _msg.payload);
				break;
			case "battle_loot":
				::BBCoop.Loot.onLoot(_msg.from, _msg.payload);
				break;
			case "battle_over":
				::BBCoop.Battle.onBattleOver(_msg.from, _msg.payload);
				break;
			case "battle_order":
				::BBCoop.Remote.onOrder(_msg.from, _msg.payload);
				break;
			case "battle_result":
				::BBCoop.Battle.onBattleResult(_msg.from, _msg.payload);
				break;
			case "hello":
				::BBCoop.notify(_msg.from + " says: " + _msg.payload.text);
				break;
			case "world_full":
				::BBCoop.World.onFull(_msg.from, _msg.payload);
				break;
			case "world_parties":
				::BBCoop.World.onParties(_msg.from, _msg.payload);
				break;
			case "trade_offer":
				::BBCoop.Trade.onOffer(_msg.from, _msg.payload);
				break;
			case "trade_answer":
				::BBCoop.Trade.onAnswer(_msg.from, _msg.payload);
				break;
			case "trade_confirm":
				::BBCoop.Trade.onConfirm(_msg.from, _msg.payload);
				break;
			case "trade_cancel":
				::BBCoop.Trade.onCancel(_msg.from, _msg.payload);
				break;
			case "trade_return":
				::BBCoop.Trade.onReturn(_msg.from, _msg.payload);
				break;
			case "world_ambush":
				::BBCoop.World.onAmbush(_msg.from, _msg.payload);
				break;
			case "world_request":
				::BBCoop.World.onRequest(_msg.from, _msg.payload);
				break;
			case "world_party_destroyed":
				::BBCoop.World.onPartyDestroyed(_msg.from, _msg.payload);
				break;
			case "world_party_troops":
				::BBCoop.World.onPartyTroops(_msg.from, _msg.payload);
				break;
			case "world_location_destroyed":
				::BBCoop.World.onLocationDestroyed(_msg.from, _msg.payload);
				break;
			case "world_location_troops":
				::BBCoop.World.onLocationTroops(_msg.from, _msg.payload);
				break;
			case "pos":
				::BBCoop.World.onPosition(_msg.from, _msg.payload);
				if ("origin" in _msg.payload) ::BBCoop.Battle.PlayerOrigins[_msg.from] <- _msg.payload.origin;
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
