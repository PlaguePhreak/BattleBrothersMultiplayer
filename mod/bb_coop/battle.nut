// Shared battles, part 1.
// Host: the player whose battle it is. When their battle starts, the other players are told.
// Ally: a player whose company is close enough can join. Their brothers arrive at the map edge
// as reinforcements in the host's battle. When it ends, each brother's new state (or death)
// is sent back and replaces the original in the ally's roster.
// Each player plays their own brothers through remote.nut (part 2).
// Checked against the decompiled vanilla scripts (tactical_entity_manager, tactical_state, player).

::BBCoop.Battle <- {
	JoinRange = 600.0,      // world units between the two companies

	// ---- host side ----
	HostBattleID = null,    // set while we host a battle
	Reinforcements = [],    // { key, owner, name, bro = WeakTableRef }
	JoinedOwners = {},      // owner name -> true
	PlayerOrigins = {},     // player name -> origin id, sent by the relay's test bot

	// ---- ally side ----
	Invite = null,          // { host, battleID, time } offer we can accept with the keybind
	PendingRefs = null,     // key -> WeakTableRef to our real brother while it fights elsewhere
	PendingHost = null,

	function isInTactical()
	{
		return ::MSU.Utils.hasState("tactical_state");
	}

	// ================= host =================

	function onBattleStarted()
	{
		try
		{
			if (::Tactical.State.isScenarioMode()) return;
		}
		catch (error) {}

		this.HostBattleID = ::BBCoop.getSetting("PlayerName") + "_" + ::Time.getRealTime();
		this.Reinforcements.clear();
		this.JoinedOwners.clear();
		::BBCoop.Remote.reset();
		::BBCoop.Loot.onBattleStarted();

		local pos = null;
		try
		{
			local p = ::World.State.getPlayer().getPos();
			pos = { x = p.X, y = p.Y };
		}
		catch (error) {}

		local payload = { battleID = this.HostBattleID, pos = pos, clan = ::BBCoop.getClan(), enemies = this.getEnemyNames() };
		// The relay's test bot can't make brothers itself, so our game rolls a fresh company for it
		if (::BBCoop.Connection.isBotEnabled())
			payload.company <- ::BBCoop.Roster.rollCompany("Bot" in this.PlayerOrigins ? this.PlayerOrigins["Bot"] : "mercenaries");

		::BBCoop.Connection.sendMessage("battle_start", payload);
		::BBCoop.log("Battle started, told other players (" + this.HostBattleID + ")");
	}

	// Names of the enemy parties, for the join prompt ("fighting Brigand Raiders")
	function getEnemyNames()
	{
		local ret = [];
		try
		{
			foreach (party in ::Tactical.State.getStrategicProperties().Parties)
				if (party != null && !party.isAlliedWithPlayer() && ret.find(party.getName()) == null) ret.push(party.getName());
		}
		catch (error) {}
		return ret;
	}

	function onJoinRequest( _from, _payload )
	{
		if (this.HostBattleID == null || !this.isInTactical() || _payload.battleID != this.HostBattleID)
		{
			::BBCoop.log(_from + " tried to join a battle that is already over");
			::BBCoop.Connection.sendMessage("join_refused", { to = _from, battleID = _payload.battleID, text = "That battle is already over." });
			return;
		}
		if (_from in this.JoinedOwners) return;
		this.JoinedOwners[_from] <- true;

		local side = ("side" in _payload) && _payload.side == "enemy" ? "enemy" : "ally";
		local spawned = this.spawnReinforcements(_from, _payload.bros, side);
		if (side == "enemy")
			::BBCoop.notify(format("%s's company joins the battle AGAINST you (%i brothers)!", _from, spawned));
		else
			::BBCoop.notify(format("%s's company arrives as reinforcements (%i brothers)! %s plays them.", _from, spawned, _from));
		local active = null;
		try { active = ::Tactical.TurnSequenceBar.getActiveEntity(); } catch (error) {}
		::BBCoop.Remote.sendView(_from, active);
	}

	// The hostile faction with the most fighters here; joiners against us fight for it
	function getEnemyFaction()
	{
		local f = 0;
		try { f = ::Tactical.Entities.getHostileFactionWithMostInstances(); } catch (error) {}
		return f > 0 ? f : ::Const.Faction.Bandits;
	}

	function spawnReinforcements( _owner, _bros, _side = "ally" )
	{
		local faction = _side == "enemy" ? this.getEnemyFaction() : ::Const.Faction.Player;
		local tiles = this.findEdgeTiles(_bros.len(), faction);
		local count = 0;
		foreach (i, entry in _bros)
		{
			if (i >= tiles.len())
			{
				::BBCoop.log("No free edge tile left for " + entry.name);
				break;
			}
			try
			{
				local bro = ::World.getTemporaryRoster().create("scripts/entity/tactical/player");
				::BBCoop.Roster.deserializeInto(bro, entry.raw);
				if ("look" in entry) ::BBCoop.Roster.applyAppearance(bro, entry.look);
				bro.setName(entry.name);
				bro.getFlags().set("BBCoopOwner", _owner);
				bro.getFlags().set("BBCoopKey", entry.key);
				// Guests are player-controlled but stay out of our roster, obituary, score and result screen
				bro.setGuest(true);
				bro.setFaction(faction);
				::Tactical.addEntityToMap(bro, tiles[i].Coords.X, tiles[i].Coords.Y);
				bro.onCombatStart();
				if (_side == "ally") ::BBCoop.Loot.recordItems(bro, _owner);
				this.Reinforcements.push({ key = entry.key, owner = _owner, name = entry.name, side = _side, bro = ::WeakTableRef(bro) });
				count++;
			}
			catch (error)
			{
				::BBCoop.log("Could not bring in " + entry.name + ": " + error);
			}
		}
		return count;
	}

	// Free tiles along the map edge nearest to the side being joined
	function findEdgeTiles( _count, _faction = 1 )
	{
		local size = ::Tactical.getMapSize();
		local sumX = 0, sumY = 0, n = 0;
		local group = [];
		if (_faction == ::Const.Faction.Player) group = ::World.getPlayerRoster().getAll();
		else
		{
			try { group = ::Tactical.Entities.getAllHostilesAsArray(); } catch (error) {}
		}
		foreach (bro in group)
		{
			if (bro == null || !bro.isPlacedOnMap()) continue;
			local t = bro.getTile();
			sumX += t.SquareCoords.X;
			sumY += t.SquareCoords.Y;
			n++;
		}
		local cx = n > 0 ? sumX / n : size.X / 2;
		local cy = n > 0 ? sumY / n : size.Y / 2;

		// pick the closest of the four edges
		local dists = [cx, size.X - 1 - cx, cy, size.Y - 1 - cy];
		local edge = 0;
		for (local i = 1; i < 4; i++)
			if (dists[i] < dists[edge]) edge = i;

		local ret = [];
		// walk outward from the point on that edge closest to our brothers, 2 tiles deep
		for (local depth = 1; depth <= 2 && ret.len() < _count; depth++)
		{
			for (local off = 0; off < 40 && ret.len() < _count; off++)
			{
				foreach (sign in [1, -1])
				{
					if (off == 0 && sign == -1) continue;
					local x = 0, y = 0;
					switch (edge)
					{
						case 0: x = depth; y = cy + off * sign; break;
						case 1: x = size.X - 1 - depth; y = cy + off * sign; break;
						case 2: x = cx + off * sign; y = depth; break;
						default: x = cx + off * sign; y = size.Y - 1 - depth; break;
					}
					if (!::Tactical.isValidTileSquare(x, y)) continue;
					local tile = ::Tactical.getTileSquare(x, y);
					if (!tile.IsEmpty || tile.IsOccupiedByActor) continue;
					ret.push(tile);
					if (ret.len() >= _count) break;
				}
			}
		}
		return ret;
	}

	function onBattleEnded()
	{
		if (this.HostBattleID == null) return;
		local battleID = this.HostBattleID;
		this.HostBattleID = null;
		::BBCoop.Remote.reset();

		local byOwner = {};
		foreach (r in this.Reinforcements)
		{
			if (!(r.owner in byOwner)) byOwner[r.owner] <- [];
			local entry = { key = r.key, name = r.name, dead = true, raw = null };
			if (r.bro != null && !r.bro.isNull() && r.bro.isAlive())
			{
				entry.dead = false;
				try
				{
					try { r.bro.onCombatFinished(); } catch (e) {}
					entry.raw = ::BBCoop.Roster.serializeBrother(r.bro);
				}
				catch (error)
				{
					::BBCoop.log("Could not pack result for " + r.name + ": " + error);
					entry.raw = null;
				}
			}
			byOwner[r.owner].push(entry);
		}

		local hostWon = false;
		try
		{
			local r = ::Tactical.Entities.getCombatResult();
			hostWon = r == ::Const.Tactical.CombatResult.EnemyDestroyed || r == ::Const.Tactical.CombatResult.EnemyRetreated;
		}
		catch (error) {}

		foreach (owner, results in byOwner)
			::BBCoop.Connection.sendMessage("battle_result", { battleID = battleID, to = owner, bros = results, hostWon = hostWon });
		::BBCoop.Connection.sendMessage("battle_over", { battleID = battleID });

		// remove the visiting brothers from our game
		foreach (r in this.Reinforcements)
		{
			if (r.bro != null && !r.bro.isNull())
				::World.getTemporaryRoster().remove(r.bro);
		}
		this.Reinforcements.clear();
		this.JoinedOwners.clear();
	}

	// ================= ally =================

	PendingSide = "ally",
	PendingBattleID = null,
	HostTimeout = 60.0,     // no word from the host this long while away: our brothers come home
	LocalEnemies = null,    // world parties we attacked ourselves before joining (removed if our side wins)
	CombatArgs = null,      // vanilla combat dialog put on hold while the join prompt is open
	EngageRange = 400.0,    // attacking within this distance of another player's battle offers to join it

	function isClanmate( _clan )
	{
		local mine = ::BBCoop.getClan();
		return mine != "" && _clan != null && _clan == mine;
	}

	function distanceTo( _pos )
	{
		local me = ::World.State.getPlayer().getPos();
		local dx = me.X - _pos.x, dy = me.Y - _pos.y;
		return ::Math.pow(dx * dx + dy * dy, 0.5);
	}

	function describeInvite( _invite )
	{
		local text = _invite.host + " is fighting";
		if (_invite.enemies.len() != 0) text += " " + _invite.enemies.reduce(@(a, b) a + ", " + b);
		return text;
	}

	function onBattleStartMessage( _from, _payload )
	{
		if (this.isInTactical()) return; // busy with our own fight
		if (this.PendingRefs != null) return; // already fighting elsewhere
		if (_payload.pos == null) return;

		local dist = 0.0;
		try { dist = this.distanceTo(_payload.pos); } catch (error) { return; }
		local clan = ("clan" in _payload) ? _payload.clan : "";
		this.Invite = {
			host = _from, battleID = _payload.battleID, time = ::Time.getRealTimeF(), pos = _payload.pos, clan = clan,
			enemies = ("enemies" in _payload) ? _payload.enemies : []
		};
		if (dist > this.JoinRange)
		{
			::BBCoop.log(format("%s started a battle %.0f units away (join range %.0f)", _from, dist, this.JoinRange));
			return;
		}
		this.showJoinPrompt(this.describeInvite(this.Invite) + " nearby.", false);
	}

	// Clanmates only get "join"; everyone else picks a side
	function showJoinPrompt( _text, _fromEngage )
	{
		local invite = this.Invite;
		local options = [];
		if (this.isClanmate(invite.clan))
		{
			_text += " They are in your clan.";
			options.push({ id = "ally", label = "Join as " + invite.host + "'s ally" });
		}
		else
		{
			options.push({ id = "ally", label = "Join on " + invite.host + "'s side" });
			options.push({ id = "enemy", label = "Join against " + invite.host });
		}
		options.push({ id = _fromEngage ? "own" : "no", label = _fromEngage ? "Fight on my own" : "Stay out" });
		::BBCoop.Connection.showPrompt({ id = "join:" + invite.battleID, title = "Battle nearby", text = _text, options = options });
	}

	function onPromptChoice( _id, _choice )
	{
		if (_id.find("join:") != 0) return;
		local fromEngage = this.CombatArgs != null;
		if (_choice == "ally" || _choice == "enemy")
		{
			if (fromEngage) this.LocalEnemies = this.CombatArgs.enemies;
			this.CombatArgs = null;
			if (!this.acceptInvite(_choice)) this.LocalEnemies = null;
			return;
		}
		if (_choice == "own" && fromEngage)
		{
			local args = this.CombatArgs;
			this.CombatArgs = null;
			this.Invite = null; // don't ask again for this fight
			::World.State.showCombatDialog(args.a, args.b, args.c, args.d, args.e);
		}
	}

	// Our brothers come back as they left: nothing happened to them in our world
	function releaseAway( _reason )
	{
		if (this.PendingRefs == null) return;
		this.PendingRefs = null;
		this.PendingHost = null;
		this.PendingBattleID = null;
		this.LocalEnemies = null;
		::BBCoop.Connection.closeBattlePanel();
		::BBCoop.notify(_reason + " Your brothers are back, unharmed.");
	}

	function onLeaveWorld()
	{
		this.PendingRefs = null;
		this.PendingHost = null;
		this.PendingBattleID = null;
		this.LocalEnemies = null;
		this.Invite = null;
		this.CombatArgs = null;
		::BBCoop.Connection.closeBattlePanel();
	}

	function onJoinRefused( _from, _payload )
	{
		if (this.PendingRefs != null && _from == this.PendingHost && _payload.battleID == this.PendingBattleID)
			this.releaseAway(_from + ": " + _payload.text);
	}

	// Every world frame while our brothers are away
	function updateAway()
	{
		if (this.PendingRefs == null) return;
		try { if (!::World.State.isPaused()) ::World.State.setPause(true); } catch (error) {}
		if (!::BBCoop.isOnline(this.PendingHost, this.HostTimeout))
			this.releaseAway("Lost contact with " + this.PendingHost + " during the battle.");
	}

	function onBattleOver( _from, _payload )
	{
		// results come before this message; if none came, they are lost
		if (this.PendingRefs != null && _from == this.PendingHost && _payload.battleID == this.PendingBattleID)
			this.releaseAway("No results arrived from " + _from + "'s battle.");

		if (this.Invite != null && this.Invite.battleID == _payload.battleID)
		{
			this.Invite = null;
			::BBCoop.Connection.closePrompt("join:" + _payload.battleID);
		}
	}

	// Called from the combat dialog hook: we are about to fight next to someone else's battle
	function interceptCombat( _a, _b, _c, _d, _e )
	{
		if (this.CombatArgs != null || this.PendingRefs != null) return true; // prompt open or already away fighting
		if (this.Invite == null || ::Time.getRealTimeF() - this.Invite.time > 900.0) return false;
		local dist = 9999.0;
		try { dist = this.distanceTo(this.Invite.pos); } catch (error) {}
		if (dist > this.EngageRange) return false;

		local enemies = [];
		try
		{
			local pos = _e != null ? _e : ::World.State.getPlayer().getPos();
			foreach (party in ::World.getAllEntitiesAtPos(pos, ::Const.World.CombatSettings.CombatPlayerDistance))
			{
				if (party.isAlive() && !party.isPlayerControlled() && !party.isAlliedWithPlayer() && !party.isLocation())
					enemies.push(::WeakTableRef(party));
			}
		}
		catch (error) {}

		this.CombatArgs = { a = _a, b = _b, c = _c, d = _d, e = _e, enemies = enemies };
		try { ::World.State.setPause(true); } catch (error) {}
		this.showJoinPrompt(this.describeInvite(this.Invite) + " right here. Join their battle instead of starting your own?", true);
		return true;
	}

	// _side: "ally", "enemy", or null (Ctrl+B: ally for clanmates and by default)
	function acceptInvite( _side )
	{
		if (this.Invite == null || ::Time.getRealTimeF() - this.Invite.time > 900.0)
		{
			::BBCoop.notify("There is no battle nearby to join.");
			return false;
		}
		if (_side == null) _side = "ally";
		local packed = ::BBCoop.Roster.packCompany(::BBCoop.getSetting("PlayerName"));
		if (packed.bros.len() == 0)
		{
			::BBCoop.notify("None of your brothers can fight.");
			return false;
		}
		this.PendingRefs = packed.refs;
		this.PendingHost = this.Invite.host;
		this.PendingSide = _side;
		this.PendingBattleID = this.Invite.battleID;
		::BBCoop.Seen[this.PendingHost] <- ::Time.getRealTimeF();
		::BBCoop.Connection.sendMessage("battle_join", { battleID = this.Invite.battleID, to = this.Invite.host, bros = packed.bros, side = _side });
		this.Invite = null;
		try { ::World.State.setPause(true); } catch (error) {}
		if (_side == "enemy")
			::BBCoop.notify(format("Your company attacks %s! Results arrive when the battle ends.", this.PendingHost));
		else
			::BBCoop.notify(format("Your company marches into %s's battle. Results arrive when it ends.", this.PendingHost));
		return true;
	}

	// Same bookkeeping vanilla does for a brother lost in battle
	function burial( _bro, _host )
	{
		try
		{
			::World.Statistics.addFallen({
				Name = _bro.getName(),
				Time = ::World.getTime().Days,
				TimeWithCompany = ::Math.max(1, _bro.getDaysWithCompany()),
				Kills = _bro.getLifetimeStats().Kills,
				Battles = _bro.getLifetimeStats().Battles + 1,
				KilledBy = "Fell in " + _host + "'s battle",
				Expendable = _bro.getBackground().getID() == "background.slave"
			});
			_bro.getSkills().onDeath(::Const.FatalityType.None);
		}
		catch (error)
		{
			::BBCoop.log("Obituary failed for " + _bro.getName() + ": " + error);
		}
		::World.getPlayerRoster().remove(_bro);
		try { _bro.die(); } catch (error) {}
	}

	function onBattleResult( _from, _payload )
	{
		if (this.PendingRefs == null) return;
		local died = [], survived = 0;
		foreach (entry in _payload.bros)
		{
			if (!(entry.key in this.PendingRefs)) continue;
			local original = this.PendingRefs[entry.key];
			if (original == null || original.isNull()) continue;

			if (entry.dead)
			{
				died.push(entry.name);
				this.burial(original, _from);
				continue;
			}
			if (entry.raw == null) continue; // keep the original if packing failed

			try
			{
				local bro = ::World.getPlayerRoster().create("scripts/entity/tactical/player");
				::BBCoop.Roster.deserializeInto(bro, entry.raw);
				::BBCoop.Roster.copyAppearance(original, bro); // engine-saved sprites aren't in the data
				::World.getPlayerRoster().remove(original);
				survived++;
			}
			catch (error)
			{
				::BBCoop.log("Could not apply result for " + entry.name + ": " + error);
			}
		}
		this.PendingRefs = null;
		this.PendingHost = null;
		this.PendingBattleID = null;

		// We fought next to the host against the parties we had attacked ourselves: if the host's side
		// won, those parties are beaten in our world too
		local hostWon = ("hostWon" in _payload) && _payload.hostWon;
		local ourSideWon = this.PendingSide == "enemy" ? !hostWon : hostWon;
		if (this.LocalEnemies != null && this.PendingSide == "ally" && hostWon)
		{
			foreach (ref in this.LocalEnemies)
			{
				if (ref == null || ref.isNull()) continue;
				try
				{
					local party = ref.get();
					if (!party.isAlive()) continue;
					if ("fadeOutAndDie" in party) party.fadeOutAndDie();
					else party.die();
				}
				catch (error) { ::BBCoop.log("Could not remove a beaten party: " + error); }
			}
		}
		this.LocalEnemies = null;

		local text = format("The battle with %s is over, your side %s. %i of your brothers came back", _from, ourSideWon ? "won" : "lost", survived);
		if (died.len() != 0) text += ". Fallen: " + died.reduce(@(a, b) a + ", " + b);
		::BBCoop.notify(text + ".");
	}
};

