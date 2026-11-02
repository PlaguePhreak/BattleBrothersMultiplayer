// Shared battles, part 3 (v0.18.0): the real battlefield for players who join someone else's battle.
// The host's game still runs the battle. Our game builds a copy ("mirror") of it in a real tactical
// scene: the same map (generated from the same seed and terrain), the same units (brothers are sent
// whole, other fighters as script + gear + looks), and every view the host sends moves them, sets
// their hitpoints and armor and removes the dead. Nothing in the copy acts on its own: no AI, no turn
// logic, no combat end. When it's one of our brothers' turn, the copy's turn bar is moved to him so
// the normal skill bar works; clicks on the map become orders for the host instead of actions here.
// If any of that can't be set up, the old battle panel takes over.
// Checked against the decompiled vanilla tactical_state (init, initMap, updateCurrentEntity,
// executeEntityTravel, executeEntitySkill, exitTactical), world_state (startScriptedCombat,
// loading_screen_onScreenShown, onCombatFinished), tactical_entity_manager (spawn, checkCombatFinished),
// actor, item_container and armor/helmet.

::BBCoop.Mirror <- {
	// ---- host side ----
	MapSetup = null,        // how our map was made, sent to joiners: seed, terrain, location, tile
	LogLines = [],          // combat log lines of this battle ({ ex, text })
	LogIndex = {},          // owner -> how many log lines they have
	DeadIDs = [],           // entity ids killed in this battle (anything else that vanished retreated)
	LogMax = 400,
	Acts = [],              // host: skill uses this battle ({ id, skill, x, y }), for joiners' animations
	ActIndex = {},          // owner -> how many acts they have
	ActQueue = [],          // copy: acts still to play
	NextActTime = 0.0,

	// ---- joiner side ----
	Scene = null,           // battle_scene from the host, waiting for the tactical map
	Active = false,         // we are in a mirrored battle
	Host = null,
	BattleID = null,
	View = null,            // newest battle_view
	NewView = false,
	SpawnData = {},         // host entity id -> spawn blob (sent once per unit)
	Units = {},             // host entity id -> WeakTableRef to our copy
	Created = [],           // WeakTableRefs to brothers we put in the temporary roster
	Moves = [],             // { id, x, y, tries }
	NextMoveTime = 0.0,
	Advancing = false,      // we are moving the turn bar ourselves
	Skipping = false,       // host: the initNextTurn hook is skipping dead units (no re-entry)
	LastUnits = {},         // joiner: host id -> unit of the last view (AP/fatigue to keep)
	Killing = false,        // we are removing a unit ourselves
	Logging = false,        // we are writing a line from the host's log
	CycleFor = null,        // host entity id we are moving the turn bar to
	CycleTries = 0,
	LastCycle = 0.0,
	Busy = false,           // an order is on its way, wait for the next view
	BusySince = 0.0,
	LastActiveID = null,    // turn bar's active entity when we last moved it
	StripKey = null,        // what the action strip shows now (sent to the UI only on change)
	ViewSeq = 0,
	Leaving = false,
	Result = null,          // battle_result kept until we are back on the world map
	StartTime = 0.0,
	Needed = {},            // ids we already asked the host to send again
	MapMismatchNoted = false,

	AISprites = [
		"body", "head", "injury", "injury_body", "tattoo_body", "scar_body", "tattoo_head", "scar_head",
		"hair", "beard", "beard_top", "legs_back", "legs_front", "miniboss",
		"permanent_injury_1", "permanent_injury_2", "permanent_injury_3", "permanent_injury_4"
	],

	function isEnabled()
	{
		try { return ::BBCoop.getSetting("RealBattleView"); } catch (error) {}
		return true;
	}

	// ======================= host =======================

	function plainCopy( _table )
	{
		if (_table == null) return null;
		local ret = {};
		foreach (k, v in _table)
		{
			local t = typeof v;
			if (t == "integer" || t == "float" || t == "bool" || t == "string" || t == "null")
				ret[k] <- v;
			else if (t == "array")
			{
				local ok = true;
				foreach (x in v)
				{
					local tx = typeof x;
					if (tx != "integer" && tx != "float" && tx != "bool" && tx != "string" && tx != "null") { ok = false; break; }
				}
				if (ok) ret[k] <- clone v;
			}
		}
		return ret;
	}

	// Called right before vanilla generates the host's map: fix the random seed so joiners can
	// generate the very same map
	function seedHostMap( _state )
	{
		this.MapSetup = null;
		this.LogLines.clear();
		this.LogIndex.clear();
		this.Acts.clear();
		this.ActIndex.clear();
		this.DeadIDs.clear();
		this.LastFingerprint = 0;
		if (_state.isScenarioMode()) return;
		local p = _state.m.StrategicProperties;
		if (p == null || p.Tile == null) return;

		local seed = 0;
		if (p.LocationTemplate != null && p.MapSeed != 0) seed = p.MapSeed; // vanilla seeds with this itself
		else
		{
			seed = ::Math.rand(1, 999999999);
			::Math.seedRandom(seed);
		}
		local pos = null;
		try
		{
			local v = ::World.State.getPlayer().getPos();
			pos = { x = v.X, y = v.Y };
		}
		catch (error) {}
		this.MapSetup = {
			seed = seed,
			terrain = p.TerrainTemplate,
			location = this.plainCopy(p.LocationTemplate),
			tile = { x = p.Tile.Coords.X, y = p.Tile.Coords.Y },
			pos = pos,
			fog = p.IsFogOfWarVisible,
			hash = 0
		};
	}

	function afterHostMap()
	{
		if (this.MapSetup != null) this.MapSetup.hash = this.mapHash();
	}

	// Short fingerprint of the generated map, to check both games made the same one
	function mapHash()
	{
		local size = ::Tactical.getMapSize();
		local h = size.X * 131 + size.Y;
		for (local y = 0; y < size.Y; y++)
		{
			for (local x = 0; x < size.X; x++)
			{
				local c = 1;
				if (::Tactical.isValidTileSquare(x, y))
				{
					local t = ::Tactical.getTileSquare(x, y);
					c = ::BBCoop.Remote.terrainChar(t)[0] + ::Math.max(0, ::Math.min(9, t.Level)) * 7;
				}
				h = (h * 31 + c) % 1000003;
			}
		}
		return h;
	}

	function sendScene( _owner )
	{
		if (this.MapSetup == null)
		{
			::BBCoop.log("No map setup to send to " + _owner + ", they get the battle panel");
			return false;
		}
		::BBCoop.Connection.sendMessage("battle_scene", { to = _owner, battleID = ::BBCoop.Battle.HostBattleID, setup = this.MapSetup });
		return true;
	}

	function onLogLine( _text, _ex )
	{
		if (::BBCoop.Battle.HostBattleID == null || ::BBCoop.Battle.MirrorOwners.len() == 0) return;
		if (typeof _text != "string") return;
		this.LogLines.push({ ex = _ex, text = _text });
		if (this.LogLines.len() > this.LogMax)
		{
			// keep indices meaningful: drop the oldest and shift everyone's position
			this.LogLines.remove(0);
			foreach (owner, i in this.LogIndex) this.LogIndex[owner] = ::Math.max(0, i - 1);
		}
	}

	// Host: a unit used a skill (attack, shot, buff...). Joiners' copies replay it as an animation.
	function onSkillUsed( _skill, _tile )
	{
		if (::BBCoop.Battle.HostBattleID == null || ::BBCoop.Battle.MirrorOwners.len() == 0 || _tile == null) return;
		local user = _skill.getContainer().getActor();
		if (user == null || !user.isPlacedOnMap()) return;
		this.Acts.push({ id = user.getID(), skill = _skill.getID(), x = _tile.SquareCoords.X, y = _tile.SquareCoords.Y });
		if (this.Acts.len() > this.LogMax)
		{
			this.Acts.remove(0);
			foreach (owner, i in this.ActIndex) this.ActIndex[owner] = ::Math.max(0, i - 1);
		}
	}

	function takeActsFor( _owner )
	{
		local from = _owner in this.ActIndex ? this.ActIndex[_owner] : 0;
		local ret = [];
		for (local i = from; i < this.Acts.len(); i++) ret.push(this.Acts[i]);
		this.ActIndex[_owner] <- this.Acts.len();
		return ret;
	}

	// Copy: play one act: the skill's sound, a shot flying for ranged skills, the user lunging and
	// whoever stands on the target tile flinching. Nothing is changed: hitpoints come with the view.
	function playAct( _act )
	{
		local user = this.getUnit(_act.id);
		if (user == null || !user.isAlive() || !user.isPlacedOnMap()) return;
		if (!::Tactical.isValidTileSquare(_act.x, _act.y)) return;
		local tile = ::Tactical.getTileSquare(_act.x, _act.y);
		local skill = null;
		try { skill = user.getSkills().getSkillByID(_act.skill); } catch (error) {}
		if (skill != null)
		{
			try
			{
				if (skill.m.SoundOnUse.len() != 0)
					::Sound.play(skill.m.SoundOnUse[::Math.rand(0, skill.m.SoundOnUse.len() - 1)], ::Const.Sound.Volume.Skill, user.getPos());
			}
			catch (error) {}
			try
			{
				local type = skill.getProjectileType();
				if (type != ::Const.ProjectileType.None && !tile.isSameTileAs(user.getTile()))
				{
					local flip = tile.SquareCoords.X < user.getTile().SquareCoords.X;
					::Tactical.spawnProjectileEffect(::Const.ProjectileSprite[type], user.getTile(), tile, 1.0, 1.0, true, flip);
				}
			}
			catch (error) {}
		}
		if (tile.isSameTileAs(user.getTile())) return;
		try { ::Tactical.getShaker().shake(user, tile, 2); } catch (error) {}
		if (!tile.IsEmpty && tile.IsOccupiedByActor)
		{
			try { ::Tactical.getShaker().shake(tile.getEntity(), user.getTile(), 3); } catch (error) {}
		}
	}

	function updateActs( _now )
	{
		if (this.ActQueue.len() == 0 || _now < this.NextActTime) return;
		local act = this.ActQueue[0];
		local user = this.getUnit(act.id);
		// let a unit finish walking there first (but don't wait forever)
		if (user != null && ::Tactical.getNavigator().isTravelling(user) && _now - act.queued < 3.0) return;
		this.ActQueue.remove(0);
		try { this.playAct(act); } catch (error) {}
		this.NextActTime = _now + 0.6;
	}

	function takeLogFor( _owner )
	{
		local from = _owner in this.LogIndex ? this.LogIndex[_owner] : 0;
		local ret = [];
		for (local i = from; i < this.LogLines.len(); i++) ret.push(this.LogLines[i]);
		this.LogIndex[_owner] <- this.LogLines.len();
		return ret;
	}

	function serializeWith( _fn )
	{
		local sd = ::MSU.Class.SerializationData();
		_fn(sd.getSerializationEmulator());
		local raw = [];
		foreach (d in sd.getDataArray()) raw.push([d.getType(), d.getData()]);
		return raw;
	}

	function scriptOf( _e )
	{
		try
		{
			local troop = _e.getWorldTroop();
			if (troop != null && ("Script" in troop) && troop.Script != "") return troop.Script;
		}
		catch (error) {}
		try { return ::IO.scriptFilenameByHash(_e.ClassNameHash); } catch (error) {}
		return null;
	}

	// Everything the joiner needs to make a copy of this unit (sent once per unit)
	function describeSpawn( _e, _side )
	{
		local faction = ::Const.Faction.Player;
		if (_side == "enemy")
		{
			faction = _e.getFaction();
			if (faction == ::Const.Faction.Player || faction == ::Const.Faction.PlayerAnimals) faction = ::Const.Faction.Bandits;
		}
		local d = { name = _e.getName(), faction = faction, player = false };
		if (::isKindOf(_e, "player"))
		{
			d.player = true;
			d.raw <- ::BBCoop.Roster.serializeBrother(_e);
			d.look <- ::BBCoop.Roster.captureAppearance(_e);
			return d;
		}
		d.script <- this.scriptOf(_e);
		if (d.script == null) return null;
		local items = _e.getItems();
		d.items <- this.serializeWith(function( _out ) { items.onSerialize(_out); });
		d.look <- this.captureLook(_e);
		return d;
	}

	function captureLook( _e )
	{
		local ret = {};
		foreach (name in this.AISprites)
		{
			if (!_e.hasSprite(name)) continue;
			local s = _e.getSprite(name);
			local entry = { brush = s.HasBrush ? s.getBrush().Name : "", visible = s.Visible, color = null };
			try { entry.color = ::BBCoop.Roster.colorToHex(s.Color); } catch (error) {}
			ret[name] <- entry;
		}
		return ret;
	}

	function armorOf( _e, _slot )
	{
		try
		{
			local item = _e.getItems().getItemAtSlot(_slot);
			if (item != null && "getArmor" in item) return item.getArmor();
		}
		catch (error) {}
		return -1;
	}

	// Extra unit fields for players who see the real battlefield
	// Reload skill of a crossbow or handgonne copy, after vanilla shoot_bolt.onUse / reload_bolt
	function syncReloadSkill( _e, _weapon, _loaded )
	{
		local skills = _e.getSkills();
		local script = null, id = null;
		if (skills.hasSkill("actives.shoot_bolt")) { script = "scripts/skills/actives/reload_bolt"; id = "actives.reload_bolt"; }
		else if (skills.hasSkill("actives.fire_handgonne")) { script = "scripts/skills/actives/reload_handgonne_skill"; id = "actives.reload_handgonne"; }
		if (script == null) return;
		if (_loaded)
		{
			if (skills.hasSkill(id)) skills.removeByID(id);
			return;
		}
		if (skills.hasSkill(id)) return;
		local reload = ::new(script);
		reload.setItem(_weapon);
		try { reload.setFatigueCost(::Math.max(0, reload.getFatigueCostRaw() + _weapon.m.FatigueOnSkillUse)); } catch (error) {}
		skills.add(reload);
	}

	function addMirrorFields( _unit, _e, _owner )
	{
		_unit.id <- _e.getID();
		_unit.ap <- _e.getActionPoints();
		_unit.fat <- _e.getFatigue();
		_unit.morale <- _e.getMoraleState();
		_unit.ah <- this.armorOf(_e, ::Const.ItemSlot.Head);
		_unit.ab <- this.armorOf(_e, ::Const.ItemSlot.Body);
		// crossbows and handgonnes: loaded or not decides whether shoot or reload is offered
		try
		{
			local w = _e.getItems().getItemAtSlot(::Const.ItemSlot.Mainhand);
			if (w != null && ("IsLoaded" in w.m)) _unit.ld <- w.m.IsLoaded;
		}
		catch (error) {}
		local info = ::BBCoop.Battle.MirrorOwners[_owner];
		if (!(_e.getID() in info.sent))
		{
			local spawn = null;
			try { spawn = this.describeSpawn(_e, _unit.side); }
			catch (error) { ::BBCoop.log("Could not describe " + _e.getName() + " for " + _owner + ": " + error); }
			if (spawn != null)
			{
				spawn.faction = spawn.faction.tointeger();
				_unit.spawn <- spawn;
				info.sent[_e.getID()] <- true;
			}
		}
	}

	// Host, every frame: when units moved or got hurt, send the players watching a copy a fresh
	// view (at most twice a second), so their copy follows each action, not only turn changes
	LastFingerprint = 0,
	LastTickTime = 0.0,
	function hostTick( _active )
	{
		if (::BBCoop.Battle.HostBattleID == null || ::BBCoop.Battle.MirrorOwners.len() == 0) return;
		local now = ::Time.getRealTimeF();
		if (now - this.LastTickTime < 0.5) return;
		this.LastTickTime = now;
		// v0.46.0: the active unit is part of it. A turn change alone (a brother who waited comes up
		// again, or the host's own brother is next) changed nothing else, so no view went out and the
		// copy kept showing "It's your turn" for a brother whose turn was over.
		local f = _active != null ? _active.getID() % 1000003 : 1;
		foreach (e in ::Tactical.Entities.getAllInstancesAsArray())
		{
			if (e == null || !e.isAlive() || !e.isPlacedOnMap()) continue;
			local t = e.getTile();
			f = (f * 7 + e.getID() * 31 + t.SquareCoords.X * 101 + t.SquareCoords.Y * 7 + e.getHitpoints() * 3 + e.getActionPoints() + e.getFatigue() * 13) % 1000003;
		}
		if (f == this.LastFingerprint) return;
		this.LastFingerprint = f;
		foreach (owner, _ in ::BBCoop.Battle.MirrorOwners)
			::BBCoop.Remote.sendView(owner, _active, true);
	}

	function onNeed( _from, _payload )
	{
		if (!(_from in ::BBCoop.Battle.MirrorOwners) || _payload.battleID != ::BBCoop.Battle.HostBattleID) return;
		local sent = ::BBCoop.Battle.MirrorOwners[_from].sent;
		foreach (id in _payload.ids)
			if (id in sent) delete sent[id];
		local active = null;
		try { active = ::Tactical.TurnSequenceBar.getActiveEntity(); } catch (error) {}
		::BBCoop.Remote.sendView(_from, active);
	}

	// ======================= joiner =======================

	function onScene( _from, _payload )
	{
		local battle = ::BBCoop.Battle;
		if (!this.isEnabled() || this.Active || this.Scene != null) return;
		if (battle.PendingRefs == null || _from != battle.PendingHost || _payload.battleID != battle.PendingBattleID) return;
		if (battle.isInTactical()) return;

		local setup = _payload.setup;
		local properties = null;
		try
		{
			properties = ::Const.Tactical.CombatInfo.getClone();
			properties.TerrainTemplate = setup.terrain;
			properties.Tile = this.findWorldTile(setup);
			if (properties.Tile == null) throw "world tile not found";
			if (setup.location != null)
			{
				properties.LocationTemplate = setup.location;
				properties.IsAttackingLocation = true;
			}
			properties.MapSeed = setup.seed.tointeger();
			properties.CombatID = "BBCoopMirror";
			properties.IsUsingSetPlayers = true;
			properties.Players = [];
			properties.IsFleeingProhibited = true;
			properties.IsLootingProhibited = true;
			properties.IsFogOfWarVisible = setup.fog;
		}
		catch (error)
		{
			::BBCoop.log("Could not set up the real battlefield (" + error + "), using the battle panel");
			return;
		}

		this.Scene = _payload;
		this.Host = _from;
		this.BattleID = _payload.battleID;
		this.StripKey = null;
		this.Leaving = false;
		this.Result = null;
		this.SpawnData.clear();
		this.Needed.clear();
		this.MapMismatchNoted = false;
		// views that came before the scene still carry spawn data
		if (this.View != null && this.View.battleID == this.BattleID) this.collectSpawns(this.View);
		::BBCoop.Connection.setBattleMirror(true, false);
		::BBCoop.log("Building " + _from + "'s battlefield (" + setup.terrain + ", seed " + setup.seed + ")");
		try
		{
			::World.State.startScriptedCombat(properties, false, false, false);
		}
		catch (error)
		{
			::BBCoop.log("Starting the real battlefield failed: " + error);
			this.Scene = null;
			::BBCoop.Connection.setBattleMirror(false, false);
		}
	}

	function findWorldTile( _setup )
	{
		local tile = null;
		if (_setup.pos != null)
		{
			try
			{
				tile = ::World.getTile(::World.worldToTile(::createVec(_setup.pos.x, _setup.pos.y)));
				if (tile.Coords.X == _setup.tile.x && tile.Coords.Y == _setup.tile.y) return tile;
			}
			catch (error) {}
		}
		// the host fought on a tile next to its company: look around
		try
		{
			local center = ::World.State.getPlayer().getTile();
			if (center.Coords.X == _setup.tile.x && center.Coords.Y == _setup.tile.y) return center;
			if (tile != null)
			{
				for (local i = 0; i < 6; i++)
				{
					if (!tile.hasNextTile(i)) continue;
					local next = tile.getNextTile(i);
					if (next.Coords.X == _setup.tile.x && next.Coords.Y == _setup.tile.y) return next;
				}
			}
		}
		catch (error) {}
		if (tile != null) ::BBCoop.log("Using a nearby world tile for the battlefield, the map may differ");
		return tile;
	}

	// The joiner's views (also used by the battle panel)
	function onView( _from, _payload )
	{
		local battle = ::BBCoop.Battle;
		if (battle.PendingRefs == null || _from != battle.PendingHost || _payload.battleID != battle.PendingBattleID) return;
		this.normalize(_payload);
		this.View = _payload;
		this.ViewSeq++;
		this.NewView = true;
		this.Busy = false;
		this.collectSpawns(_payload);
	}

	// Numbers can arrive as floats from the JS side: tables keys and array indices need integers
	function toInt( _v )
	{
		return _v == null ? null : _v.tointeger();
	}

	function normalize( _view )
	{
		if ("activeID" in _view) _view.activeID = this.toInt(_view.activeID);
		if ("dead" in _view)
		{
			local dead = [];
			foreach (id in _view.dead) dead.push(id.tointeger());
			_view.dead = dead;
		}
		foreach (u in _view.units)
		{
			foreach (k in ["x", "y", "hp", "id", "ap", "fat", "morale", "ah", "ab"])
				if (k in u) u[k] = this.toInt(u[k]);
		}
	}

	function collectSpawns( _view )
	{
		foreach (u in _view.units)
		{
			if (("spawn" in u) && ("id" in u) && u.spawn != null)
			{
				this.SpawnData[u.id] <- u.spawn;
				if (u.id in this.Needed) delete this.Needed[u.id];
			}
		}
	}

	function onOrderError( _payload )
	{
		if (!this.Active) return;
		this.Busy = false;
		::BBCoop.notify(_payload.text);
	}

	function isMirrorState( _state )
	{
		return this.Scene != null && !_state.isScenarioMode() && _state.m.StrategicProperties != null && _state.m.StrategicProperties.CombatID == "BBCoopMirror";
	}

	// tactical_state.initMap, before vanilla: same seed as the host
	function beforeInitMap( _state )
	{
		this.Finishing = false; // a new fight starts: whatever closed before is done with
		if (!this.isMirrorState(_state)) return false;
		::Math.seedRandom(this.Scene.setup.seed.tointeger());
		return true;
	}

	// tactical_state.initMap, after vanilla: the map exists, bring in the units
	function afterInitMap( _state )
	{
		this.Active = true;
		this.StartTime = ::Time.getRealTimeF();
		this.Units.clear();
		this.Removed.clear();
		this.ActQueue.clear();
		this.Created.clear();
		this.Moves.clear();
		this.CycleFor = null;
		this.Busy = false;
		local hash = this.mapHash();
		if (hash != this.Scene.setup.hash.tointeger())
		{
			this.MapMismatchNoted = true;
			::BBCoop.log(format("Our copy of the map differs from %s's (%i vs %i)", this.Host, hash, this.Scene.setup.hash));
		}
		if (this.View != null && this.View.battleID == this.BattleID) this.applyView(this.View, true);
		this.NewView = false;
	}

	function getUnit( _id )
	{
		if (_id == null || !(_id in this.Units)) return null;
		local ref = this.Units[_id];
		if (ref == null || ref.isNull()) return null;
		local e = ref.get();
		return e.isAlive() ? e : null;
	}

	function freeTile( _x, _y )
	{
		if (!::Tactical.isValidTileSquare(_x, _y)) return null;
		local tile = ::Tactical.getTileSquare(_x, _y);
		if (tile.IsOccupiedByActor) return null;
		if (!tile.IsEmpty)
		{
			// a tree or rock where the host has none: our map came out different, clear the spot
			try { tile.removeObject(); } catch (error) {}
			if (!tile.IsEmpty) return null;
		}
		return tile;
	}

	function spawnUnit( _u, _d )
	{
		local tile = this.freeTile(_u.x, _u.y);
		if (tile == null)
		{
			::BBCoop.log("No room for " + _d.name + " at " + _u.x + "," + _u.y);
			return null;
		}
		local e = null;
		if (_d.player)
		{
			e = ::World.getTemporaryRoster().create("scripts/entity/tactical/player");
			this.Created.push(::WeakTableRef(e));
			::BBCoop.Roster.deserializeInto(e, _d.raw);
			::BBCoop.Roster.applyAppearance(e, _d.look);
			e.setName(_d.name);
			e.setGuest(true);
			e.setFaction(_d.faction.tointeger());
			::Tactical.addEntityToMap(e, tile.Coords.X, tile.Coords.Y);
			try { e.onCombatStart(); } catch (error) {}
		}
		else
		{
			e = ::Tactical.spawnEntity(_d.script, tile.Coords.X, tile.Coords.Y);
			e.setFaction(_d.faction.tointeger());
			try
			{
				local overflow = ::World.Assets.getOverflowItems();
				local before = overflow.len();
				e.getItems().clear();
				e.getItems().onDeserialize(::BBCoop.Roster.makeReader(_d.items));
				if (overflow.len() > before) overflow.resize(before); // gear that didn't fit is not ours to keep
			}
			catch (error)
			{
				::BBCoop.log("Could not dress " + _d.name + ": " + error);
			}
			::BBCoop.Roster.applyAppearance(e, _d.look, false);
			e.setName(_d.name);
		}
		e.getFlags().set("BBCoopMirrorID", _u.id);
		this.Units[_u.id] <- ::WeakTableRef(e);
		return e;
	}

	function setArmor( _e, _slot, _value )
	{
		if (_value < 0) return false;
		local item = _e.getItems().getItemAtSlot(_slot);
		if (item == null || !("setArmor" in item) || item.getArmor() == _value) return false;
		item.setArmor(_value);
		return true;
	}

	function syncUnit( _e, _u )
	{
		local changed = false;
		if (_e.getHitpoints() != _u.hp)
		{
			local hurt = _u.hp < _e.getHitpoints();
			_e.setHitpoints(::Math.max(1, _u.hp));
			if (hurt)
			{
				try { _e.playSound(::Const.Sound.ActorEvent.DamageReceived, ::Const.Sound.Volume.Actor); } catch (error) {}
			}
			changed = true;
		}
		local armor = false;
		try
		{
			if (this.setArmor(_e, ::Const.ItemSlot.Head, _u.ah)) armor = true;
			if (this.setArmor(_e, ::Const.ItemSlot.Body, _u.ab)) armor = true;
		}
		catch (error) {}
		if (armor)
		{
			try { _e.getSkills().update(); } catch (error) {}
			changed = true;
		}
		if (_e.getActionPoints() != _u.ap) { _e.setActionPoints(_u.ap); changed = true; }
		if (_e.getFatigue() != _u.fat) { _e.setFatigue(_u.fat); changed = true; }
		if ("ld" in _u)
		{
			try
			{
				local w = _e.getItems().getItemAtSlot(::Const.ItemSlot.Mainhand);
				if (w != null && ("IsLoaded" in w.m) && w.m.IsLoaded != _u.ld)
				{
					if ("setLoaded" in w) w.setLoaded(_u.ld);
					else w.m.IsLoaded = _u.ld;
					// vanilla keeps the Reload skill only while the weapon is empty: the shot adds it, the
					// reload removes itself (shoot_bolt.onUse / fire_handgonne). Do the same here, or the
					// copy's brother has no Reload button until he re-equips the weapon (v0.43.3).
					this.syncReloadSkill(_e, w, _u.ld);
					try { _e.getSkills().update(); } catch (e2) {}
					changed = true;
				}
			}
			catch (error) {}
		}
		if (_e.getMoraleState() != _u.morale)
		{
			try { _e.setMoraleState(_u.morale); } catch (error) {}
			changed = true;
		}
		if (changed)
		{
			try { _e.setDirty(true); } catch (error) {}
		}

		local tile = _e.getTile();
		if (tile.SquareCoords.X != _u.x || tile.SquareCoords.Y != _u.y)
			this.Moves.push({ id = _u.id, x = _u.x, y = _u.y, tries = 0 });
	}

	// Removed copies the turn bar may still hold: a dead unit left in the bar later gets a turn,
	// the bar's UI can't find him and the copy locks up (and once crashed on a selected skill)
	Removed = [],
	LastBarClean = 0.0,
	function cleanTurnBar()
	{
		local bar = ::Tactical.TurnSequenceBar;
		local keep = [];
		foreach (ref in this.Removed)
		{
			if (ref == null || ref.isNull()) continue;
			local e = ref.get();
			local inBar = false;
			try { inBar = bar.getTurnsUntilActive(e.getID()) != null; } catch (error) {}
			local active = bar.getActiveEntity();
			local isActive = active != null && active.getID() == e.getID();
			if (!inBar && !isActive) continue;
			this.Advancing = true;
			try
			{
				bar.removeEntity(e);
				::BBCoop.log("Took " + e.getName() + " off the copy's turn bar");
			}
			catch (error) { ::BBCoop.log("Turn bar cleanup: " + error); keep.push(ref); }
			this.Advancing = false;
		}
		this.Removed = keep;
		this.cancelIfNoActive();
	}

	// The copy's own round and turn starts refill action points and recover fatigue (vanilla
	// actor.onRoundStart / onTurnStart); the host's numbers from the last view win (v0.46.0)
	function keepHostPoints( _e )
	{
		if (!this.Active || _e == null || !_e.getFlags().has("BBCoopMirrorID")) return;
		local id = _e.getFlags().get("BBCoopMirrorID");
		if (!(id in this.LastUnits)) return;
		local u = this.LastUnits[id];
		if (("ap" in u) && _e.getActionPoints() != u.ap) _e.setActionPoints(u.ap);
		if (("fat" in u) && _e.getFatigue() != u.fat) _e.setFatigue(u.fat);
	}

	// The game's cursor code needs a living active unit while a skill is selected
	function cancelIfNoActive()
	{
		local state = this.getState();
		if (state == null) return;
		local active = ::Tactical.TurnSequenceBar.getActiveEntity();
		if (active != null && active.isAlive()) return;
		if (state.m.CurrentActionState == ::Const.Tactical.ActionState.SkillSelected || state.m.CurrentActionState == ::Const.Tactical.ActionState.ComputePath)
		{
			state.m.CurrentActionState = null;
			state.m.SelectedSkillID = null;
		}
	}

	// Gone from the host's battle: dead (corpse) or retreated (just gone)
	function removeUnit( _e, _dead )
	{
		this.Removed.push(::WeakTableRef(_e));
		this.Killing = true;
		try
		{
			if (_dead) _e.kill(null, null, ::Const.FatalityType.None, false);
			else
			{
				_e.m.IsTurnDone = true;
				_e.m.IsAlive = false;
				_e.die();
			}
		}
		catch (error)
		{
			::BBCoop.log("Could not remove " + _e.getName() + ": " + error);
			try { _e.kill(null, null, ::Const.FatalityType.None, true); } catch (e2) {}
		}
		this.Killing = false;
	}

	function applyView( _view, _initial )
	{
		if (!_initial && this.LastApplied != null) this.logDrift(this.LastApplied);
		this.LastApplied = _view;
		this.LastUnits.clear();
		foreach (u in _view.units) if ("id" in u) this.LastUnits[u.id] <- u;
		this.Moves.clear();
		local seen = {};
		local need = [];
		foreach (u in _view.units)
		{
			if (!("id" in u)) continue; // an older host
			seen[u.id] <- true;
			local e = this.getUnit(u.id);
			if (e == null && (u.id in this.Units)) continue; // already dead here
			if (e == null)
			{
				if (!(u.id in this.SpawnData))
				{
					if (!(u.id in this.Needed)) { this.Needed[u.id] <- true; need.push(u.id); }
					continue;
				}
				try { e = this.spawnUnit(u, this.SpawnData[u.id]); }
				catch (error) { ::BBCoop.log("Could not copy " + this.SpawnData[u.id].name + ": " + error); }
				if (e == null) continue;
			}
			try { this.syncUnit(e, u); }
			catch (error) { ::BBCoop.log("Could not update " + e.getName() + ": " + error); }
		}

		local dead = {};
		if ("dead" in _view) foreach (id in _view.dead) dead[id] <- true;
		foreach (id, ref in this.Units)
		{
			if (id in seen || ref == null || ref.isNull()) continue;
			local e = ref.get();
			if (e.isAlive()) this.removeUnit(e, id in dead);
		}

		if ("acts" in _view)
		{
			local now = ::Time.getRealTimeF();
			foreach (a in _view.acts)
			{
				try { this.ActQueue.push({ id = a.id.tointeger(), skill = a.skill, x = a.x.tointeger(), y = a.y.tointeger(), queued = now }); }
				catch (error) {}
			}
			while (this.ActQueue.len() > 12) this.ActQueue.remove(0); // far behind: skip the oldest
		}

		if ("log" in _view)
		{
			this.Logging = true;
			foreach (line in _view.log)
			{
				try
				{
					if (line.ex) ::Tactical.EventLog.logEx(line.text);
					else ::Tactical.EventLog.log(line.text);
				}
				catch (error) {}
			}
			this.Logging = false;
		}

		this.showHostRound(_view);

		if (need.len() != 0)
			::BBCoop.Connection.sendMessage("battle_mirror_need", { to = this.Host, battleID = this.BattleID, ids = need });

	}

	function hasMoveFor( _id )
	{
		foreach (m in this.Moves)
			if (m.id == _id) return true;
		return false;
	}

	function updateMoves( _now )
	{
		if (this.Moves.len() == 0 || _now < this.NextMoveTime) return;
		local m = this.Moves.remove(0);
		if (("due" in m) && _now < m.due) { this.Moves.push(m); return; }
		local e = this.getUnit(m.id);
		if (e == null) return;
		local now = e.getTile();
		if (now.SquareCoords.X == m.x && now.SquareCoords.Y == m.y) return;
		local tile = this.freeTile(m.x, m.y);
		if (tile == null)
		{
			// someone still stands there (they move later in this batch): try again shortly
			if (++m.tries < 20) this.Moves.push(m);
			return;
		}
		// animated slide first; if the unit still isn't there a moment later, put it there instantly
		local instant = m.tries >= 3;
		try { ::Tactical.getNavigator().teleport(e, tile, null, null, !instant); }
		catch (error) { ::BBCoop.log("Moving " + e.getName() + " failed: " + error); }
		m.tries += 3;
		m.due <- _now + 1.5; // checked again then: done if he arrived
		if (m.tries < 30) this.Moves.push(m);
		this.NextMoveTime = _now + 0.25;
	}

	// Turn marker (Aaron's ask): in a shared battle the brother whose turn it is gets the game's red
	// arrow over his head, hopping, on every player's screen. Called every frame with the unit acting.
	MarkRef = null,
	MarkBaseX = 0,
	MarkBaseY = 0,
	function markTurn( _e )
	{
		local cur = this.MarkRef != null && !this.MarkRef.isNull() ? this.MarkRef.get() : null;
		local show = _e != null && _e.isAlive() && _e.isPlacedOnMap()
			&& (_e.getFaction() == ::Const.Faction.Player || _e.getFaction() == ::Const.Faction.PlayerAnimals);
		if (cur != null && (!show || cur.getID() != _e.getID())) this.unmarkTurn();
		else if (cur == null) this.MarkRef = null;
		if (!show) return;
		if (this.MarkRef == null)
		{
			local offset = _e.getSpriteOffset("arrow");
			this.MarkBaseX = offset.X;
			this.MarkBaseY = offset.Y;
			this.MarkRef = ::WeakTableRef(_e);
		}
		local arrow = _e.getSprite("arrow");
		if (!arrow.Visible) { arrow.Visible = true; arrow.fadeIn(100); }
		local phase = (::Time.getRealTimeF() * 1.6) % 1.0; // about one and a half hops a second
		local hop = 4.0 * phase * (1.0 - phase) * 12.0;
		_e.setSpriteOffset("arrow", ::createVec(this.MarkBaseX, this.MarkBaseY + hop));
	}

	function unmarkTurn()
	{
		local cur = this.MarkRef != null && !this.MarkRef.isNull() ? this.MarkRef.get() : null;
		this.MarkRef = null;
		if (cur == null) return;
		try
		{
			cur.setSpriteOffset("arrow", ::createVec(this.MarkBaseX, this.MarkBaseY));
			if (cur.isAlive()) cur.showArrow(false);
		}
		catch (error) {}
	}

	// The copy's turn bar runs extra rounds while it catches up; the top bar shows the host's round
	HostRound = null,
	function showHostRound( _view )
	{
		if (!("round" in _view) || _view.round == null || _view.round <= 0) return;
		local round = _view.round.tointeger();
		this.HostRound = round;
		try { ::Time.setRound(round); } catch (error) {}
		try { ::Tactical.TopbarRoundInformation.update(); } catch (error) {}
	}

	// For the log: how far our copy is from the host's battle after a view
	LastDriftLog = 0.0,
	LastApplied = null,
	function logDrift( _view )
	{
		local off = [], missing = 0;
		foreach (u in _view.units)
		{
			if (!("id" in u)) continue;
			local e = this.getUnit(u.id);
			if (e == null) { if (!(u.id in this.Units)) missing++; continue; }
			local t = e.getTile();
			if (t.SquareCoords.X != u.x || t.SquareCoords.Y != u.y)
				off.push(format("%s at %i,%i (host %i,%i)", e.getName(), t.SquareCoords.X, t.SquareCoords.Y, u.x, u.y));
		}
		if (off.len() == 0 && missing == 0) return;
		local now = ::Time.getRealTimeF();
		if (now - this.LastDriftLog < 10.0) return;
		this.LastDriftLog = now;
		local text = format("Copy differs from the host: %i out of place, %i not copied yet", off.len(), missing);
		if (off.len() != 0) text += ": " + off.reduce(@(a, b) a + "; " + b);
		::BBCoop.log(text);
	}

	function isOurTurn()
	{
		return this.View != null && this.View.turn != null;
	}

	// Our brother whose turn it is (his copy here), or null
	function getTurnEntity()
	{
		if (!this.isOurTurn() || !("activeID" in this.View)) return null;
		return this.getUnit(this.View.activeID);
	}

	// Moves the copy's turn bar one step at a time toward the host's active unit. Each step waits
	// until the bar has really moved on (it animates), so no unit is skipped.
	function updateTurnBar( _now, _active, _targetID, _target )
	{
		if (_target == null) return false;
		local activeID = _active != null ? _active.getID() : null;
		if (activeID == _target.getID()) return true;
		if (this.CycleFor != _targetID) { this.CycleFor = _targetID; this.CycleTries = 0; this.LastActiveID = null; this.LastCycle = 0.0; }
		if (this.CycleTries >= this.Units.len() * 2 + 4) return false; // give up for this turn; the map still works
		// A unit that already had his turn in the copy's round (he waited on the host, or the copy's
		// initiative order differs): going on would run the copy into its next round ahead of the
		// host, and every round start there refills everyone's action points (v0.46.0: the copy was
		// three rounds ahead, its brother showed 9 AP where the host had 3). Wait until the host's
		// round moves on; the map still takes orders for our brother whoever the bar shows.
		{
			local togo = null;
			try { togo = ::Tactical.TurnSequenceBar.getTurnsUntilActive(_target.getID()); } catch (error) {}
			local copyRound = 0;
			try { copyRound = ::Tactical.TurnSequenceBar.getCurrentRound(); } catch (error) {}
			if (togo == null && (this.HostRound == null || copyRound >= this.HostRound)) return false;
		}
		local moved = activeID != this.LastActiveID;
		if (!moved && _now - this.LastCycle < 2.0) return false; // still animating
		if (_active != null && ::Tactical.getNavigator().isTravelling(_active)) return false;
		this.LastActiveID = activeID;
		this.LastCycle = _now;
		this.CycleTries++;
		this.Advancing = true;
		try { ::Tactical.TurnSequenceBar.initNextTurn(); } catch (error) { ::BBCoop.log("Turn bar: " + error); }
		this.Advancing = false;
		return false;
	}

	// The small action strip (skills, wait, end turn) for our turns while the turn bar shows
	// someone else; with the turn bar on our brother the game's own skill bar does the job
	function updateStrip( _matched )
	{
		// Aaron (v0.38.0): no extra strip, the game's own skill bar and the map are the controls
		local key = null;
		if (false && this.isOurTurn() && !_matched)
		{
			local state = this.getState();
			local selected = state != null && state.m.CurrentActionState == ::Const.Tactical.ActionState.SkillSelected ? state.m.SelectedSkillID : "";
			key = this.ViewSeq + "|" + this.Busy + "|" + selected;
		}
		if (key == this.StripKey) return;
		this.StripKey = key;
		if (key == null) { ::BBCoop.Connection.setMirrorTurn(null); return; }
		local state = this.getState();
		::BBCoop.Connection.setMirrorTurn({
			turn = this.View.turn,
			busy = this.Busy,
			selected = state != null ? state.m.SelectedSkillID : null
		});
	}

	function getState()
	{
		try { return ::MSU.Utils.getState("tactical_state"); } catch (error) {}
		return null;
	}

	// tactical_state.setActionStateByMouseEvent in the copy: clicks act for our brother,
	// whoever the turn bar shows
	function onMouse( _state, _mouse )
	{
		local e = this.getTurnEntity();
		if (e == null || this.Busy || _state.isInputLocked()) return false;
		if (::Tactical.getNavigator().isTravelling(e)) return false;
		switch (_mouse.getID())
		{
			case 1:
				if (_state.m.CurrentActionState == ::Const.Tactical.ActionState.SkillSelected)
				{
					local tile = ::Tactical.getTile(::Tactical.screenToTile(_mouse.getX(), _mouse.getY()));
					this.onSkill(_state, e, tile);
				}
				else if (_state.m.CurrentActionState == ::Const.Tactical.ActionState.ComputePath)
					_state.executeEntityTravel(e, _mouse);
				else
					_state.computeEntityPath(e, _mouse);
				return true;
			case 2:
				this.cancelAction(_state);
				return true;
		}
		return false;
	}

	function cancelAction( _state )
	{
		try
		{
			::Tactical.getHighlighter().clear();
			::Tactical.getNavigator().clearPath();
			::Tactical.getNavigator().clearVisualisation();
		}
		catch (error) {}
		_state.m.CurrentActionState = null;
		_state.m.SelectedSkillID = null;
		::Cursor.setCursor(::Const.UI.Cursor.Hand);
	}

	// A skill picked in the game's skill bar, by hotkey or in the action strip
	function selectSkill( _state, _skillID )
	{
		local e = this.getTurnEntity();
		if (e == null || this.Busy) return false;
		local skill = e.getSkills().getSkillByID(_skillID);
		if (skill == null) return false;
		if (!skill.isUsable() || !skill.isAffordable())
		{
			::BBCoop.notify(skill.getName() + " can't be used right now.");
			return true;
		}
		if (_state.m.CurrentActionState == ::Const.Tactical.ActionState.SkillSelected && _state.m.SelectedSkillID == _skillID)
		{
			this.cancelAction(_state);
			return true;
		}
		this.cancelAction(_state);
		if (!skill.isTargeted())
		{
			this.sendOrder({ action = "skill", skill = skill.getID(), x = -1, y = -1 });
			return true;
		}
		_state.m.SelectedSkillID = skill.getID();
		_state.m.CurrentActionState = ::Const.Tactical.ActionState.SkillSelected;
		try { ::Tactical.getHighlighter().highlightRangeOfSkill(skill, e); } catch (error) {}
		return true;
	}

	// From the action strip
	function onStripSkill( _skillID )
	{
		local state = this.getState();
		if (state != null) this.selectSkill(state, _skillID);
	}

	function onStripOrder( _action )
	{
		if (_action == "end") this.onEndTurn();
		else if (_action == "wait") this.onWait();
	}

	// Every frame in the mirrored battle, instead of vanilla's turn handling
	function update( _state )
	{
		local now = ::Time.getRealTimeF();
		_state.setInputLocked(true);

		if (this.Leaving)
		{
			this.Leaving = false;
			::BBCoop.log("Leaving the copy of " + this.Host + "'s battle");
			// vanilla's world_state.onCombatFinished runs for this copy before tactical_state.onFinish
			// does, so the flag must be up now (v0.43.0; set in onTacticalFinish it came too late)
			this.Finishing = true;
			_state.exitTactical();
			return;
		}
		if (_state.m.IsBattleEnded) return;

		// our brothers are home already (result applied, or released): nothing left to watch
		if (::BBCoop.Battle.PendingRefs == null && this.Result == null)
		{
			this.Leaving = true;
			return;
		}

		if (!::BBCoop.isOnline(this.Host, ::BBCoop.Battle.HostTimeout))
		{
			::BBCoop.Battle.releaseAway("Lost contact with " + this.Host + " during the battle.");
			return;
		}
		// the host said the battle is over but no result came: after a grace period we go home
		::BBCoop.Battle.checkOver();
		if (::BBCoop.Battle.PendingRefs == null) return;

		// no unit got a turn yet: vanilla only hides the loading screen once someone does
		if (now - this.StartTime > 5.0)
		{
			try { if (::LoadingScreen.isVisible() && !::LoadingScreen.isAnimating()) ::LoadingScreen.hide(); } catch (error) {}
		}

		if (now - this.LastBarClean > 0.5)
		{
			this.LastBarClean = now;
			try { this.cleanTurnBar(); } catch (error) {}
		}
		if (this.NewView)
		{
			this.NewView = false;
			this.applyView(this.View, false);
		}
		if (this.Busy && now - this.BusySince > 10.0) this.Busy = false;

		local nav = ::Tactical.getNavigator();
		this.updateMoves(now);
		this.updateActs(now);

		local active = ::Tactical.TurnSequenceBar.getActiveEntity();
		local targetID = this.View != null && ("activeID" in this.View) ? this.View.activeID : null;
		local target = this.getUnit(targetID);
		local activeNow = active != null ? active.getID() : null;
		if (activeNow != this.SeenActiveID) { this.SeenActiveID = activeNow; this.ActiveSince = now; }
		try { this.markTurn(target); } catch (error) {}
		// The copy's turn bar follows every turn of the host's battle (Aaron, v0.40.0); for other
		// players' units it never runs into a round the host hasn't reached (see updateTurnBar)
		local matched = this.updateTurnBar(now, active, targetID, target);
		if (matched)
		{
			try { active.onUpdate(); } catch (error) {}
		}
		this.updateStrip(matched);
		::BBCoop.Connection.setTurnNotice(this.isOurTurn() ? "It's your turn" : null);
		// our brother's turn: the map takes clicks (onMouse), whether or not the bar shows him
		// (only our own brother's pending move holds the input: another unit the copy can't place
		// used to keep the input locked for the whole turn)
		if (this.isOurTurn() && target != null && !this.Busy && !this.hasMoveFor(targetID))
			_state.setInputLocked(false);
	}

	function sendOrder( _order )
	{
		if (!this.isOurTurn()) return false;
		_order.to <- this.Host;
		_order.battleID <- this.BattleID;
		_order.key <- this.View.turn.key;
		this.Busy = true;
		this.BusySince = ::Time.getRealTimeF();
		::BBCoop.Connection.sendMessage("battle_order", _order);
		return true;
	}

	// tactical_state.executeEntitySkill in the copy: the host uses the skill
	function onSkill( _state, _entity, _tile )
	{
		local skill = _entity.getSkills().getSkillByID(_state.m.SelectedSkillID);
		if (skill == null || _tile == null) return;
		if (skill.isTargeted() && _state.wasInCameraMovementMode()) return;
		local ok = true;
		try { ok = skill.isUsableOn(_tile); } catch (error) {}
		if (!ok)
		{
			::Cursor.setCursor(::Const.UI.Cursor.Denied);
			return;
		}
		this.sendOrder({ action = "skill", skill = skill.getID(), x = _tile.SquareCoords.X, y = _tile.SquareCoords.Y });
		::Tactical.TurnSequenceBar.deselectActiveSkill();
		::Tactical.getHighlighter().clear();
		_state.m.CurrentActionState = null;
		_state.m.SelectedSkillID = null;
		::Cursor.setCursor(::Const.UI.Cursor.Hourglass);
	}

	// tactical_state.executeEntityTravel in the copy, second click on the same tile: the host moves him
	function onTravel( _state, _entity, _tile )
	{
		this.sendOrder({ action = "move", x = _tile.SquareCoords.X, y = _tile.SquareCoords.Y });
		::Tactical.getNavigator().clearPath();
		::Tactical.getNavigator().clearVisualisation();
		::Tactical.getHighlighter().clear();
		_state.m.CurrentActionState = null;
		::Cursor.setCursor(::Const.UI.Cursor.Hourglass);
	}

	// End turn / wait in the copy (buttons or keys)
	// The game's own end turn / wait (button, key, End round) count only when the player could have
	// pressed them: the turn bar shows our brother and has rested on him for a moment. While the bar
	// catches up, the game ends turns by itself as units enter the first slot; those used to reach the
	// host as our "end turn" and skipped our brother.
	SeenActiveID = null,
	LastIgnoredLog = 0.0,
	ActiveSince = 0.0,
	function isPlayerEnding()
	{
		if (!this.isOurTurn() || this.Advancing) return false;
		local mine = this.getTurnEntity();
		local active = null;
		try { active = ::Tactical.TurnSequenceBar.getActiveEntity(); } catch (error) {}
		if (mine == null || active == null) return false;
		if (active.getID() != mine.getID())
		{
			// the turn bar gave up on reaching our brother: the game's End turn / Wait still count
			local gaveUp = this.CycleTries >= this.Units.len() * 2 + 4;
			return gaveUp && ::Time.getRealTimeF() - this.LastCycle > 1.0;
		}
		if (active.getID() != this.SeenActiveID) return false;
		return ::Time.getRealTimeF() - this.ActiveSince > 1.0;
	}

	function onGameEndTurn()
	{
		if (this.isPlayerEnding()) this.onEndTurn();
		else if (this.isOurTurn() && ::Time.getRealTimeF() - this.LastIgnoredLog > 10.0)
		{
			this.LastIgnoredLog = ::Time.getRealTimeF();
			::BBCoop.log("Ignored an end of turn the copy's turn bar made by itself");
		}
	}

	function onGameWait()
	{
		if (this.isPlayerEnding()) this.onWait();
	}

	function onEndTurn()
	{
		if (this.isOurTurn() && !this.Busy) this.sendOrder({ action = "end" });
	}

	function onWait()
	{
		if (this.isOurTurn() && !this.Busy) this.sendOrder({ action = "wait" });
	}

	function leave()
	{
		if (this.Active || this.Scene != null) this.Leaving = true;
	}

	// tactical_state.onFinish (after world_state.onCombatFinished, see Finishing)
	Finishing = false,      // a copy is closing: vanilla's world_state.onCombatFinished runs for it, not for a fight of ours
	function onTacticalFinish()
	{
		this.MarkRef = null;
		::BBCoop.Connection.setTurnNotice(null);
		if (!this.Active && this.Scene == null) return;
		this.Active = false;
		this.Scene = null;
		this.Units.clear();
		this.Removed.clear();
		this.ActQueue.clear();
		this.Moves.clear();
		foreach (ref in this.Created)
		{
			if (ref == null || ref.isNull()) continue;
			try { ::World.getTemporaryRoster().remove(ref.get()); } catch (error) {}
		}
		this.Created.clear();
		this.SpawnData.clear();
		this.LastApplied = null;
		this.LastUnits.clear();
		this.HostRound = null;
		this.View = null;
		this.StripKey = null;
		::BBCoop.Connection.setMirrorTurn(null);
		::BBCoop.Connection.setBattleMirror(false, false);
	}

	// world_state.onCombatFinished (and, as a fallback, the first world frames after): the stored
	// result is applied. v0.42.x applied nothing here: the copy still counted as active, so the
	// result went straight back into Result (keepResult) and the brothers came home as they left.
	function onBackInWorld()
	{
		if (this.Result == null) return;
		local r = this.Result;
		this.Result = null;
		::BBCoop.Battle.onBattleResult(r.from, r.payload);
	}

	// battle_result while we watch the copy: keep it for the world map
	function keepResult( _from, _payload )
	{
		if (this.Finishing) return false; // the copy is closing: apply it now
		if (!this.Active && this.Scene == null) return false;
		this.Result = { from = _from, payload = _payload };
		::BBCoop.Battle.OverAt = null;
		this.leave();
		return true;
	}
};

