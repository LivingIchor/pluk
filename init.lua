-- Get the pluk directory
local script_path = debug.getinfo(1).source:match("@?(.*)/")
package.path = script_path .. "/?.lua;" .. package.path

local M = {}
local H = {}

local LOG_FILE = script_path .. "/pluk.log"

---@enum LogLevel
local LogLevel = {
	TRACE = 1,
	[1] = "TRACE",
	DEBUG = 2,
	[2] = "DEBUG",
	INFO = 3,
	[3] = "INFO",
	ERROR = 4,
	[4] = "ERROR",
}

local log_level = LogLevel[os.getenv("kak_opt_pluk_loglevel") or "INFO"]

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
---@param level LogLevel
---@param msg string
---@return nil
H.log = function(level, msg)
	if level >= log_level then
		-- Set up useful logging info
		local timestamp = os.date("%T")
		local info = debug.getinfo(2, "Sl")
		local filename = info.short_src:match("^.+/(.+)$") or info.short_src

		-- Escape anything Kakoune might not be happy about
		local safe_msg = msg --:gsub("%%", "%%%%"):gsub("%{", "\\{"):gsub("%}", "\\}"):gsub(";", "\\;"):gsub("\n", ";")

		-- 1. SEND TO LOG FILE (via io.write) and SEND ERROR MESSAGE (via `kak -p`)
		-- 2 & 3. SEND TO KAKOUNE *debug* BUFFER (via stderr)
		if level == LogLevel.ERROR then
			local log_fp = io.open(LOG_FILE, "a")
			if log_fp then
				log_fp:write(string.format("[%s] [ERROR] [%s:%d] %s'", timestamp, filename, info.currentline, msg))
				log_fp:close()
			end

			-- Also notify the user in the editor so they don't miss it
			H.send_command(string.format("echo -markup %%{ {Error}Pluk Error: %s (see log for details) }", safe_msg))
		elseif level <= LogLevel.DEBUG then -- TRACE & DEBUG should include linenumber and file name
			io.stderr:write(string.format("[pluk] [%s] [%s:%d] %s\n", LogLevel[level], filename, info.currentline, safe_msg))
		else -- INFO is simply for tracking state of the program
			io.stderr:write(string.format("[pluk] [%s] %s\n", LogLevel[level], safe_msg))
		end
	end
end

---@enum PlukError
local PlukError = {
	NonzeroExecute = 1,
	OpenFailed = 2,
}

