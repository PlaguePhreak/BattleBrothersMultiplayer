// Shared contracts: take a contract and your online clanmates are asked to help with it.
// Everyone who said yes gets an even share of every payment made after that (the advance
// paid when the contract was signed stays with whoever signed it).
//   owner  -> "contract_share" -> clanmate   (prompt: help / no thanks)
//   helper -> "contract_join"  -> owner      (join true/false)
//   helper -> "contract_leave" -> owner      (helping someone else now)
//   owner  -> "contract_pay"   -> helper     (their share of a payment)
//   owner  -> "contract_done"  -> helper     (finished or broken)
// Payments are found by watching asset_manager.addMoney while a contract screen option runs
// (contract.processInput), which is where every vanilla contract pays out.
// Checked against vanilla contract.nut, contract_manager.nut and asset_manager.nut.

::BBCoop.Contract <- {
	Clans = {},          // player -> clan, from their position updates
	Incoming = {},       // prompt number -> { from, payload }
	NextPrompt = 0,
	Capture = null,      // crowns paid while a shared contract's option runs, or null
	PendingDone = [],    // contract_done messages held until the payment went out

	function keysOf( _table )
	{
		local ret = [];
		foreach (key, value in _table) ret.push(key);
		return ret;
	}

	// Contract text carries [color=...] markup; the prompt shows plain text
	function plain( _text )
	{
		local ret = "";
		local depth = 0;
		foreach (c in _text)
		{
			if (c == '[') depth++;
			else if (c == ']') { if (depth > 0) depth--; }
			else if (depth == 0) ret += c.tochar();
		}
		return ret;
	}

	function onPosition( _from, _payload )
	{
		if ("clan" in _payload) this.Clans[_from] <- _payload.clan;
	}

	function getOnlineClanmates()
	{
		local ret = [];
		local mine = ::BBCoop.getClan();
		if (mine == "") return ret;
		foreach (name, clan in this.Clans)
		{
			if (clan == mine && name != ::BBCoop.getSetting("PlayerName") && ::BBCoop.isOnline(name, 20.0)) ret.push(name);
		}
		return ret;
	}

	// ---- owner ----

	function getActive()
	{
		try { return ::World.Contracts.getActiveContract(); } catch (error) { return null; }
	}

	function getHelpers( _contract )
	{
		if (!_contract.m.Flags.has("BBCoopHelpers")) return [];
		local text = _contract.m.Flags.get("BBCoopHelpers");
		if (typeof text != "string" || text == "") return [];
		return split(text, "|");
	}

	function setHelpers( _contract, _list )
	{
		_contract.m.Flags.set("BBCoopHelpers", _list.len() == 0 ? "" : _list.reduce(@(a, b) a + "|" + b));
	}

	function getContractID( _contract )
	{
		return "" + _contract.getID();
	}

	function describeContract( _contract )
	{
		local ret = { id = this.getContractID(_contract), title = this.plain(_contract.getTitle()), employer = "", objectives = [], dest = "" };
		try { if (_contract.getHome() != null) ret.employer = _contract.getHome().getName(); } catch (error) {}
		try
		{
			foreach (section in _contract.getUIBulletpoints(true, false))
				foreach (item in section.items) ret.objectives.push(this.plain(item.text));
		}
		catch (error) {}
		try
		{
			if (("Destination" in _contract.m) && _contract.m.Destination != null && !_contract.m.Destination.isNull())
				ret.dest = _contract.m.Destination.getName();
		}
		catch (error) {}
		return ret;
	}

	// Ask online clanmates who aren't helping yet. Returns how many were asked.
	function share( _quiet = false )
	{
		local contract = this.getActive();
		if (contract == null)
		{
			if (!_quiet) this.showHelping();
			return 0;
		}
		local helpers = this.getHelpers(contract);
		local asked = 0;
		local info = this.describeContract(contract);
		foreach (name in this.getOnlineClanmates())
		{
			if (helpers.find(name) != null) continue;
			local payload = clone info;
			payload.to <- name;
			::BBCoop.Connection.sendMessage("contract_share", payload);
			asked++;
		}
		if (asked > 0) ::BBCoop.notify("Asked " + asked + " clanmate" + (asked == 1 ? "" : "s") + " to help with " + info.title + ".");
		else if (!_quiet)
		{
			if (::BBCoop.getClan() == "") ::BBCoop.notify("Join a clan first (Ctrl+K): contracts are shared with clanmates.");
			else if (helpers.len() != 0) ::BBCoop.notify("Helping you with " + info.title + ": " + helpers.reduce(@(a, b) a + ", " + b) + ".");
			else ::BBCoop.notify("No clanmate is online to share " + info.title + " with.");
		}
		return asked;
	}

	function onJoin( _from, _payload )
	{
		local contract = this.getActive();
		if (contract == null || this.getContractID(contract) != _payload.id)
		{
			if (_payload.join) ::BBCoop.Connection.sendMessage("contract_done", { to = _from, id = _payload.id, title = "", cancelled = true, gone = true });
			return;
		}
		local helpers = this.getHelpers(contract);
		local title = this.plain(contract.getTitle());
		if (!_payload.join)
		{
			::BBCoop.notify(_from + " won't help with " + title + ".");
			return;
		}
		if (helpers.find(_from) == null) helpers.push(_from);
		this.setHelpers(contract, helpers);
		::BBCoop.notify(_from + " is helping with " + title + ". Payments are now split " + (helpers.len() + 1) + " ways.");
	}

	function onLeave( _from, _payload )
	{
		local contract = this.getActive();
		if (contract == null || this.getContractID(contract) != _payload.id) return;
		local helpers = this.getHelpers(contract);
		local i = helpers.find(_from);
		if (i == null) return;
		helpers.remove(i);
		this.setHelpers(contract, helpers);
		::BBCoop.notify(_from + " stopped helping with " + this.plain(contract.getTitle()) + ".");
	}

	// After a contract option ran: hand each online helper their share of what it paid
	function payOut( _contract, _crowns )
	{
		if (_crowns <= 0) return;
		local helpers = this.getHelpers(_contract);
		local online = [], offline = [];
		foreach (name in helpers)
		{
			if (::BBCoop.isOnline(name, 60.0)) online.push(name);
			else offline.push(name);
		}
		local title = this.plain(_contract.getTitle());
		if (online.len() != 0)
		{
			local share = (_crowns / (online.len() + 1)).tointeger();
			if (share > 0)
			{
				foreach (name in online)
					::BBCoop.Connection.sendMessage("contract_pay", { to = name, id = this.getContractID(_contract), title = title, crowns = share, total = _crowns });
				::World.Assets.addMoney(-share * online.len());
				::World.State.updateTopbarAssets();
				::BBCoop.notify("Paid " + share + " crowns each to " + online.reduce(@(a, b) a + ", " + b) + " from the " + _crowns + " for " + title + ".");
			}
		}
		if (offline.len() != 0)
			::BBCoop.notify(offline.reduce(@(a, b) a + ", " + b) + " " + (offline.len() == 1 ? "is" : "are") + " offline, so their share stays with you.");
	}

	function flushDone()
	{
		foreach (msg in this.PendingDone) ::BBCoop.Connection.sendMessage("contract_done", msg);
		this.PendingDone = [];
	}

	function onFinished( _contract, _cancelled )
	{
		local title = this.plain(_contract.getTitle());
		foreach (name in this.getHelpers(_contract))
			this.PendingDone.push({ to = name, id = this.getContractID(_contract), title = title, cancelled = _cancelled });
		if (this.Capture == null) this.flushDone();
	}

	// ---- helper ----

	function getHelping()
	{
		if (!::World.Flags.has("BBCoopHelping")) return null;
		local owner = ::World.Flags.get("BBCoopHelping");
		if (typeof owner != "string" || owner == "") return null;
		return { owner = owner, id = ::World.Flags.get("BBCoopHelpingID"), title = ::World.Flags.get("BBCoopHelpingTitle") };
	}

	function setHelping( _owner, _id, _title )
	{
		::World.Flags.set("BBCoopHelping", _owner);
		::World.Flags.set("BBCoopHelpingID", _id);
		::World.Flags.set("BBCoopHelpingTitle", _title);
	}

	function showHelping()
	{
		local h = this.getHelping();
		if (h == null) ::BBCoop.notify("You have no contract to share and aren't helping anyone.");
		else ::BBCoop.notify("You are helping " + h.owner + " with " + h.title + ".");
	}

	function onShare( _from, _payload )
	{
		if (!::BBCoop.Ghosts.isWorldActive())
		{
			::BBCoop.Connection.sendMessage("contract_join", { to = _from, id = _payload.id, join = false });
			return;
		}
		local n = "" + this.NextPrompt++;
		this.Incoming[n] <- { from = _from, payload = _payload };
		local text = _from + " took the contract \"" + _payload.title + "\"";
		if (_payload.employer != "") text += " for " + _payload.employer;
		text += ".";
		if (_payload.objectives.len() != 0) text += " " + _payload.objectives.reduce(@(a, b) a + " " + b);
		if (_payload.dest != "") text += " Target: " + _payload.dest + ".";
		text += " Help, and every payment from now on is split between everyone helping.";
		local h = this.getHelping();
		if (h != null) text += " (You stop helping " + h.owner + ".)";
		::BBCoop.Connection.showPrompt({
			id = "contract:" + n,
			title = "Shared contract",
			text = text,
			options = [{ id = "help", label = "Help" }, { id = "decline", label = "No thanks" }]
		});
	}

	function onPromptChoice( _promptID, _choice )
	{
		if (_promptID.find("contract:") != 0) return;
		local n = _promptID.slice(9);
		if (!(n in this.Incoming)) return;
		local offer = this.Incoming[n];
		delete this.Incoming[n];
		local join = _choice == "help";
		if (join)
		{
			local h = this.getHelping();
			if (h != null && (h.owner != offer.from || h.id != offer.payload.id))
				::BBCoop.Connection.sendMessage("contract_leave", { to = h.owner, id = h.id });
			this.setHelping(offer.from, offer.payload.id, offer.payload.title);
			::BBCoop.notify("You are helping " + offer.from + " with " + offer.payload.title + ". Fight their contract battles with them (Ctrl+B joins a nearby battle).");
		}
		::BBCoop.Connection.sendMessage("contract_join", { to = offer.from, id = offer.payload.id, join = join });
	}

	function onPay( _from, _payload )
	{
		local crowns = _payload.crowns.tointeger();
		if (crowns <= 0) return;
		::World.Assets.addMoney(crowns);
		try { ::World.State.updateTopbarAssets(); } catch (error) {}
		::BBCoop.notify(_from + " paid you " + crowns + " crowns, your share of " + _payload.total + " for " + _payload.title + ".");
	}

	function onDone( _from, _payload )
	{
		local h = this.getHelping();
		if (h == null || h.owner != _from || h.id != _payload.id) return;
		this.setHelping("", "", "");
		if ("gone" in _payload) ::BBCoop.notify(_from + " no longer has that contract.");
		else if (_payload.cancelled) ::BBCoop.notify(_from + " broke the contract " + _payload.title + ".");
		else ::BBCoop.notify(_from + " finished the contract " + _payload.title + ". Thanks for the help!");
	}
};

