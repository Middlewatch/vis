-- Files: where you have been, and where you want to get back to.
--
--   files = require('vis-files')
--
-- `files.recent` holds the paths shown in a focused window this session,
-- most recent first, and `files.positions` the line last seen in each;
-- `files.pick_recent()` is fzf over them and `files.alternate()` goes to
-- the one before the current, both back to that line.
-- `files.pick_buffers()` is fzf over the editor's buffers (`vis:files()`,
-- hidden ones marked) and shows the choice with `:b`. Pins are a
-- numbered list per project, harpoon-style: `files.pin(n)` pins the
-- current file and line as entry n (appended without n), `files.jump(n)`
-- opens pin n, `files.unpin()` drops the current file's pin, and
-- `files.toggle()` shows the list in the middle of the screen, where a
-- click on a row jumps. Pins live in $XDG_STATE_HOME/vis/pins, one file
-- per project root, so they outlast the editor. Opening goes through
-- vis-pick's `open`, which reuses a window showing the file. Knobs:
-- `files.max_recent`, `files.colors`.
require('vis')
local overlay = require('vis-overlay')
local pick = require('vis-pick')

local files = {}
files.enabled = true

-- paths remembered at most
files.max_recent = 50

-- the title row, the entry rows, and within an entry the pin number and
-- the line, whose styles merge over the row's
files.colors = {
	title = "fore:black,back:blue,bold",
	entry = "fore:white,back:black",
	number = "fore:cyan,bold",
	line = "dim",
}

files.recent = {}
files.positions = {}  -- path -> line last seen there
files.pins = {}   -- of the current root: { {path=, line=}, ... }
local pins_root    -- the root files.pins belongs to

