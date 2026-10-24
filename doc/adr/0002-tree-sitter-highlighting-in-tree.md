# 0002: Tree-sitter highlighting with the binding compiled into vis

Date: 2026-10-23
Status: accepted

## Context

LPeg lexers highlight one token at a time, so `std.Io.File` and
`print(` read as identifiers, and 84 of the shipped lexers predate the
tag API that would even let a theme tell a method from a builtin. The
owner reads code in several languages to learn them and wants one
colour vocabulary across all of them; tree-sitter grammars and
nvim-treesitter's queries provide exactly that. The binding between
tree-sitter and this editor's Lua had to live somewhere: compiled into
vis, built as a separate Lua C module, or taken from ltreesitter.

## Decision

A small binding (`vis-treesitter.c`, languages, parsers, trees, queries)
is compiled into vis behind `--enable-tree-sitter`, the same way TRE and
LPeg are optional dependencies. Everything else is Lua
(`lua/vis-treesitter.lua`): predicate evaluation, query loading with
pattern dropping, capture-to-style mapping, and incremental edits fed
from the fork's `TEXT_CHANGED` event. Grammars and queries are runtime
files in the directories neovim packaging already uses. Languages
without a grammar fall back to their LPeg lexer.

## Consequences

One `make install` ships the feature; the parser reads the piece table
directly with no copy of the file, and a redraw costs an incremental
reparse plus one query over the viewport. The fork now owns about five
hundred lines of C against the tree-sitter API and must track its ABI
range when grammars update. Queries written for a different grammar
revision lose their rejected patterns rather than failing, which
`:treesitter` makes visible. Injections (Lua inside Markdown fences) and
`locals.scm` scope refinement are out until a case needs them.

## Considered options

- Separate Lua C module in `~/.local/lib/lua/5.5/`: keeps the fork's C
  untouched, but adds a second build and `package.cpath` setup, and
  incremental parsing already depends on this fork's `TEXT_CHANGED`, so
  portability to stock vis was not on offer.
- ltreesitter: 4.4k lines of generic binding that compiles its own copy
  of tree-sitter, needs luarocks, and was untested on Lua 5.5; we need
  about a tenth of its surface.
- LSP semantic tokens: the most accurate signal where a server runs,
  but vis-lspc has no support and most browsing happens without one.
