// Settings shown under Mod Options > Battle Brothers Co-op
local page = ::BBCoop.Mod.ModSettings.addPage("General");
page.addStringSetting("RelayURL", "http://127.0.0.1:7777", "Relay URL", "Address of the co-op relay server. Both players must use the same one.");
page.addStringSetting("PlayerName", "Player", "Player name", "Shown to the other player. Must differ between the two players.");
page.addBooleanSetting("ShowPopups", true, "Show popups", "Show co-op messages in a popup. They are always written to log.html.");

::BBCoop.getSetting <- function( _id )
{
	return ::BBCoop.Mod.ModSettings.getSetting(_id).getValue();
}

::BBCoop.log <- function( _text )
{
	::logInfo("[BBCoop] " + _text);
}

::BBCoop.notify <- function( _text )
{
	::BBCoop.log(_text);
	if (::BBCoop.getSetting("ShowPopups"))
		::BBCoop.Mod.Debug.addPopupMessage(_text, ::MSU.Popup.State.Small);
}

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
