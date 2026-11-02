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
//
// The calendar (v0.49.0): Aaron and Touko ended up on different days (day 5 and day 2, one in the
// morning while the other had night) although both worlds had the same virtual time. The
// day/hour the game shows does not follow Time.setVirtualTime: a joiner who jumped 193 seconds to
// the host's time still read day 1, and a joiner whose world kept running while the host fought
// got days ahead. So the session clock now also carries the host's calendar (day and hour in world
// seconds), and every game, the host's included, runs its world faster (up to 8x) while it is
// behind that calendar and slower (down to 0.1x) while it is ahead, until they meet. If the
// calendar does not come closer that way, the catch-up is dropped for five minutes and logged.

::BBCoop.Time <- {
	SendSeconds = 1.0,      // host: how often the clock goes out
	BusySeconds = 4.0,      // joiner: how often "still fighting" goes out
	BusyTimeout = 12.0,     // host: a player counts as fighting this long after their last "busy"
	SnapRunning = 2.0,      // drift (world seconds) allowed while our world runs
	SnapPaused = 1.0,       // drift allowed while it is paused (the clock only moves forward then)
	CalendarSlack = 6.0,    // calendar drift (world seconds) left alone
	CatchUpMax = 8.0,       // fastest speed factor while behind the session's calendar
	CatchUpMin = 0.1,       // slowest while ahead of it
	CatchUpCheck = 15.0,    // real seconds between progress checks of a catch-up
	// v0.49.3: off. Aaron's and Touko's v0.49.2 logs show the calendar does not run at the speed
	// set here (Touko's ran about 1x while the world was set to 4x) and the host's ran ahead while
	// set to 0.1x, so the catch-up only made worlds oscillate. The clock test (Ctrl+Shift+T) finds
	// out what does move the calendar.
	CatchUpEnabled = false,
	Probe = null,           // the clock test while it runs

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
	Catch = null,           // { Since, Drift, Started } while our calendar catches up with the session's
	CatchOffUntil = -1.0,   // real time until which catching up is off (it made no progress)
	CatchStarts = [],       // real times catch-ups finished, to stop one that keeps coming back
	LastBusySent = -100.0,

	function reset()
	{
		this.Clock = null;
		this.Remote = null;
		this.Fighting.clear();
		this.LastFightingText = "";
		this.Arrived = false;
		this.WasBusy = false;
		this.Catch = null;
		this.CatchOffUntil = -1.0;
		this.CatchStarts = [];
		this.Probe = null;
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
			this.Clock = { T = this.getWorldTime(), C = this.getCalendar(), Real = _now, Speed = this.normalSpeed() };
			::BBCoop.log("Session clock started at day " + ::World.getTime().Days);
		}
		else
		{
			this.Clock.T += (_now - this.Clock.Real) * this.Clock.Speed;
			if (this.Clock.C != null) this.Clock.C += (_now - this.Clock.Real) * this.Clock.Speed;
			else this.Clock.C = this.getCalendar();
			this.Clock.Real = _now;
		}
		if (this.isHostPaused()) this.Clock.Speed = 0.0;
		else this.Clock.Speed = fighters.len() != 0 ? this.normalSpeed() : this.getHostSpeed();
		this.showFighters(fighters);

		if (_now - this.LastSent >= this.SendSeconds || this.Clock.Speed != this.SentSpeed)
		{
			this.LastSent = _now;
			this.SentSpeed = this.Clock.Speed;
			local msg = { t = this.Clock.T, sp = this.Clock.Speed, f = fighters };
			if (this.Clock.C != null) msg.c <- this.Clock.C;
			::BBCoop.Connection.sendMessage("world_time", msg);
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
		this.Remote = { T = _payload.t.tofloat(), C = ("c" in _payload) ? _payload.c.tofloat() : null, Recv = ::Time.getRealTimeF(), Speed = _payload.sp.tofloat(), From = _from };
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

	// ================= calendar (v0.49.0) =================

	// Our world's day and hour as world seconds since day 0, or null if the game won't say
	function getCalendar()
	{
		try
		{
			local t = ::World.getTime();
			local perDay = t.SecondsPerDay.tofloat();
			// v0.49.2: from Hours and Minutes (MSU reads both). v0.49.0 used SecondsOfDay first,
			// and Touko's log showed whole days only (day 2 at 210 s in daylight), which made
			// the catch-up push their world ahead.
			local sec = (t.Hours * 60.0 + t.Minutes) * perDay / 1440.0;
			return t.Days * perDay + sec;
		}
		catch (error) {}
		return null;
	}

	// The session's calendar right now, or null
	function getCalendarTarget( _now )
	{
		if (!::BBCoop.Ghosts.isWorldActive()) return null;
		if (::BBCoop.World.getHost() != null)
		{
			if (this.getJoinerTarget(_now) == null || this.Remote.C == null) return null;
			return this.Remote.C + (_now - this.Remote.Recv) * this.Remote.Speed;
		}
		if (this.Clock == null || this.Clock.C == null) return null;
		return this.Clock.C + (_now - this.Clock.Real) * this.Clock.Speed;
	}

	function describeDrift( _drift )
	{
		local days = _drift / ::World.getTime().SecondsPerDay;
		local size = days < 0 ? -days : days;
		if (size >= 1.0) return format("%.1f days", size);
		return format("%.0f hours", size * 24.0);
	}

	// Speed factor for our world this frame: above 1 while behind the session's calendar,
	// below 1 while ahead of it
	function getCatchUp( _now )
	{
		if (!this.CatchUpEnabled) return 1.0;
		if (_now < this.CatchOffUntil) return 1.0;
		local target = this.getCalendarTarget(_now);
		local cal = target != null ? this.getCalendar() : null;
		if (target == null || cal == null)
		{
			this.Catch = null;
			return 1.0;
		}
		local drift = target - cal;
		local size = drift < 0 ? -drift : drift;
		if (size <= this.CalendarSlack)
		{
			if (this.Catch != null)
			{
				::BBCoop.log(format("Calendar caught up with the session's after %.0f s (day %i)", _now - this.Catch.Started, ::World.getTime().Days));
				// Caught up again and again within a minute: something (like the time jumps) keeps
				// pushing it away, so stop fighting it for a while
				local recent = [];
				foreach (t in this.CatchStarts) if (_now - t < 60.0) recent.push(t);
				recent.push(_now);
				this.CatchStarts = recent;
				if (recent.len() > 3)
				{
					::BBCoop.log("The calendar keeps drifting away from the session's; catching up is off for 5 minutes.");
					this.CatchOffUntil = _now + 300.0;
					this.CatchStarts = [];
				}
			}
			this.Catch = null;
			return 1.0;
		}
		if (this.Catch == null)
		{
			this.Catch = { Since = _now, Drift = size, Started = _now };
			::BBCoop.log(format("Calendar is %s the session's: day %i, the session is on day %i (%+.0f s); %s the world until they meet",
				drift > 0 ? "behind" : "ahead of", ::World.getTime().Days, (target / ::World.getTime().SecondsPerDay).tointeger(), drift, drift > 0 ? "speeding up" : "slowing down"));
			if (size >= ::World.getTime().SecondsPerDay * 0.25)
				::BBCoop.notify("Your world is " + this.describeDrift(drift) + (drift > 0 ? " behind" : " ahead of") + " the shared day: it runs " + (drift > 0 ? "faster" : "slower") + " until it matches.");
		}
		else if (_now - this.Catch.Since >= this.CatchUpCheck)
		{
			if (size > this.Catch.Drift - 1.0)
			{
				::BBCoop.log(format("Calendar is not getting closer to the session's (%+.0f s); catching up is off for 5 minutes.", drift));
				this.CatchOffUntil = _now + 300.0;
				this.Catch = null;
				return 1.0;
			}
			this.Catch.Since = _now;
			this.Catch.Drift = size;
		}
		local f = 1.0 + drift / 10.0;
		if (f > this.CatchUpMax) f = this.CatchUpMax;
		if (f < this.CatchUpMin) f = this.CatchUpMin;
		return f;
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
		if (this.Probe != null) return;
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
		if (this.Catch != null) return; // the calendar is being caught up by speed; a jump would fight it

		local joiner = ::BBCoop.World.getHost() != null;
		local big = size > ::World.getTime().SecondsPerDay * 0.25;
		::Time.setVirtualTime(target);
		if (big && ::Time.getVirtualTimeF() + 1.0 < target) ::BBCoop.log(format("World time did not move: set %.0f s, it reads %.0f s", target, ::Time.getVirtualTimeF()));
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
		try { this.logState(now); } catch (error) {}
	}

	// v0.48.1/v0.49.0: a line every 30 seconds with where our world's clock and calendar stand against the session's,
	// to trace day/night differences between players (Aaron day 5, Touko day 2)
	LastStateLog = -100.0,
	function logState( _now )
	{
		if (_now - this.LastStateLog < 30.0) return;
		this.LastStateLog = _now;
		local joiner = ::BBCoop.World.getHost() != null;
		local t = ::World.getTime();
		local day = ::World.getTime().SecondsPerDay;
		local current = ::Time.getVirtualTimeF();
		local target = this.getTarget(_now);
		local text = format("Clock (%s): world day %i %s (%.0f s), speed %.2f, paused %s, tactical %s",
			joiner ? "joiner of " + ::BBCoop.World.getHost() : (this.Clock != null ? "host" : "solo"),
			t.Days, t.IsDaytime ? "daytime" : "night", current, ::World.getSpeedMult(), "" + ::World.State.isPaused(), "" + ::BBCoop.Battle.isInTactical());
		if (target != null) text += format(", session %.0f s (drift %+.0f s = %+.2f days)", target, target - current, (target - current) / day);
		else if (joiner) text += ", no session clock: " + (this.Remote == null ? "no world_time from the host yet" : format("last world_time %.0f s ago, host online %s", _now - this.Remote.Recv, "" + ::BBCoop.World.isHostOnline()));
		local cal = this.getCalendar();
		local calTarget = this.getCalendarTarget(_now);
		if (cal != null) text += format("; calendar %.0f s (day %i %i:%02i, time of day %i)", cal, t.Days, t.Hours, t.Minutes, t.TimeOfDay);
		if (cal != null && calTarget != null) text += format(", session calendar %.0f s (drift %+.0f s)%s", calTarget, calTarget - cal, this.Catch != null ? ", catching up" : "");
		if (_now < this.CatchOffUntil) text += format(", catching up off for %.0f s more", this.CatchOffUntil - _now);
		::BBCoop.log(text);
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

	// ================= clock test (v0.49.3) =================
	// Ctrl+Shift+T on the world map: a 20-second test of what moves the game's calendar (the day
	// and hour it shows), written to the log. It moves your world about half a day ahead.

	function startProbe()
	{
		if (!::BBCoop.Ghosts.isWorldActive() || ::BBCoop.Battle.isInTactical()) { ::BBCoop.notify("The clock test runs on the world map."); return; }
		if (this.Probe != null) { ::BBCoop.notify("The clock test is already running."); return; }
		this.Probe = { Step = 0, At = null, W = null, V = null, Speed = ::World.getSpeedMult(), Last = null, Count = 0 };
		try { this.Probe.Last = ::World.State.m.LastWorldSpeedMult; } catch (error) {}
		::BBCoop.notify("Clock test: unpause and let the world run for about 20 seconds. Results go to the log.");
		::BBCoop.log(format("Clock test start: calendar %.1f s, virtual %.1f s, speed %.2f, vanilla speed %s", this.getCalendar(), ::Time.getVirtualTimeF(), ::World.getSpeedMult(), "" + this.Probe.Last));
	}

	function probeMark( _now )
	{
		this.Probe.At = _now;
		this.Probe.W = this.getCalendar();
		this.Probe.V = ::Time.getVirtualTimeF();
	}

	function probeReport( _now, _what )
	{
		local p = this.Probe;
		::BBCoop.log(format("Clock test %s: over %.1f real s the calendar moved %+.1f s and the virtual time %+.1f s (speed %.2f, vanilla speed %s, calendar now day %i %i:%02i)",
			_what, _now - p.At, this.getCalendar() - p.W, ::Time.getVirtualTimeF() - p.V, ::World.getSpeedMult(), "" + ::World.State.m.LastWorldSpeedMult,
			::World.getTime().Days, ::World.getTime().Hours, ::World.getTime().Minutes));
	}

	// Called every world frame while the test runs; returns true while it holds the speed
	function stepProbe( _now )
	{
		local p = this.Probe;
		local state = ::World.State;
		if (state.isPaused())
		{
			p.At = null; // the step starts over once the world runs
			return true;
		}
		if (p.At == null) { this.probeMark(_now); if (p.Step == 1) ::Time.setVirtualTime(p.V + 30.0); if (p.Step == 2) ::Time.setVirtualTime(p.V - 30.0); return true; }
		local held = _now - p.At;
		if (p.Step == 3) ::World.setSpeedMult(4.0);
		if (p.Step == 4) { state.m.LastWorldSpeedMult = 4.0; ::World.setSpeedMult(4.0); }
		if (held < 3.0) return true;
		local names = ["at the normal speed", "after a jump of the virtual time 30 s forward", "after a jump of the virtual time 30 s back", "with the world speed set to 4 (vanilla's own speed left alone)", "with vanilla's own speed set to 4 too"];
		this.probeReport(_now, names[p.Step]);
		if (p.Step == 4)
		{
			try { if (p.Last != null) state.m.LastWorldSpeedMult = p.Last; } catch (error) {}
			::World.setSpeedMult(p.Speed > 0 ? p.Speed : this.normalSpeed());
			this.Probe = null;
			::BBCoop.notify("Clock test done: please send your log.");
			return false;
		}
		p.Step++;
		p.At = null;
		return true;
	}

	// Every world frame, after vanilla set the speed: everyone moves at the session speed
	function onWorldUpdate()
	{
		local now = ::Time.getRealTimeF();
		if (this.Probe != null)
		{
			try { if (this.stepProbe(now)) return; }
			catch (error) { ::BBCoop.log("Clock test failed: " + error); this.Probe = null; }
		}
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
		if (::World.State.isPaused())
		{
			this.Catch = null; // a paused world can't catch up; start counting again when it runs
			return;
		}
		try { speed *= this.getCatchUp(now); } catch (error) { ::BBCoop.log("Calendar catch-up failed: " + error); this.CatchOffUntil = now + 300.0; }
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
