# 0001: Files outlive their windows, and a journal on each undo snapshot is the crash recovery

Date: 2026-10-11
Status: accepted

## Context

Upstream vis ties a file's life to its windows: closing the last window
frees the file, `:e other` refuses while the window is modified, and
nothing survives a segfault or a lost terminal. Moving code between files
in a codebase needs the opposite: switch files freely with edits in
flight, and get those edits back after a crash. The fork already keeps
recent files and pins in Lua by path, which covers navigation but not
unsaved text. Three choices had to be made together: which files stay
alive without a window, how unsaved text survives a crash, and what
happens when the last window closes over unsaved work.

## Decision

Every opened file stays in the editor's file list until `:bd` deletes it
or the editor exits (vim's `hidden`); `:e`, `:b` and `:q` hide a file
rather than refusing or freeing it. Unsaved text is journaled to
`$XDG_STATE_HOME/vis/recovery/` each time the editor takes its undo
snapshot (return to NORMAL, insert idle), removed when the file is saved
or explicitly discarded, and offered through `:recover` on the next open.
Closing the last window with any modified file refuses; `:qall!` is the
override and discards the journals.

## Consequences

Switching files never reloads or loses edits, and the recent list
becomes the real buffer list. Memory grows with every file opened in a
session, which is negligible for source files and is bounded by `:bd`.
A journal write happens per edit burst, so files above a size cap are
not journaled. Recovery survives SIGKILL, SIGHUP and power loss without
running any code in a faulting process. We now owe `:ls`, `:b`, `:bd`
and `:recover`, a modified-file check on every exit path, and journal
cleanup on save, discard and reload.

## Considered options

- Keep only modified files hidden: smaller change, but the buffer list
  would differ from the recent list and clean files would reload.
- A SIGSEGV handler dumping modified files (vim's `preserve`): catches
  only crashes, and runs the piece-table code inside the process that
  just faulted. Rejected as the primary mechanism; may be added as a
  last resort later.
- Auto-writing unsaved files to the recovery dir on the last `:q`:
  hides the data-loss moment. Rejected in favour of refusing.
