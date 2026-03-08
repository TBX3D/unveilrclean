--* ══════════════════════════════════════════════════════════════════════
--* Libraries/Types.luau
--* ══════════════════════════════════════════════════════════════════════
--*
--* Provides three categorised lists of well-known Roblox / executor global
--* names that the spy sandbox uses to make informed decisions at runtime.
--*
--* ── Categories ────────────────────────────────────────────────────────
--*
--*  "table"    – global names whose runtime value is a Lua table (standard
--*               libraries, executor namespaces, shared globals, etc.).
--*               GetType() returns "table" for any name found in this list,
--*               allowing the emitter to choose dot-index syntax rather than
--*               bracket-index syntax in generated output.
--*
--*  "function" – global names that the Roblox / executor environment exposes
--*               as callable functions (both standard Lua and executor-only
--*               APIs).  Used by GetType() so that typeof/type checks on spy
--*               proxies of these names can return "function" rather than the
--*               default "userdata" fallback.
--*
--*  "Instance" – top-level Roblox DataModel roots (game, workspace, etc.).
--*               GetType() returns "Instance" for these so that
--*               type()/typeof() calls on their spy proxies yield the correct
--*               Roblox type string rather than "userdata".
--*
--* ── Usage ─────────────────────────────────────────────────────────────
--*
--*  Required by hi.luau via:
--*    local Success, T = pcall(function() return require("../Libraries/Types.luau") end)
--*    local Types = Success and T or require("./Libraries/Types.luau")
--*
--*  Consumed in GetType():
--*    for Type, List in next, Types do
--*        if Find(List, Name) then return Type end
--*    end
--*
--* ── Extension ─────────────────────────────────────────────────────────
--*
--*  To teach the spy about a new global or executor API, add the name
--*  string to the appropriate list below.  No other files need to change.

return {
	["table"] = {
		"syn",
		"syn.crypt",
		"syn.oth",
		"synapse",
		"krnl",
		"fluxus",
		"protosmasher",
		"debug",
		"bit",
		"Drawing",
		"WebSocket",
		"cache",
		"shared",
		"_G",
		"syn.crypto",
        "crypt",
        "crypto",
		"getfenv()",
		"getgenv()",
		"getrenv()",
		"http",
		"math",
		"string",
		"table",
		"os",
		"coroutine",
		"task",
		"buffer",
		"utf8",
		"bit32",
	},
	["function"] = {"getgenv","getrenv","getreg","getgc","getinstances","getnilinstances","getscripts","getloadedmodules","getconnections","firesignal","fireclickdetector","firetouchinterest","replicatesignal","getsenv","gettenv","getmenv","getcallingscript","syn.cache_replace","syn.cache_invalidate","syn.set_thread_identity","syn.get_thread_identity","syn.is_cached","syn.protect_gui","syn.unprotect_gui","syn.queue_on_teleport","syn.secure_call","syn.create_secure_function","syn.run_secure_function","syn.request","syn.write_clipboard","syn.is_beta","hookfunction","hookmetamethod","clonefunction","newcclosure","setstackhidden","isfunctionhooked","restorefunction","syn.crypt.base64","syn.crypt.hex","syn.crypt.lz4","syn.crypt.zstd","syn.crypt.derive","syn.crypt.url","syn.crypt.user.prompt","syn.crypt.sign.detached","syn.crypt.seal","syn.crypt.custom","mouse1click","mouse1press","mouse1release","mouse2click","mouse2press","mouse2release","mousemoveabs","mousemoverel","mousescroll","fireclickdetector","fireproximityprompt","firetouchinterest","iswindowactive","keypress","keyrelease","isnetworkowner","readfile","writefile","appendfile","loadfile","listfiles","isfile","isfolder","makefolder","delfolder","delfile","setclipboard","setrbxclipboard","setfflag","getnamecallmethod","setnamecallmethod","saveinstance","gethiddenproperty","sethiddenproperty","setsimulationradius","debug.getupvalue","debug.getupvalues","debug.getstack","debug.getproto","debug.getprotos","Drawing.new","Drawing.Fonts","http.request","WebSocket.connect","typeof","elapsedTime","UserSettings","warn","assert","error","gcinfo","getmetatable","setmetatable","ipairs","pairs","next","newproxy","pcall","xpcall","print","rawequal","rawget","rawset","rawlen","require","select","tick","time","coroutine.create","coroutine.resume","coroutine.yield","request","identifyexecutor","getexecutorname","queue_on_teleport","decompile","getscripthash","isscriptable","setscriptable","checkcaller","cloneref","compareinstances","getscriptclosure","debug.setstack","debug.setconstant","debug.getconstant","debug.getconstants"},
	["Instance"] = {
		"game", "workspace", "Game", "Workspace", "game.Workspace", "Game.Workspace"
	}
}
