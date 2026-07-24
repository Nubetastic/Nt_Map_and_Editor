local APPLY_BATCH_SIZE = 250

local function baselineState(imap)
    if imap.default then
        return 'default'
    end

    return imap.enable and 'enabled' or 'disabled'
end

local function normalizedState(value)
    if type(value) == 'table' then
        return normalizedState(value.state)
    end

    if value == 'default' or value == 'enabled' or value == 'disabled' then
        return value
    end

    -- Backward compatibility for the previous boolean JSON format.
    if type(value) == 'boolean' then
        return value and 'enabled' or 'disabled'
    end

    return nil
end

local function effectiveState(imap, changes)
    local changedState = normalizedState(changes and changes[tostring(imap.dec_hash)])
    return changedState or baselineState(imap)
end

local function applyImapState(hash, state)
    if state == 'enabled' then
        RequestImap(hash)
    elseif state == 'disabled' then
        RemoveImap(hash)
    end
end

local function applyConfiguredImaps(changes)
    if type(IMAP_CATALOG) ~= 'table' then
        print('[Nt_Map_and_Editor] IMAP_CATALOG is missing or invalid; no iMaps were applied.')
        return
    end

    local defaults = 0
    local requested = 0
    local removed = 0
    local invalid = 0

    for index, imap in ipairs(IMAP_CATALOG) do
        local hash = tonumber(imap.dec_hash)

        if hash and type(imap.default) == 'boolean' and type(imap.enable) == 'boolean' then
            local state = effectiveState(imap, changes)

            if state == 'default' then
                defaults = defaults + 1
            elseif state == 'enabled' then
                RequestImap(hash)
                requested = requested + 1
            elseif state == 'disabled' then
                RemoveImap(hash)
                removed = removed + 1
            else
                invalid = invalid + 1
            end
        else
            invalid = invalid + 1
            print(('[Nt_Map_and_Editor] Skipped invalid iMap record at index %d.'):format(index))
        end

        if index % APPLY_BATCH_SIZE == 0 then
            Wait(0)
        end
    end

    print(('[Nt_Map_and_Editor] Applied iMap config: %d default, %d requested, %d removed, %d invalid.'):format(
        defaults,
        requested,
        removed,
        invalid
    ))
end

RegisterNetEvent('nt-imapviewer:syncMapState', function(changes)
    applyConfiguredImaps(type(changes) == 'table' and changes or {})
end)

RegisterNetEvent('nt-imapviewer:settingUpdated', function(hash, state)
    hash = tonumber(hash)
    state = normalizedState(state)

    if hash and state then
        applyImapState(hash, state)
    end
end)

CreateThread(function()
    Wait(500)
    TriggerServerEvent('nt-imapviewer:requestMapState')
end)
