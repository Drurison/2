local log         = require("scada-common.log")
local mqueue      = require("scada-common.mqueue")
local util        = require("scada-common.util")

local config      = require("supervisor.config")
local facility    = require("supervisor.facility")

local svqtypes    = require("supervisor.session.svqtypes")

local coordinator = require("supervisor.session.coordinator")
local plc         = require("supervisor.session.plc")
local pocket      = require("supervisor.session.pocket")
local rtu         = require("supervisor.session.rtu")

-- Supervisor Sessions Handler

local SV_Q_DATA = svqtypes.SV_Q_DATA

local PLC_S_CMDS = plc.PLC_S_CMDS
local PLC_S_DATA = plc.PLC_S_DATA
local CRD_S_DATA = coordinator.CRD_S_DATA

local svsessions = {}

local SESSION_TYPE = {
    RTU_SESSION = 0,    -- RTU gateway
    PLC_SESSION = 1,    -- reactor PLC
    COORD_SESSION = 2,  -- coordinator
    DIAG_SESSION = 3    -- pocket diagnostics
}

svsessions.SESSION_TYPE = SESSION_TYPE

local self = {
    modem = nil,        ---@type table|nil
    num_reactors = 0,
    facility = nil,     ---@type facility|nil
    sessions = { rtu = {}, plc = {}, coord = {}, diag = {} },
    next_ids = { rtu = 0, plc = 0, coord = 0, diag = 0 }
}

---@alias sv_session_structs plc_session_struct|rtu_session_struct|coord_session_struct|diag_session_struct

-- PRIVATE FUNCTIONS --

-- handle a session output queue
---@param session sv_session_structs
local function _sv_handle_outq(session)
    -- record handler start time
    local handle_start = util.time()

    -- process output queue
    while session.out_queue.ready() do
        -- get a new message to process
        local msg = session.out_queue.pop()

        if msg ~= nil then
            if msg.qtype == mqueue.TYPE.PACKET then
                -- handle a packet to be sent
                self.modem.transmit(session.r_port, session.l_port, msg.message.raw_sendable())
            elseif msg.qtype == mqueue.TYPE.COMMAND then
                -- handle instruction/notification
            elseif msg.qtype == mqueue.TYPE.DATA then
                -- instruction/notification with body
                local cmd = msg.message ---@type queue_data

                if cmd.key < SV_Q_DATA.__END_PLC_CMDS__ then
                    -- PLC commands from coordinator
                    local plc_s = svsessions.get_reactor_session(cmd.val[1])

                    if plc_s ~= nil then
                        if cmd.key == SV_Q_DATA.START then
                            plc_s.in_queue.push_command(PLC_S_CMDS.ENABLE)
                        elseif cmd.key == SV_Q_DATA.SCRAM then
                            plc_s.in_queue.push_command(PLC_S_CMDS.SCRAM)
                        elseif cmd.key == SV_Q_DATA.RESET_RPS then
                            plc_s.in_queue.push_command(PLC_S_CMDS.RPS_RESET)
                        elseif cmd.key == SV_Q_DATA.SET_BURN and type(cmd.val) == "table" and #cmd.val == 2 then
                            plc_s.in_queue.push_data(PLC_S_DATA.BURN_RATE, cmd.val[2])
                        else
                            log.debug(util.c("unknown PLC SV queue command ", cmd.key))
                        end
                    end
                else
                    local crd_s = svsessions.get_coord_session()
                    if crd_s ~= nil then
                        if cmd.key == SV_Q_DATA.CRDN_ACK then
                            -- ack to be sent to coordinator
                            crd_s.in_queue.push_data(CRD_S_DATA.CMD_ACK, cmd.val)
                        elseif cmd.key == SV_Q_DATA.PLC_BUILD_CHANGED then
                            -- a PLC build has changed
                            crd_s.in_queue.push_data(CRD_S_DATA.RESEND_PLC_BUILD, cmd.val)
                        elseif cmd.key == SV_Q_DATA.RTU_BUILD_CHANGED then
                            -- an RTU build has changed
                            crd_s.in_queue.push_data(CRD_S_DATA.RESEND_RTU_BUILD, cmd.val)
                        end
                    end
                end
            end
        end

        -- max 100ms spent processing queue
        if util.time() - handle_start > 100 then
            log.warning("supervisor out queue handler exceeded 100ms queue process limit")
            log.warning(util.c("offending session: port ", session.r_port, " type '", session.s_type, "'"))
            break
        end
    end
end

-- iterate all the given sessions
---@param sessions table
local function _iterate(sessions)
    for i = 1, #sessions do
        local session = sessions[i] ---@type sv_session_structs

        if session.open and session.instance.iterate() then
            _sv_handle_outq(session)
        else
            session.open = false
        end
    end
end

