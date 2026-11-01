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
	Blocked = false,        // restoring went wrong, or the host keeps a newer copy: never overwrite it this session
	WaitStart = null,       // when the joined world started waiting for the host's answer
	LastSent = 0.0,
	WipeAsked = null,       // when the "start over or leave" choice was last shown (v0.43.0)
	Leaving = false,        // the player chose to leave after a wipe-out: vanilla's defeat screen is showing
	KickedBy = null,        // the host reset our company: back to the main menu on the next world frame

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
			rev = this.nextRevision(),
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

	// Every copy carries a revision that only goes up in this world (kept in a world flag, so a save
	// remembers it). The host refuses a copy older than the one it stores: loading an old local save
	// of a joined world must not roll the company back in the host's save (v0.42.0).
	function getRevision()
	{
		return ::World.Flags.has("BBCoopCompanyRev") ? ::World.Flags.get("BBCoopCompanyRev").tointeger() : 0;
	}

	function nextRevision()
	{
		local rev = this.getRevision() + 1;
		::World.Flags.set("BBCoopCompanyRev", rev);
		return rev;
	}

	// The host keeps a newer copy than the one we just sent: this game's company is behind it
	function onRefused( _from, _payload )
	{
		if (this.joinedHost() != _from || this.Blocked) return;
		this.Blocked = true;
		::BBCoop.notify(format("%s's save keeps a newer copy of your company (day %s) than this game has. This game's company won't be stored; rejoin through Multiplayer > Join a world with a new campaign to get the newer one back.", _from, ("day" in _payload) ? "" + _payload.day : "?"));
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
		if (host == null) return;
		if (this.KickedBy != null) { this.finishKick(); return; }
		this.checkWipedOut();
		if (this.Blocked) return;
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
				::BBCoop.notify(host + "'s save has no company of yours (or the answer never arrived), so you start with this new company. It is kept in their save from now on.");
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
			if (this.joinedHost() == _from) ::BBCoop.notify(_from + "'s save has no company of yours yet: this new company is the one kept there from now on.");
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
			local bro = null;
			try
			{
				bro = roster.create("scripts/entity/tactical/player");
				::BBCoop.Roster.deserializeInto(bro, entry.raw);
				::BBCoop.Roster.applyAppearance(bro, entry.look);
				bro.setName(entry.name);
				back++;
			}
			catch (error)
			{
				problems.push(entry.name);
				::BBCoop.log("Could not restore " + entry.name + ": " + error);
				if (bro != null) try { roster.remove(bro); } catch (e2) {}
			}
		}
		try { ::World.Flags.set("BBCoopCompanyRev", ("rev" in c) && c.rev != null ? c.rev.tointeger() : 0); } catch (error) {}

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

	// ---- joiner: every brother dead (v0.43.0) ----
	// Vanilla shows the defeat screen when the roster is empty after a fight. In a joined world the
	// player may instead start over with a new company (the origin's starting brothers, crowns and
	// supplies, an empty stash) or leave the session, which drops their company from the host's save.

	function checkWipedOut()
	{
		if (this.Leaving || !this.Ready) return;
		if (::BBCoop.Battle.isInTactical() || ::BBCoop.Battle.PendingRefs != null) return;
		if (("IsGameOver" in ::World.State.m) && ::World.State.m.IsGameOver) return;
		if (::World.getPlayerRoster().getSize() != 0) { this.WipeAsked = null; return; }
		try { if (!::World.State.isPaused()) ::World.State.setPause(true); } catch (error) {}
		if (this.WipeAsked != null && ::Time.getRealTimeF() - this.WipeAsked < 20.0) return; // asked again if the window was closed
		this.onWipedOut("Every brother of yours is dead.");
	}

	function onWipedOut( _why )
	{
		local host = this.joinedHost();
		if (host == null || this.Leaving) return;
		this.WipeAsked = ::Time.getRealTimeF();
		::BBCoop.log("Company wiped out: " + _why);
		::BBCoop.Connection.showPrompt({
			id = "wipe",
			title = "Your company is gone",
			text = _why + " Start a new company here in " + host + "'s world (your origin's starting brothers, starting crowns and supplies, an empty stash), or leave the session. Leaving drops your company from " + host + "'s save; you start fresh if you join again.",
			options = [
				{ id = "new", label = "Start a new company" },
				{ id = "leave", label = "Leave the session" }
			]
		});
	}

	function onPromptChoice( _id, _choice )
	{
		if (_id != "wipe") return;
		if (_choice == "new") this.startNewCompany();
		else if (_choice == "leave") this.leaveAfterWipe();
	}

	// vanilla world_state.showGameFinishScreen(false) in a joined world: offer the choice instead
	function interceptDefeat()
	{
		if (this.Leaving || this.joinedHost() == null) return false;
		if (this.KickedBy != null) return false;
		try { ::World.State.setWorldmapMusic(true); } catch (error) {}
		try { ::World.State.setPause(true); } catch (error) {}
		this.onWipedOut("Every brother of yours is dead.");
		return true;
	}

	// The origin's starting company again, as a new campaign gets it (asset_manager.setCampaignSettings
	// for crowns and supplies by economic difficulty, then the origin's onSpawnAssets)
	function startNewCompany()
	{
		local assets = ::World.Assets;
		local roster = ::World.getPlayerRoster();
		foreach (bro in clone roster.getAll()) roster.remove(bro);
		try { assets.m.Stash.clear(); } catch (error) { ::BBCoop.log("Could not empty the stash: " + error); }
		local diff = 1;
		try { diff = assets.getEconomicDifficulty(); } catch (error) {}
		if (diff < 0 || diff > 2) diff = 1;
		local starts = [
			{ money = 2500, ammo = 80, tools = 40, meds = 30 },
			{ money = 2000, ammo = 40, tools = 20, meds = 20 },
			{ money = 1500, ammo = 20, tools = 10, meds = 10 }
		];
		local start = starts[diff];
		assets.m.Money = start.money;
		assets.m.Ammo = start.ammo;
		assets.m.ArmorParts = start.tools;
		assets.m.Medicine = start.meds;
		assets.m.BusinessReputation = 0;
		try { assets.resetToDefaults(); } catch (error) { ::BBCoop.log("Could not reset the company bonuses: " + error); }
		local origin = assets.getOrigin();
		try { origin.onSpawnAssets(); }
		catch (error) { ::BBCoop.log("The origin " + origin.getID() + " could not make a new company: " + error); }
		if (roster.getSize() == 0)
		{
			// an origin that needs more than a running world: the plain company instead
			try { ::Const.ScenarioManager.getScenario("scenario.early_access").onSpawnAssets(); }
			catch (error) { ::BBCoop.log("Could not make a plain new company either: " + error); }
		}
		if (roster.getSize() == 0)
		{
			::BBCoop.notify("Could not make a new company (see log.html).");
			this.WipeAsked = null;
			return;
		}
		try { assets.updateFormation(); } catch (error) {}
		try { assets.updateFood(); } catch (error) {}
		try { assets.updateAverageMoodState(); } catch (error) {}
		try { ::World.State.updateTopbarAssets(); } catch (error) {}
		this.WipeAsked = null;
		this.Ready = true;
		this.Blocked = false;
		this.LastSent = 0.0;
		::BBCoop.notify(format("A new company: %i brothers and %i crowns. It replaces the old one in %s's save.", roster.getSize(), assets.getMoney(), this.joinedHost()));
		this.send("new company");
	}

	// Vanilla's defeat screen; its button leads to the main menu. The host forgets our company.
	function leaveAfterWipe()
	{
		local host = this.joinedHost();
		this.Leaving = true;
		this.Blocked = true;
		this.WipeAsked = null;
		if (host != null) ::BBCoop.Connection.sendMessage("company_drop", { to = host });
		::BBCoop.log("Leaving " + host + "'s world after the wipe-out; our stored company is dropped.");
		try { ::World.State.showGameFinishScreen(false); }
		catch (error)
		{
			::BBCoop.log("Could not show the defeat screen: " + error);
			try { ::World.State.exitGame(); } catch (e2) {}
		}
	}

	// ---- the host reset our company (v0.43.0) ----

	function onReset( _from, _payload )
	{
		if (this.joinedHost() == null)
		{
			// at the main menu or setting up the campaign: nothing of ours is restored any more
			if (this.Restore != null && this.Restore.host == _from) this.Restore = null;
			::BBCoop.notify(_from + " reset your company: you start with a new one in their world.");
			return;
		}
		if (this.joinedHost() != _from || this.KickedBy != null) return;
		this.Blocked = true;
		this.KickedBy = _from;
		::BBCoop.notify(_from + " reset your company and removed you from their world. Back to the main menu; join again through Multiplayer > Join a world to make a new company.");
	}

	function finishKick()
	{
		if (::BBCoop.Battle.isInTactical() || ::BBCoop.Battle.PendingRefs != null) return;
		local who = this.KickedBy;
		this.KickedBy = null;
		::BBCoop.log("Leaving " + who + "'s world: they reset our company.");
		try { ::BBCoop.Connection.stopSession(); } catch (error) {}
		try { ::World.State.exitGame(); }
		catch (error) { ::BBCoop.log("Could not leave the world: " + error); }
	}

	// Origin intro events tell the story of a company that was replaced by the stored one (and
	// the default one reads the first three brothers, which a restored company need not have)
	function skipsEvent( _id )
	{
		if (this.joinedHost() == null) return false;
		return typeof _id == "string" && _id.find("scenario_intro") != null;
	}

	// ---- host ----

	// Mod Options (hosting): drop a player's company and send them back to the main menu
	function resetPlayer( _name )
	{
		local name = this.trim(_name);
		if (name == "") return;
		if (!::BBCoop.Connection.isHosting()) { ::BBCoop.notify("Only the host can reset a player's company."); return; }
		if (!::MSU.Utils.hasState("world_state")) { ::BBCoop.notify("Load your co-op world first, then reset " + name + "'s company."); return; }
		if (name == this.myName()) { ::BBCoop.notify("That is your own company."); return; }
		local had = (name in this.Stored);
		if (had)
		{
			delete this.Stored[name];
			if (name in this.Announced) delete this.Announced[name];
		}
		::BBCoop.Connection.sendMessage("company_reset", { to = name });
		::BBCoop.notify(format("%s's company %s. They go back to the main menu and start a new company when they join again.", name, had ? "was removed from your save" : "was not stored in this save"));
	}

	function trim( _text )
	{
		local text = "" + _text;
		local a = 0, b = text.len();
		while (a < b && (text[a] == ' ' || text[a] == '\t')) a++;
		while (b > a && (text[b - 1] == ' ' || text[b - 1] == '\t')) b--;
		return text.slice(a, b);
	}

	// A wiped-out player left: their next join starts a new company
	function onDrop( _from, _payload )
	{
		if (!::MSU.Utils.hasState("world_state")) return;
		if (!(_from in this.Stored)) return;
		delete this.Stored[_from];
		if (_from in this.Announced) delete this.Announced[_from];
		::BBCoop.notify(_from + "'s company was wiped out and they left; they start a new company if they join again.");
	}

	function onSave( _from, _payload )
	{
		if (!::MSU.Utils.hasState("world_state")) return;
		if (_from == "Bot") return;
		if (!("bros" in _payload) || _payload.bros.len() == 0) return;
		local rev = ("rev" in _payload) && _payload.rev != null ? _payload.rev.tointeger() : 0;
		if (_from in this.Stored)
		{
			local have = this.Stored[_from];
			local haveRev = ("rev" in have) && have.rev != null ? have.rev.tointeger() : 0;
			if (rev < haveRev || (rev == haveRev && rev != 0))
			{
				::BBCoop.log(format("Refused %s's company copy: revision %i is older than the stored %i (day %s vs %s)", _from, rev, haveRev, "" + _payload.day, "" + have.day));
				::BBCoop.Connection.sendMessage("company_refused", { to = _from, rev = haveRev, day = have.day });
				return;
			}
		}
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
		this.WipeAsked = null;
		this.Leaving = false;
		this.KickedBy = null;
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

// Every brother dead in a joined world: the choice above instead of vanilla's defeat screen
::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.showGameFinishScreen = @(__original) function( _gameWon )
	{
		if (!_gameWon)
		{
			try { if (::BBCoop.Company.interceptDefeat()) return; }
			catch (error) { ::BBCoop.log("Wipe-out choice failed: " + error); }
		}
		__original(_gameWon);
	}

	// An event whose screen can't be built (the default origin's intro reads three brothers; a
	// restored company had two) stayed queued and vanilla tried to show it every frame, playing
	// the event sound each time. Such an event is dropped instead (v0.43.0).
	q.showEventScreen = @(__original) function( _event, _isContract = false, _playSound = true )
	{
		try { return __original(_event, _isContract, _playSound); }
		catch (error)
		{
			local id = "?";
			try { id = _event.getID(); } catch (e2) {}
			::BBCoop.log("Showing the event " + id + " failed: " + error + ". The event is dropped.");
			if (!_isContract)
			{
				try
				{
					if (::World.Events.m.ActiveEvent != null) ::World.Events.m.ActiveEvent.clear();
					::World.Events.m.ActiveEvent = null;
					::World.Events.m.IsEventShown = false;
				}
				catch (e3) {}
			}
			return false;
		}
	}
});

::BBCoop.MH.hook("scripts/events/event_manager", function(q) {
	q.fire = @(__original) function( _id, _update = true )
	{
		try
		{
			if (::BBCoop.Company.skipsEvent(_id))
			{
				::BBCoop.log("Skipped the origin's intro event " + _id + ": this company plays in a joined world.");
				return false;
			}
		}
		catch (error) {}
		return __original(_id, _update);
	}
});
