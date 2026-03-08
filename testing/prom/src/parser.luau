--* ══════════════════════════════════════════════════════════════════════
--* testing/prom/src/parser.luau  –  Luau recursive-descent parser
--* ══════════════════════════════════════════════════════════════════════
--*
--* Parses a Luau source string and returns an abstract syntax tree (AST)
--* compatible with the unparser defined in unparser.luau.
--*
--* Public API:
--*   parsefile(source: string) → { root: { statements: StatNode[] } }
--*
--* AST Node format (summary):
--*
--*  Token  (istoken=true)
--*    .text        raw source text
--*    .value       Lua value for number / boolean tokens
--*    .quotestyle  "single" | "double" | "block" | "interp"  (strings)
--*    .blockdepth  number of `=` signs in long-bracket string
--*    .position    { line: number, column: number }  (0-indexed)
--*
--*  StatNode  (kind="stat")
--*    .tag         see statement tags below
--*    .location    { begin: Pos, finish: Pos }  (0-indexed)
--*    + tag-specific fields documented per tag
--*
--*  ExprNode  (kind="expr")
--*    .tag         see expression tags below
--*    .location    { begin: Pos, finish: Pos }  (0-indexed)
--*    + tag-specific fields documented per tag
--*
--*  Wrapper  – used for arrays of variables / values / arguments
--*    .node        the inner StatNode or ExprNode
--*
--*  FuncBody
--*    .parameters  ExprNode[] (each a "local" expr with .name.text)
--*    .vararg      boolean
--*    .body        block StatNode

-- ── Helpers ──────────────────────────────────────────────────────────

local Sub, Find, Match, Rep, Format = string.sub, string.find, string.match, string.rep, string.format

local function Pos(line, column)
    return { line = line, column = column }
end

local function Loc(beginPos, finishPos)
    return { ["begin"] = beginPos, finish = finishPos }
end

-- ── Tokeniser ─────────────────────────────────────────────────────────

local TK = {
    NAME = "NAME", NUMBER = "NUMBER", STRING = "STRING",
    INTERP_START = "INTERP_START", INTERP_MID = "INTERP_MID", INTERP_END = "INTERP_END",
    OP = "OP", EOF = "EOF",
    -- keywords (stored as their keyword string directly)
}

local KEYWORDS = {
    ["and"]=true, ["break"]=true, ["do"]=true, ["else"]=true,
    ["elseif"]=true, ["end"]=true, ["false"]=true, ["for"]=true,
    ["function"]=true, ["goto"]=true, ["if"]=true, ["in"]=true,
    ["local"]=true, ["nil"]=true, ["not"]=true, ["or"]=true,
    ["repeat"]=true, ["return"]=true, ["then"]=true, ["true"]=true,
    ["until"]=true, ["while"]=true,
    -- Luau extras
    ["continue"]=true, ["type"]=true, ["export"]=true,
}

