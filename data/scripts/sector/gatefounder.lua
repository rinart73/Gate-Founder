if onClient() then return end
package.path = package.path .. ";data/scripts/lib/?.lua"
local Placer = include("placer")
local PlanGenerator = include("plangenerator")
local Azimuth = include("azimuthlib-basic")

-- namespace GateFounder
GateFounder = {}

local Log, sector, x, y

function GateFounder.initialize()
    -- load config for logs
    local configOptions = {
      LogLevel = { default = 2, min = 0, max = 4, format = "floor" },
    }
    local config = Azimuth.loadConfig("GateFounder", configOptions)
    Log = Azimuth.logs("GateFounder", config.LogLevel)

    sector = Sector()
    x, y = sector:getCoordinates()
    local gateEntities = {sector:getEntitiesByScript("data/scripts/entity/gate.lua")}

    -- found gates
    local _x_y = "_"..x.."_"..y
    local server = Server()
    local gatesInfo = server:getValue("gate_founder".._x_y)
    if gatesInfo then
        server:setValue("gate_founder".._x_y)
        local gates = gatesInfo:split(";")
        local gate, factionIndex, tx, ty
        if gates then
            for i = 1, #gates do
                gate = gates[i]:split(",")
                factionIndex = tonumber(gate[1])
                tx = tonumber(gate[2])
                ty = tonumber(gate[3])
                Log.Debug("GetValue - spawn a gate %i from (%i:%i) to (%i:%i)", factionIndex, x, y, tx, ty)
                gateEntities[#gateEntities+1] = GateFounder.foundGate(factionIndex, tx, ty, true)
            end
        end
        Placer.resolveIntersections(gateEntities)
    end
    
    -- remove gates
    gatesInfo = server:getValue("gate_destroyer".._x_y)
    if gatesInfo then
        server:setValue("gate_destroyer".._x_y)
        local gates = gatesInfo:split(";")
        local gate, removedKey, factionIndex, tx, ty
        if gates then
            for i = 1, #gates do
                gate = gates[i]:split(",")
                factionIndex = tonumber(gate[1])
                tx = tonumber(gate[2])
                ty = tonumber(gate[3])
                Log.Debug("GetValue - remove a gate of faction %i from (%i:%i) to (%i:%i)", factionIndex, x, y, tx, ty)
                removedKey = GateFounder.destroyGate(factionIndex, tx, ty, gateEntities)
                gateEntities[removedKey] = nil -- remove gate from the list so we don't check it later
            end
        end
    end

    -- toggle gates on/off
    gatesInfo = server:getValue("gate_toggler".._x_y)
    if gatesInfo then
        server:setValue("gate_toggler".._x_y)
        local gates = gatesInfo:split(";")
        local gate, factionIndex, tx, ty, enable
        if gates then
            for i = 1, #gates do
                gate = gates[i]:split(",")
                factionIndex = tonumber(gate[1])
                tx = tonumber(gate[2])
                ty = tonumber(gate[3])
                enable = gate[4] == "1" and true or false
                Log.Debug("GetValue - toggle a gate of faction %i from (%i:%i) to (%i:%i) - %s", factionIndex, x, y, tx, ty, tostring(enable))
                GateFounder.toggleGate(factionIndex, tx, ty, enable, gateEntities)
            end
        end
    end
    
    sector:registerCallback("onPlayerEntered", "onPlayerEntered")
end

function GateFounder.onPlayerEntered() -- trying to solve buggy Toggle behavior
    local gatesInfo = Server():getValue("gate_toggler".."_"..x.."_"..y)
    if gatesInfo then
        Server():setValue("gate_toggler".."_"..x.."_"..y)
        local gates = gatesInfo:split(";")
        local gate, factionIndex, tx, ty, enable
        if gates then
            for i = 1, #gates do
                gate = gates[i]:split(",")
                factionIndex = tonumber(gate[1])
                tx = tonumber(gate[2])
                ty = tonumber(gate[3])
                enable = gate[4] == "1" and true or false
                Log.Debug("GetValue(entered) - toggle a gate of faction %i from (%i:%i) to (%i:%i) - %s", factionIndex, x, y, tx, ty, tostring(enable))
                GateFounder.toggleGate(factionIndex, tx, ty, enable, gateEntities)
            end
        end
    end
end

function GateFounder.foundGate(factionIndex, tx, ty, notRemote)
    Log.Debug("Spawn a gate back for faction %i from (%i:%i) to (%i:%i)", factionIndex, x, y, tx, ty)
    local faction = Faction(factionIndex)

    local desc = EntityDescriptor()
    desc:addComponents(
      ComponentType.Plan,
      ComponentType.BspTree,
      ComponentType.Intersection,
      ComponentType.Asleep,
      ComponentType.DamageContributors,
      ComponentType.BoundingSphere,
      ComponentType.PlanMaxDurability,
      ComponentType.Durability,
      ComponentType.BoundingBox,
      ComponentType.Velocity,
      ComponentType.Physics,
      ComponentType.Scripts,
      ComponentType.ScriptCallback,
      ComponentType.Title,
      ComponentType.Owner,
      ComponentType.FactionNotifier,
      ComponentType.WormHole,
      ComponentType.EnergySystem,
      ComponentType.EntityTransferrer
    )
    local plan = PlanGenerator.makeGatePlan(Seed(faction.index) + Server().seed, faction.color1, faction.color2, faction.color3)
    local dir = vec3(tx - x, 0, ty - y)
    normalize_ip(dir)

    local position = MatrixLookUp(dir, vec3(0, 1, 0))
    position.pos = dir * 2000.0

    desc:setMovePlan(plan)
    desc.position = position
    desc.factionIndex = faction.index
    desc.invincible = true
    desc:addScript("data/scripts/entity/gate.lua")

    local wormhole = desc:getComponent(ComponentType.WormHole)
    wormhole:setTargetCoordinates(tx, ty)
    wormhole.visible = false
    wormhole.visualSize = 50
    wormhole.passageSize = 50
    wormhole.oneWay = true

    if notRemote then
        return sector:createEntity(desc)
    end
    -- remote call - resolve intersections
    local gates = {sector:getEntitiesByScript("data/scripts/entity/gate.lua")}
    gates[#gates+1] = sector:createEntity(desc)
    Placer.resolveIntersections(gates)
end

function GateFounder.destroyGate(factionIndex, tx, ty, gateEntities)
    Log.Debug("Remove a gate of faction %i from (%i:%i) to (%i:%i)", factionIndex, x, y, tx, ty)
    local faction = Faction(factionIndex)
    if not faction then return end
    if not gateEntities then
        gateEntities = {sector:getEntitiesByScript("data/scripts/entity/gate.lua")}
    end
    local wx, wy
    for k, gate in pairs(gateEntities) do
        if gate.factionIndex == factionIndex then
            wx, wy = gate:getWormholeComponent():getTargetCoordinates()
            if wx == tx and wy == ty then
                Log.Debug("Gate found and removed")
                sector:deleteEntity(gate)
                return k
            end
        end
    end
end

function GateFounder.toggleGate(factionIndex, tx, ty, enable, gateEntities)
    Log.Debug("Toggle a gate of faction %i from (%i:%i) to (%i:%i) - %s", factionIndex, x, y, tx, ty, tostring(enable))
    local faction = Faction(factionIndex)
    if not faction then return end
    local isRemote = true
    if not gateEntities then
        isRemote = false
        gateEntities = {sector:getEntitiesByScript("data/scripts/entity/gate.lua")}
    end
    local wh, wx, wy
    for _, gate in pairs(gateEntities) do
        if gate.factionIndex == factionIndex then
            wh = gate:getWormholeComponent()
            wx, wy = wh:getTargetCoordinates()
            if wx == tx and wy == ty then
                Log.Debug("Gate found and toggled")
                wh.enabled = enable
                gate:invokeFunction("data/scripts/entity/gate.lua", "updateTooltip", nil, true) -- Integration: Compass-like Gate Pixel Icons
                return
            end
        end
    end
    if isRemote then
        Log.Debug("Failed to toggle a gate. Saving this instruction for later")
        local gatesInfo = Server():getValue("gate_toggler_"..x.."_"..y)
        if gatesInfo then
            gatesInfo = gatesInfo..";"..factionIndex..","..tx..","..ty..","..(enable and "0" or "1")
        else
            gatesInfo = factionIndex..","..tx..","..ty..","..(enable and "0" or "1")
        end
        Server():setValue("gate_toggler_"..x.."_"..y, gatesInfo)
    else
        Log.Debug("Failed to toggle a gate a second time. Oh well")
    end
end