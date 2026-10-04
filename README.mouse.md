# Mouse support

This fork adds experimental mouse support to vis. It is a lab for working
out what a mouse-native modal editor should feel like, not a finished
feature; the API and defaults change without notice.

The work starts from dther's `mouse-patch-v0`
(<https://github.com/dther/vis>), re-ported onto current upstream.

## How it works

The C side is small. termkey already parses terminal mouse reports; vis
used to format them as key strings and push them into the input queue.
Now `getkey()` in `vis.c` turns a `TERMKEY_TYPE_MOUSE` key into a
`VIS_EVENT_MOUSE` and the Lua side receives it as `vis.events.MOUSE`:

    mouse(type, button, line, col)

    type    1 press, 2 drag, 3 release, 0 unknown (termkey's enum)
    button  1 left, 2 middle, 3 right, 4 wheel up, 5 wheel down, 0 none
    line    1-based terminal row
    col     1-based terminal column

Motion with no button held arrives as `type == 3, button == 0`; that is
how termkey reports it.

The hit test lives in C too. `vis:win_at(line, col)` takes the same
1-based terminal cell and returns the window under it, the file position
of that cell (`nil` on the status bar), and which part of the window was
hit: `"text"`, `"sidebar"` or `"status"`. It reads the screen layout
`view.c` already keeps (per-line byte lengths, per-cell byte counts,
window origin and sidebar width), so it is exact with line numbers,
tabs, wide characters, soft wrapping and splits. Columns past the end of
a line map to its last cell, rows below the text to the last line.

Nothing is reported until something enables mouse tracking in the
terminal. `lua/vis-mouse.lua` does that on `START` (`\e[?1003h` for all
motion, `\e[?1006h` for SGR encoding) and turns it off on `QUIT`.

`external/termkey.c` carries one fix: terminfo entries such as
`xterm-256color` advertise `key_mouse` as the SGR introducer `\E[<`,
which termkey treated as an X10 prefix and truncated every report. That
entry is now skipped so the CSI parser handles SGR reports. This was the
xterm and urxvt breakage reported against the original patch.

## Using it

Add to `visrc.lua`:

    mouse = require('vis-mouse')

Defaults, in `lua/vis-mouse.lua`:

- Wheel scrolls (`<C-y>` / `<C-e>`).
- Click moves the cursor and focuses the window under the pointer; in
  INSERT it also returns to NORMAL. The wheel scrolls the window under
  the pointer, focusing it.
- Drag selects (VISUAL) and stays in the window it started in. Release
  copies to the X PRIMARY selection via `vis-clipboard`.
- Double click selects the WORD under the pointer, or the whole line
  when the click lands on a newline or in the line-number sidebar.
- Chords: right click while dragging copies to the clipboard; middle
  click while dragging inserts the clipboard.
- `:set mouse off` stops tracking.

A "ghost cursor" marks the character under the pointer in whichever
window it is over, styled as a selection by default (`mouse.ghost_style`).

## Known limits

Splits: a drag that leaves its window is ignored rather than clamped.
The ghost cursor needs a redraw to move, so it lags motion over a window
that has nothing else to redraw.

Tested in tmux and a raw pty with `TERM=xterm-256color`. Reports from
other terminals are welcome.
