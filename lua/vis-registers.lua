-- Registers: a readout of what the operators put where.
--
--   registers = require('vis-registers')
--
-- On REGISTER_PUT the info line reports the operator, the amount and the
-- register, as in `yank 22 lines → "+`, and `registers.last` keeps the
-- same facts for the modeline. `registers.toggle()` shows or hides an
-- overlay in the middle of the screen listing every filled register with
-- its size and first line; a click on a row puts that register after the
-- cursor. Knobs: `registers.notify`, `registers.names` (the order of the
-- special registers), `registers.preview_width`, `registers.colors`.
require('vis')
local overlay = require('vis-overlay')

local registers = {}
registers.enabled = true

-- report each put on the info line
registers.notify = true

-- special registers listed first, in this order, when they hold something;
-- a-z follow. The clipboard registers cost a vis-clipboard call each.
registers.names = { '"', '0', '+', '*', '.', '/', ':', '!' }

-- cells of the first line shown per register
registers.preview_width = 50

-- the title row, the entry rows, and within an entry the register name
-- and its size, whose styles merge over the row's
registers.colors = {
	title = "fore:black,back:blue,bold",
	entry = "fore:white,back:black",
	name = "fore:cyan,bold",
	size = "dim",
}

-- the last put: { name, op, count, bytes, lines, at }, or nil
registers.last = nil

local styles = {}
local function style(name)
	local id = styles[name]
	if not id then
		id = vis.ui:style_push(registers.colors[name] or "")
		styles[name] = id
	end
	return id
end

local function len(s)
	return utf8 and utf8.len(s) or #s
end

local function cut(s, w)
	if len(s) <= w then return s end
	local at = utf8 and utf8.offset(s, w + 1) or w + 1
	return s:sub(1, at - 1)
end

local function pad(s, w)
	local n = len(s)
	if n >= w then return s end
	return s .. string.rep(" ", w - n)
end

-- the slots of a register joined by newlines, and how many there were
local function content(name)
	local slots = vis.registers[name]
	if not slots or #slots == 0 then return nil, 0 end
	return table.concat(slots, "\n"), #slots
end

-- bytes and lines of a text; a last line without its newline counts
local function measure(text)
	local bytes = #text
	local _, lines = text:gsub("\n", "")
	if bytes > 0 and text:sub(-1) ~= "\n" then lines = lines + 1 end
	return bytes, lines
end

local function describe(bytes, lines)
	if lines > 1 then return lines .. " lines" end
	return bytes .. (bytes == 1 and " byte" or " bytes")
end

local shown = false
local rows -- what the box lists, for clicks

function registers.hide()
	if not shown then return end
	shown = false
	rows = nil
	overlay.hide(registers)
end

-- a click on a row puts that register after the cursor
local function clicked(row)
	if not rows or row < 2 then return end
	local r = rows[row - 1]
	registers.hide()
	if r then vis:feedkeys('"' .. r.name .. "p") end
end

function registers.show()
	rows = {}
	local seen = {}
	local function add(name)
		if seen[name] then return end
		seen[name] = true
		local text, slots = content(name)
		if not text or text == "" then return end
		local bytes, lines = measure(text)
		rows[#rows + 1] = {
			name = name, slots = slots,
			size = describe(bytes, lines),
			preview = (text:match("^[^\n]*") or ""):gsub("\t", " "),
		}
	end
	for _, name in ipairs(registers.names) do add(name) end
	for c = ("a"):byte(), ("z"):byte() do add(string.char(c)) end

	local sizew, prevw = 0, 0
	for _, r in ipairs(rows) do
		if r.slots > 1 then r.size = r.slots .. "x " .. r.size end
		sizew = math.max(sizew, len(r.size))
		prevw = math.max(prevw, len(r.preview))
	end
	prevw = math.min(prevw, registers.preview_width)

	local lines = { " registers  (" .. #rows .. ")" }
	for _, r in ipairs(rows) do
		lines[#lines + 1] = {
			{ ' "' .. r.name .. "  ", style("name") },
			{ pad(r.size, sizew + 2), style("size") },
			pad(cut(r.preview, prevw), prevw + 1),
		}
	end
	if #rows == 0 then lines[2] = " nothing yet" end

	local width = math.max(len(lines[1]), 5 + sizew + 2 + prevw + 1)
	local stys = { style("title") }
	for r = 2, #lines do stys[r] = style("entry") end
	local x, y = overlay.center(width, #lines)
	shown = true
	overlay.show(registers, {
		x = x, y = y, width = width, lines = lines,
		style = style("entry"), styles = stys,
	}, clicked)
end

function registers.toggle()
	-- another owner may have taken the box since it was shown
	if shown and overlay.owner() == registers then
		registers.hide()
	else
		registers.show()
	end
end

vis.events.subscribe(vis.events.REGISTER_PUT, function(name, op, count)
	if not registers.enabled then return end
	local text = content(name)
	local bytes, lines = 0, 0
	if text then bytes, lines = measure(text) end
	registers.last = { name = name, op = op, count = count,
	                   bytes = bytes, lines = lines, at = os.time() }
	if registers.notify then
		local what = describe(bytes, lines)
		if count > 1 then what = count .. " selections, " .. what end
		vis:info(string.format('%s %s → "%s', op, what, name))
	end
	if shown and overlay.owner() == registers then registers.show() end
end)

return registers
