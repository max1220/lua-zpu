-- ZPU EMULATE instructions implementation
-- Original by vifino, rewritten(again) by max1220
local bitlib = require("bitlib")

local band = assert(bitlib.band)
local bor = assert(bitlib.bor)
local bxor = assert(bitlib.bxor)
local lshift = assert(bitlib.lshift)
local rshift = assert(bitlib.rshift)
local mceil, mfloor = math.ceil, math.floor


-- Utils
local function a32(v)
	return band(v, 0xFFFFFFFF)
end
local function sflip(v)
	v = a32(v)
	if band(v, 0x80000000) ~= 0 then
		return v - 0x100000000
	end
	return v
end
local function mkbool(v)
	return v and 1 or 0
end
local function advip(zpu_emu)
	zpu_emu.rIP = a32(zpu_emu.rIP + 1)
end
local function v_push(self, v)
	self.rSP = band(self.rSP - 4, 0xFFFFFFFF)
	self:set32(self.rSP, v)
end
local function v_pop(self)
	local v = self:get32(self.rSP)
	self.rSP = band(self.rSP + 4, 0xFFFFFFFC)
	return v
end

-- getb and setb are the internal implementation of LOADB and STOREB
-- and are thus heavily endianess dependant
local function getb(zpu_emu, a)
	local s = (24 - lshift(band(a, 3), 3))
	local av = zpu_emu:get32(band(a, 0xFFFFFFFC))
	return band(rshift(av, s), 0xFF)
end
local function setb(zpu_emu, a, v)
	local s = (24 - lshift(band(a, 3), 3))
	local b = bxor(lshift(0xFF, s), 0xFFFFFFFF)
	local av = band(zpu_emu:get32(band(a, 0xFFFFFFFC)), b)
	zpu_emu:set32(band( a, 0xFFFFFFFC), bor(av, lshift(band(v, 0xFF), s)))
end

local function rtz(v)
	if v < 0 then return mceil(v) end
	return mfloor(v)
end
local function cmod(a, b)
	return a - (rtz(a / b) * b)
end

-- geth and seth are the same but for halfwords.
-- This implementation will just mess up if it gets a certain kind of misalignment.
-- (I have no better ideas. There is no reliable way to error-escape.)
local function geth(zpu_emu, a)
	local s = (24 - lshift(band(a, 3), 3))
	local av = zpu_emu:get32(band(a, 0xFFFFFFFC))
	return band(rshift(av, s), 0xFFFF)
end
local function seth(zpu_emu, a, v)
	local s = (24 - lshift(band(a, 3), 3))
	local b = bxor(lshift(0xFFFF, s), 0xFFFFFFFF)
	local av = band(zpu_emu:get32(band(a, 0xFFFFFFFC)), b)
	zpu_emu:set32(band(a, 0xFFFFFFFC), bor(av, lshift(band(v, 0xFFFF), s)))
end

-- Generic L/R shifter, logical-only.
local function gpi_shift(v, lShift)
	if (lShift >= 32) or (lShift <= -32) then return 0 end
	if lShift > 0 then return lshift(v, lShift) end
	if lShift < 0 then return rshift(v, -lShift) end
end
-- Generic multifunction shifter. Should handle any case with ease.
local function gp_shift(v, lShift, arithmetic)
	arithmetic = arithmetic and band(v, 0x80000000) ~= 0
	v = gpi_shift(v, lShift)
	if arithmetic and (lShift < 0) then
		return bor(v, bxor(gpi_shift(0xFFFFFFFF, lShift), 0xFFFFFFFF))
	end
	return v
end



-- Build opcode table
local op_table = {}
local function add(id, fn)
	op_table[id] = fn
end
-- wrap in stack decoding(pop 2 arguments from stack, push 1 result)
local function wrap(name, fn)
	return function(zpu_emu)
		local a = v_pop(zpu_emu)
		local b = zpu_emu:get32(zpu_emu.rSP)
		zpu_emu:set32(zpu_emu.rSP, fn(a, b))
		advip(zpu_emu)
		return name
	end
end

-- do_* functions are added directly to the opcode table
-- op_* functions always pop 2 arguments and push 1 result to the stack
local function do_LOADH(zpu_emu)
	zpu_emu:set32(zpu_emu.rSP, geth(zpu_emu, zpu_emu:get32(zpu_emu.rSP)))
	advip(zpu_emu)
	return "LOADH"
end
local function do_STOREH(zpu_emu)
	seth(zpu_emu, v_pop(zpu_emu), v_pop(zpu_emu))
	advip(zpu_emu)
	return "STOREH"
end
local function op_LESSTHAN(a, b)
	return mkbool(sflip(a) < sflip(b))
