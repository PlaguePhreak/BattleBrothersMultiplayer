// Turning brothers into plain data that can travel over the network, and back.
// Uses MSU's serialization emulator: the brother writes itself exactly as it would
// into a save file, and we keep the list of (type, value) pairs.

::BBCoop.Roster <- {
	MaxBrothers = 12,  // how many frontline brothers join someone else's battle

	// Faces and bodies are not part of the script serialization (the engine saves sprites
	// itself), so these sprites are sent separately. Items redraw their own sprites.
	AppearanceSprites = [
		"body", "injury_body", "tattoo_body", "scar_body",
		"head", "tattoo_head", "scar_head", "hair", "beard", "beard_top",
		"permanent_injury_1", "permanent_injury_2", "permanent_injury_3", "permanent_injury_4"
	],
	ColorWarned = false,
	LookLogged = false,

	function colorToHex( _color )
	{
		// "#rrggbb", the same form vanilla passes to createColor (no alpha, no "#" broke the tint)
		local parts = [_color.R, _color.G, _color.B];
		local hex = "#";
		foreach (v in parts)
		{
			local n = typeof v == "float" && v <= 1.0 ? (v * 255.0 + 0.5).tointeger() : v.tointeger();
			n = ::Math.max(0, ::Math.min(255, n));
			hex += format("%02x", n);
		}
		return hex;
	}

	function captureAppearance( _bro )
	{
		local ret = {};
		foreach (name in this.AppearanceSprites)
		{
			if (!_bro.hasSprite(name)) continue;
			local sprite = _bro.getSprite(name);
			local entry = {
				brush = sprite.HasBrush ? sprite.getBrush().Name : "",
				visible = sprite.Visible,
				color = null
			};
			try
			{
				entry.color = this.colorToHex(sprite.Color);
			}
			catch (error)
			{
				if (!this.ColorWarned)
				{
					this.ColorWarned = true;
					::BBCoop.log("Could not read sprite colors (" + error + "), skin and hair tints won't carry over");
				}
			}
			ret[name] <- entry;
		}
		if (!this.LookLogged && "head" in ret)
		{
			this.LookLogged = true;
			local h = _bro.getSprite("head");
			local sat = "?";
			try { sat = h.Saturation; } catch (error) {}
			::BBCoop.log("Appearance sample (" + _bro.getName() + "): head " + ret.head.brush + " color " + ret.head.color + " saturation " + sat);
		}
		return ret;
	}

	function applyAppearance( _bro, _appearance, _isHuman = true )
	{
		foreach (name, entry in _appearance)
		{
			if (!_bro.hasSprite(name)) continue;
			try
			{
				local sprite = _bro.getSprite(name);
				if (entry.brush != "") sprite.setBrush(entry.brush);
				else sprite.resetBrush();
				sprite.Visible = entry.visible;
				// Skin came out grey when the read-back saturation was copied, so use the normal value
				if (_isHuman && (name == "head" || name == "body")) sprite.Saturation = 1.0;
				if (entry.color != null) sprite.Color = ::createColor(entry.color);
			}
			catch (error)
			{
				::BBCoop.log("Could not restore sprite " + name + ": " + error);
			}
		}
		try { _bro.setDirty(true); } catch (error) {}
	}

	// Same game on both ends: copy the sprites over directly
	function copyAppearance( _from, _to )
	{
		foreach (name in this.AppearanceSprites)
		{
			if (!_from.hasSprite(name) || !_to.hasSprite(name)) continue;
			try
			{
				local a = _from.getSprite(name), b = _to.getSprite(name);
				if (a.HasBrush) b.setBrush(a.getBrush().Name);
				else b.resetBrush();
				b.Visible = a.Visible;
				if (name == "head" || name == "body") b.Saturation = 1.0;
				b.Color = a.Color;
			}
			catch (error)
			{
				::BBCoop.log("Could not copy sprite " + name + ": " + error);
			}
		}
		try { _to.setDirty(true); } catch (error) {}
	}

	// A copied brother's name without his title: vanilla getName() is "Name Title", and the raw
	// data restores the title on its own, so setName(getName()) doubled it at every copy
	// ("Rupert the Hound the Hound the Hound", v0.46.2)
	function nameOf( _bro )
	{
		try { return _bro.getNameOnly(); } catch (error) {}
		return _bro.getName();
	}

	// Names stored by older builds carry the title once or more: strip it before setting
	function setCopiedName( _bro, _name )
	{
		local title = "";
		try { title = _bro.getTitle(); } catch (error) {}
		if (title != null && title != "")
		{
			local tail = " " + title;
			while (_name.len() > tail.len() && _name.slice(_name.len() - tail.len()) == tail)
				_name = _name.slice(0, _name.len() - tail.len());
		}
		_bro.setName(_name);
	}

	function serializeBrother( _bro )
	{
		local sd = ::MSU.Class.SerializationData();
		local out = sd.getSerializationEmulator();
		_bro.onSerialize(out);
		local raw = [];
		foreach (d in sd.getDataArray())
			raw.push([d.getType(), d.getData()]);
		return raw;
	}

	// Writes the data into a brother that was just created (not yet set up)
	function deserializeInto( _bro, _raw )
	{
		_bro.onDeserialize(this.makeReader(_raw));
	}

	// A reader over data written by the serialization emulator (sent as [type, value] pairs)
	function makeReader( _raw )
	{
		local sd = ::MSU.Class.SerializationData();
		foreach (pair in _raw)
		{
			local value = pair[1];
			if (pair[0] == ::MSU.Serialization.DataType.F32 && typeof value == "integer")
				value = value.tofloat(); // JSON turns 1.0 into 1
			sd.write(value, pair[0]);
		}
		// The emulator's metadata reports the current save format version, which is the format
		// the sender just wrote in. (Using the loaded save's metadata could report an older version.)
		return sd.getDeserializationEmulator();
	}

	// The brothers that would fight: not in reserve, in formation order
	function getFighters()
	{
		local ret = [];
		foreach (bro in ::World.getPlayerRoster().getAll())
		{
			// vanilla: formation slots 0-17 fight, the rest are reserves
			if (bro.getPlaceInFormation() > 17) continue;
			// isInReserves only exists with Legends
			local reserve = false;
			try { reserve = bro.isInReserves(); } catch (error) {}
			if (reserve) continue;
			ret.push(bro);
		}
		ret.sort(@(a, b) a.getPlaceInFormation() <=> b.getPlaceInFormation());
		if (ret.len() > this.MaxBrothers) ret.resize(this.MaxBrothers);
		return ret;
	}

	// The relay's test bot picks one company origin; our game rolls a company that fits it
	// (the bot can't make brothers itself). Base game backgrounds only.
	BotOrigins = {
		mercenaries = { name = "Mercenaries", count = 3, backgrounds = ["sellsword_background", "retired_soldier_background", "militia_background"] },
		deserters = { name = "Deserters", count = 6, backgrounds = ["deserter_background"] },
		militia = { name = "Peasant Militia", count = 8, backgrounds = ["militia_background", "farmhand_background", "daytaler_background", "miller_background", "lumberjack_background"] },
		beast_slayers = { name = "Beast Slayers", count = 3, backgrounds = ["beast_hunter_background"] },
		caravan = { name = "Trading Caravan", count = 3, backgrounds = ["caravan_hand_background"] },
		lone_wolf = { name = "Lone Wolf", count = 1, backgrounds = ["hedge_knight_background"] }
	},

	function rollCompany( _originID )
	{
		local origin = _originID in this.BotOrigins ? this.BotOrigins[_originID] : this.BotOrigins.mercenaries;
		::BBCoop.log("Rolling the bot's company: " + origin.name);
		local bros = [];
		local roster = ::World.getTemporaryRoster();
		for (local i = 0; i < origin.count; i++)
		{
			local bro = null;
			try
			{
				bro = roster.create("scripts/entity/tactical/player");
				bro.setStartValuesEx(origin.backgrounds);
				bros.push({ key = "bot_" + i, name = this.nameOf(bro), raw = this.serializeBrother(bro), look = this.captureAppearance(bro) });
			}
			catch (error)
			{
				::BBCoop.log("Could not roll a brother for the bot: " + error);
			}
			if (bro != null) roster.remove(bro);
		}
		return bros;
	}

	// Payload sent when joining a battle. Keys let the results find the right brother later.
	function packCompany( _keyPrefix )
	{
		local bros = [];
		local refs = {};
		foreach (i, bro in this.getFighters())
		{
			local key = _keyPrefix + "_" + i;
			try
			{
				bros.push({ key = key, name = this.nameOf(bro), raw = this.serializeBrother(bro), look = this.captureAppearance(bro) });
				refs[key] <- ::WeakTableRef(bro);
			}
			catch (error)
			{
				::BBCoop.log("Could not serialize " + bro.getName() + ": " + error);
			}
		}
		return { bros = bros, refs = refs };
	}
};
