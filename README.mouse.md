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

    mouse(type, button, line, col, time)

    type    1 press, 2 drag, 3 release, 0 unknown (termkey's enum)
    button  1 left, 2 middle, 3 right, 4 wheel up, 5 wheel down, 0 none
    line    1-based terminal row
    col     1-based terminal column
    time    arrival in milliseconds on a monotonic clock

Motion with no button held arrives as `type == 3, button == 0`; that is
how termkey reports it. Horizontal wheel ticks come through termkey as
unknown and are dropped. `time` exists because vis has no timer and Lua's
`os.time()` counts seconds: it is what makes a double click a matter of
milliseconds rather than "the same cell as last time".

`win:scroll(n)` slides any window's view by `n` lines, positive towards
the end of the file like `<C-e>`, without touching focus; it is what the
wheel uses, so wheeling over a split or over the file while a `:` prompt
is open changes neither focus nor the prompt.

Two UI events bracket the moments vis hands the terminal to someone else:
`vis.events.UI_SUSPEND` fires before `^Z` stops the editor (the terminal
generates SIGTSTP itself under `cbreak()`, so vis catches the signal, runs
the event, then stops for real) and before a fullscreen `vis:pipe`;
`UI_RESUME` fires when vis has the terminal back. `vis-mouse` turns
tracking off and on at those points so the shell never sees motion reports.

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
and `styles` overrides the style per row. A line may also be a list of
segments in the `win:status` shape, `{"key", {" help", id}}`, each
segment's style merged over the row's, so one row can carry several
colors. Lines are cut at the right edge; wide characters are handled and
control characters shown as `^X`.
The overlay is not tied to a window and stays until hidden, so the
feature that showed it decides when it goes. The cursor stays in the
focused window. `vis:win_at` reports a cell on the overlay as
`nil, row, "overlay"` with the 1-based overlay row, and `vis-mouse`
routes a single click there to `mouse.overlay_click(row, state)` instead
of moving the cursor. Completion lists, hint menus, hover text, context
menus and pickers are all meant to draw through it.

Features share the one overlay through `lua/vis-overlay.lua`:

    local overlay = require('vis-overlay')
    overlay.show(me, {x = 0, y = 0, lines = {...}}, function(row, state) end)
    overlay.hide(me)

`show` makes the caller the owner and replaces whatever another owner
drew (nothing is restored later); `hide` by anyone but the owner does
nothing. The optional third argument receives clicks on the box, routed
there by `vis-mouse`'s default `overlay_click`. Hints and completion go
through it, and the completion list accepts the clicked row.

The inverse of the hit test anchors a popup at a file position:

    local x, y = win:coord(pos)

returns the 0-based terminal cell showing `pos` in that window, or `nil`
when it is off screen. The cell reflects the window's last redraw. The
overlay is painted after the `UI_DRAW` event, so a handler there can
place it against the layout of the frame being drawn.

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
on `Vis`. Keys fed with `vis:feedkeys` from outside key processing (a
mouse handler, say) continue a pending prefix rather than running after
it; a nesting counter on `Vis` tells the two cases apart. It is the hook for a which-key style hint menu: on a prefix,
draw the bindings under it from `vis:mappings` in the overlay; on `nil`,
hide it.

## Register event

`vis.events.REGISTER_PUT` fires once after a yank, delete, change or
replace has filled its register:

    register_put(name, op, count)

`name` is the register's one-character name (`"` for the unnamed one,
`+` for the clipboard), `op` one of `"yank"`, `"delete"`, `"change"`,
`"replace"`, and `count` the number of slots written, one per selection.
It is emitted from the operator loop in `vis.c` after `register_resize`,
so it reports the whole operation rather than each cursor, and the content
is already in `vis.registers[name]` (for `+` and `*` it has gone through
vis-clipboard). Puts by sam commands, the search and command registers,
and Lua writes to `vis.registers` do not fire it. It exists so the
editor can say what was copied where, which stock vis never does.

## Modeline

`lua/vis-modeline.lua` is a `WIN_STATUS` handler that builds a
lualine-style bar from status segments:

    modeline = require('vis-modeline')

Sections follow lualine. Left: a is the mode block (focused window
only), b the git branch and LSP diagnostic counts, c the file name with
its modified flag. Right: x holds pending keys or count, selection index,
LSP server name and syntax; y the percentage; z line and column. The branch
comes from `.git/HEAD` (worktrees followed), cached per directory and
re-read every `modeline.git_refresh` seconds, so no subprocess runs. LSP
state is read from vis-lspc's `open_files` table when that module is
loaded; without it those segments are simply absent.

