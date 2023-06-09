local log   = require("scada-common.log")
local rsio  = require("scada-common.rsio")
local types = require("scada-common.types")
local util  = require("scada-common.util")

local logic = require("supervisor.unitlogic")

local plc   = require("supervisor.session.plc")
local rsctl = require("supervisor.session.rsctl")

---@class reactor_control_unit
local unit = {}

local WASTE_MODE   = types.WASTE_MODE
local ALARM        = types.ALARM
local PRIO         = types.ALARM_PRIORITY
local ALARM_STATE  = types.ALARM_STATE
local TRI_FAIL     = types.TRI_FAIL

local PLC_S_CMDS = plc.PLC_S_CMDS

local IO = rsio.IO

local DT_KEYS = {
    ReactorBurnR = "RBR",
    ReactorTemp  = "RTP",
    ReactorFuel  = "RFL",
    ReactorWaste = "RWS",
    ReactorCCool = "RCC",
    ReactorHCool = "RHC",
    BoilerWater  = "BWR",
    BoilerSteam  = "BST",
    BoilerCCool  = "BCC",
    BoilerHCool  = "BHC",
    TurbineSteam = "TST",
    TurbinePower = "TPR"
}

---@enum ALARM_INT_STATE
local AISTATE = {
    INACTIVE = 1,
    TRIPPING = 2,
    TRIPPED = 3,
    ACKED = 4,
    RING_BACK = 5,
    RING_BACK_TRIPPING = 6
}

---@class alarm_def
---@field state ALARM_INT_STATE internal alarm state
---@field trip_time integer time (ms) when first tripped
---@field hold_time integer time (s) to hold before tripping
---@field id ALARM alarm ID
---@field tier integer alarm urgency tier (0 = highest)