::BBCoop.MH.hook("scripts/states/tactical_state", function(q) {
	q.executeEntitySkill = @(__original) function( _activeEntity, _targetTile )
	{
		if (!::BBCoop.Mirror.Active) return __original(_activeEntity, _targetTile);
		try { ::BBCoop.Mirror.onSkill(this, _activeEntity, _targetTile); }
		catch (error) { ::BBCoop.log("Mirror skill failed: " + error); }
	}

	q.executeEntityTravel = @(__original) function( _activeEntity, _mouseEvent )
	{
		if (!::BBCoop.Mirror.Active) return __original(_activeEntity, _mouseEvent);
		try
		{
			if (this.wasInCameraMovementMode()) return;
			local tile = ::Tactical.getTile(::Tactical.screenToTile(_mouseEvent.getX(), _mouseEvent.getY()));
			if (::Tactical.getNavigator().HasValidPath && this.m.LastTileSelected != null && this.m.LastTileSelected.X == tile.X && this.m.LastTileSelected.Y == tile.Y)
			{
				::BBCoop.Mirror.onTravel(this, _activeEntity, tile);
				return;
			}
		}
		catch (error) { ::BBCoop.log("Mirror move failed: " + error); }
		return __original(_activeEntity, _mouseEvent);
	}

	// clicks on the map act for our brother (mirror.onMouse), not for whoever the turn bar shows
	q.setActionStateByMouseEvent = @(__original) function( _mouseEvent )
	{
		if (!::BBCoop.Mirror.Active) return __original(_mouseEvent);
		try { return ::BBCoop.Mirror.onMouse(this, _mouseEvent); }
		catch (error) { ::BBCoop.log("Mirror click failed: " + error); }
		return false;
	}

	q.setActionStateBySkillId = @(__original) function( _skillId )
	{
		if (!::BBCoop.Mirror.Active) return __original(_skillId);
		local e = null;
		try { e = ::BBCoop.Mirror.getTurnEntity(); } catch (error) {}
		local active = ::Tactical.TurnSequenceBar.getActiveEntity();
		if (e != null && active != null && active.getID() == e.getID()) return __original(_skillId); // the game's own skill bar
		try { ::BBCoop.Mirror.selectSkill(this, _skillId); }
		catch (error) { ::BBCoop.log("Mirror skill pick failed: " + error); }
	}

	// skill hotkeys pick from the turn bar's unit: only allow them when that is our brother
	q.setActionStateBySkillIndex = @(__original) function( _skillIndex )
	{
		if (!::BBCoop.Mirror.Active) return __original(_skillIndex);
		local e = null;
		try { e = ::BBCoop.Mirror.getTurnEntity(); } catch (error) {}
		local active = ::Tactical.TurnSequenceBar.getActiveEntity();
		if (e == null || active == null || active.getID() != e.getID()) return false;
		return __original(_skillIndex);
	}

	q.topbar_round_information_onQueryRoundInformation = @(__original) function()
	{
		local ret = __original();
		if (::BBCoop.Mirror.Active && ::BBCoop.Mirror.HostRound != null && ret != null)
			ret.roundNumber = ::BBCoop.Mirror.HostRound;
		return ret;
	}

	q.updateCursorAndTooltip = @(__original) function( _skillSelected = false )
	{
		if (!::BBCoop.Mirror.Active) return __original(_skillSelected);
		try { ::BBCoop.Mirror.cancelIfNoActive(); } catch (error) {}
		try { return __original(_skillSelected); }
		catch (error) { try { ::BBCoop.Mirror.cancelAction(this); } catch (e2) {} }
	}

	q.onProcessAI = @(__original) function()
	{
		if (::BBCoop.Mirror.Active) return;
		return __original();
	}
});

