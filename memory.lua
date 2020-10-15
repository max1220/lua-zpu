local bitlib = require("bitlib")

local memory = {}

-- get a new memory interface that uses the LuaJITs FFI librarie
function memory.new_ffi(size)
	local ffi = require("ffi")

	local rshift = assert(bitlib.rshift)

	local mem = {}
	mem.size = size

	local data_u8 = ffi.new("uint8_t[?]", size, 0)
	local data_u32 = ffi.cast("uint32_t*", data_u8)

	function mem.read_u8(addr)
		if (addr<0) or (addr+1>size) then
			error("Illegal read_u8 at: " .. tostring(addr), 2)
		end
		return data_u8[addr]
	end

	function mem.write_u8(addr, val)
		if (addr<0) or (addr+1>size) or (val<0) or (val>0xFF) then
			error("Illegal write_u8 at: " .. tostring(addr) .. " = " .. tostring(val), 2)
		end
		data_u8[addr] = val
		return true
	end

	function mem.read_u32(addr)
		if (addr<0) or (addr+4>size) then
			error("Illegal read_u32 at: " .. tostring(addr), 2)
		end
		return data_u32[rshift(addr,2)]
	end

	function mem.write_u32(addr, val)
		if (addr<0) or (addr+4>size) or (val<0) or (val>0xFFFFFFFF) then
			error("Illegal write_u32 at: " .. tostring(addr) .. " = " .. tostring(val), 2)
		end
		data_u32[rshift(addr,2)] = val
		return true
	end

	return mem
end

-- get a new memory interface that uses regular lua tables
function memory.new_table(size)
	local band, rshift = assert(bitlib.band), assert(bitlib.rshift)

	local mem = {}
	mem.size = size

	local data = {}
	for i=0, size-1 do
		data[i] = 0
	end

	function mem.read_u8(addr)
		if (addr<0) or (addr+1>size) then
			error("Illegal read_u8 at: " .. tostring(addr), 2)
		end
		return data[addr]
	end

	function mem.write_u8(addr, val)
		if (addr<0) or (addr+1>size) or (val<0) or (val>0xFF) then
			error("Illegal write_u8 at: " .. tostring(addr) .. " = " .. tostring(val), 2)
		end
		data[addr] = val
		return true
	end

	function mem.read_u32(addr)
		if (addr<0) or (addr+4>size) then
			error("Illegal read_u32 at: " .. tostring(addr), 2)
		end
		addr = band(addr, 0xFFFFFFFC)
		return data[addr] + data[addr+1]*0x100 + data[addr+2]*0x10000 + data[addr+3]*0x1000000
	end

	function mem.write_u32(addr, val)
		if (addr<0) or (addr+4>size) or (val<0) or (val>0xFFFFFFFF) then
			error("Illegal write_u32 at: " .. tostring(addr) .. " = " .. tostring(val), 2)
		end
		addr = band(addr, 0xFFFFFFFC)
		data[addr] = band(val, 0xff)
		data[addr+1] = band(rshift(val, 8), 0xff)
		data[addr+2] = band(rshift(val, 16), 0xff)
		data[addr+3] = band(rshift(val, 24), 0xff)
		return true
	end

	return mem
end

