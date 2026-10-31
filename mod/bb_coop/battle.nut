// Shared battles, part 1.
// Host: the player whose battle it is. When their battle starts, the other players are told.
// Ally: a player whose company is close enough can join. Their brothers arrive at the map edge
// as reinforcements in the host's battle. When it ends, each brother's new state (or death)
// is sent back and replaces the original in the ally's roster.
// For now the host controls the reinforcements; remote control comes in part 2.
// Checked against the decompiled vanilla scripts (tactical_entity_manager, tactical_state, player).

::BBCoop.Battle <- {
	JoinRange = 600.0,      // world units between the two companies

	// ---- host side ----
	HostBattleID = null,    // set while we host a battle
	Reinforcements = [],    // { key, owner, name, bro = WeakTableRef }
	JoinedOwners = {},      // owner name -> true

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

		local pos = null;
		try
		{
			local p = ::World.State.getPlayer().getPos();
			pos = { x = p.X, y = p.Y };
		}
		catch (error) {}

		local payload = { battleID = this.HostBattleID, pos = pos };
		// The relay's test bot has no brothers of its own, so it joins with a copy of ours
		if (::BBCoop.Connection.isBotEnabled())
			payload.company <- ::BBCoop.Roster.packCompany("bot").bros;

		::BBCoop.Connection.sendMessage("battle_start", payload);
		::BBCoop.log("Battle started, told other players (" + this.HostBattleID + ")");
	}

	function onJoinRequest( _from, _payload )
	{
		if (this.HostBattleID == null || !this.isInTactical())
		{
			::BBCoop.log(_from + " tried to join, but we are not in a battle");
			return;
		}
		if (_payload.battleID != this.HostBattleID)
		{
			::BBCoop.log(_from + " tried to join an old battle");
			return;
		}
		if (_from in this.JoinedOwners) return;
		this.JoinedOwners[_from] <- true;

		local spawned = this.spawnReinforcements(_from, _payload.bros);
		::BBCoop.notify(format("%s's company arrives as reinforcements (%i brothers)!", _from, spawned));
	}

	function spawnReinforcements( _owner, _bros )
	{
		local tiles = this.findEdgeTiles(_bros.len());
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
				bro.setName(entry.name);
				bro.getFlags().set("BBCoopOwner", _owner);
				// Guests are player-controlled but stay out of our roster, obituary, score and result screen
				bro.setGuest(true);
				bro.setFaction(::Const.Faction.Player);
				::Tactical.addEntityToMap(bro, tiles[i].Coords.X, tiles[i].Coords.Y);
				bro.onCombatStart();
				this.Reinforcements.push({ key = entry.key, owner = _owner, name = entry.name, bro = ::WeakTableRef(bro) });
				count++;
			}
			catch (error)
			{
				::BBCoop.log("Could not bring in " + entry.name + ": " + error);
			}
		}
		return count;
	}

	// Free tiles along the map edge nearest to our own brothers
	function findEdgeTiles( _count )
	{
		local size = ::Tactical.getMapSize();
		local sumX = 0, sumY = 0, n = 0;
		foreach (bro in ::World.getPlayerRoster().getAll())
		{
			if (!bro.isPlacedOnMap()) continue;
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

		foreach (owner, results in byOwner)
			::BBCoop.Connection.sendMessage("battle_result", { battleID = battleID, to = owner, bros = results });

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

	function onBattleStartMessage( _from, _payload )
	{
		if (this.isInTactical()) return; // busy with our own fight
		if (this.PendingRefs != null) return; // already fighting elsewhere
		if (_payload.pos == null) return;

		local me = null;
		try { me = ::World.State.getPlayer().getPos(); } catch (error) { return; }
		local dx = me.X - _payload.pos.x, dy = me.Y - _payload.pos.y;
		local dist = ::Math.pow(dx * dx + dy * dy, 0.5);
		if (dist > this.JoinRange)
		{
			::BBCoop.log(format("%s started a battle %.0f units away (join range %.0f)", _from, dist, this.JoinRange));
			return;
		}
		this.Invite = { host = _from, battleID = _payload.battleID, time = ::Time.getRealTimeF() };
		::BBCoop.notify(_from + " is in a battle nearby! Press Ctrl+B to join as reinforcements.");
	}

	function acceptInvite()
	{
		if (this.Invite == null || ::Time.getRealTimeF() - this.Invite.time > 300.0)
		{
			::BBCoop.notify("There is no battle nearby to join.");
			return;
		}
		local packed = ::BBCoop.Roster.packCompany(::BBCoop.getSetting("PlayerName"));
		if (packed.bros.len() == 0)
		{
			::BBCoop.notify("None of your brothers can fight.");
			return;
		}
		this.PendingRefs = packed.refs;
		this.PendingHost = this.Invite.host;
		::BBCoop.Connection.sendMessage("battle_join", { battleID = this.Invite.battleID, to = this.Invite.host, bros = packed.bros });
		this.Invite = null;
		try { ::World.State.setPause(true); } catch (error) {}
		::BBCoop.notify(format("Your company marches into %s's battle. Results arrive when it ends.", this.PendingHost));
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

		local text = format("The battle with %s is over. %i of your brothers came back", _from, survived);
		if (died.len() != 0) text += ". Fallen: " + died.reduce(@(a, b) a + ", " + b);
		::BBCoop.notify(text + ".");
	}
};

::BBCoop.MH.hook("scripts/entity/tactical/tactical_entity_manager", function(q) {
	q.spawn = @(__original) function( _properties )
	{
		__original(_properties);
		try
		{
			::BBCoop.Battle.onBattleStarted();
		}
		catch (error)
		{
			::BBCoop.log("onBattleStarted failed: " + error);
		}
	}
});

::BBCoop.MH.hook("scripts/states/tactical_state", function(q) {
	q.onBattleEnded = @(__original) function()
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
