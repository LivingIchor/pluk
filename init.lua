-- Get the pluk directory
local script_path = debug.getinfo(1).source:match("@?(.*)/")
package.path = script_path .. "/?.lua;" .. package.path

-- stdout is reserved for returning data to kakoune,
-- use `kak -p` to run kak commands from this script
-- and stderr is for the *debug* buffer
local M = {}

---@alias Pointer function

---@class Repo
---@field name string
---@field install_hook boolean
---@field setup string

local LOG_FILE = script_path .. "/pluk.log"

---@enum LogLevel
local LogLevel = {
	TRACE = 1,
	DEBUG = 2,
	INFO = 3,
	ERROR = 4,
}

local log_level = LogLevel[os.getenv("KAK_LOG_LEVEL") or "INFO"]

local client = os.getenv("kak_client")
local session = os.getenv("kak_session")

--- Send a command to be ran by kakoune
---@param command string
---@return nil
local send_command = function(command)
	local cmd_msg = string.format("eval -client %s %%{%s}", client, command)
	os.execute(string.format("kak -p %s <<EOF\n%s\nEOF", session, cmd_msg))
end

--- Log to the *debug* buffer and/or a log file based of log level
---@param level string
---@param msg string
local function log(level, msg)
	if LogLevel[level] >= log_level then
		-- Set up useful logging info
		local timestamp = os.date("%T")
		local info = debug.getinfo(2, "Sl")
		local filename = info.short_src:match("^.+/(.+)$") or info.short_src

		-- Escape anything Kakoune might not be happy about
		local safe_msg = msg:gsub("%%", "%%%%"):gsub("%{", "\\{"):gsub("%}", "\\}"):gsub(";", "\\;"):gsub("\n", ";")

		-- 1. SEND TO LOG FILE (via io.write) and SEND ERROR MESSAGE (via `kak -p`)
		-- 2 & 3. SEND TO KAKOUNE *debug* BUFFER (via stderr)
		if LogLevel[level] == LogLevel.ERROR then
			local log_fp = io.open(LOG_FILE, "a")
			if log_fp then
				log_fp:write(string.format("[%s] [ERROR] [%s:%d] %s'", timestamp, filename, info.currentline, msg))
				log_fp:close()
			end

			-- Also notify the user in the editor so they don't miss it
			send_command(string.format("echo -markup %%{ {Error}Pluk Error: %s (see log for details) }", safe_msg))
		elseif LogLevel[level] <= LogLevel.DEBUG then -- TRACE & DEBUG should include linenumber and file name
			io.stderr:write(string.format("[pluk] [%s] [%s:%d] %s", level, filename, info.currentline, safe_msg))
		else -- INFO is simply for tracking state of the program
			io.stderr:write(string.format("[pluk] [%s] %s", level, safe_msg))
		end
	end
end

--- Creates a string from a given table
---@param obj any
---@return string
local function dump(obj)
	-- Recurse through a table,
	-- returning when something can be stringified
	if type(obj) == "table" then
		-- The variable holding the stringified table
		local str = ""
		for k, v in pairs(obj) do
			-- Variable holding the stringified value of the pair
			local vstr
			if type(v) == "string" then
				vstr = "[=[" .. v .. "]=]"
			else
				vstr = dump(v)
			end

			-- Creates the key-value string
			str = str .. k .. " = " .. vstr .. ", "
		end

		if #str > 0 then
			return "{ " .. str:sub(1, -3) .. " }"
		else -- Table must be empty
			return "{}"
		end
	else
		-- Base case for the recursion
		return tostring(obj)
	end
end

--- Iterates through the lines of a string
---@param str string
---@param start_pos integer|nil
---@return function
local lines = function(str, start_pos)
	local pos = start_pos or 1
	local line_num = 0

	---@return string|nil, integer|nil, integer|nil, integer|nil
	return function()
		-- Stop if we've exhausted the string
		if pos > #str then
			return nil
		end

		line_num = line_num + 1

		-- Find next newline
		local newline_idx = str:find("\n", pos, true)

		local start_of_this_line = pos

		local line
		if newline_idx then
			line = str:sub(pos, newline_idx - 1)
			pos = newline_idx + 1
		else
			-- Last line (no trailing newline)
			line = str:sub(pos)
			pos = #str + 1
		end

		return line, line_num, start_of_this_line, pos
	end
