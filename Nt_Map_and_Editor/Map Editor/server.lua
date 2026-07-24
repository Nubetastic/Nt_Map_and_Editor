local IMAP_CHANGES_FILE = 'shared/imap_changes.json'
local IMAP_EXPORT_FILE = 'shared/imapConfig_update.lua'
local MAX_RESET_ITEMS = 1000

local resourceName = GetCurrentResourceName()
local imapChanges = {}
local imapByHash = {}

local function baselineState(entry)
    if entry.default then
        return 'default'
    end

    return entry.enable and 'enabled' or 'disabled'
end

local function normalizedState(value)
    if value == 'default' or value == 'enabled' or value == 'disabled' then
        return value
    end

    if type(value) == 'boolean' then
        return value and 'enabled' or 'disabled'
    end

    return nil
end

local function editorEnabled()
    return Config and Config.EnableEditor == true
end

local function copyChanges(source)
    local result = {}
    for key, value in pairs(source or {}) do
        if type(value) == 'table' then
            local record = {}
            for recordKey, recordValue in pairs(value) do
                record[recordKey] = recordValue
            end
            result[key] = record
        else
            result[key] = value
        end
    end
    return result
end

local function recordState(record)
    if type(record) == 'table' then
        return normalizedState(record.state)
    end

    return normalizedState(record)
end

local function recordHeld(record)
    return type(record) == 'table' and record.held == true
end

local function makeChangeRecord(state, held)
    local normalized = normalizedState(state)
    if not normalized and held ~= true then
        return nil
    end

    local record = {}
    if normalized then
        record.state = normalized
        record.held = held == true
    elseif held == true then
        record.held = true
    end
    return record
end

