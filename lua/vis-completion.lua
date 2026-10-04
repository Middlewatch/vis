-- Completion: an as-you-type list drawn in the overlay under the word.
--
--   completion = require('vis-completion')
--
-- Typing a word character in INSERT opens a list of candidates below the
-- word: items from the language server through vis-lspc when one runs
-- for the file, then words of the file itself. Typing on narrows it,
-- <C-n> and <C-p> walk it (past either end nothing is chosen again),
-- <Enter> inserts the chosen item and stays a line break while nothing
-- is chosen, and so does a click on a row. A key that ends the word, or
-- leaving INSERT, closes the list; <C-n> on a closed list opens it by hand. A server trigger
-- character such as "." opens it with the server's items alone. Knobs:
-- `completion.keys`, `completion.colors`, `completion.max_rows`,
-- `completion.min_chars`, `completion.buffer_words`, `completion.max_scan`.
require('vis')
local overlay = require('vis-overlay')

local completion = {}
completion.enabled = true

-- word characters typed before the list opens by itself
completion.min_chars = 1

-- rows at most; the chosen row scrolls into view
completion.max_rows = 8

-- cells of label at most
completion.max_width = 40

-- offer words of the file; files over max_scan bytes give none
completion.buffer_words = true
completion.max_scan = 512 * 1024

-- the vis-lspc module; found in package.loaded when nil
completion.lspc = nil

completion.keys = {
	next = "<C-n>",
	prev = "<C-p>",
	accept = "<Enter>",
}

-- one style per overlay row
completion.colors = {
	entry = "fore:white,back:black",
	selected = "fore:black,back:blue",
}

-- CompletionItemKind to the tag shown after the label
completion.kinds = {
	"text", "method", "function", "constructor", "field", "variable",
	"class", "interface", "module", "property", "unit", "value", "enum",
	"keyword", "snippet", "color", "file", "reference", "folder",
	"enum member", "constant", "struct", "event", "operator", "type param",
}
completion.buffer_kind = "buffer"

local styles = {}
local function style(name)
	local id = styles[name]
	if not id then
		id = vis.ui:style_push(completion.colors[name] or "")
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

local function is_word(key)
	return key:match("^[%w_]$") ~= nil
end

-- the word ending at pos: its start and text
local function word_before(file, pos)
	local n = math.min(pos, 256)
	local before = file:content(pos - n, n) or ""
	local w = before:match("[%w_]*$")
	return pos - #w, w
end

-- words of a file, rescanned after a change
local words_cache = setmetatable({}, { __mode = "k" })

vis.events.subscribe(vis.events.TEXT_CHANGED, function(file)
	local c = words_cache[file]
	if c then c.stale = true end
end)

