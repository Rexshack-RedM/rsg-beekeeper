-- Simple placement: the ghost hive sits on the ground a short distance in
-- front of the player and follows them as they walk. Turn/walk to position it,
-- use the arrow keys to rotate / fine-tune height, LMB to place.
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

local function drawRing(origin, radius, valid)
    local cr, cg, cb = 111, 191, 115
    if not valid then cr, cg, cb = 224, 85, 79 end
    local seg = 24
    for i = 0, seg - 1 do
        local a1, a2 = (i / seg) * math.pi * 2, ((i + 1) / seg) * math.pi * 2
        DrawLine(origin.x + math.cos(a1) * radius, origin.y + math.sin(a1) * radius, origin.z + 0.05,
                 origin.x + math.cos(a2) * radius, origin.y + math.sin(a2) * radius, origin.z + 0.05, cr, cg, cb, 220)
    end
end

-- Ground height at x,y, searching from just above the player so it works on
-- slopes, hills and under trees. Falls back to the player's feet.
local function groundAt(x, y, refZ)
    for _, up in ipairs({ 1.5, 3.0, 6.0 }) do
        local found, z = GetGroundZFor_3dCoord(x, y, refZ + up, false)
        if found and math.abs(z - refZ) < 4.0 then return z end
    end
    return refZ - 1.0
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

    local dist = cfg.placeDistance or 1.5
    local rotOffset, heightOffset = 0.0, 0.0
    local heading = GetEntityHeading(ped)
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

        local pedPos = GetEntityCoords(ped)
        local pedHeading = GetEntityHeading(ped)
        local r = math.rad(pedHeading)
        local x, y = pedPos.x - math.sin(r) * dist, pedPos.y + math.cos(r) * dist
        local pos = vector3(x, y, groundAt(x, y, pedPos.z) + heightOffset)
        heading = (pedHeading + rotOffset) % 360

        SetEntityCoordsNoOffset(ghost, pos.x, pos.y, pos.z, false, false, false)
        SetEntityHeading(ghost, heading)

        local valid, reason = true, nil
        if IsEntityInWater(ped) or GetInteriorFromEntity(ped) ~= 0 then
            valid, reason = false, invalidMsg
        elseif checkFn then
            valid, reason = checkFn(pos)
        end

        drawRing(pos, cfg.ringRadius or 0.6, valid)
        updateHud(valid, reason)

        local dt = GetFrameTime()
        if IsDisabledControlPressed(0, CONTROLS.rotL) then rotOffset = (rotOffset + cfg.rotateSpeed * dt) % 360 end
        if IsDisabledControlPressed(0, CONTROLS.rotR) then rotOffset = (rotOffset - cfg.rotateSpeed * dt) % 360 end
        if IsDisabledControlPressed(0, CONTROLS.up)   then heightOffset = math.min(heightOffset + cfg.heightSpeed * dt, cfg.heightMax) end
        if IsDisabledControlPressed(0, CONTROLS.down) then heightOffset = math.max(heightOffset - cfg.heightSpeed * dt, -cfg.heightMax) end

        if IsDisabledControlJustPressed(0, CONTROLS.place) then
            if valid then
                result, resultHeading = pos, heading
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