local function sh(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

local styles = {}
local function style(name)
	local id = styles[name]
	if not id then
		id = vis.ui:style_push(files.colors[name] or "")
		styles[name] = id
	end
	return id
end

-- recent

local function bump(path)
	for i, p in ipairs(files.recent) do
		if p == path then table.remove(files.recent, i) break end
	end
	table.insert(files.recent, 1, path)
	files.recent[files.max_recent + 1] = nil
end

vis.events.subscribe(vis.events.UI_DRAW, function()
	local file = files.enabled and vis.win and vis.win.file
	local path = file and file.path
	if not path then return end
	if files.recent[1] ~= path then bump(path) end
	files.positions[path] = vis.win.selection.line
end)

function files.pick_recent()
	local rows = {}
	local root = pick.root()
	for i, path in ipairs(files.recent) do
		if i > 1 or #files.recent == 1 then
			local shown = path
			if path:sub(1, #root + 1) == root .. "/" then shown = path:sub(#root + 2) end
			rows[#rows + 1] = shown .. "\t" .. path
		end
	end
	if #rows == 0 then return vis:info("no other files yet") end
	local cmd = pick.fzf .. " --delimiter '\t' --with-nth 1 --tiebreak=index"
	local status, out = vis:pipe(table.concat(rows, "\n") .. "\n", cmd, true)
	if status ~= 0 or not out then return end
	local path = out:match("^[^\n]*\t([^\n]*)")
	if path then pick.open(path, files.positions[path]) end
end

function files.pick_buffers()
	local shown = {}
	for win in vis:windows() do
		if win.file then shown[win.file.number] = true end
	end
	local rows = {}
	for file in vis:files() do
		if file.number > 0 and file ~= vis.win.file then
			rows[#rows + 1] = string.format("%3d %s%s  %s\t%d", file.number,
				shown[file.number] and "a" or "h", file.modified and "+" or " ",
				file.name or "[No Name]", file.number)
		end
	end
	if #rows == 0 then return vis:info("no other buffers") end
	local cmd = pick.fzf .. " --delimiter '\t' --with-nth 1 --tiebreak=index"
	local status, out = vis:pipe(table.concat(rows, "\n") .. "\n", cmd, true)
	if status ~= 0 or not out then return end
	local number = out:match("\t(%d+)")
	if number then vis:command("b " .. number) end
end

function files.alternate()
	local path = files.recent[2]
	if path then pick.open(path, files.positions[path]) else vis:info("no previous file") end
end

-- pins

local function state_dir()
	local base = os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
	return base .. "/vis/pins"
end

local function pins_file(root)
	return state_dir() .. "/" .. root:gsub("/", "%%")
end

local function load(root)
	if pins_root == root then return files.pins end
	pins_root, files.pins = root, {}
	local f = io.open(pins_file(root), "r")
	if not f then return files.pins end
	for row in f:lines() do
		local line, path = row:match("^(%d+)\t(.+)$")
		if path then files.pins[#files.pins + 1] = { path = path, line = tonumber(line) } end
	end
	f:close()
	return files.pins
end

local function save()
	os.execute("mkdir -p " .. sh(state_dir()))
	local f = io.open(pins_file(pins_root), "w")
	if not f then return vis:info("cannot write " .. pins_file(pins_root)) end
	for _, pin in ipairs(files.pins) do
		f:write(pin.line, "\t", pin.path, "\n")
	end
	f:close()
end

local function current()
	local path = vis.win.file.path
	if not path then vis:info("no file name to pin") end
	return path, vis.win.selection.line
end

local function index_of(pins, path)
	for i, pin in ipairs(pins) do
		if pin.path == path then return i end
	end
end

local shown = false

function files.pin(n)
	local path, line = current()
	if not path then return end
	local pins = load(pick.root())
	local i = index_of(pins, path)
	if n then
		if i and i ~= n then table.remove(pins, i) end
		pins[n] = { path = path, line = line }
		for k = 1, n - 1 do pins[k] = pins[k] or { path = "", line = 0 } end
	elseif i then
		pins[i].line = line
		n = i
	else
		pins[#pins + 1] = { path = path, line = line }
		n = #pins
	end
	save()
	vis:info("pin " .. n .. ": " .. vis.win.file.name .. ":" .. line)
	if shown then files.show() end
end

function files.unpin()
	local path = current()
	if not path then return end
	local pins = load(pick.root())
	local i = index_of(pins, path)
	if not i then return vis:info("not pinned") end
	table.remove(pins, i)
	save()
	vis:info("unpinned " .. vis.win.file.name)
	if shown then files.show() end
end

function files.jump(n)
	local pin = load(pick.root())[n]
	if not pin or pin.path == "" then return vis:info("no pin " .. n) end
	files.hide()
	pick.open(pin.path, pin.line)
end

function files.hide()
	if not shown then return end
	shown = false
	overlay.hide(files)
end

local function clicked(row)
	if row >= 2 then files.jump(row - 1) end
end

function files.show()
	local root = pick.root()
	local pins = load(root)
	local lines = { " pins  " .. root }
	if #lines[1] > vis.ui.width - 4 then
		lines[1] = " pins  …" .. root:sub(#root - (vis.ui.width - 12))
	end
	local namew = 0
	for _, pin in ipairs(pins) do
		local name = pin.path
		if name:sub(1, #root + 1) == root .. "/" then name = name:sub(#root + 2) end
		pin.shown = name
		namew = math.max(namew, #name)
	end
	for i, pin in ipairs(pins) do
		lines[#lines + 1] = {
			{ " " .. i .. "  ", style("number") },
			pin.shown .. string.rep(" ", namew - #pin.shown + 2),
			{ ":" .. pin.line .. " ", style("line") },
		}
	end
	if #pins == 0 then lines[2] = " nothing pinned here" end
	local width = math.max(#lines[1] + 1, namew + 12)
	local stys = { style("title") }
	for r = 2, #lines do stys[r] = style("entry") end
	local x, y = overlay.center(width, #lines)
	shown = true
	overlay.show(files, {
		x = x, y = y, width = width, lines = lines,
		style = style("entry"), styles = stys,
	}, clicked)
end

function files.toggle()
	if shown and overlay.owner() == files then files.hide() else files.show() end
end

return files
