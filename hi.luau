--!christ is lord;
--! BEFORE YOU READ, MAKE SURE YOU USE PASCALCASE, I DONT WANNA LOOK IN A RANDOM PLACE AND SEE varMtrms = 1

--* ══════════════════════════════════════════════════════════════════════
--* About UnveilR
--* ══════════════════════════════════════════════════════════════════════
--*
--* UnveilR is a dynamic analysis / deobfuscation tool for Roblox Luau scripts.
--* It works by running an obfuscated script inside a heavily instrumented
--* sandbox environment and recording every operation it performs, then
--* re-emitting those operations as clean, readable Luau source code.
--*
--* ── High-level pipeline ────────────────────────────────────────────────
--*
--*  1. Pre-process (Obf)
--*     The target script is passed through an external Lua unparser
--*     (testing/prom/src/cli.lua) with optional hookOp instrumentation.
--*     hookOp inserts CHECKIF / CHECKAND / etc. call-sites into the AST so
--*     every conditional and logical expression can be observed at runtime.
--*
--*  2. Load & spy (Main → Spy)
--*     The pre-processed source is loaded with loadstring and its environment
--*     is replaced by a fully-instrumented proxy table called `Locked`.
--*     Every global access, call, index, newindex, and arithmetic operation
--*     is intercepted by a Spy proxy object whose metamethods write a
--*     corresponding line into the Output buffer.
--*
--*  3. Emit (Beautify / Append)
--*     As the script runs, each intercepted operation is translated back into
--*     readable Luau code via Beautify() and appended to Output[].
--*     Variable names are derived from the originating expression so the
--*     output is self-documenting (e.g. a call to GetService("Players") becomes
--*     `local Players = game:GetService("Players")`).
--*
--*  4. Post-process (minifier / varRenamer)
--*     After execution the Output buffer is walked one more time.
--*     Single-use variables are inlined, dead assignments are removed, and
--*     (optionally) variable names are replaced with more descriptive ones.
--*
--*  5. Write result (Decode)
--*     The final cleaned string is written to the output file (default
--*     out2.lua) with a small metadata header.
--*
--* ── Supported obfuscators ──────────────────────────────────────────────
--*
--*  • Standard Luau obfuscation patterns (constant encoding, name mangling)
--*  • MoonSec V3  (with anti-tamper and partial constant-protection support)
--*  • Luraph      (known issues — see P1 in the task list below)
--*  • JayFuscator (detection-safe output is a WIP — see P3 below)
--*
--* ── Key design rules ───────────────────────────────────────────────────
--*
--*  • All identifiers use PascalCase (enforced by the style comment above).
--*  • Standard library globals are localised at the top of the file so that
--*    obfuscated scripts cannot shadow them via _ENV manipulation.
--*  • The Operations counter (OpCount / max_ops) guards against infinite
--*    loops inside obfuscated scripts; the output is flushed before aborting.

--* ══════════════════════════════════════════════════════════════════════
--* Tasks  (ordered by priority / usefulness, highest first)
--* ══════════════════════════════════════════════════════════════════════
--*
--* ── Completed ─────────────────────────────────────────────────────────
--* [DONE] make "not not" get auto removed
--* [DONE] fix too many operations preventing output from being sent
--* [DONE] Add rawget(a/b, "V") in comparators (a < b, a > b)
--* [DONE] Maybe fix spy_exec_only by returning a safe env with getfenv() returning the spied env?
--* [DONE] Fix debug.getinfo
--* [DONE] Make CHECKAND work
--* [DONE] Fix indenting (nested for-loops now save/restore Tab relatively)
--* [DONE] Make elseif also call CHECKIF (added CHECKELSEIF via shared CheckCondition helper)
--* [DONE] Fix max operations not always working (__newindex now calls OpCountCheck() properly)
--* [DONE] Fix addresses for functions/tables (GetAddress now prefixes ALL known types)
--* [DONE] Fix recursive tables (IsRecursive check in Beautify handles all cycle types)
--* [DONE] Add PureVM obfuscator support (auto-disable hookOp, pass-through env,
--*        debug.info, timeout, op-skip for PureVM scripts like Luraph without loadstring)
--*
--* ── P1 · CRITICAL — complete script breakage on a major obfuscator ────
--*
--* [PARTIAL] Fix luraph not working with hookop + for-loop breakage
--*          WHY: Luraph is one of the most-used Roblox obfuscators. hookOp currently
--*               causes scripts to completely break (especially for-loops), so the tool
--*               produces zero useful output for a huge share of real-world scripts.
--*          PROGRESS: PureVM detection now auto-disables hookOp for Luraph scripts,
--*               sidestepping the for-loop breakage entirely.  The hookOp rewrite
--*               itself is still broken for for-loops if manually forced.
--*          Sub-steps:
--*            1. [DONE]   Detect PureVM / Luraph (IsLikelyVMObfuscator AND NOT HasDynamicLoader)
--*                        and auto-disable hookOp in Obf() so the dispatch loop is preserved.
--*            2. [DONE]   Pass debug.info through directly in Hooks.debug so Luraph's
--*                        anti-tamper introspection returns real data instead of a spy proxy.
--*            3. [DONE]   Extend CheckBootstrapTimeout and Locked.__index to apply a default
--*                        30 s execution cap for PureVM scripts (IsPureVMObfuscator flag).
--*            4. [EASY]   Isolate a minimal luraph for-loop snippet that reproduces the break
--*            5. [MEDIUM] Trace how hookOp rewrites numeric vs generic for-loops
--*            6. [MEDIUM] Identify which hookOp transformation(s) break luraph globally
--*            7. [MEDIUM] Fix for-loop rewrite in hookOp to preserve semantics
--*            8. [MEDIUM] Add a broader luraph-compatibility guard in the hookOp transform
--*            9. [MEDIUM] Test with the juju.lol luraph sample end-to-end
--*
--* ── P2 · HIGH — misleading output on another major obfuscator ─────────
--*
--* [HARD]   Fix moonsec constant protection not working
--*          WHY: MoonSec is also extremely common.  Without constant protection the
--*               decrypted constants are missing from output, making it actively
--*               misleading rather than merely incomplete.
--*          Sub-steps:
--*            1. [EASY]   Verify MoonSecCP flag detection (Source:find("//")) fires correctly
--*            2. [MEDIUM] Add debug prints to trace which keys the MoonSec CP env indexes
--*            3. [MEDIUM] Implement constant decryption pass in the MoonSec env branch
--*            4. [HARD]   Integrate decrypted constants back into the spy output
--*
--* ── P3 · HIGH — output safety / tool reliability ──────────────────────
--*
--* [HARD]   Fix unparser.lua making some scripts detected (jayfuscator.txt)
--*          WHY: If the unparser's output triggers anti-cheat / detection, the whole
--*               point of the tool is undermined for those scripts.
--*          Sub-steps:
--*            1. [EASY]   Run jayfuscator.txt through the tool; diff against known-safe output
--*            2. [MEDIUM] Identify which string literals / identifiers trigger detection
--*            3. [MEDIUM] Rotate or rename detection-triggering identifiers in the unparser
--*            4. [MEDIUM] Re-run and confirm the output no longer triggers detection
--*
--* ── P4 · MEDIUM — power-user feature (partially done) ─────────────────
--*
--* [HARD]   add HOOKEXP() — hook a SPECIFIC expression by ID
--*          WHY: hookexpr(id, val) already exists; HOOKEXP is the emitted counterpart
--*               that lets users drive values without touching the source.
--*          Sub-steps:
--*            1. [DONE]   hookexpr(id, val) already exists in Hooks for pre-hooking by expression ID
--*            2. [MEDIUM] Define HOOKEXP(id, callback) that is EMITTED into the generated output
--*            3. [MEDIUM] Emit `HOOKEXP(expressionId, function() ... end)` at the right call sites
--*            4. [MEDIUM] Wire the runtime so HOOKEXP callbacks override the expression value
--*
--* ── P5 · MEDIUM — reliability for specific scripts ────────────────────
--*
--* [MEDIUM] Fix unparser breaking scripts/nicuse.lua
--*          WHY: A reproducible single-script failure; worth fixing once the higher-priority
--*               issues are resolved.
--*          Sub-steps:
--*            1. [EASY]   Run nicuse.lua through the unparser and capture the exact error/diff
--*            2. [EASY]   Identify which unparser transformation breaks the script
--*            3. [MEDIUM] Add a targeted fix or exclusion in the unparser for that pattern
--*
--* ── P6 · LOW — needs identification before work can start ──────────────
--*
--* [HARD]   Fix that one obfuscator not working
--*          WHY: Too vague to prioritize further until the obfuscator is identified.
--*          Sub-steps:
--*            1. [EASY]   Identify and document which obfuscator it is
--*            2. [MEDIUM] Reproduce the failure and capture the error/traceback
--*            3. [HARD]   Fix the env / spy to handle that obfuscator's specific patterns

--* LOCALIZATION:

local loadstring = require("@lune/luau").load
local fs = require("@lune/fs")

local Process = require("@lune/process")
task = require("@lune/task")

local Setmetatable = setmetatable
local Clock = os.clock
local Typeof, Tostring, Tonumber, Next, Unpack, RawEqual, RawGet = typeof, tostring, tonumber, next, unpack, rawequal, rawget
local Gsub, Rep, Format, Sub, Match, Split, Char, Byte, Lower, Upper = string.gsub, string.rep, string.format, string.sub, string.match, string.split, string.char, string.byte, string.lower, string.upper
local Find, Insert, Concat, Move, Pack, Remove = table.find, table.insert, table.concat, table.move, table.pack, table.remove
local Wrap, Yield = coroutine.wrap, coroutine.yield
local DebugInfo = debug.info

local Alphabet = Split("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789", "")

local next = next

local _print = print
print = function(...)
    local function Color(txt, code)
        return `\27[{code}m{txt}\27[0m`
    end

    local Line, Name = DebugInfo(2, "ln")
    local ColoredName = Color(Name == "" and "???" or Name, 32)
    local ColorLine = Color(`line {Line}`, 35)

    local FinalText = `[ {ColoredName} @ {ColorLine} ]:`

    _print(FinalText, ...)
end