end

--- Creates a closure that acts like a pointer you get and set a value with
---@param val any
---@return Pointer
local function create_pointer(val)
	---@return any
	return function(new_val)
		if new_val ~= nil then
			val = new_val
		end
		return val
	end
end

--- Iterates and extracts install hooks from a string
---@param config_ptr Pointer
---@param repo string
local extract_install_hooks = function(config_ptr, repo)
	local pos = 1

	--- Iterator function for install hooks in a package config
	---@return string|nil
	return function()
		if config_ptr() == nil or type(config_ptr()) ~= "string" or config_ptr() == "" or pos > #(config_ptr()) then
			return nil
		end

		-- Find the first `pluk-install-hook` and capture every none whitespace
		-- on the line before and after
		local start_index, end_index, before, after =
			config_ptr():find("[ %t\r\f\v]*(%S*)%s*pluk%-install%-hook%s*(%S*)[ %t\r\f\v]*\n", pos)

		if start_index then
			-- Install hooks only accept one `%{}` block and can't have additional text on its start and end line
			if before ~= "" or after ~= "%{" then
				send_command(string.format("fail 'Too many arguments to ''%s'' install hook'", repo))
				return ""
			end

			-- Set posision to the first line of the hook
			pos = end_index + 1

			-- Iterate over lines following the `pluk-install-hook %{`
			-- till the matching closing brace `}` is found, without
			-- any following non-white space. While iterating add to a
			-- string representing the hook's commands
			local depth = 1
			local first_command = true
			local hook_str = "pluk-install-hook %{"
			for line, _, _, next_start in lines(config_ptr(), pos) do
				local trimmed = line:match("^%s*(.-)%s*$")

				-- Skip over any comments found in the string
				if trimmed:sub(1, 1) == "#" then
					goto continue
				end
				trimmed = trimmed:sub(1, (trimmed:find("#") and trimmed:find("#") - 1 or -1))

				-- Update depth: count opening and closing braces
				-- Handles multiple braces on one line
				for _ in trimmed:gmatch("{") do
					depth = depth + 1
				end
				for _ in trimmed:gmatch("}") do
					depth = depth - 1
				end

				pos = next_start

				if depth == 0 then -- Is this the last line of the install hook
					if trimmed:find("}%s*%S+%s*$") then
						send_command(string.format("fail 'Too many arguments to ''%s'' install hook'", repo))
						return ""
					end
					hook_str = hook_str .. trimmed
					break
				else
					hook_str = hook_str .. (first_command and "" or ";") .. trimmed
					first_command = false
				end

				::continue::
			end

			if depth ~= 0 then
				send_command(string.format("fail 'Unbalanced hook braces in ''%s'' install hook block'", repo))
				return ""
			end

			-- Prepare the string with the install hook removed
			local new_str = ""
			if start_index > 1 then
				new_str = config_ptr():sub(0, start_index - 1)
			end
			new_str = new_str .. config_ptr():sub(pos, -1)
			config_ptr(new_str)

			-- Set up for subsequent calls
			pos = start_index

			-- Return the repo and its possible config
			return hook_str
		end

		-- If no match is found, returning nothing (nil) stops the loop
	end
end

---@param repo_table Repo
---@param name string
---@param config string
M.add_repo = function(repo_table, name, config)
	repo_table = repo_table == nil and {} or repo_table

	-- Must run a trigger command after an install if there's a hook
	local found_hook = false
	local config_ptr = create_pointer(config:gsub('"', "'"))

	-- Find, extract, and set post install hooks
	for hook_str in extract_install_hooks(config_ptr, name) do
		if hook_str == "" then
			return ""
		end

		-- Immediately run any hooks found
		send_command(hook_str)

		found_hook = true
	end

	---@type Repo
	local new_repo = {
		name = name,
		install_hook = found_hook,
		setup = config_ptr(),
	}
	table.insert(repo_table, new_repo)

	-- Create a string to set an option with
	local repo_str = "{\n"
	for _, t in ipairs(repo_table) do
		repo_str = repo_str .. dump(t) .. ",\n"
	end
	repo_str = repo_str .. "}"

	-- Run by the lua shell command so must print to return anything
	print(repo_str)