end
local function op_LESSTHANEQUAL(a, b)
	return mkbool(sflip(a) <= sflip(b))
end
local function op_ULESSTHAN(a, b)
	return mkbool(a < b)
end
local function op_ULESSTHANEQUAL(a, b)
	return mkbool(a <= b)
end
local function op_LSHIFTRIGHT(a, b)
	return gp_shift(b, -sflip(a), false)
end
local function op_ASHIFTLEFT(a, b)
	return gp_shift(b, sflip(a), true)
end
local function op_ASHIFTRIGHT(a, b)
	return gp_shift(b, -sflip(a), true)
end
local function op_SLOWMULT(a, b)
	return band(a * b, 0xFFFFFFFF)
end
local function op_EQ(a, b)
	return mkbool(a == b)
end
local function op_NEQ(a, b)
	return mkbool(a ~= b)
end
local function do_NEG(zpu_emu)
	zpu_emu:set32(zpu_emu.rSP, a32(-sflip(zpu_emu:get32(zpu_emu.rSP))))
	advip(zpu_emu)
	return "NEG"
end
local function op_SUB(b, a)
	return band(a - b, 0xFFFFFFFF)
end
local function op_XOR(b, a)
	return band(bxor(a, b), 0xFFFFFFFF)
end
local function do_LOADB(zpu_emu)
	zpu_emu:set32(zpu_emu.rSP, getb(zpu_emu, zpu_emu:get32(zpu_emu.rSP)))
	advip(zpu_emu)
	return "LOADB"
end
local function do_STOREB(zpu_emu)
	setb(zpu_emu, v_pop(zpu_emu), v_pop(zpu_emu))
	advip(zpu_emu)
	return "STOREB"
end
local function op_DIV(a, b)
	return a32(rtz(sflip(a) / sflip(b)))
end
local function op_MOD(a, b)
	return a32(cmod(sflip(a), sflip(b)))
end
local function do_EQBRANCH(zpu_emu)
	local br = a32(zpu_emu.rIP + v_pop(zpu_emu))
	if v_pop(zpu_emu)==0 then
		zpu_emu.rIP = br
	else
		advip(zpu_emu)
	end
	return "EQBRANCH"
end
local function do_NEQBRANCH(zpu_emu)
	local br = a32(zpu_emu.rIP + v_pop(zpu_emu))
	if v_pop(zpu_emu)~=0 then
		zpu_emu.rIP = br
	else
		advip(zpu_emu)
	end
	return "NEQBRANCH"
end
local function do_POPPCREL(zpu_emu)
	zpu_emu.rIP = band(zpu_emu.rIP + v_pop(zpu_emu), 0xFFFFFFFF)
	return "POPPCREL"
end
local function do_PUSHSPADD(zpu_emu)
	zpu_emu:set32(zpu_emu.rSP, band(band(lshift(zpu_emu:get32(zpu_emu.rSP), 2), 0xFFFFFFFF) + zpu_emu.rSP, 0xFFFFFFFC))
	advip(zpu_emu)
	return "PUSHSPADD"
end
local function do_CALLPCREL(zpu_emu)
	local routine = band(zpu_emu.rIP + zpu_emu:get32(zpu_emu.rSP), 0xFFFFFFFF)
	zpu_emu:set32(zpu_emu.rSP, band(zpu_emu.rIP + 1, 0xFFFFFFFF))
	zpu_emu.rIP = routine
	return "CALLPCREL"
end

add(2,  do_LOADH)
add(3,  do_STOREH)
add(4,  wrap("LESSTHAN", op_LESSTHAN))
add(5,  wrap("LESSTHANEQUAL", op_LESSTHANEQUAL))
add(6,  wrap("ULESSTHAN", op_ULESSTHAN))
add(7,  wrap("ULESSTHANEQUAL", op_ULESSTHANEQUAL))
add(9,  wrap("SLOWMULT", op_SLOWMULT))
add(10, wrap("LSHIFTRIGHT", op_LSHIFTRIGHT))
add(11, wrap("ASHIFTLEFT", op_ASHIFTLEFT))
add(12, wrap("ASHIFTRIGHT", op_ASHIFTRIGHT))
add(14, wrap("EQ", op_EQ))
add(15, wrap("NEQ", op_NEQ))
add(16, do_NEG)
add(17, wrap("SUB", op_SUB))
add(18, wrap("XOR", op_XOR))
add(19, do_LOADB)
add(20, do_STOREB)
add(21, wrap("DIV", op_DIV))
add(22, wrap("MOD", op_MOD))
add(23, do_EQBRANCH)
add(24, do_NEQBRANCH)
add(25, do_POPPCREL)
add(29, do_PUSHSPADD)
add(31, do_CALLPCREL)


return op_table