local function Tokenise(source)
    local tokens = {}
    local i = 1
    local line = 0   -- 0-indexed
    local lineStart = 1  -- byte index of the start of the current line

    local function peekChar(offset)
        offset = offset or 0
        return Sub(source, i + offset, i + offset)
    end

    local function advance()
        local c = Sub(source, i, i)
        i += 1
        if c == "\n" then
            line += 1
            lineStart = i
        end
        return c
    end

    local function col()
        return i - lineStart  -- 0-indexed, pointing at the CURRENT char
    end

    local function addToken(type, text, extra)
        local tok = { type = type, text = text }
        if extra then
            for k, v in next, extra do tok[k] = v end
        end
        tokens[#tokens + 1] = tok
        return tok
    end

    -- Read a long-bracket string starting at i (pointing at the first '[').
    -- Returns (content, depth, endByteIndex) or nil.
    local function readLongBracket()
        if peekChar() ~= "[" then return nil end
        local depth = 0
        local j = i + 1
        while Sub(source, j, j) == "=" do j += 1; depth += 1 end
        if Sub(source, j, j) ~= "[" then return nil end
        -- skip the opener
        i = j + 1
        local close = "]" .. Rep("=", depth) .. "]"
        local startContent = i
        local endPos = Find(source, close, i, true)
        if not endPos then
            -- unterminated; consume rest
            local content = Sub(source, startContent, #source)
            -- count newlines
            for _ in content:gmatch("\n") do line += 1 end
            i = #source + 1
            return content, depth, #source
        end
        local content = Sub(source, startContent, endPos - 1)
        -- advance line counters through the content
        local nl = 0
        for _ in content:gmatch("\n") do nl += 1 end
        line += nl
        if nl > 0 then
            -- set lineStart to just after the last \n in the consumed range
            local lastNL = Find(source, "\n[^\n]*$", startContent, false) -- actually easier:
            local pos = startContent
            local last = pos
            while true do
                local nxt = Find(source, "\n", pos, true)
                if not nxt or nxt > endPos then break end
                last = nxt + 1
                pos = nxt + 1
            end
            lineStart = last
        end
        i = endPos + #close
        return content, depth, endPos + #close - 1
    end

    while i <= #source do
        -- record start position BEFORE consuming
        local startLine = line
        local startCol = i - lineStart  -- 0-indexed column of current char

        local c = peekChar()

        -- Whitespace
        if c == " " or c == "\t" or c == "\r" or c == "\n" then
            advance()

        -- Comments
        elseif c == "-" and peekChar(1) == "-" then
            i += 2  -- skip "--"
            local isLongComment = false
            if peekChar() == "[" then
                local savedI = i
                local content, depth = readLongBracket()
                if content then
                    -- long comment consumed; nothing to add
                    isLongComment = true
                else
                    i = savedI  -- readLongBracket failed; fall through to short comment
                end
            end
            if not isLongComment then
                -- short comment: skip to end of line
                while i <= #source and Sub(source, i, i) ~= "\n" do i += 1 end
            end

        -- Long strings
        elseif c == "[" and (peekChar(1) == "[" or peekChar(1) == "=") then
            local savedI = i
            local savedLine = line
            local savedLineStart = lineStart
            local content, depth = readLongBracket()
            if content then
                addToken(TK.STRING, content, {
                    quotestyle = "block",
                    blockdepth = depth,
                    position = Pos(startLine, startCol),
                })
            else
                -- not a long string; treat '[' as an operator
                i = savedI
                line = savedLine
                lineStart = savedLineStart
                addToken(TK.OP, advance(), { position = Pos(startLine, startCol) })
            end

        -- Backtick interpolated strings
        elseif c == "`" then
            advance()  -- consume opening backtick
            -- We emit one INTERP_START token that carries all parsed info.
            -- strings[]: array of {text, position}
            -- expressions[]: array of placeholder positions (the inner expressions
            --                are parsed by the main parser via recursion)
            -- For simplicity we emit the raw content as a single STRING token
            -- with quotestyle="interp" and embed expression markers.
            local parts = {}  -- alternating string/expr segments
            local buf = {}
            local iStart = i
            while i <= #source do
                local ch = Sub(source, i, i)
                if ch == "`" then
                    -- end of interpolated string
                    advance()
                    break
                elseif ch == "\\" then
                    -- escape
                    local esc = Sub(source, i + 1, i + 1)
                    table.insert(buf, "\\" .. esc)
                    i += 2
                elseif ch == "{" then
                    -- expression start
                    if #buf > 0 then
                        table.insert(parts, { kind = "str", text = table.concat(buf) })
                        buf = {}
                    end
                    advance()  -- consume '{'
                    table.insert(parts, { kind = "exprStart", col = startCol })
                    -- signal to the token consumer: we switch to expression mode
                    -- We emit a special INTERP_EXPR_START token
                    break  -- expression parsing handled in main parser
                else
                    if ch == "\n" then line += 1; lineStart = i + 1 end
                    table.insert(buf, ch)
                    advance()
                end
            end
            -- Simplified: emit as a plain string with quotestyle "interp"
            -- The full interpolated-string handling is done as a special case in the parser.
            -- We restart from iStart to re-lex the content properly.
            -- For now emit a token that stores the raw source content.
            local rawContent = Sub(source, iStart, i - 2)  -- everything between backticks (approx)
            addToken(TK.STRING, rawContent, {
                quotestyle = "interp",
                position = Pos(startLine, startCol),
                isInterp = true,
                rawSource = rawContent,
            })

        -- Single/double quoted strings
        elseif c == "\"" or c == "'" then
            local quote = advance()
            local buf = {}
            local qs = (quote == '"') and "double" or "single"
            while i <= #source do
                local ch = Sub(source, i, i)
                if ch == "\\" then
                    local esc = Sub(source, i + 1, i + 1)
                    table.insert(buf, ch .. esc)
                    i += 2
                elseif ch == quote then
                    advance()
                    break
                else
                    if ch == "\n" then line += 1; lineStart = i + 1 end
                    table.insert(buf, ch)
                    advance()
                end
            end
            addToken(TK.STRING, table.concat(buf), {
                quotestyle = qs,
                position = Pos(startLine, startCol),
            })

        -- Numbers
        elseif Match(c, "%d") or (c == "." and Match(peekChar(1), "%d")) then
            local numStart = i
            -- hex
            if c == "0" and (peekChar(1) == "x" or peekChar(1) == "X") then
                i += 2
                while Match(peekChar(), "[%x_]") do i += 1 end
                if peekChar() == "." then
                    i += 1
                    while Match(peekChar(), "[%x_]") do i += 1 end
                end
                if peekChar() == "p" or peekChar() == "P" then
                    i += 1
                    if peekChar() == "+" or peekChar() == "-" then i += 1 end
                    while Match(peekChar(), "%d") do i += 1 end
                end
            else
                while Match(peekChar(), "[%d_]") do i += 1 end
                if peekChar() == "." and Match(peekChar(1), "%d") then
                    i += 1
                    while Match(peekChar(), "[%d_]") do i += 1 end
                end
                if peekChar() == "e" or peekChar() == "E" then
                    i += 1
                    if peekChar() == "+" or peekChar() == "-" then i += 1 end
                    while Match(peekChar(), "%d") do i += 1 end
                end
            end
            local numStr = Sub(source, numStart, i - 1):gsub("_", "")
            local numVal = tonumber(numStr) or 0
            addToken(TK.NUMBER, numStr, {
                value = numVal,
                position = Pos(startLine, startCol),
            })

        -- Identifiers and keywords
        elseif Match(c, "[%a_]") then
            local nameStart = i
            while Match(peekChar(), "[%w_]") do i += 1 end
            local name = Sub(source, nameStart, i - 1)
            if KEYWORDS[name] then
                addToken(name, name, { position = Pos(startLine, startCol) })
            else
                addToken(TK.NAME, name, { position = Pos(startLine, startCol) })
            end

        -- Operators and punctuation
        else
            local threeChar = Sub(source, i, i + 2)
            local twoChar = Sub(source, i, i + 1)
            local op
            -- Check 3-char operators first
            if threeChar == "..." then
                op = "..."; i += 3
            elseif threeChar == "//=" then
                op = "//="; i += 3
            elseif threeChar == "..=" then
                op = "..="; i += 3
            -- Then 2-char operators
            elseif twoChar == ".." then op = ".."; i += 2
            elseif twoChar == "//" then op = "//"; i += 2
            elseif twoChar == "~=" then op = "~="; i += 2
            elseif twoChar == "==" then op = "=="; i += 2
            elseif twoChar == "<=" then op = "<="; i += 2
            elseif twoChar == ">=" then op = ">="; i += 2
            elseif twoChar == "+=" then op = "+="; i += 2
            elseif twoChar == "-=" then op = "-="; i += 2
            elseif twoChar == "*=" then op = "*="; i += 2
            elseif twoChar == "/=" then op = "/="; i += 2
            elseif twoChar == "%=" then op = "%="; i += 2
            elseif twoChar == "^=" then op = "^="; i += 2
            elseif twoChar == "::" then op = "::"; i += 2
            elseif twoChar == "->" then op = "->"; i += 2
            -- Single char
            else
                op = c
                i += 1
            end
            addToken(TK.OP, op, { position = Pos(startLine, startCol) })
        end
    end

    addToken(TK.EOF, "", { position = Pos(line, i - lineStart) })
    return tokens
end

-- ── Parser ────────────────────────────────────────────────────────────

local function NewParser(tokens, source)
    local P = {}
    local pos = 1   -- current index into tokens[]

    local function cur() return tokens[pos] end
    local function peek(offset)
        local idx = pos + (offset or 0)
        return tokens[idx] or tokens[#tokens]  -- return EOF if out of bounds
    end

    local function advance()
        local tok = tokens[pos]
        if tok.type ~= TK.EOF then pos += 1 end
        return tok
    end

    local function expect(type, text)
        local tok = cur()
        if tok.type ~= type and tok.text ~= text and tok.type ~= text then
            -- best-effort: skip and continue
            return tok
        end
        return advance()
    end

    local function check(typeOrText)
        local tok = cur()
        return tok.type == typeOrText or tok.text == typeOrText
    end

    local function match(typeOrText)
        if check(typeOrText) then return advance() end
        return nil
    end

    local function makeTok(tok, extraValue)
        local t = {
            istoken = true,
            text = tok.text,
            value = extraValue ~= nil and extraValue or tok.value,
            quotestyle = tok.quotestyle,
            blockdepth = tok.blockdepth,
            position = tok.position or Pos(0, 0),
        }
        return t
    end

    local function makeExpr(tag, loc, fields)
        local node = { kind = "expr", tag = tag, location = loc or Loc(Pos(0,0), Pos(0,0)) }
        if fields then for k, v in next, fields do node[k] = v end end
        return node
    end

    local function makeStat(tag, loc, fields)
        local node = { kind = "stat", tag = tag, location = loc or Loc(Pos(0,0), Pos(0,0)) }
        if fields then for k, v in next, fields do node[k] = v end end
        return node
    end

    local function wrap(node)
        return { node = node }
    end

    local function curPos()
        local tok = cur()
        return tok.position or Pos(0, 0)
    end

    -- Forward declarations
    local parseExpr, parseStatement, parseBlock, parseType

    -- ── Type expressions (simplified) ─────────────────────────────────
    parseType = function()
        -- We only handle enough to skip type annotations cleanly.
        local startPos = curPos()
        -- Handle `(type) ->` function types, unions, intersections, etc.
        local depth = 0
        local startIdx = pos
        -- Simple approach: consume tokens until we hit something that can't be a type
        -- This is used for `type X = <type>` and `expr :: <type>` (cast)
        local function eatType()
            if check("(") then
                advance(); depth += 1
                while not check(TK.EOF) do
                    if check("(") then depth += 1; advance()
                    elseif check(")") then
                        advance(); depth -= 1
                        if depth < 0 then break end
                    else
                        eatType()
                    end
                end
                -- possible ->
                if check("->") then advance(); eatType() end
                return
            elseif check("{") then
                advance()
                local d = 1
                while not check(TK.EOF) and d > 0 do
                    if check("{") then d += 1; advance()
                    elseif check("}") then d -= 1; advance()
                    else advance() end
                end
                return
            elseif check(TK.NAME) or KEYWORDS[cur().text] then
                advance()
                -- optional generics
                if check("<") then
                    advance()
                    local d2 = 1
                    while not check(TK.EOF) and d2 > 0 do
                        if check("<") then d2 += 1; advance()
                        elseif check(">") then d2 -= 1; advance()
                        else advance() end
                    end
                end
                -- optional .Name chain
                while check(".") do advance(); if check(TK.NAME) then advance() end end
                -- optional ? (optional type)
                match("?")
                return
            elseif check("...") then
                advance()
                eatType()
                return
            else
                advance()
            end
        end
        eatType()
        -- unions / intersections
        while check("|") or check("&") do
            advance()
            eatType()
        end
        local endPos = curPos()
        return makeExpr("reference", Loc(startPos, endPos), {
            name = makeTok({ text = "any", position = startPos })
        })
    end

    -- ── Expression parsing ─────────────────────────────────────────────

    -- Operator precedence table
    local BinOp = {
        ["or"]  = { prec = 1,  right = false },
        ["and"] = { prec = 2,  right = false },
        ["<"]   = { prec = 3,  right = false },
        [">"]   = { prec = 3,  right = false },
        ["<="]  = { prec = 3,  right = false },
        [">="]  = { prec = 3,  right = false },
        ["=="]  = { prec = 3,  right = false },
        ["~="]  = { prec = 3,  right = false },
        [".."]  = { prec = 4,  right = true  },
        ["+"]   = { prec = 5,  right = false },
        ["-"]   = { prec = 5,  right = false },
        ["*"]   = { prec = 6,  right = false },
        ["/"]   = { prec = 6,  right = false },
        ["//"]  = { prec = 6,  right = false },
        ["%"]   = { prec = 6,  right = false },
        ["^"]   = { prec = 8,  right = true  },
    }

    local UnaryOp = { ["-"] = true, ["not"] = true, ["#"] = true, ["~"] = true }

    -- Parse primary expression (no binary ops)
    local function parsePrimary()
        local tok = cur()
        local startPos = tok.position or Pos(0, 0)

        if tok.type == TK.NUMBER then
            advance()
            return makeExpr("number", Loc(startPos, startPos), {
                value = tok.text,
                text = tok.text,
            })

        elseif tok.type == TK.STRING then
            advance()
            local node = makeExpr("string", Loc(startPos, startPos), {
                text = tok.text,
                quotestyle = tok.quotestyle or "double",
                blockdepth = tok.blockdepth or 0,
            })
            return node

        elseif tok.text == "nil" then
            advance()
            return makeExpr("nil", Loc(startPos, startPos))

        elseif tok.text == "true" then
            advance()
            return makeExpr("bool", Loc(startPos, startPos), { value = true })

        elseif tok.text == "false" then
            advance()
            return makeExpr("bool", Loc(startPos, startPos), { value = false })

        elseif tok.text == "..." then
            advance()
            return makeExpr("vararg", Loc(startPos, startPos))

        elseif tok.text == "function" then
            advance()
            local body = P.parseFuncBody()
            return makeExpr("function", Loc(startPos, curPos()), { body = body })

        elseif tok.text == "if" then
            -- inline if expression: if cond then expr [elseif cond then expr]* else expr
            advance()  -- consume 'if'
            local cond = parseExpr()
            expect("then", "then")
            local thenExpr = parseExpr()
            local elseifs = {}
            while check("elseif") do
                advance()
                local ec = parseExpr()
                expect("then", "then")
                local et = parseExpr()
                table.insert(elseifs, { condition = ec, thenexpr = et })
            end
            expect("else", "else")
            local elseExpr = parseExpr()
            return makeExpr("conditional", Loc(startPos, curPos()), {
                condition = cond,
                thenexpr = thenExpr,
                elseifs = elseifs,
                elseexpr = elseExpr,
            })

        elseif tok.text == "{" then
            advance()  -- consume '{'
            local entries = {}
            while not check("}") and not check(TK.EOF) do
                local entry = {}
                -- [expr] = value  or  name = value  or  value
                if check("[") then
                    advance()
                    entry.key = parseExpr()
                    expect("]", "]")
                    expect("=", "=")
                    entry.value = parseExpr()
                elseif cur().type == TK.NAME and peek(1).text == "=" then
                    -- name = value  (only if next token after name is '=', not '==')
                    local keyTok = advance()
                    advance()  -- consume '='
                    entry.key = makeExpr("string", Loc(keyTok.position, keyTok.position), {
                        text = keyTok.text,
                        quotestyle = "double",
                    })
                    entry.value = parseExpr()
                elseif cur().type == TK.NAME and peek(1).text == ":" then
                    -- name: type  (type annotation in table type context — treat as reference)
                    local keyTok = advance()
                    advance()  -- consume ':'
                    local typeExpr = parseType()
                    entry.key = makeExpr("string", Loc(keyTok.position, keyTok.position), {
                        text = keyTok.text,
                        quotestyle = "double",
                    })
                    entry.value = makeExpr("reference", typeExpr.location, {
                        name = makeTok({ text = keyTok.text, position = keyTok.position })
                    })
                else
                    entry.value = parseExpr()
                end
                table.insert(entries, entry)
                -- separator
                if not match(",") then match(";") end
            end
            expect("}", "}")
            return makeExpr("table", Loc(startPos, curPos()), { entries = entries })

        elseif tok.text == "(" then
            advance()
            local inner = parseExpr()
            expect(")", ")")
            return makeExpr("group", Loc(startPos, curPos()), { expression = inner })

        elseif tok.type == TK.NAME then
            advance()
            local globalOrLocal = makeExpr("global", Loc(startPos, startPos), {
                name = makeTok(tok),
                token = makeTok(tok),
            })
            return globalOrLocal

        else
            -- Unknown token: produce a nil placeholder and skip
            advance()
            return makeExpr("nil", Loc(startPos, startPos))
        end
    end

    -- Parse suffix expressions (calls, index, field access) – left-to-right
    local function parseSuffix(base)
        while true do
            local tok = cur()
            local startPos = tok.position or Pos(0, 0)

            if tok.text == "." then
                advance()
                local fieldTok = cur()
                if fieldTok.type == TK.NAME then
                    advance()
                    base = makeExpr("indexname", Loc(base.location["begin"], curPos()), {
                        expression = base,
                        accessor = makeTok({ text = ".", position = startPos }),
                        index = makeTok(fieldTok),
                    })
                else
                    break
                end

            elseif tok.text == ":" then
                advance()
                local methodTok = cur()
                if methodTok.type == TK.NAME then
                    advance()
                    -- This becomes a namecall when followed by call args
                    -- We create an indexname with accessor ":"
                    local indexNode = makeExpr("indexname", Loc(base.location["begin"], curPos()), {
                        expression = base,
                        accessor = makeTok({ text = ":", position = startPos }),
                        index = makeTok(methodTok),
                    })
                    -- The call will wrap this below
                    base = indexNode
                else
                    break
                end

            elseif tok.text == "[" then
                advance()
                local idx = parseExpr()
                expect("]", "]")
                base = makeExpr("index", Loc(base.location["begin"], curPos()), {
                    expression = base,
                    index = idx,
                })

            elseif tok.text == "(" then
                -- regular call
                advance()
                local args = {}
                while not check(")") and not check(TK.EOF) do
                    table.insert(args, wrap(parseExpr()))
                    if not match(",") then break end
                end
                expect(")", ")")
                local isSelf = base.tag == "indexname" and base.accessor.text == ":"
                base = makeExpr("call", Loc(base.location["begin"], curPos()), {
                    func = base,
                    arguments = args,
                    ["self"] = isSelf,
                })

            elseif tok.text == "{" then
                -- table constructor call: f { }
                local argExpr = parsePrimary()  -- parse the table
                base = makeExpr("call", Loc(base.location["begin"], curPos()), {
                    func = base,
                    arguments = { wrap(argExpr) },
                    ["self"] = false,
                })

            elseif tok.type == TK.STRING then
                -- string literal call: f "hello"
                local strExpr = parsePrimary()
                base = makeExpr("call", Loc(base.location["begin"], curPos()), {
                    func = base,
                    arguments = { wrap(strExpr) },
                    ["self"] = false,
                })

            elseif tok.text == "::" then
                -- type cast: expr :: type
                advance()
                parseType()  -- consume and discard the type
                base = makeExpr("cast", Loc(base.location["begin"], curPos()), {
                    expression = base,
                })

            else
                break
            end
        end
        return base
    end

    -- Parse unary expression
    local function parseUnary()
        local tok = cur()
        if UnaryOp[tok.text] then
            advance()
            local operand = parseUnary()
            return makeExpr("unary", Loc(tok.position, curPos()), {
                operator = makeTok(tok),
                operand = operand,
            })
        end
        return parseSuffix(parsePrimary())
    end

    -- Parse binary expression with precedence climbing
    parseExpr = function(minPrec)
        minPrec = minPrec or 0
        local lhs = parseUnary()
        while true do
            local tok = cur()
            local info = BinOp[tok.text]
            if not info or info.prec <= minPrec then break end
            advance()
            local nextPrec = info.right and (info.prec - 1) or info.prec
            local rhs = parseExpr(nextPrec)
            lhs = makeExpr("binary", Loc(lhs.location["begin"], rhs.location.finish), {
                lhsoperand = lhs,
                operator = makeTok(tok),
                rhsoperand = rhs,
            })
        end
        return lhs
    end

    -- ── Function body ──────────────────────────────────────────────────

    P.parseFuncBody = function()
        expect("(", "(")
        local params = {}
        local hasVararg = false
        while not check(")") and not check(TK.EOF) do
            if check("...") then
                hasVararg = true
                advance()
                break
            end
            local nameTok = cur()
            if nameTok.type == TK.NAME then
                advance()
                -- optional type annotation on parameter: name: type
                if check(":") then
                    advance()
                    parseType()
                end
                table.insert(params, makeExpr("local", Loc(nameTok.position, curPos()), {
                    name = makeTok(nameTok),
                    token = makeTok(nameTok),
                }))
            else
                advance()
            end
            if not match(",") then break end
        end
        expect(")", ")")
        -- optional return type annotation
        if check(":") then
            advance()
            parseType()
        end
        local body = parseBlock()
        expect("end", "end")
        return {
            parameters = params,
            vararg = hasVararg,
            body = body,
        }
    end

    -- ── Statement parsing ──────────────────────────────────────────────

    -- Parse a list of names (for local declarations)
    local function parseNameList()
        local names = {}
        repeat
            local tok = cur()
            if tok.type ~= TK.NAME then break end
            advance()
            -- optional type annotation
            if check(":") then
                advance()
                parseType()
            end
            table.insert(names, wrap(makeExpr("local", Loc(tok.position, curPos()), {
                name = makeTok(tok),
                token = makeTok(tok),
            })))
        until not match(",")
        return names
    end

    -- Parse an expression that may be a var (for assignment LHS detection)
    local function parseExprList()
        local exprs = {}
        repeat
            table.insert(exprs, wrap(parseExpr()))
        until not match(",")
        return exprs
    end

    -- Parse function name: Name {'.' Name} [':' Name]
    local function parseFuncName()
        local tok = cur()
        if tok.type ~= TK.NAME then
            return makeExpr("global", Loc(tok.position, tok.position), {
                name = makeTok(tok), token = makeTok(tok)
            })
        end
        advance()
        local base = makeExpr("global", Loc(tok.position, curPos()), {
            name = makeTok(tok), token = makeTok(tok)
        })
        while check(".") do
            local dot = advance()
            local field = cur()
            if field.type ~= TK.NAME then break end
            advance()
            base = makeExpr("indexname", Loc(base.location["begin"], curPos()), {
                expression = base,
                accessor = makeTok(dot),
                index = makeTok(field),
            })
        end
        if check(":") then
            local colon = advance()
            local method = cur()
            if method.type == TK.NAME then
                advance()
                base = makeExpr("indexname", Loc(base.location["begin"], curPos()), {
                    expression = base,
                    accessor = makeTok(colon),
                    index = makeTok(method),
                })
            end
        end
        return base
    end

    parseStatement = function()
        local tok = cur()
        local startPos = tok.position or Pos(0, 0)

        -- Semicolons
        if tok.text == ";" then
            advance()
            return nil  -- skip empty statements

        -- do...end block
        elseif tok.text == "do" then
            local doPos = startPos
            advance()
            local blk = parseBlock()
            expect("end", "end")
            -- Set begin to the "do" keyword position so the unparser's shouldAddDo check works
            blk.location["begin"] = doPos
            return blk

        -- while
        elseif tok.text == "while" then
            advance()
            local cond = parseExpr()
            expect("do", "do")
            local body = parseBlock()
            expect("end", "end")
            return makeStat("while", Loc(startPos, curPos()), {
                condition = cond,
                body = body,
            })

        -- repeat
        elseif tok.text == "repeat" then
            advance()
            local body = parseBlock()
            expect("until", "until")
            local cond = parseExpr()
            return makeStat("repeat", Loc(startPos, curPos()), {
                body = body,
                condition = cond,
            })

        -- if
        elseif tok.text == "if" then
            advance()
            local cond = parseExpr()
            expect("then", "then")
            local thenBlk = parseBlock()
            local elseifs = {}
            local elseBlk = nil
            while check("elseif") do
                advance()
                local ec = parseExpr()
                expect("then", "then")
                local eb = parseBlock()
                table.insert(elseifs, { condition = ec, thenblock = eb })
            end
            if match("else") then
                elseBlk = parseBlock()
            end
            expect("end", "end")
            return makeStat("conditional", Loc(startPos, curPos()), {
                condition = cond,
                thenblock = thenBlk,
                elseifs = elseifs,
                elseblock = elseBlk,
            })

        -- for
        elseif tok.text == "for" then
            advance()
            local firstName = cur()
            if firstName.type ~= TK.NAME then
                -- error recovery
                return makeStat("block", Loc(startPos, curPos()), { statements = {} })
            end
            advance()
            if check("=") then
                -- numeric for
                advance()
                local from = parseExpr()
                expect(",", ",")
                local to = parseExpr()
                local step = nil
                if match(",") then step = parseExpr() end
                expect("do", "do")
                local body = parseBlock()
                expect("end", "end")
                return makeStat("for", Loc(startPos, curPos()), {
                    variable = { name = makeTok(firstName) },
                    from = from,
                    to = to,
                    step = step,
                    body = body,
                })
            else
                -- generic for  (may have multiple vars)
                local vars = {
                    wrap(makeExpr("local", Loc(firstName.position, curPos()), {
                        name = makeTok(firstName), token = makeTok(firstName)
                    }))
                }
                -- optional type annotation
                if check(":") then advance(); parseType() end
                while match(",") do
                    local vt = cur()
                    if vt.type ~= TK.NAME then break end
                    advance()
                    if check(":") then advance(); parseType() end
                    table.insert(vars, wrap(makeExpr("local", Loc(vt.position, curPos()), {
                        name = makeTok(vt), token = makeTok(vt)
                    })))
                end
                expect("in", "in")
                local vals = parseExprList()
                expect("do", "do")
                local body = parseBlock()
                expect("end", "end")
                return makeStat("forin", Loc(startPos, curPos()), {
                    variables = vars,
                    values = vals,
                    body = body,
                })
            end

        -- function declaration
        elseif tok.text == "function" then
            advance()
            local name = parseFuncName()
            local body = P.parseFuncBody()
            return makeStat("function", Loc(startPos, curPos()), {
                name = name,
                body = body,
            })

        -- local
        elseif tok.text == "local" then
            advance()
            if check("function") then
                advance()
                local nameTok = cur()
                if nameTok.type == TK.NAME then advance() end
                local body = P.parseFuncBody()
                return makeStat("localfunction", Loc(startPos, curPos()), {
                    name = makeExpr("local", Loc(nameTok.position, nameTok.position), {
                        name = makeTok(nameTok), token = makeTok(nameTok)
                    }),
                    body = body,
                })
            end
            local vars = parseNameList()
            local vals = {}
            if match("=") then
                vals = parseExprList()
            end
            return makeStat("local", Loc(startPos, curPos()), {
                variables = vars,
                values = vals,
            })

        -- return
        elseif tok.text == "return" then
            advance()
            local exprs = {}
            -- expressions follow unless we see end/else/elseif/until/eof/semicolon
            local stopSet = { ["end"]=true, ["else"]=true, ["elseif"]=true, ["until"]=true, [";"]=true }
            if not stopSet[cur().text] and cur().type ~= TK.EOF then
                exprs = parseExprList()
            end
            match(";")
            return makeStat("return", Loc(startPos, curPos()), {
                expressions = exprs,
            })

        -- break
        elseif tok.text == "break" then
            advance()
            return makeExpr("break", Loc(startPos, startPos))

        -- continue  (Luau)
        elseif tok.text == "continue" then
            advance()
            return makeExpr("continue", Loc(startPos, startPos))

        -- export type / type alias
        elseif tok.text == "export" then
            advance()
            if check("type") then
                advance()
                local nameTok = cur()
                if nameTok.type == TK.NAME then advance() end
                -- optional generic params
                if check("<") then
                    advance()
                    local d = 1
                    while not check(TK.EOF) and d > 0 do
                        if check("<") then d += 1; advance()
                        elseif check(">") then d -= 1; advance()
                        else advance() end
                    end
                end
                expect("=", "=")
                local typeExpr = parseType()
                return makeStat("typealias", Loc(startPos, curPos()), {
                    name = makeTok(nameTok),
                    type = typeExpr,
                })
            end
            -- treat `export` as an identifier expression (fall through to expr stat)
            -- re-parse from current position (export was already consumed; treat as name)
            local exportTok = { type = TK.NAME, text = "export", position = startPos }
            local lhs0 = parseSuffix(makeExpr("global", Loc(startPos, startPos), {
                name = makeTok(exportTok), token = makeTok(exportTok)
            }))
            local lhsList0 = { wrap(lhs0) }
            while match(",") do
                table.insert(lhsList0, wrap(parseSuffix(parsePrimary())))
            end
            if match("=") then
                return makeStat("assign", Loc(startPos, curPos()), {
                    variables = lhsList0, values = parseExprList(),
                })
            end
            return makeStat("expression", Loc(startPos, curPos()), { expression = lhs0 })

        elseif tok.text == "type" then
            -- `type Alias = ...`
            advance()
            local nameTok = cur()
            if nameTok.type == TK.NAME then advance() end
            if check("<") then
                advance(); local d=1
                while not check(TK.EOF) and d>0 do
                    if check("<") then d+=1;advance()
                    elseif check(">") then d-=1;advance()
                    else advance() end
                end
            end
            if match("=") then
                local typeExpr = parseType()
                return makeStat("typealias", Loc(startPos, curPos()), {
                    name = makeTok(nameTok),
                    type = typeExpr,
                })
            end
            -- `type` used as an expression (unusual; treat as identifier)
            local typeTok = { type = TK.NAME, text = "type", position = startPos }
            return makeStat("expression", Loc(startPos, curPos()), {
                expression = makeExpr("global", Loc(startPos, startPos), {
                    name = makeTok(typeTok), token = makeTok(typeTok)
                })
            })

        else
            -- Expression statement or assignment
            local lhs = parseSuffix(parsePrimary())
            local lhsList = { wrap(lhs) }

            -- Compound assignment?
            local compoundOps = { ["+="]="+=", ["-="]="-=", ["*="]="*=", ["/="]="/=",
                                  ["//="]="//=", ["%="]="%=", ["^="]="^=", ["..="]="..=" }
            if compoundOps[cur().text] then
                local opTok = advance()
                local val = parseExpr()
                return makeStat("compoundassign", Loc(startPos, curPos()), {
                    variable = lhs,
                    operand = makeTok(opTok),
                    value = val,
                })
            end

            -- Multiple assignment?
            while match(",") do
                table.insert(lhsList, wrap(parseSuffix(parsePrimary())))
            end

            if match("=") then
                -- assignment
                local vals = parseExprList()
                return makeStat("assign", Loc(startPos, curPos()), {
                    variables = lhsList,
                    values = vals,
                })
            end

            -- Expression statement (call)
            if #lhsList == 1 then
                return makeStat("expression", Loc(startPos, curPos()), {
                    expression = lhs,
                })
            end

            -- Shouldn't happen: comma-separated non-assignment expression list
            return makeStat("expression", Loc(startPos, curPos()), {
                expression = lhsList[1].node,
            })
        end
    end

    -- ── Block parsing ──────────────────────────────────────────────────

    local BLOCK_END = { ["end"]=true, ["else"]=true, ["elseif"]=true, ["until"]=true }

    parseBlock = function()
        local startPos = curPos()
        local stmts = {}
        while not BLOCK_END[cur().text] and cur().type ~= TK.EOF do
            local s = parseStatement()
            if s then
                table.insert(stmts, s)
                -- after return or break, skip to end of block
                if s.tag == "return" or s.tag == "break" then
                    match(";")
                    break
                end
            end
        end
        local endPos = curPos()
        return makeStat("block", Loc(startPos, endPos), {
            statements = stmts,
        })
    end

    -- ── Top-level parse ───────────────────────────────────────────────

    P.parseChunk = function()
        local block = parseBlock()
        return { root = block }
    end

    return P
end

-- ── Public API ────────────────────────────────────────────────────────

local function parsefile(source)
    local tokens = Tokenise(source)
    local parser = NewParser(tokens, source)
    local ast = parser.parseChunk()
    -- Wrap root to match expected format
    return {
        root = {
            statements = ast.root.statements,
        }
    }
end

return {
    parsefile = parsefile,
}
