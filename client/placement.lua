-- Gizmo-style placement (same system as rsg-farming): the ghost prop follows
-- where you aim, with drawn X/Y/Z axis handles, a valid/invalid ring,
-- rotation and height adjustment.
Placement = {}

local CONTROLS = {
    place   = 0x07CE1E61, -- LMB
    cancel  = 0xF84FA74F, -- RMB
    cancel2 = 0x156F7119, -- Backspace
    rotL    = 0xA65EBAB4, -- Arrow Left
    rotR    = 0xDEB34313, -- Arrow Right
    up      = 0x6319DB71, -- Arrow Up
    down    = 0x05CA7C52, -- Arrow Down
}

local function rotToDir(rot)
    local z, x = math.rad(rot.z), math.rad(rot.x)
    local n = math.abs(math.cos(x))
    return vector3(-math.sin(z) * n, math.cos(z) * n, math.sin(x))
end

local function camRaycast(dist, ignore)
    local camPos = GetGameplayCamCoord()
    local dest = camPos + rotToDir(GetGameplayCamRot(2)) * dist
    local handle = StartShapeTestRay(camPos.x, camPos.y, camPos.z, dest.x, dest.y, dest.z, 1, ignore, 0)
    local status, hit, endCoords = 1, false, vector3(0, 0, 0)
    repeat
        status, hit, endCoords = GetShapeTestResult(handle)
        if status == 1 then Wait(0) end
    until status ~= 1
    return hit == 1 or hit == true, endCoords
end

local function drawAxis(origin, heading)
    local r = math.rad(heading)
    local fwd   = vector3(-math.sin(r), math.cos(r), 0.0)
    local right = vector3(math.cos(r), math.sin(r), 0.0)
    local len = 0.8
    local o = origin + vector3(0, 0, 0.05)
    DrawLine(o.x, o.y, o.z, o.x + right.x * len, o.y + right.y * len, o.z, 230, 70, 70, 255)   -- X
    DrawLine(o.x, o.y, o.z, o.x + fwd.x * len,   o.y + fwd.y * len,   o.z, 90, 210, 90, 255)   -- Y
    DrawLine(o.x, o.y, o.z, o.x, o.y, o.z + len, 80, 140, 240, 255)                            -- Z
end

local function drawRing(origin, radius, valid)
    local cr, cg, cb = 111, 191, 115
    if not valid then cr, cg, cb = 224, 85, 79 end
    local seg = 24
    for i = 0, seg - 1 do
        local a1, a2 = (i / seg) * math.pi * 2, ((i + 1) / seg) * math.pi * 2
        DrawLine(origin.x + math.cos(a1) * radius, origin.y + math.sin(a1) * radius, origin.z + 0.03,
                 origin.x + math.cos(a2) * radius, origin.y + math.sin(a2) * radius, origin.z + 0.03, cr, cg, cb, 220)
    end
end

-- Shape test flags: map (1) | vehicles (2) | peds (8) | objects (16) | vegetation (256).
local CLEARANCE_FLAGS = 1 | 2 | 8 | 16
if Config.Placement.clearanceIncludeVegetation then
    CLEARANCE_FLAGS = CLEARANCE_FLAGS | 256
end
local CLEARANCE_START = Config.Placement.clearanceStartHeight or 0.4
local CLEARANCE_RECHECK_MS = 150

local function shapeTestResult(handle)
    local status, hit
    repeat
        status, hit = GetShapeTestResult(handle)
        if status == 1 then Wait(0) end
    until status ~= 1
    return hit == 1 or hit == true
end

-- True if something solid (prop, building, tree, ped, vehicle) occupies the
-- space the hive would spawn into. A capsule sweep covers collidable map and
-- world props; a pool scan also catches spawned objects without collision.
-- The sweep starts CLEARANCE_START above the ground so the terrain itself
-- (including sloped ground under the footprint) doesn't count as blocking.
local function isSpaceBlocked(pos, radius, height, ghost, ped)
    local bottom = pos.z + CLEARANCE_START
    local top = math.max(bottom + 0.1, pos.z + height)
    local handle = StartShapeTestCapsule(pos.x, pos.y, bottom, pos.x, pos.y, top, radius, CLEARANCE_FLAGS, ped, 7)
    if shapeTestResult(handle) then return true end

    local reach = radius + 0.25
    for _, obj in ipairs(GetGamePool('CObject')) do
        if obj ~= ghost and not IsEntityAttached(obj) and #(GetEntityCoords(obj) - pos) < reach then
            return true
        end
    end
    return false
end

local function loadModel(model)
    local hash = type(model) == 'number' and model or joaat(model)
    if not IsModelValid(hash) then return nil end
    local ok = pcall(lib.requestModel, hash, 5000)
    return ok and hash or nil
end

Placement.Active = false

local function notify(description)
    lib.notify({ title = locale('title_beehive'), description = description, type = 'error', duration = 5000 })
end

