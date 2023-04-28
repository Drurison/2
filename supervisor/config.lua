local config = {}

-- scada network listen for PLC's and RTU's
config.SCADA_DEV_LISTEN = 16000
-- listen port for SCADA supervisor access
config.SCADA_SV_CTL_LISTEN = 16100
-- max trusted modem message distance (0 to disable check)
config.TRUSTED_RANGE = 0
-- time in seconds (>= 2) before assuming a remote device is no longer active
config.PLC_TIMEOUT = 5
config.RTU_TIMEOUT = 5
config.CRD_TIMEOUT = 5
config.PKT_TIMEOUT = 5

-- expected number of reactors
config.NUM_REACTORS = 1
-- expected number of boilers/turbines for each reactor
config.REACTOR_COOLING = {
    { BOILERS = 1, TURBINES = 1 },  -- reactor unit 1
}

-- log path
config.LOG_PATH = "/log.txt"
-- log mode
--  0 = APPEND (adds to existing file on start)
--  1 = NEW (replaces existing file on start)
config.LOG_MODE = 0

return config
