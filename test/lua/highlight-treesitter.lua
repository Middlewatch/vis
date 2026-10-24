-- tree-sitter highlighting: captures over the fixture and tracking of edits.
-- Needs a build with --enable-tree-sitter and an installed lua grammar;
-- otherwise only the fallback is checked.

local ts = vis.treesitter
local win = vis.win
local file = win.file

describe("tree-sitter", function()

	if not ts then
		it("is not built in, nothing to check", function() end)
		return
	end

	vis:command('set syntax lua')
	local caps = ts.captures(win, 0, file.size)

	if not caps then
		it("falls back to the lexer without a grammar", function()
			assert.falsy(ts.highlight(win))
		end)
		return
	end

	local function capture_at(pos, name)
		for _, c in ipairs(caps) do
			if c.start == pos and c.capture == name then return c end
		end
	end

	it("captures the local keyword", function()
		assert.truthy(capture_at(0, 'keyword'))
	end)

	it("captures the function name with its end", function()
		local c = capture_at(15, 'function')
		assert.truthy(c)
		assert.are.equal(20, c and c.finish)
	end)

	it("captures print as a builtin", function()
		assert.truthy(capture_at(28, 'function.builtin'))
	end)

	it("orders an enclosing capture before the inner one", function()
		local seen_param, seen_name = nil, nil
		for i, c in ipairs(caps) do
			if c.start == 21 and c.capture == 'variable.parameter' then seen_param = i end
			if c.start == 21 and c.capture == 'variable' then seen_name = i end
		end
		if seen_param and seen_name then
			assert.truthy(seen_name < seen_param)
		end
	end)

	it("follows an insertion", function()
		file:insert(0, "-- note\n")
		caps = ts.captures(win, 0, file.size)
		assert.truthy(capture_at(0, 'comment'))
		assert.truthy(capture_at(8, 'keyword'))
	end)

	it("follows a deletion", function()
		file:delete(0, 8)
		caps = ts.captures(win, 0, file.size)
		assert.truthy(capture_at(0, 'keyword'))
		assert.truthy(capture_at(28, 'function.builtin'))
	end)

end)
