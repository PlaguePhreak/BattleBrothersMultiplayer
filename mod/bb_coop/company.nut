// Every player's company lives in the host's save (v0.35.0).
// Joiners keep no saves of their own: their game runs a temporary campaign on the host's map.
// So a joiner's game sends the host a full copy of its company ("company_save") every
// SendEvery seconds and whenever the host saves ("company_request"). The host keeps the latest
// copy of each player (by player name) and writes them all into its save through MSU's flag
// serialization. When a player joins the host's world again, the host sends their copy back
// ("company_restore", or none = true) and the joiner's new campaign is replaced by it.
//
// A copy holds: every brother (the same data a save file holds: stats, perks, traits,
// injuries, gear, XP, formation slot) plus their looks; the stash with all its items (food
// included); crowns, tools, medicine, ammo; renown and moral reputation; company name, banner
// and origin; followers (retinue); position on the map. Not carried: an accepted contract
// (it belongs to the joiner's copy of the world).

::BBCoop.Company <- {
	Version = 1,
	SendEvery = 90.0,       // seconds between copies a joiner sends
	WaitForHost = 45.0,     // a joiner who heard nothing back starts with the new company

	// ---- host ----
	Stored = {},            // player name -> company copy (network form: raw = [[type, value], ...])
	Announced = {},         // player names already told about in this game session

	// ---- joiner ----
	Restore = null,         // { host, company } waiting to be applied
	Ready = false,          // our company is the real one: copies may be sent to the host
	Blocked = false,        // restoring went wrong: never overwrite the host's good copy this session
	WaitStart = null,       // when the joined world started waiting for the host's answer
	LastSent = 0.0,

	function myName()
	{
		return ::BBCoop.getSetting("PlayerName");
	}

	// The host of the world we joined, or null when this world is our own
	function joinedHost()
	{
		if (!::MSU.Utils.hasState("world_state")) return null;
		return ::World.Flags.has("BBCoopHost") ? ::World.Flags.get("BBCoopHost") : null;
	}

	// ---- data <-> network form ----

	function serializeWith( _fn )
	{
		local sd = ::MSU.Class.SerializationData();
		_fn(sd.getSerializationEmulator());
		local raw = [];
		foreach (d in sd.getDataArray())
			raw.push([d.getType(), d.getData()]);
		return raw;
	}

	// raw pairs -> MSU SerializationData (compact: two flags per value in the save)
	function rawToData( _raw )
	{
		local sd = ::MSU.Class.SerializationData();
		foreach (pair in _raw)
		{
			local value = pair[1];
			if (pair[0] == ::MSU.Serialization.DataType.F32 && typeof value == "integer") value = value.tofloat();
			sd.write(value, pair[0]);
		}
		return sd;
	}

	function dataToRaw( _sd )
	{
		local raw = [];
		foreach (d in _sd.getDataArray())
			raw.push([d.getType(), d.getData()]);
		return raw;
	}

	// ---- packing our own company ----

	function pack()
	{
		local assets = ::World.Assets;
		local c = {
			v = this.Version,
			player = this.myName(),
			day = ::World.getTime().Days,
			name = assets.getName(),
			banner = assets.getBanner(),
			bannerID = assets.m.BannerID,
			look = assets.m.Look,
			origin = assets.getOrigin().getID(),
			money = assets.getMoney(),
			tools = assets.m.ArmorParts,
			meds = assets.m.Medicine,
			ammo = assets.m.Ammo,
			renown = assets.m.BusinessReputation,
			moral = assets.m.MoralReputation,
			x = null,
			y = null,
			bros = [],
			stash = null,
			retinue = null
		};
		local player = ::World.State.getPlayer();
		if (player != null)
		{
			local pos = player.getPos();
			c.x = pos.X;
			c.y = pos.Y;
		}
		foreach (bro in ::World.getPlayerRoster().getAll())
		{
			try
			{
				c.bros.push({ name = bro.getName(), raw = ::BBCoop.Roster.serializeBrother(bro), look = ::BBCoop.Roster.captureAppearance(bro) });
			}
			catch (error)
			{
				::BBCoop.log("Could not copy " + bro.getName() + " for the host's save: " + error);
			}
		}
		local stash = assets.getStash();
		c.stashSize <- stash.getCapacity();
		c.stash = this.serializeWith(function( _out ) { stash.onSerialize(_out); });
		try { c.retinue = this.serializeWith(function( _out ) { ::World.Retinue.onSerialize(_out); }); }
		catch (error) { ::BBCoop.log("Could not copy the followers: " + error); }
		return c;
	}

	// ---- joiner: sending copies ----

	function send( _why )
	{
		local host = this.joinedHost();
		if (host == null || !this.Ready) return false;
		if (::BBCoop.Connection.isHosting()) return false;
		if (::World.getPlayerRoster().getSize() == 0) return false; // game over screen: nothing to keep
		local c = null;
		try { c = this.pack(); }
		catch (error) { ::BBCoop.log("Packing the company for the host failed: " + error); return false; }
		c.to <- host;
		c.why <- _why;
		::BBCoop.Connection.sendMessage("company_save", c);
		this.LastSent = ::Time.getRealTimeF();
		::BBCoop.log("Sent " + host + " a copy of our company (" + c.bros.len() + " brothers, " + c.money + " crowns, " + _why + ")");
		return true;
	}

	function onRequest( _from, _payload )
	{
		if (this.joinedHost() != _from) return;
		this.send("host saved");
	}

	// called from world_state.onUpdate
	function update()
	{
		local host = this.joinedHost();
		if (host == null || this.Blocked) return;
		if (!this.Ready)
		{
			if (this.Restore != null && this.Restore.host == host)
			{
				this.apply();
				return;
			}
			local now = ::Time.getRealTimeF();
			if (this.WaitStart == null) this.WaitStart = now;
			if (now - this.WaitStart > this.WaitForHost)
			{
				this.Ready = true;
				::BBCoop.log(host + " sent no stored company; this company becomes the one kept in their save.");
			}
			return;
		}
		if (::Time.getRealTimeF() - this.LastSent >= this.SendEvery) this.send("regular copy");
	}

	// ---- joiner: getting our company back ----

	function onRestore( _from, _payload )
	{
		if (("none" in _payload) && _payload.none)
		{
			this.Restore = null;
			// nothing stored: the company we start with now is the one the host keeps
			if (this.joinedHost() == _from && !this.Ready)
			{
				this.Ready = true;
				this.LastSent = 0.0; // send the first copy right away
			}
			::BBCoop.log(_from + " has no company of ours stored.");
			return;
		}
		if (this.Ready && this.joinedHost() == _from) return; // already playing the restored company
		this.Restore = { host = _from, company = _payload.company };
		if (this.joinedHost() == null)
			::BBCoop.notify(_from + "'s world keeps your company (" + _payload.company.bros.len() + " brothers, day " + _payload.company.day + "). Pick any origin: your stored company replaces it once the campaign starts.");
	}

	function apply()
	{
		local r = this.Restore;
		this.Restore = null;
		local c = r.company;
		local problems = [];
		local assets = ::World.Assets;

		// origin, then followers: vanilla's retinue loading resets the company's bonuses and
		// runs the origin's onInit (asset_manager.resetToDefaults), as loading a save does
		try
		{
			if (assets.getOrigin().getID() != c.origin)
			{
				local origin = ::Const.ScenarioManager.getScenario(c.origin);
				if (origin != null) assets.m.Origin = origin;
				else problems.push("origin");
			}
		}
		catch (error) { problems.push("origin"); ::BBCoop.log("Could not restore the origin " + c.origin + ": " + error); }
		local followersBack = false;
		if (c.retinue != null)
		{
			try { ::World.Retinue.onDeserialize(::BBCoop.Roster.makeReader(c.retinue)); followersBack = true; }
			catch (error) { problems.push("followers"); ::BBCoop.log("Could not restore the followers: " + error); }
		}
		if (!followersBack)
		{
			try { assets.resetToDefaults(); } catch (error) { ::BBCoop.log("Could not reset the company bonuses: " + error); }
		}

		try { assets.m.Name = c.name; } catch (error) { problems.push("name"); }
		try
		{
			assets.m.Banner = c.banner;
			if (("bannerID" in c) && c.bannerID != null) assets.m.BannerID = c.bannerID.tointeger();
			local player = ::World.State.getPlayer();
			if (player != null)
			{
				player.getSprite("banner").setBrush(c.banner);
				if (player.hasSprite("zoom_banner")) player.getSprite("zoom_banner").setBrush(c.banner);
			}
		}
		catch (error) { problems.push("banner"); ::BBCoop.log("Could not restore the banner: " + error); }
		try { if (("look" in c) && c.look != null) assets.updateLook(c.look.tointeger()); } catch (error) { ::BBCoop.log("Could not restore the company's look: " + error); }
		try { assets.m.Money = c.money.tofloat(); } catch (error) { problems.push("crowns"); }
		try
		{
			assets.m.ArmorParts = c.tools.tofloat();
			assets.m.Medicine = c.meds.tofloat();
			assets.m.Ammo = c.ammo.tofloat();
		}
		catch (error) { problems.push("supplies"); }
		try
		{
			assets.m.BusinessReputation = c.renown.tointeger();
			assets.m.MoralReputation = c.moral.tofloat();
		}
		catch (error) { problems.push("renown"); }

		// brothers: the new campaign's starting ones leave, the stored ones come back
		local roster = ::World.getPlayerRoster();
		local back = 0;
		foreach (bro in clone roster.getAll()) roster.remove(bro);
		foreach (entry in c.bros)
		{
			try
			{
				local bro = roster.create("scripts/entity/tactical/player");
				::BBCoop.Roster.deserializeInto(bro, entry.raw);
				::BBCoop.Roster.applyAppearance(bro, entry.look);
				bro.setName(entry.name);
				back++;
			}
			catch (error)
			{
				problems.push(entry.name);
				::BBCoop.log("Could not restore " + entry.name + ": " + error);
			}
		}

		try
		{
			local stash = assets.getStash();
			if (("stashSize" in c) && c.stashSize != null) stash.resize(c.stashSize.tointeger());
			stash.onDeserialize(::BBCoop.Roster.makeReader(c.stash));
		}
		catch (error) { problems.push("stash"); ::BBCoop.log("Could not restore the stash: " + error); }

		if (c.x != null)
		{
			try
			{
				local pos = ::createVec(c.x, c.y);
				local tile = ::World.getTile(::World.worldToTile(pos));
				if (tile.Type != ::Const.World.TerrainType.Ocean)
				{
					local player = ::World.State.getPlayer();
					player.setPos(pos);
					::World.getCamera().setPos(pos);
					::World.uncoverFogOfWar(pos, 900.0);
				}
			}
			catch (error) { problems.push("position"); ::BBCoop.log("Could not restore the position: " + error); }
		}

		try { assets.updateFormation(); } catch (error) {}
		try { assets.updateFood(); } catch (error) {}
		try { assets.updateAverageMoodState(); } catch (error) {}
		try { ::World.State.updateTopbarAssets(); } catch (error) {}

		local text = "Your company is back from " + r.host + "'s save: " + back + " brothers, " + c.money.tointeger() + " crowns.";
		if (problems.len() != 0) text += " Could not restore: " + problems.reduce(@(a, b) a + ", " + b) + " (see log.html).";
		if (back < c.bros.len() || problems.find("stash") != null)
		{
			// don't let a broken copy replace the good one in the host's save
			this.Blocked = true;
			text += " " + r.host + "'s save keeps your old copy unchanged; rejoin to try again.";
		}
		else
		{
			this.Ready = true;
			this.LastSent = ::Time.getRealTimeF();
		}
		::BBCoop.notify(text);
	}

	// ---- host ----

	function onSave( _from, _payload )
	{
		if (!::MSU.Utils.hasState("world_state")) return;
		if (_from == "Bot") return;
		if (!("bros" in _payload) || _payload.bros.len() == 0) return;
		local c = clone _payload;
		if ("to" in c) delete c.to;
		if ("why" in c) delete c.why;
		this.Stored[_from] <- c;
		if (!(_from in this.Announced))
		{
			this.Announced[_from] <- true;
			::BBCoop.notify(_from + "'s company (" + c.bros.len() + " brothers) is now kept in your save.");
		}
		::BBCoop.log("Stored " + _from + "'s company: " + c.bros.len() + " brothers, " + c.money + " crowns, day " + c.day);
	}

	// A player asked to join our world: give them their company back
	function onSessionRequest( _from, _payload )
	{
		if (!::MSU.Utils.hasState("world_state")) return;
		if (_from == "Bot") return;
		if (_from in this.Stored)
		{
			::BBCoop.Connection.sendMessage("company_restore", { to = _from, company = this.Stored[_from] });
			::BBCoop.log("Sent " + _from + " their stored company.");
		}
		else
		{
			::BBCoop.Connection.sendMessage("company_restore", { to = _from, none = true });
		}
	}

	// Ask everyone for fresh copies; they arrive within a second or two, in time for the next save
	function requestCopies()
	{
		if (!::BBCoop.Connection.isHosting() || !::BBCoop.othersOnline()) return;
		::BBCoop.Connection.sendMessage("company_request", {});
	}

	// Into the save: one table of all companies, through MSU flags (cleared again after saving)
	function writeToSave()
	{
		if (this.Stored.len() == 0) return;
		local all = {};
		foreach (name, c in this.Stored)
		{
			local s = clone c;
			s.bros = c.bros.map(function( b ) { return { name = b.name, raw = ::BBCoop.Company.rawToData(b.raw), look = b.look }; });
			s.stash = this.rawToData(c.stash);
			s.retinue = c.retinue == null ? null : this.rawToData(c.retinue);
			all[name] <- s;
		}
		::BBCoop.Mod.Serialization.flagSerialize("Companies", all);
		::BBCoop.log("Saved " + all.len() + " other player companies into this save.");
	}

	function readFromSave()
	{
		this.Stored = {};
		this.Announced = {};
		local all = ::BBCoop.Mod.Serialization.flagDeserialize("Companies", null);
		if (all == null) return;
		foreach (name, s in all)
		{
			try
			{
				local c = clone s;
				c.bros = s.bros.map(function( b ) { return { name = b.name, raw = ::BBCoop.Company.dataToRaw(b.raw), look = b.look }; });
				c.stash = this.dataToRaw(s.stash);
				c.retinue = s.retinue == null ? null : this.dataToRaw(s.retinue);
				this.Stored[name] <- c;
			}
			catch (error)
			{
				::BBCoop.log("Could not read " + name + "'s stored company: " + error);
			}
		}
		if (this.Stored.len() != 0)
		{
			local names = "";
			foreach (name, c in this.Stored) names += (names == "" ? "" : ", ") + name;
			::BBCoop.log("This save keeps the companies of: " + names);
		}
	}

	function reset()
	{
		this.Stored = {};
		this.Announced = {};
		this.Ready = false;
		this.Blocked = false;
		this.WaitStart = null;
		this.LastSent = 0.0;
	}
};

