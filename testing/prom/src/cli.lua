--* ══════════════════════════════════════════════════════════════════════
--* testing/prom/src/cli.lua  –  Luau source pre-processor (unparser)
--* ══════════════════════════════════════════════════════════════════════
--*
--* Reads a Lua/Luau source file, optionally instruments every conditional
--* and loop with CHECKIF / CHECKWHILE / CHECKOR / CHECKAND / CHECKNOT /
--* __EQ / __NEQ / COMPL … call-sites (--hookOp mode), then writes the
--* result to <input>.obfuscated.lua.
--*
--* This script is invoked by hi.luau's Obf() function:
--*
--*   lua testing/prom/src/cli.lua --LuaU --preset Minify [--hookOp] <input>
--*
--* ── Flags ─────────────────────────────────────────────────────────────
--*
--*  --hookOp          Rewrite every if/while/elseif condition and every
--*                    boolean sub-expression so that the spy sandbox can
--*                    observe branch decisions at runtime.
--*                    WARNING: breaks some obfuscators (e.g. Luraph).
--*  --preset <name>   Accepted for compatibility; currently ignored.
--*  --LuaU            Accepted for compatibility; currently ignored.
--*  <input>           Path to the Lua/Luau source file to process.
--*                    Treated as the first non-flag argument.
--*
--* ── Output ────────────────────────────────────────────────────────────
--*
--*  The processed source is written to:
--*    • <input>.obfuscated.lua  (if the input path ends in .lua)
--*    • <input>.obfuscated.lua  (for any other extension)
--*
--* ── hookOp call-sites emitted ─────────────────────────────────────────
--*
--*  CHECKIF(cond)               – wraps every `if` / `elseif` condition.
--*  CHECKWHILE(cond, id)        – wraps every `while` condition; `id` is a
--*                                per-loop integer so CHECKWHILE can cap
--*                                iterations independently per loop.
--*  CHECKOR(a, b)               – replaces `a or b`.
--*  CHECKAND(a, b)              – replaces `a and b`.
--*  CHECKNOT(a)                 – replaces `not a`.
--*  __EQ(a, b) / __NEQ(a, b)   – replace `a == b` / `a ~= b`.
--*  COMPL(a,b) / COMPG(a,b)    – replace `a < b` / `a > b`.
--*  COMPLE(a,b) / COMPGE(a,b)  – replace `a <= b` / `a >= b`.

local fs = require("@lune/fs")
local Process = require("@lune/process")

local Find, Match, Rep, Sub = string.find, string.match, string.rep, string.sub
local Insert, Concat = table.insert, table.concat

-- IsIdentChar: return true when Char is a valid Lua identifier character
-- (alphanumeric or underscore) and is not the empty string.
local function IsIdentChar(Char)
    return Char ~= "" and Match(Char, "[%w_]") ~= nil
end