-- get a new memory interface that uses a string as backend
function memory.new_string(str)
	local band, rshift = assert(bitlib.band), assert(bitlib.rshift)

	local mem = {}
	mem.size = #str

	local data = str

	function mem.read_u8(addr)
		if (addr<0) or (addr+1>#str) then
			error("Illegal read_u8 at: " .. tostring(addr), 2)
		end
		return data:byte(addr+1)
	end

	function mem.write_u8(addr, val)
		if (addr<0) or (addr+1>#str) or (val<0) or (val>0xFF) then
			error("Illegal write_u8 at: " .. tostring(addr) .. " = " .. tostring(val), 2)
		end
		data = data:sub(1, addr)..string.char(val)..data:sub(addr+1)
		return true
	end

	function mem.read_u32(addr)
		if (addr<0) or (addr+4>#str) then
			error("Illegal read_u32 at: " .. tostring(addr), 2)
		end
		addr = band(addr, 0xFFFFFFFC)
		local a,b,c,d = data:byte(addr+1, addr+4)
		return a+b*0x100+c*0x10000+d*0x1000000
	end

	function mem.write_u32(addr, val)
		if (addr<0) or (addr+1>#str) or (val<0) or (val>0xFFFFFFFF) then
			error("Illegal write_u32 at: " .. tostring(addr) .. " = " .. tostring(val), 2)
		end
		addr = band(addr, 0xFFFFFFFC)
		local a = band(val, 0xff)
		local b = band(rshift(val, 8), 0xff)
		local c = band(rshift(val, 16), 0xff)
		local d = band(rshift(val, 24), 0xff)
		data = data:sub(1, addr)..string.char(a,b,c,d)..data:sub(addr+5)
		return true
	end

	return mem
end

-- get a memory interface that allows chaining other memory interfaces together.
function memory.new_callbacks(callbacks)
	local mem = {}

	local function wrap(func)
		return function (addr, val)
			for i=1, #callbacks do
				local ret = callbacks[i][func](addr, val)
				if ret then
					return ret
				end
			end
		end
	end

	mem.read_u8 = wrap("read_u8")
	mem.write_u8 = wrap("write_u8")
	mem.read_u32 = wrap("read_u32")
	mem.write_u32 = wrap("write_u32")

	return mem
end

-- get a memory interface that handles the ZPU's serial port
function memory.new_zpu_serial(serial_read, serial_write)
	local band,bor = bitlib.band,bitlib.bor
	local dummy = function() end

	local mem = {
		read_u8 = dummy,
		write_u8 = dummy
	}

	function mem.read_u32(addr)
		if addr == 0x80000024 then
			return 0x100
		elseif addr == 0x80000028 then
			return bor(serial_read(), 0x100) -- read character from serial
		end
	end
	function mem.write_u32(addr, val)
		if addr == 0x80000024 then
			serial_write(band(val, 0xff)) -- write character to serial
			return true
		end
	end

	return mem
end


-- simple correctness check
local function args_to_str(hex, ...)
	local str = ""
	for _,v in pairs({...}) do
		if hex and (type(v) == "number") then
			str = str .. ("0x%.8x"):format(v) .. ","
		else
			str = str .. tostring(v) .. ","
		end
	end
	return str:sub(1, -2)
end
function memory.test_implementation(mem)
	local hex = true
	local total,failed = 0,0
	local function expect(name, fn, expected, ...)
		total = total + 1
		local ok, ret = pcall(fn, ...)
		local expected_str = tostring(expected)
		if hex and (type(expected)=="number") then
			expected_str = ("0x%.8x"):format(expected)
		end
		local ret_str = tostring(ret)
		if hex and (type(ret)=="number") then
			ret_str = ("0x%.8x"):format(ret)
		end
		local test_str = name .. "(" .. args_to_str(hex, ...)..")=="..expected_str
		if ok and (expected==ret) then
			print("\tTest ok:     "..test_str)
		elseif ok and (expected~=ret) then
			print("\tTest failed: "..test_str, "Got: "..ret_str, "Expected: "..expected_str)
			failed = failed + 1
		elseif not ok then
			print("\tTest failed: "..test_str, "Error: "..ret_str)
			failed = failed + 1
		end
	end

	local function expect_error(name, fn, expected_error, ...)
		total = total + 1
		local ok, err = pcall(fn, ...)
		local test_str = name .. "(" .. args_to_str(false, ...)..")==error(\"" .. tostring(expected_error) .. "\")"
		if (not ok) and (err == expected_error) then
			print("\tTest ok:     "..test_str)
		elseif ok then
			print("\tTest failed: "..test_str, "Got (no error) ", "Returned: " .. tostring(err))
			failed = failed + 1
		else
			print("\tTest failed: "..test_str, "Got error(\""..tostring(err) .. "\")")
			failed = failed + 1
		end
	end

	-- test address ranges
	expect_error("read_u8", mem.read_u8, "Illegal read_u8 at: -1", -1)
	expect_error("write_u8", mem.write_u8, "Illegal write_u8 at: -1 = 1", -1, 1)
	for i=0, mem.size-1 do
		expect("read_u8", mem.read_u8, 0, i)
	end
	expect_error("read_u8", mem.read_u8, "Illegal read_u8 at: 256", 256)
	expect_error("write_u8", mem.write_u8, "Illegal write_u8 at: 256 = 1", 256, 1)

	expect_error("read_u32", mem.read_u32, "Illegal read_u32 at: -1", -1)
	expect_error("write_u32", mem.write_u32, "Illegal write_u32 at: -1 = 1", -1, 1)
	for i=0, (mem.size/4)-1 do
		expect("read_u32", mem.read_u32, 0, i*4)
	end
	expect_error("read_u32", mem.read_u32, "Illegal read_u32 at: 253", 253)
	expect_error("write_u32", mem.write_u32, "Illegal write_u32 at: -1 = 1", -1, 1)


	-- test reading/writing is consistent
	expect("write_u8", mem.write_u8, true, 0, 0xAB)
	expect("read_u8", mem.read_u8, 0xAB, 0)
	expect("read_u32", mem.read_u32, 0xAB, 0) -- byte-order dependent
	expect("write_u32", mem.write_u32, true, 0, 0xCDCDCDCD)
	expect("read_u32", mem.read_u32, 0xCDCDCDCD, 0)
	expect("write_u32", mem.write_u32, true, 4, 0x12345678)
	expect("read_u32", mem.read_u32, 0x12345678, 4)
	expect("write_u32", mem.write_u32, true, 0, 0xFFCDCDCD)
	expect("read_u32", mem.read_u32, 0xFFCDCDCD, 0)
	expect("write_u32", mem.write_u32, true, 1, 0xFFCDCDCD) -- check forced alignment
	expect("read_u32", mem.read_u32, 0xFFCDCDCD, 0)
	expect("read_u8", mem.read_u8, 0xCD, 0) -- byte-order dependent
	expect("read_u8", mem.read_u8, 0xCD, 1)
	expect("read_u8", mem.read_u8, 0xCD, 2)
	expect("read_u8", mem.read_u8, 0xFF, 3)
	expect("read_u32", mem.read_u32, 0x12345678, 4) -- check for "spills"

	return total,failed
end
function memory.test_all()
	local test_size = 0x100
	local total,failed = 0,0
	local ntotal,nfailed
	if jit then
		bitlib = require("bit")
		local ffi_mem = memory.new_ffi(test_size, bitlib)
		print("FFI")
		ntotal,nfailed = memory.test_implementation(ffi_mem)
		total,failed = total+ntotal,failed+nfailed
	end

	local table_mem = memory.new_table(test_size, bitlib)
	print("Table")
	ntotal,nfailed = memory.test_implementation(table_mem)
	total,failed = total+ntotal,failed+nfailed

	local string_mem = memory.new_string(("\0"):rep(test_size-1), bitlib)
	print("String")
	ntotal,nfailed = memory.test_implementation(string_mem)
	total,failed = total+ntotal,failed+nfailed

	print(("="):rep(80))
	print("Total", total)
	print("Failed", failed)
	print(("="):rep(80))
end

function memory.reverse_byteorder(mem)
	local band, bor, lshift, rshift = bitlib.band, bitlib.bor, bitlib.lshift, bitlib.rshift
	local function flip(val)
		local a = band(val, 0x000000ff)
		local b = band(val, 0x0000ff00)
		local c = band(val, 0x00ff0000)
		local d = band(val, 0xff000000)
		return bor(bor(bor(lshift(a, 24), lshift(b, 8)), rshift(c, 8)), rshift(d, 24))
	end

	local _read_u32 = mem.read_u32
	local _write_u32 = mem.write_u32
	function mem.read_u32(addr)
		return flip(_read_u32(addr))
	end
	function mem.write_u32(addr, val)
		return _write_u32(addr, flip(val))
	end

	return mem
end

-- simple benchmark
function memory.benchmark_implementation(mem, iter, write, stop_garbage)
	local time = require("time")

	local function measure(fn, ...)
		collectgarbage()
		if stop_garbage then
			collectgarbage("stop")
		end
		local start_garbage = collectgarbage("count")
		local start = time.monotonic()
		fn(...)
		local delta_time = time.monotonic()-start
		local delta_garbage = collectgarbage("count")-start_garbage
		collectgarbage()
		if stop_garbage then
			collectgarbage("restart")
		end
		return delta_time, tonumber(math.ceil(delta_garbage))
	end

	local mb = mem.size/1000000

	-- warmup

	local warmup_time = measure(function()
		for addr=0, mem.size-1 do
			mem.read_u8(addr)
			if write then
				mem.write_u8(addr, 0)
			end
		end
		for i=0, (mem.size/4)-1 do
			mem.read_u8(i*4)
			if write then
				mem.write_u8(i*4, 0)
			end
		end
	end)
	print(("\twarmup    %7.2fms"):format(warmup_time*1000))

	-- read-based tests

	local read_u8_time, read_u8_garbage = measure(function()
		for _=1, iter do
			for addr=0, mem.size-1 do
				mem.read_u8(addr)
			end
		end
	end)
	print(("\tread_u8   %9.2fms/iteration(%9.2f MB/s) Garbage: %d"):format((read_u8_time*1000)/iter, mb/(read_u8_time/iter), read_u8_garbage))

	local read_u32_time, read_u32_garbage = measure(function()
		for _=1, iter do
			for i=0, (mem.size/4)-1 do
				mem.read_u32(i*4)
			end
		end
	end)
	print(("\tread_u32  %9.2fms/iteration(%9.2f MB/s) Garbage: %d"):format((read_u32_time*1000)/iter, mb/(read_u32_time/iter), read_u32_garbage))

	local sum_u8_time, sum_u8_garbage = measure(function()
		local sum
		for _=1, iter do
			sum = 0
			for addr=0, mem.size-1 do
				sum = sum + mem.read_u8(addr)
			end
		end
		return sum
	end)
	print(("\tsum_u8    %9.2fms/iteration(%9.2f MB/s) Garbage: %d"):format((sum_u8_time*1000)/iter, mb/(sum_u8_time/iter), sum_u8_garbage))

	local sum_u32_time, sum_u32_garbage = measure(function()
		local sum
		for _=1, iter do
			sum = 0
			for i=0, (mem.size/4)-1 do
				sum = sum + mem.read_u32(i*4)
			end
		end
		return sum
	end)
	print(("\tsum_u32   %9.2fms/iteration(%9.2f MB/s) Garbage: %d"):format((sum_u32_time*1000)/iter, mb/(sum_u32_time/iter), sum_u32_garbage))

	-- early quit if skipping write tests
	local total = read_u8_time + read_u32_time + sum_u8_time + sum_u32_time
	if not write then
		return total/4, warmup_time
	end

	-- write-based tests

	local zero_u8_time, zero_u8_garbage = measure(function()
		for _=1, iter do
			for addr=0, mem.size-1 do
				mem.write_u8(addr, 0)
			end
		end
	end)
	print(("\tzero_u8   %9.2fms/iteration(%9.2f MB/s) Garbage: %d"):format((zero_u8_time*1000)/iter, mb/(zero_u8_time/iter), zero_u8_garbage))

	local zero_u32_time, zero_u32_garbage = measure(function()
		for _=1, iter do
			for i=0, (mem.size/4)-1 do
				mem.write_u32(i*4, 0)
			end
		end
	end)
	print(("\tzero_u32  %9.2fms/iteration(%9.2f MB/s) Garbage: %d"):format((zero_u32_time*1000)/iter, mb/(zero_u32_time/iter), zero_u32_garbage))

	local write_u8_time, write_u8_garbage = measure(function()
		for _=1, iter do
			for addr=0, mem.size-1 do
				mem.write_u8(addr, addr%256)
			end
		end
	end)
	print(("\twrite_u8  %9.2fms/iteration(%9.2f MB/s) Garbage: %d"):format((write_u8_time*1000)/iter, mb/(write_u8_time/iter), write_u8_garbage))

	local write_u32_time, write_u32_garbage = measure(function()
		for _=1, iter do
			for i=0, (mem.size/4)-1 do
				mem.write_u32(i*4, i%256)
			end
		end
	end)
	print(("\twrite_u32 %9.2fms/iteration(%9.2f MB/s) Garbage: %d"):format((write_u32_time*1000)/iter, mb/(write_u32_time/iter), write_u32_garbage))


	total = total + zero_u8_time + zero_u32_time + write_u8_time + write_u32_time
	return total/8, warmup_time
end
function memory.benchmark_all()
	local test_size = 0xA0000 -- 640K ought to be enough for anyone.
	local iter = 20
	local total = 0
	if jit then
		bitlib = require("bit")
		local ffi_mem = memory.new_ffi(test_size, bitlib)
		print("FFI")
		total = total + memory.benchmark_implementation(ffi_mem, iter, true, true, bitlib)
	end

	local table_mem = memory.new_table(test_size, bitlib)
	print("Table")
	total = total + memory.benchmark_implementation(table_mem, iter, true, true, bitlib)

	local string_data = ("\0"):rep(test_size-1)
	local string_mem = memory.new_string(string_data, bitlib)
	print("String")
	total = total + memory.benchmark_implementation(string_mem, iter, false, false, bitlib)

	print(("="):rep(80))
	print("Total", total.."s")
	print(("="):rep(80))
end


return memory