::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.onUpdate = @(__original) function()
	{
		__original();
		try { ::BBCoop.Company.update(); } catch (error) { ::BBCoop.log("Company copy update failed: " + error); }
	}

	q.saveCampaign = @(__original) function( _campaignFileName, _campaignLabel = null )
	{
		__original(_campaignFileName, _campaignLabel);
		try { ::BBCoop.Company.requestCopies(); } catch (error) {}
	}

	q.onSerialize = @(__original) function( _out )
	{
		try { ::BBCoop.Company.writeToSave(); }
		catch (error) { ::BBCoop.log("Writing the other players' companies into the save failed: " + error); }
		__original(_out);
	}

	q.onDeserialize = @(__original) function( _in )
	{
		__original(_in);
		try { ::BBCoop.Company.readFromSave(); }
		catch (error) { ::BBCoop.log("Reading the other players' companies from the save failed: " + error); }
	}

	q.loadCampaign = @(__original) function( _campaignFileName )
	{
		::BBCoop.Company.reset();
		__original(_campaignFileName);
		// a joined world we saved ourselves: our company is the real one
		if (::BBCoop.Company.joinedHost() != null) ::BBCoop.Company.Ready = true;
	}

	q.startNewCampaign = @(__original) function()
	{
		local restore = ::BBCoop.Company.Restore;
		::BBCoop.Company.reset();
		::BBCoop.Company.Restore = restore; // applied on the first update, once the company is placed
		__original();
	}
});
