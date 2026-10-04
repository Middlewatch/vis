-- Hints: a which-key style menu for half-typed key sequences.
--
--   hints = require('vis-hints')
--
-- On KEYS_PENDING the bindings under the typed prefix are listed in the
-- overlay just above the status line, in columns: the next key, then its
-- help text from vis:mappings, or a group name from `hints.groups` when
-- more keys follow. The box goes when the prefix resolves or is dropped.
-- `hints.triggers` limits the menu to some prefixes (the leader by
-- default); set it to nil for every prefix. Colors come from
-- `hints.colors`, read when a style is first used.
require('vis')
local overlay = require('vis-overlay')

local hints = {}
hints.enabled = true

-- a typed space reaches the mappings as a literal " ", so map leader
-- bindings as " f", " b" and so on
hints.leader = " "

-- prefixes that open the menu; nil means every pending prefix
hints.triggers = { hints.leader }

-- group names, keyed by the full key sequence
hints.groups = {
	[hints.leader .. "b"] = "buffers",
	[hints.leader .. "c"] = "code",
	[hints.leader .. "f"] = "files",
	[hints.leader .. "g"] = "git",
	[hints.leader .. "h"] = "harpoon",
	[hints.leader .. "p"] = "projects",
	[hints.leader .. "q"] = "quit",
	[hints.leader .. "s"] = "search",
	[hints.leader .. "t"] = "tools",
	[hints.leader .. "w"] = "windows",
}

-- how a key token is shown
hints.names = {
	[" "] = "<Space>",
}

-- one style per overlay row: the title row and the entry rows
hints.colors = {
	title = "fore:black,back:blue,bold",
	entry = "fore:white,back:black",
}

-- entry rows at most; what does not fit is counted in the title
hints.max_rows = 8

-- cells of help text per column; longer texts are cut so columns fit
hints.text_width = 30

-- cells between the key and its text, and after each column
hints.gap = 2

local styles = {}
local function style(name)
	local id = styles[name]
	if not id then
		id = vis.ui:style_push(hints.colors[name] or "")
		styles[name] = id
	end
	return id
end

local function len(s)
	return utf8 and utf8.len(s) or #s
end

local function pad(s, w)
	local n = len(s)
	if n >= w then return s end
	return s .. string.rep(" ", w - n)
end

local function cut(s, w)
	if len(s) <= w then return s end
	local at = utf8 and utf8.offset(s, w + 1) or w + 1
	return s:sub(1, at - 1)
end

-- first key token of a sequence: <Name> or one UTF-8 character
local function next_key(seq)
	local special = seq:match("^<[^<>]+>")
	if special then return special end
	return seq:match("^[%z\1-\127\194-\244][\128-\191]*")
end

local function display(key)
	return hints.names[key] or key
end

local function display_seq(seq)
	local out = {}
	while seq ~= "" do
		local key = next_key(seq) or seq
		out[#out + 1] = display(key)
		seq = seq:sub(#key + 1)
	end
	return table.concat(out)
end

-- entries under a prefix: {key, text, group} sorted by key; leaves show
-- their help, groups show "+name" or "+N keys"
local function collect(prefix)
	local by_key = {}
	for seq, help in pairs(vis:mappings(vis.mode)) do
		if #seq > #prefix and seq:sub(1, #prefix) == prefix then
			local rest = seq:sub(#prefix + 1)
			local key = next_key(rest)
			if key then
				local e = by_key[key]
				if not e then
					e = { key = key, count = 0 }
					by_key[key] = e
				end
				if #rest == #key then
					e.help = help
				else
					e.count = e.count + 1
				end
			end
		end
	end
	local entries = {}
	for key, e in pairs(by_key) do
		if e.count > 0 then
			local name = hints.groups[prefix .. key]
			e.text = "+" .. (name or (e.count .. " keys"))
		else
			e.text = e.help ~= "" and e.help or ""
		end
		table.insert(entries, e)
	end
	table.sort(entries, function(a, b) return a.key < b.key end)
	return entries
end

local shown = false

local function hide()
	if not shown then return end
	shown = false
	overlay.hide(hints)
end

local function show(prefix)
	local width, height = vis.ui.width, vis.ui.height
	local entries = collect(prefix)
	if #entries == 0 then return hide() end

	local keyw, textw = 0, 0
	for _, e in ipairs(entries) do
		keyw = math.max(keyw, len(display(e.key)))
		textw = math.max(textw, len(e.text))
	end
	textw = math.min(textw, hints.text_width)
	local colw = math.min(width, keyw + hints.gap + textw + hints.gap)
	local cols = math.max(1, width // colw)
	local rows = math.min(hints.max_rows, math.ceil(#entries / cols))
	local fit = rows * cols

	local lines = {}
	for r = 1, rows do
		local cells = {}
		for c = 0, cols - 1 do
			local e = entries[c * rows + r]
			if e then
				cells[#cells + 1] = pad(pad(display(e.key), keyw + hints.gap) .. cut(e.text, textw), colw)
			end
		end
		lines[r + 1] = " " .. table.concat(cells)
	end

	local title = " " .. display_seq(prefix)
	local name = hints.groups[prefix]
	if name then title = title .. "  " .. name end
	if #entries > fit then title = title .. "  (" .. (#entries - fit) .. " more)" end
	lines[1] = title

	local stys = { style("title") }
	for r = 2, #lines do stys[r] = style("entry") end

	shown = true
	overlay.show(hints, {
		x = 0, y = math.max(0, height - 1 - #lines),
		width = width, lines = lines,
		style = style("entry"), styles = stys,
	})
end

local function triggered(prefix)
	if not hints.triggers then return true end
	for _, t in ipairs(hints.triggers) do
		if prefix:sub(1, #t) == t then return true end
	end
	return false
end

vis.events.subscribe(vis.events.KEYS_PENDING, function(prefix)
	if not hints.enabled or not prefix then return hide() end
	if triggered(prefix) then show(prefix) else hide() end
end)

return hints