---Starts placement and blocks until the player places or cancels.
---checkFn(coords) -> ok, reason
---@return vector3|nil coords, number|nil heading
function Placement.Start(model, checkFn, invalidMsg)
    if Placement.Active then return nil end

    local hash = loadModel(model)
    if not hash then return nil end

    local cfg = Config.Placement
    local ped = PlayerPedId()
    local start = GetEntityCoords(ped)
    local ghost = CreateObject(hash, start.x, start.y, start.z - 5.0, false, false, false)
    SetEntityAlpha(ghost, 170, false)
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)
    SetModelAsNoLongerNeeded(hash)

    Placement.Active = true
    Placement.Ghost = ghost

    -- Footprint of the hive model, used for the clear-space check.
    local minDim, maxDim = GetModelDimensions(hash)
    local footprint = math.max(maxDim.x - minDim.x, maxDim.y - minDim.y) * 0.5
    local clearRadius = math.max(0.2, footprint + (cfg.clearancePadding or 0.0))
    local clearHeight = maxDim.z - minDim.z
    local lastCheckAt, lastCheckPos, blocked = 0, nil, false

    local heading, heightOffset = GetEntityHeading(ped), 0.0
    local result, resultHeading = nil, nil
    SendNUIMessage({
        action = 'placementShow',
        strings = {
            title = locale('place_hud_title'),
            place = locale('place_hud_place'),
            rotate = locale('place_hud_rotate'),
            height = locale('place_hud_height'),
            cancel = locale('place_hud_cancel'),
            valid = locale('place_hud_valid'),
            headingLabel = locale('place_hud_heading_label'),
            heightLabel = locale('place_hud_height_label'),
        },
    })

    -- Only push to the HUD when something it shows actually changed.
    local lastHud = {}
    local function updateHud(valid, reason)
        local h, off = math.floor(heading + 0.5) % 360, math.floor(heightOffset * 100 + 0.5) / 100
        if lastHud.valid == valid and lastHud.reason == reason and lastHud.h == h and lastHud.off == off then return end
        lastHud.valid, lastHud.reason, lastHud.h, lastHud.off = valid, reason, h, off
        SendNUIMessage({ action = 'placementUpdate', valid = valid, reason = reason, heading = h, height = off })
    end

    while Placement.Active do
        Wait(0)
        for _, c in pairs(CONTROLS) do DisableControlAction(0, c, true) end
        DisableControlAction(0, 0xB2F377E8, true) -- melee attack
        DisableControlAction(0, 0x8FFC75D6, true) -- sprint

        local hit, coords = camRaycast(cfg.maxDistance + 6.0, ghost)
        local pedPos = GetEntityCoords(ped)
        local valid, reason = false, nil

        if hit then
            local pos = coords + vector3(0, 0, heightOffset)
            SetEntityCoordsNoOffset(ghost, pos.x, pos.y, pos.z, false, false, false)
            SetEntityHeading(ghost, heading)

            if #(pedPos - coords) > cfg.maxDistance then
                reason = locale('place_too_far')
            else
                valid, reason = true, nil
                if checkFn then valid, reason = checkFn(pos) end

                if valid and cfg.requireClearSpace ~= false then
                    local now = GetGameTimer()
                    if not lastCheckPos or now - lastCheckAt >= CLEARANCE_RECHECK_MS or #(lastCheckPos - pos) > 0.1 then
                        blocked = isSpaceBlocked(pos, clearRadius, clearHeight, ghost, ped)
                        lastCheckAt, lastCheckPos = now, pos
                    end
                    if blocked then valid, reason = false, locale('place_obstructed') end
                end
            end

            drawAxis(pos, heading)
            drawRing(pos, cfg.ringRadius, valid)
        end

        updateHud(hit and valid, reason or (not hit and invalidMsg) or nil)

        -- frame-rate independent rotate / height
        local dt = GetFrameTime()
        if IsDisabledControlPressed(0, CONTROLS.rotL) then heading = (heading + cfg.rotateSpeed * dt) % 360 end
        if IsDisabledControlPressed(0, CONTROLS.rotR) then heading = (heading - cfg.rotateSpeed * dt) % 360 end
        if IsDisabledControlPressed(0, CONTROLS.up)   then heightOffset = math.min(heightOffset + cfg.heightSpeed * dt, cfg.heightMax) end
        if IsDisabledControlPressed(0, CONTROLS.down) then heightOffset = math.max(heightOffset - cfg.heightSpeed * dt, -cfg.heightMax) end

        if IsDisabledControlJustPressed(0, CONTROLS.place) then
            if hit and valid then
                result, resultHeading = GetEntityCoords(ghost), heading
                break
            else
                notify(reason or invalidMsg)
            end
        end

        if IsDisabledControlJustPressed(0, CONTROLS.cancel) or IsDisabledControlJustPressed(0, CONTROLS.cancel2)
            or IsEntityDead(ped) then
            break
        end
    end

    Placement.Active = false
    Placement.Ghost = nil
    SendNUIMessage({ action = 'placementHide' })
    if DoesEntityExist(ghost) then DeleteObject(ghost) end
    return result, resultHeading
end

-- Cancels an in-progress placement (e.g. on resource stop).
function Placement.Cancel()
    Placement.Active = false
    if Placement.Ghost and DoesEntityExist(Placement.Ghost) then
        DeleteObject(Placement.Ghost)
    end
    Placement.Ghost = nil
    SendNUIMessage({ action = 'placementHide' })
end
