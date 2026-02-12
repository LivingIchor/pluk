-- Get the pluk directory
local script_path = debug.getinfo(1).source:match("@?(.*)/")
package.path = script_path .. "/?.lua;" .. package.path

local M = {}

-- Level mapping: TRACE=1, DEBUG=2, INFO=3, ERROR=4
local CURRENT_LEVEL = 2

local function log(level, msg)
	local levels = { TRACE = 1, DEBUG = 2, INFO = 3, ERROR = 4 }
	local current_setting = levels[os.getenv("KAK_LOG_LEVEL") or "INFO"]

	if levels[level] >= current_setting then
		local timestamp = os.date("%T")

		-- 1. SEND TO LOG FILE (via stderr)
		-- 2. SEND TO KAKOUNE *debug* BUFFER (via stdout)
		if level == "ERROR" then
			io.stderr:write(string.format("[%s] [ERROR] %s\n", timestamp, msg))

			-- Also notify the user in the editor so they don't miss it
			print(string.format("echo -markup '{Error}Pluk Error: %s (see log for details)'", msg:gsub("'", "''")))
		elseif levels[level] <= levels["DEBUG"] then
			local info = debug.getinfo(2, "Sl")
			local filename = info.short_src:match("^.+/(.+)$") or info.short_src

			print(
				string.format(
					"echo -debug '[pluk] [%s] [%s:%d] %s'",
					level,
					filename,
					info.currentline,
					msg:gsub("'", "''")
				)
			)
		else
			print(string.format("echo -debug '[pluk] [%s] %s'", level, msg:gsub("'", "''")))
		end
	end
end

local get_load_commands = function(path)
	local load_cmds = {}
	local rc_path = path .. "/rc"

	-- Determine target directory (rc or root)
	local attr = os.execute('test -d "' .. rc_path .. '" >/dev/null')
	local target_dir = attr and rc_path or path

	print("echo -debug %{Path: " .. target_dir .. "}")
	-- Find all .kak files in that directory (non-recursive)
	local p = io.popen('find "' .. target_dir .. '" -maxdepth 1 -type f -name "*.kak"')
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

	return table.concat(load_cmds, "\n")
end

local undent = function(str)
	-- Find the indentation of the first line
	local margin = str:match("^%s*")
	-- Remove that margin from the start of every line
	return str:gsub("\n" .. margin, "\n"):gsub("^" .. margin, "")
end

M.post_install = function(repo, path, config, session)
	print("echo -debug %{", repo, path, config, "}")
	local post_str = string.format(
		undent([[
		evaluate-commands -client %%{%s} %%{
			%s

			%s

			%s
		}]]),
		os.getenv("kak_client") or "client0",
		get_load_commands(path),
		config == "" and "" or "evaluate-commands " .. config,
		string.format("echo -markup '{yellow}Installing %s in background...Finished'", repo)
	)

	os.execute(string.format("echo '%s' | kak -p %s", post_str:gsub("'", "'\\''"), session))
	print(string.format("echo -debug %%{%s}", post_str))

	print("echo -debug %{ Test: " .. repo .. " }")
end

local function install_background(repo, path, config, session)
	-- This is the "fire and forget" background process
	local shell_cmd = string.format(
		"([ ! -d '%s' ] && git clone --depth 1 https://github.com/%s %s; "
			.. "lua -e \"require('pluk').post_install( [=[%s]=], [=[%s]=], [=[%s]=], [=[%s]=])\") &",
		path,
		repo,
		path,
		repo,
		path,
		config,
		session
	)

	-- Execute in background
	os.execute(shell_cmd)

	-- Print an immediate message so the user knows something is happening
	print(string.format("echo -markup '{yellow}Installing %s in background...'", repo))
end

local line_indexer = function(str, start_pos)
	local line_num = 1
	local current_pos = start_pos

	return function()
		-- If we've passed the end of the string, stop
		if current_pos > #str then
			return nil
		end

		line_num = line_num + 1

		-- Find the next newline character starting from current_pos
		local start_idx, end_idx = str:find("\n", current_pos)

		local line
		local start_of_this_line = current_pos

		if start_idx then
			-- Grab text from current position to right before the newline
			line = str:sub(current_pos, start_idx - 1)
			-- Move the pointer past the newline for the next iteration
			current_pos = end_idx + 1
		else
			-- No more newlines; grab the remaining text
			line = str:sub(current_pos)
			current_pos = #str + 1
		end

		local start_of_next_line = current_pos

		return line, line_num, start_of_this_line, start_of_next_line
	end
end

local get_repo = function(input_str)
	local pos = 1 -- This is our state

	-- The actual iterator function
	return function()
		local config_tbl = {}
		local repo_pat = "[\"']([%w%-_%.]+/[%w%-_%.]+)[\"']"

		-- Grab the first line with repo `"user/repo"`
		local start_index, end_index, repo = input_str:find(repo_pat, pos)

		if start_index then
			-- Update the position for the NEXT call
			pos = end_index + 1

			local depth = 0
			for line, line_num, _, next_start in line_indexer(input_str, pos) do
				local trimmed = line:match("^%s*(.-)%s*$")

				if line_num == 1 and trimmed:sub(1, 2) ~= "%{" then
					break
				end

				-- Update depth: count opening and closing braces
				-- We use gmatch to handle multiple braces on one line
				for _ in trimmed:gmatch("{") do
					depth = depth + 1
				end
				for _ in trimmed:gmatch("}") do
					depth = depth - 1
				end

				pos = next_start

				table.insert(config_tbl, trimmed)

				if depth == 0 then
					break
				end
			end

			if depth ~= 0 then
				print(string.format("fail 'Unbalanced braces in '%s' config block'", repo))
				return
			end

			-- Return the repo and its possible config
			return repo, table.concat(config_tbl, "\n")
		end

		-- If no match is found, returning nothing (nil) stops the loop
	end
end

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

M.parse_setup = function(block, raw_env, session)
	-- Hydrate our options (install_dir, etc.) from the env we passed
	local options = hydrate_options(raw_env)

	for repo, config in get_repo(block) do
		local path = options.install.dir .. "/" .. repo

		-- Queue for background installation
		install_background(repo, path, config, session)
	end
end

return M