// Host: note every skill use for the joiners' animations
::BBCoop.MH.hook("scripts/skills/skill", function(q) {
	q.use = @(__original) function( ... )
	{
		if (!::BBCoop.Mirror.Active && vargv.len() != 0)
		{
			try { ::BBCoop.Mirror.onSkillUsed(this, vargv[0]); } catch (error) {}
		}
		local args = [this];
		args.extend(vargv);
		return __original.acall(args);
	}
});

// Host: a brother who retreats leaves the turn bar too (as with deaths, vanilla didn't always)
::BBCoop.MH.hook("scripts/entity/tactical/player", function(q) {
	q.retreat = @(__original) function()
	{
		local ret = __original();
		if (!::BBCoop.Mirror.Active && ::BBCoop.Battle.HostBattleID != null)
		{
			try { ::Tactical.TurnSequenceBar.removeEntity(this); } catch (error) {}
		}
		return ret;
	}
});

::BBCoop.MH.hook("scripts/entity/tactical/tactical_entity_manager", function(q) {
	// the copy never ends on its own: the host's battle decides
	q.checkCombatFinished = @(__original) function( _forceFinish = false )
	{
		if (::BBCoop.Mirror.Active) return;
		return __original(_forceFinish);
	}
});

::BBCoop.MH.hook("scripts/entity/tactical/actor", function(q) {
	// a copy's round/turn start must not refill what the host's brother has spent (v0.46.0)
	q.onRoundStart = @(__original) function( ... )
	{
		local args = [this];
		args.extend(vargv);
		local ret = __original.acall(args);
		if (::BBCoop.Mirror.Active) { try { ::BBCoop.Mirror.keepHostPoints(this); } catch (error) {} }
		return ret;
	}
	q.onTurnStart = @(__original) function( ... )
	{
		local args = [this];
		args.extend(vargv);
		local ret = __original.acall(args);
		if (::BBCoop.Mirror.Active) { try { ::BBCoop.Mirror.keepHostPoints(this); } catch (error) {} }
		return ret;
	}
	q.kill = @(__original) function( _killer = null, _skill = null, _fatalityType = ::Const.FatalityType.None, _silent = false )
	{
		if (::BBCoop.Mirror.Active && !::BBCoop.Mirror.Killing) return; // only the host's battle kills
		try
		{
			if (::BBCoop.Battle.HostBattleID != null && ::BBCoop.Battle.MirrorOwners.len() != 0 && this.isAlive())
				::BBCoop.Mirror.DeadIDs.push(this.getID());
		}
		catch (error) {}
		local ret = __original(_killer, _skill, _fatalityType, _silent);
		// host of a shared battle: a dead brother left in the turn bar later "gets a turn", the bar's
		// UI can't find him and the battle freezes (seen when a friend's brother died)
		if (!::BBCoop.Mirror.Active && ::BBCoop.Battle.HostBattleID != null && !this.isAlive())
		{
			// (vanilla removes him only while he counts as placed on the map, which a visiting
			// brother didn't always; removing one who isn't in the bar does nothing)
			try { ::Tactical.TurnSequenceBar.removeEntity(this); } catch (error) {}
		}
		return ret;
	}
});

