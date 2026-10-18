-- server.cfg:  set discord_bot_token "YOUR_BOT_TOKEN"   (use `set`, not `setr`)
-- server.cfg:  set discord_sync_nick "true"  (bot sets the Discord server nickname to  name#id )
-- server.cfg:  set discord_guild_id "YOUR_DISCORD_SERVER_ID"  (to use the nickname from your Discord server)
local QBCore = exports['qb-core']:GetCoreObject()

-- Notifications: use the custom "notify" resource when it is running, otherwise QBCore's default.
local function notify(src, msg, t)
    if src == 0 then return print('[custom_id] ' .. tostring(msg)) end
    if GetResourceState('notify') == 'started' then
        TriggerClientEvent('notify:client:notify', src, msg, t or 'primary', 5000)
    else
        TriggerClientEvent('QBCore:Notify', src, msg, t or 'primary')
    end
end

-- Admin check: megaadmin (Discord / group / ACE admins) first, then QBCore admin/god, then ACE "command".
local function isAdmin(src)
    if src == 0 then return true end
    if GetResourceState('megaadmin') == 'started' then
        local ok, rank = pcall(function() return exports['megaadmin']:GetAdminPermission(src) end)
        if ok and (rank == 'admin' or rank == 'god') then return true end -- 'mod' cannot manage IDs
    end
    return QBCore.Functions.HasPermission(src, 'admin') or QBCore.Functions.HasPermission(src, 'god')
        or IsPlayerAceAllowed(src, 'command')
end
local IDs, Names, Fonts, NC, IC = {}, {}, {}, {}, {}   -- [src]=id, [src]=name, [src]=font id, [src]=name color, [src]=id color
local Ov, Fetched = {}, {}   -- [src]=true if name set by admin (never overwritten), [src]=last time the Discord name was fetched
local REFRESH = 300   -- seconds: re-check the Discord name of online players every 5 min
local ready = false

MySQL.ready(function()
    MySQL.query.await([[CREATE TABLE IF NOT EXISTS player_ids (
        license VARCHAR(60) NOT NULL PRIMARY KEY,
        custom_id INT UNSIGNED NOT NULL UNIQUE,
        name_override VARCHAR(20) NULL)]])
    if not MySQL.scalar.await("SHOW COLUMNS FROM player_ids LIKE 'name_override'") then
        MySQL.query.await('ALTER TABLE player_ids ADD COLUMN name_override VARCHAR(20) NULL')
    end
    if not MySQL.scalar.await("SHOW COLUMNS FROM player_ids LIKE 'font'") then
        MySQL.query.await('ALTER TABLE player_ids ADD COLUMN font VARCHAR(30) NULL')
    end
    if not MySQL.scalar.await("SHOW COLUMNS FROM player_ids LIKE 'name_color'") then
        MySQL.query.await('ALTER TABLE player_ids ADD COLUMN name_color VARCHAR(7) NULL')
    end
    if not MySQL.scalar.await("SHOW COLUMNS FROM player_ids LIKE 'id_color'") then
        MySQL.query.await('ALTER TABLE player_ids ADD COLUMN id_color VARCHAR(7) NULL')
    end
    local cs = MySQL.scalar.await([[SELECT CCSA.character_set_name FROM information_schema.TABLES T
        JOIN information_schema.COLLATION_CHARACTER_SET_APPLICABILITY CCSA ON CCSA.collation_name = T.table_collation
        WHERE T.table_schema = DATABASE() AND T.table_name = 'player_ids']])
    if cs and cs ~= 'utf8mb4' then
        MySQL.query.await('ALTER TABLE player_ids CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci')
    end
    ready = true
end)

local function ident(src, p)
    for _, v in ipairs(GetPlayerIdentifiers(src)) do
        if v:sub(1, #p) == p then return v end
    end
end

-- keep letters/numbers/_ . - and any non-ASCII letter (Arabic, etc.); drops < > & quotes and spaces
-- (names are drawn by the NUI page, so Arabic works)
local function clean(s) return ((s or ''):gsub('[^%w_%.%-\128-\255]', '')) end

-- cut to n characters without breaking a multi-byte letter
local function cut(s, n)
    local len = utf8.len(s)
    if not len then return '' end
    if len <= n then return s end
    return s:sub(1, utf8.offset(s, n + 1) - 1)
end

local Last = {} -- [src] = last attempt time (retry every 10s until it works)

-- priority: nickname in YOUR Discord server > display name > username
-- (names with only emojis/arabic letters are skipped because the GTA font can't draw them)
local function pick(u, m)
    local list = { m and m.nick or '', u and u.global_name or '', u and u.username or '' }
    for i = 1, 3 do
        local raw = type(list[i]) == 'string' and list[i] or ''
        raw = raw:gsub('%s*#%d+%s*$', '') -- "Chla7#1" -> "Chla7"
        local n = cut(clean(raw), 24)
        if n ~= '' then return n end
    end
end

local function syncEnabled() return GetConvar('discord_sync_nick', 'false') == 'true' end

-- sets the nickname in your Discord server to  name#id  (e.g. Chla7#1)
-- `current` = nickname we already know (skips the request when it is already correct)
local function syncNick(src, current)
    if not syncEnabled() then return end
    local guild, token = GetConvar('discord_guild_id', ''), GetConvar('discord_bot_token', '')
    local d = ident(src, 'discord:')
    local name, id = Names[src], IDs[src]
    if guild == '' or token == '' or not d or not name or not id then return end
    local target = name .. '#' .. tostring(id)
    if current == target then return end
    PerformHttpRequest(('https://discord.com/api/v10/guilds/%s/members/%s'):format(guild, d:sub(9)), function(status)
        if status == 200 then return end
        print(('^1[custom_id] could not set Discord nickname (status %s). Bot needs "Manage Nicknames" + its role must be ABOVE the member\'s highest role. The server owner\'s nickname cannot be changed by a bot.^7'):format(tostring(status)))
    end, 'PATCH', json.encode({ nick = target }), {
        Authorization = 'Bot ' .. token,
        ['Content-Type'] = 'application/json',
        ['X-Audit-Log-Reason'] = 'custom_id sync',
    })
end

local function resolveName(src, force)
    if Ov[src] and not syncEnabled() then return end -- admin set a custom name and no Discord sync needed
    if Names[src] and not force and os.time() - (Fetched[src] or 0) < REFRESH then return end
    if Last[src] and os.time() - Last[src] < 10 then return end
    Last[src] = os.time()
    local d = ident(src, 'discord:')
    if not d then
        return print(('^3[custom_id] %s has no Discord linked (Discord app must be open before starting FiveM)^7'):format(GetPlayerName(src)))
    end
    d = d:sub(9)
    local token = GetConvar('discord_bot_token', '')
    if token == '' then
        return print('^1[custom_id] discord_bot_token is missing in server.cfg (use: set discord_bot_token "TOKEN")^7')
    end
    local guild = GetConvar('discord_guild_id', '')
    local headers = { Authorization = 'Bot ' .. token }

    local function done(u, m)
        if not GetPlayerName(src) then return end -- player left
        Fetched[src] = os.time()
        if not Ov[src] then -- names set from the panel are never overwritten
            local n = pick(u, m)
            if n then Names[src] = n end
        end
        if m then syncNick(src, m.nick) end -- re-apply name#id if it was changed in Discord
    end

    local function userOnly() -- fallback: global Discord profile
        PerformHttpRequest('https://discord.com/api/v10/users/' .. d, function(status, body)
            if status ~= 200 then
                return print(('^1[custom_id] Discord API /users returned %s (check the bot token)^7'):format(tostring(status)))
            end
            done(json.decode(body))
        end, 'GET', '', headers)
    end

    if guild == '' then
        print('^3[custom_id] discord_guild_id is not set: using global Discord username (set discord_guild_id "SERVER_ID" for server nicknames)^7')
        return userOnly()
    end

    PerformHttpRequest(('https://discord.com/api/v10/guilds/%s/members/%s'):format(guild, d), function(status, body)
        if status == 200 then
            local m = json.decode(body)
            return done(m and m.user, m)
        end
        print(('^3[custom_id] Discord guild member returned %s (is the bot in the server? is guild id right? is the player in the server?) -> fallback to global name^7'):format(tostring(status)))
        userOnly()
    end, 'GET', '', headers)
end

local function load(src)
    while not ready do Wait(100) end
    local lic = ident(src, 'license:')
    if not lic then return end
    local row = MySQL.single.await('SELECT custom_id, name_override, font, name_color, id_color FROM player_ids WHERE license = ?', { lic })
    if row then
        IDs[src] = row.custom_id
        if row.name_override then Names[src], Ov[src] = row.name_override, true end
        Fonts[src], NC[src], IC[src] = row.font, row.name_color, row.id_color
    else
        for _ = 1, 200 do
            local n = math.random(1000, 9999)
            if not MySQL.scalar.await('SELECT 1 FROM player_ids WHERE custom_id = ?', { n }) then
                MySQL.insert.await('INSERT INTO player_ids (license, custom_id) VALUES (?, ?)', { lic, n })
                IDs[src] = n
                break
            end
        end
    end
    resolveName(src, true) -- fresh Discord name on every join
end

local function getId(src) if not IDs[src] then load(src) end return IDs[src] end

AddEventHandler('playerJoining', function() load(source) end)
AddEventHandler('playerDropped', function() IDs[source], Names[source], Last[source], Fonts[source], NC[source], IC[source], Ov[source], Fetched[source] = nil, nil, nil, nil, nil, nil, nil, nil end)
CreateThread(function() Wait(2000) for _, s in ipairs(GetPlayers()) do load(tonumber(s)) end end)

exports('GetCustomId', getId)
-- used by other resources (ex: deathscreen): returns { id, name, font, nc, ic } of an online player
exports('GetCustomInfo', function(src)
    local id = getId(src)
    if not id then return nil end
    resolveName(src)
    return { id = id, name = Names[src] or 'NoDiscord', font = Fonts[src], nc = NC[src], ic = IC[src] }
end)

exports('GetSourceByCustomId', function(id)
    for s, v in pairs(IDs) do if v == tonumber(id) then return s end end
end)

RegisterNetEvent('custom_id:requestAll', function()
    local data = {}
    for _, p in ipairs(GetPlayers()) do
        local s = tonumber(p)
        local id = getId(s)
        if id then
            resolveName(s) -- retry if Discord name is not loaded yet
            data[tostring(s)] = { id = id, name = Names[s] or 'NoDiscord', font = Fonts[s], nc = NC[s], ic = IC[s] }
        end
    end
    TriggerClientEvent('custom_id:syncAll', source, data)
end)

QBCore.Commands.Add('setid', 'Change a player ID', {
    { name = 'old', help = 'Current ID' }, { name = 'new', help = 'New ID' } },
    false, function(src, args)
        if not isAdmin(src) then return notify(src, 'You are not admin', 'error') end
        local old, new = tonumber(args[1]), tonumber(args[2])
        if not old or not new or new < 1 or new > 999999 or new ~= math.floor(new) then
            return notify(src, 'Invalid ID (1-999999)', 'error')
        end
        if MySQL.scalar.await('SELECT 1 FROM player_ids WHERE custom_id = ?', { new }) then
            return notify(src, 'ID already in use', 'error')
        end
        if MySQL.update.await('UPDATE player_ids SET custom_id = ? WHERE custom_id = ?', { new, old }) == 0 then
            return notify(src, 'Old ID not found', 'error')
        end
        for s, v in pairs(IDs) do if v == old then IDs[s] = new syncNick(s) end end
        notify(src, ('ID changed: %d -> %d'):format(old, new), 'success')
    end)

QBCore.Commands.Add('id', 'Show your ID', {}, false, function(src)
    notify(src, 'Your ID: ' .. tostring(getId(src)), 'primary')
end)

-- /testid [ID] (admin): preview "name #ID" above a head for 10 seconds (only on your screen)
QBCore.Commands.Add('testid', 'Preview name + ID above a head (10s)', {
    { name = 'id', help = 'Player ID (empty = yourself)' } },
    false, function(src, args)
        if not isAdmin(src) then return notify(src, 'You are not admin', 'error') end
        local target = src
        if args[1] then
            target = exports[GetCurrentResourceName()]:GetSourceByCustomId(args[1])
            if not target then
                return notify(src, 'No online player with that ID', 'error')
            end
        end
        local id = getId(target)
        TriggerClientEvent('custom_id:test', src, target,
            { name = Names[target] or 'NoDiscord', id = id, font = Fonts[target], nc = NC[target], ic = IC[target] })
    end)


-- /manageid: opens the panel (change a player's ID and/or the name shown above the head)
-- registered without a QBCore permission so we can tell you WHY it is refused
QBCore.Commands.Add('manageid', 'Open the ID manager panel', {}, false, function(src)
    print(('[custom_id] /manageid used by %s (src %s)'):format(GetPlayerName(src) or '?', src))
    if src == 0 then return print('[custom_id] use /manageid in game') end
    if not isAdmin(src) then
        print(('^1[custom_id] %s is NOT admin. Add to server.cfg: add_principal identifier.%s qbcore.admin^7')
            :format(GetPlayerName(src), ident(src, 'license:') or 'license:xxxx'))
        return notify(src, 'You are not admin (see server console)', 'error')
    end
    local list = {}
    for s, id in pairs(IDs) do list[#list + 1] = { id = id, name = Names[s] or 'NoDiscord', font = Fonts[s], nc = NC[s], ic = IC[s] } end
    table.sort(list, function(a, b) return a.id < b.id end)
    TriggerClientEvent('custom_id:open', src, list)
end)

-- shared by the /manageid panel and by other resources (ex: admin panel) through exports.AdminSave
-- `silent` = true -> does not close the /manageid panel on the admin's screen
local function doSave(src, target, newId, name, reset, font, nameColor, idColor, silent)
    target, newId = tonumber(target), tonumber(newId)
    if not target then return notify(src, 'Enter a valid target ID', 'error') end
    local row = MySQL.single.await('SELECT license FROM player_ids WHERE custom_id = ?', { target })
    if not row then return notify(src, 'Target ID not found', 'error') end

    -- font: nil/'' = keep, 'spookyy' = back to default, otherwise a font id from html/index.html (FONTS)
    local setFont
    if font and font ~= '' then
        if type(font) ~= 'string' or not font:match('^[a-z0-9]+$') or #font > 30 then
            return notify(src, 'Invalid font', 'error')
        end
        setFont = font
    end

    -- colors: nil/'' = keep, 'default' = back to white, otherwise #rrggbb
    local function parseColor(c)
        if c == nil or c == '' then return false end
        if c == 'default' then return true, nil end
        if type(c) == 'string' and c:match('^#%x%x%x%x%x%x$') then return true, c:lower() end
        return nil
    end
    local setNC, ncVal = parseColor(nameColor)
    local setIC, icVal = parseColor(idColor)
    if setNC == nil or setIC == nil then return notify(src, 'Invalid color (use #rrggbb)', 'error') end

    local final = target
    if newId and newId ~= target then
        if newId < 1 or newId > 999999 or newId ~= math.floor(newId) then
            return notify(src, 'New ID must be 1-999999', 'error')
        end
        if MySQL.scalar.await('SELECT 1 FROM player_ids WHERE custom_id = ?', { newId }) then
            return notify(src, 'New ID already in use', 'error')
        end
        MySQL.update.await('UPDATE player_ids SET custom_id = ? WHERE license = ?', { newId, row.license })
        for s, v in pairs(IDs) do if v == target then IDs[s] = newId end end
        final = newId
    end

    local live
    for s, v in pairs(IDs) do if v == final then live = s end end

    if setNC then
        MySQL.update.await('UPDATE player_ids SET name_color = ? WHERE license = ?', { ncVal, row.license })
        if live then NC[live] = ncVal end
    end
    if setIC then
        MySQL.update.await('UPDATE player_ids SET id_color = ? WHERE license = ?', { icVal, row.license })
        if live then IC[live] = icVal end
    end

    if setFont then
        local value = setFont ~= 'spookyy' and setFont or nil
        MySQL.update.await('UPDATE player_ids SET font = ? WHERE license = ?', { value, row.license })
        if live then Fonts[live] = value end
    end

    if reset then
        MySQL.update.await('UPDATE player_ids SET name_override = NULL WHERE license = ?', { row.license })
        if live then Names[live], Last[live], Ov[live], Fetched[live] = nil, nil, nil, nil resolveName(live, true) end
    elseif name and name ~= '' then
        local n = cut(clean(name), 20)
        if n == '' then return notify(src, 'Name has no valid characters', 'error') end
        MySQL.update.await('UPDATE player_ids SET name_override = ? WHERE license = ?', { n, row.license })
        if live then Names[live], Ov[live] = n, true end
    end

    if live and not reset then syncNick(live) end -- (reset: nickname is synced after the Discord name is re-fetched)
    notify(src, 'Saved', 'success')
    if not silent then TriggerClientEvent('custom_id:close', src) end
end

RegisterNetEvent('custom_id:save', function(target, newId, name, reset, font, nameColor, idColor)
    local src = source
    if not isAdmin(src) then return end
    doSave(src, target, newId, name, reset, font, nameColor, idColor, false)
end)

-- server-side only (cannot be called by players): the calling resource must check admin permission itself
exports('AdminSave', function(src, target, newId, name, reset)
    doSave(src, target, newId, name, reset, '', '', '', true)
end)
