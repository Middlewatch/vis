-- hidden buffers: the :e, :b and :bd file lifecycle

local in_file = vis.win.file

describe("buffers", function()

	it(":bd on an unnamed, untouched buffer moves to the other file", function()
		vis:command("open")
		assert.are.equal(nil, vis.win.file.path)
		assert.truthy(vis:command("bd"))
		assert.are.equal(in_file.name, vis.win.file.name)
	end)

	it(":e of a missing path opens it rather than an unnamed buffer", function()
		vis:command("open")
		vis:insert("hello")
		local before = vis.win.file.number
		local missing = os.tmpname()
		os.remove(missing)
		missing = missing .. "-missing.txt"
		assert.truthy(vis:command("e " .. missing))
		assert.are.equal(missing, vis.win.file.path)
		assert.are.equal(0, vis.win.file.size)
		assert.truthy(vis.win.file.number ~= before)
	end)

	it(":e of an existing file with shell characters opens it literally", function()
		local dir = os.tmpname()
		os.remove(dir)
		os.execute("mkdir -p '" .. dir .. "'")
		local evil = dir .. "/x$(touch${IFS}owned)y.txt"
		local f = io.open(evil, "w"); f:write("x\n"); f:close()
		assert.truthy(vis:command('e "' .. evil:gsub('[\\"]', '\\%0') .. '"'))
		assert.are.equal(evil, vis.win.file.path)
		assert.are.equal(nil, io.open("owned")) -- would land in the cwd
		os.remove("owned")
		os.execute("rm -r '" .. dir .. "'")
	end)

	it(":ls takes no buffer number", function()
		local max = 0
		for f in vis:files() do if f.number > max then max = f.number end end
		assert.truthy(vis:command("ls"))
		assert.are.equal(0, vis.win.file.number)
		assert.truthy(vis.win.file.size > 0)
		vis:command("q")
		vis:command("open")
		assert.are.equal(max + 1, vis.win.file.number)
	end)

	it(":b is rejected inside a command group", function()
		assert.falsy(vis:command("{\nb 1\np\n}"))
	end)

end)
