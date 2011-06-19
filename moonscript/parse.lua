
module("moonscript.parse", package.seeall)

local util = require"moonscript.util"

require"lpeg"

local dump = require"moonscript.dump"
local data = require"moonscript.data"

local ntype = data.ntype
local trim = util.trim

local Stack = data.Stack

local function count_indent(str)
	local sum = 0
	for v in str:gmatch("[\t ]") do
		if v == ' ' then sum = sum + 1 end
		if v == '\t' then sum = sum + 4 end
	end
	return sum
end

local R, S, V, P = lpeg.R, lpeg.S, lpeg.V, lpeg.P
local C, Ct, Cmt, Cg, Cb, Cc = lpeg.C, lpeg.Ct, lpeg.Cmt, lpeg.Cg, lpeg.Cb, lpeg.Cc

lpeg.setmaxstack(3000)

local White = S" \t\n"^0
local _Space = S" \t"^0
local Break = S"\n"
local Stop = Break + -1
local Indent = C(S"\t "^0) / count_indent

local Comment = P"--" * (1 - S"\n")^0 * #Stop
local Space = _Space * Comment^-1

local _Name = C(R("az", "AZ", "__") * R("az", "AZ", "09", "__")^0)
local Name = Space * _Name
local Num = Space * C(R("09")^1) / tonumber

local FactorOp = Space * C(S"+-")
local TermOp = Space * C(S"*/%")

local function wrap(fn)
	local env = getfenv(fi)

	return setfenv(fn, setmetatable({}, {
		__index = function(self, name)
			local value = env[name] 
			if value ~= nil then return value end

			if name:match"^[A-Z][A-Za-z0-9]*$" then
				local v = V(name)
				rawset(self, name, v)
				return v
			end
			error("unknown variable referenced: "..name)
		end
	}))
end

function extract_line(str, start_pos)
	str = str:sub(start_pos)
	m = str:match"^(.-)\n"
	if m then return m end
	return str:match"^.-$"
end

local function mark(name)
	return function(...)
		return {name, ...}
	end
end

local function got(what)
	return Cmt("", function(str, pos, ...)
		local cap = {...}
		print("++ got "..what, "["..extract_line(str, pos).."]")
		return true
	end)
end

local function flatten(tbl)
	if #tbl == 1 then
		return tbl[1]
	end
	return tbl
end

local function flatten_or_mark(name)
	return function(tbl)
		if #tbl == 1 then return tbl[1] end
		table.insert(tbl, 1, name)
		return tbl
	end
end

