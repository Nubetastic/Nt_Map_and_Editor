local DEFAULT_RANGE = 10
local MIN_RANGE = 2
local MAX_RANGE = 50
local MOVING_REFRESH_INTERVAL = 1000
local CAMERA_DRAG_CONTROL = 0xF84FA74F
local CAMERA_LOOK_X = 0xA987235F
local CAMERA_LOOK_Y = 0xD2047988
local LOCATION_LINE_HEIGHT = 5.0

local currentRange = DEFAULT_RANGE
local imapChanges = {}
local uiOpen = false
local nuiReady = false
local cameraDragActive = false
local cameraDragGrace = 0
local imapByHash = {}
local nearbyLineCoords = {}

local function normalizedState(value)
    if value == 'default' or value == 'enabled' or value == 'disabled' then
        return value
    end

    if type(value) == 'boolean' then
        return value and 'enabled' or 'disabled'
    end

    return nil
end

local function baselineState(entry)
    if entry.default then
        return 'default'
    end

    return entry.enable and 'enabled' or 'disabled'
end

for _, imap in ipairs(IMAP_CATALOG or {}) do
    if type(imap.dec_hash) == 'number'
        and type(imap.default) == 'boolean'
        and type(imap.enable) == 'boolean' then
        imapByHash[imap.dec_hash] = imap
    end
end

local function clampRange(value)
    value = math.floor(tonumber(value) or DEFAULT_RANGE)
    return math.max(MIN_RANGE, math.min(MAX_RANGE, value))
end

local function changeState(record)
    if type(record) == 'table' then
        return normalizedState(record.state)
    end

    return normalizedState(record)
end

local function heldState(hash)
    local record = imapChanges[tostring(hash)]
    return type(record) == 'table' and record.held == true
end

local function setLocalChange(hash, state, isOverride, held)
    local key = tostring(hash)
    local record = type(imapChanges[key]) == 'table' and imapChanges[key] or {}

    if isOverride then
        record.state = state
    else
        record.state = nil
    end

    if held ~= nil then
        record.held = held == true
    end

    if record.state or record.held then
        imapChanges[key] = record
    else
        imapChanges[key] = nil
    end
end

local function configuredImapState(hash)
    return changeState(imapChanges[tostring(hash)]) or (imapByHash[hash] and baselineState(imapByHash[hash]))
end

local function observedImapState(hash)
    if type(IsImapActive) == 'function' then
        local ok, active = pcall(IsImapActive, hash)
        if ok and type(active) == 'boolean' then
            return active
        end
    end

    return nil
end

local function editorCoords(imap)
    local coords = imap.coords
    if coords and type(coords.x) == 'number' and type(coords.y) == 'number' and type(coords.z) == 'number' then
        return coords
    end

    if type(imap.x) == 'number' and type(imap.y) == 'number' and type(imap.z) == 'number' then
        return imap
    end

    return nil
end

local function hasEditorCoordinates(imap)
    local coords = editorCoords(imap)
    return coords and (coords.x ~= 0.0 or coords.y ~= 0.0 or coords.z ~= 0.0)
end

