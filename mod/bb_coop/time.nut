// Shared world time (v0.18.0). Everyone in a session is on the same day and hour.
//
// The host keeps one session clock and sends it every second ("world_time"). Every game, the
// host's included, sets its world time to that clock whenever it drifts away.
// Pausing (v0.24.0): when the host pauses (spacebar or the pause button), the clock stops and
// every joiner's world pauses with it until the host unpauses; joiners can't unpause meanwhile.
// A joiner's own pause, a town, the inventory or a contract screen stop only that player's
// company while the day keeps counting. A battle stops your world as usual; when it ends you
// come back to the shared day.
//
// Speed: the host's speed buttons set the session speed for everyone. While any player is in a
// battle (their own, or with their brothers away in someone else's), the clock is held at the
// slowest speed (normal), so nobody fast-forwards days while a friend fights.
// Joiners report their battles with "busy" messages.
//
// Checked against vanilla world_state (startNewCampaign/onCombatFinished use
// Time.setVirtualTime; onUpdate re-applies LastWorldSpeedMult every frame; getCombatStartTime),
// asset_manager (consumeFood uses the virtual-time delta; LastDayPaid) and food_item (BestBefore).

::BBCoop.Time <- {
	SendSeconds = 1.0,      // host: how often the clock goes out
	BusySeconds = 4.0,      // joiner: how often "still fighting" goes out
	BusyTimeout = 12.0,     // host: a player counts as fighting this long after their last "busy"
	SnapRunning = 2.0,      // drift (world seconds) allowed while our world runs
	SnapPaused = 1.0,       // drift allowed while it is paused (the clock only moves forward then)

	// host
	Clock = null,           // { T, Real, Speed } while someone is following our world
	LastSent = -100.0,
	SentSpeed = -1.0,       // speed in the last "world_time", so a pause goes out at once
	Fighting = {},          // player -> real time of their last "busy" with b = true

	// joiner
	Remote = null,          // { T, Recv, Speed, From } from the host's last "world_time"
	LastFightingText = "",
	PausedByHost = false,   // we paused our world because the host paused
	Arrived = false,        // the first big jump to the host's day was made

	// both
	WasBusy = false,
	LastBusySent = -100.0,

	function reset()
	{
		this.Clock = null;
		this.Remote = null;
		this.Fighting.clear();
		this.LastFightingText = "";
		this.Arrived = false;
		this.WasBusy = false;
		this.PausedByHost = false;
		this.SentSpeed = -1.0;
	}

	function normalSpeed()
	{
		return ::Const.World.SpeedSettings.NormalMult;
	}

	// In a battle, or our brothers are away in someone else's
	function isBusy()
	{
		if (::BBCoop.Battle.isInTactical() || ::BBCoop.Battle.PendingRefs != null) return true;
		try { if (::Tactical.isVisible()) return true; } catch (error) {}
		return false;
	}

	// Our world time, also while a battle borrows the game's clock
	function getWorldTime()
	{
		if (::BBCoop.Battle.isInTactical())
		{
			try { return ::World.State.getCombatStartTime(); } catch (error) {}
		}
		return ::Time.getVirtualTimeF();
	}

	// ================= host =================

	function getFighters()
	{
		local now = ::Time.getRealTimeF();
		local ret = [];
		if (this.isBusy()) ret.push(::BBCoop.getSetting("PlayerName"));
		foreach (name, time in this.Fighting)
			if (now - time <= this.BusyTimeout && ::BBCoop.isOnline(name, 20.0)) ret.push(name);
		ret.sort();
		return ret;
	}

	// The speed the host picked with the time buttons, between normal and very fast
	function getHostSpeed()
	{
		local speed = null;
		try { speed = ::World.State.getLastWorldSpeedMult(); } catch (error) {}
		if (speed == null || speed <= 0) speed = this.normalSpeed();
		return ::Math.maxf(this.normalSpeed(), ::Math.minf(speed, ::Const.World.SpeedSettings.VeryFastMult));
	}

	// The host pressed pause (not a town or menu, which only pause the host's own company).
	// In a battle the world's pause doesn't count: the battle lock holds the clock at normal.
	function isHostPaused()
	{
		if (this.isBusy()) return false;
		try { return ::World.State.m.IsGamePaused == true; } catch (error) {}
		return false;
	}

	function updateHost( _now )
	{
		if (!::BBCoop.World.hasFollowers())
		{
			if (this.Clock != null) ::BBCoop.log("Nobody follows this world any more; time runs on its own again.");
			this.Clock = null;
			return;
		}
		local fighters = this.getFighters();
		if (this.Clock == null)
		{
			this.Clock = { T = this.getWorldTime(), Real = _now, Speed = this.normalSpeed() };
			::BBCoop.log("Session clock started at day " + ::World.getTime().Days);
		}
		else
		{
			this.Clock.T += (_now - this.Clock.Real) * this.Clock.Speed;
			this.Clock.Real = _now;
		}
		if (this.isHostPaused()) this.Clock.Speed = 0.0;
		else this.Clock.Speed = fighters.len() != 0 ? this.normalSpeed() : this.getHostSpeed();
		this.showFighters(fighters);

		if (_now - this.LastSent >= this.SendSeconds || this.Clock.Speed != this.SentSpeed)
		{
			this.LastSent = _now;
			this.SentSpeed = this.Clock.Speed;
			::BBCoop.Connection.sendMessage("world_time", { t = this.Clock.T, sp = this.Clock.Speed, f = fighters });
		}
	}

	function getHostTarget( _now )
	{
		return this.Clock.T + (_now - this.Clock.Real) * this.Clock.Speed;
	}

	// A joiner started or ended a battle
	function onBusy( _from, _payload )
	{
		if (::BBCoop.World.getHost() != null) return;
		if (_payload.b) this.Fighting[_from] <- ::Time.getRealTimeF();
		else if (_from in this.Fighting) delete this.Fighting[_from];
	}

	// ================= joiner =================

	function onTime( _from, _payload )
	{
		if (!::BBCoop.World.isFromHost(_from)) return;
		this.Remote = { T = _payload.t.tofloat(), Recv = ::Time.getRealTimeF(), Speed = _payload.sp.tofloat(), From = _from };
		this.showFighters(_payload.f);
		this.followHostPause();
	}

	function getJoinerTarget( _now )
	{
		if (this.Remote == null || _now - this.Remote.Recv > 10.0) return null;
		if (!::BBCoop.World.isHostOnline()) return null;
		return this.Remote.T + (_now - this.Remote.Recv) * this.Remote.Speed;
	}

	function sendBusy( _now )
	{
		local busy = this.isBusy();
		local host = ::BBCoop.World.getHost();
		if (host == null) return;
		if (busy != this.WasBusy || (busy && _now - this.LastBusySent >= this.BusySeconds))
		{
			this.LastBusySent = _now;
			::BBCoop.Connection.sendMessage("busy", { to = host, b = busy });
		}
		this.WasBusy = busy;
	}

	// ================= both =================

	function showFighters( _list )
	{
		local me = ::BBCoop.getSetting("PlayerName");
		local others = [];
		foreach (name in _list)
			if (name != me) others.push(name);
		local text = "";
		foreach (i, name in others) text += (i == 0 ? "" : ", ") + name;
		if (text == this.LastFightingText) return;
		local was = this.LastFightingText;
		this.LastFightingText = text;
		if (text != "")
			::BBCoop.notify(text + (others.len() == 1 ? " is" : " are") + " in a battle: world time is held at normal speed until it ends.");
		else if (was != "")
			::BBCoop.notify("Nobody is fighting any more: the host's world speed applies again.");
	}

	// The session clock right now, or null when we are not in a session
	function getTarget( _now )
	{
		if (!::BBCoop.Ghosts.isWorldActive()) return null;
		if (::BBCoop.World.getHost() != null) return this.getJoinerTarget(_now);
		if (this.Clock != null) return this.getHostTarget(_now);
		return null;
	}

	function getSpeed()
	{
		if (::BBCoop.World.getHost() != null) return this.Remote != null ? this.Remote.Speed : null;
		return this.Clock != null ? this.Clock.Speed : null;
	}

	// First jump to the host's day after joining: the trip there costs no food, nothing spoils
	// and no wages are due for the days skipped
	function arrive( _jump )
	{
		try
		{
			::World.Assets.m.LastFoodConsumed += _jump;
			foreach (item in ::World.Assets.getStash().getItems())
			{
				if (item == null || !item.isItemType(::Const.Items.ItemType.Food)) continue;
				if (item.m.BestBefore != 0) item.m.BestBefore += _jump;
			}
			::World.Assets.m.LastDayPaid = ::World.getTime().Days;
		}
		catch (error)
		{
			::BBCoop.log("Adjusting supplies after joining failed: " + error);
		}
	}

	// Moves our world clock to the session's (world map only; a battle uses the clock itself)
	function apply( _now )
	{
		if (::BBCoop.Battle.isInTactical()) return;
		try { if (::Tactical.isVisible()) return; } catch (error) {}
		local target = this.getTarget(_now);
		if (target == null) return;
		local current = ::Time.getVirtualTimeF();
		local drift = target - current;
		local size = drift < 0 ? -drift : drift;
		local paused = false;
		try { paused = ::World.State.isPaused(); } catch (error) {}
		if (paused ? drift <= this.SnapPaused : size <= this.SnapRunning) return;

		local joiner = ::BBCoop.World.getHost() != null;
		local big = size > ::World.getTime().SecondsPerDay * 0.25;
		::Time.setVirtualTime(target);
		if (joiner && !this.Arrived)
		{
			this.Arrived = true;
			if (big)
			{
				this.arrive(drift);
				::BBCoop.notify("Your world's time now follows " + ::BBCoop.World.getHost() + "'s: day " + ::World.getTime().Days + ".");
			}
		}
		else if (big)
		{
			::BBCoop.log(format("World time moved %.0f seconds to the session's (day %i)", drift, ::World.getTime().Days));
		}
	}

	// Called about once a second (the connection's position timer), in battle too
	function tick()
	{
		if (!::BBCoop.Ghosts.isWorldActive()) return;
		local now = ::Time.getRealTimeF();
		if (::BBCoop.World.getHost() != null) this.sendBusy(now);
		else this.updateHost(now);
		this.apply(now);
	}

	// Joiner: pause while the host is paused, unpause when the host does (only if we paused)
	function followHostPause()
	{
		if (::BBCoop.World.getHost() == null || ::BBCoop.Battle.isInTactical()) return;
		try { if (::Tactical.isVisible()) return; } catch (error) {}
		local hostPaused = this.Remote != null && this.Remote.Speed <= 0 && this.getJoinerTarget(::Time.getRealTimeF()) != null;
		if (hostPaused)
		{
			// also when we pressed spacebar meanwhile: only the host unpauses
			if (!::World.State.m.IsGamePaused || !this.PausedByHost)
			{
				::World.State.setPause(true);
				try { ::World.TopbarDayTimeModule.showMessage("PAUSED", "(" + this.Remote.From + " paused the game)"); } catch (error) {}
				if (!this.PausedByHost) ::BBCoop.notify(this.Remote.From + " paused the game.");
			}
			this.PausedByHost = true;
		}
		else if (this.PausedByHost)
		{
			this.PausedByHost = false;
			// our brothers away in a battle keep the world paused (battle.nut)
			if (::BBCoop.Battle.PendingRefs == null && ::World.State.m.IsGamePaused) ::World.State.setPause(false);
			if (this.Remote != null) ::BBCoop.notify(this.Remote.From + " unpaused the game.");
		}
	}

	// Joiner: vanilla's auto-pause (new campaign, event, dialog, autosave) keeps the world at speed 0
	// whatever the pause button says. Every screen that sets it lifts it when it closes; a joined
	// campaign's skipped intro event never did (v0.46.1). Lift it ourselves when nothing is open.
	AutoPausedSince = null,
	function clearStaleAutoPause( _now )
	{
		local state = ::World.State;
		if (!state.m.IsGameAutoPaused) { this.AutoPausedSince = null; return; }
		if (this.AutoPausedSince == null) { this.AutoPausedSince = _now; return; }
		if (_now - this.AutoPausedSince < 3.0) return;
		if (state.m.MenuStack.hasBacksteps()) return;
		try { if (state.m.EventScreen.isVisible() || state.m.EventScreen.isAnimating()) return; } catch (error) {}
		try { if (::World.State.DialogScreen.isVisible() || ::World.State.DialogScreen.isAnimating()) return; } catch (error) {}
		::BBCoop.log("The world was left auto-paused with nothing open: lifting it.");
		state.setAutoPause(false);
		this.AutoPausedSince = null;
	}

	// Every world frame, after vanilla set the speed: everyone moves at the session speed
	function onWorldUpdate()
	{
		local now = ::Time.getRealTimeF();
		local joiner = ::BBCoop.World.getHost() != null;
		if (joiner)
		{
			this.followHostPause();
			try { this.clearStaleAutoPause(now); } catch (error) {}
		}
		else if (this.Clock != null && this.isHostPaused() != (this.Clock.Speed <= 0)) this.updateHost(now); // pause goes out at once
		local speed = this.getSpeed();
		if (speed == null || speed <= 0) return;
		if (joiner && this.getJoinerTarget(now) == null) return;
		if (::World.State.isPaused()) return;
		if (::World.getSpeedMult() != speed) ::World.setSpeedMult(speed);
	}
};

::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	q.onUpdate = @(__original) function()
	{
		__original();
		try { ::BBCoop.Time.onWorldUpdate(); } catch (error) {}
	}

	q.onFinish = @(__original) function()
	{
		::BBCoop.Time.reset();
		__original();
	}

	q.loadCampaign = @(__original) function( _campaignFileName )
	{
		::BBCoop.Time.reset();
		__original(_campaignFileName);
	}
});
