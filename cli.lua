local fs = require("@lune/fs")
local Process = require("@lune/process")

local Find, Match, Rep, Sub = string.find, string.match, string.rep, string.sub
local Insert, Concat = table.insert, table.concat

local function IsIdentChar(Char)
    return Char ~= "" and Match(Char, "[%w_]") ~= nil
end

local function StartsWithKeyword(Source, Index, Keyword)
    if Sub(Source, Index, Index + #Keyword - 1) ~= Keyword then
        return false
    end

    local Prev = Index > 1 and Sub(Source, Index - 1, Index - 1) or ""
    local Next = Sub(Source, Index + #Keyword, Index + #Keyword)

    return not IsIdentChar(Prev) and not IsIdentChar(Next)
end

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

local function ReadLongBracketEnd(Source, Index)
    local Level = GetLongBracketLevel(Source, Index)

    if Level == nil then
        return nil
    end

    local Close = "]" .. Rep("=", Level) .. "]"
    local _, EndIndex = Find(Source, Close, Index + Level + 2, true)

    return EndIndex or #Source
end

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
