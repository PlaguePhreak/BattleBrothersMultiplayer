// Shared world. The host (the player whose world the others joined through the Multiplayer
// button) is the authority: a joiner's world follows the host's while the host is online.
//
// Host: every 2 seconds sends where its roaming parties are ("world_parties"), and every 30
// seconds (or when someone asks with "world_request") the whole world ("world_full"): every
// party with its troops and looks, every camp/lair/ruin with its defenders, which settlement
// buildings are burned, and each town's situations.
// Joiner: shows the host's parties as mirrors that move where the host's parties move, removes
// parties and camps its own world spawned, adds camps the host has, and copies town situations.
// What a joiner destroys is destroyed in the host's world too ("world_party_destroyed",
// "world_location_destroyed"), and survivors of a joiner's battle keep their losses
// ("world_party_troops", "world_location_troops").
// Kept out of the sync on the joiner's side: their own contract's targets, so contracts work.
// When the host is offline the joiner's world runs on its own again, mirrors included.
// Checked against vanilla entity/world (world_entity, party, location, settlement,
// entity_manager), factions/faction and the faction actions that spawn camps and parties.

::BBCoop.World <- {
	PartiesSeconds = 2.0,    // host: how often party positions go out
	FullSeconds = 30.0,      // host: how often the whole world goes out
	ReconcileSeconds = 5.0,  // joiner: how often our world is checked against the host's
	RequestSeconds = 10.0,   // joiner: how often to ask for the world while we have none

	LastPartiesSent = -100.0,
	LastFullSent = -100.0,
	FullRequested = false,
	LastReconcile = -100.0,
	LastRequest = -100.0,
	PlayerSeeds = {},        // player -> map seed from their position updates
	Following = false,       // joiner: host online and a snapshot arrived (updated every frame)

	Snapshot = null,         // joiner: last "world_full" from the host
	Mirrors = {},            // joiner: host party id (string) -> { Party, From, To, StartTime }
	Fought = [],             // world entities in the battle being fought (WeakTableRefs)
	WasInBattle = false,
	Announced = false,

	function reset()
	{
		this.Snapshot = null;
		this.Mirrors.clear();
		this.Fought.clear();
		this.Following = false;
		this.Announced = false;
		this.LastRequest = -100.0;
	}

	// ---- roles ----

	function getHost()
	{
		if (!::BBCoop.Ghosts.isWorldActive()) return null;
		return ::World.Flags.has("BBCoopHost") ? ::World.Flags.get("BBCoopHost") : null;
	}

	function isHostOnline()
	{
		local host = this.getHost();
		return host != null && ::BBCoop.isOnline(host, 30.0);
	}

	// We host when nobody else's world is ours to follow and someone on our map is online
	function hasFollowers()
	{
		if (this.getHost() != null) return false;
		local seed = ::BBCoop.Ghosts.getSeed();
		if (seed == "") return false;
		foreach (name, s in this.PlayerSeeds)
			if (s == seed && ::BBCoop.isOnline(name, 20.0)) return true;
		return false;
	}

	function canTouchWorld()
	{
		if (!::BBCoop.Ghosts.isWorldActive()) return false;
		if (::BBCoop.Battle.isInTactical() || ::BBCoop.Battle.PendingRefs != null) return false;
		try { if (::Tactical.isVisible()) return false; } catch (error) {}
		// paused: a combat dialog, town or menu may be holding on to a party
		try { if (::World.State.isPaused()) return false; } catch (error) {}
		return true;
	}

	// ---- helpers ----

	function brushOf( _e, _sprite )
	{
		try
		{
			if (!_e.hasSprite(_sprite)) return "";
			local s = _e.getSprite(_sprite);
			return s.HasBrush ? s.getBrush().Name : "";
		}
		catch (error)
		{
			return "";
		}
	}

	function setBrush( _e, _sprite, _brush )
	{
		if (_brush == null || _brush == "" || !_e.hasSprite(_sprite)) return;
		try { _e.getSprite(_sprite).setBrush(_brush); } catch (error) {}
	}

	function findFaction( _index, _type )
	{
		local f = null;
		try { f = ::World.FactionManager.getFaction(_index); } catch (error) {}
		if (f != null && f.getType() == _type) return f;
		local list = ::World.FactionManager.getFactionsOfType(_type);
		return list.len() != 0 ? list[0] : null;
	}

	function packTroops( _e )
	{
		local ret = [];
		foreach (t in _e.getTroops())
		{
			local hash = 0;
			try { if (t.Script != null && t.Script != "") hash = ::IO.scriptHashByFilename(t.Script); } catch (error) {}
			local name = ("Name" in t && t.Name != null) ? t.Name : "";
			ret.push([t.ID, t.Variant, t.Strength, t.Row, name, hash]);
		}
		return ret;
	}

	function troopSignature( _list )
	{
		local s = "";
		foreach (t in _list) s += "" + t[0] + ":" + t[1] + ":" + t[3] + ":" + t[4] + "|";
		return s;
	}

	function unpackTroops( _e, _list )
	{
		local troops = [];
		foreach (t in _list)
		{
			local troop = clone ::Const.World.Spawn.Unit;
			troop.ID = t[0];
			troop.Variant = t[1];
			troop.Strength = t[2].tofloat();
			troop.Row = t[3];
			troop.Name = t[4];
			if (t[5] != 0) troop.Script = ::IO.scriptFilenameByHash(t[5]);
			troop.Party = ::WeakTableRef(_e);
			troop.Faction = _e.getFaction();
			troops.push(troop);
		}
		_e.m.Troops = troops;
		_e.updateStrength();
	}

	function allParties()
	{
		local ret = [];
		foreach (f in ::World.FactionManager.getFactions())
		{
			if (f == null || f.getID() == ::Const.Faction.Player) continue;
			foreach (u in f.getUnits())
				if (u != null && u.isAlive() && !u.isPlayerControlled()) ret.push(u);
		}
		return ret;
	}

	// IDs of world entities our active contract points at; the sync leaves them alone
	function getContractRefs()
	{
		local ids = {};
		local contract = null;
		try { contract = ::World.Contracts.getActiveContract(); } catch (error) {}
		if (contract == null) return ids;
		foreach (key, v in contract.m)
		{
			if (v == null) continue;
			local t = typeof v;
			if (t == "array")
			{
				foreach (x in v)
				{
					if (typeof x == "integer") ids[x] <- true;
					else if (x != null) try { ids[x.getID()] <- true; } catch (error) {}
				}
			}
			else if (t == "instance" || t == "table")
			{
				try { ids[v.getID()] <- true; } catch (error) {}
			}
		}
		return ids;
	}

	function isKept( _e, _refs )
	{
		if (_e.getID() in _refs) return true;
		try { if (_e.getSprite("selection").Visible) return true; } catch (error) {} // contract target marker
		return false;
	}

	// ================= host =================

	function packParty( _p )
	{
		local pos = _p.getPos();
		local loot = _p.getLoot();
		local speed = 100.0;
		try { speed = _p.getBaseMovementSpeed(); } catch (error) {}
		return {
			id = _p.getID().tostring(),
			x = pos.X.tointeger(),
			y = pos.Y.tointeger(),
			f = _p.getFaction(),
			ft = ::World.FactionManager.getFaction(_p.getFaction()).getType(),
			n = _p.getName(),
			d = _p.getDescription(),
			b = this.brushOf(_p, "base"),
			bd = this.brushOf(_p, "body"),
			bn = this.brushOf(_p, "banner"),
			mr = _p.m.IsMirrored,
			sp = speed,
			t = this.packTroops(_p),
			l = [loot.Money, loot.Ammo, loot.Medicine, loot.ArmorParts],
			inv = clone _p.getInventory()
		};
	}

	function packLocation( _l )
	{
		local tile = _l.getTile();
		if (_l.isLocationType(::Const.World.LocationType.AttachedLocation))
			return { k = tile.ID, at = true, a = _l.isActive() };
		local loot = [];
		try
		{
			foreach (item in _l.getLoot().getItems())
				if (item != null) loot.push(::BBCoop.Loot.packItem(item));
		}
		catch (error) {}
		local pos = _l.getPos();
		local hash = 0;
		try { hash = _l.ClassNameHash; } catch (error) {}
		return {
			k = tile.ID,
			at = false,
			x = pos.X.tointeger(),
			y = pos.Y.tointeger(),
			h = hash,
			ty = _l.getTypeID(),
			f = _l.getFaction(),
			ft = _l.getFaction() != 0 && ::World.FactionManager.getFaction(_l.getFaction()) != null ? ::World.FactionManager.getFaction(_l.getFaction()).getType() : -1,
			n = _l.getName(),
			bn = _l.getBanner(),
			r = _l.getResources(),
			t = this.packTroops(_l),
			loot = loot
		};
	}

	function packSettlement( _s )
	{
		local situations = [];
		foreach (sit in _s.getSituations())
		{
			if (sit.getValidUntil() == 0) continue; // tied to a contract of the host's
			try { situations.push([sit.getID(), sit.ClassNameHash]); } catch (error) {}
		}
		return { k = _s.getTile().ID, a = _s.isActive(), s = situations };
	}

	function sendFull()
	{
		local parties = [], locations = [], settlements = [];
		foreach (p in this.allParties())
		{
			try { parties.push(this.packParty(p)); } catch (error) { ::BBCoop.log("Could not pack party " + p.getName() + ": " + error); }
		}
		foreach (l in ::World.EntityManager.getLocations())
		{
			if (l == null || !l.isAlive()) continue;
			try { locations.push(this.packLocation(l)); } catch (error) { ::BBCoop.log("Could not pack location " + l.getName() + ": " + error); }
		}
		foreach (s in ::World.EntityManager.getSettlements())
		{
			try { settlements.push(this.packSettlement(s)); } catch (error) {}
		}
		::BBCoop.Connection.sendMessage("world_full", {
			seed = ::BBCoop.Ghosts.getSeed(),
			day = ::World.getTime().Days,
			parties = parties,
			locations = locations,
			settlements = settlements
		});
	}

	function sendParties()
	{
		local flat = [];
		foreach (p in this.allParties())
		{
			local pos = p.getPos();
			flat.push(p.getID().tostring());
			flat.push(pos.X.tointeger());
			flat.push(pos.Y.tointeger());
		}
		::BBCoop.Connection.sendMessage("world_parties", { seed = ::BBCoop.Ghosts.getSeed(), p = flat });
	}

	function updateHost( _now )
	{
		if (!this.hasFollowers()) return;
		if (this.FullRequested || _now - this.LastFullSent >= this.FullSeconds)
		{
			this.FullRequested = false;
			this.LastFullSent = _now;
			this.LastPartiesSent = _now;
			this.sendFull();
		}
		else if (_now - this.LastPartiesSent >= this.PartiesSeconds)
		{
			this.LastPartiesSent = _now;
			this.sendParties();
		}
	}

	function findLocation( _key, _typeID )
	{
		foreach (l in ::World.EntityManager.getLocations())
			if (l != null && l.isAlive() && l.getTile().ID == _key && l.getTypeID() == _typeID) return l;
		return null;
	}

	function partyByID( _id )
	{
		local e = null;
		try { e = ::World.getEntityByID(_id.tointeger()); } catch (error) {}
		if (e == null || !e.isAlive() || !e.isParty()) return null;
		return e;
	}

	// A joiner destroyed one of our parties
	function onPartyDestroyed( _from, _payload )
	{
		if (this.getHost() != null) return;
		local p = this.partyByID(_payload.id);
		if (p == null || p.isInCombat()) return;
		::BBCoop.notify(_from + " destroyed " + p.getName() + ".");
		if (p.hasLabel("name")) p.getLabel("name").Visible = false;
		p.fadeOutAndDie();
	}

	// A joiner fought one of our parties and it survived with losses
	function onPartyTroops( _from, _payload )
	{
		if (this.getHost() != null) return;
		local p = this.partyByID(_payload.id);
		if (p == null || p.isInCombat()) return;
		if (_payload.t.len() == 0) { p.fadeOutAndDie(); return; }
		this.unpackTroops(p, _payload.t);
	}

	// A joiner destroyed one of our camps: same as vanilla location.onCombatLost, without
	// the player-only parts (achievements, contracts)
	function onLocationDestroyed( _from, _payload )
	{
		if (this.getHost() != null) return;
		local l = this.findLocation(_payload.k.tointeger(), _payload.ty);
		if (l == null || l.isInCombat()) return;
		::BBCoop.notify(_from + " destroyed " + l.getName() + ".");
		local tile = l.getTile();
		local battlesite = false;
		try { battlesite = l.m.IsBattlesite; } catch (error) {}
		if (l.hasLabel("name")) l.getLabel("name").Visible = false;
		l.fadeOutAndDie();
		if (!battlesite)
		{
			try { ::World.spawnLocation("scripts/entity/world/locations/battlefield_location", tile.Coords).setSize(1); } catch (error) {}
		}
	}

	function onLocationTroops( _from, _payload )
	{
		if (this.getHost() != null) return;
		local l = this.findLocation(_payload.k.tointeger(), _payload.ty);
		if (l == null || l.isInCombat()) return;
		this.unpackTroops(l, _payload.t);
	}

	// ================= joiner =================

	function isFromHost( _from )
	{
		return _from == this.getHost();
	}

	function onFull( _from, _payload )
	{
		if (!this.isFromHost(_from) || !::BBCoop.Ghosts.isWorldActive()) return;
		if (_payload.seed != ::BBCoop.Ghosts.getSeed()) return;
		this.Snapshot = _payload;
		this.Following = true;
		if (!this.Announced)
		{
			this.Announced = true;
			local text = format("Your world now follows %s's: %i parties, %i camps and lairs.", _from, _payload.parties.len(), _payload.locations.filter(@(i, l) !l.at).len());
			local myDay = ::World.getTime().Days;
			if (_payload.day != myDay) text += format(" Their world is on day %i, yours on day %i (days can't be synced).", _payload.day, myDay);
			::BBCoop.notify(text);
		}
		if (!this.canTouchWorld()) return;
		this.reconcile();
		this.LastReconcile = ::Time.getRealTimeF();
	}

	function onParties( _from, _payload )
	{
		if (!this.isFromHost(_from) || this.Snapshot == null) return;
		local now = ::Time.getRealTimeF();
		local seen = {};
		local flat = _payload.p;
		for (local i = 0; i + 2 < flat.len(); i += 3)
		{
			local id = flat[i];
			seen[id] <- true;
			if (!(id in this.Mirrors)) continue; // new on the host: arrives with the next full update
			local m = this.Mirrors[id];
			if (m.Party == null || m.Party.isNull()) continue;
			m.From = m.Party.getPos();
			m.To = ::createVec(flat[i + 1].tofloat(), flat[i + 2].tofloat());
			m.StartTime = now;
		}
		// gone on the host: gone here
		if (!this.canTouchWorld()) return;
		local gone = [];
		foreach (id, m in this.Mirrors)
			if (!(id in seen)) gone.push(id);
		foreach (id in gone)
			this.removeMirror(id);
	}

	function removeMirror( _id )
	{
		local m = this.Mirrors[_id];
		delete this.Mirrors[_id];
		if (m.Party != null && !m.Party.isNull() && m.Party.isAlive() && !m.Party.isInCombat())
			m.Party.die();
	}

	function spawnMirror( _p )
	{
		local f = this.findFaction(_p.f, _p.ft);
		if (f == null) return null;
		local pos = ::createVec(_p.x.tofloat(), _p.y.tofloat());
		local party = ::World.spawnEntity("scripts/entity/world/party", ::World.worldToTile(pos));
		party.setPos(pos);
		f.addUnit(party);
		party.getFlags().set("BBCoopMirror", _p.id);
		this.applyParty(party, _p, true);
		return party;
	}

	function applyParty( _party, _p, _new )
	{
		if (_new || _party.getName() != _p.n)
		{
			_party.setName(_p.n);
			_party.setDescription(_p.d);
			this.setBrush(_party, "base", _p.b);
			this.setBrush(_party, "body", _p.bd);
			this.setBrush(_party, "banner", _p.bn);
			_party.setMirrored(_p.mr);
			_party.setMovementSpeed(_p.sp.tofloat());
			_party.setAttackableByAI(false); // the host's AI decides who it fights
			_party.clearInventory();
			foreach (item in _p.inv) _party.addToInventory(item);
			local loot = _party.getLoot();
			loot.Money = _p.l[0];
			loot.Ammo = _p.l[1];
			loot.Medicine = _p.l[2];
			loot.ArmorParts = _p.l[3];
		}
		if (_new || this.troopSignature(this.packTroops(_party)) != this.troopSignature(_p.t))
			this.unpackTroops(_party, _p.t);
	}

	function syncMirrors()
	{
		local now = ::Time.getRealTimeF();
		local want = {};
		foreach (p in this.Snapshot.parties) want[p.id] <- p;

		// mirrors from before a reload carry the host's id in a flag
		foreach (u in this.allParties())
		{
			if (!u.getFlags().has("BBCoopMirror")) continue;
			local id = u.getFlags().get("BBCoopMirror");
			if (id in this.Mirrors && !this.Mirrors[id].Party.isNull() && this.Mirrors[id].Party.getID() == u.getID()) continue;
			if ((id in want) && !(id in this.Mirrors))
				this.Mirrors[id] <- { Party = ::WeakTableRef(u), From = u.getPos(), To = u.getPos(), StartTime = now };
			else if (!u.isInCombat())
				u.die();
		}

		local gone = [];
		foreach (id, m in this.Mirrors)
			if (!(id in want) || m.Party == null || m.Party.isNull()) gone.push(id);
		foreach (id in gone)
			this.removeMirror(id);

		foreach (id, p in want)
		{
			try
			{
				if (id in this.Mirrors)
				{
					local m = this.Mirrors[id];
					if (m.Party.isInCombat()) continue;
					this.applyParty(m.Party, p, false);
					m.From = m.Party.getPos();
					m.To = ::createVec(p.x.tofloat(), p.y.tofloat());
					m.StartTime = now;
				}
				else
				{
					local party = this.spawnMirror(p);
					if (party != null) this.Mirrors[id] <- { Party = ::WeakTableRef(party), From = party.getPos(), To = party.getPos(), StartTime = now };
				}
			}
			catch (error)
			{
				::BBCoop.log("Could not mirror " + p.n + ": " + error);
			}
		}
	}

	function spawnLocation( _l )
	{
		local script = null;
		if (_l.h != 0) script = ::IO.scriptFilenameByHash(_l.h);
		// vanilla names location scripts after their type: location.bandit_camp -> bandit_camp_location
		if ((script == null || script == "") && _l.ty.find("location.") == 0)
			script = "scripts/entity/world/locations/" + _l.ty.slice(9) + "_location";
		if (script == null || script == "") return;
		local pos = ::createVec(_l.x.tofloat(), _l.y.tofloat());
		local coords = ::World.worldToTile(pos);
		if (::World.getTile(coords).IsOccupied) return;
		local loc = ::World.spawnLocation(script, coords);
		try { loc.onSpawned(); } catch (error) {}
		local f = _l.ft >= 0 ? this.findFaction(_l.f, _l.ft) : null;
		if (f != null) f.addSettlement(loc, false);
		loc.setName(_l.n);
		if (loc.hasLabel("name")) loc.getLabel("name").Text = _l.n;
		try { loc.setBanner(_l.bn); } catch (error) {}
		loc.setResources(_l.r);
		this.unpackTroops(loc, _l.t);
		try
		{
			local stash = loc.getLoot();
			stash.clear();
			foreach (entry in _l.loot) stash.add(::BBCoop.Loot.unpackItem(entry));
		}
		catch (error)
		{
			::BBCoop.log("Could not copy the loot of " + _l.n + ": " + error);
		}
	}

	function syncLocations( _refs )
	{
		local want = {};
		foreach (l in this.Snapshot.locations) want[l.k.tointeger()] <- l;
		local have = {};
		local removed = 0, added = 0;

		foreach (loc in clone ::World.EntityManager.getLocations())
		{
			if (loc == null || !loc.isAlive() || loc.isInCombat()) continue;
			local k = loc.getTile().ID;
			if (loc.isLocationType(::Const.World.LocationType.AttachedLocation))
			{
				// burned or rebuilt farms, mines and the like
				if ((k in want) && want[k].at && want[k].a != loc.isActive())
					try { loc.setActive(want[k].a); } catch (error) {}
				continue;
			}
			if ((k in want) && !want[k].at && want[k].ty == loc.getTypeID())
			{
				have[k] <- true;
				local l = want[k];
				if (this.troopSignature(this.packTroops(loc)) != this.troopSignature(l.t)) this.unpackTroops(loc, l.t);
				if (loc.getName() != l.n)
				{
					loc.setName(l.n);
					if (loc.hasLabel("name")) loc.getLabel("name").Text = l.n;
				}
				continue;
			}
			if (this.isKept(loc, _refs)) continue;
			if (loc.hasLabel("name")) loc.getLabel("name").Visible = false;
			loc.die();
			removed++;
		}

		foreach (k, l in want)
		{
			if (l.at || (k in have)) continue;
			try
			{
				this.spawnLocation(l);
				added++;
			}
			catch (error)
			{
				::BBCoop.log("Could not add " + l.n + ": " + error);
			}
		}
		if (removed != 0 || added != 0) ::BBCoop.log(format("World sync: removed %i camps, added %i", removed, added));
	}

	function syncSettlements()
	{
		local want = {};
		foreach (s in this.Snapshot.settlements) want[s.k.tointeger()] <- s;
		foreach (s in ::World.EntityManager.getSettlements())
		{
			local k = s.getTile().ID;
			if (!(k in want)) continue;
			local w = want[k];
			try
			{
				if (w.a != s.isActive()) s.setActive(w.a, false);
				local hostSituations = {};
				foreach (pair in w.s) hostSituations[pair[0]] <- pair[1];
				foreach (sit in clone s.getSituations())
				{
					if (sit.getValidUntil() == 0) continue; // tied to one of our contracts
					if (!(sit.getID() in hostSituations)) s.removeSituationByInstance(sit.getInstanceID());
				}
				foreach (id, hash in hostSituations)
				{
					if (s.hasSituation(id)) continue;
					local script = ::IO.scriptFilenameByHash(hash);
					if (script != null && script != "") s.addSituation(::new(script));
				}
			}
			catch (error)
			{
				::BBCoop.log("Could not sync " + s.getName() + ": " + error);
			}
		}
	}

	// Parties our own world spawned: the host's world decides what roams
	function removeLocalParties( _refs )
	{
		foreach (u in this.allParties())
		{
			local flags = u.getFlags();
			if (flags.has("BBCoopMirror") || flags.has("BBCoopGhost") || u.isInCombat() || this.isKept(u, _refs)) continue;
			u.die();
		}
	}

	function reconcile()
	{
		if (this.Snapshot == null) return;
		local refs = this.getContractRefs();
		this.removeLocalParties(refs);
		this.syncMirrors();
		this.syncLocations(refs);
		this.syncSettlements();
	}

	function moveMirrors( _now )
	{
		foreach (id, m in this.Mirrors)
		{
			if (m.Party == null || m.Party.isNull() || m.Party.isInCombat()) continue;
			local t = ::Math.minf(1.0, (_now - m.StartTime) / this.PartiesSeconds);
			local x = m.From.X + (m.To.X - m.From.X) * t;
			local y = m.From.Y + (m.To.Y - m.From.Y) * t;
			if (m.To.X != m.From.X)
			{
				try { m.Party.getSprite("body").setHorizontalFlipping(m.Party.m.IsMirrored && m.To.X < m.From.X); } catch (error) {}
			}
			m.Party.setPos(::createVec(x, y));
		}
	}

	function updateJoiner( _now )
	{
		local hostOnline = this.isHostOnline();
		this.Following = hostOnline && this.Snapshot != null;
		if (!hostOnline) return;
		if (this.Snapshot == null)
		{
			if (_now - this.LastRequest >= this.RequestSeconds)
			{
				this.LastRequest = _now;
				::BBCoop.Connection.sendMessage("world_request", { to = this.getHost() });
			}
			return;
		}
		if (!this.canTouchWorld()) return;
		this.moveMirrors(_now);
		if (_now - this.LastReconcile >= this.ReconcileSeconds)
		{
			this.LastReconcile = _now;
			try { this.reconcile(); } catch (error) { ::BBCoop.log("World sync failed: " + error); }
		}
	}

	// ---- battles on the joiner's side ----

	function onEntityCombatStarted( _e )
	{
		if (!this.Following) return;
		this.Fought.push(::WeakTableRef(_e));
	}

	function onEntityLost( _e )
	{
		if (!this.Following) return;
		local host = this.getHost();
		if (_e.isParty() && _e.getFlags().has("BBCoopMirror"))
		{
			local id = _e.getFlags().get("BBCoopMirror");
			::BBCoop.Connection.sendMessage("world_party_destroyed", { to = host, id = id });
			if (id in this.Mirrors) delete this.Mirrors[id];
		}
		else if (_e.isLocation() && !_e.isLocationType(::Const.World.LocationType.AttachedLocation))
		{
			::BBCoop.Connection.sendMessage("world_location_destroyed", { to = host, k = _e.getTile().ID, ty = _e.getTypeID() });
		}
	}

	// After our battle: survivors keep their losses in the host's world too
	function afterBattle()
	{
		local host = this.getHost();
		foreach (ref in this.Fought)
		{
			if (ref == null || ref.isNull() || !ref.isAlive() || host == null) continue;
			try
			{
				if (ref.isParty() && ref.getFlags().has("BBCoopMirror"))
					::BBCoop.Connection.sendMessage("world_party_troops", { to = host, id = ref.getFlags().get("BBCoopMirror"), t = this.packTroops(ref) });
				else if (ref.isLocation())
					::BBCoop.Connection.sendMessage("world_location_troops", { to = host, k = ref.getTile().ID, ty = ref.getTypeID(), t = this.packTroops(ref) });
			}
			catch (error) {}
		}
		this.Fought.clear();
	}

	// ---- every frame from world_state.onUpdate ----

	function update()
	{
		if (!::BBCoop.Ghosts.isWorldActive()) return;
		local now = ::Time.getRealTimeF();
		local inBattle = false;
		try { inBattle = ::Tactical.isVisible(); } catch (error) {}
		if (this.WasInBattle && !inBattle && this.Fought.len() != 0) this.afterBattle();
		this.WasInBattle = inBattle;
		if (this.getHost() != null) this.updateJoiner(now);
		else this.updateHost(now);
	}

	function onPosition( _from, _payload )
	{
		if ("seed" in _payload) this.PlayerSeeds[_from] <- _payload.seed;
	}

	function onRequest( _from, _payload )
	{
		if (this.getHost() == null) this.FullRequested = true;
	}
};