`modeline.colors` holds the style strings: one `{ a, b }` pair per mode
(z and y reuse them) and a `fore` per diagnostic kind, laid over the b
section's background. c, x and the bar itself take the theme's
`STYLE_STATUS_FOCUSED` (`STYLE_STATUS` for unfocused windows), so a
solid bar comes from redefining those two styles. `modeline.separators`
holds the powerline glyphs between sections (`left`, `right`) and
between items of one section (`item_left`, `item_right`); a section
separator needs a `back` on the section it leaves and falls back to a
space. `modeline.symbols` holds the other glyphs. Set all of these in
`visrc.lua` before the first redraw. `modeline.enabled = false` returns
the bar to the default handler.

A modus-vivendi-tinted setup matching lualine's modus theme:

    modeline.colors.normal  = { a = "fore:#1d2235,back:#82b0ec,bold", b = "fore:#82b0ec,back:#393f51,bold" }
    modeline.colors.insert  = { a = "fore:#1d2235,back:#88ca9f,bold", b = "fore:#88ca9f,back:#393f51,bold" }
    modeline.colors.visual  = { a = "fore:#1d2235,back:#caa6df,bold", b = "fore:#caa6df,back:#393f51,bold" }
    modeline.colors.replace = { a = "fore:#1d2235,back:#ff9f80,bold", b = "fore:#ff9f80,back:#393f51,bold" }
    vis.events.subscribe(vis.events.INIT, function()
    	local ui = vis.ui
    	ui:style_define(ui.style_ids.STATUS_FOCUSED, "fore:#f0f0f0,back:#393f51")
    	ui:style_define(ui.style_ids.STATUS, "fore:#969696,back:#292d48")
    end)

The INIT handler runs after vis-std's, which applies the theme, so the
redefinition survives it.

## Leader hints

`lua/vis-hints.lua` is the which-key replacement, the first consumer of
`KEYS_PENDING` and the overlay:

    hints = require('vis-hints')

On a pending prefix it lists the bindings under that prefix from
`vis:mappings(vis.mode)` in a box just above the status line: a title row
with the prefix and its group name, then the entries in columns, each the
next key, `hints.sep` (an arrow) and either its help text or `+group`
when more keys follow; the key and the arrow take `hints.colors.key`
and `hints.colors.sep` over the row. Help longer than
`hints.text_width` cells is cut so several columns fit, and at most `hints.max_rows` rows are drawn, the rest counted in
the title. Group names live in `hints.groups`, keyed by the full sequence; a typed
space reaches the mappings as a literal `" "`, so leader bindings are
mapped as `" ff"`, `" bd"` and so on, and `hints.leader` is that string.
By default only prefixes starting with the leader open the box
(`hints.triggers`); set it to `nil` for every prefix, `g` and `<C-w>`
included. A click on an entry types its key. The box goes when the
prefix resolves or is abandoned. There is
no delay: vis has no timer, so the box appears on the first key. Terminal
size comes from `vis.ui.width` and `vis.ui.height`, a one-line addition
in `vis-lua.c` that the box needs to anchor itself. `hints.anchor` is
`"bottom"` (full width above the status line) or `"center"`, a block in
the middle of the screen no wider than its columns, placed with
`overlay.center(width, height)` from `vis-overlay.lua`.

The leader map itself lives in `~/.config/vis/visrc.lua`, grouped the
Doom Emacs way (`b` buffers, `c` code, `f` files, `g` git, `h` harpoon,
`q` quit, `s` search, `t` toggles, `w` windows), with the top-level
shortcuts `Space Space` (find file), `Space ,` (recent file) and
`Space /` (grep). Every entry is a plain `vis:map` with a help string,
which is what the box displays, so the config is the menu.

## Completion

`lua/vis-completion.lua` is the as-you-type list, drawn in the overlay
under the word being typed:

    completion = require('vis-completion')

Typing a word character in INSERT opens it with the language server's
items (through vis-lspc, when a server runs for the file) followed by
words of the file; typing on narrows it. `<C-n>` and `<C-p>` walk the
rows and past either end nothing is chosen again; `<Enter>` inserts the
chosen item and stays a line break while nothing is chosen. A key that
ends the word, or leaving INSERT, closes it; `<C-n>` on a closed list
opens it by hand, and a server trigger character such as `.` opens it
with the server's items alone. Server items arrive asynchronously and
are filtered by the typed prefix on the client, case-insensitively;
snippets lose their placeholders (`${1:x}` keeps `x`). Each row shows
the label and its kind, the kind in `completion.colors.kind` (dim by
default). Knobs: `completion.keys`, `completion.colors`,
`completion.max_rows`, `completion.min_chars`, `completion.buffer_words`
and `completion.max_scan` (files over that size give no buffer words).