local function getNearbyImaps()
    local playerPosition = GetEntityCoords(PlayerPedId())
    local rangeSquared = currentRange * currentRange
    local nearby = {}
    local lineCoords = {}

    for _, imap in ipairs(IMAP_CATALOG) do
        if hasEditorCoordinates(imap) then
            local coords = editorCoords(imap)
            local dx = coords.x - playerPosition.x
            local dy = coords.y - playerPosition.y
            local dz = coords.z - playerPosition.z
            local distanceSquared = dx * dx + dy * dy + dz * dz
            if distanceSquared <= rangeSquared then
                lineCoords[#lineCoords + 1] = { x = coords.x, y = coords.y, z = coords.z }
                local active = observedImapState(imap.dec_hash)
                nearby[#nearby + 1] = {
                    hash = imap.dec_hash,
                    name = imap.hashname or '',
                    distance = math.sqrt(distanceSquared),
                    state = active == nil and 'unknown' or (active and 'loaded' or 'unloaded'),
                    configuredState = configuredImapState(imap.dec_hash),
                    changed = changeState(imapChanges[tostring(imap.dec_hash)]) ~= nil,
                    held = heldState(imap.dec_hash)
                }
            end
        end
    end

    table.sort(nearby, function(a, b)
        if a.distance == b.distance then return a.hash < b.hash end
        return a.distance < b.distance
    end)
    nearbyLineCoords = lineCoords
    return nearby
end

local function sendCurrent(action)
    if not uiOpen then return end

    SendNUIMessage({
        action = action or 'update',
        range = currentRange,
        imaps = getNearbyImaps()
    })
end

local function closeUi()
    if not uiOpen then return end
    uiOpen = false
    cameraDragActive = false
    nearbyLineCoords = {}
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    SendNUIMessage({ action = 'close' })
end

local function openUi()
    uiOpen = true
    SetNuiFocus(true, true)
    SetNuiFocusKeepInput(true)
    TriggerServerEvent('nt-imapviewer:requestSettings')
    if nuiReady then sendCurrent('open') end
end

RegisterCommand('viewimaps', function()
    if uiOpen then closeUi() else TriggerServerEvent('nt-imapviewer:requestOpen') end
end, false)

RegisterNUICallback('close', function(_, callback)
    closeUi()
    callback({ ok = true })
end)

RegisterNUICallback('ready', function(_, callback)
    nuiReady = true
    if uiOpen then sendCurrent('open') end
    callback({ ok = true })
end)

RegisterNUICallback('cameraDragStart', function(_, callback)
    if uiOpen and not cameraDragActive then
        cameraDragActive = true
        cameraDragGrace = GetGameTimer() + 250
        SetNuiFocus(false, false)
        SetNuiFocusKeepInput(true)
    end
    callback({ ok = true })
end)

RegisterNUICallback('setRange', function(data, callback)
    currentRange = clampRange(data and data.range)
    sendCurrent('update')
    callback({ ok = true, range = currentRange })
end)

RegisterNUICallback('setImap', function(data, callback)
    local hash = data and tonumber(data.hash)
    local state = data and normalizedState(data.state)
    if not hash or not imapByHash[hash] or not state then
        callback({ ok = false })
        return
    end
    TriggerServerEvent('nt-imapviewer:setSetting', hash, state)
    callback({ ok = true })
end)

RegisterNUICallback('resetImaps', function(data, callback)
    local requested = data and data.hashes
    if type(requested) ~= 'table' then callback({ ok = false }) return end
    local hashes, seen = {}, {}
    for _, value in ipairs(requested) do
        local hash = tonumber(value)
        if hash and imapByHash[hash] and not seen[hash] then
            seen[hash] = true
            hashes[#hashes + 1] = hash
        end
    end
    if #hashes == 0 then callback({ ok = false }) return end
    TriggerServerEvent('nt-imapviewer:resetSettings', hashes)
    callback({ ok = true, count = #hashes })
end)

RegisterNUICallback('setHeld', function(data, callback)
    local hash = data and tonumber(data.hash)
    if not hash or not imapByHash[hash] then
        callback({ ok = false })
        return
    end

    TriggerServerEvent('nt-imapviewer:setHeld', hash, data.held == true)
    callback({ ok = true })
end)

RegisterNUICallback('exportConfig', function(_, callback)
    TriggerServerEvent('nt-mapeditor:exportConfig')
    callback({ ok = true })
end)

RegisterNetEvent('nt-imapviewer:openEditor', openUi)

RegisterNetEvent('nt-imapviewer:accessDenied', function(message)
    print(('[Nt_Map_and_Editor] %s'):format(message or 'Map editor access denied.'))
end)

RegisterNetEvent('nt-imapviewer:syncSettings', function(settings)
    imapChanges = type(settings) == 'table' and settings or {}
    sendCurrent('update')
end)

RegisterNetEvent('nt-imapviewer:settingUpdated', function(hashValue, stateValue, isOverride, heldValue)
    local hash = tonumber(hashValue)
    local state = normalizedState(stateValue)
    if not hash or not imapByHash[hash] or not state then return end
    setLocalChange(hash, state, isOverride == true, heldValue)
    if uiOpen then
        SendNUIMessage({ action = 'settingState', mode = 'imaps', hash = hash, state = state, changed = isOverride == true, held = heldState(hash) })
    end
    sendCurrent('update')
end)

RegisterNetEvent('nt-imapviewer:heldUpdated', function(hashValue, heldValue)
    local hash = tonumber(hashValue)
    if not hash or not imapByHash[hash] then return end
    local currentState = changeState(imapChanges[tostring(hash)])
    setLocalChange(hash, currentState or baselineState(imapByHash[hash]), currentState ~= nil, heldValue == true)
    if uiOpen then
        SendNUIMessage({ action = 'heldState', mode = 'imaps', hash = hash, held = heldState(hash) })
    end
    sendCurrent('update')
end)

RegisterNetEvent('nt-mapeditor:exportResult', function(mode, ok, message)
    print(('[Nt_Map_and_Editor] %s'):format(message or (ok and 'Config exported.' or 'Config export failed.')))
    if uiOpen then SendNUIMessage({ action = 'exportResult', mode = mode, ok = ok == true, message = message or '' }) end
end)

RegisterNetEvent('nt-mapeditor:resetResult', function(mode, ok, message)
    print(('[Nt_Map_and_Editor] %s'):format(message or (ok and 'List reset.' or 'Reset failed.')))
    if uiOpen then SendNUIMessage({ action = 'resetResult', mode = mode, ok = ok == true, message = message or '' }) end
end)

CreateThread(function()
    Wait(500)
    TriggerServerEvent('nt-imapviewer:requestSettings')
    local wasMoving = false
    while true do
        if uiOpen then
            local isMoving = GetEntitySpeed(PlayerPedId()) > 0.01
            if isMoving or wasMoving then sendCurrent('update') end
            wasMoving = isMoving
            Wait(MOVING_REFRESH_INTERVAL)
        else
            wasMoving = false
            Wait(1000)
        end
    end
end)

CreateThread(function()
    while true do
        if uiOpen then
            DisablePlayerFiring(PlayerId(), true)
            DisableControlAction(0, CAMERA_DRAG_CONTROL, true)
            if cameraDragActive then
                if GetGameTimer() > cameraDragGrace and not IsDisabledControlPressed(0, CAMERA_DRAG_CONTROL) then
                    cameraDragActive = false
                    SetNuiFocus(true, true)
                    SetNuiFocusKeepInput(true)
                end
            else
                DisableControlAction(0, CAMERA_LOOK_X, true)
                DisableControlAction(0, CAMERA_LOOK_Y, true)
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

CreateThread(function()
    while true do
        if uiOpen and #nearbyLineCoords > 0 then
            for _, coords in ipairs(nearbyLineCoords) do
                DrawLine(
                    coords.x, coords.y, coords.z,
                    coords.x, coords.y, coords.z + LOCATION_LINE_HEIGHT,
                    255, 0, 0, 220
                )
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

AddEventHandler('onResourceStop', function(stoppedResource)
    if stoppedResource == GetCurrentResourceName() then
        SetNuiFocus(false, false)
        SetNuiFocusKeepInput(false)
    end
end)