// Mirrors move where the host says, not where their own AI wants
::BBCoop.MH.hook("scripts/entity/world/party", function(q) {
	q.onUpdate = @(__original) function()
	{
		if (::BBCoop.World.Following && this.m.Flags != null && this.m.Flags.has("BBCoopMirror") && !this.isInCombat())
		{
			this.world_entity.onUpdate();
			return;
		}
		return __original();
	}
});

::BBCoop.MH.hook("scripts/entity/world/world_entity", function(q) {
	q.onCombatStarted = @(__original) function()
	{
		try { ::BBCoop.World.onEntityCombatStarted(this); } catch (error) {}
		return __original();
	}

	q.onCombatLost = @(__original) function()
	{
		try { ::BBCoop.World.onEntityLost(this); } catch (error) { ::BBCoop.log("Sharing a destroyed party failed: " + error); }
		return __original();
	}
});

::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.onUpdate = @(__original) function()
	{
		__original();
		try { ::BBCoop.World.update(); } catch (error) { ::BBCoop.log("World sync update failed: " + error); }
	}

	q.onFinish = @(__original) function()
	{
		::BBCoop.World.reset();
		__original();
	}

	q.loadCampaign = @(__original) function( _campaignFileName )
	{
		::BBCoop.World.reset();
		__original(_campaignFileName);
	}
});