It needs `lspc.complete(win, on_result, trigger)` and the `on_result`
request context, both on the fork's `incremental-sync` branch of
vis-lspc (see LSP below); without lspc the file's words still complete.

## Registers

`lua/vis-registers.lua` consumes `REGISTER_PUT`. Each put is reported
on the info line, as in `yank 22 lines → "+`, and kept in
`registers.last`, which `vis-modeline` shows in its x section as
`"+ 22L` until the next put. `registers.toggle()` draws a centered
overlay listing every filled register (the special ones in
`registers.names`, then `a`-`z`) with its size and first line; a click on
a row puts that register after the cursor. Reading `+` and `*` costs a
vis-clipboard call each.

## Pickers

`lua/vis-pick.lua` runs fzf through a fullscreen `vis:pipe` and acts on
the chosen row: `pick.lines()` jumps to a line of the current file
(`nl` feeds the numbered file to fzf), `pick.files()` opens a file under
the project root (`fd`), `pick.grep(query)` live-greps the root with
`rg` on every keystroke and opens the match at its line with a `bat` or
`sed` preview, `pick.word()` seeds grep with the word under the cursor.
`pick.root()` is the git toplevel of the current file's directory, or
that directory. `pick.open(path, line)` is the one way files get opened
from Lua here: a window already showing the file takes focus, otherwise
`:e` replaces the current window when it may be closed and `:open`
splits when it may not.

## Files

`lua/vis-files.lua` keeps `files.recent`, the paths shown in a focused
window this session (bumped from `UI_DRAW`, most recent first), with
`files.pick_recent()` as the fzf over them and `files.alternate()` as
the jump to the previous one. Pins are a numbered per-project list in
the harpoon style: `files.pin(n)`, `files.jump(n)`, `files.unpin()`,
and `files.toggle()` for a centered overlay where a click jumps. They
are stored as `line<Tab>path` rows in `$XDG_STATE_HOME/vis/pins/<root
with / as %>`, so they survive restarts and crashes. `files.pick_buffers()`
is fzf over `vis:files()`, hidden ones marked, and switches with `:b`.

## Buffers and recovery

Upstream frees a file with its last window and refuses `:e` while the
window is modified. The fork keeps every opened file in the editor's
list until `:bd` or exit (vim's `hidden`; the decision and its
alternatives are in `doc/adr/0001`). `vis_file_unref` is what a closing
window calls; it frees only internal files, and an unnamed untouched
file, since there is nothing to keep. `vis_file_free` frees for real and
fires `FILE_CLOSE`, so plugins see a file close once, at `:bd` or exit.
Each file carries a stable `number` (also `file.number` in Lua) and the
cursor of the last window that showed it, restored when it is shown
again.

    :ls              number, % current, a shown or h hidden, + modified, name
    :b N | :b name   show that buffer here (exact path or name, or a unique substring)
    :bd[!] [buffer]  delete it; its windows move to another buffer
    :recover[!]      load this file's journal, or drop it

`:e other` and `:b` hide the current file; `:q` closes the window and
hides its file, and on the last window it is the exit, which refuses
while any file is modified; `:qall` refuses likewise, naming the file,
and `:qall!` (or `:q!` on the last window) exits and drops the
journals. `:q!` on a window that is not the last only hides the file;
`:bd!` is the way to throw a modified buffer away.

The recovery journal, `vis-recovery.c`: a named file whose text changed
since the last journal is written whole to
`$XDG_STATE_HOME/vis/recovery/<path with / as %>` (temporary file and
rename) every time the editor takes its undo snapshot, which is on the
return to NORMAL and on insert idle, so a crash loses at most the
current edit burst. Files above 8 MiB are skipped. The journal goes when
the file is saved, when undo brings it back to the saved state, when an
unmodified file is freed, and on an explicit discard (`:e!`, `:bd!`,
`:qall!`); a `vis_die` exit (SIGTERM, SIGHUP, a mainloop error) keeps
it. Opening a file that has a journal says so on the info line;
`:recover` replaces the text with the journal, leaving the file modified
for `:w`. Unnamed files are not journaled.

## LSP

