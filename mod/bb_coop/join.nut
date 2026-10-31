// Joining another player's world from the main menu.
// Joiner: Multiplayer button -> join window (relay address, name) -> asks for the session
// ("session_request"). The host answers with its map seed and position ("session_info").
// The new campaign screen opens with the host's seed filled in, the joiner picks an origin,
// and once the campaign has started their company is moved next to the host's.
// Checked against vanilla main_menu_state, world_state.startNewCampaign and the scenarios'
// onSpawnPlayer (tile rules: no ocean, no shore, not occupied, reachable).

::BBCoop.Join <- {
	Pending = null,   // { host, seed, x, y } while a joined campaign is being set up

	// ---- host ----
	function onSessionRequest( _from, _payload )
	{
		if (!::MSU.Utils.hasState("world_state")) return; // only a player on the world map can host
		local player = null;
		try { player = ::World.State.getPlayer(); } catch (error) {}
		if (player == null) return;
		local seed = ::BBCoop.Ghosts.getSeed();
		if (seed == null || seed == "")
		{
			::BBCoop.Connection.sendMessage("session_info", { to = _from, error = "The host's campaign was started before the co-op mod was installed, so its map seed is unknown. The host needs a new campaign." });
			return;
		}
		local pos = player.getPos();
		::BBCoop.Connection.sendMessage("session_info", { to = _from, seed = seed, x = pos.X, y = pos.Y, dlcs = ::BBCoop.getDLCs() });
		::BBCoop.notify(_from + " is joining your world.");
	}

	// ---- joiner ----
	function start( _info )
	{
		this.Pending = _info;
		::BBCoop.log("Joining " + _info.host + "'s world, seed " + _info.seed);
		try
		{
			::MSU.Utils.getState("main_menu_state").main_menu_module_onNewCampaignPressed();
		}
		catch (error)
		{
			::BBCoop.log("Could not open the new campaign screen: " + error);
		}
	}

	// A free, reachable tile near the host's company
	function findSpawnTile( _x, _y )
	{
		local hostTile = ::World.getTile(::World.worldToTile(::createVec(_x, _y)));
		local nav = ::World.getNavigator();
		local settings = nav.createSettings();
		settings.ActionPointCosts = ::Const.World.TerrainTypeNavCost_Flat;

		local seen = {};
		local queue = [hostTile];
		seen[hostTile.ID] <- true;
		local i = 0;
		while (i < queue.len() && i < 200)
		{
			local tile = queue[i++];
			local d = tile.getDistanceTo(hostTile);
			if (d >= 2 && tile.Type != ::Const.World.TerrainType.Ocean && tile.Type != ::Const.World.TerrainType.Shore && !tile.IsOccupied)
			{
				local path = nav.findPath(tile, hostTile, settings, 0);
				if (!path.isEmpty()) return tile;
			}
			if (d >= 5) continue;
			for (local dir = 0; dir != 6; dir++)
			{
				if (!tile.hasNextTile(dir)) continue;
				local next = tile.getNextTile(dir);
				if (next.ID in seen) continue;
				seen[next.ID] <- true;
				queue.push(next);
			}
		}
		return null;
	}

	function onCampaignStarted( _seed )
	{
		if (this.Pending == null) return;
		local info = this.Pending;
		this.Pending = null;
		if (_seed != info.seed)
		{
			::BBCoop.notify("The map seed was changed, so your company starts on its own map instead of next to " + info.host + ".");
			return;
		}
		local tile = this.findSpawnTile(info.x, info.y);
		if (tile == null)
		{
			::BBCoop.notify("Could not find free land next to " + info.host + ", so you start at your origin's usual place.");
			return;
		}
		local player = ::World.State.getPlayer();
		player.setPos(tile.Pos);
		::World.getCamera().setPos(player.getPos());
		::World.uncoverFogOfWar(tile.Pos, 900.0);
		::BBCoop.notify("Your company arrives next to " + info.host + "'s.");
	}
};

::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.startNewCampaign = @(__original) function()
	{
		local seed = null;
		try { seed = this.m.CampaignSettings.Seed; } catch (error) {}
		__original();
		try
		{
			::BBCoop.Join.onCampaignStarted(seed);
		}
		catch (error)
		{
			::BBCoop.log("Placing the company next to the host failed: " + error);
		}
	}
});
