// Trading: send items, crowns and brothers to another player whose company is near yours.
// Ctrl+T opens the trade window. What you offer leaves your company at once and waits; the
// other player accepts or declines. Nothing can be duplicated: the goods only land after the
// sender confirms the acceptance, and the sender only confirms while the offer still waits.
//   sender -> "trade_offer"   -> receiver   (prompt: accept / decline)
//   receiver -> "trade_answer" -> sender    (accepted true/false)
//   sender -> "trade_confirm" or "trade_cancel" -> receiver
//   receiver -> "trade_return" -> sender    (what didn't fit: full stash or roster)
// An offer waits up to 2 minutes; then, or when saving, it comes back to the sender.
// Checked against vanilla stash_container, item, asset_manager money and player roster.

::BBCoop.Trade <- {
	Range = 500.0,          // world units between the two companies
	WaitSeconds = 120.0,
	Pending = {},           // sender: offer id -> { to, items (live), crowns, bros (packed), time }
	Incoming = {},          // receiver: offer id -> { from, payload, accepted }
	NextID = 0,

	function keysOf( _table )
	{
		local ret = [];
		foreach (key, value in _table) ret.push(key);
		return ret;
	}

	function isOnWorldMap()
	{
		return ::BBCoop.Ghosts.isWorldActive() && !::BBCoop.Battle.isInTactical() && ::BBCoop.Battle.PendingRefs == null;
	}

	// Players whose company is close enough, nearest first
	function getPlayersInRange()
	{
		local ret = [];
		if (!this.isOnWorldMap()) return ret;
		local me = ::World.State.getPlayer();
		foreach (name, e in ::BBCoop.Ghosts.Entries)
		{
			if (e.Party == null || e.Party.isNull() || !::BBCoop.isOnline(name, 20.0)) continue;
			local d = me.getDistanceTo(e.Party.get());
			if (d <= this.Range) ret.push({ name = name, distance = d });
		}
		ret.sort(@(a, b) a.distance <=> b.distance);
		return ret.map(@(p) p.name);
	}

	// ---- trade window data ----

	function getWindowData()
	{
		if (!this.isOnWorldMap()) return { error = "Trading works on the world map." };
		local players = this.getPlayersInRange();
		if (players.len() == 0) return { error = "No other player's company is close enough. Move next to them (within " + this.Range.tointeger() + ")." };
		local items = [];
		foreach (item in ::World.Assets.getStash().getItems())
		{
			if (item == null) continue;
			local amount = "";
			try { amount = item.getAmountString(); } catch (error) {}
			items.push({ id = item.getInstanceID(), name = item.getName(), icon = item.getIcon(), value = item.getValue(), amount = amount });
		}
		local bros = [];
		foreach (bro in ::World.getPlayerRoster().getAll())
			bros.push({ id = bro.getID(), name = bro.getName(), level = bro.getLevel(), background = bro.getBackground().getName() });
		return { players = players, items = items, bros = bros, crowns = ::World.Assets.getMoney() };
	}

	// ---- sender ----

	// _data: { to, items: [instance ids], crowns, bros: [entity ids] }
	function send( _data )
	{
		if (!this.isOnWorldMap()) return "Trading works on the world map.";
		if (this.getPlayersInRange().find(_data.to) == null) return _data.to + "'s company is no longer close enough.";
		local crowns = _data.crowns == null ? 0 : _data.crowns.tointeger();
		if (crowns < 0 || crowns > ::World.Assets.getMoney()) return "You don't have that many crowns.";
		local roster = ::World.getPlayerRoster();
		if (_data.bros.len() >= roster.getSize()) return "You can't give away your whole company.";
		if (_data.items.len() == 0 && _data.bros.len() == 0 && crowns == 0) return "Pick something to send.";

		local stash = ::World.Assets.getStash();
		local offer = { to = _data.to, items = [], crowns = crowns, bros = [], time = ::Time.getRealTimeF() };
		local packedItems = [], packedBros = [];
		try
		{
			foreach (id in _data.items)
			{
				local found = stash.getItemByInstanceID(id);
				if (found == null) continue;
				packedItems.push(::BBCoop.Loot.packItem(found.item));
				offer.items.push(found.item);
			}
			foreach (id in _data.bros)
			{
				foreach (bro in roster.getAll())
				{
					if (bro.getID() != id) continue;
					local entry = { name = bro.getName(), level = bro.getLevel(), background = bro.getBackground().getName(), raw = ::BBCoop.Roster.serializeBrother(bro), look = ::BBCoop.Roster.captureAppearance(bro) };
					packedBros.push(entry);
					offer.bros.push({ entry = entry, bro = ::WeakTableRef(bro) });
				}
			}
		}
		catch (error)
		{
			::BBCoop.log("Could not pack the trade: " + error);
			return "Something in the trade couldn't be packed; nothing was sent.";
		}

		// everything packed: take it out of our company until the offer is answered
		foreach (item in offer.items) stash.remove(item.getInstanceID());
		foreach (b in offer.bros) if (!b.bro.isNull()) roster.remove(b.bro.get());
		foreach (b in offer.bros) b.bro = null;
		::World.Assets.addMoney(-crowns);

		local id = ::BBCoop.getSetting("PlayerName") + "_" + (this.NextID++) + "_" + ::Time.getRealTime();
		this.Pending[id] <- offer;
		::BBCoop.Connection.sendMessage("trade_offer", { to = _data.to, id = id, items = packedItems, crowns = crowns, bros = packedBros });
		::BBCoop.notify("Offer sent to " + _data.to + ". It waits up to 2 minutes for an answer.");
		return null;
	}

	function addBrother( _entry )
	{
		local roster = ::World.getPlayerRoster();
		if (roster.getSize() >= ::World.Assets.getBrothersMax()) return false;
		local bro = roster.create("scripts/entity/tactical/player");
		try
		{
			::BBCoop.Roster.deserializeInto(bro, _entry.raw);
			::BBCoop.Roster.applyAppearance(bro, _entry.look);
			bro.setName(_entry.name);
		}
		catch (error)
		{
			roster.remove(bro); // no half-made brother in the roster
			throw error;
		}
		// the sender's formation slot may be taken here: first free slot, reserves included
		local used = {};
		foreach (other in roster.getAll())
			if (other.getID() != bro.getID()) used[other.getPlaceInFormation()] <- true;
		for (local slot = 0; slot < 27; slot++)
		{
			if (slot in used) continue;
			bro.setPlaceInFormation(slot);
			break;
		}
		return true;
	}

	// The offer comes back: declined, timed out, cancelled or before saving
	function restore( _id, _reason )
	{
		if (!(_id in this.Pending)) return;
		local offer = this.Pending[_id];
		delete this.Pending[_id];
		local stash = ::World.Assets.getStash();
		local lost = [];
		foreach (item in offer.items)
			if (stash.add(item) == null) lost.push(item.getName());
		::World.Assets.addMoney(offer.crowns);
		foreach (b in offer.bros)
		{
			try { if (!this.addBrother(b.entry)) lost.push(b.entry.name); }
			catch (error) { ::BBCoop.log("Could not bring back " + b.entry.name + ": " + error); lost.push(b.entry.name); }
		}
		local text = _reason + " Your offer came back to you.";
		if (lost.len() != 0) text += " No room for: " + lost.reduce(@(a, b) a + ", " + b) + ".";
		::BBCoop.notify(text);
	}

	function onAnswer( _from, _payload )
	{
		if (!(_payload.id in this.Pending) || this.Pending[_payload.id].to != _from)
		{
			// too late: it already came back to us
			if (_payload.accepted) ::BBCoop.Connection.sendMessage("trade_cancel", { to = _from, id = _payload.id });
			return;
		}
		if (!_payload.accepted)
		{
			this.restore(_payload.id, _from + " declined.");
			return;
		}
		delete this.Pending[_payload.id]; // it's theirs now
		::BBCoop.Connection.sendMessage("trade_confirm", { to = _from, id = _payload.id });
		::BBCoop.notify(_from + " accepted your offer.");
	}

	// The receiver had no room for some of it
	function onReturn( _from, _payload )
	{
		local stash = ::World.Assets.getStash();
		local lost = [];
		foreach (entry in _payload.items)
		{
			try { if (stash.add(::BBCoop.Loot.unpackItem(entry)) == null) lost.push(entry.name); }
			catch (error) { lost.push(entry.name); }
		}
		foreach (entry in _payload.bros)
		{
			try { if (!this.addBrother(entry)) lost.push(entry.name); }
			catch (error) { lost.push(entry.name); }
		}
		local text = _from + " had no room for part of your offer, so it came back.";
		if (lost.len() != 0) text += " No room here either, lost: " + lost.reduce(@(a, b) a + ", " + b) + ".";
		::BBCoop.notify(text);
	}

	function restoreAll( _reason )
	{
		foreach (id in this.keysOf(this.Pending))
		{
			::BBCoop.Connection.sendMessage("trade_cancel", { to = this.Pending[id].to, id = id });
			this.restore(id, _reason);
		}
	}

	// ---- receiver ----

	function describe( _payload )
	{
		local parts = [];
		if (_payload.crowns > 0) parts.push("" + _payload.crowns + " crowns");
		foreach (entry in _payload.items) parts.push(entry.name);
		foreach (entry in _payload.bros) parts.push(entry.name + " (" + entry.background + ", level " + entry.level + ")");
		return parts.len() == 0 ? "nothing" : parts.reduce(@(a, b) a + ", " + b);
	}

	function onOffer( _from, _payload )
	{
		if (!this.isOnWorldMap())
		{
			::BBCoop.Connection.sendMessage("trade_answer", { to = _from, id = _payload.id, accepted = false });
			return;
		}
		this.Incoming[_payload.id] <- { from = _from, payload = _payload, accepted = false, time = ::Time.getRealTimeF() };
		::BBCoop.Connection.showPrompt({
			id = "trade:" + _payload.id,
			title = "Offer from " + _from,
			text = _from + " offers you: " + this.describe(_payload) + ".",
			options = [{ id = "accept", label = "Accept" }, { id = "decline", label = "Decline" }]
		});
	}

	function onPromptChoice( _promptID, _choice )
	{
		if (_promptID.find("trade:") != 0) return;
		local id = _promptID.slice(6);
		if (!(id in this.Incoming)) return;
		local offer = this.Incoming[id];
		if (_choice == "accept" && this.isOnWorldMap())
		{
			offer.accepted = true;
			::BBCoop.Connection.sendMessage("trade_answer", { to = offer.from, id = id, accepted = true });
			::BBCoop.notify("Accepted. Waiting for " + offer.from + "'s game to hand it over...");
		}
		else
		{
			delete this.Incoming[id];
			::BBCoop.Connection.sendMessage("trade_answer", { to = offer.from, id = id, accepted = false });
		}
	}

	function onConfirm( _from, _payload )
	{
		if (!(_payload.id in this.Incoming)) return;
		local offer = this.Incoming[_payload.id];
		delete this.Incoming[_payload.id];
		if (offer.from != _from || !offer.accepted) return;
		local p = offer.payload;
		local stash = ::World.Assets.getStash();
		local back = { items = [], bros = [] };
		::World.Assets.addMoney(p.crowns.tointeger());
		foreach (entry in p.items)
		{
			try
			{
				local item = ::BBCoop.Loot.unpackItem(entry);
				if (stash.add(item) == null) back.items.push(entry);
			}
			catch (error)
			{
				::BBCoop.log("Could not unpack " + entry.name + ": " + error);
				back.items.push(entry);
			}
		}
		foreach (entry in p.bros)
		{
			try { if (!this.addBrother(entry)) back.bros.push(entry); }
			catch (error) { ::BBCoop.log("Could not add " + entry.name + ": " + error); back.bros.push(entry); }
		}
		local text = "You received from " + _from + ": " + this.describe(p) + ".";
		if (back.items.len() != 0 || back.bros.len() != 0)
		{
			::BBCoop.Connection.sendMessage("trade_return", { to = _from, id = _payload.id, items = back.items, bros = back.bros });
			text += " Not enough room for some of it, so that went back.";
		}
		::BBCoop.notify(text);
	}

	function onCancel( _from, _payload )
	{
		if (!(_payload.id in this.Incoming)) return;
		delete this.Incoming[_payload.id];
		::BBCoop.Connection.closePrompt("trade:" + _payload.id);
		::BBCoop.notify(_from + "'s offer was withdrawn.");
	}

	// ---- every frame from world_state.onUpdate ----

	function update()
	{
		if (this.Pending.len() == 0 && this.Incoming.len() == 0) return;
		local now = ::Time.getRealTimeF();
		foreach (id in this.keysOf(this.Pending))
		{
			local offer = this.Pending[id];
			if (now - offer.time > this.WaitSeconds || (now - offer.time > 20.0 && !::BBCoop.isOnline(offer.to, 30.0)))
			{
				::BBCoop.Connection.sendMessage("trade_cancel", { to = offer.to, id = id });
				this.restore(id, "No answer from " + offer.to + ".");
			}
		}
		foreach (id in this.keysOf(this.Incoming))
		{
			if (now - this.Incoming[id].time > this.WaitSeconds + 30.0)
			{
				delete this.Incoming[id];
				::BBCoop.Connection.closePrompt("trade:" + id);
			}
		}
	}
};

::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.onUpdate = @(__original) function()
	{
		__original();
		try { ::BBCoop.Trade.update(); } catch (error) { ::BBCoop.log("Trade update failed: " + error); }
	}

	// a waiting offer must not vanish from a save: it comes back first
	q.onBeforeSerialize = @(__original) function( _out )
	{
		try { ::BBCoop.Trade.restoreAll("Saving the game."); } catch (error) { ::BBCoop.log("Bringing back offers failed: " + error); }
		__original(_out);
	}
});
