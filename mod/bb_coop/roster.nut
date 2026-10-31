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
				saturation = sprite.Saturation,
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
		return ret;
	}

	function applyAppearance( _bro, _appearance )
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
				sprite.Saturation = entry.saturation;
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
				b.Saturation = a.Saturation;
				b.Color = a.Color;
			}
			catch (error)
			{
				::BBCoop.log("Could not copy sprite " + name + ": " + error);
			}
		}
		try { _to.setDirty(true); } catch (error) {}
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
		_bro.onDeserialize(sd.getDeserializationEmulator());
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
				bros.push({ key = key, name = bro.getName(), raw = this.serializeBrother(bro), look = this.captureAppearance(bro) });
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
