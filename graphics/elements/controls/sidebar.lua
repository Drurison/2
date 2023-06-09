-- Sidebar Graphics Element

local tcd     = require("scada-common.tcallbackdsp")

local element = require("graphics.element")

---@class sidebar_tab
---@field char string character identifier
---@field color cpair tab colors (fg/bg)

---@class sidebar_args
---@field tabs table sidebar tab options
---@field callback function function to call on tab change
---@field parent graphics_element
---@field id? string element id
---@field x? integer 1 if omitted
---@field y? integer 1 if omitted
---@field height? integer parent height if omitted
---@field fg_bg? cpair foreground/background colors

-- new sidebar tab selector
---@param args sidebar_args
---@return graphics_element element, element_id id
local function sidebar(args)
    assert(type(args.tabs) == "table", "graphics.elements.controls.sidebar: tabs is a required field")
    assert(#args.tabs > 0, "graphics.elements.controls.sidebar: at least one tab is required")
    assert(type(args.callback) == "function", "graphics.elements.controls.sidebar: callback is a required field")

    -- always 3 wide
    args.width = 3

    -- create new graphics element base object
    local e = element.new(args)

    assert(e.frame.h >= (#args.tabs * 3), "graphics.elements.controls.sidebar: height insufficent to display all tabs")

    -- default to 1st tab
    e.value = 1

    -- show the button state
    ---@param pressed boolean if the currently selected tab should appear as actively pressed
    local function draw(pressed)
        for i = 1, #args.tabs do
            local tab = args.tabs[i] ---@type sidebar_tab

            local y = ((i - 1) * 3) + 1

            e.window.setCursorPos(1, y)

            if pressed and e.value == i then
                e.window.setTextColor(e.fg_bg.fgd)
                e.window.setBackgroundColor(e.fg_bg.bkg)
            else
                e.window.setTextColor(tab.color.fgd)
                e.window.setBackgroundColor(tab.color.bkg)
            end

            e.window.write("   ")
            e.window.setCursorPos(1, y + 1)
            if e.value == i then
                -- show as selected
                e.window.write(" " .. tab.char .. "\x10")
            else
                -- show as unselected
                e.window.write(" " .. tab.char .. " ")
            end
            e.window.setCursorPos(1, y + 2)
            e.window.write("   ")
        end
    end

    -- handle mouse interaction
    ---@param event mouse_interaction mouse event
    function e.handle_mouse(event)
        -- determine what was pressed
        if e.enabled then
            local idx = math.ceil(event.y / 3)

            if args.tabs[idx] ~= nil then
                e.value = idx
                draw(true)

                -- show as unpressed in 0.25 seconds
                tcd.dispatch(0.25, function () draw(false) end)

                args.callback(e.value)
            end
        end
    end

    -- set the value
    ---@param val integer new value
    function e.set_value(val)
        e.value = val
        draw(false)
    end

    -- initial draw
    draw(false)

    return e.get()
end

return sidebar
