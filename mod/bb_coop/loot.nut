// Loot for players who joined a battle on the host's side.
// When the host wins, the loot is split before the loot screen opens: gear that belonged to a
// joiner's own (fallen) brothers goes back to them, and the rest is shared by how many brothers
// each player brought. Each joiner's share is sent as "battle_loot" and lands in their stash
// (crowns, ammo and other supplies are added straight to their stock).
// Checked against vanilla tactical_state.gatherLoot, stash_container and item/money_item.

::BBCoop.Loot <- {
	OwnedItems = {},     // item instance id -> owner, for gear the joiners brought
	HostFighters = 0,    // how many of our own brothers started the battle

	function reset()
	{
		this.OwnedItems.clear();
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

		// who shares: allies who are still connected, weighted by the brothers they brought
		local weights = { [""] = ::Math.max(1, this.HostFighters) };  // "" is us
		foreach (rf in battle.Reinforcements)
		{
			if (rf.side != "ally" || !::BBCoop.isOnline(rf.owner, 60.0)) continue;
			if (!(rf.owner in weights)) weights[rf.owner] <- 0;
			weights[rf.owner]++;
		}
		if (weights.len() == 1) return;

		local container = _state.m.CombatResultLoot;
		local items = [];
		foreach (item in container.getItems())
			if (item != null) items.push(item);

		local given = {};   // owner -> [items]
		foreach (owner, w in weights)
			if (owner != "") given[owner] <- [];

		// 1. their own fallen brothers' gear goes home
		local rest = [];
		foreach (item in items)
		{
			local id = item.getInstanceID();
			if ((id in this.OwnedItems) && (this.OwnedItems[id] in given)) given[this.OwnedItems[id]].push(item);
			else rest.push(item);
		}

		// 2. the rest by value: each item goes to whoever is furthest below their fair share
		rest.sort(@(a, b) b.getValue() <=> a.getValue());
		local total = 0, weightSum = 0;
		foreach (item in rest) total += item.getValue();
		foreach (owner, w in weights) weightSum += w;
		local got = {};
		foreach (owner, w in weights) got[owner] <- 0;
		foreach (item in rest)
		{
			local best = null, bestDeficit = -1.0e9;
			foreach (owner, w in weights)
			{
				local deficit = total * w / weightSum.tofloat() - got[owner];
				if (deficit > bestDeficit) { best = owner; bestDeficit = deficit; }
			}
			got[best] += item.getValue();
			if (best != "") given[best].push(item);
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
		::BBCoop.notify("The loot was shared with your allies.");
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
