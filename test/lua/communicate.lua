describe("vis.communicate", function()

	it("write returns before the child reads", function()
		-- a pipe holds 64 KB; a blocking write of 1 MB would wait for cat
		local p = vis:communicate("sleeper", "sleep 3; cat > /dev/null")
		assert.truthy(p)
		local start = os.time()
		local chunk = string.rep("x", 65536)
		for _ = 1, 16 do
			assert.truthy(p:write(chunk))
		end
		assert.truthy(p:flush())
		assert.truthy(os.time() - start <= 1)
		assert.truthy(p:close())
	end)

	it("write accepts several strings", function()
		local p = vis:communicate("cat", "cat > /dev/null")
		assert.are.equal(p, p:write("a", "b", "c"))
		p:close()
	end)

	it("a child that ignores SIGTERM does not block exit", function()
		-- the shell ignores SIGTERM; vis kills it after a grace period when
		-- it quits, else this test file never finishes. The sleep ends on
		-- its own, so no orphan is left behind.
		local p = vis:communicate("stubborn", "trap '' TERM; while :; do sleep 1; done")
		assert.truthy(p)
		-- give the shell time to install the trap before the kill
		os.execute("sleep 0.3")
		assert.truthy(p:close())
	end)

	it("a closed handle rejects writes", function()
		local p = vis:communicate("closed", "cat > /dev/null")
		assert.truthy(p:close())
		assert.has_error(function() p:write("x") end)
		assert.truthy(p:close())
	end)

end)
