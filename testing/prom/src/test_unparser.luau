--* ══════════════════════════════════════════════════════════════════════
--* testing/prom/src/test_unparser.luau  –  Tests for unparser.luau
--* ══════════════════════════════════════════════════════════════════════
--*
--* Runs unparser.luau as a child process and checks its output.
--* Execute with:
--*   lune run testing/prom/src/test_unparser.luau

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

-- Write Source to a temp file, run unparser.luau on it, return output text.
-- ExtraArgs are inserted after the output path argument.
local function RunUnparser(Source, ExtraArgs)
    local InputPath  = "/tmp/unparser_test_input.lua"
    local OutputPath = "/tmp/unparser_test_output.lua"

    fs.writeFile(InputPath, Source)

    local Args = {
        "run",
        "testing/prom/src/unparser.luau",
        InputPath,
        OutputPath,
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
    if Result.ok and fs.isFile(OutputPath) then
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
        {"run", "testing/prom/src/unparser.luau"},
        { cwd = RepoRoot }
    )
    Assert(not Result.ok, "expected non-zero exit when no args provided")
end)

Test("error when output argument is missing", function()
    local InputPath = "/tmp/unparser_noout_input.lua"
    fs.writeFile(InputPath, "local x = 1\n")
    local Result = process.exec(
        "lune",
        {"run", "testing/prom/src/unparser.luau", InputPath},
        { cwd = RepoRoot }
    )
    fs.removeFile(InputPath)
    Assert(not Result.ok, "expected non-zero exit when output arg is missing")
end)

-- ── Tests: local variable pass-through ────────────────────────────────

Test("local variable assignment is emitted", function()
    local _, Output = RunUnparser("local x = 1\n")
    AssertContains(Output, "local x = 1")
end)

Test("local string assignment is emitted", function()
    local _, Output = RunUnparser('local s = "hello"\n')
    AssertContains(Output, 'local s = "hello"')
end)

-- ── Tests: function calls ─────────────────────────────────────────────

Test("function call is wrapped with CALL()", function()
    local _, Output = RunUnparser('print("hello")\n')
    AssertContains(Output, "CALL(print,")
end)

Test("function call arguments are preserved", function()
    local _, Output = RunUnparser('foo(1, 2, 3)\n')
    AssertContains(Output, "CALL(foo, 1, 2, 3)")
end)

Test("method call is wrapped with NAMECALL()", function()
    local _, Output = RunUnparser('obj:method(x)\n')
    AssertContains(Output, "NAMECALL(obj,")
end)

-- ── Tests: control flow instrumentation ───────────────────────────────

Test("if condition is wrapped with CHECKIF()", function()
    local _, Output = RunUnparser("if x then end\n")
    AssertContains(Output, "CHECKIF(x,")
end)

Test("if block end marker is emitted", function()
    local _, Output = RunUnparser("if x then end\n")
    AssertContains(Output, "checkifend(")
end)

Test("while condition is wrapped with checkwhile()", function()
    local _, Output = RunUnparser("while x do end\n")
    AssertContains(Output, "checkwhile(")
end)

Test("while block end marker is emitted", function()
    local _, Output = RunUnparser("while x do end\n")
    AssertContains(Output, "checkwhileend(")
end)

Test("binary comparison < is wrapped with COMPL()", function()
    local _, Output = RunUnparser("if x < 10 then end\n")
    AssertContains(Output, "COMPL(")
end)

Test("binary comparison > is wrapped with COMPG()", function()
    local _, Output = RunUnparser("if x > 0 then end\n")
    AssertContains(Output, "COMPG(")
end)

Test("binary and is wrapped with CHECKAND()", function()
    local _, Output = RunUnparser("if a and b then end\n")
    AssertContains(Output, "CHECKAND(")
end)

Test("binary or is wrapped with CHECKOR()", function()
    local _, Output = RunUnparser("if a or b then end\n")
    AssertContains(Output, "CHECKOR(")
end)

-- ── Tests: return statements ───────────────────────────────────────────

Test("return statement is emitted", function()
    local _, Output = RunUnparser("return 42\n")
    AssertContains(Output, "return 42")
end)

-- ── Tests: local function declarations ────────────────────────────────

Test("local function declaration is emitted", function()
    local _, Output = RunUnparser("local function foo(a, b)\n  return a + b\nend\n")
    AssertContains(Output, "local function foo(a, b)")
    AssertContains(Output, "return a + b")
end)

-- ── Tests: callId prefix ──────────────────────────────────────────────

Test("callId prefix is prepended to instrumentation calls", function()
    local _, Output = RunUnparser('print("hi")\n', {"PREFIX_"})
    AssertContains(Output, "PREFIX_CALL(print,")
end)

Test("callId '0' results in no prefix", function()
    local _, Output = RunUnparser('print("hi")\n', {"0"})
    AssertContains(Output, "CALL(print,")
    AssertNotContains(Output, "0CALL(")
end)

-- ── Tests: constant collection mode ───────────────────────────────────

Test("constant collection: table constructor is wrapped with CONSTRUCT()", function()
    local _, Output = RunUnparser("local t = {}\n", {"0", "1"})
    AssertContains(Output, "CONSTRUCT(")
end)

Test("constant collection: index access is wrapped with CHECKINDEX()", function()
    local _, Output = RunUnparser('local x = t["key"]\n', {"0", "1"})
    AssertContains(Output, "CHECKINDEX(")
end)

Test("constant collection disabled: no CHECKINDEX in plain index access", function()
    local _, Output = RunUnparser('local x = t["key"]\n')
    AssertNotContains(Output, "CHECKINDEX(")
end)

-- ── Tests: multiple statements ─────────────────────────────────────────

Test("multiple statements are all emitted", function()
    local Source = "local a = 1\nlocal b = 2\nlocal c = 3\n"
    local _, Output = RunUnparser(Source)
    AssertContains(Output, "local a = 1")
    AssertContains(Output, "local b = 2")
    AssertContains(Output, "local c = 3")
end)

-- ── Summary ───────────────────────────────────────────────────────────

print(string.format("\nunparser.luau tests: %d passed, %d failed", Passed, Failed))

if Failed > 0 then
    process.exit(1)
end
