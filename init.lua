-- Get the pluk directory
local script_path = debug.getinfo(1).source:match("@?(.*)/")
package.path = script_path .. "/?.lua;" .. package.path

-- stdout is reserved for returning data to kakoune,
-- use `kak -p` to run kak commands from this script
-- and stderr is for the *debug* buffer
local M = {}
local H = {}

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
H.send_command = function(command)
	local cmd_msg = string.format("eval -client %s %%{%s}", client, command)
	os.execute(string.format("kak -p %s <<EOF\n%s\nEOF", session, cmd_msg))
end

--- Log to the *debug* buffer and/or a log file based of log level
---@param level string
---@param msg string
H.log = function(level, msg)
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
			H.send_command(string.format("echo -markup %%{ {Error}Pluk Error: %s (see log for details) }", safe_msg))
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
H.dump = function(obj)
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
				vstr = H.dump(v)
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
---@param pos Pointer
---@return function
H.lines = function(str, pos)
	---@return string?, integer?
	return function()
		-- Stop if we've exhausted the string
		if pos() > #str then
			return nil
		end

		-- Find next newline
		local newline_idx = str:find("\n", pos(), true)

		local start_of_this_line = pos()

		local line
		if newline_idx then
			line = str:sub(pos(), newline_idx - 1)
			pos(newline_idx + 1)
		else
			-- Last line (no trailing newline)
			line = str:sub(pos())
			pos(#str + 1)
		end

		return line, start_of_this_line
	end
end

--- Creates a closure that acts like a pointer you get and set a value with
---@param val any
---@return Pointer
H.create_pointer = function(val)
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
H.extract_hooks = function(config_ptr, repo)
	local pos = H.create_pointer(1)

	--- Iterator function for install hooks in a package config
	---@return string?
	return function()
		if config_ptr() == nil or type(config_ptr()) ~= "string" or config_ptr() == "" or pos() > #(config_ptr()) then
			return nil
		end

		-- Find the first `pluk-install-hook` and capture every none whitespace
		-- on the line before and after
		local start_index, end_index, before, after =
			config_ptr():find("[ %t\r\f\v]*(%S*)%s*pluk%-install%-hook%s*(%S*)[ %t\r\f\v]*\n", pos())

		if start_index then
			-- Install hooks only accept one `%{}` block and can't have additional text on its start and end line
			if before ~= "" or after ~= "%{" then
				H.send_command(string.format("fail 'Too many arguments to ''%s'' install hook'", repo))
				return ""
			end

			-- Set posision to the first line of the hook
			pos(end_index + 1)

			-- Iterate over lines following the `pluk-install-hook %{`
			-- till the matching closing brace `}` is found, without
			-- any following non-white space. While iterating add to a
			-- string representing the hook's commands
			local depth = 1
			local first_command = true
			local hook_str = "pluk-install-hook %{"
			for line in H.lines(config_ptr(), pos) do
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

				if depth == 0 then -- Is this the last line of the install hook
					if trimmed:find("}%s*%S+%s*$") then
						H.send_command(string.format("fail 'Too many arguments to ''%s'' install hook'", repo))
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
				H.send_command(string.format("fail 'Unbalanced hook braces in ''%s'' install hook block'", repo))
				return ""
			end

			-- Prepare the string with the install hook removed
			local new_str = ""
			if start_index > 1 then
				new_str = config_ptr():sub(0, start_index - 1)
			end
			new_str = new_str .. config_ptr():sub(pos(), -1)
			config_ptr(new_str)

			-- Set up for subsequent calls
			pos(start_index)

			-- Return the repo and its possible config
			return hook_str
		end

		-- If no match is found, returning nothing (nil) stops the loop
	end
end

---@param repo_table Repo
---@param url string
---@param repo_path string
---@param config string
M.add_repo = function(repo_table, url, repo_path, config)
	repo_table = repo_table == nil and {} or repo_table

	-- Must run a trigger command after an install if there's a hook
	local found_hook = false
	local config_ptr = H.create_pointer(config:gsub('"', "'"))

	-- Find, extract, and set post install hooks
	for hook_str in H.extract_hooks(config_ptr, url) do
		if hook_str == "" then
			return ""
		end

		-- Immediately run any hooks found
		H.send_command(hook_str)

		found_hook = true
	end

	---@type Repo
	local new_repo = {
		url = url,
		path = repo_path,
		hook = found_hook,
		config = config_ptr(),
	}
	table.insert(repo_table, new_repo)

	-- Create a string to set an option with
	local repo_str = "{\n"
	for _, t in ipairs(repo_table) do
		repo_str = repo_str .. H.dump(t) .. ",\n"
	end
	repo_str = repo_str .. "}"

	-- Run by the lua shell command so must print to return anything
	print(repo_str)
end

--- Provides the commands to source a plugin and require its modules, if any
---@param path string
H.get_load_commands = function(path)
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
	return table.concat(load_cmds, "\n")
end

------------------------------------------------------------------------------------------

---@enum PlukOpName
local PlukOpName = {
	not_pluk = 0,

	-- Ops that can have hooks
	pluk_repo = 1,
	pluk = 2,
}

---@class PlukOp
---@field low_param integer
---@field high_param integer

---@type PlukOp[]
local PlukOps = {
	{ low_param = 2, high_param = 3 },
	{ low_param = 1, high_param = 2 },
}

---@class PlukCommand
---@field op PlukOpName
---@field [integer] string

---@alias Pointer function

---@class Repo
---@field url string
---@field path string
---@field hook boolean
---@field config string

---@param str string
---@param pos Pointer
function H.construct_params(str, pos, identity, params, count)
	if str:match("^[ %t\r\f\v]*\n", pos()) or str:match("^[ %t\r\f\v]*$", pos()) then
		if count < PlukOps[identity].low_param then
			return 2
		end
		return
	elseif count >= PlukOps[identity].high_param then
		return 2
	end

	local _, last, capture = str:find("[ %t\r\f\v]*(%S)", pos())

	local closer
	if capture == "'" or capture == '"' then
		closer = capture
		pos(last + 1)
	elseif capture == "%" then
		if str:sub(last + 1, last + 1) ~= "{" then
			return 1
		end
		closer = "}"
		pos(last + 2)
	else
		closer = "%s"
	end

	local depth = 1
	local str_len = #str
	local ch_idx = pos()
	while ch_idx <= str_len do
		local next_ch = str:sub(ch_idx + 1, ch_idx + 1)

		if next_ch == "{" then
			depth = depth + 1
		end

		if next_ch:match(closer) then
			if closer:match("['\"]") and ch_idx < str_len and str:sub(ch_idx + 2, ch_idx + 2):match(closer) then
				goto continue
			elseif closer == "}" then
				depth = depth - 1
				if depth == 0 then
					break
				end

				goto continue
			end
			break
		end

		::continue::
		ch_idx = ch_idx + 1
	end

	local new_param = str:sub(pos(), ch_idx)
	pos(ch_idx + 2)

	H.send_command("echo -debug %{ '" .. new_param .. "' }")

	count = count + 1
	(params())[count] = new_param

	return H.construct_params(str, pos, identity, params, count)
end

---@param pos Pointer
---@return (string[]|integer)?
H.get_params = function(str, pos, identity)
	if str == nil or str == "" then
		return nil
	end

	local params = H.create_pointer({})
	local err = H.construct_params(str, pos, identity, params, 0)
	if err and err ~= 0 then
		return err
	end
	return params()
end

---@param pos Pointer
---@param identity PlukOpName
---@return PlukCommand
H.extract = function(str, pos, identity)
	if str == nil or str == "" then
		return {}
	end

	-- Get the name of the pluk command
	local _, op_end, op_str = str:find("%s*(%S*)", pos())
	pos(op_end + 1)
	if PlukOpName[op_str] ~= identity then
		-- TODO: Logging
		os.exit(1)
	end

	---@type PlukCommand
	local cmd = { op = identity }

	---@type (string[]|integer)?
	local params = H.get_params(str, pos, identity)
	if type(params) == "number" then
		if params == 0 then
		elseif params == 1 then
			-- TODO: Logging: Incompatible
			os.exit(1)
		elseif params == 2 then
			-- TODO: Logging: Too few or too many arguements
			os.exit(1)
		else
			-- This should never be reached
			os.exit(1)
		end
	elseif params == nil then
		-- TODO: Logging: a problem with get_params
		os.exit(1)
	end

	---@cast params string[]
	for i, val in ipairs(params) do
		cmd[i] = val
	end

	return cmd
end

---@return PlukOpName
H.cmd_identity = function(str)
	for k, _ in pairs(PlukOpName) do
		if str:match("^%s*(%S*)") == k:gsub("_", "-") then
			return PlukOpName[k]
		end
	end

	return PlukOpName.not_pluk
end

---@param setup_str string
---@return Repo[]
H.populate_repos = function(setup_str)
	---@type Repo[]
	local repos = {}

	local repo_count = 0
	local line_ptr = H.create_pointer(1)
	local home_ptr = H.create_pointer(1)
	for line, home in H.lines(setup_str, line_ptr) do

		H.send_command("echo -debug %{ Hello }")
		local trimmed = line:match("^%s*(.-)%s*$")
		local identity = H.cmd_identity(trimmed)

		-- TODO: Comment removal

		if identity == PlukOpName.not_pluk then
			H.send_command(trimmed)
			goto continue
		end

		home_ptr(home)
		---@type PlukCommand
		local cmd = H.extract(setup_str, home_ptr, identity)
		if home_ptr() > home then
			line_ptr(home_ptr())
		end

		local url
		local path
		local config
		if cmd.op == PlukOpName.pluk then
			url = string.format("%s%s%s", os.getenv("kak_opt_pluk_git_protocol"), os.getenv("kak_opt_pluk_git_domain"), cmd[1]:sub(1,1) == '/' and cmd[1] or '/' .. cmd[1])
			path = cmd[1]
			config = cmd[2]
		elseif cmd.op == PlukOpName.pluk_repo then
			url = cmd[1]
			path = cmd[2]
			config = cmd[3]
		else -- This should never be reached
			os.exit(1)
		end

		local found_hook = false
		for hook in H.extract_hooks(H.create_pointer(config), cmd[1]) do
			if hook == "" or hook == nil then
				-- TODO: Logging
				os.exit(1)
			end

			H.send_command(hook)
			found_hook = true
		end

		---@type Repo
		local new_repo = {
			url = url,
			path = path,
			hook = found_hook,
			config = config,
		}

		repo_count = repo_count + 1
		repos[repo_count] = new_repo

		::continue::
	end

	return repos
end

---@param setup_str string
M.run_setup = function(setup_str)
	---@type Repo[]
	local repos = H.populate_repos(setup_str)

	local hook_trigger = ""
	for i, repo in ipairs(repos) do
		H.send_command("echo -debug %{ Howdy }")
		if repo.hook then
			hook_trigger = "trigger-user-hook pluk-install-index-" .. i
		end

		local install_dir = os.getenv("kak_opt_pluk_install_dir")
		if install_dir == nil then
			-- TODO: Logging
			return
		end
		local install_location = install_dir .. (install_dir:sub(-1) == "/" and "" or "/") .. repo.path
		local repo_exists = os.execute(string.format("[ -d '%s' ]", install_location))

		if not repo_exists or repo_exists == 1 then -- Both to account for lua 5.1 and lua >5.1
			os.execute(string.format("git clone -q --depth 1 %s %s", repo.url, install_location))
		end

		H.send_command(string.format("%s\n%s\n%s", hook_trigger, H.get_load_commands(install_location), repo.config))
	end
end

-- Export internals ONLY when testing
M.helper = os.getenv("PLUK_TEST") and H or nil

return M
