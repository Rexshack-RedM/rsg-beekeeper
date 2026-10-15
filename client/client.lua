local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

local Beehive = Config.Beehive
local PTFX_DICT = 'core'

local hives = {}          -- [id] = { id, coords, heading, prop, citizenid, active, isFull, isCalm, entity, ptfx, point }
local entityToId = {}     -- [entity] = id
local openHiveId = nil

local function Notify(description, notifyType)
    lib.notify({ title = locale('title_beehive'), description = description, type = notifyType or 'inform', duration = 5000 })
end

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

local function LoadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelValid(hash) then return nil end

    local ok = pcall(lib.requestModel, hash, 5000)
    return ok and hash or nil
end

--------------------------------------------------------------------------------------------------
-- Bee swarm ptfx
--------------------------------------------------------------------------------------------------

local function HasPtfxLoaded(dictHash)
    -- Raw InvokeNative returns an integer; 0 is truthy in Lua.
    return Citizen.InvokeNative(0x65BB72F29138F5D6, dictHash) ~= 0 -- HasNamedPtfxAssetLoaded
end

local function StopBeeSwarm(hive)
    if hive.ptfx then
        Citizen.InvokeNative(0x22970F3A088B133B, hive.ptfx, false) -- StopParticleFxLooped
        hive.ptfx = nil
    end
end

-- (Re)starts the swarm for a spawned, full hive -- calm or angry variant.
local function RefreshBeeSwarm(hive)
    StopBeeSwarm(hive)
    if not hive.entity or not hive.isFull then return end

    local dictHash = joaat(PTFX_DICT)
    if not HasPtfxLoaded(dictHash) then
        Citizen.InvokeNative(0xF2B2353BBC0D4E8F, dictHash) -- RequestNamedPtfxAsset
        local timeout = GetGameTimer() + 5000
        while not HasPtfxLoaded(dictHash) and GetGameTimer() < timeout do
            Wait(0)
        end
        if not HasPtfxLoaded(dictHash) then return end
    end

    -- The hive may have despawned while we waited on the asset.
    if not hive.entity then return end

    local smoker = Beehive.smoker
    local fxName = hive.isCalm and smoker.calmPtfx or smoker.angryPtfx
    local c = hive.coords

    Citizen.InvokeNative(0xA10DB07FC234DD12, PTFX_DICT) -- UseParticleFxAsset
    local handle = Citizen.InvokeNative(0xBA32867E86125D3A, fxName, c.x, c.y, c.z + 0.4, 0.0, 0.0, 0.0, 1.0, false, false, false, false) -- StartParticleFxLoopedAtCoord

    if handle and handle ~= 0 then
        hive.ptfx = handle
    end
end

--------------------------------------------------------------------------------------------------
-- Hive streaming (only hives near the player exist as entities)
--------------------------------------------------------------------------------------------------

local function SpawnHiveEntity(hive)
    if hive.entity or hive.loading then return end
    hive.loading = true

    local hash = LoadModel(hive.prop) or LoadModel(Beehive.prop)
    hive.loading = false

    -- The player may have walked off, or the hive been removed, while the
    -- model was streaming in.
    if not hash or not hive.inRange or hives[hive.id] ~= hive or hive.entity then return end

    local entity = CreateObject(hash, hive.coords.x, hive.coords.y, hive.coords.z, false, false, false)
    SetEntityHeading(entity, hive.heading)
    FreezeEntityPosition(entity, true)
    SetModelAsNoLongerNeeded(hash)

    hive.entity = entity
    entityToId[entity] = hive.id

    RefreshBeeSwarm(hive)
end

local function DespawnHiveEntity(hive)
    StopBeeSwarm(hive)

    if hive.entity then
        entityToId[hive.entity] = nil
        if DoesEntityExist(hive.entity) then
            DeleteEntity(hive.entity)
        end
        hive.entity = nil
    end
end

local function CloseHiveUI()
    if not openHiveId then return end
    openHiveId = nil
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

local function RemoveHive(id)
    local hive = hives[id]
    if not hive then return end

    if openHiveId == id then CloseHiveUI() end

    DespawnHiveEntity(hive)
    hive.inRange = false
    if hive.point then hive.point:remove() end
    hives[id] = nil
end

local function AddHive(data)
    local id = tonumber(data.id)
    if not id then return end

    RemoveHive(id)

    local hive = {
        id = id,
        coords = vector3(data.x, data.y, data.z),
        heading = tonumber(data.heading) or 0.0,
        prop = data.prop or Beehive.prop,
        citizenid = data.citizenid,
        active = data.active == true,
        isFull = data.isFull == true,
        isCalm = data.isCalm == true,
    }

    hive.point = lib.points.new({
        coords = hive.coords,
        distance = Beehive.renderDistance,
        onEnter = function()
            hive.inRange = true
            CreateThread(function() SpawnHiveEntity(hive) end)
        end,
        onExit = function()
            hive.inRange = false
            DespawnHiveEntity(hive)
        end,
    })

    hives[id] = hive
end

