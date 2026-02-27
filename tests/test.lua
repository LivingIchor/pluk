-- Look for .lua files in the parent directory
package.path = package.path .. ";../?.lua"

-- Set the environment flag so internals are exposed
os.execute("export PLUK_TEST=true")
local pluk = require("pluk")
local h = pluk.helper

local function test(name, fn)
	-- ANSI Escape Codes
	local RED = "\27[31m"
	local GREEN = "\27[32m"
	local RESET = "\27[0m"

	local ok, err = pcall(fn)

	if ok then
		print(GREEN .. " [PASS] " .. RESET .. name)
	else
		print(RED .. " [FAIL] " .. name)
		print("\n\t-> " .. err .. RESET)
	end
end

-- TDD: We can test the small piece in isolation! (But not too strictly)
