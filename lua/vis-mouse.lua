-- Basic and extensible mouse support for vis development build
require('vis')

local mouse = {}

-- mouse event constants used by libtermkey
local MOUSE_EVENT = {
	UNKNOWN = 0,
	PRESSED = 1,
	DRAGGED = 2,
	RELEASED = 3,
}
mouse.MOUSE_EVENT = MOUSE_EVENT

-- common mouse buttons
local BUTTON = {
	NONE = 0,
	LEFT = 1,
	MIDDLE = 2,
	RIGHT = 3,
	WHEELUP = 4,
	WHEELDOWN = 5,
}
mouse.BUTTON = BUTTON

-- Store the mouse state as it changes
local state = {}
mouse.state = state

state.current = {
	event = MOUSE_EVENT.UNKNOWN,
	button = BUTTON.NONE,
	line = 1,
	col = 1,
	time = 0, -- arrival time in ms (monotonic)
	dragging = 0, -- button of in-progress dragging event
	chordbase = 0, -- the first button clicked in a chord event
}

-- store the immediately previous state
state.last = state.current

-- the last button that was clicked
state.lastclick = state.current

-- Maintained map of currently pressed buttons
state.pressed = {
	[BUTTON.LEFT] = false,
	[BUTTON.MIDDLE] = false,
	[BUTTON.RIGHT] = false,
}

-- Custom events
local events = {
	PRESS = "mousepress",
	DRAG = "mousedrag",
	RELEASE = "mouserelease",
	DOUBLE_CLICK = "mousedoubleclick",
	CHORD_PRESS = "mousechordpress",
	CHORD_RELEASE = "mousechordrelease",
}
mouse.events = events

mouse.options = { mouse = true }

-- two presses of one button on one cell within this many milliseconds
-- are a double click; later ones are single clicks again
mouse.double_click_ms = 400

-- lines scrolled per wheel tick
mouse.wheel_lines = 1

-- write a drag selection to the primary selection on release. nil: decide
-- on START from the clipboard backend: on with a Wayland or X primary,
-- off under OSC 52, where primary and clipboard are one and tmux keeps a
-- paste buffer of every write besides
mouse.copy_on_select = nil

-- file position of the last press, nil when it hit no text (status bar,
-- overlay, prompt): a drag from there selects nothing
state.press_pos = nil

-- resolve the terminal cell under the mouse: window, file position (nil on
-- the status bar) and which part of the window was hit ("text", "sidebar"
-- or "status"). On the overlay the window and position are nil, the part
-- is "overlay" and the 1-based overlay row follows as a fourth value.
function mouse.resolve(m)
	local win, pos, where = vis:win_at(m.line, m.col)
	if where == "overlay" then return nil, nil, where, pos end
	return win, pos, where
end

-- called with the 1-based overlay row and the mouse state when a click
-- (single or double) lands on the overlay; by default vis-overlay routes
-- it to the handler given by whoever showed the overlay
mouse.overlay_click = require('vis-overlay').click

-- like mouse.resolve, but also focus the window under the mouse
local function focus_resolve(m)
	local win, pos, where, row = mouse.resolve(m)
	if win and win ~= vis.win then
		vis.win = win
	end
	return win, pos, where, row
end

vis:option_register("mouse", "bool", function(value, toggle)
	if toggle then
		mouse.options.mouse = not mouse.options.mouse
	else
		mouse.options.mouse = value
	end
	mouse.deactivate()
	if (mouse.options.mouse) then
		mouse.activate()
	end
	return true
end, "Enable tracking mouse events")

-- activate mouse detection
function mouse.activate()
	io.write("\x1b[?1003h") --report any mouse movement
	io.write("\x1b[?1006h") --report button release
	io.flush()
end

vis.events.subscribe(vis.events.START, function()
	mouse.activate()
	if mouse.copy_on_select == nil then
		local status, backend = vis:pipe("vis-clipboard --backend")
		mouse.copy_on_select = status == 0 and not backend:match("^osc52")
	end
end)

-- hand the terminal over clean: no motion reports into the shell under
-- <C-z> or a fullscreen program, tracking back when vis returns
vis.events.subscribe(vis.events.UI_SUSPEND, function() mouse.deactivate() end)
vis.events.subscribe(vis.events.UI_RESUME, function()
	if mouse.options.mouse then mouse.activate() end
end)

