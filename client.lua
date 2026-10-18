local Distance, Key = 15.0, 'B'   -- draw distance, default key (rebindable in FiveM settings)
local players, show, test = {}, false, nil
local sent = false

RegisterNetEvent('custom_id:syncAll', function(d) players = d or {} end)

RegisterCommand('+showids', function() show = true TriggerServerEvent('custom_id:requestAll') end, false)
RegisterCommand('-showids', function() show = false end, false)
RegisterKeyMapping('+showids', 'Show player IDs', 'keyboard', Key)

CreateThread(function() -- refresh data while visible
    while true do
        if show then TriggerServerEvent('custom_id:requestAll') end
        Wait(2000)
    end
end)

-- /testid preview (10 seconds, only on your screen, works on yourself too)
RegisterNetEvent('custom_id:test', function(serverId, info)
    test = { sid = serverId, info = info, exp = GetGameTimer() + 10000 }
end)

-- world position -> screen position, then the text is drawn by the NUI page (Spookyy font)
-- info = { name, id, font, nc (name color), ic (id color) }
local function addTag(tags, x, y, z, info)
    local on, sx, sy = GetScreenCoordFromWorldCoord(x, y, z)
    if on then
        tags[#tags + 1] = { x = sx, y = sy, name = info.name, id = '#' .. tostring(info.id), font = info.font, nc = info.nc, ic = info.ic }
    end
end

CreateThread(function()
    while true do
        if test and GetGameTimer() > test.exp then test = nil end
        if show or test then
            local tags = {}
            local me = PlayerPedId()
            local mc = GetEntityCoords(me)
            if show then
                for _, p in ipairs(GetActivePlayers()) do
                    if p ~= PlayerId() then
                        local ped = GetPlayerPed(p)
                        local c = GetEntityCoords(ped)
                        local info = players[tostring(GetPlayerServerId(p))]
                        if info and #(mc - c) <= Distance and IsEntityVisible(ped)
                            and HasEntityClearLosToEntity(me, ped, 17) then
                            addTag(tags, c.x, c.y, c.z + 1.05, info)
                        end
                    end
                end
            end
            if test then
                local p = GetPlayerFromServerId(test.sid)
                if p ~= -1 then
                    local c = GetEntityCoords(GetPlayerPed(p))
                    addTag(tags, c.x, c.y, c.z + 1.05, test.info)
                end
            end
            SendNUIMessage({ tags = tags })
            sent = true
            Wait(0)
        else
            if sent then SendNUIMessage({ tags = {} }) sent = false end
            Wait(500)
        end
    end
end)

-- /manageid panel (NUI)
local function closePanel()
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end
RegisterNetEvent('custom_id:open', function(list)
    print('[custom_id] opening panel, players: ' .. tostring(list and #list or 0))
    SetNuiFocus(true, true)
    SendNUIMessage({ action = 'open', players = list })
end)
RegisterNetEvent('custom_id:close', closePanel)
RegisterNUICallback('close', function(_, cb) closePanel() cb('ok') end)
RegisterNUICallback('save', function(d, cb)
    TriggerServerEvent('custom_id:save', d.target, d.newId, d.name, d.reset, d.font, d.nameColor, d.idColor)
    cb('ok')
end)