::BBCoop.MH.hook("scripts/ui/screens/tactical/modules/turn_sequence_bar/turn_sequence_bar", function(q) {
	q.initNextTurn = @(__original) function( ... )
	{
		if (::BBCoop.Mirror.Active && !::BBCoop.Mirror.Advancing)
		{
			try { ::BBCoop.Mirror.onGameEndTurn(); } catch (error) {}
			return;
		}
		local args = [this];
		args.extend(vargv);
		local ret = __original.acall(args);
		// host of a shared battle: never hand the turn to a dead unit (his turn bar entry can't be
		// shown and the battle froze); move on to the next one.
		// v0.46.0: not while vanilla itself is done with the round. With one unit left in the round
		// initNextTurn only flags the next round and keeps him in front, and removeEntity on the
		// front unit calls initNextTurn again: the old loop recursed through this hook until the
		// game crashed (a dead Brigand Thug, 184,000 log lines). The next round clears him anyway.
		if (::BBCoop.Battle.HostBattleID != null && !::BBCoop.Mirror.Active && !::BBCoop.Mirror.Skipping)
		{
			::BBCoop.Mirror.Skipping = true;
			try
			{
				for (local i = 0; i < 8; i++)
				{
					if (this.m.IsLocked || this.m.IsInitNextRound || this.m.CurrentEntities.len() <= 1) break;
					local e = this.getActiveEntity();
					if (e == null || (e.isAlive() && e.isPlacedOnMap())) break;
					::BBCoop.log(e.getName() + " is dead or gone but was next in the turn bar: skipping him");
					this.removeEntity(e);
					if (this.getActiveEntity() != e) break;
					__original.acall(args);
					if (this.getActiveEntity() == e) break; // vanilla keeps him: leave it to the next round
				}
			}
			catch (error) { ::BBCoop.log("Turn bar skip: " + error); }
			::BBCoop.Mirror.Skipping = false;
		}
		return ret;
	}

	// "End round" (button or Enter) skips every brother the game counts as player-controlled. On the
	// host that includes the brothers other players control, so their turns were skipped too: give
	// those back. In a copy of someone else's battle it just ends our brother's turn.
	q.onEndTurnAllButtonPressed = @(__original) function( ... )
	{
		if (::BBCoop.Mirror.Active)
		{
			try { ::BBCoop.Mirror.onGameEndTurn(); } catch (error) {}
			return;
		}
		local args = [this];
		args.extend(vargv);
		local ret = __original.acall(args);
		try
		{
			if (::BBCoop.Battle.HostBattleID != null)
			{
				foreach (e in ::Tactical.Entities.getInstancesOfFaction(::Const.Faction.Player))
				{
					if (e != null && e.isAlive() && ::BBCoop.Remote.getOwner(e) != null && e.getID() != ::BBCoop.Remote.TookOverID)
						e.setSkipTurn(false);
				}
			}
		}
		catch (error) { ::BBCoop.log("End round: " + error); }
		return ret;
	}

	q.entityWaitTurn = @(__original) function( _entity )
	{
		if (::BBCoop.Mirror.Active && !::BBCoop.Mirror.Advancing)
		{
			try { ::BBCoop.Mirror.onGameWait(); } catch (error) {}
			return true;
		}
		return __original(_entity);
	}
});

