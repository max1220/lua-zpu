#!/usr/bin/env luajit
local zpu_emu = require("zpu")
local memory = require("memory")
local bit = require("bitlib")
--local zpu_emulates = dofile("zpu_emus.lua")
--local band,bor = bit.band,bit.bor

local memsz = 0x80000


local f = assert(io.open(assert(arg[1]), "rb"))
local rom_data = f:read(memsz)
f:close()

local function serial_read()
	return io.read(1):byte()
end

local function serial_write(val)
	io.write(string.char(val))
end

-- Memory: ROM, RAM and peripherals.
local serial = memory.new_zpu_serial(serial_read, serial_write, bit)
local ram = memory.new_ffi(memsz, bit)
for i=1, #rom_data do
	ram.write_u8(i-1, rom_data:byte(i))
end

local mem = memory.reverse_byteorder(memory.new_callbacks({
	serial,
	ram
}), bit)

-- Get ZPU instance and set up.
local zpu = zpu_emu.new(mem.read_u32, mem.write_u32)
zpu.rSP = memsz

while zpu:step_trace(io.stderr, 1) do
end

-- echo "end" | ./emu_zpu.lua tests/zpu/reb_old.bin > mem_log.txt 2> instr_log.txt ; less instr_log.txt
-- echo "end" | ./emulator.lua ../tests/zpu/reb_old.bin > mem_log.txt 2> instr_log.txt ; less instr_log.txt
