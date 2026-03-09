--* ══════════════════════════════════════════════════════════════════════
--* testing/prom/src/test_parser.luau  –  Tests for parser.luau
--* ══════════════════════════════════════════════════════════════════════
--*
--* Requires parser.luau directly and exercises the parsefile() function.
--* Execute with:
--*   lune run testing/prom/src/test_parser.luau

local process = require("@lune/process")
local parser  = require("./parser")

-- ── Helpers ───────────────────────────────────────────────────────────

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

local function AssertEq(Got, Expected)
    if Got ~= Expected then
        error(string.format("expected %q, got %q", tostring(Expected), tostring(Got)), 2)
    end
end

-- Convenience: parse source and return the first top-level statement.
local function FirstStatement(Source)
    local Ast = parser.parsefile(Source)
    return Ast.root.statements[1]
end

-- ── Tests: basic structure ─────────────────────────────────────────────

Test("parsefile returns a table with a root block", function()
    local Ast = parser.parsefile("local x = 1")
    Assert(type(Ast) == "table", "expected table")
    Assert(type(Ast.root) == "table", "expected root table")
    Assert(type(Ast.root.statements) == "table", "expected statements table")
end)

Test("parsefile on empty source returns no statements", function()
    local Ast = parser.parsefile("")
    Assert(type(Ast.root.statements) == "table")
    AssertEq(#Ast.root.statements, 0)
end)

-- ── Tests: local variable declarations ────────────────────────────────

Test("local declaration: tag is 'local'", function()
    local Stmt = FirstStatement("local x = 1")
    AssertEq(Stmt.tag, "local")
    AssertEq(Stmt.kind, "stat")
end)

Test("local declaration: variable name is captured", function()
    local Stmt = FirstStatement("local x = 1")
    local Var  = Stmt.variables[1].node
    AssertEq(Var.name.text, "x")
end)

Test("local declaration: number value has correct tag and value", function()
    local Stmt = FirstStatement("local x = 42")
    local Val  = Stmt.values[1].node
    AssertEq(Val.tag, "number")
    AssertEq(Val.text, "42")
end)

Test("local declaration: string value has correct tag and text", function()
    local Stmt = FirstStatement('local s = "hello"')
    local Val  = Stmt.values[1].node
    AssertEq(Val.tag, "string")
    AssertEq(Val.text, "hello")
end)

Test("local declaration: multiple variables", function()
    local Stmt = FirstStatement("local a, b = 1, 2")
    Assert(#Stmt.variables == 2, "expected 2 variables")
    AssertEq(Stmt.variables[1].node.name.text, "a")
    AssertEq(Stmt.variables[2].node.name.text, "b")
end)

-- ── Tests: assignment statements ──────────────────────────────────────

Test("assignment: tag is 'assign'", function()
    local Stmt = FirstStatement("x = 1")
    AssertEq(Stmt.tag, "assign")
end)

-- ── Tests: if statements ───────────────────────────────────────────────

Test("if statement: tag is 'conditional'", function()
    local Stmt = FirstStatement("if x then end")
    AssertEq(Stmt.tag, "conditional")
end)

Test("if statement: condition is a global reference", function()
    local Stmt = FirstStatement("if myVar then end")
    AssertEq(Stmt.condition.tag, "global")
    AssertEq(Stmt.condition.name.text, "myVar")
end)

Test("if statement: thenblock contains expected statements", function()
    local Stmt = FirstStatement("if x then print(x) end")
    Assert(type(Stmt.thenblock) == "table", "expected thenblock")
    AssertEq(#Stmt.thenblock.statements, 1)
end)

Test("if/elseif statement: elseifs list is populated", function()
    local Stmt = FirstStatement("if a then elseif b then end")
    Assert(type(Stmt.elseifs) == "table")
    Assert(#Stmt.elseifs >= 1, "expected at least one elseif")
end)

-- ── Tests: while loops ────────────────────────────────────────────────

Test("while loop: tag is 'while'", function()
    local Stmt = FirstStatement("while x do end")
    AssertEq(Stmt.tag, "while")
end)

Test("while loop: condition is captured", function()
    local Stmt = FirstStatement("while running do end")
    AssertEq(Stmt.condition.tag, "global")
    AssertEq(Stmt.condition.name.text, "running")
end)

-- ── Tests: for loops ──────────────────────────────────────────────────

Test("numeric for loop: tag is 'for'", function()
    local Stmt = FirstStatement("for i = 1, 10 do end")
    AssertEq(Stmt.tag, "for")
end)

Test("generic for loop: tag is 'forin'", function()
    local Stmt = FirstStatement("for k, v in pairs(t) do end")
    AssertEq(Stmt.tag, "forin")
end)

-- ── Tests: function calls ─────────────────────────────────────────────

Test("function call statement: outer tag is 'expression'", function()
    local Stmt = FirstStatement("print('hi')")
    AssertEq(Stmt.tag, "expression")
end)

Test("function call statement: inner expression tag is 'call'", function()
    local Stmt = FirstStatement("print('hi')")
    AssertEq(Stmt.expression.tag, "call")
end)

Test("function call: callee is captured", function()
    local Stmt = FirstStatement("print('hi')")
    AssertEq(Stmt.expression.func.tag, "global")
    AssertEq(Stmt.expression.func.name.text, "print")
end)

Test("function call: argument count matches", function()
    local Stmt = FirstStatement("foo(1, 2, 3)")
    AssertEq(#Stmt.expression.arguments, 3)
end)

Test("method call (self): self flag is true", function()
    local Stmt = FirstStatement("obj:method(x)")
    AssertEq(Stmt.expression.tag, "call")
    AssertEq(Stmt.expression.self, true)
end)

-- ── Tests: return statements ──────────────────────────────────────────

Test("return statement: tag is 'return'", function()
    local Stmt = FirstStatement("return 1")
    AssertEq(Stmt.tag, "return")
end)

Test("return statement: values list has the returned expression", function()
    local Stmt = FirstStatement("return 99")
    Assert(#Stmt.expressions >= 1, "expected at least one return value")
    AssertEq(Stmt.expressions[1].node.text, "99")
end)

-- ── Tests: function declarations ──────────────────────────────────────

Test("local function declaration: tag is 'localfunction'", function()
    local Stmt = FirstStatement("local function foo() end")
    AssertEq(Stmt.tag, "localfunction")
end)

Test("global function declaration: tag is 'function'", function()
    local Stmt = FirstStatement("function foo() end")
    AssertEq(Stmt.tag, "function")
end)

Test("function parameters are captured", function()
    local Stmt   = FirstStatement("local function bar(a, b) end")
    local Params = Stmt.body.parameters
    AssertEq(#Params, 2)
    AssertEq(Params[1].name.text, "a")
    AssertEq(Params[2].name.text, "b")
end)

Test("vararg function has vararg flag set", function()
    local Stmt = FirstStatement("local function f(...) end")
    AssertEq(Stmt.body.vararg, true)
end)

-- ── Tests: expressions ────────────────────────────────────────────────

Test("nil literal: tag is 'nil'", function()
    local Stmt = FirstStatement("local x = nil")
    local Val  = Stmt.values[1].node
    AssertEq(Val.tag, "nil")
end)

Test("true literal: tag is 'bool'", function()
    local Stmt = FirstStatement("local x = true")
    local Val  = Stmt.values[1].node
    AssertEq(Val.tag, "bool")
    AssertEq(Val.value, true)
end)

Test("false literal: tag is 'bool'", function()
    local Stmt = FirstStatement("local x = false")
    local Val  = Stmt.values[1].node
    AssertEq(Val.tag, "bool")
    AssertEq(Val.value, false)
end)

Test("vararg expression: tag is 'vararg'", function()
    local Stmt = FirstStatement("local function f(...) local x = ... end")
    AssertEq(Stmt.tag, "localfunction")
    local Inner = Stmt.body.body.statements[1]
    AssertEq(Inner.values[1].node.tag, "vararg")
end)

Test("binary addition: tag is 'binary'", function()
    local Stmt = FirstStatement("local z = a + b")
    local Val  = Stmt.values[1].node
    AssertEq(Val.tag, "binary")
    AssertEq(Val.operator.text, "+")
end)

Test("unary minus: tag is 'unary'", function()
    local Stmt = FirstStatement("local z = -x")
    local Val  = Stmt.values[1].node
    AssertEq(Val.tag, "unary")
    AssertEq(Val.operator.text, "-")
end)

Test("table constructor: tag is 'table'", function()
    local Stmt = FirstStatement("local t = {1, 2, 3}")
    local Val  = Stmt.values[1].node
    AssertEq(Val.tag, "table")
end)

-- ── Tests: location metadata ───────────────────────────────────────────

Test("statements carry location metadata", function()
    local Stmt = FirstStatement("local x = 1")
    Assert(type(Stmt.location) == "table", "expected location table")
    Assert(type(Stmt.location["begin"]) == "table", "expected begin position")
    Assert(type(Stmt.location.finish) == "table", "expected finish position")
end)

Test("location begin is at column 0 for first statement", function()
    local Stmt = FirstStatement("local x = 1")
    AssertEq(Stmt.location["begin"].column, 0)
    AssertEq(Stmt.location["begin"].line, 0)
end)

-- ── Tests: multiple statements ─────────────────────────────────────────

Test("multiple statements are all parsed", function()
    local Source = "local a = 1\nlocal b = 2\nlocal c = 3\n"
    local Ast    = parser.parsefile(Source)
    AssertEq(#Ast.root.statements, 3)
end)

-- ── Summary ───────────────────────────────────────────────────────────

print(string.format("\nparser.luau tests: %d passed, %d failed", Passed, Failed))

if Failed > 0 then
    process.exit(1)
end
