// New settlements (v0.44.0, roadmap item 6, Aaron 2026-11-01): a prosperous settlement can send
// settlers out to found a small village a few tiles away, joined to it by a new road.
//
// Only the host's world founds (and a world played alone). A joiner's world copies what the host
// founded: the host's "world_full" carries a "founded" list (tile, script, name, owner, road
// tiles with their road directions), and the joiner spawns the same village on the same tile and
// draws the same road.
//
// Vanilla has no prosperity number, so "prosperous" here means: a northern civilian settlement
// (no castle, no southern city) that has a noble owner, is not burned, has none of its farms,
// mines or camps burned, has no bad situation (raided, sickness, ambushed trade routes ...) and
// has at least one good one (well supplied, good harvest, seasonal fair ...); cities (size 3)
// count as prosperous without a good situation.
// Pacing: nothing before day 20; at most one new village every 10 days in the whole world, with a
// 25% chance on each new day once that wait is over; a settlement founds at most 2 villages and
// waits 50 days between them (a new village waits 50 days before it can found one itself); at
// most 10 new villages per world.
//
// Saved in World.Flags (so a save remembers the roads even if the engine does not keep them):
//   BBCoopFoundedNum = n, BBCoopFounded<i> = "x,y,script,founderX,founderY,day",
//   BBCoopFoundedRoad<i> = "x:y:dirs;x:y:dirs;..."
//   BBCoopFounder<tileID> = "lastDay,count"
// Built from vanilla worldmap_generator (buildSettlements, buildRoads, buildAdditionalRoads,
// buildRoadSprites, getTerrainInRegion), settlement (build, updateProperties) and
// faction_manager.createSettlements.

