local rtu = require("rtu.rtu")

local boilerv_rtu = {}

-- create new boiler (mek 10.1+) device
---@param boiler table
boilerv_rtu.new = function (boiler)
    local self = {
        rtu = rtu.init_unit(),
        boiler = boiler
    }

    -- discrete inputs --
    self.rtu.connect_di(self.boiler.isFormed)

    -- coils --
    -- none

    -- input registers --
    -- multiblock properties
    self.rtu.connect_input_reg(self.boiler.getLength)
    self.rtu.connect_input_reg(self.boiler.getWidth)
    self.rtu.connect_input_reg(self.boiler.getHeight)
    self.rtu.connect_input_reg(self.boiler.getMinPos)
    self.rtu.connect_input_reg(self.boiler.getMaxPos)
    -- build properties
    self.rtu.connect_input_reg(self.boiler.getBoilCapacity)
    self.rtu.connect_input_reg(self.boiler.getSteamCapacity)
    self.rtu.connect_input_reg(self.boiler.getWaterCapacity)
    self.rtu.connect_input_reg(self.boiler.getHeatedCoolantCapacity)
    self.rtu.connect_input_reg(self.boiler.getCooledCoolantCapacity)
    self.rtu.connect_input_reg(self.boiler.getSuperheaters)
    self.rtu.connect_input_reg(self.boiler.getMaxBoilRate)
    self.rtu.connect_input_reg(self.boiler.getEnvironmentalLoss)
    -- current state
    self.rtu.connect_input_reg(self.boiler.getTemperature)
    self.rtu.connect_input_reg(self.boiler.getBoilRate)
    -- tanks
    self.rtu.connect_input_reg(self.boiler.getSteam)
    self.rtu.connect_input_reg(self.boiler.getSteamNeeded)
    self.rtu.connect_input_reg(self.boiler.getSteamFilledPercentage)
    self.rtu.connect_input_reg(self.boiler.getWater)
    self.rtu.connect_input_reg(self.boiler.getWaterNeeded)
    self.rtu.connect_input_reg(self.boiler.getWaterFilledPercentage)
    self.rtu.connect_input_reg(self.boiler.getHeatedCoolant)
    self.rtu.connect_input_reg(self.boiler.getHeatedCoolantNeeded)
    self.rtu.connect_input_reg(self.boiler.getHeatedCoolantFilledPercentage)
    self.rtu.connect_input_reg(self.boiler.getCooledCoolant)
    self.rtu.connect_input_reg(self.boiler.getCooledCoolantNeeded)
    self.rtu.connect_input_reg(self.boiler.getCooledCoolantFilledPercentage)

    -- holding registers --
    -- none

    return self.rtu.interface()
end

return boilerv_rtu
