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

-- resolve the terminal cell under the mouse: window, file position (nil on
-- the status bar) and which part of the window was hit ("text", "sidebar"
-- or "status"). On the overlay the window and position are nil, the part
-- is "overlay" and the 1-based overlay row follows as a fourth value.
function mouse.resolve(m)
	local win, pos, where = vis:win_at(m.line, m.col)
	if where == "overlay" then return nil, nil, where, pos end
	return win, pos, where
end

-- called with the 1-based overlay row and the mouse state when a single
-- click lands on the overlay; whoever shows the overlay sets this
mouse.overlay_click = nil

-- like mouse.resolve, but also focus the window under the mouse
local function focus_resolve(m)
	local win, pos, where = mouse.resolve(m)
	if win and win ~= vis.win then
		vis.win = win
	end
	return win, pos, where
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

vis.events.subscribe(vis.events.START, mouse.activate)

-- deactivate mouse detection
function mouse.deactivate()
	io.write("\x1b[?1003l")
	io.write("\x1b[?1006l")
	io.flush()
end

vis.events.subscribe(vis.events.QUIT, mouse.deactivate)

-- set mouse.state appropriately and emit vis events for common operations
function update_mouse_state(event, button, line, col)
	state.last = state.current
	state.current = {}
	state.current.event = event
	state.current.button = button
	state.current.line = line
	state.current.col = col
	state.current.dragging = state.last.dragging
	state.current.chordbase = state.last.chordbase

	if (event == MOUSE_EVENT.PRESSED) then
		-- wheel movements don't produce release events
		if (button ~= BUTTON.WHEELUP
			and button ~= BUTTON.WHEELDOWN) then
			state.pressed[button] = true
			if (state.current.chordbase == 0) then
				state.current.chordbase = button
			end
		end

		if (state.lastclick.button == button
			and state.lastclick.col == col
			and state.lastclick.line == line) then
			vis.events.emit(events.DOUBLE_CLICK, state)
		elseif (state.current.chordbase ~= button
			and button ~= BUTTON.WHEELUP
			and button ~= BUTTON.WHEELDOWN) then
			vis.events.emit(events.CHORD_PRESS, state)
		else
			vis.events.emit(events.PRESS, state)
		end

		-- After executing appropriate action
		if (button ~= BUTTON.WHEELUP
			and button ~= BUTTON.WHEELDOWN) then
			state.lastclick = state.current
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
function mouse.double_click(state)
	if (state.current.button == BUTTON.WHEELUP or state.current.button == BUTTON.WHEELDOWN) then return end
	if (state.current.chordbase ~= state.current.button) then return end
	-- double clicking, by default, selects the WORD under the cursor
	-- If the cursor is on column 1, start a line selection
	-- same if the cursor is on a newline
	local win, guessedpos, where = focus_resolve(state.current)
	if not guessedpos then return end
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
function mouse.chord(mouse)
	if (mouse.button == BUTTON.WHEELUP or mouse.button == BUTTON.WHEELDOWN) then return end
	-- Do nothing. See mouse.chord_release instead.
	vis:info("chord detect")
end

-- perform actions for single clicks
function mouse.single_click(state)
	-- wheel motions don't create release events and aren't clicks
	if (state.current.button == BUTTON.WHEELUP) then
		focus_resolve(state.current)
		vis:feedkeys("<C-y>")
		return
	elseif (state.current.button == BUTTON.WHEELDOWN) then
		focus_resolve(state.current)
		vis:feedkeys("<C-e>")
		return
	end

	local _, gpos, where, row = focus_resolve(state.current)
	if where == "overlay" then
		if mouse.overlay_click then mouse.overlay_click(row, state.current) end
		return
	end
	if not gpos then return end
	local currange = vis.win.selection.range

	-- remove anchor and enter normal if click outside the original selection
	if (gpos < currange.start or gpos > currange.finish) then
		vis.win.selection.anchored = false
		vis.mode = vis.modes.NORMAL
	end

	vis.win.selection.pos = gpos

	-- ensure visual line acts as expected
	if (vis.mode == vis.modes.VISUAL_LINE) then
		vis:feedkeys("0$")
	end
end

-- perform actions for when the mouse is moved with at least one button held down
function mouse.dragged(state)
	-- a drag stays in the window it started in
	local win, pos = mouse.resolve(state.current)
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
function mouse.release(state)
	-- just movement, do nothing
	if (state.current.button == 0) then return end

	local action = state.current.chordbase
	local selection = vis.win.selection
	local file = vis.win.file

	if (action == BUTTON.LEFT and selection.anchored) then
		vis:pipe(file, selection.range, "vis-clipboard --copy --selection primary")
	end
end

-- a button that was pressed while another was held down has been released
function mouse.chord_release(state)
	local chordbase = state.current.chordbase
	local button = state.lastclick.button
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
		local _, paste = vis:pipe("vis-clipboard --paste")
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

vis.events.subscribe(vis.events.WIN_HIGHLIGHT, function(win)
	-- draw the ghost cursor in whichever window the pointer is over
	local target, pos = mouse.resolve(state.current)
	if target ~= win or not pos then return end
	local style = mouse.ghost_style or vis.ui.style_ids.SELECTION
	win:style(style, pos, pos)
end)


return mouse
