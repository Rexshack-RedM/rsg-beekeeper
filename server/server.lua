local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

local Beehive = Config.Beehive
local POP_MAX = Beehive.population.max
local BEES_PER_INTERVAL = math.max(1, math.floor(tonumber(Beehive.population.beesPerInterval) or 1))
-- Seconds from activation until a hive reaches max population.
local TIME_TO_FULL = Beehive.population.growthIntervalSeconds * math.ceil(POP_MAX / BEES_PER_INTERVAL)
local INTERACT_RANGE = Beehive.target.distance + Config.ProximityBuffer

local RestoreSchedules -- defined below; runs once the table is confirmed to exist

--------------------------------------------------------------------------------------------------
-- Database bootstrap
--------------------------------------------------------------------------------------------------

-- Creates the rsg_beehives table on startup so operators don't have to import
-- installation/rsg_beehives.sql by hand (that file is kept as a reference).
MySQL.ready(function()
    local ok = pcall(MySQL.query.await, [[
        CREATE TABLE IF NOT EXISTS `rsg_beehives` (
          `id` INT NOT NULL AUTO_INCREMENT,
          `citizenid` VARCHAR(50) DEFAULT NULL,
          `x` FLOAT NOT NULL,
          `y` FLOAT NOT NULL,
          `z` FLOAT NOT NULL,
          `heading` FLOAT NOT NULL DEFAULT 0,
          `active` TINYINT(1) NOT NULL DEFAULT 0,
          `activated_at` INT UNSIGNED DEFAULT NULL,
          `food` TINYINT UNSIGNED NOT NULL DEFAULT 100,
          `water` TINYINT UNSIGNED NOT NULL DEFAULT 100,
          `health` TINYINT UNSIGNED NOT NULL DEFAULT 100,
          `honey` TINYINT UNSIGNED NOT NULL DEFAULT 0,
          `smoked_until` INT UNSIGNED DEFAULT NULL,
          `prop` VARCHAR(50) NOT NULL DEFAULT 'bee_house_gk_1',
          `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
          PRIMARY KEY (`id`),
          KEY `idx_citizenid` (`citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    if not ok then
        print('^1[rsg-beekeeper]^7 Failed to create/verify the rsg_beehives table -- check your database connection and oxmysql setup.')
        return
    end

    print('^2[rsg-beekeeper]^7 Database ready.')
    RestoreSchedules()
end)

--------------------------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------------------------

local function Notify(source, description, notifyType)
    TriggerClientEvent('ox_lib:notify', source, {
        title = locale('title_beehive'),
        description = description,
        type = notifyType or 'inform',
        duration = 5000,
    })
end

local function BroadcastToAll(eventName, ...)
    TriggerClientEvent(eventName, -1, ...)
end

local function IsActive(value)
    return value == 1 or value == true
end

local function ItemLabel(itemName)
    local item = RSGCore.Shared.Items[itemName]
    return item and item.label or itemName
end

-- Server-side distance check against the player's real ped position -- every
-- net event below can be fired by a modified client with arbitrary arguments,
-- so never trust ox_target's client-side distance gate on its own.
local function IsPlayerNearCoords(source, x, y, z, maxDistance)
    local ped = GetPlayerPed(source)
    if not ped or ped == 0 then return false end

    return #(GetEntityCoords(ped) - vector3(x, y, z)) <= maxDistance
end

local function CanCarry(source, itemName, amount)
    local ok, result = pcall(function()
        return exports['rsg-inventory']:CanAddItem(source, itemName, amount)
    end)
    -- If the export isn't available, fall back to letting AddItem decide.
    return not ok or result ~= false
end

-- One action at a time per player. Stops a modified client from firing the
-- same (or different) item-moving events back-to-back while an earlier
-- request's async DB work is still in flight -- the root cause of most
-- duplication exploits in persistent-prop scripts.
local busy = {}

local function Lock(source)
    if busy[source] then return false end
    busy[source] = true
    return true
end

local function Unlock(source)
    busy[source] = nil
end

-- Runs fn while holding the player's action lock, always releasing it --
-- even if fn errors part-way through.
local function WithLock(source, fn)
    if not Lock(source) then return end
    local ok, err = pcall(fn)
    Unlock(source)
    if not ok then
        print(('^1[rsg-beekeeper]^7 %s'):format(err))
    end
end

AddEventHandler('playerDropped', function()
    busy[source] = nil
end)

--------------------------------------------------------------------------------------------------
-- Webhook helpers
--------------------------------------------------------------------------------------------------

local function GetPlayerWebhookFields(source, Player)
    local charinfo = Player.PlayerData.charinfo or {}
    local fullName = ('%s %s'):format(charinfo.firstname or '', charinfo.lastname or ''):match('^%s*(.-)%s*$')
    if fullName == '' then fullName = locale('unknown_value') end

    return {
        { name = locale('webhook_field_player'), value = ('%s (%s)'):format(fullName, GetPlayerName(source) or locale('unknown_value')), inline = true },
        { name = locale('webhook_field_citizenid'), value = Player.PlayerData.citizenid or locale('unknown_value'), inline = true },
    }
end

local function AppendField(fields, name, value, inline)
    fields[#fields + 1] = { name = name, value = tostring(value), inline = inline ~= false }
    return fields
end

local function FormatCoords(x, y, z)
    return ('%.2f, %.2f, %.2f'):format(x, y, z)
end

--------------------------------------------------------------------------------------------------
-- Population
--------------------------------------------------------------------------------------------------

-- Population is derived from the activation timestamp rather than stored, so
-- it keeps growing across restarts without a ticking loop.
local function CalculatePopulation(activatedAt)
    activatedAt = tonumber(activatedAt)
    if not activatedAt then return 0 end

    local elapsed = os.time() - activatedAt
    if elapsed <= 0 then return 0 end

    return math.min(POP_MAX, math.floor(elapsed / Beehive.population.growthIntervalSeconds) * BEES_PER_INTERVAL)
end

local function IsHiveFull(row)
    return IsActive(row.active) and CalculatePopulation(row.activated_at) >= POP_MAX
end

local function IsHiveCalm(smokedUntil)
    smokedUntil = tonumber(smokedUntil)
    return smokedUntil ~= nil and smokedUntil > os.time()
end

--------------------------------------------------------------------------------------------------
-- Scheduled state changes (hive full / calm expired)
--------------------------------------------------------------------------------------------------

-- Fires exactly when a hive's population reaches max. When the timer fires it
-- re-checks the row, so a hive that died, was picked up or was re-queened in
-- the meantime doesn't get a stale "full" broadcast.
local function ScheduleHiveFullCheck(id, activatedAt)
    activatedAt = tonumber(activatedAt)
    if not activatedAt then return end

    local fullAt = activatedAt + TIME_TO_FULL
    local remaining = math.max(0, fullAt - os.time())

    SetTimeout(remaining * 1000, function()
        local row = MySQL.single.await('SELECT active, activated_at FROM rsg_beehives WHERE id = ?', { id })
        if row and IsActive(row.active) and tonumber(row.activated_at) == activatedAt then
            BroadcastToAll('rsg-beekeeper:client:beehiveFull', id)
        end
    end)
end

local function ScheduleCalmExpiry(id, smokedUntil)
    smokedUntil = tonumber(smokedUntil)
    if not smokedUntil then return end

    local remaining = smokedUntil - os.time()
    if remaining <= 0 then return end

    SetTimeout(remaining * 1000, function()
        BroadcastToAll('rsg-beekeeper:client:hiveCalmExpired', id)
    end)
end

RestoreSchedules = function()
    local rows = MySQL.query.await('SELECT id, active, activated_at, smoked_until FROM rsg_beehives WHERE active = 1') or {}
    local now = os.time()

    for _, row in ipairs(rows) do
        -- Backfill any active hive missing a timestamp so its growth isn't
        -- stuck at 0 forever.
        if not tonumber(row.activated_at) then
            row.activated_at = now
            MySQL.update('UPDATE rsg_beehives SET activated_at = ? WHERE id = ?', { now, row.id })
        end

        if CalculatePopulation(row.activated_at) < POP_MAX then
            ScheduleHiveFullCheck(row.id, row.activated_at)
        end
        ScheduleCalmExpiry(row.id, row.smoked_until)
    end
end

--------------------------------------------------------------------------------------------------
-- Upkeep (food / water / health / honey)
--------------------------------------------------------------------------------------------------

-- Only fully grown colonies consume food/water. Each tick food/water decay; if
-- either is at 0 health decays instead of regenerating. Health hitting 0 kills
-- the colony and queen -- the hive stays placed but resets to empty/inactive.
-- Honey only progresses while the colony is fed.
--
-- The whole tick runs as one UPDATE instead of one query per hive. MySQL
-- applies SET assignments left to right, so health/honey see the already
-- decayed food/water values. IF() guards keep the unsigned columns from
-- underflowing (food - 5 on an unsigned 3 would error in strict mode).
local function KillColony(hive)
    local affected = MySQL.update.await([[
        UPDATE rsg_beehives SET active = 0, activated_at = NULL, smoked_until = NULL, food = 100, water = 100, health = 100, honey = 0
        WHERE id = ? AND active = 1
    ]], { hive.id })
    if not affected or affected == 0 then return end

    BroadcastToAll('rsg-beekeeper:client:colonyDied', hive.id)

    BeekeeperWebhook.Send('died', locale('webhook_title_died'), locale('webhook_description_died'), {
        { name = locale('webhook_field_hive_id'), value = tostring(hive.id), inline = true },
        { name = locale('webhook_field_owner_citizenid'), value = hive.citizenid or locale('unknown_value'), inline = true },
        { name = locale('webhook_field_coords'), value = FormatCoords(hive.x, hive.y, hive.z), inline = false },
    })
end

local function RunUpkeepTick()
    local cfg = Beehive.upkeep
    local fullBefore = os.time() - TIME_TO_FULL

    MySQL.update.await([[
        UPDATE rsg_beehives SET
            food   = IF(food  > ?, food  - ?, 0),
            water  = IF(water > ?, water - ?, 0),
            health = IF(food > 0 AND water > 0, LEAST(100, health + ?), IF(health > ?, health - ?, 0)),
            honey  = IF(food > 0 AND water > 0, LEAST(100, honey + ?), honey)
        WHERE active = 1 AND activated_at IS NOT NULL AND activated_at <= ?
    ]], {
        cfg.foodDecayPerTick, cfg.foodDecayPerTick,
        cfg.waterDecayPerTick, cfg.waterDecayPerTick,
        cfg.healthRegenPerTick, cfg.healthDecayPerTick, cfg.healthDecayPerTick,
        Beehive.honey.honeyPerTick,
        fullBefore,
    })

    local dead = MySQL.query.await('SELECT id, citizenid, x, y, z FROM rsg_beehives WHERE active = 1 AND health = 0') or {}
    for _, hive in ipairs(dead) do
        KillColony(hive)
    end
end

CreateThread(function()
    local interval = Beehive.upkeep.tickIntervalSeconds * 1000
    while true do
        Wait(interval)
        local ok, err = pcall(RunUpkeepTick)
        if not ok then print(('^1[rsg-beekeeper]^7 Upkeep tick failed: %s'):format(err)) end
    end
end)

--------------------------------------------------------------------------------------------------
-- Useable items
--------------------------------------------------------------------------------------------------

local propEntries = {} -- [prop] = Config.BeeHiveProps entry
for _, entry in ipairs(Config.BeeHiveProps) do
    propEntries[entry.prop] = entry

    RSGCore.Functions.CreateUseableItem(entry.item, function(source)
        if not RSGCore.Functions.GetPlayer(source) then return end
        TriggerClientEvent('rsg-beekeeper:client:startPlacement', source, entry.prop)
    end)
end

-- Bee smoker: calms the closest full, active hive within interaction range.
-- Uses are stored in the item's metadata so each smoker tracks its own count.
RSGCore.Functions.CreateUseableItem(Beehive.smoker.item, function(source, item)
    WithLock(source, function()
        local Player = RSGCore.Functions.GetPlayer(source)
        if not Player then return end

        local ped = GetPlayerPed(source)
        if not ped or ped == 0 then return end

        local coords = GetEntityCoords(ped)
        local cfg = Beehive.smoker

        -- Bounding-box pre-filter keeps this cheap with lots of hives.
        local rows = MySQL.query.await([[
            SELECT id, x, y, z, active, activated_at, smoked_until FROM rsg_beehives
            WHERE active = 1 AND x BETWEEN ? AND ? AND y BETWEEN ? AND ?
        ]], {
            coords.x - INTERACT_RANGE, coords.x + INTERACT_RANGE,
            coords.y - INTERACT_RANGE, coords.y + INTERACT_RANGE,
        }) or {}

        local closest, closestDist = nil, INTERACT_RANGE
        for _, row in ipairs(rows) do
            local dist = #(coords - vector3(row.x, row.y, row.z))
            if dist <= closestDist then
                closest, closestDist = row, dist
            end
        end

        if not closest then
            return Notify(source, locale('smoker_no_hive_nearby'), 'error')
        end

        if not IsHiveFull(closest) then
            return Notify(source, locale('smoker_hive_not_swarming'), 'inform')
        end

        if IsHiveCalm(closest.smoked_until) then
            return Notify(source, locale('hive_already_calm'), 'inform')
        end

        -- Re-read the smoker from the player's inventory rather than trusting
        -- the item table passed to the callback (it can be stale).
        local smoker = item and item.slot and exports['rsg-inventory']:GetItemBySlot(source, item.slot)
        if not smoker or smoker.name ~= cfg.item then return end

        local usesLeft = ((smoker.info and tonumber(smoker.info.uses)) or cfg.totalUses) - 1

        -- Claim the hive first with a conditional update, so two players
        -- smoking the same hive at once can't both burn a use, and a failed
        -- DB write never costs the player a use.
        local now = os.time()
        local smokedUntil = now + cfg.calmDurationSeconds
        local affected = MySQL.update.await([[
            UPDATE rsg_beehives SET smoked_until = ?
            WHERE id = ? AND active = 1 AND (smoked_until IS NULL OR smoked_until <= ?)
        ]], { smokedUntil, closest.id, now })
        if not affected or affected == 0 then
            return Notify(source, locale('hive_already_calm'), 'inform')
        end

        if not Player.Functions.RemoveItem(cfg.item, 1, smoker.slot) then
            MySQL.update.await('UPDATE rsg_beehives SET smoked_until = ? WHERE id = ?', { closest.smoked_until, closest.id })
            return
        end

        if usesLeft > 0 then
            Player.Functions.AddItem(cfg.item, 1, smoker.slot, { uses = usesLeft })
        else
            TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[cfg.item], 'remove', 1)
        end

        BroadcastToAll('rsg-beekeeper:client:hiveSmoked', closest.id)
        ScheduleCalmExpiry(closest.id, smokedUntil)

        Notify(source, usesLeft > 0 and locale('smoker_used_success', usesLeft) or locale('smoker_used_last'), 'success')
    end)
end)

--------------------------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------------------------

RegisterNetEvent('rsg-beekeeper:server:placeBeehive', function(coords, heading, prop)
    local source = source

    WithLock(source, function()
        local Player = RSGCore.Functions.GetPlayer(source)
        if not Player then return end

        if type(coords) ~= 'vector3' and type(coords) ~= 'table' then return end
        local x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
        if not x or not y or not z then return end

        heading = (tonumber(heading) or 0.0) % 360.0

        -- The prop decides which item gets consumed, so it must be configured.
        local entry = type(prop) == 'string' and propEntries[prop]
        if not entry then return end

        if not IsPlayerNearCoords(source, x, y, z, Config.Placement.maxDistance + Config.ProximityBuffer) then return end

        -- Same spacing rule the client gizmo enforces.
        local spacing = Config.Placement.minHiveSpacing
        local nearby = MySQL.scalar.await([[
            SELECT COUNT(*) FROM rsg_beehives
            WHERE x BETWEEN ? AND ? AND y BETWEEN ? AND ?
              AND POW(x - ?, 2) + POW(y - ?, 2) + POW(z - ?, 2) < ?
        ]], { x - spacing, x + spacing, y - spacing, y + spacing, x, y, z, spacing * spacing }) or 0
        if nearby > 0 then
            return Notify(source, locale('place_too_close'), 'error')
        end

        local citizenid = Player.PlayerData.citizenid

        if Beehive.maxHivesPerPlayer and Beehive.maxHivesPerPlayer > 0 then
            local count = MySQL.scalar.await('SELECT COUNT(*) FROM rsg_beehives WHERE citizenid = ?', { citizenid }) or 0
            if count >= Beehive.maxHivesPerPlayer then
                return Notify(source, locale('hive_max_reached', Beehive.maxHivesPerPlayer), 'error')
            end
        end

        if not Player.Functions.GetItemByName(entry.item) then return end
        if not Player.Functions.RemoveItem(entry.item, 1) then return end
        TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[entry.item], 'remove', 1)

        local insertId = MySQL.insert.await('INSERT INTO rsg_beehives (citizenid, x, y, z, heading, prop) VALUES (?, ?, ?, ?, ?, ?)', {
            citizenid, x, y, z, heading, entry.prop,
        })

        if not insertId then
            -- Refund the item rather than silently eating it.
            Player.Functions.AddItem(entry.item, 1)
            return Notify(source, locale('hive_place_failed'), 'error')
        end

        BroadcastToAll('rsg-beekeeper:client:spawnBeehive', {
            id = insertId, x = x, y = y, z = z, heading = heading, prop = entry.prop,
            citizenid = citizenid, active = false, isFull = false, isCalm = false,
        })

        Notify(source, locale('hive_placed_success'), 'success')

        local fields = GetPlayerWebhookFields(source, Player)
        AppendField(fields, locale('webhook_field_hive_id'), insertId)
        AppendField(fields, locale('webhook_field_style'), entry.label)
        AppendField(fields, locale('webhook_field_coords'), FormatCoords(x, y, z), false)
        BeekeeperWebhook.Send('placed', locale('webhook_title_placed'), nil, fields)
    end)
end)

--------------------------------------------------------------------------------------------------
-- Persistence load
--------------------------------------------------------------------------------------------------

local lastRequest = {} -- [source] = os.time() of their last full hive list request

RegisterNetEvent('rsg-beekeeper:server:requestBeehives', function()
    local source = source

    -- Pulls every hive on the server, so don't let a client spam it.
    local now = os.time()
    if lastRequest[source] and now - lastRequest[source] < 10 then return end
    lastRequest[source] = now

    local rows = MySQL.query.await('SELECT id, citizenid, x, y, z, heading, active, activated_at, smoked_until, prop FROM rsg_beehives') or {}
    local hives = {}

    for i, row in ipairs(rows) do
        hives[i] = {
            id = row.id, x = row.x, y = row.y, z = row.z, heading = row.heading, prop = row.prop,
            citizenid = row.citizenid,
            active = IsActive(row.active),
            isFull = IsHiveFull(row),
            isCalm = IsHiveCalm(row.smoked_until),
        }
    end

    TriggerClientEvent('rsg-beekeeper:client:loadBeehives', source, hives)
end)

AddEventHandler('playerDropped', function()
    lastRequest[source] = nil
end)

--------------------------------------------------------------------------------------------------
-- Hive info (management UI)
--------------------------------------------------------------------------------------------------

local function SendHiveInfo(source, id, eventName, extra)
    local row = MySQL.single.await('SELECT citizenid, active, activated_at, food, water, health, honey, x, y, z FROM rsg_beehives WHERE id = ?', { id })
    if not row then
        TriggerClientEvent('rsg-beekeeper:client:hiveGone', source, id, locale('hive_not_found'))
        return
    end

    local Player = RSGCore.Functions.GetPlayer(source)
    local active = IsActive(row.active)

    local data = {
        id = id,
        active = active,
        isOwner = Player and row.citizenid == Player.PlayerData.citizenid or false,
        population = active and CalculatePopulation(row.activated_at) or 0,
        max = POP_MAX,
        food = tonumber(row.food) or 100,
        water = tonumber(row.water) or 100,
        health = tonumber(row.health) or 100,
        honey = tonumber(row.honey) or 0,
    }

    if extra then
        for k, v in pairs(extra) do data[k] = v end
    end

    TriggerClientEvent(eventName, source, data)
end

RegisterNetEvent('rsg-beekeeper:server:getHiveInfo', function(id, isRefresh)
    local source = source
    if not RSGCore.Functions.GetPlayer(source) then return end

    id = tonumber(id)
    if not id then return end

    local row = MySQL.single.await('SELECT x, y, z FROM rsg_beehives WHERE id = ?', { id })
    if not row then
        TriggerClientEvent('rsg-beekeeper:client:hiveGone', source, id, locale('hive_not_found'))
        return
    end

    if not IsPlayerNearCoords(source, row.x, row.y, row.z, INTERACT_RANGE) then
        if not isRefresh then Notify(source, locale('hive_not_close_enough'), 'error') end
        return
    end

    SendHiveInfo(source, id, isRefresh and 'rsg-beekeeper:client:updateHiveUI' or 'rsg-beekeeper:client:openHiveUI')
end)

-- Shared front half of every hive action: resolves the player, validates the
-- id, loads the row and checks proximity. Returns Player, row or nil.
local function LoadHiveForAction(source, id, columns)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player then return end

    local row = MySQL.single.await(('SELECT %s, x, y, z FROM rsg_beehives WHERE id = ?'):format(columns), { id })
    if not row then
        TriggerClientEvent('rsg-beekeeper:client:actionResult', source, { id = id, success = false, message = locale('hive_not_found') })
        return
    end

    if not IsPlayerNearCoords(source, row.x, row.y, row.z, INTERACT_RANGE) then
        TriggerClientEvent('rsg-beekeeper:client:actionResult', source, { id = id, success = false, message = locale('hive_not_close_enough') })
        return
    end

    return Player, row
end

local function Fail(source, id, message)
    TriggerClientEvent('rsg-beekeeper:client:actionResult', source, { id = id, success = false, message = message })
end

local function Succeed(source, id, message)
    SendHiveInfo(source, id, 'rsg-beekeeper:client:actionResult', { success = true, message = message })
end

--------------------------------------------------------------------------------------------------
-- Activation (add queen bee)
--------------------------------------------------------------------------------------------------

RegisterNetEvent('rsg-beekeeper:server:addQueenBee', function(id)
    local source = source
    id = tonumber(id)
    if not id then return end

    WithLock(source, function()
        local Player, row = LoadHiveForAction(source, id, 'active')
        if not Player then return end

        if IsActive(row.active) then
            return Fail(source, id, locale('hive_already_active'))
        end

        local queenItem = Beehive.queenBeeItem
        if not Player.Functions.GetItemByName(queenItem) then
            return Fail(source, id, locale('queen_bee_required'))
        end

        -- Claim the hive first with a conditional update, so two players
        -- queening the same hive at once can't both spend a queen bee.
        local activatedAt = os.time()
        local affected = MySQL.update.await([[
            UPDATE rsg_beehives SET active = 1, activated_at = ?, smoked_until = NULL, food = 100, water = 100, health = 100, honey = 0
            WHERE id = ? AND active = 0
        ]], { activatedAt, id })

        if not affected or affected == 0 then
            return Fail(source, id, locale('hive_already_active'))
        end

        if not Player.Functions.RemoveItem(queenItem, 1) then
            MySQL.update.await('UPDATE rsg_beehives SET active = 0, activated_at = NULL WHERE id = ?', { id })
            return Fail(source, id, locale('queen_bee_remove_failed'))
        end
        TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[queenItem], 'remove', 1)

        BroadcastToAll('rsg-beekeeper:client:beehiveActivated', id)
        ScheduleHiveFullCheck(id, activatedAt)
        Succeed(source, id, locale('hive_activated_success'))

        local fields = GetPlayerWebhookFields(source, Player)
        AppendField(fields, locale('webhook_field_hive_id'), id)
        BeekeeperWebhook.Send('activated', locale('webhook_title_activated'), nil, fields)
    end)
end)

--------------------------------------------------------------------------------------------------
-- Upkeep top-up (add food / water)
--------------------------------------------------------------------------------------------------

RegisterNetEvent('rsg-beekeeper:server:addHiveResource', function(id, resourceType)
    local source = source
    id = tonumber(id)
    if not id or (resourceType ~= 'food' and resourceType ~= 'water') then return end

    WithLock(source, function()
        local Player, row = LoadHiveForAction(source, id, 'active, activated_at, food, water')
        if not Player then return end

        if not IsActive(row.active) then
            return Fail(source, id, locale('hive_no_queen'))
        end

        -- Food/water aren't consumed until the colony is full, so don't let
        -- players waste items topping up a still-growing hive.
        if not IsHiveFull(row) then
            return Fail(source, id, locale('hive_still_growing'))
        end

        local cfg = Beehive.upkeep
        local isFood = resourceType == 'food'
        local resourceLabel = isFood and locale('nui_food_label') or locale('nui_water_label')

        if (tonumber(row[resourceType]) or 0) >= 100 then
            return Fail(source, id, locale('hive_resource_full', resourceLabel:lower()))
        end

        -- Food uses the bee food item, water uses a full water bucket.
        local itemName = isFood and cfg.foodItem or cfg.waterItem
        local invItem = Player.Functions.GetItemByName(itemName)
        if not invItem then
            return Fail(source, id, locale('item_required', ItemLabel(itemName)))
        end

        -- A full bucket holds several uses (stored in its metadata), so only
        -- one use is spent per top-up. It becomes an empty bucket on the last use.
        local usesKey = cfg.waterUsesKey or 'uses'
        local originalInfo = invItem.info or {}
        local bucketUsesLeft
        if not isFood then
            bucketUsesLeft = ((tonumber(originalInfo[usesKey])) or cfg.waterTotalUses or 1) - 1
        end

        if not Player.Functions.RemoveItem(itemName, 1, invItem.slot) then
            return Fail(source, id, locale('item_remove_failed'))
        end
        if not isFood and bucketUsesLeft > 0 then
            local newInfo = {}
            for k, v in pairs(originalInfo) do newInfo[k] = v end
            newInfo[usesKey] = bucketUsesLeft
            Player.Functions.AddItem(itemName, 1, invItem.slot, newInfo)
        else
            TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[itemName], 'remove', 1)
        end

        -- Atomic increment, so concurrent top-ups by different players stack
        -- correctly instead of overwriting each other.
        local column = isFood and 'food' or 'water'
        local amount = isFood and cfg.foodPerItem or cfg.waterPerItem
        local affected = MySQL.update.await(
            ('UPDATE rsg_beehives SET %s = LEAST(100, %s + ?) WHERE id = ? AND active = 1'):format(column, column),
            { amount, id })

        if not affected or affected == 0 then
            -- refund: restore the item exactly as it was
            if not isFood and bucketUsesLeft > 0 then
                Player.Functions.RemoveItem(itemName, 1, invItem.slot)
            end
            Player.Functions.AddItem(itemName, 1, invItem.slot, originalInfo)
            return Fail(source, id, locale('hive_update_failed'))
        end

        -- Hand back the empty bucket once the last use of water has been poured.
        local emptyItem = cfg.waterReturnItem
        if not isFood and bucketUsesLeft <= 0 and emptyItem and emptyItem ~= '' and RSGCore.Shared.Items[emptyItem] then
            Player.Functions.AddItem(emptyItem, 1)
            TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[emptyItem], 'add', 1)
        end

        Succeed(source, id, locale('hive_resource_topped_up', resourceLabel:lower()))
    end)
end)