-- create a new reactor unit
---@nodiscard
---@param reactor_id integer reactor unit number
---@param num_boilers integer number of boilers expected
---@param num_turbines integer number of turbines expected
function unit.new(reactor_id, num_boilers, num_turbines)
    ---@class _unit_self
    local self = {
        r_id = reactor_id,
        plc_s = nil,    ---@class plc_session_struct
        plc_i = nil,    ---@class plc_session
        num_boilers = num_boilers,
        num_turbines = num_turbines,
        types = { DT_KEYS = DT_KEYS, AISTATE = AISTATE },
        -- rtus
        redstone = {},
        boilers = {},
        turbines = {},
        envd = {},
        -- redstone control
        io_ctl = nil,   ---@type rs_controller
        valves = {},    ---@type unit_valves
        emcool_opened = false,
        -- auto control
        auto_engaged = false,
        auto_was_alarmed = false,
        ramp_target_br100 = 0,
        -- state tracking
        deltas = {},
        last_heartbeat = 0,
        last_radiation = 0,
        damage_decreasing = false,
        damage_initial = 0,
        damage_start = 0,
        damage_last = 0,
        damage_est_last = 0,
        waste_mode = WASTE_MODE.AUTO,
        status_text = { "UNKNOWN", "awaiting connection..." },
        -- logic for alarms
        had_reactor = false,
        last_rate_change_ms = 0,
        ---@type rps_status
        last_rps_trips = {
            high_dmg = false,
            high_temp = false,
            low_cool = false,
            ex_waste = false,
            ex_hcool = false,
            no_fuel = false,
            fault = false,
            timeout = false,
            manual = false,
            automatic = false,
            sys_fail = false,
            force_dis = false
        },
        plc_cache = {
            active = false,
            ok = false,
            rps_trip = false,
            ---@type rps_status
            rps_status = {
                high_dmg = false,
                high_temp = false,
                low_cool = false,
                ex_waste = false,
                ex_hcool = false,
                no_fuel = false,
                fault = false,
                timeout = false,
                manual = false,
                automatic = false,
                sys_fail = false,
                force_dis = false
            },
            damage = 0,
            temp = 0,
            waste = 0
        },
        ---@class alarm_monitors
        alarms = {
            -- reactor lost under the condition of meltdown imminent
            ContainmentBreach    = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 0, id = ALARM.ContainmentBreach, tier = PRIO.CRITICAL },
            -- radiation monitor alarm for this unit
            ContainmentRadiation = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 0, id = ALARM.ContainmentRadiation, tier = PRIO.CRITICAL },
            -- reactor offline after being online
            ReactorLost          = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 0, id = ALARM.ReactorLost, tier = PRIO.TIMELY },
            -- damage >100%
            CriticalDamage       = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 0, id = ALARM.CriticalDamage, tier = PRIO.CRITICAL },
            -- reactor damage increasing
            ReactorDamage        = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 0, id = ALARM.ReactorDamage, tier = PRIO.EMERGENCY },
            -- reactor >1200K
            ReactorOverTemp      = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 0, id = ALARM.ReactorOverTemp, tier = PRIO.URGENT },
            -- reactor >=1150K
            ReactorHighTemp      = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 1, id = ALARM.ReactorHighTemp, tier = PRIO.TIMELY },
            -- waste = 100%
            ReactorWasteLeak     = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 0, id = ALARM.ReactorWasteLeak, tier = PRIO.EMERGENCY },
            -- waste >85%
            ReactorHighWaste     = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 2, id = ALARM.ReactorHighWaste, tier = PRIO.URGENT },
            -- RPS trip occured
            RPSTransient         = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 2, id = ALARM.RPSTransient, tier = PRIO.TIMELY },
            -- CoolantLevelLow, WaterLevelLow, TurbineOverSpeed, MaxWaterReturnFeed, RCPTrip, RCSFlowLow, BoilRateMismatch, CoolantFeedMismatch,
            -- SteamFeedMismatch, MaxWaterReturnFeed, RCS hardware fault
            RCSTransient         = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 5, id = ALARM.RCSTransient, tier = PRIO.TIMELY },
            -- "It's just a routine turbin' trip!" -Bill Gibson, "The China Syndrome"
            TurbineTrip          = { state = AISTATE.INACTIVE, trip_time = 0, hold_time = 2, id = ALARM.TurbineTrip, tier = PRIO.URGENT }
        },
        ---@class unit_db
        db = {
            ---@class annunciator
            annunciator = {
                -- reactor
                PLCOnline = false,
                PLCHeartbeat = false,   -- alternate true/false to blink, each time there is a keep_alive
                RadiationMonitor = 1,
                AutoControl = false,
                ReactorSCRAM = false,
                ManualReactorSCRAM = false,
                AutoReactorSCRAM = false,
                RadiationWarning = false,
                RCPTrip = false,
                RCSFlowLow = false,
                CoolantLevelLow = false,
                ReactorTempHigh = false,
                ReactorHighDeltaT = false,
                FuelInputRateLow = false,
                WasteLineOcclusion = false,
                HighStartupRate = false,
                -- cooling
                RCSFault = false,
                EmergencyCoolant = 1,
                CoolantFeedMismatch = false,
                BoilRateMismatch = false,
                SteamFeedMismatch = false,
                MaxWaterReturnFeed = false,
                -- boilers
                BoilerOnline = {},
                HeatingRateLow = {},
                WaterLevelLow = {},
                -- turbines
                TurbineOnline = {},
                SteamDumpOpen = {},
                TurbineOverSpeed = {},
                GeneratorTrip = {},
                TurbineTrip = {}
            },
            ---@class alarms
            alarm_states = {
                ALARM_STATE.INACTIVE,
                ALARM_STATE.INACTIVE,
                ALARM_STATE.INACTIVE,
                ALARM_STATE.INACTIVE,
                ALARM_STATE.INACTIVE,
                ALARM_STATE.INACTIVE,
                ALARM_STATE.INACTIVE,
                ALARM_STATE.INACTIVE,
                ALARM_STATE.INACTIVE,
                ALARM_STATE.INACTIVE,
                ALARM_STATE.INACTIVE,
                ALARM_STATE.INACTIVE
            },
            -- fields for facility control
            ---@class unit_control
            control = {
                ready = false,
                degraded = false,
                blade_count = 0,
                br100 = 0,
                lim_br100 = 0
            }
        }
    }

    -- init redstone RTU I/O controller
    self.io_ctl = rsctl.new(self.redstone)

    -- init boiler table fields
    for _ = 1, num_boilers do
        table.insert(self.db.annunciator.BoilerOnline, false)
        table.insert(self.db.annunciator.HeatingRateLow, false)
    end

    -- init turbine table fields
    for _ = 1, num_turbines do
        table.insert(self.db.annunciator.TurbineOnline, false)
        table.insert(self.db.annunciator.SteamDumpOpen, TRI_FAIL.OK)
        table.insert(self.db.annunciator.TurbineOverSpeed, false)
        table.insert(self.db.annunciator.GeneratorTrip, false)
        table.insert(self.db.annunciator.TurbineTrip, false)
    end

    -- PRIVATE FUNCTIONS --

    --#region time derivative utility functions

    -- compute a change with respect to time of the given value
    ---@param key string value key
    ---@param value number value
    ---@param time number timestamp for value
    local function _compute_dt(key, value, time)
        if self.deltas[key] then
            local data = self.deltas[key]

            if time > data.last_t then
                data.dt = (value - data.last_v) / (time - data.last_t)

                data.last_v = value
                data.last_t = time
            end
        else
            self.deltas[key] = {
                last_t = time,
                last_v = value,
                dt = 0.0
            }
        end
    end

    -- clear a delta
    ---@param key string value key
    local function _reset_dt(key) self.deltas[key] = nil end

    -- get the delta t of a value
    ---@nodiscard
    ---@param key string value key
    ---@return number value value or 0 if not known
    function self._get_dt(key) if self.deltas[key] then return self.deltas[key].dt else return 0.0 end end

    -- update all delta computations
    local function _dt__compute_all()
        if self.plc_i ~= nil then
            local plc_db = self.plc_i.get_db()

            local last_update_s = plc_db.last_status_update / 1000.0

            _compute_dt(DT_KEYS.ReactorBurnR, plc_db.mek_status.act_burn_rate, last_update_s)
            _compute_dt(DT_KEYS.ReactorTemp, plc_db.mek_status.temp, last_update_s)
            _compute_dt(DT_KEYS.ReactorFuel, plc_db.mek_status.fuel, last_update_s)
            _compute_dt(DT_KEYS.ReactorWaste, plc_db.mek_status.waste, last_update_s)
            _compute_dt(DT_KEYS.ReactorCCool, plc_db.mek_status.ccool_amnt, last_update_s)
            _compute_dt(DT_KEYS.ReactorHCool, plc_db.mek_status.hcool_amnt, last_update_s)
        end

        for i = 1, #self.boilers do
            local boiler = self.boilers[i]  ---@type unit_session
            local db = boiler.get_db()      ---@type boilerv_session_db

            local last_update_s = db.tanks.last_update / 1000.0

            _compute_dt(DT_KEYS.BoilerWater .. boiler.get_device_idx(), db.tanks.water.amount, last_update_s)
            _compute_dt(DT_KEYS.BoilerSteam .. boiler.get_device_idx(), db.tanks.steam.amount, last_update_s)
            _compute_dt(DT_KEYS.BoilerCCool .. boiler.get_device_idx(), db.tanks.ccool.amount, last_update_s)
            _compute_dt(DT_KEYS.BoilerHCool .. boiler.get_device_idx(), db.tanks.hcool.amount, last_update_s)
        end

        for i = 1, #self.turbines do
            local turbine = self.turbines[i]    ---@type unit_session
            local db = turbine.get_db()         ---@type turbinev_session_db

            local last_update_s = db.tanks.last_update / 1000.0

            _compute_dt(DT_KEYS.TurbineSteam .. turbine.get_device_idx(), db.tanks.steam.amount, last_update_s)
            _compute_dt(DT_KEYS.TurbinePower .. turbine.get_device_idx(), db.tanks.energy, last_update_s)
        end
    end

    --#endregion

    --#region redstone I/O

    local __rs_w = self.io_ctl.digital_write

    -- valves
    local waste_pu  = { open = function () __rs_w(IO.WASTE_PU,    true) end, close = function () __rs_w(IO.WASTE_PU,    false) end }
    local waste_sna = { open = function () __rs_w(IO.WASTE_PO,    true) end, close = function () __rs_w(IO.WASTE_PO,    false) end }
    local waste_po  = { open = function () __rs_w(IO.WASTE_POPL,  true) end, close = function () __rs_w(IO.WASTE_POPL,  false) end }
    local waste_sps = { open = function () __rs_w(IO.WASTE_AM,    true) end, close = function () __rs_w(IO.WASTE_AM,    false) end }
    local emer_cool = { open = function () __rs_w(IO.U_EMER_COOL, true) end, close = function () __rs_w(IO.U_EMER_COOL, false) end }

    ---@class unit_valves
    self.valves = {
        waste_pu = waste_pu,
        waste_sna = waste_sna,
        waste_po = waste_po,
        waste_sps = waste_sps,
        emer_cool = emer_cool
    }

    --#endregion

    -- unlink disconnected units
    ---@param sessions table
    local function _unlink_disconnected_units(sessions)
        util.filter_table(sessions, function (u) return u.is_connected() end)
    end

    -- PUBLIC FUNCTIONS --

    ---@class reactor_unit
    local public = {}

    -- ADD/LINK DEVICES --
    --#region

    -- link the PLC
    ---@param plc_session plc_session_struct
    function public.link_plc_session(plc_session)
        self.had_reactor = true
        self.plc_s = plc_session
        self.plc_i = plc_session.instance

        -- reset deltas
        _reset_dt(DT_KEYS.ReactorTemp)
        _reset_dt(DT_KEYS.ReactorFuel)
        _reset_dt(DT_KEYS.ReactorWaste)
        _reset_dt(DT_KEYS.ReactorCCool)
        _reset_dt(DT_KEYS.ReactorHCool)
    end

    -- link a redstone RTU session
    ---@param rs_unit unit_session
    function public.add_redstone(rs_unit)
        table.insert(self.redstone, rs_unit)

        -- send or re-send waste settings
        public.set_waste(self.waste_mode)
    end

    -- link a turbine RTU session
    ---@param turbine unit_session
    function public.add_turbine(turbine)
        if #self.turbines < num_turbines and turbine.get_device_idx() <= num_turbines then
            table.insert(self.turbines, turbine)

            -- reset deltas
            _reset_dt(DT_KEYS.TurbineSteam .. turbine.get_device_idx())
            _reset_dt(DT_KEYS.TurbinePower .. turbine.get_device_idx())

            return true
        else
            return false
        end
    end

    -- link a boiler RTU session
    ---@param boiler unit_session
    function public.add_boiler(boiler)
        if #self.boilers < num_boilers and boiler.get_device_idx() <= num_boilers then
            table.insert(self.boilers, boiler)

            -- reset deltas
            _reset_dt(DT_KEYS.BoilerWater .. boiler.get_device_idx())
            _reset_dt(DT_KEYS.BoilerSteam .. boiler.get_device_idx())
            _reset_dt(DT_KEYS.BoilerCCool .. boiler.get_device_idx())
            _reset_dt(DT_KEYS.BoilerHCool .. boiler.get_device_idx())

            return true
        else
            return false
        end
    end

    -- link an environment detector RTU session
    ---@param envd unit_session
    function public.add_envd(envd)
        table.insert(self.envd, envd)
    end

    -- purge devices associated with the given RTU session ID
    ---@param session integer RTU session ID
    function public.purge_rtu_devices(session)
        util.filter_table(self.redstone, function (s) return s.get_session_id() ~= session end)
        util.filter_table(self.boilers,  function (s) return s.get_session_id() ~= session end)
        util.filter_table(self.turbines, function (s) return s.get_session_id() ~= session end)
        util.filter_table(self.envd,     function (s) return s.get_session_id() ~= session end)
    end

    --#endregion

    -- UPDATE SESSION --

    -- update (iterate) this unit
    function public.update()
        -- unlink PLC if session was closed
        if self.plc_s ~= nil and not self.plc_s.open then
            self.plc_s = nil
            self.plc_i = nil
            self.db.control.br100 = 0
            self.db.control.lim_br100 = 0
        end

        -- unlink RTU unit sessions if they are closed
        _unlink_disconnected_units(self.redstone)
        _unlink_disconnected_units(self.boilers)
        _unlink_disconnected_units(self.turbines)
        _unlink_disconnected_units(self.envd)

        -- update degraded state for auto control
        self.db.control.degraded = (#self.boilers ~= num_boilers) or (#self.turbines ~= num_turbines) or (self.plc_i == nil)

        -- check boilers formed/faulted
        for i = 1, #self.boilers do
            local sess = self.boilers[i]    ---@type unit_session
            local boiler = sess.get_db()    ---@type boilerv_session_db
            if sess.is_faulted() or not boiler.formed then
                self.db.control.degraded = true
            end
        end

        -- check turbines formed/faulted
        for i = 1, #self.turbines do
            local sess = self.turbines[i]   ---@type unit_session
            local turbine = sess.get_db()   ---@type turbinev_session_db
            if sess.is_faulted() or not turbine.formed then
                self.db.control.degraded = true
            end
        end

        -- check plc formed/faulted
        if self.plc_i ~= nil then
            local rps = self.plc_i.get_rps()
            if rps.fault or rps.sys_fail then
                self.db.control.degraded = true
            end
        end

        -- update deltas
        _dt__compute_all()

        -- update annunciator logic
        logic.update_annunciator(self)

        -- update alarm status
        logic.update_alarms(self)

        -- if in auto mode, SCRAM on certain alarms
        logic.update_auto_safety(public, self)

        -- update status text
        logic.update_status_text(self)

        -- handle redstone I/O
        if #self.redstone > 0 then
            logic.handle_redstone(self)
        elseif not self.plc_cache.rps_trip then
            self.emcool_opened = false
        end
    end

    -- AUTO CONTROL OPERATIONS --
    --#region

    -- engage automatic control
    function public.a_engage()
        self.auto_engaged = true
        if self.plc_i ~= nil then
            self.plc_i.auto_lock(true)
        end
    end

    -- disengage automatic control
    function public.a_disengage()
        self.auto_engaged = false
        if self.plc_i ~= nil then
            self.plc_i.auto_lock(false)
            self.db.control.br100 = 0
        end
    end

    -- get the actual limit of this unit<br>
    -- if it is degraded or not ready, the limit will be 0
    ---@nodiscard
    ---@return integer lim_br100
    function public.a_get_effective_limit()
        if (not self.db.control.ready) or self.db.control.degraded or self.plc_cache.rps_trip then
            self.db.control.br100 = 0
            return 0
        else
            return self.db.control.lim_br100
        end
    end

    -- set the automatic burn rate based on the last set burn rate in 100ths
    ---@param ramp boolean true to ramp to rate, false to set right away
    function public.a_commit_br100(ramp)
        if self.auto_engaged then
            if self.plc_i ~= nil then
                self.plc_i.auto_set_burn(self.db.control.br100 / 100, ramp)

                if ramp then self.ramp_target_br100 = self.db.control.br100 end
            end
        end
    end

    -- check if ramping is complete (burn rate is same as target)
    ---@nodiscard
    ---@return boolean complete
    function public.a_ramp_complete()
        if self.plc_i ~= nil then
            return self.plc_i.is_ramp_complete() or
                (self.plc_i.get_status().act_burn_rate == 0 and self.db.control.br100 == 0) or
                public.a_get_effective_limit() == 0
        else return true end
    end

    -- perform an automatic SCRAM
    function public.a_scram()
        if self.plc_s ~= nil then
            self.db.control.br100 = 0
            self.plc_s.in_queue.push_command(PLC_S_CMDS.ASCRAM)
        end
    end

    -- queue a command to clear timeout/auto-scram if set
    function public.a_cond_rps_reset()
        if self.plc_s ~= nil and self.plc_i ~= nil and (not self.auto_was_alarmed) and (not self.emcool_opened) then
            local rps = self.plc_i.get_rps()
            if rps.timeout or rps.automatic then
                self.plc_i.auto_lock(true)  -- if it timed out/restarted, auto lock was lost, so re-lock it
                self.plc_s.in_queue.push_command(PLC_S_CMDS.RPS_AUTO_RESET)
            end
        end
    end

    --#endregion

    -- OPERATIONS --
    --#region

    -- queue a command to SCRAM the reactor
    function public.scram()
        if self.plc_s ~= nil then
            self.plc_s.in_queue.push_command(PLC_S_CMDS.SCRAM)
        end
    end

    -- queue a SCRAM command only if a manual SCRAM has not already occured
    function public.cond_scram()
        if self.plc_s ~= nil and not self.plc_cache.rps_status.manual then
            self.plc_s.in_queue.push_command(PLC_S_CMDS.SCRAM)
        end
    end

    -- acknowledge all alarms (if possible)
    function public.ack_all()
        for i = 1, #self.db.alarm_states do
            if self.db.alarm_states[i] == ALARM_STATE.TRIPPED then
                self.db.alarm_states[i] = ALARM_STATE.ACKED
            end
        end
    end

    -- acknowledge an alarm (if possible)
    ---@param id ALARM alarm ID
    function public.ack_alarm(id)
        if type(id) == "number" and self.db.alarm_states[id] == ALARM_STATE.TRIPPED then
            self.db.alarm_states[id] = ALARM_STATE.ACKED
        end
    end

    -- reset an alarm (if possible)
    ---@param id ALARM alarm ID
    function public.reset_alarm(id)
        if type(id) == "number" and self.db.alarm_states[id] == ALARM_STATE.RING_BACK then
            self.db.alarm_states[id] = ALARM_STATE.INACTIVE
        end
    end

    -- route reactor waste
    ---@param mode WASTE_MODE waste handling mode
    function public.set_waste(mode)
        if mode == WASTE_MODE.AUTO then
            ---@todo automatic waste routing
            self.waste_mode = mode
        elseif mode == WASTE_MODE.PLUTONIUM then
            -- route through plutonium generation
            self.waste_mode = mode
            waste_pu.open()
            waste_sna.close()
            waste_po.close()
            waste_sps.close()
        elseif mode == WASTE_MODE.POLONIUM then
            -- route through polonium generation into pellets
            self.waste_mode = mode
            waste_pu.close()
            waste_sna.open()
            waste_po.open()
            waste_sps.close()
        elseif mode == WASTE_MODE.ANTI_MATTER then
            -- route through polonium generation into SPS
            self.waste_mode = mode
            waste_pu.close()
            waste_sna.open()
            waste_po.close()
            waste_sps.open()
        else
            log.debug(util.c("invalid waste mode setting ", mode))
        end
    end

    -- set the automatic control max burn rate for this unit
    ---@param limit number burn rate limit for auto control
    function public.set_burn_limit(limit)
        if limit > 0 then
            self.db.control.lim_br100 = math.floor(limit * 100)

            if self.plc_i ~= nil then
                if limit > self.plc_i.get_struct().max_burn then
                    self.db.control.lim_br100 = math.floor(self.plc_i.get_struct().max_burn * 100)
                end
            end
        end
    end

    --#endregion

    -- READ STATES/PROPERTIES --
    --#region

    -- check if an alarm of at least a certain priority level is tripped
    ---@nodiscard
    ---@param min_prio ALARM_PRIORITY alarms with this priority or higher will be checked
    ---@return boolean tripped
    function public.has_alarm_min_prio(min_prio)
        for _, alarm in pairs(self.alarms) do
            if alarm.tier <= min_prio and (alarm.state == AISTATE.TRIPPED or alarm.state == AISTATE.ACKED) then
                return true
            end
        end

        return false
    end

    -- get build properties of all machines
    ---@nodiscard
    ---@param inc_plc boolean? true/nil to include PLC build, false to exclude
    ---@param inc_boilers boolean? true/nil to include boiler builds, false to exclude
    ---@param inc_turbines boolean? true/nil to include turbine builds, false to exclude
    function public.get_build(inc_plc, inc_boilers, inc_turbines)
        local build = {}

        if inc_plc ~= false then
            if self.plc_i ~= nil then
                build.reactor = self.plc_i.get_struct()
            end
        end

        if inc_boilers ~= false then
            build.boilers = {}
            for i = 1, #self.boilers do
                local boiler = self.boilers[i]      ---@type unit_session
                build.boilers[boiler.get_device_idx()] = { boiler.get_db().formed, boiler.get_db().build }
            end
        end

        if inc_turbines ~= false then
            build.turbines = {}
            for i = 1, #self.turbines do
                local turbine = self.turbines[i]    ---@type unit_session
                build.turbines[turbine.get_device_idx()] = { turbine.get_db().formed, turbine.get_db().build }
            end
        end

        return build
    end

    -- get reactor status
    ---@nodiscard
    function public.get_reactor_status()
        local status = {}
        if self.plc_i ~= nil then
            status = { self.plc_i.get_status(), self.plc_i.get_rps(), self.plc_i.get_general_status() }
        end

        return status
    end

    -- get RTU statuses
    ---@nodiscard
    function public.get_rtu_statuses()
        local status = {}

        -- status of boilers (including tanks)
        status.boilers = {}
        for i = 1, #self.boilers do
            local boiler = self.boilers[i]  ---@type unit_session
            status.boilers[boiler.get_device_idx()] = {
                boiler.is_faulted(),
                boiler.get_db().formed,
                boiler.get_db().state,
                boiler.get_db().tanks
            }
        end

        -- status of turbines (including tanks)
        status.turbines = {}
        for i = 1, #self.turbines do
            local turbine = self.turbines[i]  ---@type unit_session
            status.turbines[turbine.get_device_idx()] = {
                turbine.is_faulted(),
                turbine.get_db().formed,
                turbine.get_db().state,
                turbine.get_db().tanks
            }
        end

        -- radiation monitors (environment detectors)
        status.rad_mon = {}
        for i = 1, #self.envd do
            local envd = self.envd[i]       ---@type unit_session
            status.rad_mon[envd.get_device_idx()] = {
                envd.is_faulted(),
                envd.get_db().radiation
            }
        end

        return status
    end

    -- get the annunciator status
    ---@nodiscard
    function public.get_annunciator() return self.db.annunciator end

    -- get the alarm states
    ---@nodiscard
    function public.get_alarms() return self.db.alarm_states end

    -- get information required for automatic reactor control
    ---@nodiscard
    function public.get_control_inf() return self.db.control end

    -- get unit state
    ---@nodiscard
    function public.get_state()
        return { self.status_text[1], self.status_text[2], self.waste_mode, self.db.control.ready, self.db.control.degraded }
    end

    -- get the reactor ID
    ---@nodiscard
    function public.get_id() return self.r_id end

    --#endregion

    return public
end

return unit
