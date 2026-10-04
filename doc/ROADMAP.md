# Fork roadmap

This fork is a design lab. The owner wants a suckless, Plan 9 inspired
editor that is modal at the core and mouse native at the surface, and
intends to write it from scratch in Zig once the design is known. vis is
the substrate for finding that design by feel: it already has the
selection model and the sam command language the final editor would
borrow, so the open questions are what a mouse layer and a small set of
IDE conveniences feel like on top of a modal core.

The second goal is nearer: replace Neovim as the daily editor. Most of
what Neovim provides is already in vis. What follows is the list of what
is missing, which layer each item lives in, and the order to build them.

## Principles

- The editor stays an editor. Project navigation and file browsing live
  in tmux and nnn (see "Environment" below), so that leaving vis later
  costs nothing. The Zig editor inherits the same environment.
- C changes are primitives, not features. Each one is small, generic,
  and consumed by several Lua features. Features live in Lua.
- Commits follow upstream style so a primitive can go back as a PR.

## Primitives (C side)

**P1. Exact hit test.** `view.c` keeps per-screen-line byte lengths and
per-cell byte counts, and each `UiWin` knows its `x`, `y`, and
`sidebar_width`. A `vis:win_at(line, col)` returning the window and byte
position under a terminal cell makes the mouse exact with line numbers,
tabs, wide characters, soft wrapping, and splits, and deletes the Lua
estimator `guess_mouse_pos` in `lua/vis-mouse.lua`.

**P2. Overlay.** A rectangle of styled cells drawn over the view after
the normal redraw, filled from Lua (position, size, lines, per-line
style). vis has no popup surface today: the drawing surfaces are buffer
cells, one status line per window, and `vis:message`, which opens a
window. The overlay is consumed by F2 completion, F4 leader hints, LSP
hover, mouse context menus, and the F6 picker.

**P3. Styled status segments.** `win:status(left, right)` takes plain
strings and `ui_window_status` paints the line in one style. Let the
string carry style markers (or accept a segment table) so the modeline
can color segments. Content is already fully under Lua control through
`WIN_STATUS`.

**P4. Text changed event.** The Lua API has no event for buffer edits,
so `vis-lspc` resends the whole file before every request. Emit a
`TEXT_CHANGED` event with range and replacement from the C insert and
delete path, then patch lspc to send incremental `didChange`.

**P5. Pending prefix event.** For the leader hint menu, Lua needs to
know when a multi-key sequence is partly typed. `vis:mappings(mode)`
already returns every binding with its help text, so the data exists;
emit a `KEYS_PENDING(prefix)` event from the key processing loop when a
prefix matches bindings but no complete one, and a matching event (or
`nil` prefix) when it resolves or is abandoned.

## Features (Lua side)

**F1. LSP.** `vis-lspc` (fischerling) covers completion, definition,
declaration, references, hover, rename, formatting, and diagnostics,
which is every binding in the owner's Neovim `lsp.lua` (`gd`, `gr`, `K`,
rename, line diagnostics). Configure `ls_map` for the servers in use
(zls, lua-language-server, clangd, gopls, bashls, pyright, marksman).
Servers install by hand onto `PATH`; there is no Mason equivalent and
none is wanted. Improves with P4.

**F2. Completion.** Today lspc completion is a deliberate action rendered
through `vis-menu` or `fzf` at the bottom of the screen. The target is an
as-you-type popup like blink.cmp: `events.INPUT` triggers after a word
character in INSERT, lspc supplies candidates (plus buffer words via
`vis-complete`), and P2 draws the list at the cursor. Nothing preselected;
Enter stays a newline until an item is chosen.

**F3. Modeline.** A `WIN_STATUS` handler producing the lualine layout:
mode, file and modified flag, git branch (cached from a subprocess),
LSP server state, diagnostic counts, position. Nerd-font glyphs work
already since they are plain UTF-8. Color arrives with P3.

**F4. Leader hint menu.** The which-key replacement. On `KEYS_PENDING`
(P5) with a leader prefix, draw an overlay (P2) listing the bindings
under that prefix with their help text from `vis:mappings`, grouped by
the same leader groups as the Neovim config (buffers, code, files, git,
harpoon, projects, search, tools, windows). Every custom `vis:map` call
passes a help string so the menu stays complete.

**F5. Cross-file tracing.** Mostly F1: definition, references, and
`lspc-back` as the jump stack. Add a `:grep`-style command that pipes
`rg --vimgrep` through `fzf` and opens the chosen file at the line, and a
harpoon clone: a per-project table of pinned paths with saved positions,
one key per slot.

**F6. Picker.** Once P2 exists, one fuzzy picker over `fd` output drawn
in the overlay, for the "I know roughly the name" case. This is the only
project-navigation feature inside the editor by design.

## Environment (outside vis)

The owner prefers nnn for browsing and does not want the editor to become
the IDE. The chosen shape is tmux as the IDE shell: one tmux session per
project with panes for vis, nnn, and a shell. Project switching is tmux
session switching, driven by the existing `~/dl/projects.dl` registry.
nnn opens files in `$EDITOR`; sending a path into an already running vis
needs either a small remote command path in the fork or a tmux
`send-keys`. Rejected: porting the Neovim projects and sessions layer into
vis Lua, which would rebuild a file tree inside a buffer.

## Order

1. P1 hit test (cheap, unblocks exact mouse behaviour).
2. P2 overlay (F2, F4, F6, hover, and mouse menus all depend on it).
3. P3 status segments and P4 text changed event (both small).
4. P5 pending prefix event, then F4.
5. F1, F3, F5 can land in parallel with any of the above since they need
   no C changes to be useful.

## Status

Done: `MOUSE` event, termkey SGR `kmous` fix, `vis-mouse.lua` port, P1
hit test as `vis:win_at`, P2 overlay as `vis:overlay_show` and
`vis:overlay_hide` (see `README.mouse.md`). Everything else is open.