local function GenerateId(len)
    local txt = ''
    for i = 1,len or 6 do
        txt ..= Alphabet[math.random(1, #Alphabet)]
    end
    return txt
end

local function RE_Safe(Str, FullChars)
    local Chars = (FullChars and "%()[].-+^*$?" or "%"):split("")
    for _, char in next, Chars do
        Str = Str:gsub("%" .. char, "%%" .. (char == "%" and "%" or "") .. char)
    end
    return Str
end

local function Strip(Str, IgnoreStart)
    local start_idx, end_idx = 1, #Str
    local Split = Str:split("")

    local Spaces = { [" "] = true, ["\t"] = true, ["\r"] = true, ["\n"] = true }

    if not IgnoreStart then for i = 1, #Split do if not Spaces[Split[i]] then start_idx = i break end end end
    for i = #Split, 1, -1 do if not Spaces[Split[i]] then end_idx = i break end end

    return Str:sub(start_idx, end_idx)
end

local TraceId = GenerateId(7)
--local Types = {}

local FileSystem = {
    read = fs.readFile,
    write = fs.writeFile
}

--* ── Settings ──────────────────────────────────────────────────────────
--* All fields can be overridden from the command line with --key=value.
--*
--*  hookOp        (bool)   Pre-process the source through the Lua unparser with
--*                         --hookOp to inject CHECKIF/CHECKAND/... call-sites.
--*                         Disable if the target obfuscator (e.g. Luraph)
--*                         breaks under hookOp transforms.
--*  hookOpValue   (string) Controls what spied values evaluate to inside
--*                         hook-inserted expressions: "spy" means use the
--*                         actual Spy proxy; anything else is a literal value.
--*  explore_funcs (bool)   When true, nested functions are decompiled
--*                         recursively by calling Main() again. When false,
--*                         an inline comment placeholder is emitted instead.
--*  spy_exec_only (bool)   Restrict active spying to names in ExecEnv
--*                         (executor / Roblox globals). Unknown globals are
--*                         returned as nil rather than creating spy entries,
--*                         which keeps the output focused on meaningful calls.
--*  minifier      (bool)   Run the post-execution cleanup pass: inline
--*                         single-use variables, drop zero-use assignments,
--*                         and collapse multiple blank lines.
--*  varRenamer    (bool)   Replace auto-generated var<N> names with
--*                         descriptive names derived from the expression.
--*                         Disabled by default because it can produce
--*                         incorrect names for some patterns.
--*  raw           (bool)   Skip the Obf() pre-process step and feed the
--*                         source directly to the Lune sandbox. Faster but
--*                         CHECKIF / CHECKAND hooks will not be present.
--*  max_ops       (number) Hard cap on the number of intercepted operations.
--*                         When reached the current Output is flushed and an
--*                         error is raised to prevent runaway execution.
--*  max_while_count (number) Separate cap for CHECKWHILE iterations so that
--*                         tight while-loops do not exhaust max_ops before
--*                         meaningful output is produced.
--*  saveFails     (bool)   Write Output to disk after every Append() call.
--*                         Very slow but ensures partial output is preserved
--*                         even when the script crashes mid-execution.
--*  env_index     (bool)   Emit a `local _ = <name>` line every time the
--*                         sandboxed script reads an untracked global. Useful
--*                         for debugging which globals a script accesses.
local Settings = {
    hookOpValue = "spy",
    hookOp = true,
    explore_funcs = true,
    spy_exec_only = true,
    minifier = true,
    varRenamer = false,
    raw = false, --> Loads stuff instantly
    max_ops = 10_500, -- the max number of operations the script can perform
    max_while_count = 100_000,
    saveFails = false,
    env_index = false,
    print_env_hits = false,
    print_spy_hits = false,
    max_spy_hits = 0,
    -- 0 = disabled (no cap).  For PureVM obfuscators (Luraph-style, no loadstring)
    -- this is automatically raised to 5 s so a stuck dispatch loop cannot run
    -- forever.  Override with --max_bootstrap_seconds=<n>.
    max_bootstrap_seconds = 0
}

local function StrToValue(Str)
    if Str == "false" then return false
    elseif Str == "true" then return true
    elseif Str == "nil" then return nil
    elseif tonumber(Str) then return tonumber(Str)
    else return Str end
end

for index, arg in Process.args do
    local k, v = Match(arg, "--([%w_]+)=(.+)")

    if v then -- --key=value flag (e.g. --outfile=out.lua)
        Settings[k] = StrToValue(v)
    elseif Sub(arg, 1, 2) == "--" then -- boolean flag (e.g. --hookOp, --raw)
        local Arg = Sub(arg, 3) -- strip the leading "--"
        Settings[Arg] = true
    else -- positional argument: treat as the input file path
        Settings.input = Settings.input or arg
    end
end

local Top = {
    add_if_comment = false
}

local Version = "1.1.0"

local ExecEnv = {"game";"workspace";"script";"Instance";"Enum";"Vector3";"Vector2";"Vector3int16";"Vector2int16";"UDim";"UDim2";"CFrame";"Color3";"BrickColor";"Ray";"Axes";"Faces";"Region3";"Region3int16";"Rect";"NumberRange";"PhysicalProperties";"cache";"cloneref";"compareinstances";"checkcaller";"clonefunction";"getcallingscript";"getscriptclosure";"hookfunction";"iscclosure";"islclosure";"isexecutorclosure";"loadstring";"newcclosure";"rconsoleclear";"rconsolecreate";"rconsoledestroy";"rconsoleinput";"rconsoleprint";"rconsolesettitle";"crypt";"debug";"readfile";"listfiles";"writefile";"makefolder";"appendfile";"isfile";"isfolder";"delfolder";"delfile";"loadfile";"dofile";"isrbxactive";"mouse1click";"mouse1press";"mouse1release";"mouse2click";"mouse2press";"mouse2release";"mousemoveabs";"mousemoverel";"mousescroll";"fireclickdetector";"getcallbackvalue";"getconnections";"getcustomasset";"gethiddenproperty";"sethiddenproperty";"syn";"gethui";"getinstances";"getnilinstances";"isscriptable";"setscriptable";"setrbxclipboard";"getrawmetatable";"hookmetamethod";"getnamecallmethod";"isreadonly";"setrawmetatable";"setreadonly";"identifyexecutor";"lz4compress";"lz4decompress";"messagebox";"request";"setclipboard";"setfpscap";"getgc";"getgenv";"getloadedmodules";"getrenv";"getrunningscripts";"getscriptbytecode";"getscripthash";"getscripts";"getsenv";"getthreadidentity";"setthreadidentity";"Drawing";"isrenderobj";"getrenderproperty";"setrenderproperty";"cleardrawcache";"WebSocket";"getfenv";"coroutine";"math";"string";"table";"os";"utf8";"bit32";"buffer";"TweenInfo";"RaycastParams";"OverlapParams";"Random";"ColorSequence";"ColorSequenceKeypoint";"NumberSequenceKeypoint";"NumberSequence";"SharedTable";"shared";"Font";"elapsedTime";"settings";"tick";"time";"typeof";"UserSettings";"version","warn";"plugin";"shared";"assert";"error";"gcinfo";"getmetatable";"ipairs";"newproxy";"next";"pairs";"pcall";"print";"rawequal";"rawget";"rawlen";"rawset";"require";"select";"setmetatable";"tostring";"unpack";"xpcall";"_G";"_VERSION";"Game","Workspace";"gethwid";"delay";"getexecutorname";"queue_on_teleport";"fireproximityprompt";"firetouchinterest";"keypress";"keyrelease";"iswindowactive";"saveinstance";"decompile";"setfflag";"rconsoleinfo";"rconsolewarn";"rconsoleerror";"rconsolename";"consolecreate";"consoledestroy";"consoleinput";"consoleprint";"consoleclear";"consolesettitle"}

local newcclosure = function(Function)
    local a = Wrap(function(...)
        local b = {Yield()}
        while true do
            b = {Yield(Function(Unpack(b)))}
        end
    end)
    a()
    return a
end

local NewCClosure = newcclosure

-- Internal[]  : maps Spy-proxy objects → their canonical path string (e.g. "game.Players")
-- Addresses[] : stable fake memory addresses for functions/tables shown in output
-- ParamsUsed[]: tracks which arg<N> spy params were actually accessed during a call
local Internal, Addresses, ParamsUsed = {}, {}, {}

-- Values[varName] = { Value, Tag, Line, Usage }
--   Value : the source expression the variable was assigned from
--   Tag   : a category tag (__call, __index, __arth, __eq, __comp, __len, __while, __newindex)
--   Line  : the index into Output[] where the assignment was emitted
--   Usage : how many times this variable has been read back; drives the inliner
local Values = {}
-- Output[] collects lines of emitted Luau source code in order.
-- After Main() returns the caller joins it with "\n" to form the final output string.
local Output = {}
-- Id is the monotonically-increasing counter used to generate unique var<N> names.
-- ExpressionId counts every hooked expression so that hookexpr(id, val) can target
-- a specific boolean expression by index.
-- ExpressionHooks[id] = value overrides the truth-value of expression #id at runtime.
local Id, ExpressionId, ExpressionHooks = 0, 0, {}

-- OriginalSource holds the raw file content read by Decode() BEFORE the hookOp
-- pre-processing step (Obf()) runs.  Main() uses it for MoonSec signature detection
-- so that hookOp rewrites of the AST cannot invalidate the pattern search.
local OriginalSource

local Success, T = pcall(function()
    return require("../Libraries/Types")
end)

local Types = Success and T or require("./Libraries/Types")

-- GetActualPath: follow the Values chain to resolve aliased variable names.
-- When variable A is defined as the value of variable B, reading A should
-- ultimately yield the root expression, not a chain of intermediate names.
local function GetActualPath(Path)
    local Result = Path;

    while true do
        local Value = Values[Result]
        if not Value then break end
        Result = Value.Value
    end

    return Result
end

-- GetAddress: produce or recall a stable fake hex address for a spied value P.
-- The address is shown in the output wherever a raw tostring() of a function or
-- table would normally produce something like "function: 0x55a8…".  A consistent
-- fake address (per P) makes diffs easier to read across multiple runs.
local function GetAddress(P, T)
    local Address = Addresses[P] or Format('%s0x%s', T and `{T}: ` or '', Match(tostring(function()end), "0x([A-Fa-f0-9]+)"))

    Addresses[P] = Address
    return Address
end

-- GetType: return the semantic type of Name as it would appear in Luau.
-- For non-string values this is just typeof().  For string names that match a
-- known global (e.g. "game", "math", "Drawing") the type from Types.luau is
-- returned ("Instance", "table", etc.) so the emitter can make informed decisions.
local function GetType(Name)
    local OldType = Typeof(Name)
    if OldType ~= "string" then
        return OldType
    end

    for Type, List in next, Types do
        if Find(List, Name) then return Type end
    end
end

--* ── VM Obfuscator Detection ──────────────────────────────────────────
--* IsLikelyVMObfuscator: heuristic check for VM-interpreter obfuscators.
--* Scores several signals and returns true only when 3 or more are present.
--* HasDynamicLoader: returns true when the source contains a dynamic loader
--* call (loadstring or a bare load() call), which VM obfuscators always use.
--* IsPureVMObfuscator: returns true when the source looks like a VM
--* obfuscator but does NOT contain loadstring/load – a "pure" VM that
--* interprets bytecode directly without ever calling loadstring.
local function IsLikelyVMObfuscator(Source)
    if Typeof(Source) ~= "string" then
        return false
    end

    local NewLines = select(2, Gsub(Source, "\n", ""))

    if #Source < 100_000 or NewLines > 160 then
        return false
    end

    local Score = 0

    -- Check for return({ opener anywhere in the source (not just the start)
    -- so that scripts with leading block-comment headers still match.
    if string.find(Source, "return({", 1, true) then Score += 1 end
    if string.find(Source, "string.pack", 1, true) then Score += 1 end
    if string.find(Source, "string.unpack", 1, true) then Score += 1 end
    if string.find(Source, "coroutine.wrap", 1, true) then Score += 1 end
    if string.find(Source, "table.create", 1, true) then Score += 1 end
    if string.find(Source, "bit32.", 1, true) then Score += 1 end

    return Score >= 3
end

local function HasDynamicLoader(Source)
    if Typeof(Source) ~= "string" then
        return false
    end

    if string.find(Source, "loadstring", 1, true) then
        return true
    end

    return Match(Source, "^%s*load%s*%(") ~= nil or Match(Source, "[^%w_]load%s*%(") ~= nil
end

local function IsPureVMObfuscator(Source)
    return IsLikelyVMObfuscator(Source) and not HasDynamicLoader(Source)
end

--* ── Main ─────────────────────────────────────────────────────────────
--* Core dynamic-analysis engine.
--*
--* Parameters:
--*   Source        – either a file-path string (loaded with loadstring) or an
--*                   already-loaded function object.
--*   NestCount     – recursion depth; incremented each time an inner function
--*                   is decompiled by Beautify's ["function"] handler.
--*                   Used to suffix var names (var3_1, var3_2 …) so names
--*                   from nested scopes do not clash with outer ones.
--*   CurrentIndent – number of leading 4-space indent levels for Append().
--*   Original      – when true this is the top-level call; the return value
--*                   of the script is added to Output as a `return` line.
--*
--* Returns: (outputString, returnValueLine)
--*   outputString     – all emitted lines joined with "\n"
--*   returnValueLine  – the final `return …` or `error(…)` line, or ""
--*
--* Expectations:
--*   • Source must be valid Luau (after Obf() pre-processing).
--*   • The function modifies the module-level Output / Values / Id / ExpressionId
--*     tables; callers that capture nested output swap these with fresh tables
--*     (see Beautify's ["function"] handler).
--*   • OpCount is reset to 0 for each call, so nested invocations have their
--*     own independent operation budget.
local function Main(Source, NestCount, CurrentIndent, Original)
    local OutFile = Settings.outfile or "out2.lua"

    CurrentIndent = CurrentIndent or 0
    NestCount = NestCount or 0

    local LoopCount, OpCount = 0, 0

    local BrokenLoops = {}
    local LoopHits = {}
    local EnvHits = {}
    local SpyHits = {}
    -- IsPureVMObfuscator: true when the source looks like a VM obfuscator whose
    -- interpreter loop is entirely self-contained (Luraph-style) – i.e. it never
    -- calls loadstring / load() to load the deobfuscated payload.  For these
    -- scripts hookOp's CHECKWHILE wrappers would kill the dispatch loop after
    -- max_while_count iterations, producing no useful output.
    local IsPureVMObfuscator = Settings.spy_exec_only and IsLikelyVMObfuscator(Source) and not HasDynamicLoader(Source)
    local ConcreteBootstrap = Settings.spy_exec_only and IsLikelyVMObfuscator(Source) and HasDynamicLoader(Source)
    -- Legacy aliases: earlier iterations of PureVM support used different names.
    local PureVM = IsPureVMObfuscator
    local PureVMObfuscator = IsPureVMObfuscator
    local BootstrapStartedAt = Clock()
    -- Set to true just before a CheckBootstrapTimeout error fires so the
    -- result-handler below can distinguish our analysis timeout from any
    -- real error thrown by the obfuscated script.
    local BootstrapTimedOut = false

    -- PureVM obfuscators (e.g. Luraph without loadstring) have no transition
    -- point where the bootstrap ends.  Apply a default timeout and raise the
    -- operation cap so the VM can finish executing before we hit the limit.
    if IsPureVMObfuscator then
        if not Settings.max_bootstrap_seconds or Settings.max_bootstrap_seconds == 0 then
            Settings.max_bootstrap_seconds = 5
        end
        -- 10_500 is the default max_ops for normal scripts; raise it for
        -- PureVM since the VM interpreter generates far more operations.
        if Settings.max_ops <= 10_500 then
            Settings.max_ops = 500_000
        end
        print("PureVM obfuscator detected – hookOp disabled, bootstrap timeout set to", Settings.max_bootstrap_seconds, "s")
    end

    local function OpCountCheck()
        if OpCount >= Settings.max_ops then
            local OutFile = Settings.outfile or "out2.lua"
            task.spawn(fs.writeFile, OutFile, Concat(Output, "\n"))
            error("Too many operations.", 2)
        end
    end

    local Tab = Rep("    ", CurrentIndent)
    local ParamSuffix = NestCount == 0 and "" or `_{NestCount}`

    local function IsInternal(x)
        local i = Internal[x]
        if i then Use(i, "__tostring") end
        return i
    end

    local function GetVarID() Id += 1 return `var{Id}{ParamSuffix}` end
    local function Append(a)
        --print("Append", a)
        Output[#Output+1] = Tab .. a
        if Settings.saveFails and Original then task.spawn(fs.writeFile, OutFile, Concat(Output, "\n")) end --> might be VERY horrible but it gets the job done 
    end

    local function TrackEnvHit(Key)
        if not Settings.print_env_hits then
            return
        end

        EnvHits[Key] = (EnvHits[Key] or 0) + 1
    end

    local function TrackSpyHit(Path)
        local HasLimit = Settings.max_spy_hits and Settings.max_spy_hits > 0

        if not Settings.print_spy_hits then
            if HasLimit then
                SpyHits[Path] = (SpyHits[Path] or 0) + 1

                if SpyHits[Path] >= Settings.max_spy_hits then
                    error(`Spy path flood: {Path}`, 2)
                end
            end

            return
        end

        SpyHits[Path] = (SpyHits[Path] or 0) + 1

        if HasLimit and SpyHits[Path] >= Settings.max_spy_hits then
            error(`Spy path flood: {Path}`, 2)
        end
    end

    -- Effective bootstrap timeout: honour the user-supplied max_bootstrap_seconds
    -- when it is non-zero; otherwise default to 30 seconds when running in
    -- PureVMObfuscator mode (no loadstring) so that a VM game-loop cannot spin
    -- indefinitely.  ConcreteBootstrap scripts that call loadstring eventually
    -- get intercepted, so they keep 0 (disabled) as their default.
    local EffectiveBootstrapSeconds = Settings.max_bootstrap_seconds
    if EffectiveBootstrapSeconds == 0 and PureVMObfuscator then
        EffectiveBootstrapSeconds = 30
    end

    local function CheckBootstrapTimeout()
        if not ConcreteBootstrap and not IsPureVMObfuscator then
            return
        end

        if Settings.max_bootstrap_seconds and Settings.max_bootstrap_seconds > 0 and Clock() - BootstrapStartedAt >= Settings.max_bootstrap_seconds then
            BootstrapTimedOut = true
            if ConcreteBootstrap then
                error("VM bootstrap timed out before reaching load/loadstring. This script likely needs a VM-specific devirtualizer.", 0)
            else
                error(`PureVM execution timed out after {Settings.max_bootstrap_seconds}s. Partial output was saved.`, 0)
            end
        end
    end
    --* ── Beautify ──────────────────────────────────────────────────────────
    --* Convert a runtime Lua/Luau value back into a readable source-code string.
    --*
    --* Data   – the value to convert (any type).
    --* Indent – current indentation level (used for multi-line tables/functions).
    --* Args   – optional table of extra options:
    --*            Args.FuncName    – if set, emit `function <FuncName>(…)` rather
    --*                               than anonymous `function(…)`.
    --*            Args.Minify      – when true, table entries are placed on one
    --*                               line with minimal whitespace.
    --*            Args.FromBeautify– set when called recursively so indenting is
    --*                               relative to the current context.
    --*
    --* Type dispatch:
    --*   "table"    → recursively Beautify each key/value; detect recursive
    --*                tables and emit `{ "recursive table" }` to avoid infinite
    --*                loops; check Internal[] first to see if this table is a
    --*                known spy proxy.
    --*   "string"   → wrap in double quotes, escape control chars & backslashes;
    --*                truncate strings longer than 1000 chars with a byte count.
    --*   "function" → call Main() recursively (NestCount+1) to decompile the
    --*                function body; collect ParamsUsed to build the param list;
    --*                C closures are emitted as their name or a comment stub.
    --*   "number"   → normalise weird floats; emit math.huge / -math.huge for
    --*                IEEE infinities.
    --*   "userdata" → if it has a metatable (i.e. is a newproxy()) emit
    --*                `get_user_data(<mt>)`; otherwise tostring it.
    --*   (other)    → tostring fallback.
    --*
    --* Returns: the string representation (and optionally a function name).
    function Beautify(Data, Indent, Args)
        Indent = Indent or CurrentIndent

        Args = Typeof(Args) == "table" and Args or {}

        local FuncName = Args.FuncName
        local Minify = Args.Minify

        local function IsRecursive(t)
            local visited = {}

            local function check(tbl)
                if visited[tbl] then
                    return true
                end

                visited[tbl] = true

                for _, v in next, tbl do
                    if type(v) == "table" then
                        if check(v) then
                            return true
                        end
                    end
                end

                visited[tbl] = nil
                return false
            end

            return check(t)
        end

        local Types = {
            ["table"] = function() --> x:CreateWindow(args)
                --print("yo",debug.traceback())
                local Int = IsInternal(Data)
                if Int then return Int end

                if IsRecursive(Data) then return "{ \"recursive table\" }" end

                local Options = {Minify = true}

                local Result = "{"
                local NewLine, Tab = Minify and " " or "\n", Minify and "" or Rep("    ", Indent)
                local Count, Dict = 0

                for k, v in Next, Data do -- Next to bypass __iter
                    Count += 1
                    
                    local Base = `{NewLine}{Tab}`
                    local Fixed = IsWeird(k) and `[{Beautify(k, Indent, Options)}]` or k
                    local Key = Count == k and not Dict and Base or `{Base}{Fixed} = ` --> Support for arrays

                    if Count ~= k then Dict = true end

                    Result ..= `{Key}{Beautify(v, Indent + 1, {FromBeautify = true})},`
                end

                local End = Minify and " }" or `\n{Rep("    ", Indent - 1)}}`

                return Count == 0 and "{}" or Sub(Result, 1, -2) .. End
            end,
            ["string"] = function()
                local Replaced = Gsub(Data, "\\", "\\\\")

                Replaced = Gsub(Replaced, "[\n\b\t\v\f\"\r]", {
                    ["\n"] = "\\n", ["\b"] = "\\b", ["\t"] = "\\t", ["\v"] = "\\v", ["\f"] = "\\f", ["\""] = "\\\"", ["\r"] = "\\r"
                })

                if #Replaced > 1000 then
                    Replaced = Sub(Replaced, 1, 1000) .. `..( {#Replaced - 1000} bytes left)` --> heh
                end

                return ('"' .. Replaced .. '"')
            end,
            ["function"] = function()
                local S, N = DebugInfo(Data, "sn")
                N = FuncName or N

                if not Settings.explore_funcs then return `function()--[[enable explore funcs to view this function]]end`, N end
                if S == "[C]" then return N == "" and "(function()--[[cclosure]]end)" or N, N end

                --^^ ts is just for stuff like pcall, explore funcs and func names

                local Old, OldParams = Output, ParamsUsed
                Output, ParamsUsed = {}, {} --> so we can capture everything new the code runs
            
                local CallBody, Return = Main(Data, NestCount + 1, Indent)
                local FunctionIndent = Args.FromBeautify and Rep("    ", Indent) or Rep(" ", 4)

                local Sorted = {}
                for k in next, ParamsUsed do
                    table.insert(Sorted, k)
                end

                table.sort(Sorted, function(a, b)
                    return (Tonumber(Match(a, "arg(%d+)")) or math.huge) < (Tonumber(Match(b, "arg(%d+)")) or math.huge)
                end)

                local ParamList = {}
                for _, key in next, Sorted do
                    Insert(ParamList, ParamsUsed[key] and key or "_")
                end

                for i = #ParamList, 1, -1 do
                    if ParamList[i] == "_" then
                        Remove(ParamList, i)
                    else
                        break
                    end
                end

                local Params = Concat(ParamList, ", ")

                local Body = '';
                if FuncName then
                    if IsWeird(FuncName) then
                        Body ..= `{Index(FuncName)} = function`
                    else
                        Body ..= `function {FuncName}`
                    end
                else
                    Body ..= "function"
                end

                Body ..= `({Params})\n`

                if #CallBody > 0 then
                    Output = {}

                    for _, Line in next, Split(CallBody, "\n") do
                        Insert(Output, Line)
                    end
                end

                for _, v in next, Output do Body ..= FunctionIndent .. v .. "\n" end

                if Return then Body ..= FunctionIndent .. Return .. "\n" end --> return value

                -- LIMITATION: The multi-assignment on the next line is doing two things at once:
                -- (1) It appends "end" (with correct closing indent) to Body.
                -- (2) It restores the module-level Output and ParamsUsed tables from the
                --     snapshots taken before this nested Main() call.
                -- The assignment order in Luau (right-hand side fully evaluated before any
                -- assignment) means Old/OldParams are read before Output/ParamsUsed are
                -- overwritten, which makes the restore correct.  Moving this to two separate
                -- statements would also work but this compact form relies on that evaluation
                -- order being guaranteed.
                Body, Output, ParamsUsed = Body .. (Indent > 1 and Rep("    ", Indent - 1) or "") .. "end", Old, OldParams

                return Body
            end,
            ["userdata"] = function() -- error i guess?
                local mt = getmetatable(Data)
                if mt then --> newproxy()
                    return `get_user_data({Beautify(mt, Indent + 1)})`
                end

                return Beautify(Tostring(Data))
            end,
            ["number"] = function()
                if Tonumber(Format("%.4f", Data)) ~= Data then Data = math.ceil(Data) end --> weird floats
                local str = Tostring(Data)
                return str == "-inf" and "-math.huge" or str == "inf" and "math.huge" or str
            end
        }

        local Value = Types[Typeof(Data)]
        local Return = Value and {Value()} or {Tostring(Data)}

        return Unpack(Return)
    end

    local function BeautifyTuple(...)
        local Out = ""
        local Args = Pack(...)
        
        for i = 1, Args.n do
            Out ..= `{Beautify(Args[i], CurrentIndent + 1)}, `
        end

        return Sub(Out, 1, -3)
    end

    function IsWeird(Key)
        return Key == "" or Match(Key, "[^_%w]") or Match(Key, "%d") == Sub(Key, 1, 1) --> Has non english character or starts with a number
    end

    -- FIX: Index() now handles four key shapes:
    --   • Key is a known Spy proxy path (IsInternal)      → emits Path[proxyName]
    --   • Key is a non-string runtime value (table, etc.) → emits Path[Beautify(Key)]
    --   • Key is a "weird" string (non-identifier chars or leading digit) → emits Path["key"]
    --   • Key is a plain identifier string                → emits Path.key
    -- Previously, a non-string Key that was not registered in Internal[] would fall
    -- through to IsWeird()/string operations on a non-string, producing wrong output.
    function Index(Key, Path)
        local Beauty = IsInternal(Key)
        if Beauty then
            -- When Path itself is nil and Key is an internal proxy, the emitted
            -- expression is just the proxy name rather than a qualified index.
            -- This preserves existing behaviour; a proper fix would require tracking
            -- the container alongside the key.
            return Path and `{Path}[{Beauty}]` or Beauty --! a[b]
        end

        -- FIX (temporary limitation): If Key is not a string (e.g. a table, number,
        -- or Spy proxy not found in Internal[]), fall back to a Beautify'd bracket-
        -- index expression rather than treating the object as a string identifier.
        if Typeof(Key) ~= "string" then
            return `{Path or "getfenv()"}[{Beautify(Key)}]`
        end

        local IsWeirdo = IsWeird(Key)
        local IsVararg = Path == "..."

        if IsVararg then Path = "(...)" end

        return IsWeirdo and `{Path or "getfenv()"}[{Beautify(Key)}]` or `{Path and Path .. "." or ""}{Key}`
    end

    local Vars = {}

    local function GetVar(Idx)
        local Value = Vars[Idx] or 1

        Vars[Idx] = Value + 1
        return Value == 1 and "" or Value
    end

    local function SplitIDX(str) --> Returns the indexes of a string (a['b'], a.b, ...)
        str = tostring(str)

        local Result = {}
        for Part in str:gmatch("[^%.%[]+") do
            local Key = Part:match('^%s*(.-)%s*$')

            if Sub(Key, -1) == ']' then
                Key = Match(Key, '%[(.-)%]') or Key
                Key = Gsub(Key, '^["\'](.-)["\']$', '%1') -- remove quotes
            end
            Insert(Result, Key)
        end
        return Result
    end

    local function GenerateName(str, Method)
        while true do
            local Value = (Values[str] or {}).Value

            if Value then
                str = Value
            else break end
        end

        Method = Gsub(Method, "%A", "") == "" and (Method .. GetVar(Method) .. ParamSuffix) or Method

        if str == "GetService" then
            return Method .. Id
        elseif Method == "iter" then
            return str .. Id
        end

        return GetVarID()
    end

    local function Define(Var, Value, Tag)
        Values[Var] = {Value = Value, Tag = Tag, Line = #Output, Usage = 0}
    end

    function Use(Var, Tag, Increment, Val)
        local Value = Values[Var]
        if not Value then return Define(Var, Val, Tag) end
        if Value.Usage == 0 or Increment then Value.Usage = (Increment and Value.Usage or 0) + 1 end
    end

    local Spied = {}

    --* ── Spy ───────────────────────────────────────────────────────────────
    --* Create (or return an already-cached) proxy object for a named value.
    --*
    --* Path   – the Luau expression string this proxy stands for, e.g. "game",
    --*          "var3_1", "game.Players", "arg1".
    --* Flags  – optional table:
    --*            Flags.Param = true   marks this as a function parameter so
    --*                                 ParamsUsed[Path] is tracked; un-used
    --*                                 parameters are emitted as "_" in the
    --*                                 decompiled function signature.
    --*
    --* The returned proxy has metamethods that intercept every operation and
    --* emit the equivalent Luau source line via Append():
    --*
    --*   __index    → `local var<N> = <Path>.<Key>`
    --*   __newindex → `<Path>.<Key> = <Value>`
    --*   __call     → `local var<N> = <Path>(<args>)`  (namecall-aware)
    --*   __add/sub/mul/div/… → `local var<N> = <a> + <b>`
    --*   __eq / __neq        → uses FastEq; records expression ID for hookexpr
    --*   __iter              → emits `for k, v in <Path> do … end`
    --*   __tostring          → returns Path (so the proxy prints as its name)
    --*   __unm               → `local var<N> = -<Path>`
    --*
    --* Proxies are cached in Spied[Path] so the same path always returns the
    --* identical object (important for identity comparisons inside obfuscated code).
    local function Spy(Path, Flags)
        if Spied[Path] then return Spied[Path] end

        Flags = Flags or {}

        local ISP = Flags.Param

        local function Arth(Symbol)
            return NewCClosure(function(a, b)
                local A = IsInternal(a)
                local B = IsInternal(b)
                local Value = `{Beautify(a)} {Symbol} {Beautify(b)}`
                local Var = GetVarID()

                if A then Use(A, "__arth", true) end
                if B then Use(B, "__arth", true) end
    
                Append(`local {Var} = {Value}`)
                Define(Var, Value, "__arth")
                return Spy(Var)
            end)
        end

        function Iter(_, Key)
            local Path = RawGet(_, "P")
            local Value = Values[Path] or {}
    
            local IterFunc = Path
    
            if not Key then
                if Value.Tag == "__call" and Value.Usage == 0 then
                    IterFunc = Value.Value
                    Output[Value.Line] = nil
                end
            else -- next, ipairs, whatever
                local Arg1 = Path;
                if Value.Usage == 0 then Arg1 = Value.Value or Path end
                IterFunc = Key == "next" and `next, {Arg1}` or `{Key}({Arg1})`
            end
    
            local Iv, Vv = GenerateName("k", "iter"), GenerateName("val", "iter")
    
            Append(`for {Iv}, {Vv} in {IterFunc} do`)
    
            local Called
            local PreviousTab = Tab
            Tab = Tab .. "    "
                
            return function(_, k) --> if k and key == 'next' that means we're using next()
                if Called then Tab = PreviousTab Append("end") return else Called = true end
    
                return Spy(Iv), Spy(Vv)
            end
        end

        local Mt = {
            __index = function(_, Key)
                --print("Indexed",Path,Key)

                -- LIMITATION (external — obfuscator-controlled probe keys): Pristine
                -- indexes `workspace.subgmaallshaha` at startup; if that key exists in
                -- the environment the script assumes it is being analysed and bails out.
                -- Returning nil here passes the check.
                --
                -- This bypass is hardcoded to one known key.  If the obfuscator rotates
                -- its probe key in a future version, or if another obfuscator uses a
                -- different invented key, the tool will break silently.
                --
                -- More general proposed approach: treat ALL __index accesses on
                -- "workspace" or "game" that use a Key not present in the Types.luau
                -- "Instance" list as probe attempts and return nil without emitting.
                -- This covers unknown probe keys automatically at the cost of hiding
                -- accesses to legitimate but undocumented workspace properties:
                --
                --   if (Path == "workspace" or Path == "game") then
                --     local KnownAPI = Types["Instance"]  -- from Types.luau
                --     if not Find(KnownAPI, Key) then return end
                --   end
                if Path == "workspace" and Key == "subgmaallshaha" then return end --pristine antitamper

                local Var = GetVarID()
                local Value = Index(Key, Path) --> Variable index

                Use(Path, "__index", true)

                Append(`local {Var} = {Value}`)
                Define(Var, Value, "__index")
        
                return Spy(Var)
            end,
            __newindex = function(_, Key, Value)
                --print("newindex",Values[Path],Path,Key)

                local P = IsInternal(Value)
                    
                Use(Path, "__newindex", true)

                if Values[P] then Values[P].Usage -= 1 end --> TextLabel.Font = Enum.Font.GothamBold

                local InternalKey = IsInternal(Key)
                local Var = InternalKey and `{Path}[{InternalKey}]` or Index(Key, Path) --> Variable index

                Append(`{Var} = {Beautify(Value, CurrentIndent + 1)}`)

                Use(Var, "__newindex", true)
            end,
            __call = function(_, ...)
                Use(Path, "__call")

                local Path = Path == "..." and "(...)" or Path

                local Dots = SplitIDX(GetActualPath(Path))
                local Self = Concat(Move(Dots, 1, #Dots - 1, 1, {}), ".")

                local Args, Tuple, Var = Pack(...), {}

                for i = 1, Args.n do
                    local Arg = Args[i]
                    local b = Beautify(Arg, CurrentIndent + 1)
                    Insert(Tuple, b)
                end

                local FirstArg, SecondArg = Args[1], Args[2]

                if Beautify(FirstArg) == Self then -- Namecall
                    local Method = Dots[#Dots]
                    Path = `{Self}:{Method}`
                    Var = GenerateName(Method, Typeof(SecondArg) == "string" and SecondArg or "__call")

                    Remove(Tuple, 1)
                end

                Var = Var or GenerateName(Path, Typeof(FirstArg) == "string" and FirstArg or "__call")

                local Value = `{Path}({Concat(Tuple, ", ")})`

                Append(`local {Var} = {Value}`)
                Define(Var, Value, "__call")
                --Use(Var, "__call", true, Value)

                return Spy(Var)
            end,
            __add = Arth("+"), __sub = Arth("-"), __mul = Arth("*"), __div = Arth("/"), __idiv = Arth("//"), __pow = Arth("^"), __concat = Arth(".."), __mod = Arth("%"),
            __tostring = function(_)
                Use(Path, "__tostring"--[[, (Values[Path] or {}).Usage == 1]])

                return Path
            end,
            __unm = function(_)
                local Var = GenerateName(P, "unm")

                Append(`local {Var} = -{Path}`)
                return Spy(Var)
            end,
            __iter = Iter,
            __metatable = {}
        }

        for i, Method in Next, Mt do
            if Typeof(Method) ~= "function" then continue end

            Mt[i] = function(_, ...)
                OpCount += 1

                OpCountCheck()
                if ISP then ParamsUsed[Path] = true end

                return Method(_, ...)
            end
        end

        local Object = Setmetatable({P = Path, ISP = ISP}, Mt)
        Spied[Path] = Object

        if ISP then ParamsUsed[Path] = false end

        Internal[Object] = Path

        return Object
    end

    local function SpyParams(Amount)
        local Out = {}

        for i = 1, Amount do Out[#Out+1] = Spy(`arg{i}{ParamSuffix}`, {Param = true}) end

        return Unpack(Out)
    end

    local function CreateFunction(Callback, Path)
        Path = Path or "(function()end)"

        local Meta = Setmetatable({}, {
            __call = function(_, ...)
                return Callback(...)
            end,
            __tostring = function() return Path end
        })

        Internal[Meta] = Path

        return Meta
    end

    local IsFile = Typeof(Source) == "string"

    local function SafeWrap(f, path, isCore)
	    if Typeof(f) ~= "function" then return end

	    local name = DebugInfo(f, "n")

	    local function isDtc(v)
		    if Typeof(v) == "table" then
			    for k, val in next, v do
				    if isDtc(k) or isDtc(val) then
                        print("kv dtc",k,val)
					    return true
				    end
			    end
		    end

            local Internal = IsInternal(v)

		    return Internal and Internal ~= "getfenv()" and not Find({"string", "table", "os", "task", "coroutine", "debug"}, Internal) and not RawGet(v, "ISP")
	    end

	    local function helper(...)
			local var = GenerateName(name, "call")
			local value = `{path}({BeautifyTuple(...)})`

			Append(`local {var} = {value}`)
			Define(var, value, "__call")

			return Spy(var)
	    end

	    return CreateFunction(function(...)
		    local args = Pack(...)
	    	for i = 1, args.n do
    			local arg = args[i]

		    	if IsInternal(arg) and (not isCore or not RawGet(arg, "ISP")) then
                    local value = helper(...)
				    if value then return value end
				end
		    end

		    return f(...)
	    end, path)
    end

    local Locked;

    local function AddVar(Name1, Name2, Value, Tag)
        local Var = GenerateName(Name1, Name2)

        Append(`local {Var} = {Value}`)
        Define(Var, Value, Tag)

        return Var
    end

    local function Obfuscate(Code)
        -- Create the temp directory if it does not exist yet so that
        -- fs.writeFile() below does not fail on a fresh clone of the repo.
        if not fs.isDir("temp") then
            fs.makeDir("temp")
        end

        local File = "temp/" .. GenerateId(6)

        -- FIX (temporary limitation): Strip ALL leading whitespace (spaces, tabs,
        -- and blank lines) before writing to the temp file.  The external Lua
        -- unparser (Obf) has line-number assertions that fail when the first real
        -- token is not on line 1.  Chunks produced by inner loadstring() calls
        -- inside obfuscated scripts often start with `\n` (e.g. "\n-- chunk header"),
        -- triggering this failure and causing hookOp instrumentation to be silently
        -- skipped.  Removing all leading whitespace ensures the first real token is
        -- always on line 1 without altering the semantics of the chunk.
        Code = Gsub(Code, "^%s+", "")

        fs.writeFile(File, Code)
        local t = Obf(File)
        fs.removeFile(File)
        return t
    end

    local function CreateLoader(Name)
        local Loader = Setmetatable({P=Name}, {
            __call = function(_, a, b)
                local IsString = Typeof(a) == "string"
                local IsWeird = b and Typeof(b) ~= "string" --> weird chunk names?

                local Value = `{Name}(`
                local Args = {a, b}
                Value ..= `{BeautifyTuple(Unpack(Args))})`

                if IsString and not IsWeird then
                    return Setmetatable({P=Value}, {
                        __call = function(_, ...)
                            Append(`{Value}({BeautifyTuple(...)})`)

                            local _a = a

                            if not Settings.raw then
                                -- Obfuscate() now strips leading whitespace internally (see its
                                -- definition above), so the line-check error that previously
                                -- occurred on chunks starting with `\n` is fixed.  The pcall
                                -- guard is kept as a safety net for any other unparser errors
                                -- (e.g., syntax errors in the inner chunk).
                                local S, Obfuscated = pcall(Obfuscate, a)
                                if S then a = Obfuscated end
                            end

                            local Returned = {setfenv(loadstring(a, b), Locked)(...)}
                            local Message = Returned[2]
                            if not Returned[1] then Message = Sub(_a, 1, 1) == "\n" and Gsub(Message, ":1:", ":2:") or Message return false, Message end

                            return Unpack(Returned)
                        end,
                        __tostring = function() return Value end
                    })
                end

                return function(...)
                    local Vars = {}
                    local Str = "local "

                    for _ = 1, 3 do
                        local Var = GetVarID()
                        Str ..= Var .. ", "
                        
                        Insert(Vars, Spy(Var))
                    end

                    Append(`{Sub(Str, 1, -3)} = {Value}({BeautifyTuple(...)})`)

                    return Unpack(Vars)
                end
            end,
            __tostring = function() return Name end
        })
        Internal[Loader] = Name
        return Loader
    end

    local Loadstring = CreateLoader("loadstring")
    local Load = CreateLoader("load")

    local function FastComp(Symbol)
        return function(a, b)
            local A = IsInternal(a)
            local B = IsInternal(b)

            local v1, v2 = a, b;

            if A or B then
                if A then Use(A, "__comp", true) v1 = RawGet(a, "V") or a end
                if B then Use(B, "__comp", true) v2 = RawGet(b, "V") or b end

                return Spy(AddVar("Comp", Symbol, `{A or Beautify(a)} {Symbol} {B or Beautify(b)}`, "__comp"))
            end

            if Symbol == "<" then return v1 < v2
            elseif Symbol == ">" then return v1 > v2
            elseif Symbol == "<=" then return v1 <= v2
            elseif Symbol == ">=" then return v1 >= v2
            end
        end
    end

    local function FastEq(Symbol)
        return function(a, b)
            local A = IsInternal(a)
            local B = IsInternal(b)
                
            if A or B then
                local v1, v2;

                if A then Use(A, "__comp", true) v1 = RawGet(a, "V") end
                if B then Use(B, "__comp", true) v2 = RawGet(b, "V") end

                if v1 == nil then v1 = a end
                if v2 == nil then v2 = b end

                local Hook = ExpressionHooks[ExpressionId]
                local HookExists = Hook ~= nil

                local ValueOut;

                if HookExists then
                    if Hook ~= "nil" and Hook ~= "spy" then
                        ValueOut = Hook
                    else
                        HookExists = false
                    end
                end

                local Eq;
                
                if Symbol == "~=" then
                    Eq = v1 ~= v2
                else
                    Eq = v1 == v2
                end

                if HookExists then
                    Eq = ValueOut
                end

                local Var = AddVar("Equal", "", `{A or Beautify(a)} {Symbol} {B or Beautify(b)} --[[expr id {ExpressionId}, hooked: {HookExists}, value: {Eq}]]`, "__eq")
                ExpressionId += 1

                if HookExists then return Eq end

                local Value = Spy(Var); -- v is nil

                rawset(Value, "V", Eq)

                return Value
            end

            if Symbol == "~=" then return a ~= b else return a == b end
        end
    end

    local function Type(x, a)
        local p = IsInternal(a)
        if not p then return x == "type" and type(a) or typeof(a) end

        local S = Spy(`{x}({a})`)
        local Type = GetType(GetActualPath(p) or p)

        -- LIMITATION: Only the four Roblox service roots are handled here.
        -- Any other Instance (e.g. Players, Workspace.Part, script.Parent) that
        -- reaches this branch will rely solely on GetType() looking up the path
        -- string in Types.luau.  If the path isn't in Types.luau, GetType() returns
        -- nil and rawset(S, "V", nil) has no effect, so downstream typeof/type
        -- comparisons on that spy value fall back to "userdata" by default.
        -- Fix: replace this hardcoded list with a broader Instance-ancestry check
        -- or extend Types.luau with all common Instance types.
        if p == "game" or p == "workspace" or p == "Workspace" or p == "Game" then --! hardcoded for now
            if x == "type" then
                Type = "userdata"
            else
                Type = "Instance"
            end
        end

        rawset(S, "V", Type)

        return S
    end

    local NextCalls = {}

    local function CheckCondition(Condition, IsElseIf)
        local Int = IsInternal(Condition)
        if Int then
            Top.add_if_comment = true

            local v = RawGet(Condition, "V")
            local Hook = ExpressionHooks[ExpressionId]
            local HookExists = Hook ~= nil

            if HookExists then
                if Hook ~= "nil" and Hook ~= "spy" then
                    v = Hook
                end
            end

            local DidRun = (v == nil or v) and "--[[ i ran ]]" or "--[[ i did not run ]]"

            if IsElseIf then
                Append(`-- elseif {Int} then {DidRun} --[[expression id {ExpressionId} was hooked: {HookExists}]]\n`)
            else
                Append(`if {Int} then {DidRun} end --[[expression id {ExpressionId} was hooked: {HookExists}]]\n`)
            end

            ExpressionId += 1

            if v == nil then return Condition else return v end
        end

        return Condition
    end

    --* ── Hooks ─────────────────────────────────────────────────────────────
    --* The Hooks table forms the sandboxed global environment seen by the
    --* obfuscated script.  Every entry is either:
    --*
    --*   a)  a safe pass-through to the real Lune runtime function, or
    --*   b)  a custom implementation that first checks whether its arguments
    --*       are Spy proxies and, if so, emits the matching Luau source line.
    --*
    --* Special entries that require explanation:
    --*
    --*   hookexpr(id, val) – pre-set the truth value of expression #id.  The
    --*                       unparser inserts CHECKIF(expr_id, value) call-sites;
    --*                       the user can call hookexpr before running to force a
    --*                       specific branch to be taken.
    --*
    --*   CHECKIF / CHECKELSEIF – called for every if/elseif condition.
    --*                       Emits a comment showing whether the branch ran and
    --*                       increments ExpressionId.
    --*
    --*   CHECKWHILE – called every iteration of a while-loop to prevent infinite
    --*                loops exceeding max_while_count.
    --*
    --*   CHECKOR / CHECKAND / CHECKNOT / __EQ / __NEQ / COMPL … COMPGE –
    --*                logical and comparison operators that emit an expression
    --*                variable when at least one operand is a Spy proxy.
    --*
    --*   CHECKLEN – intercepts the # length operator on spy values.
    --*
    --*   setfenv – prevents the script from replacing Locked with an untrusted
    --*             env; if the new env has no metatable it is merged into Locked.
    --*
    --*   islclosure / iscclosure – return accurate answers for real functions but
    --*             also emit a line so the output shows the check was performed.
    --*
    --*   tostring – intercepts tostring() on Spy proxies and returns their stable
    --*              fake address instead of "userdata: …".
    --*
    --*   type / typeof – wrap Type() which uses GetType() to infer the semantic
    --*                   type of a spy path rather than returning "userdata".
    --*
    --*   getgc – returns a large random table to satisfy scripts that call getgc()
    --*           and then iterate over the result looking for specific objects.
    local Hooks = {
        hookexpr = function(id, val)
            ExpressionHooks[id] = val
        end,
        --[[rawget = function(a, b)

        end,]]
        next = function(tbl, ...)
            --print("next called",tbl,...)
            if IsInternal(tbl) then
                if NextCalls[tbl] then
                    return NextCalls[tbl](tbl, ...)
                end

                local Func = Iter(tbl, "next")
                NextCalls[tbl] = Func
                return Func(tbl, ...)
            else return next(tbl, ...) end
        end,
        getmetatable = function(tbl)
            if IsInternal(tbl) then return nil end

            local tp = Typeof(tbl)

            if tp ~= "table" and tp ~= "userdata" then error("invalid argument #1 to 'getmetatable', 'table' or 'userdata' expected got '" .. tp .. '') end
            return getmetatable(tbl)
        end,
        wait = function(a) return Spy(`wait({a})`) end,
        -- For PureVM obfuscators (e.g. Luraph) the VM stores pcall at init time
        -- as an upvalue.  Wrapping it here means every internal VM pcall also
        -- triggers the time-based execution cap so the hook does not require
        -- debug.sethook (which is unavailable in Lune 0.10).
        pcall = function(f, ...)
            if IsPureVMObfuscator then CheckBootstrapTimeout() end
            return pcall(f, ...)
        end,
        setfenv = function(a, b) --> prevent env wiping
            if getmetatable(b) then return end --> we don't wanna override, do we?
            setfenv(a, Setmetatable(b, Locked))
        end,
        islclosure = function(a)
            AddVar("IsLua", "_call", `islclosure({Beautify(a)})`, "__call")

            if IsInternal(a) then if Find(ExecEnv, a) then return false end end
            
            return DebugInfo(a, "s") ~= 'C'
        end,
        iscclosure = function(a)
            AddVar("IsC", "_call", `iscclosure({Beautify(a)})`, "__call")

            if IsInternal(a) then if Find(ExecEnv, a) then return true end end
            
            return DebugInfo(a, "s") == 'C'
        end,
        tostring = function(Str)
            if IsInternal(Str) then --> Hey get off my variable
                local Path = RawGet(Str, "P")
                local Type = GetType(Path)
                
                return GetAddress(Path, Type)
            end
            return Tostring(Str)
        end,
        CHECKIF = function(Condition) return CheckCondition(Condition, false) end,
        CHECKELSEIF = function(Condition) return CheckCondition(Condition, true) end,
        CHECKWHILE = function(Condition, LoopId)
            local LoopKey = LoopId or "__default"
            local Hits = (LoopHits[LoopKey] or 0) + 1

            LoopHits[LoopKey] = Hits
            if Settings.max_while_count <= Hits then
                if Condition == true and LoopId ~= nil then
                    error(`While loop {LoopId} exceeded max_while_count while its condition stayed true. This script looks like a direct VM interpreter. Raise --max_while_count to probe further or use a VM-specific devirtualizer.`, 0)
                end

                if not BrokenLoops[LoopKey] then
                    local LoopSuffix = LoopId ~= nil and `, {Beautify(LoopId)}` or ""
                    Append(`CHECKWHILE({Condition}{LoopSuffix}) -- this was the last call before breaking out of while loop {Beautify(LoopKey)}.`)
                    BrokenLoops[LoopKey] = true
                end

                return false
            end

            LoopCount += 1

            local Int = IsInternal(Condition)

            if Int then
                AddVar("While", "Condition", `CHECKWHILE({Int})`, "__while")
            end

            return Condition
        end,
        -- LIMITATION: When either operand is a Spy proxy that represents loadstring,
        -- CHECKOR short-circuits and returns the real Loadstring loader directly.
        -- This is correct for the `loadstring or fallback` pattern, but the early
        -- return means the or-expression is NOT emitted to Output, so the output
        -- shows nothing for that line.  The `--! isnt the issue..` note refers to an
        -- earlier investigation where loadstring appearing nil in Locked.__index was
        -- blamed on CHECKOR; the actual cause is that CHECKOR returns Loadstring
        -- before Locked.__index ever gets a chance to handle the "loadstring" key,
        -- so `Key == "loadstring"` in __index is only hit when CHECKOR is absent.
        CHECKOR = function(a, b) --! isnt the issue..
            local A = IsInternal(a)
            local B = IsInternal(b)

            if A or B then
                local v1, v2;

                if A then
                    if A == "loadstring" then return Loadstring end --> ignore loadstring?
                    v1 = RawGet(a, "V")
                end
                if B then
                    if B == "loadstring" then return v1 or Loadstring end --^^
                    v2 = RawGet(b, "V")
                end

                if v1 == nil then v1 = a end
                if v2 == nil then v2 = b end

                if Tostring(v1 or v2) == "getfenv()" then return Locked end --> return the actual getfenv()

                local Var = Spy(AddVar("comp", "Or", `({A or Beautify(a)} or {B or Beautify(b)})`, "__comp"))
                rawset(Var, "V", v1 or v2)

                return Var
            end

            return a or b
        end,
        CHECKAND = function(a, b)
            local A = IsInternal(a)
            local B = IsInternal(b)

            if A or B then
                local v1, v2;

                if A then Use(A, "__comp", true) v1 = RawGet(a, "V") end
                if B then Use(B, "__comp", true) v2 = RawGet(b, "V") end

                if v1 == nil then v1 = a end
                if v2 == nil then v2 = b end

                local Hook = ExpressionHooks[ExpressionId]
                local HookExists = Hook ~= nil

                local ValueOut;

                if HookExists then
                    if Hook ~= "nil" and Hook ~= "spy" then
                        ValueOut = Hook
                    else
                        HookExists = false
                    end
                end

                local AndResult = v1 and v2

                if HookExists then
                    AndResult = ValueOut
                end

                local Var = AddVar("Comp", "And", `{A or Beautify(a)} and {B or Beautify(b)} --[[expr id {ExpressionId}, hooked: {HookExists}, value: {AndResult}]]`, "__comp")
                ExpressionId += 1

                if HookExists then return AndResult end

                local Return = Spy(Var)
                rawset(Return, "V", v1 and v2)

                return Return
            end

            return a and b
        end,
        CHECKNOT = function(a)
            local Path = IsInternal(a)
            if Path then
                if Path == "getconstants" then return true end
                if Path == "loadstring" then return false end --> not loadstring = false since loadstring exists

                local Var = GetVarID()
                local Value = `not {a}`
                Append(`local {Var} = {Value};`)
                Define(Var, Value, "__comp")

                if Settings.hookOpValue == "spy" then
                    local Return = Spy(Var)

                    local V = RawGet(a, "V")

                    if V == nil then V = true end

                    rawset(Return, "V", not V)

                    return Return
                end
            end
            return not a
        end,
        __NEQ = FastEq("~="),
        __EQ = FastEq("=="),
        CHECKLEN = function(a)
            local A = IsInternal(a)
            local Len = #a

            if A then
                Use(A, "__len", true)

                local Var = Spy(AddVar("Len", "len", `#{A}`, "__len"))
                rawset(Var, "V", Len)

                return Var
            end

            return Len
        end,
        COMPL = FastComp("<"),
        COMPG = FastComp(">"),
        COMPLE = FastComp("<="),
        COMPGE = FastComp(">="),
        getgc = function()
            return table.create(math.random(1000, 10_000), {})
        end
    }

    Hooks.type, Hooks.typeof = function(...)
        return Type("type", ...)
    end, function(...)
        return Type("typeof", ...)
    end
    
    local function Deglobal(Text) --> Prevents a string from being a global name (CFrame, math, ...)
        for _, Name in next, ExecEnv do
            if Text == Name then
                return Text .. GetVar(Text)
            end
        end
        return Text
    end

    local function HookLib(Lib, Extra)
        local l = getfenv()[Lib]
        local r = {P = Lib}

        for i, v in next, l do
            r[i] = SafeWrap(v, Index(i, Lib), true)
        end

        for i, v in next, Extra or {} do
            r[i] = v
        end

        local Meta = Setmetatable(r, {
            __tostring = function() return Lib end,
            __metatable = "This metatable is locked.",
            __iter = Iter
        })
        Internal[Meta] = Lib
        return Meta
    end

    -- LIMITATION (external — SafeWrap semantic mismatch): Applying HookLib("table")
    -- would break void-return mutating functions.  SafeWrap wraps each function
    -- so that when any argument is a spy proxy it records the call and returns a new
    -- Spy rather than calling the real function.  For table.insert / table.remove /
    -- table.sort this means: (a) the real mutation never happens, and (b) the spy
    -- proxy for the table is not actually modified, breaking subsequent reads.
    --
    -- Proposed workaround for read-only or value-returning table functions
    -- (table.concat, table.find, table.unpack, table.move):
    --   Hooks.table = HookLib("table", {
    --     insert = function(t, v)  table.insert(t, v); Append(`table.insert(…)`)  end,
    --     remove = function(t, i)  table.remove(t, i); Append(`table.remove(…)`)  end,
    --     sort   = function(t, fn) table.sort(t, fn);  Append(`table.sort(…)`)    end,
    --   })
    -- This keeps the real mutation AND emits the call.  Implementing this fully
    -- requires handling spy proxy arguments inside the custom wrappers.
    Hooks.string, Hooks.table, Hooks.math = HookLib("string"), table, HookLib("math")

    -- LIMITATION (external — Luau VM constraint): coroutine.wrap cannot be
    -- correctly sandboxed because setfenv() is a no-op on C closures in Luau.
    -- coroutine bodies that escape Locked run with their original _ENV, so their
    -- global accesses and operations are not emitted to Output.
    --
    -- Proposed workaround (partial): check islclosure(f) before applying setfenv.
    -- For Lua closures, setfenv works.  C closures can only be emitted as stubs
    -- (record that coroutine.wrap was called with that function, but don't execute
    -- the body in the sandbox).
    -- Note: Append() and Beautify() in the example below refer to the Output emitter
    -- and value-serialiser functions defined in Main() — both are in scope here.
    --
    --   Hooks.coroutine = HookLib("coroutine", {
    --     wrap = function(f)
    --       if DebugInfo(f, "s") ~= "[C]" then
    --         -- Lua closure: rebind to sandbox and intercept its body.
    --         return coroutine.wrap(setfenv(f, Locked))
    --       else
    --         -- C closure: cannot rebind; emit a placeholder and run unsandboxed.
    --         Append(`-- coroutine.wrap({Beautify(f)}) (C closure, body not intercepted)`)
    --         return coroutine.wrap(f)
    --       end
    --     end
    --   })
    --
    -- This still does not intercept globals inside nested Lua closures that are
    -- called by the coroutine body — a complete fix requires deep setfenv of every
    -- reachable function in the coroutine's call graph, which is not feasible here.
    --[[Hooks.coroutine = HookLib("coroutine", {
        wrap = function(f)
            return coroutine.wrap(setfenv(f, Locked))
            --return Spy(AddVar("wrap", "coroutine", Beautify(f, CurrentIndent + 1), "__call"))
        end
    })]]
    Hooks.debug = Setmetatable({
        getinfo = function(thread)
            local SpiedPath = IsInternal(thread)
            if SpiedPath then
                Append(`-- debug.getinfo was called on a spied value: {SpiedPath}`)
                return {numparams = 0, is_vararg = 0, what = 'C', line = 1}
            end

            if typeof(thread) ~= "function" and typeof(thread) ~= "number" then return {numparams = 1, is_vararg = true, what = 'C', line = 1} end

            local line = debug.info(2, "l")

            local numparams, isvrg = DebugInfo(thread, 'a')
            return Setmetatable({
                ["line"] = line,
                ['numparams'] = numparams,
                ['is_vararg'] = isvrg and 1 or 0,
                ['what'] = DebugInfo(thread, 's') == '[C]' and 'C' or 'Lua'
            }, {
                __index = function(_, Key)
                    Append(`-- The script indexed debug.getinfo(...) with key '{Key}'.`)
                end
            })
        end,
        -- PureVM obfuscators (e.g. Luraph) use debug.info internally to
        -- introspect function arities and source locations.  Pass through to
        -- the real debug.info so the VM's bootstrap logic works correctly.
        info = DebugInfo,
        -- debug.info is the Luau-style introspection function (format-string based).
        -- Obfuscators such as Luraph call debug.info(getmetatable, "slnaf") as an
        -- anti-tamper check: if getmetatable is the real C function the source
        -- field "s" comes back as "[C]"; a sandboxed Lua wrapper breaks this check.
        -- This handler passes through to the real debug.info for any non-Spy target
        -- so the check passes.  For Spy proxies (where a real call is impossible)
        -- it synthesises a plausible "[C]"-source result and emits a comment.
        info = function(f, opts)
            local SpiedPath = IsInternal(f)
            if SpiedPath then
                Append(`-- debug.info was called on spy: {SpiedPath}`)
                local ret = {}
                for i = 1, #(opts or "") do
                    local c = Sub(opts, i, i)
                    if c == "s" then ret[#ret+1] = "[C]"         -- "s": source; C functions always show "[C]"
                    elseif c == "l" then ret[#ret+1] = -1         -- "l": current line; -1 = unavailable for C
                    elseif c == "n" then ret[#ret+1] = SpiedPath  -- "n": name; use the spy path as a stand-in
                    elseif c == "a" then ret[#ret+1] = 0; ret[#ret+1] = false  -- "a": arity (0 params, not vararg)
                    elseif c == "f" then ret[#ret+1] = f          -- "f": the function object itself
                    end
                end
                return Unpack(ret)
            end
            -- Real function or stack-level number: pass through to the genuine
            -- debug.info so anti-tamper checks on standard C globals return "[C]".
            if Typeof(f) == "function" or Typeof(f) == "number" then
                return debug.info(f, opts)
            end
            return nil
        end,
        traceback = function(a)
            assert(not a or Typeof(a) == "string", "invalid argument #1 to 'traceback' (string expected got " .. Typeof(a) .. ")")

            local trace = debug.traceback(a)
            local lines = Split(trace, "\n")
            local out = {}

            for _, v in next, lines do
                if not Match(v, "%[string \".*hi\"%]") then
                    v = Gsub(v, "string \"luau%.load%(.-%)\"", TraceId)
                    Insert(out, v)
                end
            end --> covering my traces:)

            return Concat(out, "\n")
        end,
        -- Pass debug.info through to the real implementation.  VM obfuscators
        -- (e.g. Luraph) call debug.info to read parameter/upvalue counts for
        -- anti-tamper checks; returning a spy proxy would cause the VM to
        -- malfunction before executing any deobfuscated code.
        info = debug.info,
        setmetatable = Spy("debug.setmetatable"),
        P = "debug"
    }, {
        __index = function(_, Key)
            return debug[Key] and Spy(Index(Key, "debug")) or nil
        end,
        __tostring = function() return "debug" end,
        __newindex = function(_, k, v)
            if k == "P" then return end
            rawset(_, k, v)
        end,
        __iter = Iter
    })

    Internal[Hooks.debug] = "debug"

    local TrueEnv = getfenv(Main)
    TrueEnv.bit = bit32
    TrueEnv.ypcall = pcall

    -- FIX (temporary limitation): Use the original (pre-hookOp) source for all
    -- MoonSec signature checks.  When hookOp is active, Obf() rewrites the AST
    -- before Main() is called; this can rename or inline `_ENV` references so
    -- that `Source:find("_ENV")` returns nil even on genuine MoonSec scripts.
    -- OriginalSource is set by Decode() before calling Obf(), so it always holds
    -- the unmodified file text.  For non-file invocations (nested Beautify calls)
    -- OriginalSource is nil and we fall back to the Source that was passed in.
    local DetectionSource = OriginalSource or Source
    local MoonSec = IsFile and DetectionSource:find("This file was protected with MoonSec V3")
    local MoonSecAntiTamper = MoonSec and DetectionSource:find("_ENV")
    local MoonSecCP = MoonSec and DetectionSource:find("//") --> Constant Protection
    local Pristine;
    local Tasks = 0;

    local EnvValues = {_ENV = {}, bit = {bit32}}

    local IterFuncs = {"pairs", "ipairs"}
    local Funcs = {"newproxy", "select", "setmetatable", "assert", "rawget", "rawset", "xpcall", "unpack", "ypcall", "error", "spawn", "getmetatable", "next", "print", "rawequal", "rawlen", "require", "type", "typeof", "warn"}
    local WrapFuncs = {"tonumber", "collectgarbage", "tostring", "pcall"}
    local Tables = {"bit", "bit32", "buffer", "coroutine", "math", "os", "string", "table", "utf8"}

    local Env = {}

    for i, v in Next, Hooks do Env[i] = v end
    for _, i in Next, WrapFuncs do Env[i] = SafeWrap(TrueEnv[i], i) end
    for _, i in Next, Funcs do Env[i] = TrueEnv[i] end
    for _, i in Next, Tables do Env[i] = TrueEnv[i] end

    if ConcreteBootstrap or IsPureVMObfuscator then
        Env.debug = TrueEnv.debug
    end

    -- For pure VM obfuscators the entire execution is self-contained in Lua
    -- closures that never touch the global env, so Locked.__index is rarely
    -- called and the wall-clock timeout there cannot fire.  Luraph-style VMs
    -- use pcall heavily for instruction dispatch: wrapping it gives us a
    -- reliable hook to check the execution time limit on every VM cycle.
    if PureVMObfuscator then
        local BasePcall = Env["pcall"]
        Env["pcall"] = CreateFunction(function(...)
            CheckBootstrapTimeout()
            return BasePcall(...)
        end, "pcall")
    end

    local Task = Setmetatable({}, {
        __index = function(_, Key)
            local Actual = task[Key]

            return Actual and (Pristine and function(...)
                Tasks += 1

                local Args = Pack(...)
                local Input = {}

                for i = 1, Args.n do
                    local Arg = Args[i]

                    if Typeof(Arg) == "function" then
                        Arg = setfenv(Arg, Locked)
                    end

                    Input[i] = Arg
                end

                return Pristine and Tasks <= 5 and Actual(Unpack(Input)) or Spy(AddVar("scheduled", "", `{Index(Key, "task")}({BeautifyTuple(Unpack(Input))})`, "__call"))
            end or function(...)
                local Indexed = Index(Key, "task")

                OpCount += 1
                OpCountCheck()

                return Spy(AddVar("", "", `{Indexed}({BeautifyTuple(...)})`, "__call"))
            end) or nil
        end
    })

    Internal[Task] = "task"

    Env.task = Task

    local Function = IsFile and loadstring(Source) or Source
    local SetfenvResult

    local ParamCount, Extra = DebugInfo(Function, "a")
    -- LIMITATION: SpyParams is called with ParamCount + 50 to speculatively create
    -- spy proxies for extra parameters beyond the declared count.  This is a
    -- workaround for obfuscated functions that call `debug.getinfo` to obtain their
    -- own parameter count and then read arguments they were not formally declared
    -- with (a common anti-analysis trick).  The downside is that 50 extra `arg<N>`
    -- variables are always created and registered in ParamsUsed; if the function
    -- genuinely has fewer than ParamCount+50 parameters, the unused arg<N> proxies
    -- contribute noise.  A smarter fix would detect dynamic arg-count reads and
    -- generate proxies lazily.
    local Params = {SpyParams(ParamCount + 50)}

    if Extra then Insert(Params, Spy("...", { Param=true })) end

    if MoonSecAntiTamper then print("MoonSec anti tamper enabled") end
    if MoonSecCP then print("MoonSec constant protection enabled") end

    if MoonSecAntiTamper or MoonSecCP then --
        print("Script uses MoonSec AntiTamper / Constant Protection")

        local _fenv = getfenv() --> table.cloning ts breaks it so
        local _core = { tonumber = tonumber, select = select, unpack = unpack, tostring = tostring, pcall = pcall, setmetatable = setmetatable, rawget = rawget, assert = assert, os = os, type = type, bit32 = bit32 }

        for HookKey, Hook in next, Hooks do
            _core[HookKey] = _core[HookKey] or Hook
        end

        _core.wait = function() return 1 end

        local loads = 0;

        Locked = setmetatable(_core, {
            __index = function(_, Key)
                --print("[MSAT] Env Indexed",Key,#Key)

                if Key == "getconstants" or Key == "_ENV" then return end
                if Key == "getfenv" then return function() return Locked end end

                -- LIMITATION (external — MoonSec V3 internal naming): MoonSec V3
                -- generates its own internal globals with exactly 15-character obfuscated
                -- names.  Passing those through to the real environment (_fenv) lets
                -- MoonSec's runtime function correctly without being intercepted.
                --
                -- The length-15 heuristic is fragile because:
                --   • Any legitimate 15-char global (e.g. "NumberSequence", 14 chars;
                --     "getscriptclosure", 16 chars) is mis-classified.
                --   • If a future MoonSec version changes its identifier length, the
                --     heuristic stops working entirely.
                --   • The ad-hoc extra exemptions ("type", "setfenv") show the heuristic
                --     already has known holes.
                --
                -- Proposed replacement: build an explicit allowlist of MoonSec's known
                -- internal identifiers by extracting them from a reference sample:
                --   local MoonSecInternals = {"<name1>", "<name2>", ...}
                --   if Find(MoonSecInternals, Key) or Key == "type" or Key == "setfenv" then
                --     return _fenv[Key]
                --   end
                -- This is more precise but requires updating the list when MoonSec changes.
                if #Key == 15 or Key == "type" or Key == "setfenv" then return _fenv[Key] end
                if Key == "loadstring" then
                    return Setmetatable({}, {
                        __call = function(_, Source, Chunk)
                            loads += 1
                            if Typeof(Source) == "table" and not IsInternal(Source) then error("no load") end --> {}

                            return function(...)
                                if Typeof(Source) == "string" then
                                    if loads <= 4 then
                                        if not Settings.raw then --> use hookOp and stuff yfm
                                            Source = Obfuscate(Source)

                                            return setfenv(loadstring(Source, Chunk), Locked)(...)
                                        end

                                        return loadstring(Source, Chunk)(...)
                                    end

                                    Append(Beautify(loadstring(Source)))
                                else
                                    local Var = GetVarID()
                                    Append(`local {Var} = loadstring({Beautify(Source)})({BeautifyTuple(...)})`)
                                    return Spy(Var)
                                end
                            end
                        end
                    })
                end

                if Find(IterFuncs, Key) then return function(a) return Iter(a, Key) end end

                local Indexed = Index(Key)

                if Settings.env_index then
                    Append(`local _ = {Indexed}`)
                end

                local IsSafe = Find(ExecEnv, Key)

                --print("MSAT", Key, _fenv[Key])

                -- if key is 13 chars long but is ColorSequence, allow it

                if IsSafe and ( #Key ~= 32 and (#Key ~= 13) and #Key ~= 17 ) then print("Spy",Indexed) return Spy(Indexed) end
                return _fenv[Key]
            end,
            __tostring = function() return "getfenv()" end,
            __newindex = function(_, k, v)
                if k == "P" then return end
                rawset(_, k, v)
            end,
            __metatable = nil
        })

        rawset(Locked, "P", "getfenv()")
        rawset(Locked, "V", Locked)
        rawset(Locked, "R", getfenv()["\114\101\113\117\105\114\101"])

        Internal[Locked] = "getfenv()"

        getfenv = newcclosure(function() return Locked end)
    else
        Locked = Setmetatable(Env, {
            __index = function(_, Key)
                --print(Key)

                -- PureVM obfuscators (e.g. Luraph) run their entire interpreter loop
                -- through this __index.  Counting every global read against max_ops
                -- exhausts the budget within a handful of VM instructions, producing no
                -- useful output.  Instead, rely solely on the time-based cap
                -- (max_bootstrap_seconds) which is automatically set to 30 s for PureVM.
                if not IsPureVMObfuscator then
                    OpCount += 1
                    OpCountCheck()
                end

                if Key == "_ENV" then return end
                -- NOTE: getfenv is normally resolved via rawget (we rawset a
                -- stable closure directly into Locked after it is created so
                -- that VM anti-tamper reference-equality checks pass).  This
                -- branch is a fallback for MoonSec/ConcreteBootstrap paths
                -- where the rawset is not performed.
                if Key == "getfenv" then return function() return Locked end end
                -- LIMITATION: When the obfuscated script uses a `x or loadstring` pattern,
                -- hookOp emits `CHECKOR(x, loadstring)`.  CHECKOR special-cases the
                -- "loadstring" path and returns Loadstring directly (see CHECKOR above),
                -- so `Locked.__index` for the key "loadstring" is only reached when
                -- loadstring is accessed directly (not via an `or` expression).
                -- In practice this line is always reachable on direct access, but the
                -- comment records that there was a period where CHECKOR was suspected of
                -- returning nil for loadstring in some edge-case and this fallback was
                -- added as a safety net.
                if Key == "loadstring" then return Loadstring end --! reason it might be nil sometimes is due to CHECKOR
                if Key == "load" then return Load end

                -- For pure VM obfuscators (Luraph et al.) only charge an op when
                -- accessing a known Roblox/executor global.  Those are the accesses
                -- that produce spy output; internal VM globals return nil and must
                -- not exhaust max_ops during the bootstrap phase.
                local IsExec = Find(ExecEnv, Key)
                if not PureVMObfuscator or IsExec then
                    OpCount += 1
                    OpCountCheck()
                else
                    -- Non-ExecEnv access in PureVMObfuscator mode: check wall-clock
                    -- time so a game-loop payload cannot spin indefinitely.
                    CheckBootstrapTimeout()
                end

                if ConcreteBootstrap then
                    CheckBootstrapTimeout()

                    if EnvValues[Key] ~= nil then
                        return EnvValues[Key][1]
                    end

                    return TrueEnv[Key]
                end

                -- PureVM obfuscators run their own bytecode interpreter and
                -- never call loadstring.  We let the VM access all non-exec
                -- globals (bit32, string, coroutine, …) directly so it can
                -- bootstrap, but Roblox API accesses (game, workspace, …) are
                -- still intercepted via Spy so the output captures what the
                -- original script was doing.
                if IsPureVMObfuscator then
                    CheckBootstrapTimeout()

                    if EnvValues[Key] ~= nil then
                        return EnvValues[Key][1]
                    end

                    local IsExec = Find(ExecEnv, Key)
                    if IsExec then
                        OpCount += 1
                        return Spy(Index(Key))
                    end

                    -- Non-exec key: pass through real environment so the VM
                    -- can use standard library functions without interference.
                    if TrueEnv[Key] ~= nil then
                        return TrueEnv[Key]
                    end

                    return nil
                end

                TrackEnvHit(Key)

                if Find(IterFuncs, Key) then -- pairs, ipairs
                    return NewCClosure(function(Table)
                        if IsInternal(Table) then
                            return Iter(Table, Key)
                        else
                            return TrueEnv[Key](Table)
                        end
                    end)
                end

                local HasEnvValue = EnvValues[Key] ~= nil
                local a = HasEnvValue and EnvValues[Key] or (Pristine and {TrueEnv[Key]} or nil)
                local Indexed = Index(Key)

                -- IsExec already computed at the top of this function.
                if a or (Find({14, 13, 12}, #Key) and not IsExec) then return (a or {})[1] end

                if Settings.env_index then
                    Append(`local _ = {Indexed}`)
                end

                if Settings.spy_exec_only then
                    if not IsExec then return (a or {})[1] end

                    if Pristine then
                        if GetType(Key) == "function" then --> antitamper
                            return function(...)
                                if Typeof(...) == "function" then
                                    return a[1](...)
                                end
                                return Spy(AddVar("", "", `{Key}({BeautifyTuple(...)})`, "__call"))
                            end
                        end
                    end

                    return Spy(Indexed) --> if its not a function or pristine isnt on
                end

                TrackSpyHit(Key)
                return Spy(Indexed)
            end,
            __newindex = function(_, Key, Value)
                --print("Newindex",Key,Value)

                EnvValues[Key] = {Value}

                -- PureVM: store the value but don't count it as an operation;
                -- the VM writes many internal temporaries during bootstrap.
                if PureVM then return end

                OpCount += 1

                OpCountCheck()

                -- Also apply the PureVM time-based cap here so that scripts whose
                -- dispatch loops write globals (rather than indexing them) are still
                -- stopped when the deadline is reached.
                if IsPureVMObfuscator then
                    CheckBootstrapTimeout()
                end

                if Settings.spy_exec_only then return end

                local IsFunc = Typeof(Value) == "function"
                local Indexed = Index(Key)

                if IsFunc and not Settings.spy_exec_only then
                    -- LIMITATION: Function definitions written to the global environment
                    -- (e.g. `function myFunc() ... end` at the top level of an obfuscated
                    -- script) are emitted directly into Output[] without calling Append(),
                    -- which would prefix the line with the current Tab indent string.
                    -- The intent is that top-level function definitions should always be
                    -- emitted at zero indent so the output stays readable.
                    -- However, if __newindex fires while the script is inside a nested
                    -- scope (NestCount > 0 or CurrentIndent > 0), the function body will
                    -- still be emitted at indent 0, breaking the visual nesting of the
                    -- output.  Using `Append()` instead would fix the indenting but would
                    -- add the Tab prefix to multi-line function bodies, which then look
                    -- wrong because only the first line gets the prefix.
                    Output[#Output+1] = Beautify(Value, CurrentIndent + 1, {FuncName = Key}); --! By not using append(), we don't add extra tabs.
                    return
                elseif not IsFunc then
                    Append(`{Indexed} = {Beautify(Value, CurrentIndent + 1)}`)
                end
            end,
            __tostring = function() return "getfenv()" end,
            __metatable = nil,
            __iter = Iter
        })

        rawset(Locked, "P", "getfenv()")
        rawset(Locked, "V", Locked)

        -- FIX: Provide a stable getfenv implementation so that VM anti-tamper
        -- checks comparing `getfenv == storedRef` pass correctly.
        --
        -- Without this fix the __index handler at line 2091 creates a NEW
        -- function object on every call to getfenv (because Lua allocates a
        -- fresh closure each time the `function() return Locked end` literal is
        -- evaluated).  Luraph-style obfuscators store a reference to getfenv at
        -- startup and then periodically check that the stored reference is still
        -- equal to the current value of getfenv.  Because a new closure ≠ the
        -- original one, the equality check always fails, trapping the VM in an
        -- infinite anti-tamper retry loop (~265 K iterations per second) and
        -- preventing the inner script from ever executing.
        --
        -- By rawset-ing a single cached closure as the "getfenv" key we ensure
        -- that every access—whether from the VM at start-up or from Luraph's
        -- periodic check—returns the identical function object.
        local _getfenvFn = function() return Locked end
        rawset(Locked, "getfenv", _getfenvFn)

        Internal[Locked] = "getfenv()"
    end

    --SetfenvResult = table.pack(pcall(setfenv(Function, Locked), Unpack(Params)))

    -- For PureVM obfuscators the dispatch loop never touches Locked, so the
    -- CheckBootstrapTimeout() calls in __index/__newindex may not fire in time.
    -- Install a Luau instruction-count hook (fires every 10 000 instructions)
    -- that checks the wall-clock deadline and raises an error if exceeded.
    -- Guarded with a nil-check because Lune 0.10 does not expose debug.sethook
    -- (its debug table only contains debug.info and debug.traceback); when
    -- unavailable the __index/__newindex clock checks and the Hooks.pcall
    -- wrapper serve as fallbacks.
    local PureVMHookActive = false
    if IsPureVMObfuscator and Settings.max_bootstrap_seconds > 0 and debug.sethook then
        debug.sethook(function()
            if Clock() - BootstrapStartedAt >= Settings.max_bootstrap_seconds then
                debug.sethook()
                BootstrapTimedOut = true
                error(`PureVM execution timed out after {Settings.max_bootstrap_seconds}s. Partial output was saved.`, 0)
            end
        end, "", 10000)
        PureVMHookActive = true
    end

    SetfenvResult = table.pack(pcall(setfenv(Function, Locked), Unpack(Params)))

    -- Always clear the instruction hook after execution finishes (success or error).
    if PureVMHookActive then
        debug.sethook()
    end

    local ReturnValue = ""

    if not SetfenvResult[1] then
        local Err = SetfenvResult[2]
        local ErrStr = Tostring(Err)
        -- PureVM and ConcreteBootstrap timeouts are analysis limits imposed by
        -- this tool, not errors in the obfuscated script itself. Emitting them
        -- as a Luau comment keeps the output file valid and lets any spy output
        -- captured above remain readable. All other execution failures keep the
        -- error() form so the reconstructed script behaviour is accurate.
        if BootstrapTimedOut then
            ReturnValue = `-- [UnveilR] {ErrStr}`
        else
            ReturnValue = `error({Beautify(Err)})`
        end
    else
        if #SetfenvResult > 1 then -- Ignoring the true, is there a return value?
            ReturnValue = "return "
            for i = 2, SetfenvResult.n do
                ReturnValue ..= Beautify(SetfenvResult[i], CurrentIndent + 1) .. ", "
            end
            ReturnValue = Sub(ReturnValue, 1, -3)
        end
    end

    if Original then
        Insert(Output, ReturnValue)
    end

    if Settings.print_env_hits then
        local Sorted = {}

        for Key, Count in next, EnvHits do
            Insert(Sorted, { Key, Count })
        end

        table.sort(Sorted, function(a, b)
            return a[2] > b[2]
        end)

        for i = 1, math.min(15, #Sorted) do
            local Hit = Sorted[i]
            warn(`Env hit {i}: {Hit[1]} x{Hit[2]}`)
        end
    end

    if Settings.print_spy_hits then
        local Sorted = {}

        for Path, Count in next, SpyHits do
            Insert(Sorted, { Path, Count })
        end

        table.sort(Sorted, function(a, b)
            return a[2] > b[2]
        end)

        for i = 1, math.min(15, #Sorted) do
            local Hit = Sorted[i]
            warn(`Spy hit {i}: {Hit[1]} x{Hit[2]}`)
        end
    end

    local Out = ""
    local Replace = {}

    --[[
        The Process
        Get 1 time use variable
        Loop through ALL variables
        If any of those are inside it, de-nest
        And then replace that variable with the new value.

        What about if it's multiline? - I dont know
    ]]

    local function CaseInsensitive(A)local Out = ""; for _, Letter in Next, Split(A, "") do Out ..= `([{Upper(Letter)}{Lower(Letter)}])`end return Out end

    local function DecodeArgs(Str)
        local Args = {}

        for _, v in next, Split(Str, ", ") do
            local Value, Number = nil, Tonumber(v);

            if Sub(v, 1, 1) == '"' then
                Value = Sub(v, 2, -2)
            elseif Number then
                Value = Number
            elseif v == "true" then
                Value = true
            elseif v == "false" then
                Value = false
            else
                Value = v
            end

            Insert(Args, Value)
        end

        return Args
    end

    local function GetName(Var, Value, Side2, Old)
        local VarId = Match(Var, "%d+") or ""

        local Name;
        local IsNamecall = string.find(Side2, ":") and Value.Tag == "__call"

        local Comp = {
            ["<"] = "is_less",
            [">"] = "is_greater",
            ["<="] = "less_equal",
            [">="] = "greater_equal"
        }

        if IsNamecall then
            local Calls = Split(Side2, ":")
            local Args = DecodeArgs(Match(Side2, "%((.-)%)"))

            Name = Split(Calls[#Calls], "(")[1]

            if Find({"FindFirstChild", "WaitForChild", "FindFirstChildOfClass", "GetService"}, Name) then Name = Args[1] .. VarId end

            Name = Gsub(Name, CaseInsensitive("Get"), "")
            Name = Gsub(Name, CaseInsensitive("Make"), "")
            Name = Gsub(Name, CaseInsensitive("Create"), "")
            Name = Gsub(Name, CaseInsensitive("Decode"), "%1ecoded")
            Name = Gsub(Name, CaseInsensitive("Encode"), "%1ncoded")
        elseif Value.Tag == "__index" then
            local Indexes = SplitIDX(Value.Value)
            Name = Indexes[#Indexes]
        elseif Value.Tag == "__comp" then
            local Symbol = Match(Side2, "[<>]=?")
            local Keyword = Match(Side2, "%w+")

            Name = Comp[Symbol or Keyword] or "unknown"
        elseif Value.Tag == "__len" then
            Name = "len"
        elseif Value.Tag == "__eq" then
            local Type = Match(Value.Value, "[~=]=")

            if Type == "~=" then
                Name = "not_equal"
            else
                Name = "is_equal"
            end
        elseif Value.Tag == "__call" then
            local Out = Values[Var].Value
            local Old, Changed = Out, true;

            while Changed do
                for Var2, Value in next, Values do
                    local v = Value.Value
                    if not v or Value.Usage > 1 or Var2 == Var then continue end
                    Out = SubstituteVar(Out, Var2, RE_Safe(v))
                end

                Changed, Old = Out ~= Old, Out
            end
            
            local Path = Split(Out, "(")[1]
            local Indexes = Split(Path, ".")
            local First = Indexes[1]
            local Args = DecodeArgs(Match(Side2, "%((.-)%)"))

            if Path == "Instance.new" then
                Name = Args[1]
            elseif First == "Vector3" or First == "Vector2" or First == "CFrame" then
                local n = Sub(First, 1, First == "CFrame" and 3 or 2) .. Sub(First, #First) .. "_" -- v3 or v2

                Name = n .. Indexes[2]
            else
                Name = Gsub(Path, "%W", "") .. "_call"
            end
        end

        if Name then Name = Deglobal(Name .. GetVar(Name)) end
        if not Name or Match(Name, "[^A-Za-z0-9_]") or Name == "" or Tonumber(Sub(Name, 1, 1)) then Name = Var else Replace[Var] = Name end

        return Name and `local {Name} ={Side2}` or Old
    end

    local CachedSafe = {}

    local function GetSafe(val)
    	if not CachedSafe[val] then
    		CachedSafe[val] = RE_Safe(val)
	    end
	    return CachedSafe[val]
    end

    -- SubstituteVar: replace all word-boundary occurrences of `Var` in `Str` with
    -- `SafeReplacement` (already RE_Safe'd).  Two Gsubst are needed:
    --   • `([^%w_])` catches Var followed by a non-identifier character (guards
    --     against "var1" matching inside "var1a" or "var1_2").
    --   • `$` catches Var at the very end of the string where no following char
    --     exists for the capture group to match.
    local function SubstituteVar(Str, Var, SafeReplacement)
        Str = Gsub(Str, Var .. "([^%w_])", SafeReplacement .. "%1")
        Str = Gsub(Str, Var .. "$", SafeReplacement)
        return Str
    end

    local function HandleSplit(Separated)
	    local Side1, Side2 = Separated[1], Concat(Move(Separated, 2, #Separated, 1, {}), "=")
	    local IsLocal = Sub(Side1, 1, 5) == "local"

	    local Var = IsLocal and Sub(Side1, 7, -2)
	    local Value = Values[Var]
	    local Old = `{Side1}={Side2}`

        if not Var or not Value or not Value.Value then return Old end --* safe (performance)

	    if Value.Usage == 1 or Value.Usage < 0 then
		    local Val = Value.Value

		    -- FIX (temporary limitation — two issues):
		    -- Issue 1 (partial-identifier collision): The old `(%D)` pattern only
		    -- guards against a trailing digit, so "var1" would wrongly match inside
		    -- "var1_2" or "var1a" (where `_` and `a` are non-digits but are valid
		    -- identifier chars).  `([^%w_])` fixes this by only matching when the
		    -- variable name is NOT followed by any alphanumeric or underscore char.
		    -- Issue 2 (end-of-string): when the variable name sits at the end of the
		    -- expression string there is no following character, so no pattern with a
		    -- capture group ever matches.  A second Gsub with `$` handles that case.
		    -- Issues 3 (string boundaries) and 4 (substitution ordering) remain open;
		    -- they require a proper AST-level inliner rather than text substitution.
		    for var, val in next, Values do
			    local valVal = val.Value
			    if not valVal or val.Usage > 1 then continue end

			    Val = SubstituteVar(Val, var, GetSafe(valVal))
		    end

		    Replace[Var] = Val
	    elseif Value.Usage == 0 then
		    return Value.Tag == "__call" and Value.Value or `local _ ={Side2}` --* safe
	    else
		    if not Settings.varRenamer then return Old end
		    return GetName(Var, Value, Side2, Old) --* maybe safe
	    end
    end

    --* ── Post-process / minifier pass ────────────────────────────────────
    --* After the script finishes executing, the raw Output[] array is walked
    --* once more to clean up the emitted code:
    --*
    --*  HandleSplit – for every line of the form `local <Var> = <Expr>`:
    --*    • Usage == 0  : variable was never read → drop it (emit `local _ =`
    --*                    for __call side-effects, otherwise discard entirely).
    --*    • Usage == 1  : single-use → inline the expression wherever Var
    --*                    appears, add to Replace[].  All transitively single-use
    --*                    sub-expressions are also inlined.
    --*    • Usage >= 2  : keep the variable, but optionally rename it via
    --*                    GetName() when Settings.varRenamer is true.
    --*
    --*  After the per-line pass, a second loop applies the Replace[] map with
    --*  a regex-substitute so all occurrences are updated in the final string.
    --*  `not not` is collapsed to nothing, and repeated blank lines are removed.
    --*
    --* NOTE: The inliner uses simple pattern matching (not a proper AST walk)
    --* which can produce incorrect results for some edge-cases.  The `--!` marker
    --* comments in the code indicate known unsafe sites.
    local Minify = Settings.minifier
    local NewOut = Output

    if Minify then
        for _, v in next, NewOut do
            local Stripped = Strip(v)
            local Separated = Split(Stripped, "=")

            local Spaces = Match(v, "^%s+") or ""

            if #Separated > 1 then
                local Handled = HandleSplit(Separated) --! the big bad punisher
                if not Handled then continue end
                v = Spaces .. Handled
            end

            Out ..= v .. "\n"
        end

        local Old, Changed = Out, true;

        while Changed do
            -- FIX (temporary limitation): Collapse `not not` in all boolean-context
            -- keywords, not just `if`.  `not not <expr>` always simplifies to just
            -- `<expr>` in an if/while/elseif guard because those positions test for
            -- truthiness (any non-nil, non-false value is treated as true) rather than
            -- requiring a strict boolean, so the double negation has no effect.
            -- `return not not x` is intentionally excluded because removing it could
            -- change the actual return value for non-boolean truthy values.
            -- Uses `%s+` to handle any amount of whitespace (spaces or tabs) between
            -- the keyword and the `not not` tokens.
            for _, Kw in ipairs({"if", "while", "elseif"}) do
                Out = Gsub(Out, Kw .. "%s+not%s+not%s+", Kw .. " ")
            end

            for Var, Value in next, Replace do
                Out = SubstituteVar(Out, Var, RE_Safe(Value))
            end

            Changed, Old = Out ~= Old, Out
        end
    else
        Out = Concat(NewOut, "\n")
    end

    Out = Gsub(Out, "%s*\n%s*\n", "\n") --> Make it look better
    
    return Strip(Out, true), ReturnValue
end

--* ── Obf ───────────────────────────────────────────────────────────────
--* Pre-process a Luau source file through the external unparser so that the
--* dynamic analysis pass can observe conditional branches.
--*
--* Steps performed:
--*   1. Invoke `lune cli.lua --LuaU --preset Minify [--hookOp] <Path>`
--*      The unparser parses the AST and re-emits the script with optional
--*      hookOp instrumentation (inserts CHECKIF / CHECKAND / CHECKNOT /
--*      __EQ / __NEQ / CHECKOR / COMPL … calls at every conditional site).
--*   2. The unparser writes its result to `<Path>.obfuscated.lua`.
--*   3. Obf() reads that file, deletes it, and returns the content string.
--*
--* Expected: Path must be a file path (not raw source). The top-level cli.lua
--* must be present and `lune` (or `lune.exe`) must be in PATH.
--* If no working Lune runtime is found, Obf() falls back to returning the
--* raw file contents and logs a warning.
--* If hookOp is false the CHECKIF/CHECKAND hooks are absent; conditionals
--* will not be recorded but the script will be less likely to break.
function Obf(Path)
    local Source = FileSystem.read(Path)

    -- PureVM obfuscators break when hookOp rewrites their AST (the VM's
    -- bytecode tables, for-loops and dispatch logic are not designed to
    -- survive CHECKIF/CHECKWHILE injection).  Automatically skip hookOp
    -- for these scripts so the user does not have to pass --hookOp=false.
    if IsPureVMObfuscator(Source) then
        warn("PureVM obfuscator detected (no loadstring/load call). Automatically disabling --hookOp to preserve the VM dispatch loop.")
        Settings.hookOp = false
        return Source
    end

    -- FIX: Use `lune run testing/prom/src/cli.lua` (the correct sub-command and
    -- relative path from the repo root).  The old invocation used `"cli.lua"` as
    -- the first positional argument to lune which lune 0.10+ rejects with
    -- "unrecognized subcommand 'cli.lua'", causing the process to exit non-zero.
    local Args = {
        "run",
        "testing/prom/src/cli.lua",
        "--LuaU",
        "--preset", "Minify"
    }

    if Settings.hookOp then Insert(Args, "--hookOp") end

    Insert(Args, Path)

    local RuntimeCandidates = {}

    if fs.isFile("lune.exe") then
        Insert(RuntimeCandidates, "lune.exe")
        Insert(RuntimeCandidates, "lune")
    else
        Insert(RuntimeCandidates, "lune")
        Insert(RuntimeCandidates, "lune.exe")
    end

    local Success, Out

    for _, Runtime in next, RuntimeCandidates do
        Success, Out = pcall(function()
            return Process.exec(Runtime, Args)
        end)

        if Success then
            break
        end
    end

    -- If Out.ok is false the lune process exited non-zero (e.g. script parse
    -- error, wrong sub-command); fall back to raw source so we do not try to
    -- read a .obfuscated.lua file that was never written.
    if not Success or not Out.ok then
        warn(`Skipping obfuscation: {Success and Out.stderr or Tostring(Out)}. Using raw source.`)
        return Source
    end

    fs.writeFile("Output.txt", Out.stdout)
    warn("Errors:", Out.stderr)

    local Splitted = Split(Path, ".")
    local OutPath = Path

    -- Strip the trailing .lua or .luau extension before appending .obfuscated.lua
    -- so that foo.lua → foo.obfuscated.lua and foo.luau → foo.obfuscated.lua
    -- (matching the path that cli.lua writes to).
    local LastExt = Splitted[#Splitted]
    if LastExt == "lua" or LastExt == "luau" then
        OutPath = Concat(Move(Splitted, 1, #Splitted - 1, 1, {}), ".")
    end

    local FilePath = `{OutPath}.obfuscated.lua`

    local Content = FileSystem.read(FilePath)
    fs.removeFile(FilePath)

    return Content
end

--* ── Decode ────────────────────────────────────────────────────────────
--* Top-level entry point.  Given a file path it runs the full pipeline:
--*
--*   1. Read the file from disk.
--*   2. (Unless Settings.raw) pre-process with Obf() to inject hooks.
--*   3. Call Main() to run the script inside the spy sandbox and collect
--*      the emitted output.
--*   4. Prepend a metadata header (version, discord, time taken).
--*   5. If Top.add_if_comment is set, prepend an explanation of the
--*      if-statement comment notation used in the output.
--*   6. Write the final string to Settings.outfile (default: out2.lua).
--*
--* The input file is deleted after reading so temporary copies do not
--* accumulate in the working directory.
--*
--* Expected: File must be a valid path readable by the Lune fs module.
--* On success the output file is written; on failure a partial output may
--* still exist if saveFails is enabled.
local function Decode(File)
    local function StrToValue(Str)
        if Str == "false" then return false
        elseif Str == "true" then return true
        elseif Str == "nil" then return nil
        elseif tonumber(Str) then return tonumber(Str)
        else return Str end
    end

    local Source = fs.readFile(File)

    -- Preserve the raw file content for MoonSec signature detection inside Main().
    -- Obf() rewrites the AST (hookOp) which can remove `_ENV` references; storing
    -- the original text here lets Main() detect MoonSec anti-tamper reliably.
    OriginalSource = Source

    Settings.outfile = Settings.outfile or "out2.lua"

    local Start = Clock()
    local Success, Code = pcall(Main, Settings.raw and Source or Obf(File), nil, nil, true)
    local End = Clock() - Start

    print("Took",End,"seconds to process.",Success)

    -- FIX: When deobfuscation fails, print the error message to the console so it
    -- is visible without having to open the output file.  The output file still
    -- contains the `error(...)` line so the user can see what went wrong there too.
    -- LIMITATION (external): non-string Luau error objects (tables, userdata) are
    -- serialised via Beautify() which may not capture all detail (e.g. an Instance
    -- passed to error() only shows its class name).  Full stack traces are not
    -- captured because pcall discards them.
    --
    -- ErrMsg (via Tostring) is used for the human-readable console print and the
    -- `-- deobfuscation error:` comment line in the output.  Beautify(Code) is used
    -- separately for the `error(…)` Luau expression in the output because Beautify
    -- correctly wraps strings in quotes, serialises tables as {…}, etc., while
    -- Tostring always returns a plain string representation.
    if type(Code) == "userdata" or not Success then
        local ErrMsg = Tostring(Code)
        print("Deobfuscation error:", ErrMsg)
        Code = `-- deobfuscation error: {ErrMsg}\nerror({Beautify(Code)})`
    end

    --[[local Metadata = {
        time = `{os.date("%d/%m/%Y")} @ {os.date("%H:%M:%S")}`,
        time_taken = End,
        discord = "discord.gg/threaded",
        opcount = GlobalOpCount,
        maxops = Settings.max_ops
    }]]

    local Metadata = {
        discord = "discord.gg/threaded",
        time_taken = End
    }
    
    local Out = `--[[\n\tThis file was generated with UnveilR v{Version}.\n`
    for k, v in next, Metadata do
        Out ..= `\t{k} = {v};\n`
    end

    Out ..= "]]\n\n"

    if Top.add_if_comment then
        Out ..= "-- When you see an if/elseif statement, the only correct thing you see is the first argument, the code after is ALL invalid. (theres an end right after)\n"
    end

    Out ..= Code

    if fs.isFile("input.lua") then fs.removeFile("input.lua") end
    fs.writeFile(Settings.outfile or "out2.lua", Out)
end

assert(Settings.input, "missing input file – pass the path as a positional argument: lune hi.luau <file>")
assert(fs.isFile(Settings.input), "input file not found: " .. Settings.input)

return Decode(Settings.input)