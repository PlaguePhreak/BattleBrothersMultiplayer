// Ghost companies: the other players' companies, shown on your world map.
// A ghost is a plain world party that never fights and is never saved. It follows
// the position updates the other player sends, smoothly interpolated between updates.

::BBCoop.Ghosts <- {
	Entries = {},           // player name -> entry table
	TimeoutSeconds = 20.0,  // remove a ghost when its player goes quiet this long
	MoveSeconds = 1.0,      // interpolation time between two position updates
	WarnedSeed = {},        // player name -> true once we warned about a seed mismatch
	PendingSeed = null,     // map seed of a campaign being created, until world flags exist
	Leftovers = [],         // ghosts that slipped into a save anyway; removed on the next frame

	function isWorldActive()
	{
		try
		{
			return ::MSU.Utils.hasState("world_state") && ("Flags" in ::World) && ::World.Flags != null;
		}
		catch (error)
		{
			return false;
		}
	}

	function getSeed()
	{
		if (!this.isWorldActive()) return "";
		if (this.PendingSeed != null)
		{
			::World.Flags.set("BBCoopSeed", this.PendingSeed);
			this.PendingSeed = null;
		}
		return ::World.Flags.has("BBCoopSeed") ? ::World.Flags.get("BBCoopSeed") : "";
	}

	// Called for every "pos" message from another player
	function onPosition( _from, _payload )
	{
		if (!this.isWorldActive()) return;

		local mySeed = this.getSeed();
		if ("seed" in _payload && _payload.seed != "" && mySeed != "" && _payload.seed != mySeed && !(_from in this.WarnedSeed))
		{
			this.WarnedSeed[_from] <- true;
			::BBCoop.notify(format("%s is on a different map (seed %s, yours is %s). Their company is shown, but the maps won't line up.", _from, _payload.seed, mySeed));
		}

		local target = ::createVec(_payload.x.tofloat(), _payload.y.tofloat());
		local now = ::Time.getRealTimeF();

		if (!(_from in this.Entries) || this.Entries[_from].Party == null || this.Entries[_from].Party.isNull())
		{
			local party = this.spawn(_from, target, _payload);
			if (party == null) return;
			this.Entries[_from] <- {
				Party = ::WeakTableRef(party),
				From = target,
				To = target,
				StartTime = now,
				LastSeen = now
			};
			::BBCoop.notify(_from + "'s company is now on your map.");
			return;
		}

		local e = this.Entries[_from];
		e.From = e.Party.getPos();
		e.To = target;
		e.StartTime = now;
		e.LastSeen = now;
	}

	function spawn( _from, _pos, _payload )
	{
		try
		{
			local coords = ::World.worldToTile(_pos);
			local party = ::World.spawnEntity("scripts/entity/world/party", coords);
			party.setPos(_pos);
			party.setName(_from + "'s company");
			party.setDescription("A fellow mercenary company led by " + _from + ", another player.");
			party.setFaction(::Const.Faction.Player);
			party.setAttackableByAI(false);
			party.setVisibleInFogOfWar(true);
			party.getFlags().set("BBCoopGhost", true);
			this.setBrush(party, "base", "base" in _payload ? _payload.base : null, "world_base_07");
			this.setBrush(party, "body", "body" in _payload ? _payload.body : null, "figure_mercenary_01");
			return party;
		}
		catch (error)
		{
			::BBCoop.log("Could not spawn ghost for " + _from + ": " + error);
			return null;
		}
	}

	function setBrush( _party, _sprite, _brush, _fallback )
	{
		if (!_party.hasSprite(_sprite)) return;
		try
		{
			_party.getSprite(_sprite).setBrush(_brush != null && _brush != "" ? _brush : _fallback);
		}
		catch (error)
		{
			_party.getSprite(_sprite).setBrush(_fallback);
		}
	}

	// Called every frame from world_state.onUpdate
	function update()
	{
		if (this.Leftovers.len() != 0)
		{
			foreach (party in this.Leftovers)
				if (!party.isNull()) party.die();
			this.Leftovers.clear();
		}
		if (this.Entries.len() == 0) return;
		local now = ::Time.getRealTimeF();
		local gone = [];
		foreach (name, e in this.Entries)
		{
			if (e.Party == null || e.Party.isNull())
			{
				gone.push(name);
				continue;
			}
			if (now - e.LastSeen > this.TimeoutSeconds)
			{
				e.Party.die();
				gone.push(name);
				::BBCoop.notify(name + "'s company left your map.");
				continue;
			}
			local t = ::Math.minf(1.0, (now - e.StartTime) / this.MoveSeconds);
			e.Party.setPos(::createVec(e.From.X + (e.To.X - e.From.X) * t, e.From.Y + (e.To.Y - e.From.Y) * t));
		}
		foreach (name in gone)
			delete this.Entries[name];
	}

	// Ghosts must never end up in a save file
	function despawnAll()
	{
		foreach (name, e in this.Entries)
		{
			if (e.Party != null && !e.Party.isNull())
				e.Party.die();
		}
		this.Entries.clear();
	}

	// Our own company's brushes, so the other player's ghost of us looks like our company
	function getOwnBrushes()
	{
		local ret = { base = "", body = "" };
		try
		{
			local player = ::World.State.getPlayer();
			if (player.hasSprite("base")) ret.base = player.getSprite("base").getBrush().Name;
			if (player.hasSprite("body")) ret.body = player.getSprite("body").getBrush().Name;
		}
		catch (error) {}
		return ret;
	}
};

::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.onUpdate = @(__original) function()
	{
		__original();
		::BBCoop.Ghosts.update();
	}

	q.onBeforeSerialize = @(__original) function( _out )
	{
		::BBCoop.Ghosts.despawnAll();
		__original(_out);
	}

	q.onFinish = @(__original) function()
	{
		::BBCoop.Ghosts.Entries.clear(); // the whole world is being torn down
		__original();
	}

	q.setNewCampaignSettings = @(__original) function( _settings )
	{
		::BBCoop.Ghosts.PendingSeed = ("Seed" in _settings) ? _settings.Seed.tostring() : null;
		__original(_settings);
	}

	q.loadCampaign = @(__original) function( _campaignFileName )
	{
		::BBCoop.Ghosts.PendingSeed = null;
		::BBCoop.Ghosts.Entries.clear(); // old world's entities are gone
		__original(_campaignFileName);
	}
});

// Safety net: if a ghost was ever written into a save, remove it after loading
::BBCoop.MH.hook("scripts/entity/world/party", function(q) {
	q.onDeserialize = @(__original) function( _in )
	{
		__original(_in);
		if (this.getFlags().get("BBCoopGhost"))
			::BBCoop.Ghosts.Leftovers.push(::WeakTableRef(this));
	}
});