::BBCoop.Settlements <- {
	FirstDay = 20,
	WorldCooldownDays = 10,
	DailyChance = 25,
	FounderCooldownDays = 50,
	MaxPerFounder = 2,
	MaxPerWorld = 10,
	MinDistance = 4,     // tiles from the founder (and from any other settlement)
	MaxDistance = 7,     // tiles from the founder
	MaxRoadLength = 16,

	GoodSituations = [
		"situation.well_supplied", "situation.good_harvest", "situation.full_nets", "situation.rich_veins",
		"situation.seasonal_fair", "situation.high_spirits", "situation.safe_roads", "situation.hunting_season",
		"situation.local_holiday", "situation.preparing_feast", "situation.ceremonial_season", "situation.archery_contest"
	],
	BadSituations = [
		"situation.raided", "situation.razed", "situation.conquered", "situation.besieged",
		"situation.ambushed_trade_routes", "situation.disappearing_villagers", "situation.short_on_food",
		"situation.sickness", "situation.draught", "situation.greenskins", "situation.unhold_attacks",
		"situation.refugees", "situation.warehouse_burned_down", "situation.terrified_villagers",
		"situation.terrifying_nightmares", "situation.mine_cavein", "situation.lost_at_sea",
		"situation.abducted_children", "situation.rebuilding_effort", "situation.witch_burnings",
		"situation.cultist_procession", "situation.snow_storms", "situation.sand_storm"
	],

	LastDayChecked = -1,
	RoadsRestored = false,

	function reset()
	{
		this.LastDayChecked = -1;
		this.RoadsRestored = false;
	}

	function isEnabled()
	{
		try { return ::BBCoop.getSetting("NewSettlements"); } catch (error) {}
		return true;
	}

	// ---- stored list ----

	function count()
	{
		return ::World.Flags.has("BBCoopFoundedNum") ? ::World.Flags.get("BBCoopFoundedNum").tointeger() : 0;
	}

	function getEntries()
	{
		local ret = [];
		local n = this.count();
		for (local i = 0; i < n; i++)
		{
			if (!::World.Flags.has("BBCoopFounded" + i)) continue;
			local parts = split(::World.Flags.get("BBCoopFounded" + i), ",");
			if (parts.len() < 6) continue;
			ret.push({
				x = parts[0].tointeger(),
				y = parts[1].tointeger(),
				sc = parts[2],
				fx = parts[3].tointeger(),
				fy = parts[4].tointeger(),
				d = parts[5].tointeger(),
				road = this.parseRoad(::World.Flags.has("BBCoopFoundedRoad" + i) ? ::World.Flags.get("BBCoopFoundedRoad" + i) : "")
			});
		}
		return ret;
	}

	function hasEntryAt( _x, _y )
	{
		foreach (e in this.getEntries())
			if (e.x == _x && e.y == _y) return true;
		return false;
	}

	function store( _x, _y, _script, _fx, _fy, _day, _road )
	{
		local i = this.count();
		::World.Flags.set("BBCoopFounded" + i, format("%i,%i,%s,%i,%i,%i", _x, _y, _script, _fx, _fy, _day));
		::World.Flags.set("BBCoopFoundedRoad" + i, this.roadToString(_road));
		::World.Flags.set("BBCoopFoundedNum", i + 1);
	}

	// road: flat array [x, y, dirs, x, y, dirs, ...] (tile Coords and the tile's RoadDirections)
	function roadToString( _road )
	{
		local parts = [];
		for (local i = 0; i + 2 < _road.len(); i += 3)
			parts.push(format("%i:%i:%i", _road[i], _road[i + 1], _road[i + 2]));
		if (parts.len() == 0) return "";
		return parts.reduce(@(a, b) a + ";" + b);
	}

	function parseRoad( _s )
	{
		local ret = [];
		if (_s == null || _s == "") return ret;
		foreach (p in split(_s, ";"))
		{
			local v = split(p, ":");
			if (v.len() < 3) continue;
			ret.push(v[0].tointeger());
			ret.push(v[1].tointeger());
			ret.push(v[2].tointeger());
		}
		return ret;
	}

	function getFounderInfo( _tile )
	{
		local key = "BBCoopFounder" + _tile.ID;
		if (!::World.Flags.has(key)) return { Day = -1000, Count = 0 };
		local v = split(::World.Flags.get(key), ",");
		return { Day = v[0].tointeger(), Count = v.len() > 1 ? v[1].tointeger() : 0 };
	}

	function setFounderInfo( _tile, _day, _count )
	{
		::World.Flags.set("BBCoopFounder" + _tile.ID, format("%i,%i", _day, _count));
	}

	// ---- which settlements can found ----

	function isCivilianNorthern( _s )
	{
		if (_s.isMilitary()) return false;
		if (::isKindOf(_s, "city_state")) return false;
		try { if (_s.isSouthern()) return false; } catch (error) {}
		return true;
	}

	// 0 = not prosperous; higher = more likely to be picked
	function prosperity( _s )
	{
		if (!_s.isActive() || !this.isCivilianNorthern(_s) || _s.getOwner() == null) return 0;
		foreach (a in _s.getAttachedLocations())
			if (!a.isActive()) return 0;
		local good = 0;
		foreach (sit in _s.getSituations())
		{
			local id = sit.getID();
			if (this.BadSituations.find(id) != null) return 0;
			if (this.GoodSituations.find(id) != null) good++;
		}
		if (good == 0 && _s.getSize() < 3) return 0;
		return good + _s.getSize();
	}

	function canFound( _s, _day )
	{
		local info = this.getFounderInfo(_s.getTile());
		if (info.Count >= this.MaxPerFounder) return false;
		if (_day - info.Day < this.FounderCooldownDays) return false;
		return true;
	}

	// ---- terrain (vanilla worldmap_generator.getTerrainInRegion) ----

	function getTerrain( _tile )
	{
		local terrain = { Local = _tile.Type, Adjacent = [], Region = [] };
		terrain.Adjacent.resize(::Const.World.TerrainType.COUNT, 0);
		terrain.Region.resize(::Const.World.TerrainType.COUNT, 0);
		for (local i = 0; i < 6; i++)
			if (_tile.hasNextTile(i)) terrain.Adjacent[_tile.getNextTile(i).Type]++;
		::World.queryTilesInRange(_tile, 1, 4, function( _t, _region ) { _region[_t.Type]++; }, terrain.Region);
		return terrain;
	}

	// small village scripts (no forts: those would be castles) that fit this tile
	function villageScripts( _terrain )
	{
		local ret = [];
		local lists = [];
		local coastal = _terrain.Adjacent[::Const.World.TerrainType.Ocean] > 0 || _terrain.Adjacent[::Const.World.TerrainType.Shore] > 0;
		if (coastal && ("Villages_small_coast" in ::Const.World.Settlements)) lists.push(::Const.World.Settlements.Villages_small_coast);
		if ("Villages_small" in ::Const.World.Settlements) lists.push(::Const.World.Settlements.Villages_small);
		foreach (list in lists)
		{
			foreach (entry in list)
			{
				if (!("Script" in entry) || entry.Script.find("_fort") != null) continue;
				local ok = false;
				try { ok = entry.isSuitable(_terrain); } catch (error) { ok = false; }
				if (ok) ret.push(entry.Script);
			}
		}
		return ret;
	}

	// ---- roads (vanilla buildRoads / buildAdditionalRoads / buildRoadSprites) ----

	function roadNavSettings()
	{
		local roadCost = [0, 0, 10, 50, 60, 40, 40, 40, 40, 0, 1, 50, 30, 30, 10, 10, 0, 10, 10];
		roadCost.resize(::Const.World.TerrainType.COUNT, 50);
		local nav = ::World.getNavigator().createSettings();
		nav.ActionPointCosts = roadCost;
		nav.RoadMult = 0.15;
		nav.StopAtRoad = false;
		return nav;
	}

	// tiles from _from to _to along a new road, or null when no good road can be built
	function planRoad( _from, _to )
	{
		local path = ::World.getNavigator().findPath(_from, _to, this.roadNavSettings(), 0);
		if (path.isEmpty()) return null;
		local tiles = [_from];
		while (path.getSize() >= 1)
		{
			tiles.push(::World.getTile(path.getCurrent()));
			path.pop();
		}
		if (tiles.len() < 2 || tiles.len() > this.MaxRoadLength) return null;
		if (tiles[tiles.len() - 1].ID != _to.ID) return null;
		// road directions each tile ends up with; no hills (vanilla re-terrains those) and only
		// combinations a road sprite exists for
		local road = [];
		local prev = null;
		foreach (i, tile in tiles)
		{
			if (tile.Type == ::Const.World.TerrainType.Hills || tile.Type == ::Const.World.TerrainType.Mountains) return null;
			local dirA = prev != null ? tile.getDirectionTo(prev) : 0;
			local dirB = i < tiles.len() - 1 ? tile.getDirectionTo(tiles[i + 1]) : 0;
			local dirs = tile.RoadDirections;
			if (prev != null) dirs = dirs | ::Const.DirectionBit[dirA];
			if (i < tiles.len() - 1) dirs = dirs | ::Const.DirectionBit[dirB];
			if (!::Const.World.RoadBrushes.has(dirs)) return null;
			road.push(tile.Coords.X);
			road.push(tile.Coords.Y);
			road.push(dirs);
			prev = tile;
		}
		return road;
	}

	// sets the road directions and draws the road sprites
	function applyRoad( _road )
	{
		local changed = false;
		for (local i = 0; i + 2 < _road.len(); i += 3)
		{
			local tile = null;
			try { tile = ::World.getTile(_road[i], _road[i + 1]); } catch (error) { tile = null; }
			if (tile == null) continue;
			local dirs = tile.RoadDirections | _road[i + 2];
			if (!::Const.World.RoadBrushes.has(dirs)) dirs = _road[i + 2];
			if (!::Const.World.RoadBrushes.has(dirs)) continue;
			if (dirs == tile.RoadDirections && tile.HasRoad && this.RoadsRestored) continue;
			tile.RoadDirections = dirs;
			try
			{
				tile.clear(::Const.World.DetailType.Road | ::Const.World.DetailType.Swamp | ::Const.World.DetailType.NotCompatibleWithRoad);
				tile.spawnDetail(::Const.World.RoadBrushes.get(dirs), ::Const.World.ZLevel.Road, ::Const.World.DetailType.Road, false);
			}
			catch (error)
			{
				::BBCoop.log("Could not draw a road tile: " + error);
			}
			changed = true;
		}
		if (changed)
			try { ::World.EntityManager.buildRoadAmbushSpots(); } catch (error) {}
	}

	// tiles of the road that are not its ends: kept free of the new village's houses
	function reserveRoad( _road, _reserve )
	{
		local held = [];
		for (local i = 3; i + 5 < _road.len(); i += 3)
		{
			local tile = ::World.getTile(_road[i], _road[i + 1]);
			if (_reserve && !tile.IsOccupied)
			{
				tile.IsOccupied = true;
				held.push(tile);
			}
		}
		return held;
	}

	// ---- picking a site ----

	function findSite( _founder )
	{
		local origin = _founder.getTile();
		local tiles = [];
		::World.queryTilesInRange(origin, this.MinDistance, this.MaxDistance, function( _t, _list ) { _list.push(_t); }, tiles);
		local settlements = ::World.EntityManager.getSettlements();
		local tries = 0;
		while (tiles.len() != 0 && tries++ < 40)
		{
			local tile = tiles.remove(::Math.rand(0, tiles.len() - 1));
			if (tile.IsOccupied) continue;
			local t = tile.Type;
			if (t == ::Const.World.TerrainType.Ocean || t == ::Const.World.TerrainType.Shore || t == ::Const.World.TerrainType.Mountains || t == ::Const.World.TerrainType.Hills) continue;
			local edge = false;
			for (local i = 0; i < 6; i++) if (!tile.hasNextTile(i)) edge = true;
			if (edge) continue;
			local tooClose = false;
			foreach (s in settlements)
			{
				if (s.getTile().getDistanceTo(tile) < this.MinDistance) { tooClose = true; break; }
			}
			if (tooClose) continue;
			local terrain = this.getTerrain(tile);
			if (terrain.Adjacent[::Const.World.TerrainType.Ocean] >= 3 || terrain.Adjacent[::Const.World.TerrainType.Shore] >= 3) continue;
			local scripts = this.villageScripts(terrain);
			if (scripts.len() == 0) continue;
			local road = this.planRoad(tile, origin);
			if (road == null) continue;
			return { Tile = tile, Script = scripts[::Math.rand(0, scripts.len() - 1)], Road = road };
		}
		return null;
	}

	// ---- creating the village (host and joiner) ----

	function spawnVillage( _tile, _script, _road, _name, _owner )
	{
		local held = this.reserveRoad(_road, true);
		local s = null;
		try
		{
			_tile.clear();
			s = ::World.spawnLocation(_script, _tile.Coords);
			if (_name != null && _name != "")
			{
				s.setName(_name);
				try { if (s.hasLabel("name")) s.getLabel("name").Text = _name; } catch (error) {}
			}
			s.updateProperties();
			s.build();
		}
		catch (error)
		{
			foreach (t in held) t.IsOccupied = false;
			::BBCoop.log("Could not found a settlement: " + error);
			if (s != null) try { s.die(); } catch (e2) {}
			return null;
		}
		foreach (t in held) t.IsOccupied = false;

		// its own village faction first (vanilla createSettlements), then the noble owner
		try
		{
			local fm = ::World.FactionManager;
			local f = ::new("scripts/factions/settlement_faction");
			f.setID(fm.m.Factions.len());
			f.setName(s.getName());
			f.setDescription(s.getDescription());
			f.setBanner(11);
			f.setDiscovered(true);
			fm.m.Factions.push(f);
			f.addTrait(::Const.FactionTrait.Settlement);
			f.addSettlement(s, false);
		}
		catch (error)
		{
			::BBCoop.log("Could not give the new settlement its faction: " + error);
		}
		if (_owner != null)
			try { _owner.addSettlement(s); } catch (error) { ::BBCoop.log("Could not give the new settlement its owner: " + error); }

		this.applyRoad(_road);

		// who it is connected to (vanilla updateProperties), both ways
		try
		{
			s.updateProperties();
			foreach (other in ::World.EntityManager.getSettlements())
			{
				if (other.getID() == s.getID()) continue;
				if (s.m.ConnectedTo.find(other.getID()) != null && other.m.ConnectedTo.find(s.getID()) == null) other.m.ConnectedTo.push(s.getID());
				if (s.m.ConnectedToByRoads.find(other.getID()) != null && other.m.ConnectedToByRoads.find(s.getID()) == null) other.m.ConnectedToByRoads.push(s.getID());
			}
		}
		catch (error) {}
		try { ::World.updateTilesWithHeat([_tile], 6); } catch (error) {}
		return s;
	}

	function discoverIfNear( _s, _founder )
	{
		try
		{
			local known = _founder == null || _founder.isDiscovered();
			if (known) _s.setDiscovered(true);
		}
		catch (error)
		{
			try { _s.setDiscovered(true); } catch (e2) {}
		}
	}

	// ---- host: once per new day ----

	function tryFound( _day )
	{
		if (_day < this.FirstDay || this.count() >= this.MaxPerWorld) return;
		local last = ::World.Flags.has("BBCoopFoundedLastDay") ? ::World.Flags.get("BBCoopFoundedLastDay").tointeger() : -1000;
		if (_day - last < this.WorldCooldownDays) return;
		if (::Math.rand(1, 100) > this.DailyChance) return;

		local candidates = [], total = 0;
		foreach (s in ::World.EntityManager.getSettlements())
		{
			local p = 0;
			try { p = this.prosperity(s); } catch (error) { p = 0; }
			if (p <= 0 || !this.canFound(s, _day)) continue;
			candidates.push({ S = s, W = p });
			total += p;
		}
		while (candidates.len() != 0)
		{
			local r = ::Math.rand(1, total), pick = 0;
			for (local i = 0; i < candidates.len(); i++)
			{
				r -= candidates[i].W;
				if (r <= 0) { pick = i; break; }
			}
			local c = candidates.remove(pick);
			total -= c.W;
			if (this.found(c.S, _day)) return;
		}
	}

	function found( _founder, _day )
	{
		local site = this.findSite(_founder);
		if (site == null) return false;
		local s = this.spawnVillage(site.Tile, site.Script, site.Road, null, _founder.getOwner());
		if (s == null) return false;
		local ft = _founder.getTile();
		this.store(site.Tile.Coords.X, site.Tile.Coords.Y, site.Script, ft.Coords.X, ft.Coords.Y, _day, site.Road);
		::World.Flags.set("BBCoopFoundedLastDay", _day);
		local info = this.getFounderInfo(ft);
		this.setFounderInfo(ft, _day, info.Count + 1);
		this.setFounderInfo(site.Tile, _day, 0); // the new village waits before it founds one itself
		this.discoverIfNear(s, _founder);
		::BBCoop.notify(format("Settlers from prosperous %s founded the village of %s nearby, with a road between them.", _founder.getName(), s.getName()));
		::BBCoop.World.FullRequested = true; // joiners get it with the next world update
		return true;
	}

	// ---- world sync ----

	// host: what goes into "world_full"
	function pack()
	{
		local ret = [];
		foreach (e in this.getEntries())
		{
			local tile = ::World.getTile(e.x, e.y);
			local s = this.settlementOn(tile);
			if (s == null) continue;
			local owner = s.getOwner();
			ret.push({
				x = e.x, y = e.y, sc = e.sc, n = s.getName(),
				fx = e.fx, fy = e.fy, d = e.d,
				o = owner != null ? owner.getID() : -1,
				ot = owner != null ? owner.getType() : -1,
				road = e.road
			});
		}
		return ret;
	}

	function settlementOn( _tile )
	{
		foreach (s in ::World.EntityManager.getSettlements())
			if (s.getTile().ID == _tile.ID) return s;
		return null;
	}

	// joiner: found what the host founded
	function sync( _snapshot )
	{
		if (!("founded" in _snapshot) || _snapshot.founded == null) return;
		foreach (f in _snapshot.founded)
		{
			try
			{
				local x = f.x.tointeger(), y = f.y.tointeger();
				local tile = ::World.getTile(x, y);
				local road = [];
				foreach (v in f.road) road.push(v.tointeger());
				if (this.settlementOn(tile) != null) continue; // copied already
				if (tile.IsOccupied) continue; // a camp of ours still fading out there: next time
				local owner = f.ot.tointeger() >= 0 ? ::BBCoop.World.findFaction(f.o.tointeger(), f.ot.tointeger()) : null;
				local founder = this.settlementOn(::World.getTile(f.fx.tointeger(), f.fy.tointeger()));
				local s = this.spawnVillage(tile, f.sc, road, f.n, owner);
				if (s == null) continue;
				this.store(x, y, f.sc, f.fx.tointeger(), f.fy.tointeger(), f.d.tointeger(), road);
				this.discoverIfNear(s, founder);
				::BBCoop.notify(format("Settlers from %s founded the village of %s in %s's world.", founder != null ? founder.getName() : "a prosperous town", s.getName(), ::BBCoop.World.getHost()));
			}
			catch (error)
			{
				::BBCoop.log("Could not copy a founded settlement: " + error);
			}
		}
	}

	// ---- every frame ----

	function update()
	{
		if (!::BBCoop.Ghosts.isWorldActive()) return;
		if (::BBCoop.Battle.isInTactical()) return;
		if (!this.RoadsRestored)
		{
			// redraw stored roads once after loading, in case the save did not keep them
			foreach (e in this.getEntries())
				try { this.applyRoad(e.road); } catch (error) {}
			this.RoadsRestored = true;
		}
		local day = ::World.getTime().Days;
		if (day == this.LastDayChecked) return;
		local first = this.LastDayChecked < 0;
		this.LastDayChecked = day;
		if (first) return; // just loaded: wait for a real new day
		if (::BBCoop.World.getHost() != null || !this.isEnabled()) return; // joiners copy the host
		try { this.tryFound(day); } catch (error) { ::BBCoop.log("Founding a settlement failed: " + error); }
	}
};

::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.onUpdate = @(__original) function()
	{
		__original();
		try { ::BBCoop.Settlements.update(); } catch (error) { ::BBCoop.log("New settlements update failed: " + error); }
	}

	q.onFinish = @(__original) function()
	{
		::BBCoop.Settlements.reset();
		__original();
	}

	q.loadCampaign = @(__original) function( _campaignFileName )
	{
		::BBCoop.Settlements.reset();
		__original(_campaignFileName);
	}
});
