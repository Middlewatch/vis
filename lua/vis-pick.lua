-- Pickers: fzf over lines, files and grep matches, in the editor's terminal.
--
--   pick = require('vis-pick')
--
-- Each picker hands fzf the terminal through a fullscreen vis:pipe and
-- acts on the chosen row. `pick.lines(query)` jumps to a line of the
-- current file; `pick.files()` opens a file under the project root;
-- `pick.grep(query)` live-greps the root with rg as you type and opens
-- the match at its line; `pick.word()` is grep seeded with the word under
-- the cursor; `pick.symbols()` hands over to vis-lspc's symbol window.
-- Files open through `pick.open(path, line)`: a window already showing
-- the file gets focus, otherwise the current window takes the file and
-- the one it showed stays as a hidden buffer. `pick.root()` is
-- the git toplevel of the current file's directory, or that directory.
-- Knobs: `pick.fzf`, `pick.rg`, `pick.fd`, `pick.preview`.
require('vis')

local pick = {}

-- the commands; fzf gets the rows on stdin and prints the chosen one
pick.fzf = "fzf --layout=reverse --info=inline"
pick.rg = "rg --line-number --no-heading --color=never --smart-case"
pick.fd = "fd --type f --hidden --exclude .git"

-- the grep preview, a shell snippet with fzf's {1} (path) and {2} (line);
-- fzf hands them over quoted, so they go through variables first
if os.execute("command -v bat >/dev/null 2>&1") then
	pick.preview = "l={2}; s=$((l > 8 ? l - 8 : 1)); bat --color=always --style=numbers "
	             .. "--highlight-line \"$l\" --line-range \"$s:+30\" {1}"
else
	pick.preview = "l={2}; s=$((l > 8 ? l - 8 : 1)); sed -n \"${s},$((l + 22))p\" {1}"
end

local function sh(s)
	return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- one argument for a : command: sam splits on blanks and reads backslash
-- escapes, so the path goes in double quotes with \ and " escaped
local function arg(s)
	return '"' .. s:gsub('[\\"]', '\\%0') .. '"'
end

local function dir_of(file)
	local path = file and file.path
	if path then return path:match("^(.*)/[^/]*$") or "/" end
	return os.getenv("PWD") or "."
end

-- the git toplevel above the current file, or its directory
function pick.root()
	local dir = dir_of(vis.win.file)
	local status, out = vis:pipe("git -C " .. sh(dir) .. " rev-parse --show-toplevel 2>/dev/null")
	if status == 0 and out and out ~= "" then return (out:gsub("\n$", "")) end
	return dir
end

-- the first line fzf printed, or nil when it was cancelled
local function chosen(status, out)
	if status ~= 0 or not out or out == "" then return nil end
	return out:match("^[^\n]*")
end

-- open path, then put the cursor on line (and col); see the header
function pick.open(path, line, col)
	for win in vis:windows() do
		if win.file and win.file.path == path then
			vis.win = win
			break
		end
	end
	if vis.win.file.path ~= path and not vis:command("e " .. arg(path)) then
		return false
	end
	if line then vis.win.selection:to(line, col or 1) end
	return true
end

function pick.lines(query)
	local file = vis.win.file
	local cmd = "nl -ba -w1 -s'\t' | " .. pick.fzf
	          .. " --delimiter '\t' --with-nth 2.. --tiebreak=index"
	if query and query ~= "" then cmd = cmd .. " --query " .. sh(query) end
	local row = chosen(vis:pipe(file, { start = 0, finish = file.size }, cmd, true))
	local n = row and tonumber(row:match("^(%d+)"))
	if n then vis.win.selection:to(n, 1) end
end

function pick.files()
	local root = pick.root()
	local cmd = "cd " .. sh(root) .. " && " .. pick.fd .. " | " .. pick.fzf
	local row = chosen(vis:pipe(cmd, true))
	if row then pick.open(root .. "/" .. row) end
end

-- rg runs again on every keystroke; an empty query lists nothing
function pick.grep(query)
	local root = pick.root()
	local reload = "[ -n {q} ] && " .. pick.rg .. " -- {q} . || true"
	local cmd = "cd " .. sh(root) .. " && " .. pick.fzf
	          .. " --disabled --delimiter : --query " .. sh(query or "")
	          .. " --bind " .. sh("start:reload:" .. reload)
	          .. " --bind " .. sh("change:reload:" .. reload)
	          .. " --preview " .. sh(pick.preview)
	          .. " --preview-window down,45%"
	local row = chosen(vis:pipe(cmd, true))
	if not row then return end
	local path, line = row:match("^([^:]+):(%d+):")
	if path then pick.open(root .. "/" .. path:gsub("^%./", ""), tonumber(line)) end
end

function pick.word()
	local file, pos = vis.win.file, vis.win.selection.pos
	local range = pos and file:text_object_word(pos)
	local word = range and file:content(range) or ""
	pick.grep((word:match("^%s*(.-)%s*$")))
end

function pick.symbols()
	vis:command("lspc-navigate-symbols")
end

return pick
