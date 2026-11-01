// Shared battles, part 2: each player controls their own brothers.
// The host's game runs the battle. When it is the turn of a brother that belongs to another
// player, the host locks its own input and sends that player a view of the battlefield
// ("battle_view"). The other player picks a skill and a tile in their battle panel, which
// sends an order ("battle_order") back; the host carries it out exactly as if its own
// player had clicked. Between turns, every turn change sends a fresh view so the other
// player can follow the battle.
// Checked against the decompiled vanilla tactical_state (updateCurrentEntity,
// computeEntityPath, executeEntityTravel, executeEntitySkill) and skill.nut.

::BBCoop.Remote <- {
	TimeoutSeconds = 90.0,  // no order for this long: the host takes over that turn
	OfflineSeconds = 20.0,  // no message at all for this long: the player counts as disconnected
	ResendSeconds = 15.0,   // waiting for orders: send the view again in case it got lost
	OfflineNotified = {},
	LastViewSent = 0.0,

	Orders = [],            // orders waiting for the active brother
	ActiveID = null,        // entity id whose turn we last saw
	TurnStart = 0.0,
	LastOrderTime = 0.0,
	Travelling = false,
	NeedView = false,       // send a view once the current action has finished
	TookOverID = null,      // entity the host controls this turn after a timeout
	LastViewEntity = null,  // entity id of the last turn change we reported

	function reset()
	{
		this.Orders.clear();
		this.ActiveID = null;
		this.Travelling = false;
		this.NeedView = false;
		this.TookOverID = null;
		this.LastViewEntity = null;
		this.OfflineNotified.clear();
	}

	function getOwner( _e )
	{
		if (_e == null || !_e.getFlags().has("BBCoopOwner")) return null;
		return _e.getFlags().get("BBCoopOwner");
	}

	// Is this brother played by someone else right now?
	function controls( _e )
	{
		if (_e == null || !_e.isAlive()) return false;
		if (this.getOwner(_e) == null) return false;
		if (_e.getID() == this.TookOverID) return false;
		if (_e.getMoraleState() == ::Const.MoraleState.Fleeing) return false; // vanilla AI runs fleeing brothers
		local owner = this.getOwner(_e);
		if (!::BBCoop.isOnline(owner, this.OfflineSeconds))
		{
			if (!(owner in this.OfflineNotified))
			{
				this.OfflineNotified[owner] <- true;
				::BBCoop.notify(owner + " seems to have disconnected. You control their brothers until they are back.");
			}
			return false;
		}
		if (owner in this.OfflineNotified)
		{
			delete this.OfflineNotified[owner];
			::BBCoop.notify(owner + " is back and controls their brothers again.");
		}
		return true;
	}

	// ---------- views ----------

	function terrainChar( _t )
	{
		if (_t.Type == ::Const.Tactical.TerrainType.Impassable) return "#";
		if (!_t.IsEmpty && !_t.IsOccupiedByActor) return "#"; // trees, rocks, walls
		if (_t.Type == ::Const.Tactical.TerrainType.DeepWater) return "~";
		if (_t.Type == ::Const.Tactical.TerrainType.ShallowWater) return "-";
		return ".";
	}

	function buildView( _owner, _active )
	{
		local size = ::Tactical.getMapSize();
		local terrain = "", levels = "";
		local units = [];
		local mirror = _owner in ::BBCoop.Battle.MirrorOwners;
		// sides are seen from the owner's point of view: they may have joined against us
		local ownerFaction = ::Const.Faction.Player;
		foreach (r in ::BBCoop.Battle.Reinforcements)
		{
			if (r.owner == _owner && r.bro != null && !r.bro.isNull())
			{
				ownerFaction = r.bro.getFaction();
				break;
			}
		}

		for (local y = 0; y < size.Y; y++)
		{
			for (local x = 0; x < size.X; x++)
			{
				if (!::Tactical.isValidTileSquare(x, y))
				{
					terrain += " ";
					levels += "0";
					continue;
				}
				local t = ::Tactical.getTileSquare(x, y);
				terrain += this.terrainChar(t);
				levels += ::Math.max(0, ::Math.min(9, t.Level)).tostring();

				if (!t.IsOccupiedByActor) continue;
				local u = t.getEntity();
				if (u == null || !u.isAlive()) continue;
				local side = "enemy";
				if (this.getOwner(u) == _owner) side = "mine";
				else if (u.getFaction() == ownerFaction || ::World.FactionManager.isAllied(ownerFaction, u.getFaction())) side = "ally";
				// enemies we can't see: the battle panel leaves them out, the real battlefield
				// keeps them (its own fog of war hides them)
				local hidden = !t.IsVisibleForPlayer && side == "enemy" && ownerFaction == ::Const.Faction.Player;
				if (hidden && !mirror) continue;
				local unit = {
					x = x, y = y,
					name = u.getName(),
					hp = u.getHitpoints(),
					hpMax = u.getHitpointsMax(),
					side = side,
					active = _active != null && u.getID() == _active.getID()
				};
				if (hidden) unit.hid <- true;
				if (side == "mine" && u.getFlags().has("BBCoopKey")) unit.key <- u.getFlags().get("BBCoopKey");
				if (mirror) ::BBCoop.Mirror.addMirrorFields(unit, u, _owner);
				units.push(unit);
			}
		}

		local view = {
			to = _owner,
			battleID = ::BBCoop.Battle.HostBattleID,
			round = 0,
			map = { w = size.X, h = size.Y, oddDown = this.isOddColumnDown(), terrain = terrain, levels = levels },
			units = units,
			turn = null
		};
		try { view.round = ::Tactical.TurnSequenceBar.getCurrentRound(); } catch (error) {}
		if (mirror)
		{
			view.activeID <- _active != null ? _active.getID() : null;
			view.log <- ::BBCoop.Mirror.takeLogFor(_owner);
			view.dead <- clone ::BBCoop.Mirror.DeadIDs;
		}
		if (_active != null && this.getOwner(_active) == _owner && this.controls(_active))
			view.turn = this.buildTurn(_active);
		else if (_active != null)
			view.waitingFor <- _active.getName();
		return view;
	}

	// Which way odd columns of the square grid are shifted, worked out from tile distances
	OddDown = null,
	function isOddColumnDown()
	{
		if (this.OddDown != null) return this.OddDown;
		this.OddDown = true;
		try
		{
			// with odd columns shifted down, square (0,1) touches (1,0)
			this.OddDown = ::Tactical.getTileSquare(0, 1).getDistanceTo(::Tactical.getTileSquare(1, 0)) == 1;
		}
		catch (error) {}
		return this.OddDown;
	}

	function buildTurn( _e )
	{
		local own = _e.getTile();
		local size = ::Tactical.getMapSize();
		local skills = [];
		foreach (ref in _e.getSkills().queryActives())
		{
			if (ref == null || ref.isNull()) continue;
			local s = ref.get();
			local entry = {
				id = s.getID(),
				name = s.getName(),
				ap = s.getActionPointCost(),
				fat = s.getFatigueCost(),
				usable = s.isUsable() && s.isAffordable(),
				attack = s.isAttack(),
				targeted = s.isTargeted(),
				targets = []
			};
			if (entry.usable && entry.targeted)
			{
				local reach = s.getMaxRange() + s.getMaxRangeBonus() + 1;
				for (local y = 0; y < size.Y; y++)
				{
					for (local x = 0; x < size.X; x++)
					{
						if (!::Tactical.isValidTileSquare(x, y)) continue;
						local t = ::Tactical.getTileSquare(x, y);
						if (own.getDistanceTo(t) > reach) continue;
						try
						{
							if (s.isUsableOn(t)) entry.targets.push([x, y]);
						}
						catch (error) {}
					}
				}
			}
			skills.push(entry);
		}
		return {
			key = _e.getFlags().has("BBCoopKey") ? _e.getFlags().get("BBCoopKey") : "",
			name = _e.getName(),
			x = own.SquareCoords.X,
			y = own.SquareCoords.Y,
			ap = _e.getActionPoints(),
			fatigue = _e.getFatigue(),
			fatigueMax = _e.getFatigueMax(),
			skills = skills
		};
	}

	function sendView( _owner, _active )
	{
		try
		{
			::BBCoop.Connection.sendMessage("battle_view", this.buildView(_owner, _active));
			this.LastViewSent = ::Time.getRealTimeF();
		}
		catch (error)
		{
			::BBCoop.log("Could not build the battle view: " + error);
		}
	}

	// Every turn change: tell each joined player who is up
	function onTurnChange( _active )
	{
		foreach (owner, _ in ::BBCoop.Battle.JoinedOwners)
			this.sendView(owner, _active);
	}

	function sendError( _owner, _text )
	{
		::BBCoop.Connection.sendMessage("battle_order_error", { to = _owner, text = _text });
	}

	// ---------- orders ----------

	function onOrder( _from, _payload )
	{
		if (::BBCoop.Battle.HostBattleID == null || _payload.battleID != ::BBCoop.Battle.HostBattleID) return;
		_payload.from <- _from;
		this.Orders.push(_payload);
	}

	// Called every frame by the hook below while a remote brother has its turn
	function update( _state, _e )
	{
		local now = ::Time.getRealTimeF();
		if (this.ActiveID != _e.getID())
		{
			this.ActiveID = _e.getID();
			this.TurnStart = now;
			this.LastOrderTime = now;
			this.Travelling = false;
			this.NeedView = false;
			// drop leftovers meant for someone else
			local key = _e.getFlags().get("BBCoopKey");
			local keep = [];
			foreach (o in this.Orders)
				if (o.key == key) keep.push(o);
			this.Orders = keep;
		}

		local nav = ::Tactical.getNavigator();
		if (this.Travelling)
		{
			if (!nav.travel(_e, _e.getActionPoints(), _e.getFatigueMax() - _e.getFatigue()))
			{
				this.Travelling = false;
				this.NeedView = true;
				if (_e.isAlive()) ::Tactical.TurnSequenceBar.updateEntity(_e.getID());
			}
			return;
		}

		if (nav.isTravelling(_e) || _e.isPlayingRenderAnimation() || _e.getSkills().isBusy()) return;

		if (_e.isTurnDone())
		{
			this.endTurn();
			return;
		}

		if (this.NeedView)
		{
			this.NeedView = false;
			this.sendView(this.getOwner(_e), _e);
		}

		if (this.Orders.len() == 0 && now - this.LastViewSent > this.ResendSeconds && now - this.LastOrderTime > this.ResendSeconds)
			this.sendView(this.getOwner(_e), _e);

		if (this.Orders.len() != 0)
		{
			this.LastOrderTime = now;
			this.execute(_state, _e, this.Orders.remove(0));
			return;
		}

		if (now - this.LastOrderTime > this.TimeoutSeconds)
		{
			this.TookOverID = _e.getID();
			_state.setInputLocked(false);
			::BBCoop.notify(format("No orders from %s for %s, you control him this turn.", this.getOwner(_e), _e.getName()));
		}
	}

	function endTurn()
	{
		this.ActiveID = null;
		::Tactical.TurnSequenceBar.initNextTurn();
	}

	function execute( _state, _e, _order )
	{
		local owner = this.getOwner(_e);
		if (_order.from != owner || _order.key != _e.getFlags().get("BBCoopKey"))
		{
			this.sendError(_order.from, "It is not that brother's turn.");
			return;
		}

		switch (_order.action)
		{
			case "end":
				this.endTurn();
				return;

			case "wait":
				if (!::Tactical.TurnSequenceBar.entityWaitTurn(_e)) this.endTurn();
				else this.ActiveID = null;
				return;

			case "move":
				this.move(_e, owner, _order.x, _order.y);
				return;

			case "skill":
				this.useSkill(_state, _e, owner, _order.skill, _order.x, _order.y);
				return;
		}
		this.sendError(owner, "Unknown order " + _order.action);
	}

	function move( _e, _owner, _x, _y )
	{
		if (!::Tactical.isValidTileSquare(_x, _y)) { this.sendError(_owner, "That tile is off the map."); return; }
		if (_e.getCurrentProperties().IsRooted) { this.sendError(_owner, _e.getName() + " can't move right now."); return; }
		local tile = ::Tactical.getTileSquare(_x, _y);
		if (tile.ID == _e.getTile().ID) return;

		// same settings vanilla uses when the player clicks a tile
		local nav = ::Tactical.getNavigator();
		local settings = nav.createSettings();
		settings.ActionPointCosts = _e.getActionPointCosts();
		settings.FatigueCosts = _e.getFatigueCosts();
		settings.FatigueCostFactor = ::Const.Movement.FatigueCostFactor;
		settings.ActionPointCostPerLevel = _e.getLevelActionPointCost();
		settings.FatigueCostPerLevel = _e.getLevelFatigueCost();
		settings.ZoneOfControlCost = 4;
		settings.AlliedFactions = _e.getAlliedFactions();
		settings.Faction = _e.getFaction();
		settings.AllowZoneOfControlPassing = true;
		settings.IsPlayer = true;

		if (!nav.findPath(_e.getTile(), tile, settings, 0))
		{
			this.sendError(_owner, "No path to that tile.");
			return;
		}
		settings.ZoneOfControlCost = 0;
		local costs = nav.getCostForPath(_e, settings, _e.getActionPoints(), _e.getFatigueMax() - _e.getFatigue());
		if (costs.Tiles == 0)
		{
			nav.clearPath();
			this.sendError(_owner, "Not enough action points or fatigue to move there.");
			return;
		}
		::Tactical.getShaker().cancel(_e);
		this.Travelling = true;
	}

	function useSkill( _state, _e, _owner, _skillID, _x, _y )
	{
		local skill = _e.getSkills().getSkillByID(_skillID);
		if (skill == null) { this.sendError(_owner, "Unknown skill."); return; }
		if (!skill.isUsable() || !skill.isAffordable()) { this.sendError(_owner, skill.getName() + " can't be used right now."); return; }
		local tile = skill.isTargeted() && ::Tactical.isValidTileSquare(_x, _y) ? ::Tactical.getTileSquare(_x, _y) : _e.getTile();
		if (!skill.isUsableOn(tile)) { this.sendError(_owner, "Invalid target for " + skill.getName() + "."); return; }

		::BBCoop.log(_e.getName() + " (" + _owner + ") uses " + skill.getName());
		skill.use(tile);
		if (_e.isAlive()) ::Tactical.TurnSequenceBar.updateEntity(_e.getID());
		this.NeedView = true;
	}
};

