// Loot for players who joined a battle on the host's side: what you kill, you get (Aaron's rule).
// Every kill records whose brother struck the blow, and the victim's gear goes to that player.
// When the host wins, the loot is split before the loot screen opens: gear that belonged to a
// joiner's own fallen brothers goes back to them, each enemy's gear goes to whoever killed it,
// and loot that belongs to no single enemy (crowns, the party's stash, ammo and armor parts)
// is shared by number of kills. A joiner's share is sent as "battle_loot" and lands in their
// stash (crowns, ammo and other supplies are added straight to their stock).
// Checked against vanilla tactical_state.gatherLoot, stash_container and item/money_item.

::BBCoop.Loot <- {
	OwnedItems = {},     // item instance id -> owner, for gear the joiners brought
	KilledItems = {},    // item instance id -> player whose brother killed its wearer ("" = us)
	Kills = {},          // player -> kills this battle ("" = us)
	HostFighters = 0,    // how many of our own brothers started the battle

	function reset()
	{
		this.OwnedItems.clear();
		this.KilledItems.clear();
		this.Kills.clear();
		this.HostFighters = 0;
	}

	function onBattleStarted()
	{
		this.reset();
		foreach (bro in ::World.getPlayerRoster().getAll())
			if (bro.isPlacedOnMap()) this.HostFighters++;
	}

	function recordItems( _bro, _owner )
	{
		try
		{
			foreach (item in _bro.getItems().getAllItems())
				if (item != null) this.OwnedItems[item.getInstanceID()] <- _owner;
		}
		catch (error)
		{
			::BBCoop.log("Could not record the gear of " + _bro.getName() + ": " + error);
		}
	}

	// Called just before an actor dies: its gear belongs to whoever killed it
	function onKill( _victim, _killer )
	{
		if (::BBCoop.Battle.HostBattleID == null || _killer == null) return;
		if (_victim.getFlags().has("BBCoopOwner")) return; // a joiner's brother: their gear goes home anyway
		local owner = "";
		if (_killer.getFlags().has("BBCoopOwner"))
		{
			if (_killer.getFaction() != ::Const.Faction.Player) return; // joined against us: no share
			owner = _killer.getFlags().get("BBCoopOwner");
		}
		else if (_killer.getFaction() != ::Const.Faction.Player) return; // allied troops and enemies killing each other
		if (!(owner in this.Kills)) this.Kills[owner] <- 0;
		this.Kills[owner]++;
		foreach (item in _victim.getItems().getAllItems())
			if (item != null) this.KilledItems[item.getInstanceID()] <- owner;
	}

	// ---- items to network data and back (same idea as brothers in roster.nut) ----

	function packItem( _item )
	{
		local sd = ::MSU.Class.SerializationData();
		_item.onSerialize(sd.getSerializationEmulator());
		local raw = [];
		foreach (d in sd.getDataArray())
			raw.push([d.getType(), d.getData()]);
		local entry = { hash = _item.ClassNameHash, name = _item.getName(), raw = raw, amount = null };
		// supplies keep their amount outside the save data
		if ("getAmount" in _item) entry.amount = _item.getAmount();
		return entry;
	}

	function unpackItem( _entry )
	{
		local item = ::new(::IO.scriptFilenameByHash(_entry.hash));
		local sd = ::MSU.Class.SerializationData();
		foreach (pair in _entry.raw)
		{
			local value = pair[1];
			if (pair[0] == ::MSU.Serialization.DataType.F32 && typeof value == "integer") value = value.tofloat();
			sd.write(value, pair[0]);
		}
		item.onDeserialize(sd.getDeserializationEmulator());
		if (_entry.amount != null && "setAmount" in item) item.setAmount(_entry.amount);
		return item;
	}

	// ---- host ----

	function onGatherLoot( _state )
	{
		local battle = ::BBCoop.Battle;
		if (battle.HostBattleID == null || battle.Reinforcements.len() == 0) return;

		local r = ::Tactical.Entities.getCombatResult();
		if (r != ::Const.Tactical.CombatResult.EnemyDestroyed && r != ::Const.Tactical.CombatResult.EnemyRetreated) return;

		// who gets a share: allies who are still connected
		local given = {};   // owner -> [items]
		foreach (rf in battle.Reinforcements)
			if (rf.side == "ally" && ::BBCoop.isOnline(rf.owner, 60.0) && !(rf.owner in given)) given[rf.owner] <- [];
		if (given.len() == 0) return;

		local container = _state.m.CombatResultLoot;
		local items = [];
		foreach (item in container.getItems())
			if (item != null) items.push(item);

		// 1. a joiner's own fallen brothers' gear goes home; 2. each enemy's gear goes to its killer
		local rest = [];
		foreach (item in items)
		{
			local id = item.getInstanceID();
			if ((id in this.OwnedItems) && (this.OwnedItems[id] in given)) given[this.OwnedItems[id]].push(item);
			else if (id in this.KilledItems)
			{
				if (this.KilledItems[id] in given) given[this.KilledItems[id]].push(item);
				// our kills (or a disconnected player's) stay in our loot screen
			}
			else rest.push(item);
		}

		// 3. loot no single enemy carried: shared by kills, each item to whoever is furthest below their share
		local weights = { [""] = ("" in this.Kills) ? this.Kills[""] : 0 };
		foreach (owner, list in given) weights[owner] <- (owner in this.Kills) ? this.Kills[owner] : 0;
		local weightSum = 0;
		foreach (owner, w in weights) weightSum += w;
		if (weightSum > 0)
		{
			rest.sort(@(a, b) b.getValue() <=> a.getValue());
			local total = 0;
			foreach (item in rest) total += item.getValue();
			local got = {};
			foreach (owner, w in weights) got[owner] <- 0;
			foreach (item in rest)
			{
				local best = null, bestDeficit = -1.0e9;
				foreach (owner, w in weights)
				{
					if (w == 0) continue;
					local deficit = total * w / weightSum.tofloat() - got[owner];
					if (deficit > bestDeficit) { best = owner; bestDeficit = deficit; }
				}
				got[best] += item.getValue();
				if (best != "") given[best].push(item);
			}
		}

		foreach (owner, list in given)
		{
			if (list.len() == 0) continue;
			local packed = [];
			foreach (item in list)
			{
				try
				{
					packed.push(this.packItem(item));
					container.remove(item);
				}
				catch (error)
				{
					::BBCoop.log("Could not pack " + item.getName() + " for " + owner + ": " + error);
				}
			}
			::BBCoop.Connection.sendMessage("battle_loot", { to = owner, battleID = battle.HostBattleID, items = packed });
			::BBCoop.log(format("Sent %i items to %s as their share of the loot", packed.len(), owner));
		}
		::BBCoop.notify("Your allies took the loot from the enemies they killed.");
	}

	// ---- joiner ----

	function onLoot( _from, _payload )
	{
		local stash = ::World.Assets.getStash();
		local added = 0, crowns = 0, lost = [];
		foreach (entry in _payload.items)
		{
			try
			{
				local item = this.unpackItem(entry);
				if (item.isConsumed())
				{
					if (item.getID() == "supplies.money") crowns += item.getAmount();
					item.consume();  // crowns, ammo, tools, medicine go straight to the company's stock
				}
				else if (stash.add(item) != null) added++;
				else lost.push(entry.name);
			}
			catch (error)
			{
				::BBCoop.log("Could not unpack " + entry.name + ": " + error);
				lost.push(entry.name);
			}
		}
		local text = format("Your share of the loot from %s's battle: %i items", _from, added);
		if (crowns > 0) text += format(" and %i crowns", crowns);
		if (lost.len() != 0) text += ". Your stash was full, lost: " + lost.reduce(@(a, b) a + ", " + b);
		::BBCoop.notify(text + ".");
	}
};

::BBCoop.MH.hook("scripts/states/tactical_state", function(q) {
	q.gatherLoot = @(__original) function()
	{
		__original();
		try
		{
			::BBCoop.Loot.onGatherLoot(this);
		}
		catch (error)
		{
			::BBCoop.log("Sharing the loot failed: " + error);
		}
	}
});

::BBCoop.MH.hook("scripts/entity/tactical/actor", function(q) {
	q.kill = @(__original) function( _killer = null, _skill = null, _fatalityType = ::Const.FatalityType.None, _silent = false )
	{
		try
		{
			if (this.isAlive()) ::BBCoop.Loot.onKill(this, _killer);
		}
		catch (error)
		{
			::BBCoop.log("Recording a kill failed: " + error);
		}
		return __original(_killer, _skill, _fatalityType, _silent);
	}
});