---@enum PlukOpName
local PlukOpName = {
	not_pluk = 0,
	[0] = "not_pluk",

	-- Ops that can have hooks
	pluk_repo = 1,
	[1] = "pluk_repo",
	pluk = 2,
	[2] = "pluk",
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

---@class Repo
---@field url string
---@field path string
---@field hook boolean
---@field config string

---@alias Pointer function

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

--- Provides the commands to source a plugin and require its modules, if any
---@param path string
---@return boolean, string|PlukError
H.get_load_commands = function(path)
	H.log(LogLevel.INFO, string.format("Getting the load commands from the plugin in '%s'", path))

	local load_cmds = {}
	local rc_path = path .. "/rc"

	-- Determine target directory (rc or root)
	H.log(LogLevel.TRACE, "Testing for '" .. rc_path .. "'")
	local attr = os.execute('test -d "' .. rc_path .. '" >/dev/null')
	local target_dir = attr and rc_path or path

	-- Find all .kak files in that directory (non-recursive)
	H.log(LogLevel.TRACE, "Finding all files in '" .. target_dir .. "'")
	local p = io.popen('find "' .. target_dir .. '" -maxdepth 1 -type f -name "*.kak" 2>/dev/null')
	if p == nil then
		H.log(LogLevel.ERROR, string.format("Failed to find anything in '%s'", target_dir))
		return false, PlukError.NonzeroExecute
	end

	H.log(LogLevel.TRACE, "Iterating over files found")
	for file in p:lines() do
		-- Check if the file uses the module system
		H.log(LogLevel.TRACE, "Opening '" .. file .. "'")
		local f = io.open(file, "r")
		if f == nil then
			H.log(LogLevel.ERROR, string.format("Failed to open '%s'", file))
			return false, PlukError.OpenFailed
		end
		local content = f:read("*a")
		f:close()

		local module_name = content:match("provide%-module%s+([%w%-]+)")

		if module_name ~= nil then
			-- It's a module! Source it, then require it.
			table.insert(load_cmds, string.format("source '%s'", file))
			table.insert(load_cmds, string.format("require-module %s", module_name))
		else
			-- Traditional script, just source it.
			table.insert(load_cmds, string.format("source '%s'", file))
		end
	end
	p:close()

	H.log(LogLevel.INFO, "Got load commands")
	H.log(LogLevel.DEBUG, "Load command contents: " .. table.concat(load_cmds, ", "))
	return true, table.concat(load_cmds, "\n")
end

--- Iterates and extracts install hooks from a string
---@param config_ptr Pointer
---@param repo string
H.extract_hooks = function(config_ptr, repo)
	H.log(LogLevel.INFO, string.format("Extracting hooks from '%s' config string", repo))
	local pos = H.create_pointer(1)
	local iter = 1

	--- Iterator function for install hooks in a package config
	---@return string?
	return function()
		H.log(LogLevel.TRACE, "Iteration: " .. tostring(iter))
		if config_ptr() == nil or type(config_ptr()) ~= "string" or config_ptr() == "" or pos() > #(config_ptr()) then
			return
		end

		-- Find the first `pluk-install-hook` and capture every none whitespace
		-- on the line before and after
		local start_index, end_index, before, after =
			config_ptr():find("[ %t\r\f\v]*(%S*)%s*pluk%-install%-hook%s*(%S*)[ %t\r\f\v]*\n", pos())
		H.log(LogLevel.DEBUG, string.format("Before: '%s',\tAfter: '$s'", before, after))

		if start_index then
			-- Install hooks only accept one `%{}` block and can't have additional text on its start and end line
			if before ~= "" or after ~= "%{" then
				H.send_command(string.format("fail 'Too many arguments to ''%s'' install hook'", repo))
				H.log(LogLevel.ERROR, string.format("Too many arguments to '%s' install hook", repo))
				os.exit(1)
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
						H.log(LogLevel.ERROR, string.format("Too many arguments to '%s' install hook", repo))
						os.exit(1)
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
				H.log(LogLevel.ERROR, string.format("Unbalanced hook braces in '%s' install hook block", repo))
				os.exit(1)
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

			H.log(LogLevel.DEBUG, "Hook extracted:" .. hook_str:gsub("\n", "\n >\t"))
			H.log(LogLevel.DEBUG, "New string with hook extracted:" .. new_str:gsub("\n", "\n >\t"))

			-- Return the repo and its possible config
			return hook_str
		end

		H.log(LogLevel.INFO, "Hook extraction completed")
		-- If no match is found, returning nothing (nil) stops the loop
	end
end

--- Gives the string of a numbers ordinal, 1 -> "1st"
---@param int integer
---@return string
H.ordinal = function(int)
	local suffix = "th"
	local degree = int % 10
	if degree == 1 then
		suffix = "st"
	elseif degree == 2 then
		suffix = "nd"
	elseif degree == 3 then
		suffix "rd"
	end

	return tostring(int) .. suffix
end

--- Recursive function that builds a table of the parameters passed to a pluk command
---@param str string
---@param pos Pointer
---@return table
H.construct_params = function(str, pos, identity, params, count)
	if str:match("^[ %t\r\f\v]*\n", pos()) or str:match("^[ %t\r\f\v]*$", pos()) then
		if count < PlukOps[identity].low_param then
			H.send_command(string.format("fail 'Too few arguments to %s'", PlukOpName[identity]:gsub("_","-")))
			H.log(LogLevel.ERROR, string.format("Too few arguments to %s", PlukOpName[identity]:gsub("_","-")))
			os.exit(1)
		end
		return params
	elseif count >= PlukOps[identity].high_param then
		H.send_command(string.format("fail 'Too many arguments to %s'", PlukOpName[identity]:gsub("_","-")))
		H.log(LogLevel.ERROR, string.format("Too many arguments to %s", PlukOpName[identity]:gsub("_","-")))
		os.exit(1)
	end

	local _, last, capture = str:find("[ %t\r\f\v]*(%S)", pos())

	local closer
	if capture == "'" or capture == '"' then
		closer = capture
		pos(last + 1)
	elseif capture == "%" then
		if str:sub(last + 1, last + 1) ~= "{" then
			H.send_command(string.format("fail '%s only accepts %{} blocks'", PlukOpName[identity]:gsub("_","-")))
			H.log(LogLevel.ERROR, string.format("%s only accepts %{} blocks", PlukOpName[identity]:gsub("_","-")))
			os.exit(1)
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

	count = count + 1
	params[count] = new_param
	H.log(LogLevel.DEBUG, string.format("Found %s parameter:%s", H.ordinal(count), new_param:gsub("\n","\n >\t")))

	return H.construct_params(str, pos, identity, params, count)
end

--- Assemble a string of the pluk option in the provided string, starting at the given position
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
		H.send_command(string.format("fail 'Found command ''%s'', doesn''t match expected ''%s'''", PlukOpName[op_str], PlukOpName[identity]:gsub("_","-")))
		H.log(LogLevel.ERROR, string.format("Found command '%s', doesn't match expected '%s'", PlukOpName[op_str], PlukOpName[identity]:gsub("_","-")))
		os.exit(1)
	end

	---@type PlukCommand
	local cmd = { op = identity }

	---@type string[]
	local params = H.construct_params(str, pos, identity, {}, 0)
	for i, val in ipairs(params) do
		cmd[i] = val
	end

	return cmd
end

---@return PlukOpName
H.cmd_identity = function(str)
	for k, _ in pairs(PlukOpName) do
		if type(k) == "number" then
		elseif str:match("^%s*(%S*)") == k:gsub("_", "-") then
			return PlukOpName[k]
		end
	end

	return PlukOpName.not_pluk
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

---@param setup_str string
---@return Repo[]
H.populate_repos = function(setup_str)
	---@type Repo[]
	local repos = {}

	local repo_count = 0
	local line_ptr = H.create_pointer(1)
	local home_ptr = H.create_pointer(1)
	for line, home in H.lines(setup_str, line_ptr) do
		local trimmed = line:match("^%s*(.-)%s*$")
		local identity = H.cmd_identity(trimmed)

		-- TODO: Comment removal

		if identity == PlukOpName.not_pluk then
			H.send_command(trimmed)
			goto continue
		end

		home_ptr(home)
		H.log(LogLevel.INFO, string.format("Trying to extract '%s'", PlukOpName[identity]:gsub("_","-")))
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

		-- Get out and run all the hooks in config
		local found_hook = false
		for hook in H.extract_hooks(H.create_pointer(config), cmd[1]) do
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
	local install_dir = os.getenv("kak_opt_pluk_install_dir")
	if install_dir == nil or install_dir == "" then
		H.send_command("fail 'Aborting: pluk_install_dir unset'")
		H.log(LogLevel.ERROR, "Aborting: pluk_install_dir unset")
		return
	end

	---@type Repo[]
	local repos = H.populate_repos(setup_str)

	local hook_trigger = ""
	for i, repo in ipairs(repos) do
		if repo.hook then
			hook_trigger = "trigger-user-hook pluk-install-index-" .. i
		end

		local install_location = install_dir .. (install_dir:sub(-1) == "/" and "" or "/") .. repo.path
		local repo_exists = os.execute(string.format("[ -d '%s' ]", install_location))

		if not repo_exists or repo_exists == 1 then -- Both to account for lua 5.1 and lua >5.1
			os.execute(string.format("git clone -q --depth 1 %s %s", repo.url, install_location))
		end

		local ok, load_cmds = H.get_load_commands(install_location)
		if ok then
			H.send_command(string.format("%s\n%s\n%s", hook_trigger, load_cmds, repo.config and repo.config or ""))
		end
	end
end

-- Export internals ONLY when testing
M.helper = os.getenv("PLUK_TEST") and H or nil

return M