--------------------------------------------------------------------------------------------------
-- Placement (shared gizmo in client/placement.lua, same as rsg-farming)
--------------------------------------------------------------------------------------------------

RegisterNetEvent('rsg-beekeeper:client:startPlacement', function(prop)
    if Placement.Active then
        return Notify(locale('placement_already_placing'), 'error')
    end

    local spacing = Config.Placement.minHiveSpacing
    local coords, heading = Placement.Start(prop, function(pos)
        for _, hive in pairs(hives) do
            if #(hive.coords - pos) < spacing then
                return false, locale('place_too_close')
            end
        end
        return true
    end, locale('placement_cannot_place'))

    if not coords then
        return Notify(locale('placement_cancelled'), 'inform')
    end

    TriggerServerEvent('rsg-beekeeper:server:placeBeehive', coords, heading, prop)
end)

--------------------------------------------------------------------------------------------------
-- ox_target
--------------------------------------------------------------------------------------------------

local beeHiveModels = {}
for _, entry in ipairs(Config.BeeHiveProps) do
    beeHiveModels[#beeHiveModels + 1] = entry.prop
end

exports.ox_target:addModel(beeHiveModels, {
    {
        name = 'rsg_beekeeper_manage_beehive',
        icon = Beehive.target.icon,
        label = locale('target_manage_beehive'),
        distance = Beehive.target.distance,
        canInteract = function(entity)
            return entityToId[entity] ~= nil and not Placement.Active
        end,
        onSelect = function(data)
            local id = entityToId[data.entity]
            if id then
                TriggerServerEvent('rsg-beekeeper:server:getHiveInfo', id)
            end
        end,
    },
})

--------------------------------------------------------------------------------------------------
-- Management UI (NUI)
--------------------------------------------------------------------------------------------------

local NUI_LOCALE_KEYS = {
    panelTitle = 'nui_panel_title',
    closeTitle = 'nui_close_title',
    statusActive = 'nui_status_active',
    statusInactive = 'nui_status_inactive',
    statusWorking = 'nui_status_working',
    inactiveFlavorText = 'nui_inactive_flavor_text',
    addQueenLabel = 'nui_add_queen_label',
    addQueenSub = 'nui_add_queen_sub',
    activeFlavorText = 'nui_active_flavor_text',
    populationLabel = 'nui_population_label',
    upkeepNotice = 'nui_upkeep_notice',
    foodLabel = 'nui_food_label',
    addFoodBtn = 'nui_add_food_btn',
    waterLabel = 'nui_water_label',
    addWaterBtn = 'nui_add_water_btn',
    healthLabel = 'nui_health_label',
    honeyLabel = 'nui_honey_label',
    harvestHoneyBtn = 'nui_harvest_honey_btn',
    busyFlavorText = 'nui_busy_flavor_text',
    pickupLabel = 'nui_pickup_label',
    pickupSub = 'nui_pickup_sub',
    pickupConfirm = 'nui_pickup_confirm',
    notOwnerNote = 'nui_not_owner_note',
}

RegisterNUICallback('nuiReady', function(_, cb)
    local strings = {}
    for key, localeKey in pairs(NUI_LOCALE_KEYS) do
        strings[key] = locale(localeKey)
    end
    SendNUIMessage({ action = 'locale', strings = strings })
    cb({})
end)

-- Closes the panel automatically if the player walks away from the hive.
local function WatchDistance(id)
    CreateThread(function()
        local maxDist = Beehive.target.distance + 2.0
        while openHiveId == id do
            local hive = hives[id]
            if not hive or #(GetEntityCoords(PlayerPedId()) - hive.coords) > maxDist then
                CloseHiveUI()
                break
            end
            Wait(500)
        end
    end)
end

local function SyncHiveState(data)
    local hive = hives[data.id]
    if not hive then return end

    local isFull = data.active and data.population >= data.max
    if hive.active ~= data.active or hive.isFull ~= isFull then
        hive.active = data.active
        hive.isFull = isFull
        RefreshBeeSwarm(hive)
    end
end

RegisterNetEvent('rsg-beekeeper:client:openHiveUI', function(data)
    if Placement.Active then return end

    SyncHiveState(data)
    openHiveId = data.id
    SetNuiFocus(true, true)
    data.action = 'open'
    SendNUIMessage(data)
    WatchDistance(data.id)
end)

RegisterNetEvent('rsg-beekeeper:client:updateHiveUI', function(data)
    SyncHiveState(data)
    if openHiveId ~= data.id then return end
    data.action = 'update'
    SendNUIMessage(data)
end)

-- Result of any hive action (queen / food / water / harvest / failed pickup).
RegisterNetEvent('rsg-beekeeper:client:actionResult', function(data)
    if data.success then SyncHiveState(data) end

    if openHiveId == data.id then
        data.action = 'result'
        SendNUIMessage(data)
    end

    Notify(data.message, data.success and 'success' or 'error')
end)

RegisterNetEvent('rsg-beekeeper:client:hiveGone', function(id, message)
    RemoveHive(id)
    Notify(message, 'error')
end)

RegisterNUICallback('closeBeehiveUI', function(_, cb)
    openHiveId = nil
    SetNuiFocus(false, false)
    cb({})
end)

RegisterNUICallback('refreshHiveInfo', function(data, cb)
    local id = tonumber(data and data.id)
    if id and id == openHiveId then
        TriggerServerEvent('rsg-beekeeper:server:getHiveInfo', id, true)
    end
    cb({})
end)

-- All panel actions funnel through one callback; the server validates the rest.
local ACTION_EVENTS = {
    addQueenBee = 'rsg-beekeeper:server:addQueenBee',
    addFood = 'rsg-beekeeper:server:addHiveResource',
    addWater = 'rsg-beekeeper:server:addHiveResource',
    harvestHoney = 'rsg-beekeeper:server:harvestHoney',
    pickupBeehive = 'rsg-beekeeper:server:pickupBeehive',
}

RegisterNUICallback('hiveAction', function(data, cb)
    local id = tonumber(data and data.id)
    local eventName = data and ACTION_EVENTS[data.action]

    if id and id == openHiveId and eventName then
        if data.action == 'addFood' then
            TriggerServerEvent(eventName, id, 'food')
        elseif data.action == 'addWater' then
            TriggerServerEvent(eventName, id, 'water')
        else
            TriggerServerEvent(eventName, id)
        end
    end
    cb({})
end)

--------------------------------------------------------------------------------------------------
-- Server -> client state sync
--------------------------------------------------------------------------------------------------

RegisterNetEvent('rsg-beekeeper:client:spawnBeehive', function(data)
    AddHive(data)
end)

RegisterNetEvent('rsg-beekeeper:client:loadBeehives', function(list)
    for id in pairs(hives) do
        RemoveHive(id)
    end
    for _, data in ipairs(list) do
        AddHive(data)
    end
end)

RegisterNetEvent('rsg-beekeeper:client:removeBeehive', function(id)
    RemoveHive(id)
end)

RegisterNetEvent('rsg-beekeeper:client:beehiveActivated', function(id)
    local hive = hives[id]
    if hive then hive.active = true end
end)

RegisterNetEvent('rsg-beekeeper:client:beehiveFull', function(id)
    local hive = hives[id]
    if not hive then return end
    hive.isFull = true
    RefreshBeeSwarm(hive)
end)

RegisterNetEvent('rsg-beekeeper:client:hiveSmoked', function(id)
    local hive = hives[id]
    if not hive then return end
    hive.isCalm = true
    RefreshBeeSwarm(hive)
end)

RegisterNetEvent('rsg-beekeeper:client:hiveCalmExpired', function(id)
    local hive = hives[id]
    if not hive then return end
    hive.isCalm = false
    RefreshBeeSwarm(hive)
end)

-- Colony starved: the hive stays placed but goes back to empty/unqueened.
RegisterNetEvent('rsg-beekeeper:client:colonyDied', function(id)
    local hive = hives[id]
    if not hive then return end

    hive.active, hive.isFull, hive.isCalm = false, false, false
    StopBeeSwarm(hive)

    if openHiveId == id then
        SendNUIMessage({ action = 'update', id = id, active = false, population = 0, max = Beehive.population.max })
    end

    -- Only tell the owner -- nobody else needs a server-wide death notice.
    local PlayerData = RSGCore.Functions.GetPlayerData()
    if PlayerData and PlayerData.citizenid == hive.citizenid then
        Notify(locale('hive_colony_died'), 'error')
    end
end)

local function RequestHives()
    TriggerServerEvent('rsg-beekeeper:server:requestBeehives')
end

RegisterNetEvent('RSGCore:Client:OnPlayerLoaded', RequestHives)

RegisterNetEvent('RSGCore:Client:OnPlayerUnload', function()
    CloseHiveUI()
    for id in pairs(hives) do
        RemoveHive(id)
    end
end)

CreateThread(function()
    if LocalPlayer.state.isLoggedIn then
        RequestHives()
    end
end)

--------------------------------------------------------------------------------------------------
-- Stinging (angry, full hives hurt players who get too close)
--------------------------------------------------------------------------------------------------

CreateThread(function()
    local cfg = Beehive.smoker

    while true do
        Wait(cfg.damageIntervalMs)

        local ped = PlayerPedId()
        if not IsEntityDead(ped) then
            local pedCoords = GetEntityCoords(ped)

            for _, hive in pairs(hives) do
                -- Only spawned (nearby) hives can sting, which keeps this loop tiny.
                if hive.entity and hive.isFull and not hive.isCalm and #(pedCoords - hive.coords) <= cfg.dangerRadius then
                    local floorHealth = math.floor(GetEntityMaxHealth(ped) * cfg.minHealthFraction)
                    local current = GetEntityHealth(ped)
                    if current > floorHealth then
                        SetEntityHealth(ped, math.max(current - cfg.damageAmount, floorHealth))
                    end
                    break -- one sting per tick, however many hives are close
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------------------------

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then return end

    Placement.Cancel()
    CloseHiveUI()

    for id in pairs(hives) do
        RemoveHive(id)
    end
end)
