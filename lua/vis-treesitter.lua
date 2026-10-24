-- Tree-sitter syntax highlighting.
--
-- vis.lua loads this module before vis-std when the binary was built with
-- --enable-tree-sitter (the C half is package.preload.treesitter, see
-- vis-treesitter.c). vis-std's WIN_HIGHLIGHT handler calls highlight(win)
-- first and runs the LPeg lexer only when that returns false, so a syntax
-- without an installed grammar keeps its old highlighting.
--
-- Grammars are the shared objects distributions install for neovim
-- (/usr/lib/tree_sitter/<name>.so exporting tree_sitter_<name>). Queries
-- are nvim-treesitter style highlights.scm files, looked up first under
-- $XDG_CONFIG_HOME/vis/queries/<name>/ and then under
-- /usr/share/tree-sitter/queries/<name>/; a leading "; inherits: a,b"
-- line pulls in those languages' files first. A pattern the installed
-- grammar does not understand (a node type from a newer or older grammar)
-- is dropped rather than failing the whole file; :treesitter lists them.
--
-- A capture @a.b.c takes the theme's STYLE_A_B_C, falling back to
-- STYLE_A_B and then STYLE_A, the same convention vis.lua applies to lexer
-- tags, so one palette serves both engines. Later patterns and inner nodes
-- win when captures overlap, as in neovim.
--
-- The tree is kept per file and edited through TEXT_CHANGED, so a redraw
-- costs an incremental reparse plus one query over the viewport.

local core = require('treesitter')

local M = { core = core }

local home = os.getenv('HOME') or ''
local config = os.getenv('XDG_CONFIG_HOME') or (home .. '/.config')

--- Grammar locations tried in order, with %s for the grammar name. The
-- tree_sitter/ directory is neovim's layout; the libtree-sitter-<name>
-- form is what grammar packages install when they skip the symlink.
M.grammar_paths = {
	home .. '/.local/lib/tree_sitter/%s.so',
	'/usr/local/lib/tree_sitter/%s.so',
	'/usr/lib/tree_sitter/%s.so',
	'/usr/local/lib/libtree-sitter-%s.so',
	'/usr/lib/libtree-sitter-%s.so',
}

--- Directories searched for <name>/highlights.scm, in order.
M.query_dirs = {
	config .. '/vis/queries',
	'/usr/local/share/tree-sitter/queries',
	'/usr/share/tree-sitter/queries',
}

--- Syntax name to grammar name, for the few that differ. Unlisted
-- syntaxes use their own name.
M.languages = {}

--- Files above this size keep the LPeg lexer (a full parse happens on
-- open and after every undo).
M.max_bytes = 2 * 1024 * 1024

--- Capture names that never style text.
M.ignored_captures = { spell = true, nospell = true, conceal = true, none = true }

--- Predicates seen that this module cannot evaluate; such patterns apply
-- unconditionally. For :treesitter.
M.unsupported_predicates = {}

local languages = {}   -- grammar name -> language or false
local queries = {}     -- grammar name -> { query, captures, predicates, dropped, paths } or false
local styles = {}      -- capture name -> style id or false
local states = setmetatable({}, { __mode = 'k' })  -- file -> state

