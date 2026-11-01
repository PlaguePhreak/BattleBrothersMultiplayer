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
		local info = { to = _from, seed = seed, x = pos.X, y = pos.Y, dlcs = ::BBCoop.getDLCs(), day = ::World.getTime().Days };
		// the joiner plays our campaign: same combat and economic difficulty
		try { info.cd <- ::World.Assets.getCombatDifficulty(); info.ed <- ::World.Assets.getEconomicDifficulty(); } catch (error) {}
		// v0.30.0: and every other campaign setting of ours, forced on the joiner's new campaign
		try
		{
			info.im <- ::World.Assets.isIronman();
			info.pd <- ::World.Assets.m.IsPermanentDestruction;
			info.ex <- ::World.Assets.m.IsExplorationMode;
			info.ge <- ::World.FactionManager.getGreaterEvil().Type;
		}
		catch (error)
		{
			::BBCoop.log("Could not read all campaign settings for " + _from + ": " + error);
		}
		::BBCoop.Connection.sendMessage("session_info", info);
		::BBCoop.notify(_from + " is joining your world.");
	}

	// ---- joiner ----

	// The new campaign screen's choices, with everything but origin, banner and name replaced
	// by the host's settings (v0.30.0). Called from world_state.setNewCampaignSettings.
	function forceHostSettings( _settings )
	{
		local info = this.Pending;
		if (info == null) return;
		_settings.Seed = info.seed;
		if (("cd" in info) && info.cd != null) _settings.Difficulty = info.cd;
		if (("ed" in info) && info.ed != null) _settings.EconomicDifficulty = info.ed;
		if (("im" in info) && info.im != null) _settings.Ironman = info.im;
		if (("pd" in info) && info.pd != null) _settings.PermanentDestruction = info.pd;
		if (("ex" in info) && info.ex != null) _settings.ExplorationMode = info.ex;
		if (("ge" in info) && info.ge != null) _settings.GreaterEvil = info.ge;
		_settings.BudgetDifficulty = 1; // starting funds aren't kept in a save: every joiner gets Medium
		::BBCoop.log(format("Joining with %s's campaign settings (difficulty %s/%s, ironman %s, unexplored %s)", info.host, "" + _settings.Difficulty, "" + _settings.EconomicDifficulty, "" + _settings.Ironman, "" + _settings.ExplorationMode));
	}

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
		// from now on this world follows the host's: parties and camps (world.nut), day and hour (time.nut)
		::World.Flags.set("BBCoopHost", info.host);
		::BBCoop.Time.reset();
		if (("cd" in info) && info.cd != null)
		{
			try
			{
				::World.Assets.m.CombatDifficulty = info.cd;
				::World.Assets.m.EconomicDifficulty = info.ed;
			}
			catch (error)
			{
				::BBCoop.log("Could not copy the host's difficulty: " + error);
			}
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
	q.setNewCampaignSettings = @(__original) function( _settings )
	{
		try { ::BBCoop.Join.forceHostSettings(_settings); }
		catch (error) { ::BBCoop.log("Forcing the host's campaign settings failed: " + error); }
		return __original(_settings);
	}

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

// Same origin, different brothers (v0.26.0): the new campaign seeds the dice with the map seed
// right before the origin rolls its starting brothers, so a joiner who picked the host's origin
// got the host's exact brothers. A joiner's company is rolled from the map seed plus their name
// instead (the map itself is built before this, from the seed alone, so it still matches).
// Checked against vanilla world_state.startNewCampaign (seedRandomString, then onSpawnPlayer).
::BBCoop.MH.hookTree("scripts/scenarios/world/starting_scenario", function(q) {
	q.onSpawnPlayer = @(__original) function()
	{
		try
		{
			local info = ::BBCoop.Join.Pending;
			if (info != null) ::Math.seedRandomString(info.seed + "|" + ::BBCoop.getSetting("PlayerName"));
		}
		catch (error)
		{
			::BBCoop.log("Could not reroll the starting company: " + error);
		}
		return __original();
	}
});
