--* ══════════════════════════════════════════════════════════════════════
--* testing/prom/src/test_hi.luau  –  Tests for hi.luau
--* ══════════════════════════════════════════════════════════════════════
--*
--* Runs hi.luau as a child process and checks its output for correctness.
--* Execute with:
--*   lune run testing/prom/src/test_hi.luau

local process = require("@lune/process")
local fs      = require("@lune/fs")

-- ── Helpers ───────────────────────────────────────────────────────────

-- Derive the repository root from the current working directory.
-- Tests must be run from the repository root with `lune run`.
local RepoRoot = process.cwd:gsub("/$", "")

local Passed = 0
local Failed = 0

local function Test(Name, Fn)
    local Ok, Err = pcall(Fn)
    if Ok then
        print("[PASS] " .. Name)
        Passed += 1
    else
        print("[FAIL] " .. Name)
        print("       " .. tostring(Err))
        Failed += 1
    end
end

local function Assert(Condition, Message)
    if not Condition then
        error(Message or "assertion failed", 2)
    end
end

local function AssertContains(Haystack, Needle)
    if not string.find(Haystack, Needle, 1, true) then
        error(string.format("expected output to contain %q\n       got: %q", Needle, Haystack), 2)
    end
end

local function AssertNotContains(Haystack, Needle)
    if string.find(Haystack, Needle, 1, true) then
        error(string.format("expected output to NOT contain %q\n       got: %q", Needle, Haystack), 2)
    end
end

-- Write Source to a temp file, run hi.luau on it, and return the process
-- result along with the contents of the output file.  Cleans up temp files.
-- ExtraArgs are appended to the hi.luau invocation.
local function RunHi(Source, ExtraArgs)
    local InputPath  = "/tmp/hi_test_input.lua"
    local OutputPath = "/tmp/hi_test_output.lua"

    fs.writeFile(InputPath, Source)

    local Args = {
        "run",
        "hi.luau",
        InputPath,
        "--outfile=" .. OutputPath,
    }
    for _, Arg in ExtraArgs or {} do
        table.insert(Args, Arg)
    end

    local Result = process.exec(
        "lune",
        Args,
        { cwd = RepoRoot }
    )

    local Output = ""
    if fs.isFile(OutputPath) then
        Output = fs.readFile(OutputPath)
        fs.removeFile(OutputPath)
    end
    if fs.isFile(InputPath) then
        fs.removeFile(InputPath)
    end

    return Result, Output
end

-- ── Tests: error handling ─────────────────────────────────────────────

Test("error when input argument is missing", function()
    local Result = process.exec(
        "lune",
        {"run", "hi.luau"},
        { cwd = RepoRoot }
    )
    Assert(not Result.ok, "expected non-zero exit when no input provided")
end)

Test("error when input file does not exist", function()
    local Result = process.exec(
        "lune",
        {"run", "hi.luau", "/tmp/hi_nonexistent_99999.lua"},
        { cwd = RepoRoot }
    )
    Assert(not Result.ok, "expected non-zero exit for missing input file")
end)

-- ── Tests: basic output structure ─────────────────────────────────────

Test("output file is created for valid input", function()
    local InputPath  = "/tmp/hi_smoke_input.lua"
    local OutputPath = "/tmp/hi_smoke_output.lua"
    fs.writeFile(InputPath, "local x = 1\n")
    local Result = process.exec(
        "lune",
        {"run", "hi.luau", InputPath, "--outfile=" .. OutputPath, "--raw=true"},
        { cwd = RepoRoot }
    )
    local Exists = fs.isFile(OutputPath)
    if Exists then fs.removeFile(OutputPath) end
    fs.removeFile(InputPath)
    Assert(Result.ok, "hi.luau exited with error: " .. Result.stderr)
    Assert(Exists, "output file was not created")
end)

Test("output contains UnveilR metadata header", function()
    local _, Output = RunHi("local x = 1\n", {"--raw=true"})
    AssertContains(Output, "This file was generated with UnveilR")
end)

Test("output header contains version string", function()
    local _, Output = RunHi("local x = 1\n", {"--raw=true"})
    AssertContains(Output, "UnveilR v")
end)

-- ── Tests: spy sandbox (global tracking) ──────────────────────────────

Test("global index access is tracked in output (raw mode)", function()
    local _, Output = RunHi("local x = game.Players\n", {"--raw=true"})
    AssertContains(Output, "game.Players")
end)

Test("method call is tracked in output (raw mode)", function()
    local _, Output = RunHi('local Players = game:GetService("Players")\n', {"--raw=true"})
    AssertContains(Output, 'GetService("Players")')
end)

Test("if condition tracking emits if/end comment (hookOp mode)", function()
    local _, Output = RunHi("if game then print('yes') end\n")
    AssertContains(Output, "if game then")
    AssertContains(Output, "end")
end)

