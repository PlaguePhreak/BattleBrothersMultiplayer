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
	MirrorOwners = {},      // owner name -> { sent = { entity id -> true } }: they see the real battlefield
	PlayerOrigins = {},     // player name -> origin id, sent by the relay's test bot
	// Join window (Aaron's design, v0.30.0): before round 1 the battle waits up to GatherSeconds for
	// the other players to join, so their brothers start next to ours and act from round 1
	GatherSeconds = 20.0,
	GatherUntil = 0.0,      // > 0 while waiting
	GatherPlayers = [],     // online players asked
	GatherAnswered = {},    // player -> true once they joined or said no
	FirstRoundHeld = false, // vanilla's first initNextRound, put off until the window closes

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
		this.LateJoins.clear();
		this.JoinedOwners.clear();
		this.MirrorOwners.clear();
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
		this.GatherUntil = 0.0;
		this.GatherAnswered.clear();
		this.FirstRoundHeld = false;
		this.GatherPlayers = this.getOnlineOthers();
		if (this.GatherPlayers.len() != 0)
		{
			this.GatherUntil = ::Time.getRealTimeF() + this.GatherSeconds;
			payload.gather <- this.GatherSeconds.tointeger();
			::BBCoop.notify(format("Waiting up to %i seconds for nearby players to join before the battle starts.", this.GatherSeconds.tointeger()));
		}
		// The relay's test bot can't make brothers itself, so our game rolls a fresh company for it
		if (::BBCoop.Connection.isBotEnabled())
			payload.company <- ::BBCoop.Roster.rollCompany("Bot" in this.PlayerOrigins ? this.PlayerOrigins["Bot"] : "mercenaries");

		::BBCoop.Connection.sendMessage("battle_start", payload);
		::BBCoop.log("Battle started, told other players (" + this.HostBattleID + ")");
	}

	function getOnlineOthers()
	{
		local me = ::BBCoop.getSetting("PlayerName");
		local ret = [];
		foreach (name, time in ::BBCoop.Seen)
			if (name != me && ::BBCoop.isOnline(name, 15.0)) ret.push(name);
		return ret;
	}

	function isGathering()
	{
		return this.GatherUntil > 0.0;
	}

	// Every frame of our battle before round 1 while the join window is open. True: hold the battle.
	function updateGather( _state )
	{
		if (this.GatherUntil <= 0.0) return false;
		local now = ::Time.getRealTimeF();
		local waiting = 0;
		foreach (p in this.GatherPlayers)
			if (!(p in this.GatherAnswered) && ::BBCoop.isOnline(p, 15.0)) waiting++;
		if (this.HostBattleID == null || waiting == 0 || now >= this.GatherUntil)
		{
			this.GatherUntil = 0.0;
			local joined = this.JoinedOwners.len();
			::BBCoop.notify(joined != 0 ? "Everyone is here. The battle begins!" : "Nobody joined in time. The battle begins.");
			::BBCoop.log(format("Join window closed: %i joined, %i still undecided", joined, waiting));
			if (this.FirstRoundHeld)
			{
				this.FirstRoundHeld = false;
				::Tactical.TurnSequenceBar.initNextRound();
			}
			return false;
		}
		_state.setInputLocked(true);
		try { if (::LoadingScreen.isVisible() && !::LoadingScreen.isAnimating()) ::LoadingScreen.hide(); } catch (error) {}
		return true;
	}

	function onDecline( _from, _payload )
	{
		if (this.HostBattleID == null || _payload.battleID != this.HostBattleID) return;
		this.GatherAnswered[_from] <- true;
		if (this.isGathering()) ::BBCoop.log(_from + " is not joining the battle");
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
		this.GatherAnswered[_from] <- true;

		local side = ("side" in _payload) && _payload.side == "enemy" ? "enemy" : "ally";
		// joiners build a copy of our battlefield and watch it there
		if (("mirror" in _payload) && _payload.mirror)
		{
			this.MirrorOwners[_from] <- { sent = {} };
			if (!::BBCoop.Mirror.sendScene(_from)) delete this.MirrorOwners[_from];
		}
		// Aaron's rule: in the join window they line up with their side; after it they arrive at the
		// map edge when the current round ends
		if (!this.isGathering() && this.hasRoundStarted())
		{
			this.LateJoins.push({ owner = _from, bros = _payload.bros, side = side });
			::BBCoop.notify(format("%s joins the battle%s at the end of this round.", _from, side == "enemy" ? " AGAINST you" : ""));
			::BBCoop.log(_from + " joins at the end of the round");
			local now = null;
			try { now = ::Tactical.TurnSequenceBar.getActiveEntity(); } catch (error) {}
			::BBCoop.Remote.sendView(_from, now);
			return;
		}
		this.bringIn(_from, _payload.bros, side);
	}

	LateJoins = [],         // { owner, bros, side } waiting for the end of the round

	function hasRoundStarted()
	{
		local round = 0;
		try { round = ::Tactical.TurnSequenceBar.getCurrentRound(); } catch (error) {}
		return round > 0;
	}

	// The end of a round (just before the next starts): late joiners arrive at the edge
	function onRoundEnd()
	{
		if (this.HostBattleID == null || this.LateJoins.len() == 0) return;
		local list = this.LateJoins;
		this.LateJoins = [];
		foreach (j in list)
		{
			try { this.bringIn(j.owner, j.bros, j.side); }
			catch (error) { ::BBCoop.log("Could not bring in " + j.owner + "'s company: " + error); }
		}
	}

	function bringIn( _from, _bros, side )
	{
		local spawned = this.spawnReinforcements(_from, _bros, side);
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
		// during the join window they line up next to their side; later they arrive at the map edge
		local tiles = this.isGathering() ? this.findTilesNear(_bros.len(), faction) : this.findEdgeTiles(_bros.len(), faction);
		if (tiles.len() < _bros.len()) tiles.extend(this.findEdgeTiles(_bros.len() - tiles.len(), faction));
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

	// Where a side stands: the middle of its units on the map
	function getSideCentre( _faction )
	{
		local size = ::Tactical.getMapSize();
		local group = [];
		try
		{
			if (_faction == ::Const.Faction.Player) group = ::Tactical.Entities.getInstancesOfFaction(::Const.Faction.Player);
			else group = ::Tactical.Entities.getAllHostilesAsArray();
		}
		catch (error) {}
		local sumX = 0, sumY = 0, n = 0;
		foreach (e in group)
		{
			if (e == null || !e.isPlacedOnMap()) continue;
			local t = e.getTile();
			sumX += t.SquareCoords.X;
			sumY += t.SquareCoords.Y;
			n++;
		}
		return n > 0 ? { x = sumX / n, y = sumY / n, n = n } : { x = size.X / 2, y = size.Y / 2, n = 0 };
	}

	// Free tiles around a side's units, closest first (rings outward from their middle)
	function findTilesNear( _count, _faction = 1 )
	{
		local c = this.getSideCentre(_faction);
		local ret = [];
		for (local r = 1; r <= 14 && ret.len() < _count; r++)
		{
			for (local dx = -r; dx <= r && ret.len() < _count; dx++)
			{
				for (local dy = -r; dy <= r && ret.len() < _count; dy++)
				{
					if (dx != -r && dx != r && dy != -r && dy != r) continue; // only the ring itself
					local x = c.x + dx, y = c.y + dy;
					if (!::Tactical.isValidTileSquare(x, y)) continue;
					local tile = ::Tactical.getTileSquare(x, y);
					if (!tile.IsEmpty || tile.IsOccupiedByActor) continue;
					ret.push(tile);
				}
			}
		}
		return ret;
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
		try { ::BBCoop.Connection.setTurnNotice(null); } catch (error) {}
		this.GatherUntil = 0.0;
		this.FirstRoundHeld = false;
		this.LateJoins.clear();
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
		this.MirrorOwners.clear();
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

	// Tell the host we won't join, so its join window doesn't wait for us
	function sendDecline( _host, _battleID )
	{
		::BBCoop.Connection.sendMessage("battle_decline", { to = _host, battleID = _battleID });
	}

	function onBattleStartMessage( _from, _payload )
	{
		if (this.isInTactical() || this.PendingRefs != null || _payload.pos == null)
		{
			this.sendDecline(_from, _payload.battleID); // busy with our own fight, or already fighting elsewhere
			return;
		}

		local dist = 0.0;
		try { dist = this.distanceTo(_payload.pos); } catch (error) { this.sendDecline(_from, _payload.battleID); return; }
		local clan = ("clan" in _payload) ? _payload.clan : "";
		this.Invite = {
			host = _from, battleID = _payload.battleID, time = ::Time.getRealTimeF(), pos = _payload.pos, clan = clan,
			enemies = ("enemies" in _payload) ? _payload.enemies : []
		};
		if (dist > this.JoinRange)
		{
			::BBCoop.log(format("%s started a battle %.0f units away (join range %.0f)", _from, dist, this.JoinRange));
			this.sendDecline(_from, _payload.battleID);
			return;
		}
		local text = this.describeInvite(this.Invite) + " nearby.";
		if ("gather" in _payload)
			text += format(" Join within %i seconds and your brothers start the battle next to theirs.", _payload.gather);
		this.showJoinPrompt(text, false);
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
		if (this.Invite != null && (_choice == "no" || _choice == "own"))
			this.sendDecline(this.Invite.host, this.Invite.battleID);
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
		::BBCoop.Mirror.leave();
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
		::BBCoop.Mirror.Result = null;
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
		::BBCoop.Connection.sendMessage("battle_join", { battleID = this.Invite.battleID, to = this.Invite.host, bros = packed.bros, side = _side, mirror = ::BBCoop.Mirror.isEnabled() });
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
		if (_from != this.PendingHost) return;
		// watching the copy of the battle: apply the result once we are back on the world map
		if (::BBCoop.Mirror.keepResult(_from, _payload)) return;
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
		// a copy of another player's battle (mirror.nut): same seed, then their units
		local mirror = false;
		try { mirror = ::BBCoop.Mirror.beforeInitMap(this); }
		catch (error) { ::BBCoop.log("Mirror setup failed: " + error); }
		if (!mirror)
		{
			try { ::BBCoop.Mirror.seedHostMap(this); }
			catch (error) { ::BBCoop.log("Seeding the map failed: " + error); }
		}
		__original();
		if (mirror)
		{
			try { ::BBCoop.Mirror.afterInitMap(this); }
			catch (error) { ::BBCoop.log("Building the copy of the battle failed: " + error); }
			return;
		}
		try { ::BBCoop.Mirror.afterHostMap(); }
		catch (error) { ::BBCoop.log("Map fingerprint failed: " + error); }
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
		try { ::BBCoop.Mirror.onTacticalFinish(); }
		catch (error) { ::BBCoop.log("Closing the copy of the battle failed: " + error); }
		__original();
	}
});

// The join window holds vanilla's first round until the other players had their chance to join
::BBCoop.MH.hook("scripts/ui/screens/tactical/modules/turn_sequence_bar/turn_sequence_bar", function(q) {
	q.initNextRound = @(__original) function( ... )
	{
		local copy = false;
		try { copy = ::BBCoop.Mirror.Active; } catch (error) {}
		if (::BBCoop.Battle.isGathering() && !copy)
		{
			::BBCoop.Battle.FirstRoundHeld = true;
			return;
		}
		// before the new round's turn order is made, so late joiners act in it
		if (!copy)
		{
			try { ::BBCoop.Battle.onRoundEnd(); } catch (error) { ::BBCoop.log("Late joiners: " + error); }
		}
		local args = [this];
		args.extend(vargv);
		return __original.acall(args);
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
