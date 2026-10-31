// Settings shown under Mod Options > Battle Brothers Co-op
local page = ::BBCoop.Mod.ModSettings.addPage("General");
page.addStringSetting("RelayURL", "http://127.0.0.1:7777", "Relay URL", "Address of the co-op relay server. Both players must use the same one.");
page.addStringSetting("SessionPassword", "", "Session password", "Only needed when the host started the relay with a password.");
page.addStringSetting("PlayerName", "Player", "Player name", "Shown to the other player. Must differ between the two players.");
local joinRange = page.addRangeSetting("JoinRange", 600, 100, 2000, 50, "Battle join range", "How close (in world units) your company must be to another player's battle to join it as reinforcements.");
joinRange.addCallback(function( _value ) { ::BBCoop.Battle.JoinRange = _value.tofloat(); });
page.addStringSetting("Clan", "", "Clan", "Players in the same clan always fight on the same side. Easier to set with the clan window (Ctrl+K).");
page.addStringSetting("HostSessionName", "", "Session name (hosting)", "Name of the session you host, shown to players who join. Empty: <your name>'s company.");
page.addRangeSetting("HostMaxPlayers", 8, 2, 8, 1, "Max players (hosting)", "How many players can be in a session you host, you included.");
page.addStringSetting("LastServerURL", "", "Last server", "Address of the last world you joined; the join window's Rejoin last server button uses it.");
page.addStringSetting("LastServerHost", "", "Last server's host", "Who hosted the last world you joined.");
page.addStringSetting("CoopSaves", "", "Co-op saves", "Save files used in multiplayer, marked Co-op in the Load screen. Filled in automatically.");
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

// Co-op saves (v0.14.0): a world that was hosted carries the flag BBCoopSave (the host's name),
// so every save of it is marked. Loading one outside of hosting shows a reminder.
// Set when the player used Multiplayer > Host a world in this game session
::BBCoop.HostChosen <- false;

::BBCoop.markCoopSave <- function( _host )
{
	if (!::World.Flags.has("BBCoopSave")) ::BBCoop.log("This world is now a co-op save.");
	::World.Flags.set("BBCoopSave", _host);
}

// Another real player (not the test bot) was heard from in the last 20 seconds
::BBCoop.othersOnline <- function()
{
	foreach (name, time in ::BBCoop.Seen)
		if (name != "Bot" && ::Time.getRealTimeF() - time <= 20.0) return true;
	return false;
}

// Save file names of co-op worlds, kept so the Load screen can label them (newest last, at most 200)
::BBCoop.getCoopSaves <- function()
{
	local text = ::BBCoop.getSetting("CoopSaves");
	local list = [];
	if (text == "") return list;
	local start = 0;
	while (true)
	{
		local i = text.find("|", start);
		if (i == null) { list.push(text.slice(start)); break; }
		list.push(text.slice(start, i));
		start = i + 1;
	}
	return list;
}

::BBCoop.rememberCoopSave <- function( _fileName )
{
	if (_fileName == null || _fileName == "") return;
	local list = ::BBCoop.getCoopSaves();
	local i = list.find(_fileName);
	if (i != null) list.remove(i);
	list.push(_fileName);
	while (list.len() > 200) list.remove(0);
	local text = "";
	foreach (j, name in list) text += (j == 0 ? "" : "|") + name;
	::BBCoop.Mod.ModSettings.getSetting("CoopSaves").set(text);
}

::BBCoop.isCoopSave <- function()
{
	return ::World.Flags.has("BBCoopSave");
}

::BBCoop.MH.hook("scripts/states/world_state", function(q) {
	// saves of a co-op world (manual, quick and autosaves all come through here) get the Co-op label
	q.saveCampaign = @(__original) function( _campaignFileName, _campaignLabel = null )
	{
		__original(_campaignFileName, _campaignLabel);
		try { if (::BBCoop.isCoopSave()) ::BBCoop.rememberCoopSave(_campaignFileName); }
		catch (error) { ::BBCoop.log("Remembering the co-op save failed: " + error); }
	}

	q.loadCampaign = @(__original) function( _campaignFileName )
	{
		__original(_campaignFileName);
		try
		{
			if (!::BBCoop.isCoopSave()) return;
			::BBCoop.rememberCoopSave(_campaignFileName);
			::BBCoop.log("Loaded co-op save " + _campaignFileName + " (hosted by " + ::World.Flags.get("BBCoopSave") + ")");
			if (!::BBCoop.HostChosen)
				::BBCoop.notify("This save is co-op specific. To play it with your friends, load it through Multiplayer > Host a world.");
		}
		catch (error)
		{
			::BBCoop.log("Checking for a co-op save failed: " + error);
		}
	}
});

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
::include("bb_coop/trade.nut");
::include("bb_coop/contract.nut");

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

::BBCoop.Mod.Keybinds.addSQKeybind("TradeWindow", "ctrl+t", ::MSU.Key.State.World, function() {
	::BBCoop.Connection.openTradeWindow();
	return true;
}, "Trade window", null, "Send items, crowns or brothers to another player whose company is next to yours.");

::BBCoop.Mod.Keybinds.addSQKeybind("Chat", "enter", ::MSU.Key.State.World, function() {
	::BBCoop.Connection.openChat();
	return true;
}, "Chat", null, "Open the chat on the world map. Enter sends, Escape closes.");

::BBCoop.Mod.Keybinds.addSQKeybind("ChatInBattle", "ctrl+enter", ::MSU.Key.State.Tactical, function() {
	::BBCoop.Connection.openChat();
	return true;
}, "Chat in battle", null, "Open the chat during a battle (plain Enter ends the turn there).");

::BBCoop.Mod.Keybinds.addSQKeybind("ShareContract", "ctrl+o", ::MSU.Key.State.World, function() {
	::BBCoop.Contract.share(false);
	return true;
}, "Share contract", null, "Ask online clanmates to help with your contract (taking a contract asks them too). Shows who helps, or whose contract you help with.");