-- ── Tests: --raw flag ─────────────────────────────────────────────────

Test("--raw=true skips hookOp preprocessing and still produces output", function()
    local Result, Output = RunHi("local x = game.Players\n", {"--raw=true"})
    Assert(Result.ok, "hi.luau exited with error in raw mode: " .. Result.stderr)
    AssertContains(Output, "This file was generated with UnveilR")
    AssertContains(Output, "game.Players")
end)

-- ── Tests: --minifier flag ────────────────────────────────────────────

Test("--minifier=false: unused variable keeps original generated name instead of underscore", function()
    local _, Output = RunHi("local x = game.Players\n", {"--raw=true", "--minifier=false"})
    -- With minifier off, the variable should keep its generated name (e.g. var1)
    -- rather than being replaced with _ (which the minifier does for zero-use vars).
    AssertContains(Output, "var")
    AssertNotContains(Output, "local _ =")
end)

Test("--minifier=true (default): unused variable is replaced with _", function()
    local _, Output = RunHi("local x = game.Players\n", {"--raw=true"})
    -- With minifier on, zero-use __index vars become `local _ = ...`
    AssertContains(Output, "local _ = game.Players")
end)

-- ── Tests: --outfile flag ─────────────────────────────────────────────

Test("--outfile writes to the specified path", function()
    local InputPath  = "/tmp/hi_outfile_test_input.lua"
    local OutputPath = "/tmp/hi_outfile_custom_123.lua"
    fs.writeFile(InputPath, "local x = 1\n")
    if fs.isFile(OutputPath) then fs.removeFile(OutputPath) end

    local Result = process.exec(
        "lune",
        {"run", "hi.luau", InputPath, "--outfile=" .. OutputPath, "--raw=true"},
        { cwd = RepoRoot }
    )
    local Exists = fs.isFile(OutputPath)
    if Exists then fs.removeFile(OutputPath) end
    fs.removeFile(InputPath)

    Assert(Result.ok, "hi.luau exited with error: " .. Result.stderr)
    Assert(Exists, "output was not written to the specified --outfile path")
end)

-- ── Tests: hookOp mode (full pipeline) ────────────────────────────────

Test("hookOp mode: output file is created and contains header", function()
    local Result, Output = RunHi("local x = game.Players\n")
    Assert(Result.ok, "hi.luau failed in hookOp mode: " .. Result.stderr)
    AssertContains(Output, "This file was generated with UnveilR")
end)

Test("hookOp mode: global index access appears in output", function()
    local _, Output = RunHi("local x = game.Players\n")
    AssertContains(Output, "game.Players")
end)

