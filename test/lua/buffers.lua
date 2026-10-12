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

	it(":b is rejected inside a command group", function()
		assert.falsy(vis:command("{\nb 1\np\n}"))
	end)

end)
