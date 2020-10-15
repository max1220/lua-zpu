-- ZPU Emulator V4
-- this file creates a new ZPU instance.
-- optimized for execution speed in LuaJIT
-- Based on ZPU Emulator V3 by vifino
-- https://github.com/vifino/lua-cpuemus
local bitlib = require("bitlib")
local op_table = require("zpu_instructions")
local op_table_emulate = require("zpu_instructions_emulate")

for k,v in pairs(op_table_emulate) do
	op_table[0x20+k] = v
end

local band = assert(bitlib.band)
local rshift = assert(bitlib.rshift)


local function split32(v)
	return {
		band(rshift(v, 24), 0xFF),
		band(rshift(v, 16), 0xFF),
		band(rshift(v, 8), 0xFF),
		band(v, 0xFF)
	}
end

-- get the instruction currently pointed at by rIP
local function zpu_fetch(self)
	-- NOTE: The ZPU porbably can't be trusted to have a consistent memory
	-- access pattern, *unless* it is accessing memory in the IO range.
	-- In the case of the IO range, it is specifically
	-- assumed MMIO will happen there, so the processor bypasses caches.
	-- For now, we're just using the behavior that would be used for
	-- a naive processor, which is exactly what this is.
	return split32(self:get32(band(self.rIP, 0xFFFFFFFC)))[band(self.rIP, 3) + 1]
end

-- Run a single instruction
local function zpu_step(self)
	local op = zpu_fetch(self)
	local lim = self.fLastIM
	self.fLastIM = false

	-- check if OP is found in lookup tables
	-- By the amount of ops we have, a lookup table is a good thing.
	-- For a few ifs, it would probably be slower. But for many, it is faster on average.
	return op_table[op](self, op, lim)
end

local function zpu_step_trace(self, fh, tracestack)
	fh:write(self.rIP .. " (" .. string.format("%x", self.rSP))
	fh:flush()
	for i=0, tracestack-1 do
		local success, val = pcall(self.get32, self, self.rSP+i*4)
		fh:write(string.format("/%x", success and val or 0))
	end
	local op_code = zpu_fetch(self)
	fh:write(") ("..string.format("%x", op_code).."): ")
	local op_name = self:step()
	fh:write(op_name or "UNKNOWN", "\n")
	return op_name, op_code
end

local zpu = {}

-- Create a new ZPU instance
function zpu.new(memget32, memset32)
	local zpu_instance = {}
	setmetatable(zpu_instance, {
		__index = {
			step = zpu_step,
			step_trace = zpu_step_trace,
		}
	})
	zpu_instance.get32 = function(_, addr) return memget32(addr) end
	zpu_instance.set32 = function(_, addr, val) return memset32(addr, val) end

	zpu_instance.rSP = 0
	zpu_instance.rIP = 0
	zpu_instance.fLastIM = false

	return zpu_instance
end

-- Hooray! We're done!
return zpu
