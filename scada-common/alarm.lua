local util = require("scada-common.util")

---@class alarm
local alarm = {}

---@alias SEVERITY integer
SEVERITY = {
    INFO = 0,       -- basic info message
    WARNING = 1,    -- warning about some abnormal state
    ALERT = 2,      -- important device state changes
    FACILITY = 3,   -- facility-wide alert
    SAFETY = 4,     -- safety alerts
    EMERGENCY = 5   -- critical safety alarm
}

alarm.SEVERITY = SEVERITY

-- severity integer to string
---@param severity SEVERITY
alarm.severity_to_string = function (severity)
    if severity == SEVERITY.INFO then
        return "INFO"
    elseif severity == SEVERITY.WARNING then
        return "WARNING"
    elseif severity == SEVERITY.ALERT then
        return "ALERT"
    elseif severity == SEVERITY.FACILITY then
        return "FACILITY"
    elseif severity == SEVERITY.SAFETY then
        return "SAFETY"
    elseif severity == SEVERITY.EMERGENCY then
        return "EMERGENCY"
    else
        return "UNKNOWN"
    end
end

-- create a new scada alarm entry
---@param severity SEVERITY
---@param device string
---@param message string
alarm.scada_alarm = function (severity, device, message)
    local self = {
        time = util.time(),
        ts_string = os.date("[%H:%M:%S]"),
        severity = severity,
        device = device,
        message = message
    }

    ---@class scada_alarm
    local public = {}

    -- format the alarm as a string
    ---@return string message
    public.format = function ()
        return self.ts_string .. " [" .. alarm.severity_to_string(self.severity) .. "] (" .. self.device ") >> " .. self.message
    end

    -- get alarm properties
    public.properties = function ()
        return {
            time = self.time,
            severity = self.severity,
            device = self.device,
            message = self.message
        }
    end

    return public
end

return alarm