--------------------------------------------------------------------------------------------------
-- Honey harvesting
--------------------------------------------------------------------------------------------------

RegisterNetEvent('rsg-beekeeper:server:harvestHoney', function(id)
    local source = source
    id = tonumber(id)
    if not id then return end

    WithLock(source, function()
        local Player, row = LoadHiveForAction(source, id, 'active, honey, citizenid')
        if not Player then return end

        local cfg = Beehive.honey
        local citizenid = Player.PlayerData.citizenid

        if not IsActive(row.active) then
            return Fail(source, id, locale('hive_no_queen'))
        end

        -- Anyone may help feed/water a hive, but only the owner collects.
        if row.citizenid ~= citizenid then
            return Fail(source, id, locale('hive_not_owner'))
        end

        if (tonumber(row.honey) or 0) < 100 then
            return Fail(source, id, locale('honey_not_ready'))
        end

        if not Player.Functions.GetItemByName(cfg.harvestTool) then
            return Fail(source, id, locale('harvest_tool_required', ItemLabel(cfg.harvestTool)))
        end

        if not CanCarry(source, cfg.honeyCombItem, cfg.honeyCombAmount) or not CanCarry(source, cfg.beeswaxItem, cfg.beeswaxAmount) then
            return Fail(source, id, locale('inventory_full'))
        end

        -- Conditional reset is the claim: only one request can ever flip a
        -- full honey meter back to 0, so the reward can't be duplicated.
        local affected = MySQL.update.await('UPDATE rsg_beehives SET honey = 0 WHERE id = ? AND citizenid = ? AND honey >= 100', { id, citizenid })
        if not affected or affected == 0 then
            return Fail(source, id, locale('harvest_failed'))
        end

        Player.Functions.AddItem(cfg.honeyCombItem, cfg.honeyCombAmount)
        Player.Functions.AddItem(cfg.beeswaxItem, cfg.beeswaxAmount)
        TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[cfg.honeyCombItem], 'add', cfg.honeyCombAmount)
        TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[cfg.beeswaxItem], 'add', cfg.beeswaxAmount)

        Succeed(source, id, locale('harvest_success',
            cfg.honeyCombAmount, ItemLabel(cfg.honeyCombItem),
            cfg.beeswaxAmount, ItemLabel(cfg.beeswaxItem)))

        local fields = GetPlayerWebhookFields(source, Player)
        AppendField(fields, locale('webhook_field_hive_id'), id)
        AppendField(fields, locale('webhook_field_honeycomb'), cfg.honeyCombAmount)
        AppendField(fields, locale('webhook_field_beeswax'), cfg.beeswaxAmount)
        BeekeeperWebhook.Send('harvested', locale('webhook_title_harvested'), nil, fields)
    end)