local function read_file(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local data = f:read('a')
	f:close()
	return data
end

local function find_file(dirs, rel)
	for _, dir in ipairs(dirs) do
		local path = dir .. '/' .. rel
		local f = io.open(path, 'rb')
		if f then
			f:close()
			return path
		end
	end
end

local function load_language(name)
	local lang = languages[name]
	if lang ~= nil then return lang or nil end
	local path, err
	for _, pattern in ipairs(M.grammar_paths) do
		local candidate = pattern:format(name)
		local f = io.open(candidate, 'rb')
		if f then
			f:close()
			path = candidate
			break
		end
	end
	if path then
		lang, err = core.language(path, name)
	end
	if lang then
		languages[name] = { lang = lang, path = path }
	else
		languages[name] = false
		if err then vis:info('treesitter: ' .. err) end
	end
	return languages[name] or nil
end

-- query source for name with its inherited sources prepended
local function query_source(name, paths, seen)
	seen = seen or {}
	if seen[name] then return '' end
	seen[name] = true
	local path = find_file(M.query_dirs, name .. '/highlights.scm')
	if not path then return nil end
	local src = read_file(path)
	paths[#paths + 1] = path
	local parts = {}
	for list in src:gmatch(';+[ \t]*inherits[ \t]*:[ \t]*([%w_, \t]+)') do
		for parent in list:gmatch('[%w_]+') do
			parts[#parts + 1] = query_source(parent, paths, seen) or ''
		end
	end
	parts[#parts + 1] = src
	return table.concat(parts, '\n')
end

-- spans of the top-level patterns in src, as {first, last} byte indices
-- (one-based, inclusive), each extended over its trailing captures and
-- quantifiers so blanking a span leaves a valid query
local function pattern_spans(src)
	local spans, depth, first, i, n = {}, 0, nil, 1, #src
	while i <= n do
		local c = src:sub(i, i)
		if c == ';' then
			i = (src:find('\n', i, true) or n + 1) - 1
		elseif c == '"' then
			i = i + 1
			while i <= n do
				local d = src:sub(i, i)
				if d == '\\' then i = i + 1 elseif d == '"' then break end
				i = i + 1
			end
		elseif c == '(' or c == '[' then
			if depth == 0 then first = i end
			depth = depth + 1
		elseif c == ')' or c == ']' then
			depth = depth - 1
			if depth == 0 and first then
				local j = src:match('^%s*()', i + 1)
				while true do
					local tok = src:match('^[+*?]', j) or src:match('^@[%w_.]+', j)
					if not tok then break end
					j = src:match('^%s*()', j + #tok)
				end
				spans[#spans + 1] = { first, j - 1 }
				first = nil
			end
		end
		i = i + 1
	end
	return spans
end

-- compile src for lang, blanking patterns the grammar rejects. Blanking
-- keeps every byte offset, so the spans are computed once.
local function compile(lang, src)
	local dropped = {}
	local spans = pattern_spans(src)
	for _ = 1, 200 do
		local query, kind, offset = core.query(lang, src)
		if query then return query, dropped end
		local pos = offset + 1
		local span
		for _, s in ipairs(spans) do
			if s[1] <= pos and pos <= s[2] then span = s break end
		end
		if not span then
			return nil, string.format('%s error at byte %d', kind, offset)
		end
		local text = src:sub(span[1], span[2])
		dropped[#dropped + 1] = string.format('%s: %s', kind, text:match('^[^\n]*'))
		src = src:sub(1, span[1] - 1) .. text:gsub('[^\n]', ' ') .. src:sub(span[2] + 1)
	end
	return nil, 'too many rejected patterns'
end

local function load_query(name, lang)
	local q = queries[name]
	if q ~= nil then return q or nil end
	local paths = {}
	local src = query_source(name, paths)
	q = false
	if src then
		local query, dropped = compile(lang, src)
		if query then
			q = {
				query = query,
				captures = query:captures(),
				predicates = query:predicates(),
				dropped = dropped,
				paths = paths,
			}
		else
			vis:info(string.format('treesitter: %s highlights: %s', name, dropped))
		end
	end
	queries[name] = q
	return q or nil
end

-- style string for a theme entry, as vis.lua does for lexer tags
local function style_string(style)
	if type(style) == 'table' then
		local s
		if style.attr then s = tostring(style.attr) end
		if style.fore then s = (s and s .. ',' or '') .. 'fore:' .. tostring(style.fore) end
		if style.back then s = (s and s .. ',' or '') .. 'back:' .. tostring(style.back) end
		return s or ''
	end
	return style
end

-- style id for a capture name, or false when nothing styles it
local function style_for(name)
	local id = styles[name]
	if id ~= nil then return id end
	id = false
	if not M.ignored_captures[name] and name:sub(1, 1) ~= '_' then
		local tag = name
		while tag ~= '' do
			local style = vis.lexers['STYLE_' .. tag:upper():gsub('%.', '_')]
			if style ~= nil then
				local ui = vis.ui
				local style_id = ui.style_ids[tag] or ui:style_push()
				if style_id then
					ui.style_ids[tag] = style_id
					ui:style_define(style_id, style_string(style))
					id = style_id
				end
				break
			end
			tag = tag:match('^(.*)%.[^.]*$') or ''
		end
	end
	styles[name] = id
	return id
end

--- Forget resolved styles; the theme changed.
function M.reset_styles()
	styles = {}
end

-- a very small regex to Lua pattern translation for #match?; nil when
-- the regex uses features Lua patterns lack
local regex_cache = {}
local function regex_patterns(re)
	local cached = regex_cache[re]
	if cached ~= nil then return cached or nil end
	local patterns = {}
	if re:find('[()]') then
		patterns = false
	else
		for alt in (re .. '|'):gmatch('(.-)|') do
			local p = alt:gsub('\\([dDsSwW])', '%%%1'):gsub('\\(%p)', '%%%1')
			patterns[#patterns + 1] = p
		end
	end
	regex_cache[re] = patterns
	return patterns or nil
end

local function match_regex(text, re)
	local patterns = regex_patterns(re)
	if not patterns then
		M.unsupported_predicates['match? ' .. re] = true
		return true
	end
	for _, p in ipairs(patterns) do
		local ok, found = pcall(string.find, text, p)
		if ok and found then return true end
	end
	return false
end

-- evaluate one predicate; texts(id) gives the matched text of each node
-- captured under id in this match
local function predicate_holds(pred, texts)
	local name = pred[1]
	if name:sub(-1) == '!' then return true end  -- directive (#set!, #offset!)
	local negate, any = false, false
	if name:sub(1, 4) == 'not-' then negate, name = true, name:sub(5) end
	-- structural predicates were already decided by query:exec
	if name == 'has-parent?' or name == 'has-ancestor?' then return true end
	-- any-of? is its own predicate; any- is otherwise a quantifier prefix
	if name ~= 'any-of?' and name:sub(1, 4) == 'any-' then any, name = true, name:sub(5) end

	local test
	if name == 'eq?' then
		test = function(text)
			local other = pred[3]
			if type(other) == 'number' then other = texts(other)[1] end
			return text == other
		end
	elseif name == 'lua-match?' then
		test = function(text)
			local ok, found = pcall(string.find, text, pred[3])
			return ok and found ~= nil
		end
	elseif name == 'match?' then
		test = function(text) return match_regex(text, pred[3]) end
	elseif name == 'any-of?' then
		test = function(text)
			for i = 3, #pred do if text == pred[i] then return true end end
			return false
		end
	elseif name == 'contains?' then
		test = function(text)
			for i = 3, #pred do if text:find(pred[i], 1, true) then return true end end
			return false
		end
	else
		M.unsupported_predicates[name] = true
		return true
	end

	local subjects = type(pred[2]) == 'number' and texts(pred[2]) or { pred[2] }
	local holds
	if any then
		holds = false
		for _, text in ipairs(subjects) do
			if test(text) then holds = true break end
		end
	else
		holds = true
		for _, text in ipairs(subjects) do
			if not test(text) then holds = false break end
		end
	end
	if negate then holds = not holds end
	return holds
end

-- zero-based row and byte column of a file offset
local function point(file, pos)
	local line = file:line_column_from_offset(pos)
	local line_start = file:offset_from_line_column(line) or pos
	return line - 1, pos - line_start
end

local function state_for(win)
	local file, syntax = win.file, win.syntax
	if not file or not syntax then return nil end
	local state = states[file]
	if state and state.syntax == syntax then return state end
	state = { syntax = syntax, dirty = true }
	states[file] = state
	local name = M.languages[syntax] or syntax
	local lang = load_language(name)
	if not lang then
		state.reason = 'no grammar for ' .. name
		return state
	end
	local q = load_query(name, lang.lang)
	if not q then
		state.reason = 'no highlights query for ' .. name
		return state
	end
	state.name = name
	state.grammar = lang
	state.parser = core.parser(lang.lang)
	state.q = q
	return state
end

--- Captures intersecting a byte range of the window's file, as an array
-- of { capture = name, start = byte, finish = byte } in the order they
-- should be applied: outer before inner, earlier pattern before later.
-- `nil` when tree-sitter does not handle this window.
function M.captures(win, start, finish)
	local state = state_for(win)
	if not state or not state.parser then return nil end
	local file = win.file
	if file.size > M.max_bytes then return nil end
	if state.dirty or not state.tree then
		local clock = os.clock()
		local tree, err = state.parser:parse(file, state.tree)
		state.parse_ms = (os.clock() - clock) * 1000
		if not tree then
			state.reason = err
			state.parser = nil
			return nil
		end
		state.tree, state.dirty = tree, false
	end

	local q = state.q
	local matches, n = q.query:exec(state.tree, start, finish)
	local out = {}
	local i = 1
	while i < n do
		local pattern, count = matches[i], matches[i + 1]
		i = i + 2
		local first = i
		i = i + 3 * count
		local preds = q.predicates[pattern]
		local ok = true
		if preds and #preds > 0 then
			local cache = {}
			local function texts(id)
				local t = cache[id]
				if t then return t end
				t = {}
				for j = first, i - 1, 3 do
					if matches[j] == id then
						t[#t + 1] = file:content(matches[j + 1], matches[j + 2] - matches[j + 1])
					end
				end
				cache[id] = t
				return t
			end
			for _, pred in ipairs(preds) do
				if not predicate_holds(pred, texts) then ok = false break end
			end
		end
		if ok then
			for j = first, i - 1, 3 do
				local s, e = matches[j + 1], matches[j + 2]
				if e > s then
					out[#out + 1] = {
						capture = q.captures[matches[j]],
						start = s, finish = e, pattern = pattern, order = #out,
					}
				end
			end
		end
	end
	table.sort(out, function(a, b)
		if a.start ~= b.start then return a.start < b.start end
		if a.finish ~= b.finish then return a.finish > b.finish end
		if a.pattern ~= b.pattern then return a.pattern < b.pattern end
		return a.order < b.order
	end)
	return out
end

--- Highlight the window's viewport. Returns `false` when the window has
-- no grammar, so the caller can fall back to the LPeg lexer.
function M.highlight(win)
	local viewport = win.viewport and win.viewport.bytes
	if not viewport then return false end
	local captures = M.captures(win, viewport.start, viewport.finish)
	if not captures then return false end
	for _, c in ipairs(captures) do
		local id = style_for(c.capture)
		if id then win:style(id, c.start, c.finish - 1) end
	end
	return true
end

vis.events.subscribe(vis.events.TEXT_CHANGED, function(file, pos, deleted, inserted)
	local state = states[file]
	if not state or not state.tree then return end
	state.dirty = true
	if not pos then
		state.tree = nil  -- undo: range unknown, reparse from scratch
		return
	end
	-- a deletion is reported before it happens, an insertion after, so
	-- the file still holds whichever side the points are needed for
	local start_row, start_col = point(file, pos)
	local old_end, new_end = pos + deleted, pos + (inserted and #inserted or 0)
	local old_row, old_col, new_row, new_col = start_row, start_col, start_row, start_col
	if deleted > 0 then old_row, old_col = point(file, old_end) end
	if inserted then new_row, new_col = point(file, new_end) end
	state.tree:edit(pos, old_end, new_end, start_row, start_col, old_row, old_col, new_row, new_col)
end)

vis.events.subscribe(vis.events.FILE_CLOSE, function(file)
	states[file] = nil
end)

--- Status of tree-sitter for a window: `nil` before the first highlight,
-- otherwise a table with `syntax`, and either `reason` (inactive) or
-- `grammar`, `queries`, `parse_ms`, `has_error` and `dropped` (the
-- patterns the grammar rejected).
function M.info(win)
	local state = win and win.file and states[win.file]
	if not state then return nil end
	if not state.parser then return { syntax = state.syntax, reason = state.reason or 'inactive' } end
	return {
		syntax = state.syntax,
		grammar = state.grammar.path,
		queries = state.q.paths,
		parse_ms = state.parse_ms or 0,
		has_error = state.tree and state.tree:has_error() or false,
		dropped = state.q.dropped,
	}
end

vis:command_register('treesitter', function(argv, force, win)
	local info = M.info(win)
	if not info then
		vis:info('treesitter: ' .. (win and win.syntax and 'not yet highlighted' or 'no syntax'))
		return true
	end
	if info.reason then
		vis:info('treesitter: ' .. info.reason)
		return true
	end
	local lines = {
		'syntax:  ' .. info.syntax,
		'grammar: ' .. info.grammar,
		'queries: ' .. table.concat(info.queries, ', '),
		string.format('parse:   %.1f ms%s', info.parse_ms, info.has_error and ' (with syntax errors)' or ''),
	}
	if #info.dropped > 0 then
		lines[#lines + 1] = 'patterns dropped by this grammar:'
		for _, d in ipairs(info.dropped) do lines[#lines + 1] = '  ' .. d end
	end
	local unsupported = {}
	for name in pairs(M.unsupported_predicates) do unsupported[#unsupported + 1] = name end
	if #unsupported > 0 then
		table.sort(unsupported)
		lines[#lines + 1] = 'predicates applied unconditionally: ' .. table.concat(unsupported, ', ')
	end
	vis:message(table.concat(lines, '\n') .. '\n')
	return true
end, 'Show tree-sitter highlighting status for the window')

return M
