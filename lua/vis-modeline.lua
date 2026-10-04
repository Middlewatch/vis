-- Modeline: a lualine-style status line built from styled segments.
--
--   modeline = require('vis-modeline')
--
-- Sections follow lualine: a is the mode block, b the git branch and
-- LSP diagnostic counts, c the file name with its modified flag. The
-- right side mirrors them: x holds pending keys or count, selection
-- index, LSP server and syntax; y the percentage; z line:col. Only the
-- focused window shows a and z. Colors come from `modeline.colors`, read
-- when a style is first used, so set them in visrc before the first
-- redraw. `modeline.enabled = false` hands the status line back to the
-- default.
require('vis')

local modeline = {}
modeline.enabled = true

-- Style strings. A segment style is merged over the status style, so a
-- `fore`-only string keeps the bar's background. Each mode names the
-- style of its a block and of the b section; c, x and the bar itself are
-- the theme's STATUS_FOCUSED style (STATUS for unfocused windows).
modeline.colors = {
	normal   = { a = "fore:black,back:blue,bold",    b = "fore:blue,bold"    },
	insert   = { a = "fore:black,back:green,bold",   b = "fore:green,bold"   },
	visual   = { a = "fore:black,back:magenta,bold", b = "fore:magenta,bold" },
	replace  = { a = "fore:black,back:red,bold",     b = "fore:red,bold"     },
	modified = "fore:yellow",
	error    = "fore:red",
	warn     = "fore:yellow",
	info     = "fore:cyan",
	hint     = "fore:blue",
	lsp      = "fore:green",
}

-- Powerline glyphs between sections and between items of one section.
-- A section separator takes the near section's background as its
-- foreground, so it draws only when that section sets `back`; otherwise
-- it falls back to a space. Set any entry to nil for a plain space.
modeline.separators = {
	left  = "\u{e0b0}", right = "\u{e0b2}",  -- between sections
	item_left = "\u{e0b1}", item_right = "\u{e0b3}",  -- within a section
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

-- style ids are allocated once per distinct style string
local styles = {}
local function style(spec)
	local id = styles[spec]
	if not id then
		id = vis.ui:style_push(spec)
		styles[spec] = id
	end
	return id
end

local function back(spec)
	return spec and spec:match("back:%s*([^,%s]+)")
end

-- an item's own colors laid over its section's background
local function on(section, spec)
	spec = spec or ""
	local bg = back(section)
	if bg and not back(spec) then spec = spec .. ",back:" .. bg end
	return spec
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

-- A section is { style = spec or nil, items = { text | {text, spec} } }.
-- Rendering pads each item, joins items with the item separator, and
-- puts a section separator between adjacent non-empty sections. The
-- right side is built in reading order (x, y, z) and the glyphs point
-- the other way.

local function render(sections, sep, item_sep, rightward)
	local out, prev = {}, nil
	for _, section in ipairs(sections) do
		if #section.items > 0 then
			if prev then
				-- the near section is the one the glyph's point leaves
				local near, far = prev.style, section.style
				if rightward then near, far = far, near end
				local bg = back(near)
				if sep and bg then
					local fbg = back(far)
					table.insert(out, { sep, style("fore:" .. bg .. (fbg and (",back:" .. fbg) or "")) })
				else
					table.insert(out, section.style and { " ", style(section.style) } or " ")
				end
			end
			for i, item in ipairs(section.items) do
				local text, spec = item, section.style
				if type(item) == "table" then
					text, spec = item[1], on(section.style or "", item[2])
				end
				if i > 1 then
					local glyph = item_sep or ""
					table.insert(out, section.style and { glyph, style(section.style) } or glyph)
				end
				text = " " .. text .. " "
				table.insert(out, spec and spec ~= "" and { text, style(spec) } or text)
			end
			prev = section
		end
	end
	return out
end

local function status(win)
	if not modeline.enabled then return end
	local file, sel = win.file, win.selection
	local sym, colors, sep = modeline.symbols, modeline.colors, modeline.separators
	local mode = vis.win == win and modes[vis.mode]
	local mc = mode and colors[mode[2]] or {}

	local a, b, c = { style = mc.a, items = {} }, { style = mc.b, items = {} }, { items = {} }
	local x, y, z = { items = {} }, { style = mc.b, items = {} }, { style = mc.a, items = {} }

	if mode then table.insert(a.items, mode[1]) end

	local path = file.path and parent(file.path) or os.getenv("PWD")
	local branch = path and git_branch(path)
	if branch then table.insert(b.items, sym.branch .. branch) end

	local servers, counts = lsp_state(file)
	if counts then
		for i, name in ipairs(severities) do
			if counts[i] > 0 then
				table.insert(b.items, { sym[name] .. counts[i], colors[name] })
			end
		end
	end

	local name = file.name or "[No Name]"
	if vis.recording then name = name .. " @" end
	table.insert(c.items, file.modified and { name .. sym.modified, colors.modified } or name)

	local keys = vis.input_queue
	if keys ~= "" then
		table.insert(x.items, keys)
	elseif vis.count then
		table.insert(x.items, tostring(vis.count))
	end
	if #win.selections > 1 then
		table.insert(x.items, sel.number .. "/" .. #win.selections)
	end
	if servers and servers ~= "" then
		table.insert(x.items, { sym.lsp .. servers, colors.lsp })
	end
	if win.syntax then table.insert(x.items, win.syntax) end

	local size, pos = file.size, sel.pos or 0
	table.insert(y.items, size == 0 and "0%" or math.ceil(pos / size * 100) .. "%")
	if not win.large then
		local col = sel.col
		table.insert(z.items, sel.line .. ":" .. col)
		if size > 33554432 or col > 65536 then win.large = true end
	end

	win:status(render({ a, b, c }, sep.left, sep.item_left, false),
	           render({ x, y, z }, sep.right, sep.item_right, true))
	return true
end

vis.events.subscribe(vis.events.WIN_STATUS, status, 1)

return modeline