local function prettyJson(value, depth)
    local valueType = type(value)
    if valueType == 'string' then
        return json.encode(value)
    end
    if valueType == 'number' or valueType == 'boolean' then
        return tostring(value)
    end
    if valueType ~= 'table' then
        return 'null'
    end

    local indent = string.rep('  ', depth or 0)
    local childIndent = indent .. '  '
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    if #keys == 0 then
        return '{}'
    end

    table.sort(keys, function(left, right)
        local leftNumber = tonumber(left)
        local rightNumber = tonumber(right)
        if leftNumber and rightNumber and leftNumber ~= rightNumber then
            return leftNumber < rightNumber
        end
        return tostring(left) < tostring(right)
    end)

    local lines = {'{'}
    for index, key in ipairs(keys) do
        local comma = index < #keys and ',' or ''
        lines[#lines + 1] = ('%s%s: %s%s'):format(
            childIndent,
            json.encode(tostring(key)),
            prettyJson(value[key], (depth or 0) + 1),
            comma
        )
    end
    lines[#lines + 1] = indent .. '}'
    return table.concat(lines, '\n')
end

local function saveJson(path, value)
    local ok, encoded = pcall(prettyJson, value, 0)
    if not ok or type(encoded) ~= 'string' then
        print(('[%s] Failed to encode %s.'):format(resourceName, path))
        return false
    end

    encoded = encoded .. '\n'
    local written = SaveResourceFile(resourceName, path, encoded, -1)
    if not written then
        print(('[%s] Failed to write %s.'):format(resourceName, path))
        return false
    end

    return true
end

local function readJson(path)
    local raw = LoadResourceFile(resourceName, path)
    if not raw or raw == '' then
        return {}
    end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        print(('[%s] Could not read %s; using catalog defaults.'):format(resourceName, path))
        return {}
    end

    return decoded
end

for index, imap in ipairs(IMAP_CATALOG or {}) do
    if type(imap.dec_hash) ~= 'number'
        or type(imap.default) ~= 'boolean'
        or type(imap.enable) ~= 'boolean'
        or imapByHash[imap.dec_hash] then
        error(('Invalid or duplicate IMAP_CATALOG record at index %d.'):format(index))
    end

    imapByHash[imap.dec_hash] = imap
end

local function loadImapChanges()
    local decoded = readJson(IMAP_CHANGES_FILE)
    local accepted = 0
    local rejected = 0

    for hashText, savedState in pairs(decoded) do
        local hash = tonumber(hashText)
        local baseline = hash and imapByHash[hash]
        local state = recordState(savedState)
        local held = recordHeld(savedState)
        if baseline and (state or held) then
            local overrideState = state ~= baselineState(baseline) and state or nil
            local record = makeChangeRecord(overrideState, held)
            if record then
                imapChanges[tostring(hash)] = record
                accepted = accepted + 1
            end
        else
            rejected = rejected + 1
        end
    end

    print(('[%s] Loaded %d iMap changes from %s (%d rejected).'):format(resourceName, accepted, IMAP_CHANGES_FILE, rejected))
end

local function effectiveImapState(hash)
    return recordState(imapChanges[tostring(hash)]) or baselineState(imapByHash[hash])
end

local function sendExportResult(playerSource, mode, ok, message)
    print(('[%s] %s'):format(resourceName, message))
    if playerSource > 0 then
        TriggerClientEvent('nt-mapeditor:exportResult', playerSource, mode, ok, message)
    end
end

local function exportImaps(playerSource)
    local baseline = LoadResourceFile(resourceName, 'shared/imapConfig.lua')
    if not baseline or baseline == '' then
        sendExportResult(playerSource, 'imaps', false, 'Could not read shared/imapConfig.lua.')
        return
    end

    local merged, replacedCount = baseline:gsub(
        'dec_hash%s*=%s*(%-?%d+)%s*,%s*default%s*=%s*%a+%s*,%s*enable%s*=%s*%a+',
        function(hashText)
            local hash = tonumber(hashText)
            local state = hash and imapByHash[hash] and effectiveImapState(hash) or 'default'
            return ('dec_hash=%s,default=%s,enable=%s'):format(
                hashText,
                state == 'default' and 'true' or 'false',
                state == 'enabled' and 'true' or 'false'
            )
        end
    )

    if replacedCount ~= #IMAP_CATALOG then
        sendExportResult(playerSource, 'imaps', false, ('iMap export validation failed: expected %d records, replaced %d.'):format(#IMAP_CATALOG, replacedCount))
        return
    end

    if not SaveResourceFile(resourceName, IMAP_EXPORT_FILE, merged, -1) then
        sendExportResult(playerSource, 'imaps', false, ('Failed to write %s.'):format(IMAP_EXPORT_FILE))
        return
    end

    sendExportResult(playerSource, 'imaps', true, ('Exported %d iMaps to %s.'):format(#IMAP_CATALOG, IMAP_EXPORT_FILE))
end

loadImapChanges()

RegisterNetEvent('nt-imapviewer:requestSettings', function()
    TriggerClientEvent('nt-imapviewer:syncSettings', source, imapChanges)
end)

RegisterNetEvent('nt-imapviewer:requestMapState', function()
    TriggerClientEvent('nt-imapviewer:syncMapState', source, imapChanges)
end)

RegisterNetEvent('nt-imapviewer:requestOpen', function()
    local playerSource = source
    if not editorEnabled() then
        TriggerClientEvent('nt-imapviewer:accessDenied', playerSource, 'The iMap editor is disabled on this server.')
        return
    end

    TriggerClientEvent('nt-imapviewer:openEditor', playerSource)
end)

RegisterNetEvent('nt-imapviewer:setSetting', function(hashValue, requestedState)
    local playerSource = source
    local hash = tonumber(hashValue)
    local state = normalizedState(requestedState)
    local baseline = hash and imapByHash[hash]
    if not editorEnabled() or not baseline or not state then
        return
    end

    local nextChanges = copyChanges(imapChanges)
    local key = tostring(hash)
    local held = recordHeld(nextChanges[key])
    local overrideState = state ~= baselineState(baseline) and state or nil
    nextChanges[key] = makeChangeRecord(overrideState, held)
    if not saveJson(IMAP_CHANGES_FILE, nextChanges) then
        return
    end

    imapChanges = nextChanges
    print(('[%s] %s set iMap %s to %s.'):format(resourceName, GetPlayerName(playerSource) or tostring(playerSource), hash, state))
    TriggerClientEvent('nt-imapviewer:settingUpdated', -1, hash, state, recordState(imapChanges[key]) ~= nil, recordHeld(imapChanges[key]))
end)

RegisterNetEvent('nt-imapviewer:resetSettings', function(requestedHashes)
    local playerSource = source
    if not editorEnabled() or type(requestedHashes) ~= 'table' then
        TriggerClientEvent('nt-mapeditor:resetResult', playerSource, 'imaps', false, 'Invalid iMap reset request.')
        return
    end

    local hashes = {}
    local seen = {}
    for _, value in ipairs(requestedHashes) do
        if #hashes >= MAX_RESET_ITEMS then break end
        local hash = tonumber(value)
        if hash and imapByHash[hash] and not seen[hash] then
            seen[hash] = true
            hashes[#hashes + 1] = hash
        end
    end
    if #hashes == 0 then
        TriggerClientEvent('nt-mapeditor:resetResult', playerSource, 'imaps', false, 'No valid displayed iMaps were supplied.')
        return
    end

    local nextChanges = copyChanges(imapChanges)
    for _, hash in ipairs(hashes) do
        local key = tostring(hash)
        nextChanges[key] = makeChangeRecord(nil, recordHeld(nextChanges[key]))
    end
    if not saveJson(IMAP_CHANGES_FILE, nextChanges) then
        TriggerClientEvent('nt-mapeditor:resetResult', playerSource, 'imaps', false, 'Failed to save the iMap reset.')
        return
    end

    imapChanges = nextChanges
    for _, hash in ipairs(hashes) do
        TriggerClientEvent('nt-imapviewer:settingUpdated', -1, hash, baselineState(imapByHash[hash]), false, recordHeld(imapChanges[tostring(hash)]))
    end
    TriggerClientEvent('nt-mapeditor:resetResult', playerSource, 'imaps', true, ('Restored %d displayed iMaps to baseline.'):format(#hashes))
end)

RegisterNetEvent('nt-imapviewer:setHeld', function(hashValue, heldValue)
    local playerSource = source
    local hash = tonumber(hashValue)
    local baseline = hash and imapByHash[hash]
    if not editorEnabled() or not baseline then
        return
    end

    local nextChanges = copyChanges(imapChanges)
    local key = tostring(hash)
    local state = recordState(nextChanges[key])
    nextChanges[key] = makeChangeRecord(state, heldValue == true)
    if not saveJson(IMAP_CHANGES_FILE, nextChanges) then
        return
    end

    imapChanges = nextChanges
    print(('[%s] %s %s hold on iMap %s.'):format(resourceName, GetPlayerName(playerSource) or tostring(playerSource), heldValue == true and 'set' or 'cleared', hash))
    TriggerClientEvent('nt-imapviewer:heldUpdated', -1, hash, recordHeld(imapChanges[key]))
end)
RegisterNetEvent('nt-mapeditor:exportConfig', function()
    local playerSource = source
    if not editorEnabled() then
        sendExportResult(playerSource, 'imaps', false, 'The iMap editor export is disabled.')
        return
    end

    exportImaps(playerSource)
end)
