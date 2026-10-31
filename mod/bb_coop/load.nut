// Settings shown under Mod Options > Battle Brothers Co-op
local page = ::BBCoop.Mod.ModSettings.addPage("General");
page.addStringSetting("RelayURL", "http://127.0.0.1:7777", "Relay URL", "Address of the co-op relay server. Both players must use the same one.");
page.addStringSetting("SessionPassword", "", "Session password", "Only needed when the host started the relay with a password.");
page.addStringSetting("PlayerName", "Player", "Player name", "Shown to the other player. Must differ between the two players.");
local joinRange = page.addRangeSetting("JoinRange", 600, 100, 2000, 50, "Battle join range", "How close (in world units) your company must be to another player's battle to join it as reinforcements.");
joinRange.addCallback(function( _value ) { ::BBCoop.Battle.JoinRange = _value.tofloat(); });
page.addStringSetting("Clan", "", "Clan", "Players in the same clan always fight on the same side. Easier to set with the clan window (Ctrl+K).");
page.addBooleanSetting("ShowNotifications", true, "Show notifications", "Show co-op messages on screen. They are always written to log.html.");

::BBCoop.getSetting <- function( _id )
{
	return ::BBCoop.Mod.ModSettings.getSetting(_id).getValue();
}

::BBCoop.getClan <- function()
{
	return ::BBCoop.getSetting("Clan");
}

// The DLCs this game has; both players need the same ones (they change the world map)
::BBCoop.getDLCs <- function()
{
	local ret = [];
	foreach (key, value in ::Const.DLC)
		if (typeof value == "bool" && value) ret.push(key);
	ret.sort();
	return ret;
}

// When we last heard from each player (any message counts; games send a heartbeat every 5s)
::BBCoop.Seen <- {};
::BBCoop.isOnline <- function( _name, _seconds = 20.0 )
{
	return (_name in ::BBCoop.Seen) && ::Time.getRealTimeF() - ::BBCoop.Seen[_name] <= _seconds;
}

::BBCoop.log <- function( _text )
{
	::logInfo("[BBCoop] " + _text);
}

::BBCoop.notify <- function( _text )
{
	::BBCoop.log(_text);
	if (::BBCoop.getSetting("ShowNotifications"))
		::BBCoop.Connection.showToast(_text);
}

// True while one of our text fields has focus: keys are for the field, not for game hotkeys
::BBCoop.Typing <- false;
foreach (state in ["scripts/states/world_state", "scripts/states/main_menu_state", "scripts/states/tactical_state"])
{
	::BBCoop.MH.hook(state, function(q) {
		q.onKeyInput = @(__original) function( _key )
		{
			if (::BBCoop.Typing) return true;
			return __original(_key);
		}

		// a state change drops focus without a blur event
		q.onInit = @(__original) function()
		{
			::BBCoop.Typing = false;
			return __original();
		}
	});
}

::include("bb_coop/ghosts.nut");
::include("bb_coop/roster.nut");
::include("bb_coop/battle.nut");
::include("bb_coop/remote.nut");
::include("bb_coop/join.nut");
::include("bb_coop/loot.nut");
::include("bb_coop/world.nut");

// Squirrel <-> JS bridge, connected when the main menu loads (same pattern MSU uses)
::Hooks.registerJS("ui/mods/bb_coop/bb_coop_connection.js");
::BBCoop.Connection <- ::new("scripts/mods/bb_coop/bb_coop_connection");
::MSU.UI.registerConnection(::BBCoop.Connection);

// Keybinds (rebindable under Mod Options > Keybinds)
::BBCoop.Mod.Keybinds.addSQKeybind("SendHello", "ctrl+h", ::MSU.Key.State.World | ::MSU.Key.State.Tactical, function() {
	::BBCoop.Connection.sendHello();
	return true;
}, "Send hello", null, "Send a test message to the other player.");

::BBCoop.Mod.Keybinds.addSQKeybind("RunPing", "ctrl+j", ::MSU.Key.State.All, function() {
	::BBCoop.Connection.runPing();
	return true;
}, "Run connection test", null, "Re-run the relay ping and WebSocket test.");

::BBCoop.Mod.Keybinds.addSQKeybind("JoinBattle", "ctrl+b", ::MSU.Key.State.World, function() {
	::BBCoop.Battle.acceptInvite(null);
	return true;
}, "Join nearby battle", null, "Join another player's battle as reinforcements when they are fighting nearby.");

::BBCoop.Mod.Keybinds.addSQKeybind("ClanWindow", "ctrl+k", ::MSU.Key.State.All, function() {
	::BBCoop.Connection.openClanWindow();
	return true;
}, "Clan window", null, "Create, join or leave a clan. Clanmates always fight on the same side.");