local build_grammar = wrap(function()
	local err_msg = "Failed to parse, line:\n [%d] >> %s (%d)"

	local _indent = Stack(0) -- current indent

	local last_pos = 0 -- used to know where to report error
	local function check_indent(str, pos, indent)
		last_pos = pos
		return _indent:top() == indent
	end

	local function advance_indent(str, pos, indent)
		if indent > _indent:top() then
			_indent:push(indent)
			return true
		end
	end

	local function pop_indent(str, pos)
		if not _indent:pop() then error("unexpected outdent") end
		return true
	end

	local keywords = {}
	local function key(word)
		keywords[word] = true
		return Space * word
	end

	local function op(word)
		if word:match("^%w*$") then
			keywords[word] = true
		end
		return Space * C(word)
	end

	local function sym(chars)
		return Space * chars
	end

	local function symx(chars)
		return chars
	end

	local function flatten_func(callee, args)
		if #args == 0 then return callee end

		args = {"call", args}
		if ntype(callee) == "chain" then
			-- check for colon stub that needs arguments
			if ntype(callee[#callee]) == "colon_stub" then
				local stub = callee[#callee]
				stub[1] = "colon"
				table.insert(stub, args)
			else
				table.insert(callee, args)
			end

			return callee
		end

		return {"chain", callee, args}
	end

	local function wrap_func_arg(value)
		return {"call", {value}}
	end


	-- makes sure the last item in a chain is an index
	local _assignable = { index = true, dot = true, slice = true }
	local function check_assignable(str, pos, value)
		if ntype(value) == "chain" and _assignable[ntype(value[#value])]
			or type(value) == "string"
		then
			return true, value
		end
		return false
	end

	local SimpleName = Name -- for table key

	-- make sure name is not a keyword
	local Name = Cmt(Name, function(str, pos, name)
		if keywords[name] then return false end
		return true
	end) / trim

	local Name = sym"@" * Name / mark"self" + Name + Space * "..." / trim

	local function simple_string(delim, x)
		return C(symx(delim)) * C((P('\\'..delim) + (1 - S('\n'..delim)))^0) * sym(delim) / mark"string"
	end

	-- wrap if statement if there is a conditional decorator
	local function wrap_if(stm, cond)
		if cond then
			local pass, fail = unpack(cond)
			if fail then fail = {"else", {fail}} end
			return {"if", cond[2], {stm}, fail}
		end
		return stm
	end

	local function wrap_decorator(stm, dec)
		if not dec then return stm end

		local arg = {stm, dec}

		if dec[1] == "if" then
			local _, cond, fail = unpack(dec)
			if fail then fail = {"else", {fail}} end
			stm = {"if", cond, {stm}, fail}
		elseif dec[1] == "comprehension" then
			local _, clauses = unpack(dec)
			stm = {"comprehension", stm, clauses}
		end

		return stm
	end

	local function check_lua_string(str, pos, right, left)
		return #left == #right
	end

	local g = lpeg.P{
		File,
		File = Block + Ct"",
		Block = Ct(Line * (Break^1 * Line)^0),
		Line = Cmt(Indent, check_indent) * Statement + _Space * Comment,

		Statement = (Import + While + For + ClassDecl + Export + BreakLoop + Ct(ExpList) / flatten_or_mark"explist" * Space) * (
				-- statement decorators
				key"if" * Exp * (key"else" * Exp)^-1 * Space / mark"if" +
				CompInner / mark"comprehension"
			)^-1 / wrap_decorator,

		Body = Break * InBlock + Ct(Statement),

		InBlock = #Cmt(Indent, advance_indent) * Block * OutBlock,
		OutBlock = Cmt("", pop_indent),

		Import = key"import"*  Ct(ImportNameList) * key"from" * Exp / mark"import", 
		ImportName = (Ct(sym":" / trim * Name) + Name),
		ImportNameList = ImportName * (sym"," * ImportName)^0,

		NameList = Name * (sym"," * Name)^0,

		BreakLoop = Ct(key"break"/trim),

		If = key"if" * Exp * key"then"^-1 * Body *
			((Break * Cmt(Indent, check_indent))^-1 * key"elseif" * Exp * key"then"^-1 * Body / mark"elseif")^0 *
			((Break * Cmt(Indent, check_indent))^-1 * key"else" * Body / mark"else")^-1 / mark"if",

		While = key"while" * Exp * key"do"^-1 * Body / mark"while",

		For = key"for" * (Name * sym"=" * Ct(Exp * sym"," * Exp * (sym"," * Exp)^-1)) *
			key"do"^-1 * Body / mark"for",

		Comprehension = sym"[" * Exp * CompInner * sym"]" / mark"comprehension",

		CompInner = Ct(CompFor * CompClause^0),
		CompFor = key"for" * Ct(NameList) * key"in" * (sym"*" * Exp / mark"unpack" + Exp) / mark"for",
		CompClause = CompFor + key"when" * Exp / mark"when",

		Assign = Ct(AssignableList) * sym"=" * (If + Ct(TableBlock + ExpListLow)) / mark"assign",
		Update = Assignable * ((sym"+=" + sym"-=" + sym"*=" + sym"/=" + sym"%=")/trim) * Exp / mark"update",

		-- we can ignore precedence for now
		OtherOps = op"or" + op"and" + op"<=" + op">=" + op"~=" + op"!=" + op"==" + op".." + op"<" + op">",

		Assignable = Cmt(Chain, check_assignable) + Name,
		AssignableList = Assignable * (sym"," * Assignable)^0,

		Exp = Ct(Value * ((OtherOps + FactorOp + TermOp) * Value)^0) / flatten_or_mark"exp",

		-- Exp = Ct(Factor * (OtherOps * Factor)^0) / flatten_or_mark"exp",
		-- Factor = Ct(Term * (FactorOp * Term)^0) / flatten_or_mark"exp",
		-- Term = Ct(Value * (TermOp * Value)^0) / flatten_or_mark"exp",

		Value =
			If +
			sym"-" * Exp / mark"minus" +
			sym"#" * Exp / mark"length" +
			sym"not" * Exp / mark"not" +
			TableLit +
			Comprehension +
			ColonChain * Ct(ExpList^0) / flatten_func + -- have precedence over open table
			Ct(KeyValueList) / mark"table" +
			Assign + Update + FunLit + String +
			((Chain + Callable) * Ct(ExpList^0)) / flatten_func +
			Num,


		String = Space * DoubleString + Space * SingleString + LuaString,
		SingleString = simple_string("'"),
		DoubleString = simple_string('"'),

		LuaString = Cg(LuaStringOpen, "string_open") * Cb"string_open" * P"\n"^-1 *
			C((1 - Cmt(C(LuaStringClose) * Cb"string_open", check_lua_string))^0) *
			C(LuaStringClose) / mark"string",

		LuaStringOpen = sym"[" * P"="^0 * "[" / trim,
		LuaStringClose = "]" * P"="^0 * "]",

		Callable = Name + Parens / mark"parens",
		Parens = sym"(" * Exp * sym")",

		FnArgs = symx"(" * Ct(ExpList^-1) * sym")",

		-- chain that starts with colon expression (for precedence over table literal)
		ColonChain = 
			Callable * (ColonCall * (ChainItem)^0 + ColonSuffix) / mark"chain",

		-- a list of funcalls and indexs on a callable
		Chain = Callable * (ChainItem^1 * ColonSuffix^-1 + ColonSuffix) / mark"chain",

		ChainItem = 
			Invoke + 
			Slice +
			symx"[" * Exp/mark"index" * sym"]" +
			symx"." * _Name/mark"dot" +
			ColonCall,

		Slice = symx"[" * Num * sym":" * Num * (sym":" * Num)^-1 *sym"]" / mark"slice",

		ColonCall = symx":" * (_Name * Invoke) / mark"colon",

		ColonSuffix = symx":" * _Name / mark"colon_stub",

		Invoke = FnArgs/mark"call" +
			SingleString / wrap_func_arg +
			DoubleString / wrap_func_arg,

		TableValue = KeyValue + Ct(Exp),

		TableLit = sym"{" * White *
			Ct((TableValue * ((sym"," + Break) * White * TableValue)^0)^-1) * sym","^-1 *
			White * sym"}" / mark"table",

		TableBlockInner = Ct(KeyValueLine * (Break^1 * KeyValueLine)^0),

		TableBlock = Break * #Cmt(Indent, advance_indent) * TableBlockInner * OutBlock / mark"table",

		ClassDecl = key"class" * Name * (key"extends" * Exp + C"")^-1 * TableBlock / mark"class",
		Export = key"export" * Ct(NameList) / mark"export",

		KeyValue = Ct((SimpleName + sym"[" * Exp * sym"]") * symx":" * (Exp + TableBlock)),
		KeyValueList = KeyValue * (sym"," * KeyValue)^0,
		KeyValueLine = Cmt(Indent, check_indent) * KeyValueList * sym","^-1,

		FunLit = (sym"(" * Ct(NameList^-1) * sym")" + Ct("")) *
			(sym"->" * Cc"slim" + sym"=>" * Cc"fat") *
			(Body + Ct"") / mark"fndef",

		NameList = Name * (sym"," * Name)^0,
		ExpList = Exp * (sym"," * Exp)^0,
		ExpListLow = Exp * ((sym"," + sym";") * Exp)^0,
	}

	return {
		_g = White * g * White * -1,
		match = function(self, str, ...)
			local function pos_to_line(pos)
				local line = 1
				for _ in str:sub(1, pos):gmatch("\n") do
					line = line + 1
				end
				return line
			end

			local function get_line(num)
				for line in str:gmatch("(.-)[\n$]") do
					if num == 1 then return line end
					num = num - 1
				end
			end


			local tree
			local args = {...}
			local pass, err = pcall(function()
				tree = self._g:match(str, unpack(args))
			end)

			if not pass then
				local line_no = pos_to_line(last_pos)
				print("stopped at", line_no)
				error(err)
			end
			

			if not tree then
				local line_no = pos_to_line(last_pos)
				local line_str = get_line(line_no)
				return nil, err_msg:format(line_no, line_str, _indent:top())
			end
			return tree
		end
	}
	
end)

-- parse a string
-- returns tree, or nil and error message
function string(str)
	local g = build_grammar()
	return g:match(str)
end

local program3 = [[
-- hello
class Hello
	@something: 2323

	hello: () ->
		print 200
]]