end)

--------------------------------------------------------------------------------------------------
-- Pickup (remove beehive, return item(s) to owner)
--------------------------------------------------------------------------------------------------

RegisterNetEvent('rsg-beekeeper:server:pickupBeehive', function(id)
    local source = source
    id = tonumber(id)
    if not id then return end

    WithLock(source, function()
        local Player, row = LoadHiveForAction(source, id, 'active, citizenid, prop')
        if not Player then return end

        local citizenid = Player.PlayerData.citizenid

        if row.citizenid ~= citizenid then
            return Fail(source, id, locale('hive_pickup_not_owner'))
        end

        local entry = propEntries[row.prop]
        if not entry then
            return Fail(source, id, locale('hive_pickup_item_missing'))
        end

        local active = IsActive(row.active)

        -- Check space before deleting so the hive (and queen) can't vanish.
        if not CanCarry(source, entry.item, 1) or (active and not CanCarry(source, Beehive.queenBeeItem, 1)) then
            return Fail(source, id, locale('inventory_full'))
        end

        local affected = MySQL.update.await('DELETE FROM rsg_beehives WHERE id = ? AND citizenid = ?', { id, citizenid })
        if not affected or affected == 0 then
            return Fail(source, id, locale('hive_pickup_failed'))
        end

        Player.Functions.AddItem(entry.item, 1)
        TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[entry.item], 'add', 1)

        -- A living colony's queen comes back with the hive.
        if active then
            Player.Functions.AddItem(Beehive.queenBeeItem, 1)
            TriggerClientEvent('rsg-inventory:client:ItemBox', source, RSGCore.Shared.Items[Beehive.queenBeeItem], 'add', 1)
        end

        BroadcastToAll('rsg-beekeeper:client:removeBeehive', id)
        Notify(source, active and locale('hive_pickup_success_with_queen') or locale('hive_pickup_success'), 'success')

        local fields = GetPlayerWebhookFields(source, Player)
        AppendField(fields, locale('webhook_field_hive_id'), id)
        AppendField(fields, locale('webhook_field_style'), entry.label)
        BeekeeperWebhook.Send('pickedup', locale('webhook_title_pickedup'), nil, fields)
    end)
end)
