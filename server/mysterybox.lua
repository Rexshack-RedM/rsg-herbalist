----------------------------------------------------------------------------
-- Herb mystery box
--
-- Server-authoritative, mirroring the herb-node gathering flow in
-- server/server.lua: the server alone decides where the box is, when it
-- moves, and what's inside it. Clients are only ever told the current
-- location and, on open, whether they were close enough - they never pick
-- the coord, the contents, or the timing themselves.
--
-- Only one box exists on the map at any given time. It sits at its current
-- coord for Config.MysteryBox.relocateAfterSeconds, then is removed and a
-- new coord (different from the current one, when more than one is
-- configured) is picked and a fresh box spawned there. Opening the box
-- (looting it) also triggers an immediate relocation rather than waiting
-- out the rest of that timer, since the box is a one-shot pickup.
----------------------------------------------------------------------------

local RSGCore = exports['rsg-core']:GetCoreObject()

lib.locale()

local mb = Config.MysteryBox

local function Debug(msg)
    if Config.Debug then
        print('[rsg-herbalist:mysterybox] ' .. msg)
    end
end

if not mb or not mb.enabled then
    return
end

if not mb.coords or #mb.coords == 0 then
    Debug('no coords configured, mystery box disabled')
    return
end

local currentCoord = nil
local currentCoordIndex = nil
local relocateAt = nil -- os.time() timestamp the box should next relocate at
local lastOpenAt = {}  -- src -> GameTimer of last open attempt, per-player anti-spam

local function PickNewCoordIndex()
    if #mb.coords == 1 then return 1 end
    local idx
    repeat
        idx = math.random(#mb.coords)
    until idx ~= currentCoordIndex
    return idx
end

local function BroadcastBox()
    TriggerClientEvent('rsg-herbalist:client:SetMysteryBox', -1, currentCoord)
end

-- Removes the box (if any) and spawns a fresh one at a new coord, resetting
-- the relocation timer. Used both by the periodic relocation loop below and
-- immediately after a successful open.
local function RelocateBox()
    currentCoordIndex = PickNewCoordIndex()
    currentCoord = mb.coords[currentCoordIndex]
    relocateAt = os.time() + mb.relocateAfterSeconds
    Debug('box relocated to index=' .. currentCoordIndex)
    BroadcastBox()
end

RegisterNetEvent('RSGCore:Server:OnPlayerLoaded', function()
    local src = source
    TriggerClientEvent('rsg-herbalist:client:SetMysteryBox', src, currentCoord)
end)

-- Fired by the client the moment its own script starts (see client/mysterybox.lua).
-- The one-off broadcast in RelocateBox() only reaches clients that are
-- already listening at that exact instant, and OnPlayerLoaded above only
-- fires on a fresh login - neither covers a player who's already connected
-- when this resource (re)starts. This closes that gap: every client
-- explicitly asks for the current state as soon as it's ready to receive it,
-- rather than hoping it didn't miss the one broadcast.
RegisterNetEvent('rsg-herbalist:server:requestMysteryBox', function()
    local src = source
    Debug('src=' .. src .. ' requested current box state')
    TriggerClientEvent('rsg-herbalist:client:SetMysteryBox', src, currentCoord)
end)

AddEventHandler('playerDropped', function()
    lastOpenAt[source] = nil
end)

CreateThread(function()
    RelocateBox()
    while true do
        Wait(60 * 1000)
        if relocateAt and os.time() >= relocateAt then
            RelocateBox()
        end
    end
end)

-- Builds the loot list for a single box: a random number (herbCountMin -
-- herbCountMax) of regular herbs from herbPool, picked with repetition, plus
-- exactly one guaranteed entry from orchidPool.
local function RollLoot()
    local loot = {}

    local orchid = mb.orchidPool[math.random(#mb.orchidPool)]
    loot[#loot + 1] = orchid

    local herbCount = math.random(mb.herbCountMin, mb.herbCountMax)
    for _ = 1, herbCount do
        loot[#loot + 1] = mb.herbPool[math.random(#mb.herbPool)]
    end

    return loot
end

RegisterNetEvent('rsg-herbalist:server:openMysteryBox', function()
    local src = source
    Debug('src=' .. src .. ' requested open')

    if not currentCoord then
        Debug('no box currently spawned')
        return
    end

    local now = GetGameTimer()
    if lastOpenAt[src] and (now - lastOpenAt[src]) < Config.GatherCooldownMs then
        Debug('cooldown src=' .. src)
        Webhook.FlagSuspicious(src, 'mysterybox_cooldown', 'fired again ' .. (now - lastOpenAt[src]) .. 'ms after previous open attempt')
        return
    end

    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then Debug('no player'); return end

    local ped = GetPlayerPed(src)
    if ped == 0 then Debug('invalid ped src=' .. src); return end

    local playerPos = GetEntityCoords(ped)
    local dist = #(playerPos - currentCoord)
    if dist > mb.scopeRangeGather then
        Debug('too far, dist=' .. dist)
        Webhook.FlagSuspicious(src, 'mysterybox_distance', ('dist=%.1f max=%.1f'):format(dist, mb.scopeRangeGather))
        return
    end

    -- Reserve the cooldown slot, and clear currentCoord immediately, before
    -- touching inventory - closes the window for a double-fired event (or
    -- two players opening within the same tick) to loot the same box twice.
    lastOpenAt[src] = now
    currentCoord = nil
    BroadcastBox()

    local loot = RollLoot()
    local grantedLabels = {}
    for _, item in ipairs(loot) do
        local added = Player.Functions.AddItem(item, 1)
        if added then
            TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[item], 'add', 1)
            local itemDef = RSGCore.Shared.Items[item]
            grantedLabels[#grantedLabels + 1] = itemDef and itemDef.label or item
        end
    end

    TriggerClientEvent('ox_lib:notify', src, {
        title = locale('mysterybox_found_title'),
        description = locale('mysterybox_found_description'),
        type = 'success',
        duration = 5000
    })

    if #grantedLabels > 0 then
        Webhook.LogMysteryBox(src, grantedLabels)
    end

    RelocateBox()
end)
