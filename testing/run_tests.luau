--* ══════════════════════════════════════════════════════════════════════
--* testing/run_tests.luau  –  Top-level test runner
--* ══════════════════════════════════════════════════════════════════════
--*
--* Runs all test suites in testing/prom/src/ and reports a combined
--* pass / fail summary.  Exits with code 1 if any suite fails.
--*
--* Usage (from the repository root):
--*   lune run testing/run_tests.luau

local process = require("@lune/process")

-- ── Helpers ───────────────────────────────────────────────────────────

-- Derive the repository root from the current working directory.
-- Tests must be run from the repository root with `lune run`.
local RepoRoot = process.cwd:gsub("/$", "")

local TotalPassed = 0
local TotalFailed = 0

local function RunSuite(Label, ScriptPath)
    print(string.rep("─", 60))
    print(string.format("▶  %s", Label))
    print(string.rep("─", 60))

    local Result = process.exec(
        "lune",
        {"run", ScriptPath},
        { cwd = RepoRoot }
    )

    -- Print whatever the suite printed to stdout / stderr
    if #Result.stdout > 0 then
        print(Result.stdout)
    end
    if #Result.stderr > 0 then
        print(Result.stderr)
    end

    if Result.ok then
        TotalPassed += 1
    else
        TotalFailed += 1
    end

    print()
end

-- ── Run suites ────────────────────────────────────────────────────────

RunSuite("cli.lua  (text-based hookOp pre-processor)",
         "testing/prom/src/test_cli.luau")

RunSuite("parser.luau  (Luau recursive-descent parser)",
         "testing/prom/src/test_parser.luau")

RunSuite("unparser.luau  (AST-based source re-emitter)",
         "testing/prom/src/test_unparser.luau")

RunSuite("hi.luau  (main deobfuscation engine)",
         "testing/prom/src/test_hi.luau")

-- ── Summary ───────────────────────────────────────────────────────────

print(string.rep("═", 60))
print(string.format(
    "ALL SUITES: %d passed, %d failed",
    TotalPassed, TotalFailed
))
print(string.rep("═", 60))

if TotalFailed > 0 then
    process.exit(1)
end