-- deactivate mouse detection
function mouse.deactivate()
	io.write("\x1b[?1003l")
	io.write("\x1b[?1006l")
	io.flush()
end

vis.events.subscribe(vis.events.QUIT, mouse.deactivate)

-- set mouse.state appropriately and emit vis events for common operations
local function update_mouse_state(event, button, line, col, time)
	state.last = state.current
	state.current = {}
	state.current.event = event
	state.current.button = button
	state.current.line = line
	state.current.col = col
	state.current.time = time or 0
	state.current.dragging = state.last.dragging
	state.current.chordbase = state.last.chordbase

	if (event == MOUSE_EVENT.PRESSED) then
		state.press_pos = nil
		-- wheel movements don't produce release events
		if (button ~= BUTTON.WHEELUP
			and button ~= BUTTON.WHEELDOWN) then
			state.pressed[button] = true
			if (state.current.chordbase == 0) then
				state.current.chordbase = button
			end
		end

		local double = state.lastclick.button == button
			and state.lastclick.col == col
			and state.lastclick.line == line
			and state.current.time - (state.lastclick.time or 0) <= mouse.double_click_ms
		if double then
			vis.events.emit(events.DOUBLE_CLICK, state)
		elseif (state.current.chordbase ~= button
			and button ~= BUTTON.WHEELUP
			and button ~= BUTTON.WHEELDOWN) then
			vis.events.emit(events.CHORD_PRESS, state)
		else
			vis.events.emit(events.PRESS, state)
		end

		-- After executing appropriate action. A double click does not seed
		-- another one: the third press on the cell is a single click.
		if (button ~= BUTTON.WHEELUP
			and button ~= BUTTON.WHEELDOWN) then
			state.lastclick = double and { button = 0, line = 0, col = 0, time = 0 } or state.current
		end
	elseif (event == MOUSE_EVENT.DRAGGED) then
		state.current.dragging = button
		vis.events.emit(events.DRAG, state)
	elseif (event == MOUSE_EVENT.RELEASED) then
		state.pressed[button] = false
		if (button ~= state.current.chordbase) then
			vis.events.emit(events.CHORD_RELEASE, state)
		else
			vis.events.emit(events.RELEASE, state)
			state.current.chordbase = 0
		end
		if (button == state.current.dragging) then
			state.current.dragging = 0
		end
	end
end

-- perform special double click actions
function mouse.double_click(ms)
	if (ms.current.button == BUTTON.WHEELUP or ms.current.button == BUTTON.WHEELDOWN) then return end
	if (ms.current.chordbase ~= ms.current.button) then return end
	-- double clicking, by default, selects the WORD under the cursor
	-- If the cursor is on column 1, start a line selection
	-- same if the cursor is on a newline
	local win, guessedpos, where, row = focus_resolve(ms.current)
	if where == "overlay" then
		if mouse.overlay_click then mouse.overlay_click(row, ms.current) end
		return
	end
	if not guessedpos then return end
	state.press_pos = guessedpos
	local charatpos = win.file:content(guessedpos, 1)

	if (where == "sidebar" or charatpos == "\n") then
		win.selection.pos = guessedpos
		vis.mode = vis.modes.VISUAL_LINE
		vis:feedkeys("0$") -- ensure it always selects the clicked line
	else
		vis.mode = vis.modes.VISUAL
		win.selection.range = win.file:text_object_longword(guessedpos)
	end
end

-- called on mouse chord begin
function mouse.chord(ms)
	if (ms.current.button == BUTTON.WHEELUP or ms.current.button == BUTTON.WHEELDOWN) then return end
	-- Do nothing. See mouse.chord_release instead.
	vis:info("chord detect")
end

