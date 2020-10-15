-- ZPU base instructions implementation
-- this file contains the implementations of the opcodes(returned as opcode table).
-- most code by vifino, some improvements by max1220
local bitlib = require("bitlib")

local bnot = assert(bitlib.bnot)
local band = assert(bitlib.band)
local bor = assert(bitlib.bor)
local bxor = assert(bitlib.bxor)
local lshift = assert(bitlib.lshift)
local rshift = assert(bitlib.rshift)

-- helpers
local function v_push(self, v)
	self.rSP = band(self.rSP - 4, 0xFFFFFFFF)
	self:set32(self.rSP, v)
end
local function v_pop(self)
	local v = self:get32(self.rSP)
	self.rSP = band(self.rSP + 4, 0xFFFFFFFC)
	return v
end

-- OPs!
local function op_im(self, i, last)
	if last then
		v_push(self, bor(lshift(band(v_pop(self), 0x1FFFFFFF), 7), i))
	else
		if band(i, 0x40) ~= 0 then i = bor(i, 0xFFFFFF80) end
		v_push(self, i)
	end
end
local function op_loadsp(self, i)
	local addr = band(self.rSP + lshift(bxor(i, 0x10), 2), 0xFFFFFFFC)
	v_push(self, self:get32(addr))
end
local function op_storesp(self, i)
	-- Careful with the ordering! Documentation suggests the OPPOSITE of what it should be!
	-- https://github.com/zylin/zpugcc/blob/master/toolchain/gcc/libgloss/zpu/crt0.S#L836
	-- This is a good testpoint:
	-- 0x81 0x3F
	-- This should leave zpuinst.rSP + 4 on stack.
	-- You can work it out from the sources linked.
	local bsp = band(self.rSP + lshift(bxor(i, 0x10), 2), 0xFFFFFFFC)
	self:set32(bsp, v_pop(self))
end
local function op_addsp(self, i)
	local addr = band(self.rSP + lshift(i, 2), 0xFFFFFFFC)
	v_push(self, band(self:get32(addr) + v_pop(self), 0xFFFFFFFF))
end
local function op_load(self)
	self:set32(self.rSP, self:get32(band(self:get32(self.rSP), 0xFFFFFFFC)))
end
local function op_store(self)
	self:set32(band(v_pop(self), 0xFFFFFFFC), v_pop(self))
end
local function op_add(self)
	local a = v_pop(self)
	self:set32(self.rSP, band(a + self:get32(self.rSP), 0xFFFFFFFF))
end
local function op_and(self)
	v_push(self, band(v_pop(self), v_pop(self)))
end
local function op_or(self)
	v_push(self, bor(v_pop(self), v_pop(self)))
end
local function op_not(self)
	v_push(self, bnot(v_pop(self)))
end
local function op_emulate(self, op)
	v_push(self, band(self.rIP + 1, 0xFFFFFFFF))
	self.rIP = lshift(op, 5)
	return "EMULATE ".. op .. "/" .. bor(op, 0x20)
end
local op_flip_tb = {
	[0] = 0,
	[1] = 2,
	[2] = 1,
	[3] = 3
}
local function op_flip_byte(i)
	local a = op_flip_tb[rshift(band(i, 0xC0), 6)]
	local b = op_flip_tb[rshift(band(i, 0x30), 4)]
	local c = op_flip_tb[rshift(band(i, 0x0C), 2)]
	local d = op_flip_tb[band(i, 0x03)]
	return bor(bor(a, lshift(b, 2)), bor(lshift(c, 4), lshift(d, 6)))
end
local function op_flip(self)
	local v = v_pop(self)
	local a = op_flip_byte(band(rshift(v, 24), 0xFF))
	local b = op_flip_byte(band(rshift(v, 16), 0xFF))
	local c = op_flip_byte(band(rshift(v, 8), 0xFF))
	local d = op_flip_byte(band(v, 0xFF))
	v_push(self, bor(bor(lshift(d, 24), lshift(c, 16)), bor(lshift(b, 8), a)))
end
local function ip_adv(self)
	self.rIP = band(self.rIP + 1, 0xFFFFFFFF)
end


-- do_* function are for instruction decoding

-- base instructions
local function do_POPPC(self)
	self.rIP = v_pop(self)
	return "POPPC"
end
local function do_LOAD(self)
	op_load(self)
	ip_adv(self)
	return "LOAD"
end
local function do_STORE(self)
	op_store(self)
	ip_adv(self)
	return "STORE"
end
local function do_PUSHSP(self)
	v_push(self, self.rSP)
	ip_adv(self)
	return "PUSHSP"
end
local function do_POPSP(self)
	self.rSP = band(v_pop(self), 0xFFFFFFFC)
	ip_adv(self)
	return "POPSP"
end
local function do_ADD(self)
	op_add(self)
	ip_adv(self)
	return "ADD"
end
local function do_AND(self)
	op_and(self)
	ip_adv(self)
	return "AND"
end
local function do_OR(self)
	op_or(self)
	ip_adv(self)
	return "OR"
end
local function do_NOT(self)
	op_not(self)
	ip_adv(self)
	return "NOT"
end
local function do_FLIP(self)
	op_flip(self)
	ip_adv(self)
	return "FLIP"
end
local function do_NOP(self)
	ip_adv(self) return "NOP"
end

-- instructions that require immediate decoding
local function do_IM(self, op, lim)
	local tmp = band(op, 0x7F)
	op_im(self, tmp, lim)
	self.fLastIM = true
	ip_adv(self)
	return "IM "..tmp
end
local function do_LOADSP(self, op)
	local tmp = band(op, 0x1F)
	op_loadsp(self, tmp)
	ip_adv(self)
	return "LOADSP " .. (bxor(0x10, tmp) * 4)
end
local function do_STORESP(self, op)
	local tmp = band(op, 0x1F)
	op_storesp(self, tmp)
	ip_adv(self)
	return "STORESP " .. (bxor(0x10, tmp) * 4)
end
local function do_EMULATE(self, op)
	return op_emulate(self, band(op, 0x1F))
end
local function do_ADDSP(self, op)
	local tmp = band(op, 0xF)
	op_addsp(self, tmp)
	ip_adv(self)
	return "ADDSP " .. tmp
end

-- OP lookup table
local op_table = {
	[0x04] = do_POPPC,
	[0x08] = do_LOAD,
	[0x0C] = do_STORE,
	[0x02] = do_PUSHSP,
	[0x0D] = do_POPSP,
	[0x05] = do_ADD,
	[0x06] = do_AND,
	[0x07] = do_OR,
	[0x09] = do_NOT,
	[0x0A] = do_FLIP,
	[0x0B] = do_NOP,
}
for op=0x80, 0xFF do
	op_table[op] = do_IM
end
for op=0x60, 0x7F do
	op_table[op] = do_LOADSP
end
for op=0x40, 0x5F do
	op_table[op] = do_STORESP
end
for op=0x20, 0x3F do
	op_table[op] = do_EMULATE
end
for op=0x10, 0x1F do
	op_table[op] = do_ADDSP
end

return op_table
