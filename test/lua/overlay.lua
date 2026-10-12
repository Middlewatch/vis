-- vis-overlay: the arbiter's dismiss on <Escape>

local overlay = require('vis-overlay')

describe("overlay", function()

	it("<Escape> hides the owner and still does the native escape", function()
		local hidden = 0
		local me = {}
		me.hide = function()
			hidden = hidden + 1
			overlay.hide(me)
		end
		overlay.show(me, { x = 0, y = 0, lines = { "box" } })
		assert.are.equal(me, overlay.owner())
		vis:feedkeys("<C-j>")
		assert.are.equal(2, #vis.win.selections)
		vis:feedkeys("<Escape>")
		assert.are.equal(1, hidden)
		assert.are.equal(nil, overlay.owner())
		assert.are.equal(1, #vis.win.selections)
	end)

	it("an owner without hide() still loses the box", function()
		local me = {}
		overlay.show(me, { x = 0, y = 0, lines = { "box" } })
		vis:feedkeys("<Escape>")
		assert.are.equal(nil, overlay.owner())
	end)

	it("dismiss() with no owner reports nothing shown", function()
		assert.are.equal(false, overlay.dismiss())
	end)

end)
