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

local session = os.getenv("kak_session")
local config_dir = os.getenv("kak_config")
local install_dir = os.getenv("kak_opt_pluk_install_dir")
if install_dir == nil or install_dir == "" then
	H.send_command("fail 'Aborting: pluk_install_dir unset'")
	H.log(LogLevel.ERROR, "Aborting: pluk_install_dir unset")
	return
end

--- Send a command to be ran by kakoune
---@param command string
---@return nil
H.send_command = function(command)
	local cmd_msg = string.format("eval -client client0 %%{%s}", command)
	os.execute(string.format("kak -p %s <<'EOF'\n%s\nEOF\n >/dev/null 2>&1 &", session, cmd_msg))
end

H.checked_send = function(kak_command)
	-- Create a unique temporary filename
	local tmp_flag = os.tmpname()
	os.remove(tmp_flag) -- Ensure it doesn't exist yet

	-- Build a command that only touches the file if the command succeeds
	local wrapped_cmd = string.format(
		"%s; nop %%sh{ touch %s }",
		kak_command,
		tmp_flag
	)

	-- Send it to Kakoune (Synchronously)
	H.send_command(wrapped_cmd)

	-- Check if the file exists (give Kakoune a few ms to process)
	local success = false
	for _ = 1, 20 do
		local f = io.open(tmp_flag, "r")
		if f then
			f:close()
			os.remove(tmp_flag)
			success = true
			break
		end
		os.execute("sleep 0.01")
	end

	if success then
		H.log(LogLevel.INFO, string.format("Validated '%s' as a pluk command", kak_command))
		return true
	else
		H.log(LogLevel.ERROR, string.format("'%s' failed validation as a pluk command", kak_command))
		return false
	end

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
				log_fp:write(string.format("[%s] [ERROR] [%s:%d] %s\n", timestamp, filename, info.currentline, msg))
				log_fp:close()
			end
			H.send_command(string.format("echo -debug %%{[Pluk] [ERROR] %s (see log for details)}", safe_msg))

			-- Also notify the user in the editor so they don't miss it
			H.send_command(string.format("echo -markup %%{ {Error}Pluk Error: %s (see log for details) }", safe_msg))
		elseif level <= LogLevel.DEBUG then -- TRACE & DEBUG should include linenumber and file name
			H.send_command(string.format("echo -debug %%{[pluk] [%s] [%s:%d] %s}", LogLevel[level], filename, info.currentline, safe_msg))
		else -- INFO is simply for tracking state of the program
			H.send_command(string.format("echo -debug %%{[pluk] [%s] %s}", LogLevel[level], safe_msg))
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
	pluk_colorscheme = 3,
	[3] = "pluk_colorscheme",
}

---@class PlukOp
---@field low_param integer
---@field high_param integer

---@type PlukOp[]
local PlukOps = {
	{ low_param = 2, high_param = 4 },
	{ low_param = 1, high_param = 3 },
	{ low_param = 2, high_param = 3 },
}

---@class PlukCommand
---@field op PlukOpName
---@field has_config boolean
---@field [integer] string

---@class Repo
---@field url string
---@field path string
---@field config string
---@field configurer function

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