local function buffer_words(file, prefix, taken)
	local c = words_cache[file]
	if not c or c.stale then
		c = { stale = false, words = {} }
		if file.size <= completion.max_scan then
			local text = file:content(0, file.size) or ""
			for w in text:gmatch("[%a_][%w_]*") do
				c.words[w] = true
			end
		end
		words_cache[file] = c
	end
	local lower = prefix:lower()
	local out = {}
	for w in pairs(c.words) do
		if w ~= prefix and not taken[w] and w:sub(1, #prefix):lower() == lower then
			out[#out + 1] = w
		end
	end
	table.sort(out)
	return out
end

-- ${1:name} keeps name, ${1} and $1 go
local function snippet_text(s)
	s = s:gsub("%$(%b{})", function(m)
		return m:match("^{%d+:(.*)}$") or ""
	end)
	return (s:gsub("%$%d+", ""))
end

-- server items as {label, text, filter, kind}, in the server's order
local function lsp_items(result)
	local items = result or {}
	if items.items then items = items.items end
	local out = {}
	for _, it in ipairs(items) do
		if type(it) == "table" and it.label then
			local text = it.insertText or it.label
			if it.textEdit and it.textEdit.newText then text = it.textEdit.newText end
			if it.insertTextFormat == 2 then text = snippet_text(text) end
			out[#out + 1] = {
				label = it.label,
				text = text,
				filter = it.filterText or it.label,
				kind = completion.kinds[it.kind or 0] or "",
				sort = it.sortText or it.label,
			}
		end
	end
	table.sort(out, function(a, b) return a.sort < b.sort end)
	return out
end

local function find_lspc()
	if completion.lspc then return completion.lspc end
	for _, m in pairs(package.loaded) do
		if type(m) == "table" and m.open_files and m.running and m.complete then
			completion.lspc = m
			return m
		end
	end
end

-- characters the file's server wants to be asked after
local function trigger_chars(win)
	local lspc = find_lspc()
	if not lspc then return nil end
	local ls = lspc.get_running_ls(win)
	local provider = ls and ls.capabilities and ls.capabilities.completionProvider
	return provider and provider.triggerCharacters
end

local state = {
	want = false,      -- the last typed key asked for the list
	win = nil,         -- window the list belongs to
	start = nil,       -- file position where the word starts
	prefix = nil,      -- the word typed so far
	lsp = {},          -- server items for start
	incomplete = false,-- the server wants to be asked again as the word grows
	request = 0,       -- number of the latest request, stale answers are dropped
	trigger = nil,     -- {char, at}: a trigger character and the position after it
	manual = false,    -- opened with the next key, so an empty word counts
	candidates = {},
	selected = nil,
	first = 1,         -- first row shown
	shown = false,
}

local function hide(drop)
	if state.shown then
		state.shown = false
		overlay.hide(completion)
	end
	if drop then
		state.want, state.manual, state.trigger = false, false, nil
		state.start, state.prefix, state.lsp = nil, nil, {}
		state.incomplete, state.selected, state.first = false, nil, 1
	end
end

local function request(win, start)
	local lspc = find_lspc()
	if not lspc then return end
	state.request = state.request + 1
	local id = state.request
	local trig = state.trigger and state.trigger.at == start and state.trigger.char or nil
	lspc.complete(win, function(_, result)
		if id ~= state.request or not state.want then return end
		state.lsp = lsp_items(result)
		state.incomplete = type(result) == "table" and result.isIncomplete or false
	end, trig)
end

local function collect(win)
	local prefix, lower = state.prefix, state.prefix:lower()
	local out, taken = {}, {}
	for _, it in ipairs(state.lsp) do
		if it.text ~= prefix and it.filter:sub(1, #prefix):lower() == lower then
			out[#out + 1] = it
			taken[it.label] = true
		end
	end
	if completion.buffer_words and (prefix ~= "" or state.manual) then
		for _, w in ipairs(buffer_words(win.file, prefix, taken)) do
			out[#out + 1] = { label = w, text = w, kind = completion.buffer_kind }
		end
	end
	return out
end

local accept

local function clicked(row, m)
	if m.button ~= 1 or not state.shown then return end
	local i = state.first + row - 1
	if not state.candidates[i] then return end
	state.selected = i
	accept()
end

local function show(win)
	local x, y = win:coord(state.start)
	if not x then return hide() end
	local width, height = vis.ui.width, vis.ui.height
	local n = #state.candidates
	local rows = math.min(completion.max_rows, n)
	if state.selected then
		if state.selected < state.first then state.first = state.selected end
		if state.selected >= state.first + rows then state.first = state.selected - rows + 1 end
	else
		state.first = 1
	end
	state.first = math.max(1, math.min(state.first, n - rows + 1))

	local labelw, kindw = 0, 0
	for i = state.first, state.first + rows - 1 do
		local c = state.candidates[i]
		labelw = math.max(labelw, len(c.label))
		kindw = math.max(kindw, len(c.kind))
	end
	labelw = math.min(labelw, completion.max_width)

	local lines, stys = {}, {}
	for r = 1, rows do
		local i = state.first + r - 1
		local c = state.candidates[i]
		local line = " " .. pad(cut(c.label, labelw), labelw)
		if kindw > 0 then line = line .. "  " .. pad(c.kind, kindw) end
		lines[r] = line .. " "
		stys[r] = style(i == state.selected and "selected" or "entry")
	end

	-- below the word's row when that fits above the last row, else above it
	local w = len(lines[1])
	local py = y + 1
	if py + rows > height - 1 then py = y - rows end
	py = math.max(0, py)
	local px = math.max(0, math.min(x, width - w))
	state.shown = true
	overlay.show(completion, { x = px, y = py, width = w, lines = lines, style = style("entry"), styles = stys }, clicked)
end

-- runs on every redraw: follow the cursor, ask the server for a new word,
-- filter, draw
local function refresh()
	if not state.want then return hide() end
	local win = vis.win
	if not win or win ~= state.win or vis.mode ~= vis.modes.INSERT then return hide(true) end
	local pos = win.selection.pos
	if not pos then return hide(true) end

	local start, prefix = word_before(win.file, pos)
	if state.trigger and state.trigger.at ~= start then state.trigger = nil end
	local allow_empty = state.manual or (state.trigger ~= nil)
	if prefix == "" and not allow_empty then return hide(true) end
	if #prefix < completion.min_chars and not allow_empty then return hide() end

	if start ~= state.start then
		state.start, state.lsp, state.selected, state.incomplete = start, {}, nil, false
		state.prefix = prefix
		request(win, start)
	elseif prefix ~= state.prefix then
		state.prefix, state.selected = prefix, nil
		if state.incomplete then request(win, start) end
	end

	state.candidates = collect(win)
	if #state.candidates == 0 then
		state.selected = nil
		return hide()
	end
	if state.selected and state.selected > #state.candidates then state.selected = nil end
	show(win)
end

vis.events.subscribe(vis.events.UI_DRAW, function()
	if completion.enabled then refresh() else hide(true) end
end)

vis.events.subscribe(vis.events.INPUT, function(key)
	if not completion.enabled then return end
	local win = vis.win
	if not win or vis.mode ~= vis.modes.INSERT then return end
	if is_word(key) then
		state.want, state.win = true, win
		return
	end
	local triggers = trigger_chars(win)
	if triggers then
		for _, t in ipairs(triggers) do
			if t == key then
				hide(true)
				state.want, state.win = true, win
				state.trigger = { char = key, at = (win.selection.pos or 0) + #key }
				return
			end
		end
	end
	hide(true)
end)

local function move(delta)
	if not state.shown then
		if delta > 0 and vis.win and vis.mode == vis.modes.INSERT then
			state.want, state.manual, state.win = true, true, vis.win
		end
		return
	end
	local n = #state.candidates
	local i = (state.selected or (delta > 0 and 0 or n + 1)) + delta
	if i < 1 or i > n then i = nil end
	state.selected = i
end

function accept()
	local c = state.candidates[state.selected]
	local win = state.win
	local pos = win.selection.pos
	local start = state.start
	if pos > start then win.file:delete(start, pos - start) end
	win.file:insert(start, c.text)
	win.selection.pos = start + #c.text
	hide(true)
end

vis:map(vis.modes.INSERT, completion.keys.next, function()
	move(1)
end, "Next completion, or open the list")

vis:map(vis.modes.INSERT, completion.keys.prev, function()
	move(-1)
end, "Previous completion")

vis:map(vis.modes.INSERT, completion.keys.accept, function()
	if state.shown and state.selected then
		accept()
	else
		hide(true)
		vis:feedkeys("<vis-insert-newline>")
	end
end, "Insert the chosen completion, or a line break")

return completion
