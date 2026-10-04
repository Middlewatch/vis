-- Overlay arbiter: one overlay, one owner at a time.
--
--   local overlay = require('vis-overlay')
--   overlay.show(me, {x = 0, y = 0, lines = {"..."}}, function(row, m) end)
--   overlay.hide(me)
--
-- show() hands the box to its caller, replacing whatever another owner
-- drew (nothing is restored when the new owner hides). hide() by anyone
-- but the owner does nothing, so a feature that lost the box cannot pull
-- it from under the one that has it. The optional click handler gets the
-- 1-based row and the mouse state; vis-mouse routes overlay clicks to
-- overlay.click, which forwards to the owner's handler.
require('vis')

local overlay = {}
local owner, on_click

function overlay.show(who, spec, click)
	owner, on_click = who, click
	vis:overlay_show(spec)
end

function overlay.hide(who)
	if owner ~= who then return false end
	owner, on_click = nil, nil
	vis:overlay_hide()
	return true
end

function overlay.owner()
	return owner
end

function overlay.click(row, m)
	if on_click then on_click(row, m) end
end

return overlay