-- ── Tests: example obfuscated.lua ────────────────────────────────────
--
-- These tests verify that hi.luau correctly handles the repository's example
-- Luraph-obfuscated script (a real self-contained VM obfuscator, all on one
-- line).  Key expectations after the fixes implemented in this session:
--
--   1. The Luraph anti-tamper check (debug.info(getmetatable, "slnaf"))
--      must NOT appear in the output — that line means the sandbox was
--      detected and the script aborted.
--   2. The old "Too many operations" flood error (wrapped in multiple layers
--      of "Luraph Script:(internal):") must NOT appear — it was caused by
--      the ops counter being exhausted before the anti-tamper even passed.
--   3. The tool MUST terminate within a bounded time (we set a 5-second
--      bootstrap limit so the test suite doesn't block indefinitely).
--
-- hookOp is disabled because Luraph's for-loop structure is incompatible
-- with the hookOp AST rewriter.

-- Run hi.luau on an existing file (not a source string) and return the
-- process result plus the output file contents.  Cleans up the output file.
local function RunHiFile(InputPath, ExtraArgs)
    local OutputPath = "/tmp/hi_test_file_output.lua"
    if fs.isFile(OutputPath) then fs.removeFile(OutputPath) end

    local Args = {
        "run",
        "hi.luau",
        InputPath,
        "--outfile=" .. OutputPath,
    }
    for _, Arg in ExtraArgs or {} do
        table.insert(Args, Arg)
    end

    local Result = process.exec("lune", Args, { cwd = RepoRoot })

    local Output = ""
    if fs.isFile(OutputPath) then
        Output = fs.readFile(OutputPath)
        fs.removeFile(OutputPath)
    end

    return Result, Output
end

-- Shared flags for all obfuscated.lua tests: disable hookOp (incompatible
-- with Luraph), and cap bootstrap time so CI does not block.
local LuraphFlags = {"--hookOp=false", "--max_bootstrap_seconds=5"}

Test("obfuscated.lua: tool exits successfully", function()
    local Result = RunHiFile(RepoRoot .. "/obfuscated.lua", LuraphFlags)
    Assert(Result.ok, "hi.luau exited with error on obfuscated.lua: " .. Result.stderr)
end)

Test("obfuscated.lua: output file is created and non-empty", function()
    local Result, Output = RunHiFile(RepoRoot .. "/obfuscated.lua", LuraphFlags)
    Assert(Result.ok, "hi.luau exited with error: " .. Result.stderr)
    Assert(#Output > 0, "output file was empty for obfuscated.lua")
end)

Test("obfuscated.lua: output contains UnveilR metadata header", function()
    local Result, Output = RunHiFile(RepoRoot .. "/obfuscated.lua", LuraphFlags)
    Assert(Result.ok, "hi.luau exited with error: " .. Result.stderr)
    AssertContains(Output, "This file was generated with UnveilR")
end)

-- The anti-tamper line "debug.info(getmetatable, \"slnaf\")" in the output
-- means Luraph detected our sandbox and aborted.  After the debug.info
-- pass-through fix this line should never appear.
Test("obfuscated.lua: Luraph anti-tamper does not trigger", function()
    local Result, Output = RunHiFile(RepoRoot .. "/obfuscated.lua", LuraphFlags)
    Assert(Result.ok, "hi.luau exited with error: " .. Result.stderr)
    local HasAntiTamperOutput = string.find(Output, 'debug.info(getmetatable, "slnaf")', 1, true) ~= nil
    Assert(not HasAntiTamperOutput,
        "Luraph anti-tamper was triggered (debug.info line present in output) — debug.info pass-through is broken")
end)

-- "Too many operations" wrapped in "Luraph Script:(internal):" was the old
-- failure mode: the ops counter was exhausted before the anti-tamper could
-- even pass.  After the PureVMObfuscator ops fix this pattern must not appear.
-- Both substrings must co-occur to avoid false positives from unrelated output.
Test("obfuscated.lua: ops-flood error is not present", function()
    local Result, Output = RunHiFile(RepoRoot .. "/obfuscated.lua", LuraphFlags)
    Assert(Result.ok, "hi.luau exited with error: " .. Result.stderr)
    local HasOpsFlood = string.find(Output, "Luraph Script:(internal):", 1, true) ~= nil
        and string.find(Output, "Too many operations", 1, true) ~= nil
    Assert(not HasOpsFlood,
        "Ops-flood error pattern found in output — PureVMObfuscator ops skipping is broken")
end)

-- Verify that the output header contains the time_taken metadata.
Test("obfuscated.lua: output contains time_taken metadata", function()
    local Result, Output = RunHiFile(RepoRoot .. "/obfuscated.lua", LuraphFlags)
    Assert(Result.ok, "hi.luau exited with error: " .. Result.stderr)
    AssertContains(Output, "time_taken")
end)

-- Verify that PureVM auto-detection works without manually passing --hookOp=false.
-- The Obf() function should detect the PureVM obfuscator and automatically disable
-- hookOp, so the tool should succeed even when no flags are explicitly passed.
-- The default PureVM timeout (5 s) is used so CI does not block.
Test("obfuscated.lua: PureVM auto-detection disables hookOp automatically", function()
    local Result = RunHiFile(RepoRoot .. "/obfuscated.lua", {})
    Assert(Result.ok, "hi.luau exited with error when relying on PureVM auto-detection: " .. Result.stderr)
end)

-- Verify that the PureVM timeout produces a comment in the output, not an
-- error() call. The output must remain valid Luau and show any spy results
-- that were captured before the timeout, so terminating with error() would
-- be misleading (it implies the original script crashed, not that we timed out).
Test("obfuscated.lua: PureVM timeout appears as comment not error call", function()
    local Result, Output = RunHiFile(RepoRoot .. "/obfuscated.lua", LuraphFlags)
    Assert(Result.ok, "hi.luau exited with error: " .. Result.stderr)
    -- The timeout notice must appear somewhere in the output file.
    AssertContains(Output, "-- [UnveilR]")
    -- It must NOT appear as a Luau error() call.
    AssertNotContains(Output, 'error("PureVM execution timed out')
end)

-- input.  If the VM dispatch table constants leak into the output, the
-- deobfuscator is not intercepting properly.
-- Note: "0X6614" uses uppercase X to match the exact literal in obfuscated.lua.
Test("obfuscated.lua: output does not contain raw VM dispatch patterns", function()
    local Result, Output = RunHiFile(RepoRoot .. "/obfuscated.lua", LuraphFlags)
    Assert(Result.ok, "hi.luau exited with error: " .. Result.stderr)
    AssertNotContains(Output, "0X6614")
    AssertNotContains(Output, "bit32.rrotate")
end)

-- ── Summary ───────────────────────────────────────────────────────────

print(string.format("\nhi.luau tests: %d passed, %d failed", Passed, Failed))

if Failed > 0 then
    process.exit(1)
end