// Take a contract: ask clanmates to help
::BBCoop.MH.hook("scripts/contracts/contract_manager", function(q) {
	q.setActiveContract = @(__original) function( _contract, _alreadyStarted = false )
	{
		local wasActive = this.getActiveContract() != null;
		__original(_contract, _alreadyStarted);
		if (wasActive || _alreadyStarted || this.getActiveContract() != _contract) return;
		try { ::BBCoop.Contract.share(true); }
		catch (error) { ::BBCoop.log("Could not share the contract: " + error); }
	}

	q.finishActiveContract = @(__original) function( _isCancelled = false )
	{
		local contract = this.getActiveContract();
		__original(_isCancelled);
		if (contract == null) return;
		try { ::BBCoop.Contract.onFinished(contract, _isCancelled); }
		catch (error) { ::BBCoop.log("Could not tell helpers the contract ended: " + error); }
	}
});

// Contract screen options are where payments happen
::BBCoop.MH.hook("scripts/contracts/contract", function(q) {
	q.processInput = @(__original) function( _option )
	{
		if (::BBCoop.Contract.Capture != null || ::BBCoop.Contract.getHelpers(this).len() == 0)
			return __original(_option);
		::BBCoop.Contract.Capture = 0;
		local ret;
		try
		{
			ret = __original(_option);
		}
		catch (error)
		{
			::BBCoop.Contract.Capture = null;
			::BBCoop.Contract.flushDone();
			throw error;
		}
		local crowns = ::BBCoop.Contract.Capture;
		::BBCoop.Contract.Capture = null;
		try { ::BBCoop.Contract.payOut(this, crowns); }
		catch (error) { ::BBCoop.log("Could not split the payment: " + error); }
		::BBCoop.Contract.flushDone();
		return ret;
	}
});

::BBCoop.MH.hook("scripts/states/world/asset_manager", function(q) {
	q.addMoney = @(__original) function( _f )
	{
		if (::BBCoop.Contract.Capture != null && _f > 0) ::BBCoop.Contract.Capture += _f;
		return __original(_f);
	}
});
