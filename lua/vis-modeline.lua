-- Modeline: a lualine-style status line built from styled segments.
--
--   modeline = require('vis-modeline')
--
-- Left: mode block, git branch, file name with modified flag, LSP
-- diagnostic counts. Right: pending keys or count, selection index, LSP
-- server name, syntax, percentage, line:col. Only the focused window
-- shows the mode block. Colors come from `modeline.colors`, read when a
-- style is first used, so set them in visrc before the first redraw.
-- `modeline.enabled = false` hands the status line back to the default.
require('vis')

local modeline = {}
modeline.enabled = true

-- Style strings. Attributes replace the status style's, so a colored
-- segment sets both `fore` and `back`; plain text keeps the status style.
modeline.colors = {
	normal   = "fore:black,back:blue,bold",
	insert   = "fore:black,back:green,bold",
	visual   = "fore:black,back:magenta,bold",
	replace  = "fore:black,back:red,bold",
	modified = "fore:black,back:yellow",
	branch   = "fore:black,back:cyan",
	error    = "fore:black,back:red",
	warn     = "fore:black,back:yellow",
	info     = "fore:black,back:cyan",
	hint     = "fore:black,back:blue",
	lsp      = "fore:black,back:green",
}

-- Nerd-font glyphs are plain UTF-8; replace with ASCII if the font lacks them.
modeline.symbols = {
	branch   = "\u{e0a0} ",
	modified = " [+]",
	readonly = " [RO]",
	error    = "\u{f057} ",
	warn     = "\u{f071} ",
	info     = "\u{f05a} ",
	hint     = "\u{f0eb} ",
	lsp      = "\u{f085} ",
}

-- seconds between re-reads of .git/HEAD
modeline.git_refresh = 2

-- the vis-lspc module when loaded; found in package.loaded when nil
modeline.lspc = nil

local modes = {
	[vis.modes.NORMAL]           = { "NORMAL",  "normal"  },
	[vis.modes.OPERATOR_PENDING] = { "PENDING", "normal"  },
	[vis.modes.VISUAL]           = { "VISUAL",  "visual"  },
	[vis.modes.VISUAL_LINE]      = { "V-LINE",  "visual"  },
	[vis.modes.INSERT]           = { "INSERT",  "insert"  },
	[vis.modes.REPLACE]          = { "REPLACE", "replace" },
}

local styles = {}
local function style(name)
	local id = styles[name]
	if not id then
		id = vis.ui:style_push(modeline.colors[name] or "")
		styles[name] = id
	end
	return id
end

-- git branch, read from .git/HEAD and cached per directory

local function read_line(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local line = f:read("*l")
	f:close()
	return line
end

local function parent(dir)
	local up = dir:match("^(.*)/[^/]*$")
	if up == "" then up = "/" end
	return up
end

local function find_git_dir(dir)
	while dir do
		local dotgit = dir .. "/.git"
		if read_line(dotgit .. "/HEAD") then return dotgit end
		-- worktree or submodule: .git is a file naming the real directory
		local link = (read_line(dotgit) or ""):match("^gitdir:%s*(.+)$")
		if link then
			if link:sub(1, 1) ~= "/" then link = dir .. "/" .. link end
			return link
		end
		if dir == "/" then return nil end
		dir = parent(dir)
	end
end

local git_cache = {}
local function git_branch(dir)
	local c = git_cache[dir]
	local now = os.time()
	if c and now - c.at < modeline.git_refresh then return c.branch end
	if not c then
		c = { gitdir = find_git_dir(dir) }
		git_cache[dir] = c
	end
	c.at = now
	c.branch = nil
	if c.gitdir then
		local head = read_line(c.gitdir .. "/HEAD")
		if head then
			c.branch = head:match("^ref: refs/heads/(.+)$") or head:sub(1, 7)
		end
	end
	return c.branch
end
modeline.git_branch = git_branch

-- LSP state through vis-lspc's tables: open_files[path].language_servers
-- is keyed by server object, .diagnostics by server with LSP severities.

local function lspc_module()
	if modeline.lspc then return modeline.lspc end
	for _, mod in pairs(package.loaded) do
		if type(mod) == "table" and mod.open_files and mod.running then
			modeline.lspc = mod
			return mod
		end
	end
end

local severities = { "error", "warn", "info", "hint" }

local function lsp_state(file)
	local lspc = lspc_module()
	local open = lspc and file.path and lspc.open_files[file.path]
	if not open then return nil, nil end
	local names = {}
	for ls in pairs(open.language_servers) do
		table.insert(names, ls.name or "?")
	end
	table.sort(names)
	local counts = { 0, 0, 0, 0 }
	for _, list in pairs(open.diagnostics) do
		for _, d in ipairs(list) do
			local s = d.severity or 1
			counts[s] = (counts[s] or 0) + 1
		end
	end
	return table.concat(names, ","), counts
end

-- the status handler

local function pad(text) return " " .. text .. " " end

local function status(win)
	if not modeline.enabled then return end
	local file, sel = win.file, win.selection
	local sym = modeline.symbols
	local left, right = {}, {}
	local mode = vis.win == win and modes[vis.mode]
	if mode then table.insert(left, { pad(mode[1]), style(mode[2]) }) end

	local path = file.path and parent(file.path) or os.getenv("PWD")
	local branch = path and git_branch(path)
	if branch then table.insert(left, { pad(sym.branch .. branch), style("branch") }) end

	table.insert(left, pad(file.name or "[No Name]"))
	if file.modified then table.insert(left, { sym.modified, style("modified") }) end
	if vis.recording then table.insert(left, " @") end

	local servers, counts = lsp_state(file)
	if counts then
		for i, name in ipairs(severities) do
			if counts[i] > 0 then
				table.insert(left, { pad(sym[name] .. counts[i]), style(name) })
			end
		end
	end

	local keys = vis.input_queue
	if keys ~= "" then
		table.insert(right, pad(keys))
	elseif vis.count then
		table.insert(right, pad(vis.count))
	end
	if #win.selections > 1 then
		table.insert(right, pad(sel.number .. "/" .. #win.selections))
	end
	if servers and servers ~= "" then
		table.insert(right, { pad(sym.lsp .. servers), style("lsp") })
	end
	if win.syntax then table.insert(right, pad(win.syntax)) end

	local size, pos = file.size, sel.pos or 0
	local percent = size == 0 and "0%" or math.ceil(pos / size * 100) .. "%"
	table.insert(right, pad(percent))
	if not win.large then
		local col = sel.col
		local where = pad(sel.line .. ":" .. col)
		table.insert(right, mode and { where, style(mode[2]) } or where)
		if size > 33554432 or col > 65536 then win.large = true end
	end

	win:status(left, right)
	return true
end

vis.events.subscribe(vis.events.WIN_STATUS, status, 1)

return modeline