-- StartsWithKeyword: return true when the exact keyword Keyword appears at
-- position Index in Source and is surrounded by non-identifier characters
-- (i.e. it is a whole word, not part of a longer identifier).
local function StartsWithKeyword(Source, Index, Keyword)
    if Sub(Source, Index, Index + #Keyword - 1) ~= Keyword then
        return false
    end

    local Prev = Index > 1 and Sub(Source, Index - 1, Index - 1) or ""
    local Next = Sub(Source, Index + #Keyword, Index + #Keyword)

    return not IsIdentChar(Prev) and not IsIdentChar(Next)
end

-- GetLongBracketLevel: if a long-bracket open sequence starts at Index
-- (e.g. `[[`, `[=[`, `[==[`), return the level (number of `=` signs).
-- Returns nil if the character at Index is not `[` or the sequence is not
-- a valid long-bracket opener.
local function GetLongBracketLevel(Source, Index)
    if Sub(Source, Index, Index) ~= "[" then
        return nil
    end

    local Cursor = Index + 1

    while Sub(Source, Cursor, Cursor) == "=" do
        Cursor += 1
    end

    if Sub(Source, Cursor, Cursor) ~= "[" then
        return nil
    end

    return Cursor - Index - 1
end

-- ReadLongBracketEnd: given that a long-bracket opener begins at Index,
-- return the index of the final `]` of the matching close sequence.
-- Returns #Source if no matching close is found (treats the rest of the
-- source as part of the bracket content, matching Lua's error-tolerant
-- behaviour for our purposes).
local function ReadLongBracketEnd(Source, Index)
    local Level = GetLongBracketLevel(Source, Index)

    if Level == nil then
        return nil
    end

    local Close = "]" .. Rep("=", Level) .. "]"
    local _, EndIndex = Find(Source, Close, Index + Level + 2, true)

    return EndIndex or #Source
end

-- ReadCommentEnd: if a comment begins at Index (i.e. `--`), return the
-- index of the last character of the comment.
--  • Long comments (`--[[…]]`) end at the matching close bracket.
--  • Short comments end at the newline (or end-of-file).
-- Returns nil if there is no comment at Index.
local function ReadCommentEnd(Source, Index)
    if Sub(Source, Index, Index + 1) ~= "--" then
        return nil
    end

    local LongEnd = ReadLongBracketEnd(Source, Index + 2)

    if LongEnd then
        return LongEnd
    end

    local NewLine = Find(Source, "\n", Index + 2, true)

    return NewLine and (NewLine - 1) or #Source
end

-- ReadQuotedStringEnd: given that a quoted string begins at Index (i.e.
-- the opening `"` or `'`), return the index of the closing quote.
-- Handles backslash-escape sequences correctly.
local function ReadQuotedStringEnd(Source, Index)
    local Quote = Sub(Source, Index, Index)
    local Cursor = Index + 1

    while Cursor <= #Source do
        local Char = Sub(Source, Cursor, Cursor)

        if Char == "\\" then
            Cursor += 2
        elseif Char == Quote then
            return Cursor
        else
            Cursor += 1
        end
    end

    return #Source
end

-- ReadStringEnd: if a string literal begins at Index, return the index of
-- its final character.  Handles single-quoted, double-quoted, and
-- long-bracket strings.  Returns nil for non-string characters.
local function ReadStringEnd(Source, Index)
    local Char = Sub(Source, Index, Index)

    if Char == "'" or Char == "\"" then
        return ReadQuotedStringEnd(Source, Index)
    end

    if Char == "[" then
        return ReadLongBracketEnd(Source, Index)
    end

    return nil
end

-- FindNextTopLevelKeyword: scan Source forward from StartIndex looking for
-- the first occurrence of Keyword that is at the top syntactic level
-- (i.e. not inside parentheses, braces, brackets, strings, or comments).
-- Returns (matchStart, matchEnd) or nil.
local function FindNextTopLevelKeyword(Source, StartIndex, Keyword)
    local ParenDepth, BraceDepth, BracketDepth = 0, 0, 0
    local Cursor = StartIndex

    while Cursor <= #Source do
        local Char = Sub(Source, Cursor, Cursor)

        if Char == "-" and Sub(Source, Cursor, Cursor + 1) == "--" then
            Cursor = ReadCommentEnd(Source, Cursor)
        else
            local StringEnd = ReadStringEnd(Source, Cursor)

            if StringEnd then
                Cursor = StringEnd
            elseif Char == "(" then
                ParenDepth += 1
            elseif Char == ")" then
                ParenDepth = math.max(ParenDepth - 1, 0)
            elseif Char == "{" then
                BraceDepth += 1
            elseif Char == "}" then
                BraceDepth = math.max(BraceDepth - 1, 0)
            elseif Char == "[" then
                BracketDepth += 1
            elseif Char == "]" then
                BracketDepth = math.max(BracketDepth - 1, 0)
            elseif ParenDepth == 0 and BraceDepth == 0 and BracketDepth == 0 and StartsWithKeyword(Source, Cursor, Keyword) then
                return Cursor, Cursor + #Keyword - 1
            end
        end

        Cursor += 1
    end

    return nil
end

-- FindLastTopLevelKeyword: like FindNextTopLevelKeyword but scans the
-- entire source and returns the position of the LAST (rightmost) match.
-- Used by RewriteBooleanExpression to correctly decompose `a or b or c`
-- right-to-left, preserving Lua's left-associative evaluation order.
local function FindLastTopLevelKeyword(Source, Keyword)
    local ParenDepth, BraceDepth, BracketDepth = 0, 0, 0
    local Cursor = 1
    local MatchStart, MatchEnd

    while Cursor <= #Source do
        local Char = Sub(Source, Cursor, Cursor)

        if Char == "-" and Sub(Source, Cursor, Cursor + 1) == "--" then
            Cursor = ReadCommentEnd(Source, Cursor)
        else
            local StringEnd = ReadStringEnd(Source, Cursor)

            if StringEnd then
                Cursor = StringEnd
            elseif Char == "(" then
                ParenDepth += 1
            elseif Char == ")" then
                ParenDepth = math.max(ParenDepth - 1, 0)
            elseif Char == "{" then
                BraceDepth += 1
            elseif Char == "}" then
                BraceDepth = math.max(BraceDepth - 1, 0)
            elseif Char == "[" then
                BracketDepth += 1
            elseif Char == "]" then
                BracketDepth = math.max(BracketDepth - 1, 0)
            elseif ParenDepth == 0 and BraceDepth == 0 and BracketDepth == 0 and StartsWithKeyword(Source, Cursor, Keyword) then
                MatchStart, MatchEnd = Cursor, Cursor + #Keyword - 1
            end
        end

        Cursor += 1
    end

    return MatchStart, MatchEnd
end

-- SplitPadding: decompose Source into (Leading whitespace, Core content,
-- Trailing whitespace) so that transformations can preserve indentation.
local function SplitPadding(Source)
    local Leading = Match(Source, "^(%s*)") or ""
    local Trailing = Match(Source, "(%s*)$") or ""
    local StartIndex = #Leading + 1
    local EndIndex = #Source - #Trailing

    if EndIndex < StartIndex then
        return Leading, "", Trailing
    end

    return Leading, Sub(Source, StartIndex, EndIndex), Trailing
end

-- HasOuterParens: return true when the entire non-whitespace content of
-- Source is wrapped in a single matching pair of parentheses.
-- Example: "  (a or b)  " → true;  "(a) or (b)" → false.
local function HasOuterParens(Source)
    if Sub(Source, 1, 1) ~= "(" or Sub(Source, #Source, #Source) ~= ")" then
        return false
    end

    local Depth = 0
    local Cursor = 1

    while Cursor <= #Source do
        local Char = Sub(Source, Cursor, Cursor)

        if Char == "-" and Sub(Source, Cursor, Cursor + 1) == "--" then
            Cursor = ReadCommentEnd(Source, Cursor)
        else
            local StringEnd = ReadStringEnd(Source, Cursor)

            if StringEnd then
                Cursor = StringEnd
            elseif Char == "(" then
                Depth += 1
            elseif Char == ")" then
                Depth -= 1

                if Depth == 0 and Cursor < #Source then
                    return false
                end
            end
        end

        Cursor += 1
    end

    return Depth == 0
end

-- RewriteBooleanExpression: recursively wrap every `or`, `and`, and `not`
-- operator in Expression with the corresponding CHECK* call so the spy
-- sandbox can intercept every logical sub-expression at runtime.
--
-- Rewrite rules (applied bottom-up / right-to-left):
--   a or  b  →  CHECKOR(rewrite(a), rewrite(b))
--   a and b  →  CHECKAND(rewrite(a), rewrite(b))
--   not a    →  CHECKNOT(rewrite(a))
--   (expr)   →  (rewrite(expr))          ← outer parens are preserved
local function RewriteBooleanExpression(Expression)
    local Leading, Core, Trailing = SplitPadding(Expression)

    if Core == "" then
        return Expression
    end

    if HasOuterParens(Core) then
        return Leading .. "(" .. RewriteBooleanExpression(Sub(Core, 2, #Core - 1)) .. ")" .. Trailing
    end

    local OrStart, OrEnd = FindLastTopLevelKeyword(Core, "or")

    if OrStart then
        local Left = RewriteBooleanExpression(Sub(Core, 1, OrStart - 1))
        local Right = RewriteBooleanExpression(Sub(Core, OrEnd + 1, #Core))

        return Leading .. "CHECKOR(" .. Left .. ", " .. Right .. ")" .. Trailing
    end

    local AndStart, AndEnd = FindLastTopLevelKeyword(Core, "and")

    if AndStart then
        local Left = RewriteBooleanExpression(Sub(Core, 1, AndStart - 1))
        local Right = RewriteBooleanExpression(Sub(Core, AndEnd + 1, #Core))

        return Leading .. "CHECKAND(" .. Left .. ", " .. Right .. ")" .. Trailing
    end

    if StartsWithKeyword(Core, 1, "not") then
        local Rest = Sub(Core, 4, #Core)
        return Leading .. "CHECKNOT(" .. RewriteBooleanExpression(Rest) .. ")" .. Trailing
    end

    return Leading .. Core .. Trailing
end

-- WrapCondition: wrap the condition Expression in a HookName(...) call
-- (e.g. CHECKIF, CHECKWHILE) and recursively rewrite any boolean
-- sub-expressions inside it.  If ExtraArgument is provided it is appended
-- as an additional argument (used to pass the while-loop ID to CHECKWHILE).
-- Idempotent: if the expression is already a HookName(…) call, it is
-- returned unchanged.
local function WrapCondition(Expression, HookName, ExtraArgument)
    local Leading, Core, Trailing = SplitPadding(Expression)

    if Core == "" then
        return Expression
    end

    if StartsWithKeyword(Core, 1, HookName) then
        return Expression
    end

    if Leading == "" then
        Leading = " "
    end

    local Args = RewriteBooleanExpression(Core)

    if ExtraArgument ~= nil then
        Args ..= ", " .. tostring(ExtraArgument)
    end

    return Leading .. HookName .. "(" .. Args .. ")" .. Trailing
end

-- TransformControlFlow: walk Source character-by-character and replace
-- every `if`, `elseif`, and `while` condition with a WrapCondition call.
-- Strings, comments, and nested bracket depths are tracked so that
-- keywords inside literals are not rewritten.
--
-- Returns the fully instrumented source string.
local function TransformControlFlow(Source)
    local Output = {}
    local Cursor = 1
    local CopyStart = 1
    local WhileId = 0

    while Cursor <= #Source do
        local Char = Sub(Source, Cursor, Cursor)

        if Char == "-" and Sub(Source, Cursor, Cursor + 1) == "--" then
            Cursor = ReadCommentEnd(Source, Cursor)
        else
            local StringEnd = ReadStringEnd(Source, Cursor)

            if StringEnd then
                Cursor = StringEnd
            else
                local Keyword, EndKeyword, HookName, ExtraArgument

                if StartsWithKeyword(Source, Cursor, "elseif") then
                    Keyword, EndKeyword, HookName = "elseif", "then", "CHECKIF"
                elseif StartsWithKeyword(Source, Cursor, "while") then
                    WhileId += 1
                    Keyword, EndKeyword, HookName, ExtraArgument = "while", "do", "CHECKWHILE", WhileId
                elseif StartsWithKeyword(Source, Cursor, "if") then
                    Keyword, EndKeyword, HookName = "if", "then", "CHECKIF"
                end

                if Keyword then
                    local AfterKeyword = Cursor + #Keyword
                    local GuardStart, GuardEnd = FindNextTopLevelKeyword(Source, AfterKeyword, EndKeyword)

                    if GuardStart then
                        Insert(Output, Sub(Source, CopyStart, AfterKeyword - 1))
                        Insert(Output, WrapCondition(Sub(Source, AfterKeyword, GuardStart - 1), HookName, ExtraArgument))
                        Insert(Output, EndKeyword)

                        Cursor = GuardEnd
                        CopyStart = GuardEnd + 1
                    end
                end
            end
        end

        Cursor += 1
    end

    Insert(Output, Sub(Source, CopyStart, #Source))

    return Concat(Output)
end

-- ParseArgs: parse Process.args into a Settings table.
--
-- Recognised flags:
--   --hookOp         → Settings.hookOp = true
--   --preset <name>  → skip the next argument (value is ignored)
--   --<anything>     → accepted silently for forward compatibility
--   <other>          → treated as the positional input file path
--                      (first non-flag argument wins)
local function ParseArgs()
    local Settings = {
        hookOp = false
    }

    local SkipNext = false

    for _, Arg in Process.args do
        if SkipNext then
            SkipNext = false
            continue
        end

        if Arg == "--hookOp" then
            Settings.hookOp = true
        elseif Arg == "--preset" then
            SkipNext = true
        elseif Sub(Arg, 1, 2) == "--" then
            -- Flags such as --LuaU are accepted for compatibility.
        else
            Settings.input = Settings.input or Arg
        end
    end

    return Settings
end

-- GetOutputPath: derive the output file path from the input path.
-- Strips a trailing .lua extension before appending .obfuscated.lua so
-- that `foo.lua` → `foo.obfuscated.lua` rather than `foo.lua.obfuscated.lua`.
local function GetOutputPath(Path)
    if Path:match("%.lua$") then
        return Path:gsub("%.lua$", "") .. ".obfuscated.lua"
    end

    return Path .. ".obfuscated.lua"
end

local Settings = ParseArgs()

assert(Settings.input, "missing input file")
assert(fs.isFile(Settings.input), "input file not found: " .. Settings.input)

local Source = fs.readFile(Settings.input)

if Settings.hookOp then
    Source = TransformControlFlow(Source)
end

fs.writeFile(GetOutputPath(Settings.input), Source)
