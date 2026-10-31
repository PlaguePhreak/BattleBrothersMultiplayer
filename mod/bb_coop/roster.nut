// Turning brothers into plain data that can travel over the network, and back.
// Uses MSU's serialization emulator: the brother writes itself exactly as it would
// into a save file, and we keep the list of (type, value) pairs.

::BBCoop.Roster <- {
	MaxBrothers = 12,  // how many frontline brothers join someone else's battle

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
				bros.push({ key = key, name = bro.getName(), raw = this.serializeBrother(bro) });
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