-- perform actions for single clicks
function mouse.single_click(ms)
	local button = ms.current.button

	-- the wheel scrolls the window under the pointer and leaves focus (and
	-- an open prompt) alone; it creates no release events and is no click
	if (button == BUTTON.WHEELUP or button == BUTTON.WHEELDOWN) then
		local win = mouse.resolve(ms.current)
		if win then
			win:scroll(button == BUTTON.WHEELDOWN and mouse.wheel_lines or -mouse.wheel_lines)
		end
		return
	end

	-- a right click on its own does nothing (the left+right chord copies)
	if (button == BUTTON.RIGHT) then return end

	local _, gpos, where, row = focus_resolve(ms.current)
	if where == "overlay" then
		if mouse.overlay_click then mouse.overlay_click(row, ms.current) end
		return
	end
	if not gpos then return end
	state.press_pos = gpos

	-- a plain click ends any selection and puts the cursor where it landed;
	-- INSERT and REPLACE keep going at the new position
	vis.win.selection.anchored = false
	if (vis.mode == vis.modes.VISUAL or vis.mode == vis.modes.VISUAL_LINE) then
		vis.mode = vis.modes.NORMAL
	end
	vis.win.selection.pos = gpos

	-- middle click pastes the primary selection at the pointer
	if (button == BUTTON.MIDDLE) then
		local status, paste = vis:pipe("vis-clipboard --paste --selection primary")
		if status == 0 and paste and #paste > 0 then
			vis:insert(paste)
		end
	end
end

-- perform actions for when the mouse is moved with at least one button held down
function mouse.dragged(ms)
	-- a drag stays in the window it started in and needs a press on text
	if not state.press_pos then return end
	local win, pos = mouse.resolve(ms.current)
	if win ~= vis.win or not pos then return end
	if (vis.win.selection.anchored == false) then
		-- just started dragging
		vis.win.selection.anchored = true
	end
	-- preserve VISUAL LINE
	if (vis.mode ~= vis.modes.VISUAL and vis.mode ~= vis.modes.VISUAL_LINE) then
		vis.mode = vis.modes.VISUAL
	end
	vis.win.selection.pos = pos
	-- make sure VISUAL LINE continues to select entire lines
	if (vis.mode == vis.modes.VISUAL_LINE) then
		vis:feedkeys('0$')
	end
end

-- perform actions on mouse release
-- i.e.: call vis-clipboard if mouse.dragging = BUTTON.LEFT
function mouse.release(ms)
	-- just movement, do nothing
	if (ms.current.button == 0) then return end

	local action = ms.current.chordbase
	local selection = vis.win.selection
	local file = vis.win.file

	-- only a drag copies, and only where primary is a selection of its own
	if (mouse.copy_on_select and action == BUTTON.LEFT
		and ms.current.dragging == BUTTON.LEFT and selection.anchored) then
		vis:pipe(file, selection.range, "vis-clipboard --copy --selection primary")
	end
end

-- a button that was pressed while another was held down has been released
function mouse.chord_release(ms)
	local chordbase = ms.current.chordbase
	local button = ms.lastclick.button
	local selection = vis.win.selection
	local file = vis.win.file

	-- cursor moves around in an unexpected fashion
	if (selection.anchored
		and chordbase == BUTTON.LEFT
		and button == BUTTON.RIGHT) then
		-- cut
		vis:pipe(file, selection.range, "vis-clipboard --copy")
		vis:info("Selection copied to clipboard")
	elseif (chordbase == BUTTON.LEFT and button == BUTTON.MIDDLE) then
		-- paste
		local status, paste = vis:pipe("vis-clipboard --paste")
		if status ~= 0 or not paste or #paste == 0 then return end
		local oldpos = selection.pos
		vis:insert(paste)
		local newpos = selection.pos
		-- select the pasted text
		if (oldpos ~= nil and newpos ~= nil) then
			selection.anchored = false
			selection.pos = oldpos
			selection.anchored = true
			selection.pos = newpos
		end

		vis.mode = vis.modes.VISUAL
		vis:info("Clipboard inserted")
	end
end

-- XXX comment/unsubscribe as necessary to customise behaviour.
vis.events.subscribe(vis.events.MOUSE, update_mouse_state)
vis.events.subscribe(events.PRESS, mouse.single_click)
vis.events.subscribe(events.DOUBLE_CLICK, mouse.double_click)
vis.events.subscribe(events.DRAG, mouse.dragged)
vis.events.subscribe(events.RELEASE, mouse.release)
vis.events.subscribe(events.CHORD_RELEASE, mouse.chord_release)

-- ghost cursor: mark the character under the pointer; off by default
mouse.ghost_cursor = false

vis.events.subscribe(vis.events.WIN_HIGHLIGHT, function(win)
	if not mouse.ghost_cursor then return end
	local target, pos = mouse.resolve(state.current)
	if target ~= win or not pos then return end
	local style = mouse.ghost_style or vis.ui.style_ids.SELECTION
	win:style(style, pos, pos)
end)


return mouse