::BBCoop.MH.hook("scripts/states/tactical_state", function(q) {
	q.updateCurrentEntity = @(__original) function()
	{
		// a copy of another player's battle: nothing acts here, the host's views drive it (mirror.nut)
		if (::BBCoop.Mirror.Active)
		{
			try { ::BBCoop.Mirror.update(this); }
			catch (error) { ::BBCoop.log("Mirror update failed: " + error); }
			return;
		}

		local e = null;
		try { e = ::Tactical.TurnSequenceBar.getActiveEntity(); } catch (error) {}

		// keep the other players up to date on whose turn it is
		if (e != null && ::BBCoop.Battle.HostBattleID != null && ::BBCoop.Battle.JoinedOwners.len() != 0)
		{
			local id = e.getID();
			if (id != ::BBCoop.Remote.LastViewEntity)
			{
				::BBCoop.Remote.LastViewEntity = id;
				if (id != ::BBCoop.Remote.TookOverID) ::BBCoop.Remote.TookOverID = null;
				::BBCoop.Remote.onTurnChange(e);
			}
			try { ::BBCoop.Mirror.hostTick(e); }
			catch (error) { ::BBCoop.log("Mirror sync failed: " + error); }
		}

		local remote = false;
		try
		{
			remote = e != null && !this.m.IsGamePaused && !this.m.IsAutoRetreat && !(this.m.IsGameFinishable && this.isBattleEnded()) && ::BBCoop.Remote.controls(e);
		}
		catch (error) {}

		if (!remote)
		{
			__original();
			return;
		}

		e.onUpdate();
		this.setInputLocked(true);
		try
		{
			::BBCoop.Remote.update(this, e);
		}
		catch (error)
		{
			::BBCoop.log("Remote turn failed: " + error + ", handing the turn to the host");
			::BBCoop.Remote.TookOverID = e.getID();
			this.setInputLocked(false);
		}
	}

	// Keep the host's end turn / wait keys away from brothers someone else is playing
	q.onKeyInput = @(__original) function( _key )
	{
		try
		{
			local e = ::Tactical.TurnSequenceBar.getActiveEntity();
			if (::BBCoop.Remote.controls(e) && [16, 28, 39, 40, 44].find(_key.getKey()) != null) return true;
		}
		catch (error) {}
		return __original(_key);
	}
});