end

--- Provides the commands to source a plugin and require its modules, if any
---@param path string
M.get_load_commands = function(path)
	local load_cmds = {}
	local rc_path = path .. "/rc"

	-- Determine target directory (rc or root)
	local attr = os.execute('test -d "' .. rc_path .. '" >/dev/null')
	local target_dir = attr and rc_path or path

	-- Find all .kak files in that directory (non-recursive)
	local p = io.popen('find "' .. target_dir .. '" -maxdepth 1 -type f -name "*.kak" 2>/dev/null')
	if p == nil then
		return
	end

	for file in p:lines() do
		-- Check if the file uses the module system
		local f = io.open(file, "r")
		if f == nil then
			return
		end
		local content = f:read("*a")
		f:close()

		local module_name = content:match("provide%-module%s+([%w%-]+)")

		if module_name then
			-- It's a module! Source it, then require it.
			table.insert(load_cmds, string.format("source '%s'", file))
			table.insert(load_cmds, string.format("require-module %s", module_name))
		else
			-- Traditional script, just source it.
			table.insert(load_cmds, string.format("source '%s'", file))
		end
	end
	p:close()

	-- Run by the lua shell command so must print to return anything
	print(table.concat(load_cmds, "\n"))
end

--- Creates a lua table from all the pluk options in Kakoune
---@param raw_env string
local hydrate_options = function(raw_env)
	local options = {}

	for line in raw_env:gmatch("[^\r\n]+") do
		-- Remove the prefix and lowercase everything
		-- Input:  KAK_OPT_PLUK_UI_FACE=info
		-- Target: ui.face = info
		local key, value = line:match("^kak_opt_pluk_([^=]+)=(.*)")

		if key then
			key = key:lower()
			local current = options
			local parts = {}

			-- Split key by underscores for nesting (e.g., ui_face -> {ui, face})
			for part in key:gmatch("[^_]+") do
				table.insert(parts, part)
			end

			-- Build nested tables
			for i = 1, #parts - 1 do
				local part = parts[i]
				current[part] = current[part] or {}
				current = current[part]
			end

			-- Type conversion for the final value
			local final_val = value
			if value == "true" then
				final_val = true
			elseif value == "false" then
				final_val = false
			elseif tonumber(value) then
				final_val = tonumber(value)
			end

			current[parts[#parts]] = final_val
		end
	end

	return options
end

---@param repo_table Repo[]
---@param raw_env string
M.run_setup = function(repo_table, raw_env)
	-- Hydrate our options (install_dir, etc.) from the env we passed
	local options = hydrate_options(raw_env)

	local hook_trigger = ""
	for i, repo in ipairs(repo_table) do
		if repo.install_hook then
			hook_trigger = "trigger-user-hook pluk-install-index-" .. i
		end

		local repo_path = options.install.dir .. (options.install.dir:sub(-1) == "/" and "" or "/") .. repo.name
		local repo_exists = os.execute(string.format("[ -d '%s' ]", repo_path))

		if not repo_exists or repo_exists == 1 then -- Both to account for lua 5.1 and lua >5.1
			print(
				string.format(
					'eval %%sh{ git clone -q --depth 1 https://github.com/%s %s; echo "eval -client %s %%{ %s\n%s\n%s }" | kak -p "%s" }',
					repo.name,
					repo_path,
					client,
					hook_trigger,
					string.format([[$(lua -e "require('pluk').get_load_commands('%s')")]], repo_path),
					repo.setup,
					session
				)
			)
		else
			print(
				string.format(
					'eval %%sh{ echo "eval -client %s %%{ %s\n%s }" | kak -p "%s" }',
					client,
					string.format([[$(lua -e "require('pluk').get_load_commands('%s')")]], repo_path),
					repo.setup,
					session
				)
			)
		end
	end
end

return M