// Hook points: Legends replaces tactical_entity_manager.spawn and tactical_state.onBattleEnded
// outright (without calling the original), so hooks there never run with Legends installed.
// initMap and onFinish are left alone by Legends and exist in vanilla.
::BBCoop.MH.hook("scripts/states/tactical_state", function(q) {
	q.initMap = @(__original) function()
	{
		__original();
		try
		{
			::BBCoop.Battle.onBattleStarted();
		}
		catch (error)
		{
			::BBCoop.log("onBattleStarted failed: " + error);
		}
	}

	q.onFinish = @(__original) function()
	{
		try
		{
			::BBCoop.Battle.onBattleEnded();
		}
		catch (error)
		{
			::BBCoop.log("onBattleEnded failed: " + error);
		}
		__original();
	}
});

// Attacking (or being attacked) right next to another player's battle offers to join it instead
::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.showCombatDialog = @(__original) function( _isPlayerInitiated = true, _isCombatantsVisible = true, _allowFormationPicking = true, _properties = null, _pos = null )
	{
		local intercepted = false;
		try
		{
			intercepted = ::BBCoop.Battle.interceptCombat(_isPlayerInitiated, _isCombatantsVisible, _allowFormationPicking, _properties, _pos);
		}
		catch (error)
		{
			::BBCoop.log("Join check failed: " + error);
		}
		if (intercepted) return;
		return __original(_isPlayerInitiated, _isCombatantsVisible, _allowFormationPicking, _properties, _pos);
	}
});

// Leaving the campaign (main menu, loading a save) ends any battle we were following
::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.onFinish = @(__original) function()
	{
		try { ::BBCoop.Battle.onLeaveWorld(); } catch (error) { ::BBCoop.log("onLeaveWorld failed: " + error); }
		__original();
	}
});

// While our brothers fight elsewhere, the world stays paused and we watch for the host going quiet
::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.onUpdate = @(__original) function()
	{
		__original();
		try
		{
			::BBCoop.Battle.updateAway();
		}
		catch (error)
		{
			::BBCoop.log("updateAway failed: " + error);
		}
	}
});