::BBCoop.MH.hook("scripts/ui/screens/tactical/modules/topbar/tactical_screen_topbar_event_log", function(q) {
	q.log = @(__original) function( ... )
	{
		local text = vargv.len() != 0 ? vargv[0] : null;
		if (::BBCoop.Mirror.Active && !::BBCoop.Mirror.Logging) return; // the host's log is the one that counts
		try { ::BBCoop.Mirror.onLogLine(text, false); } catch (error) {}
		local args = [this];
		args.extend(vargv);
		return __original.acall(args);
	}

	q.logEx = @(__original) function( ... )
	{
		local text = vargv.len() != 0 ? vargv[0] : null;
		if (::BBCoop.Mirror.Active && !::BBCoop.Mirror.Logging) return;
		try { ::BBCoop.Mirror.onLogLine(text, true); } catch (error) {}
		local args = [this];
		args.extend(vargv);
		return __original.acall(args);
	}
});

// Back on the world map after a copy of someone else's battle. Checked against vanilla
// world_state.onCombatFinished (v0.42.1): with no parties of ours in that fight it would still put a
// battlefield marker where our company stands and stun the parties around us; the arena flag skips the
// marker (and the empty parties loop), the stun is skipped below. The rest (brothers' onCombatFinished,
// ammo refill, repairs, time reset to the combat start) is harmless here: nobody of ours fought in it.
::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.onCombatFinished = @(__original) function()
	{
		local mirror = ::BBCoop.Mirror.Finishing;
		local wasArena = null;
		if (mirror)
		{
			try
			{
				wasArena = ::World.Statistics.getFlags().get("LastCombatWasArena");
				::World.Statistics.getFlags().set("LastCombatWasArena", true);
			}
			catch (error) {}
		}
		__original();
		if (mirror)
		{
			::BBCoop.Mirror.Finishing = false;
			try { ::World.Statistics.getFlags().set("LastCombatWasArena", wasArena == true); } catch (error) {}
		}
		try { ::BBCoop.Mirror.onBackInWorld(); }
		catch (error) { ::BBCoop.log("Applying the battle result failed: " + error); }
	}

	q.stunPartiesNearPlayer = @(__original) function( _isMinor = false )
	{
		if (::BBCoop.Mirror.Finishing) return;
		return __original(_isMinor);
	}
});
