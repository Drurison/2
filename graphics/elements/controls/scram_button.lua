-- SCRAM Button Graphics Element

local tcd     = require("scada-common.tcallbackdsp")

local core    = require("graphics.core")

local element = require("graphics.element")

---@class scram_button_args
---@field callback function function to call on touch
---@field parent graphics_element
---@field x? integer 1 if omitted
---@field y? integer 1 if omitted
---@field fg_bg? cpair foreground/background colors

-- new scram button
---@param args scram_button_args
local function scram_button(args)
    assert(type(args.callback) == "function", "graphics.elements.controls.scram_button: callback is a required field")

    -- static dimensions
    args.height = 3
    args.width = 9

    -- create new graphics element base object
    local e = element.new(args)

    -- write the button text
    e.window.setCursorPos(3, 2)
    e.window.write("SCRAM")

    -- draw border

    -- top
    e.window.setTextColor(colors.yellow)
    e.window.setBackgroundColor(args.fg_bg.bkg)
    e.window.setCursorPos(1, 1)
    e.window.write("\x99\x89\x89\x89\x89\x89\x89\x89\x99")

    -- center left
    e.window.setCursorPos(1, 2)
    e.window.setTextColor(args.fg_bg.bkg)
    e.window.setBackgroundColor(colors.yellow)
    e.window.write("\x99")

    -- center right
    e.window.setTextColor(args.fg_bg.bkg)
    e.window.setBackgroundColor(colors.yellow)
    e.window.setCursorPos(9, 2)
    e.window.write("\x99")

    -- bottom
    e.window.setTextColor(colors.yellow)
    e.window.setBackgroundColor(args.fg_bg.bkg)
    e.window.setCursorPos(1, 3)
    e.window.write("\x99\x98\x98\x98\x98\x98\x98\x98\x99")

    -- handle touch
    ---@param event monitor_touch monitor touch event
---@diagnostic disable-next-line: unused-local
    function e.handle_touch(event)
        -- call the touch callback
        args.callback()
    end

    return e.get()
end

return scram_button