local get_min_indent = function(text)
	local min = math.huge
	-- Look for a newline followed by any number of spaces or tabs
	-- Skip purely empty lines to avoid getting a "0" result incorrectly
	for indent in text:gmatch("\n([ \t]+)%S") do
		min = math.min(min, #indent)
	end

	-- If no indentation was found, or text is one line, return 0
	return min == math.huge and 0 or min
end

H.unindent = function(text)
	local n = get_min_indent(text)
	if n == 0 then return text end

	-- Construct a pattern for exactly 'n' spaces/tabs
	local pattern = "\n" .. ("[ \t]"):rep(n)
	return (text:gsub(pattern, "\n"))
end

--- Returnes an iterator over the files matching a pattern in a directory (non-recursive)
---@param target_dir string
---@param pattern string
---@return function?
H.matching_files = function(target_dir, pattern)
	H.log(LogLevel.TRACE, "Finding all files in '" .. target_dir .. "' matching '" .. pattern .. "'")
	local p = io.popen('find "' .. target_dir .. '" -maxdepth 1 -type f -name "' .. pattern .. '" 2>/dev/null')
	if p == nil then
		H.log(LogLevel.ERROR, string.format("Failed to find anything in '%s'", target_dir))
		return nil
	end

	---@return string?
	return function()
		local file = p:read("*l")
		if file then
			return file
		end
		-- EOF reached
		p:close()
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

	-- Find all .kak files in target directory (non-recursive)
	for file in H.matching_files(target_dir, "*.kak") do
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

		-- Find the first `pluk-hook` and capture every none whitespace
		-- on the line before and after
		local start_index, end_index, before, after =
			config_ptr():find("[ %t\r\f\v]*(%S*)%s*pluk%-hook%s*(%S*)[ %t\r\f\v]*\n", pos())
		H.log(LogLevel.DEBUG, string.format("Before: '%s',\tAfter: '$s'", before, after))

		if start_index then
			-- Install hooks only accept one `%{}` block and can't have additional text on its start and end line
			if before ~= "" or after ~= "%{" then
				H.send_command(string.format("fail 'Too many arguments to ''%s'' hook'", repo))
				H.log(LogLevel.ERROR, string.format("Too many arguments to '%s' hook", repo))
				os.exit(1)
			end

			-- Set posision to the first line of the hook
			pos(end_index + 1)

			-- Iterate over lines following the `pluk-hook %{`
			-- till the matching closing brace `}` is found, without
			-- any following non-white space. While iterating add to a
			-- string representing the hook's commands
			local depth = 1
			local first_command = true
			local hook_str = ""
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
						H.send_command(string.format("fail 'Too many arguments to ''%s'' hook'", repo))
						H.log(LogLevel.ERROR, string.format("Too many arguments to '%s' hook", repo))
						os.exit(1)
					end
					if #trimmed > 1 then
						hook_str = hook_str .. trimmed:sub(1, -2)
					end
					break
				else
					hook_str = hook_str .. (first_command and "" or "\n") .. trimmed
					first_command = false
				end

				::continue::
			end

			if depth ~= 0 then
				H.send_command(string.format("fail 'Unbalanced hook braces in ''%s'' hook block'", repo))
				H.log(LogLevel.ERROR, string.format("Unbalanced hook braces in '%s' hook block", repo))
				os.exit(1)
			end

			-- Prepare the string with the install hook removed
			local new_str = ""
			if start_index > 1 then
				new_str = config_ptr():sub(0, start_index - 1)
			end
			new_str = new_str .. config_ptr():sub(pos(), -1)
			config_ptr(new_str)

			H.log(LogLevel.DEBUG, ("Hook extracted:\n" .. hook_str):gsub("\n", "\n >\t"))
			H.log(LogLevel.DEBUG, "New string without extracted hook:" .. H.unindent(new_str):gsub("\n", "\n >\t"))

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
		suffix = "rd"
	end

	return tostring(int) .. suffix
end

--- Recursive function that builds a table of the parameters passed to a pluk command
---@param str string
---@param pos Pointer
---@param cmd PlukCommand
H.construct_params = function(str, pos, cmd, count)
	if str:match("^[ %t\r\f\v]*\n", pos()) or str:match("^[ %t\r\f\v]*$", pos()) then
		if count < PlukOps[cmd.op].low_param then
			H.send_command(string.format("fail 'Too few arguments to %s'", PlukOpName[cmd.op]:gsub("_","-")))
			H.log(LogLevel.ERROR, string.format("Too few arguments to %s", PlukOpName[cmd.op]:gsub("_","-")))
			os.exit(1)
		end
		return
	elseif count >= PlukOps[cmd.op].high_param then
		H.send_command(string.format("fail 'Too many arguments to %s'", PlukOpName[cmd.op]:gsub("_","-")))
		H.log(LogLevel.ERROR, string.format("Too many arguments to %s", PlukOpName[cmd.op]:gsub("_","-")))
		os.exit(1)
	end

	local _, last, capture = str:find("[ %t\r\f\v]*(%S)", pos())

	local closer
	if capture == "'" or capture == '"' then
		closer = capture
		pos(last + 1)
	elseif capture == "%" then
		if str:sub(last + 1, last + 1) ~= "{" then
			H.send_command(string.format("fail '%s only accepts %{} blocks'", PlukOpName[cmd.op]:gsub("_","-")))
			H.log(LogLevel.ERROR, string.format("%s only accepts %{} blocks", PlukOpName[cmd.op]:gsub("_","-")))
			os.exit(1)
		end
		closer = "}"
		pos(last + 2)

		cmd.has_config = true
	else
		closer = "%s"
		pos(last)
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
	cmd[count] = new_param
	H.log(LogLevel.DEBUG, (string.format("Found %s parameter:\n%s", H.ordinal(count), H.unindent(new_param)):gsub("\n","\n >\t")))

	return H.construct_params(str, pos, cmd, count)
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
	if PlukOpName[op_str:gsub("-","_")] ~= identity then
		H.send_command(string.format("fail 'Found command ''%s'', doesn''t match expected ''%s'''", PlukOpName[op_str], PlukOpName[identity]:gsub("_","-")))
		H.log(LogLevel.ERROR, string.format("Found command '%s', doesn't match expected '%s'", PlukOpName[op_str], PlukOpName[identity]:gsub("_","-")))
		os.exit(1)
	end

	---@type PlukCommand
	local cmd = { op = identity, has_config = false }

	---@type string[]
	H.construct_params(str, pos, cmd, 0)

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

		-- Comment removal
		if #trimmed == 0 or trimmed:sub(1,1) == '#' then
			goto continue
		end

		local hashpos = trimmed:find('#')
		if hashpos then
			trimmed = trimmed:sub(1, hashpos - 1)
		end

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

		local virt_cmd = PlukOpName[cmd.op]:gsub("_","-") .. " " .. table.concat(cmd, " ", 1, (cmd.has_config and #cmd - 1 or #cmd))
		if not H.checked_send(virt_cmd) then
			os.exit(1)
		end
		local flag_count = (cmd.has_config and #cmd - 1 or #cmd) - PlukOps[cmd.op].low_param

		local url
		local path
		local config
		local configurer = function(repo) -- Default configurer. Sources/requires plugin then runs config
			local install_location = install_dir .. (install_dir:sub(-1) == "/" and "" or "/") .. repo.path
			local ok, load_cmds = H.get_load_commands(install_location)
			if ok then
				local complete = string.format("\n%s\n%s", load_cmds, repo.config and repo.config or "")
				H.log(LogLevel.DEBUG, string.format("Finished config:%s", complete:gsub("\n","\n >\t")))
				H.send_command(complete)
			end
		end
		if cmd.op == PlukOpName.pluk then
			url = string.format("%s%s%s", os.getenv("kak_opt_pluk_git_protocol"), os.getenv("kak_opt_pluk_git_domain"), cmd[1]:sub(1,1) == '/' and cmd[1] or '/' .. cmd[1 + flag_count])
			path = cmd[1 + flag_count]
			config = H.create_pointer(cmd[2 + flag_count])

			for flag_idx = 1, flag_count do
				local flag = cmd[flag_idx]
				if flag == "-auto-source" then
				elseif flag == "-no-source" then
					configurer = function(repo)
						local complete = string.format("\n%s", repo.config and repo.config or "")
						H.log(LogLevel.DEBUG, string.format("Finished config:%s", complete:gsub("\n","\n >\t")))
						H.send_command(complete)
					end
				else
					H.log(LogLevel.ERROR, string.format("pluk doesn't accept '%s' as a flag", flag))
					os.exit(1)
				end
			end
		elseif cmd.op == PlukOpName.pluk_repo then
			url = cmd[1 + flag_count]
			path = cmd[2 + flag_count]
			config = H.create_pointer(cmd[3 + flag_count])

			for flag_idx = 1, flag_count do
				local flag = cmd[flag_idx]
				if flag == "-auto-source" then
				elseif flag == "-no-source" then
					configurer = function(repo)
						local complete = string.format("\n%s", repo.config and repo.config or "")
						H.log(LogLevel.DEBUG, string.format("Finished config:%s", complete:gsub("\n","\n >\t")))
						H.send_command(complete)
					end
				else
					H.log(LogLevel.ERROR, string.format("pluk doesn't accept '%s' as a flag", flag))
					os.exit(1)
				end
			end
		elseif cmd.op == PlukOpName.pluk_colorscheme then
			if flag_count > 0 then
				H.log(LogLevel.ERROR, "pluk-colorscheme can't take any flags")
				os.exit(1)
			end

			url = string.format("%s%s%s", os.getenv("kak_opt_pluk_git_protocol"), os.getenv("kak_opt_pluk_git_domain"), cmd[1]:sub(1,1) == '/' and cmd[1] or '/' .. cmd[1])
			path = cmd[1]
			config = H.create_pointer(cmd[3])
			configurer = function(repo)
				local install_location = install_dir .. (install_dir:sub(-1) == "/" and "" or "/") .. repo.path
				local target_dir

				H.log(LogLevel.TRACE, "Testing for '" .. install_location .. "/colors'")
				local attr = os.execute('test -d "' .. install_location .. '/colors" >/dev/null')
				if attr then
					target_dir = install_location .. "/colors"
				else
					H.log(LogLevel.ERROR, "'" .. install_location .. "/colors' not found")
					H.send_command("fail '''" .. install_location .. "/colors'' not found'")
					os.exit(1)
				end

				local colorscheme
				for file in H.matching_files(target_dir, "*.kak") do
					H.log(LogLevel.INFO, "file: " .. file:sub(#target_dir + 2, -5))
					if file:sub(#target_dir + 2, -5) == cmd[2] then
						colorscheme = cmd[2]
					end
				end

				if not colorscheme then
					H.log(LogLevel.ERROR, string.format("No colorscheme '%s' found in '%s'", cmd[2], target_dir))
					H.send_command(string.format("fail 'No colorscheme ''%s'' found in ''%s'''", cmd[2], target_dir))
					os.exit(1)
				end

				-- Symlink the colorscheme into root colors
				local link_src = target_dir .. '/' .. colorscheme .. ".kak"
				os.execute("mkdir -p " .. config_dir .. "/colors")
				H.log(LogLevel.TRACE, "Testing for '" .. config_dir .. "/colors/" .. colorscheme .. ".kak")
				local attr2 = os.execute('test -f "' .. config_dir .. "/colors/" .. colorscheme .. '.kak" >/dev/null')
				if not attr2 then
					H.log(LogLevel.TRACE, ("Linking with: ln -s %s %s"):format(link_src, config_dir .. "/colors/" .. colorscheme .. ".kak"))
					os.execute(("ln -s %s %s"):format(link_src, config_dir .. "/colors/" .. colorscheme .. ".kak"))
				end

				local complete = string.format("\ncolorscheme %s\n%s", colorscheme, repo.config and repo.config or "")
				H.log(LogLevel.DEBUG, string.format("Finished config:%s", complete:gsub("\n","\n >\t")))
				H.send_command(complete)
			end
		else -- This should never be reached
			os.exit(1)
		end

		-- Get out and run all the hooks in config
		local found_hook = false
		for hook in H.extract_hooks(config, cmd[1 + flag_count]) do
			-- hook <scope> User <hook_name> <commands>
			H.send_command(string.format("hook global User pluk-hook-index-%d %%{eval %%sh{cd %s;%s}}", repo_count, install_dir .. "/" .. path, hook))

			found_hook = true
		end
		if found_hook then
			config(string.format("trigger-user-hook pluk-hook-index-%d\n%s", repo_count, config()))
		end

		---@type Repo
		local new_repo = {
			url = url,
			path = path,
			config = (config() ~= nil) and H.unindent(config()) or "",
			configurer = configurer,
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

	for _, repo in ipairs(repos) do
		local install_location = install_dir .. (install_dir:sub(-1) == "/" and "" or "/") .. repo.path
		local repo_exists = os.execute(string.format("[ -d '%s' ]", install_location))

		if not repo_exists or repo_exists == 1 then -- Both to account for lua 5.1 and lua >5.1
			os.execute(string.format("git clone -q --depth 1 %s %s", repo.url, install_location))
		end

		repo:configurer()
	end
end

-- Export internals ONLY when testing
M.helper = os.getenv("PLUK_TEST") and H or nil

return M
