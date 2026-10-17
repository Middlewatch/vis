-- filetype detection: opening a file name sets win.syntax to the lexer
-- the filetype plugin maps it to. Files need not exist; vis opens an
-- empty buffer under the name and WIN_OPEN runs detection on it.

local cases = {
	-- name, expected syntax
	{ "a.c", "c" },
	{ "a.h", "c" },
	{ "a.cpp", "cpp" },
	{ "a.hpp", "cpp" },
	{ "a.zig", "zig" },
	{ "a.go", "go" },
	{ "a.lua", "lua" },
	{ "a.py", "python" },
	{ "a.sh", "bash" },
	{ "a.js", "javascript" },
	{ "a.mjs", "javascript" },
	{ "a.ts", "typescript" },
	{ "a.tsx", "typescript" },
	{ "a.rs", "rust" },
	{ "a.html", "html" },
	{ "a.htm", "html" },
	{ "a.xml", "xml" },
	{ "a.css", "css" },
	{ "a.json", "json" },
	{ "a.yaml", "yaml" },
	{ "a.yml", "yaml" },
	{ "a.toml", "toml" },
	{ "a.ini", "ini" },
	{ "a.conf", "ini" },
	{ "a.md", "markdown" },
	{ "a.txt", "text" },
	{ "Makefile", "makefile" },
	{ "Dockerfile", "dockerfile" },
	-- an unknown extension falls back to the mime check, which calls
	-- an empty buffer plain text
	{ "a.unknownext", "text" },
}

describe("filetype", function()
	for _, c in ipairs(cases) do
		local name, want = c[1], c[2]
		it(name, function()
			vis:command("open " .. name)
			assert.are.equal(want, vis.win.syntax)
			vis:command("q!")
		end)
	end
end)
