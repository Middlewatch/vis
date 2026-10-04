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

## Overlay

vis draws into buffer cells, one status line per window, and the info
line; there was no surface for a popup. The fork adds one overlay, a
rectangle of styled text painted over the windows after every redraw:

    vis:overlay_show{x = 4, y = 2, lines = {"first", "second"},
                     width = 20, height = 3, style = id, styles = {id1, id2}}
    vis:overlay_hide()

`x` and `y` are 0-based terminal cells like `win:style_pos`. `width`
defaults to the widest line and `height` to the number of lines; rows
without a line are filled in `style` (default `ui.style_ids.STATUS`),
and `styles` overrides the style per row. Lines are cut at the right
edge; wide characters are handled and control characters shown as `^X`.
The overlay is not tied to a window and stays until hidden, so the
feature that showed it decides when it goes. The cursor stays in the
focused window. `vis:win_at` reports a cell on the overlay as
`nil, row, "overlay"` with the 1-based overlay row, and `vis-mouse`
routes a single click there to `mouse.overlay_click(row, state)` instead
of moving the cursor. Completion lists, hint menus, hover text, context
menus and pickers are all meant to draw through it.

## Status segments

`win:status(left, right)` still takes two strings. Either part may also
be a list of segments, each a string or a `{text, style_id}` table:

    win:status({ {" NORMAL ", mode_id}, " " .. win.file.name },
               { {"12:3", pos_id} })

Plain text takes the status style. A segment style is merged over it, so
a style setting only `fore` keeps the status background; with the
default theme's `reverse` status set both `fore` and `back`. The C side
is one primitive, `ui_window_status_segment`, which paints a run of
cells in a style; the Lua binding does the layout.

## Text changed event

`vis.events.TEXT_CHANGED` fires for every modification of a non-internal
file:

    text_changed(file, pos, deleted, inserted)

For an insertion it arrives after the data is in place with `deleted`
0. For a deletion it arrives before the bytes go, with `inserted` `nil`,
so `file:content(pos, deleted)` still returns them and a handler can
turn the range into line and column coordinates. After undo, redo,
`:earlier` or `:later` it arrives once with `pos` `nil`: the range is
unknown and the file should be reread. Do not modify the file from the
handler. The hook lives in `text.c` (`text_on_change`), so every path
that edits a `Text` reports, including sam commands and Lua `file:insert`.

## Pending keys event

`vis.events.KEYS_PENDING` reports a half-typed key sequence:

    keys_pending(prefix)

It fires with the typed keys when they are a prefix of at least one
binding in the current mode but no complete one, so the editor is
waiting for more input, and once with `nil` when that prefix resolves to
a binding or is abandoned. Keys a binding itself waits for (the character
after `f`, the register after `"`) are not reported. The check runs at
the end of `vis_keys_process` in `vis.c`, which already knows whether
what remains in the input queue is ambiguous, so the event costs one flag
on `Vis`. It is the hook for a which-key style hint menu: on a prefix,
draw the bindings under it from `vis:mappings` in the overlay; on `nil`,
hide it.

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