-- cleanly close a session
---@param session sv_session_structs
local function _shutdown(session)
    session.open = false
    session.instance.close()

    -- send packets in out queue (namely the close packet)
    while session.out_queue.ready() do
        local msg = session.out_queue.pop()
        if msg ~= nil and msg.qtype == mqueue.TYPE.PACKET then
            self.modem.transmit(session.r_port, session.l_port, msg.message.raw_sendable())
        end
    end

    log.debug(util.c("closed ", session.s_type, " session ", session.instance.get_id(), " on remote port ", session.r_port))
end

-- close connections
---@param sessions table
local function _close(sessions)
    for i = 1, #sessions do
        local session = sessions[i]  ---@type sv_session_structs
        if session.open then _shutdown(session) end
    end
end

-- check if a watchdog timer event matches that of one of the provided sessions
---@param sessions table
---@param timer_event number
local function _check_watchdogs(sessions, timer_event)
    for i = 1, #sessions do
        local session = sessions[i]  ---@type sv_session_structs
        if session.open then
            local triggered = session.instance.check_wd(timer_event)
            if triggered then
                log.debug(util.c("watchdog closing ", session.s_type, " session ", session.instance.get_id(),
                    " on remote port ", session.r_port, "..."))
                _shutdown(session)
            end
        end
    end
end

-- delete any closed sessions
---@param sessions table
local function _free_closed(sessions)
    local f = function (session) return session.open end

    ---@param session sv_session_structs
    local on_delete = function (session)
        log.debug(util.c("free'ing closed ", session.s_type, " session ", session.instance.get_id(),
            " on remote port ", session.r_port))
    end

    util.filter_table(sessions, f, on_delete)
end

-- find a session by remote port
---@nodiscard
---@param list table
---@param port integer
---@return sv_session_structs|nil
local function _find_session(list, port)
    for i = 1, #list do
        if list[i].r_port == port then return list[i] end
    end
    return nil
end

-- PUBLIC FUNCTIONS --

-- initialize svsessions
---@param modem table
---@param num_reactors integer
---@param cooling_conf table
function svsessions.init(modem, num_reactors, cooling_conf)
    self.modem = modem
    self.num_reactors = num_reactors
    self.facility = facility.new(num_reactors, cooling_conf)
end

-- re-link the modem
---@param modem table
function svsessions.relink_modem(modem)
    self.modem = modem
end

-- find an RTU session by the remote port
---@nodiscard
---@param remote_port integer
---@return rtu_session_struct|nil
function svsessions.find_rtu_session(remote_port)
    -- check RTU sessions
    local session = _find_session(self.sessions.rtu, remote_port)
    ---@cast session rtu_session_struct|nil
    return session
end

-- find a PLC session by the remote port
---@nodiscard
---@param remote_port integer
---@return plc_session_struct|nil
function svsessions.find_plc_session(remote_port)
    -- check PLC sessions
    local session = _find_session(self.sessions.plc, remote_port)
    ---@cast session plc_session_struct|nil
    return session
end

-- find a PLC/RTU session by the remote port
---@nodiscard
---@param remote_port integer
---@return plc_session_struct|rtu_session_struct|nil
function svsessions.find_device_session(remote_port)
    -- check RTU sessions
    local session = _find_session(self.sessions.rtu, remote_port)

    -- check PLC sessions
    if session == nil then session = _find_session(self.sessions.plc, remote_port) end
    ---@cast session plc_session_struct|rtu_session_struct|nil

    return session
end

-- find a coordinator or diagnostic access session by the remote port
---@nodiscard
---@param remote_port integer
---@return coord_session_struct|diag_session_struct|nil
function svsessions.find_svctl_session(remote_port)
    -- check coordinator sessions
    local session = _find_session(self.sessions.coord, remote_port)

    -- check diagnostic sessions
    if session == nil then session = _find_session(self.sessions.diag, remote_port) end
    ---@cast session coord_session_struct|diag_session_struct|nil

    return session
end

-- get the a coordinator session if exists
---@nodiscard
---@return coord_session_struct|nil
function svsessions.get_coord_session()
    return self.sessions.coord[1]
end

-- get a session by reactor ID
---@nodiscard
---@param reactor integer
---@return plc_session_struct|nil session
function svsessions.get_reactor_session(reactor)
    local session = nil

    for i = 1, #self.sessions.plc do
        if self.sessions.plc[i].reactor == reactor then
            session = self.sessions.plc[i]
        end
    end

    return session
end

