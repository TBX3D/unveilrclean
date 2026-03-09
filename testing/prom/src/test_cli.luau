--* ══════════════════════════════════════════════════════════════════════
--* testing/prom/src/test_cli.luau  –  Tests for cli.lua
--* ══════════════════════════════════════════════════════════════════════
--*
--* Runs cli.lua as a child process and checks its output for correctness.
--* Execute with:
--*   lune run testing/prom/src/test_cli.luau

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

-- Write a temporary input file, run cli.lua on it, return the output text.
-- Cleans up both the input and output files afterwards.
local function RunCli(Source, ExtraArgs)
    local InputPath  = "/tmp/cli_test_input.lua"
    local OutputPath = "/tmp/cli_test_input.obfuscated.lua"

    fs.writeFile(InputPath, Source)

    local Args = {"run", "testing/prom/src/cli.lua", "--LuaU", "--preset", "Minify"}
    for _, Arg in ExtraArgs or {} do
        table.insert(Args, Arg)
    end
    table.insert(Args, InputPath)

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
    fs.removeFile(InputPath)

    return Result, Output
end

-- ── Tests ─────────────────────────────────────────────────────────────

Test("pass-through: output equals input when --hookOp is absent", function()
    local Source = "local x = 1\nprint(x)\n"
    local Result, Output = RunCli(Source)
    Assert(Result.ok, "cli.lua exited with error: " .. Result.stderr)
    Assert(Output == Source, string.format("expected %q, got %q", Source, Output))
end)

Test("output file naming: foo.lua → foo.obfuscated.lua", function()
    local InputPath  = "/tmp/cli_naming_test.lua"
    local OutputPath = "/tmp/cli_naming_test.obfuscated.lua"
    fs.writeFile(InputPath, "local x = 1\n")
    local Result = process.exec(
        "lune",
        {"run", "testing/prom/src/cli.lua", InputPath},
        { cwd = RepoRoot }
    )
    Assert(Result.ok, "cli.lua exited with error: " .. Result.stderr)
    Assert(fs.isFile(OutputPath), "output file not created at expected path")
    fs.removeFile(OutputPath)
    fs.removeFile(InputPath)
end)

Test("error when input file argument is missing", function()
    local Result = process.exec(
        "lune",
        {"run", "testing/prom/src/cli.lua"},
        { cwd = RepoRoot }
    )
    Assert(not Result.ok, "expected non-zero exit for missing input")
end)

Test("error when input file does not exist", function()
    local Result = process.exec(
        "lune",
        {"run", "testing/prom/src/cli.lua", "/tmp/does_not_exist_12345.lua"},
        { cwd = RepoRoot }
    )
    Assert(not Result.ok, "expected non-zero exit for missing input file")
end)

Test("hookOp: wraps `if` condition with CHECKIF", function()
    local _, Output = RunCli("if x then\n  print(x)\nend\n", {"--hookOp"})
    AssertContains(Output, "CHECKIF(x)")
    AssertNotContains(Output, "if x then")
end)

Test("hookOp: wraps `elseif` condition with CHECKIF", function()
    local Source = "if a then\n  x()\nelseif b then\n  y()\nend\n"
    local _, Output = RunCli(Source, {"--hookOp"})
    AssertContains(Output, "CHECKIF(a)")
    AssertContains(Output, "CHECKIF(b)")
end)

Test("hookOp: wraps `while` condition with CHECKWHILE and loop id", function()
    local _, Output = RunCli("while x > 0 do\n  x = x - 1\nend\n", {"--hookOp"})
    AssertContains(Output, "CHECKWHILE(")
    AssertContains(Output, ", 1)")
end)

Test("hookOp: multiple while loops receive distinct ids", function()
    local Source = "while a do end\nwhile b do end\n"
    local _, Output = RunCli(Source, {"--hookOp"})
    AssertContains(Output, "CHECKWHILE(a, 1)")
    AssertContains(Output, "CHECKWHILE(b, 2)")
end)

Test("hookOp: rewrites `or` expression with CHECKOR", function()
    local _, Output = RunCli("if a or b then end\n", {"--hookOp"})
    AssertContains(Output, "CHECKOR(")
end)

Test("hookOp: rewrites `and` expression with CHECKAND", function()
    local _, Output = RunCli("if a and b then end\n", {"--hookOp"})
    AssertContains(Output, "CHECKAND(")
end)

Test("hookOp: rewrites `not` expression with CHECKNOT", function()
    local _, Output = RunCli("if not x then end\n", {"--hookOp"})
    AssertContains(Output, "CHECKNOT(")
end)

Test("hookOp: does not rewrite keywords inside string literals", function()
    local Source = 'local s = "if x or y then"\n'
    local _, Output = RunCli(Source, {"--hookOp"})
    AssertContains(Output, '"if x or y then"')
    AssertNotContains(Output, 'CHECKOR("if x')
end)

Test("hookOp: does not rewrite keywords inside line comments", function()
    local Source = "-- if x or y then\nlocal z = 1\n"
    local _, Output = RunCli(Source, {"--hookOp"})
    AssertContains(Output, "-- if x or y then")
end)

Test("hookOp: nested boolean: if a or b and c then", function()
    local _, Output = RunCli("if a or b and c then end\n", {"--hookOp"})
    AssertContains(Output, "CHECKIF(")
    AssertContains(Output, "CHECKOR(")
    AssertContains(Output, "CHECKAND(")
end)

Test("--LuaU and --preset flags accepted without error", function()
    local _, Output = RunCli("local x = 1\n", {"--LuaU", "--preset", "Minify"})
    Assert(Output == "local x = 1\n", "unexpected output: " .. tostring(Output))
end)

-- ── Summary ───────────────────────────────────────────────────────────

print(string.format("\ncli.lua tests: %d passed, %d failed", Passed, Failed))

if Failed > 0 then
    process.exit(1)
end
