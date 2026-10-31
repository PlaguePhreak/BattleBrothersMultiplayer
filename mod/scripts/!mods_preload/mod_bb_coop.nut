::BBCoop <- {
	ID = "mod_bb_coop",
	Version = "0.6.0",
	Name = "Battle Brothers Co-op"
};

::BBCoop.MH <- ::Hooks.register(::BBCoop.ID, ::BBCoop.Version, ::BBCoop.Name);
::BBCoop.MH.require("mod_msu >= 1.3.0");

::BBCoop.MH.queue(">mod_msu", function() {
	::BBCoop.Mod <- ::MSU.Class.Mod(::BBCoop.ID, ::BBCoop.Version, ::BBCoop.Name);
	::include("bb_coop/load.nut");
});