The fork carries no LSP code. It uses vis-lspc
(<https://codeberg.org/muhq/vis-lspc>, GPL-3.0; the GitHub repository is
abandoned), copied into `~/.config/vis/plugins/vis-lspc` and loaded with
`lspc = require('plugins/vis-lspc')`. The vet before adopting it: one
maintainer with occasional contributors, commits every month or two
through 2026-10, releases tagged, the LICENSE file is GPL-3 verbatim
with a public-domain `json.lua`, and it needs only `vis:communicate`,
which upstream has had since 0.9. The bus factor is the noted risk.

The copy carries two local patches. The first: when
`vis.events.TEXT_CHANGED` exists and the server asked for incremental
synchronization, each change goes out as one ranged `didChange` and the
whole-file resend before every request is skipped; an undo marks the
file stale and the next request sends it whole. Servers that want full
synchronization and a vis without the event behave as before. The
second hands a request's raw method result to its `on_result`
callback. Both stay local: vis-lspc's README forbids contributions
created or modified with an LLM, and these were. The owner's dotfiles
keep the copy as plain files with the patches beside it.

Servers come from `PATH`. lspc preconfigures zls, lua-language-server,
clangd, gopls and bash-language-server; `~/.config/vis/visrc.lua` adds
pyright and marksman. One quirk of running the fork from its build
directory: `vis_lua_path_add` prepends, so the binary-relative `lua/`
outranks `~/.config/vis` and upstream's sample `lua/visrc.lua` shadows
the user's. `VIS_PATH=~/.config/vis` outranks both.

Nothing is reported until something enables mouse tracking in the
terminal. `lua/vis-mouse.lua` does that on `START` (`\e[?1003h` for all
motion, `\e[?1006h` for SGR encoding) and turns it off on `QUIT`.

`external/termkey.c` carries one fix: terminfo entries such as
`xterm-256color` advertise `key_mouse` as the SGR introducer `\E[<`,
which termkey treated as an X10 prefix and truncated every report. That
entry is now skipped so the CSI parser handles SGR reports. This was the
xterm and urxvt breakage reported against the original patch.

## Building

`bin/install [PREFIX]` runs `./configure --prefix`, `make` and
`make install`; the default prefix is `~/.local`, so the binary lands
in `~/.local/bin/vis` and the Lua runtime in `~/.local/share/vis`. It
needs a C compiler, make, Lua 5.x and ncursesw headers, and LPeg for
that Lua at run time; on Fedora
`sudo dnf install gcc make lua-devel ncurses-devel lua-lpeg`. User
config in `~/.config/vis` is searched before the share directory. To
run the tree without installing, `./vis` works after `make`, but the
`lua/` beside the binary is searched first, so point `VIS_PATH` at
the config directory to keep its `visrc.lua` from being shadowed by
the sample one.

## Using it

Add to `visrc.lua`:

    mouse = require('vis-mouse')

Defaults, in `lua/vis-mouse.lua`:

- Wheel scrolls the window under the pointer by `mouse.wheel_lines`
  (1) without moving focus; it works in every mode, INSERT included.
- Left click moves the cursor and focuses the window under the pointer.
  It ends any selection; INSERT and REPLACE continue at the new
  position. A click off the open `:` prompt abandons it as `Escape`
  would, also after a failed command.
- Drag selects (VISUAL) and stays in the window it started in; a drag
  that begins on a status bar selects nothing. Release copies to the
  primary selection via `vis-clipboard` when `mouse.copy_on_select` is
  on. It defaults from `vis-clipboard --backend`: on with a Wayland or
  X primary, off under OSC 52, where primary and clipboard are the same
  thing and tmux keeps a paste buffer of every write besides. Set it to
  `true` or `false` in `visrc.lua` to decide yourself.
- Double click (two presses on one cell within `mouse.double_click_ms`,
  400) selects the WORD under the pointer, or the whole line when it
  lands on a newline or in the line-number sidebar. It copies nothing;
  a third press is a single click again.
- Middle click moves the cursor there and inserts the primary
  selection. Right click on its own does nothing.
- Chords: right click while dragging copies to the clipboard; middle
  click while dragging inserts the clipboard.
- `:set mouse off` stops tracking.

`mouse.ghost_cursor = true` marks the character under the pointer in
whichever window it is over, styled as a selection by default
(`mouse.ghost_style`). It is off by default; it was built as a hit-test
check.

## Known limits

Splits: a drag that leaves its window is ignored rather than clamped.
A click on the prompt line itself does nothing; the prompt is reached
with `:` and left with `Escape`, `Enter` or a click elsewhere.
The ghost cursor needs a redraw to move, so it lags motion over a window
that has nothing else to redraw.

Tested in tmux and a raw pty with `TERM=xterm-256color`. Reports from
other terminals are welcome.