-- establish a new PLC session
---@nodiscard
---@param local_port integer
---@param remote_port integer
---@param for_reactor integer
---@param version string
---@return integer|false session_id
function svsessions.establish_plc_session(local_port, remote_port, for_reactor, version)
    if svsessions.get_reactor_session(for_reactor) == nil and for_reactor >= 1 and for_reactor <= self.num_reactors then
        ---@class plc_session_struct
        local plc_s = {
            s_type = "plc",
            open = true,
            reactor = for_reactor,
            version = version,
            l_port = local_port,
            r_port = remote_port,
            in_queue = mqueue.new(),
            out_queue = mqueue.new(),
            instance = nil  ---@type plc_session
        }

        plc_s.instance = plc.new_session(self.next_ids.plc, for_reactor, plc_s.in_queue, plc_s.out_queue, config.PLC_TIMEOUT)
        table.insert(self.sessions.plc, plc_s)

        local units = self.facility.get_units()
        units[for_reactor].link_plc_session(plc_s)

        log.debug(util.c("established new PLC session to ", remote_port, " with ID ", self.next_ids.plc, " for reactor ", for_reactor))

        self.next_ids.plc = self.next_ids.plc + 1

        -- success
        return plc_s.instance.get_id()
    else
        -- reactor already assigned to a PLC or ID out of range
        return false
    end
end

-- establish a new RTU session
---@nodiscard
---@param local_port integer
---@param remote_port integer
---@param advertisement table
---@param version string
---@return integer session_id
function svsessions.establish_rtu_session(local_port, remote_port, advertisement, version)
    ---@class rtu_session_struct
    local rtu_s = {
        s_type = "rtu",
        open = true,
        version = version,
        l_port = local_port,
        r_port = remote_port,
        in_queue = mqueue.new(),
        out_queue = mqueue.new(),
        instance = nil  ---@type rtu_session
    }

    rtu_s.instance = rtu.new_session(self.next_ids.rtu, rtu_s.in_queue, rtu_s.out_queue, config.RTU_TIMEOUT, advertisement, self.facility)
    table.insert(self.sessions.rtu, rtu_s)

    log.debug("established new RTU session to " .. remote_port .. " with ID " .. self.next_ids.rtu)

    self.next_ids.rtu = self.next_ids.rtu + 1

    -- success
    return rtu_s.instance.get_id()
end

-- establish a new coordinator session
---@nodiscard
---@param local_port integer
---@param remote_port integer
---@param version string
---@return integer|false session_id
function svsessions.establish_coord_session(local_port, remote_port, version)
    if svsessions.get_coord_session() == nil then
        ---@class coord_session_struct
        local coord_s = {
            s_type = "crd",
            open = true,
            version = version,
            l_port = local_port,
            r_port = remote_port,
            in_queue = mqueue.new(),
            out_queue = mqueue.new(),
            instance = nil  ---@type coord_session
        }

        coord_s.instance = coordinator.new_session(self.next_ids.coord, coord_s.in_queue, coord_s.out_queue, config.CRD_TIMEOUT, self.facility)
        table.insert(self.sessions.coord, coord_s)

        log.debug("established new coordinator session to " .. remote_port .. " with ID " .. self.next_ids.coord)

        self.next_ids.coord = self.next_ids.coord + 1

        -- success
        return coord_s.instance.get_id()
    else
        -- we already have a coordinator linked
        return false
    end
end

-- establish a new pocket diagnostics session
---@nodiscard
---@param local_port integer
---@param remote_port integer
---@param version string
---@return integer|false session_id
function svsessions.establish_diag_session(local_port, remote_port, version)
    ---@class diag_session_struct
    local diag_s = {
        s_type = "pkt",
        open = true,
        version = version,
        l_port = local_port,
        r_port = remote_port,
        in_queue = mqueue.new(),
        out_queue = mqueue.new(),
        instance = nil  ---@type diag_session
    }

    diag_s.instance = pocket.new_session(self.next_ids.diag, diag_s.in_queue, diag_s.out_queue, config.PKT_TIMEOUT)
    table.insert(self.sessions.diag, diag_s)

    log.debug("established new pocket diagnostics session to " .. remote_port .. " with ID " .. self.next_ids.diag)

    self.next_ids.diag = self.next_ids.diag + 1

    -- success
    return diag_s.instance.get_id()
end

-- attempt to identify which session's watchdog timer fired
---@param timer_event number
function svsessions.check_all_watchdogs(timer_event)
    for _, list in pairs(self.sessions) do _check_watchdogs(list, timer_event) end
end

-- iterate all sessions, and update facility/unit data & process control logic
function svsessions.iterate_all()
    -- iterate sessions
    for _, list in pairs(self.sessions) do _iterate(list) end

    -- report RTU sessions to facility
    self.facility.report_rtus(self.sessions.rtu)

    -- iterate facility
    self.facility.update()

    -- iterate units
    self.facility.update_units()
end

-- delete all closed sessions
function svsessions.free_all_closed()
    for _, list in pairs(self.sessions) do _free_closed(list) end
end

-- close all open connections
function svsessions.close_all()
    -- close sessions
    for _, list in pairs(self.sessions) do
        _close(list)
    end

    -- free sessions
    svsessions.free_all_closed()
end

return svsessions
