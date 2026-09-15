local RSGCore = exports['rsg-core']:GetCoreObject()

lib.locale()

local function Debug(msg)
    if Config.Debug then
        print('[rsg-herbalist] ' .. msg)
    end
end

-- Composite (stripped of COMPOSITE_LOOTABLE_/_INTERACTABLE) -> inventory item.
-- Entries below the line are kept for herbs that already have item + image
-- assets defined but have no spawn coords in shared/zones_data.lua yet, so
-- they're currently unreachable in-game. Left in place (rather than deleted)
-- so adding coords for them later doesn't also require restoring this
-- mapping - remove them if these herbs are never going to be added.
local toItem = {
    ["AGARITA_DEF"] = "herb_agarita",
    ["ALASKAN_GINSENG_ROOT_DEF"] = "herb_alaskan_ginseng",
    ["AMERICAN_GINSENG_ROOT_DEF"] = "herb_american_ginseng",
    ["BAY_BOLETE_DEF"] = "herb_bay_boletus",
    ["BITTERWEED_DEF"] = "herb_bitterweed",
    ["BLACK_BERRY_DEF"] = "herb_black_berry",
    ["BLACK_CURRANT_DEF"] = "herb_black_current",
    ["BLOODFLOWER_DEF"] = "herb_bloodflower",
    ["BURDOCK_ROOT_DEF"] = "herb_burdock_root",
    ["CARDINAL_FLOWER_DEF"] = "herb_cardinal_flower",
    ["CHANTERELLES_DEF"] = "herb_chanterelles",
    ["CHOC_DAISY_DEF"] = "herb_choc_daisy",
    ["COMMON_BULRUSH_DEF"] = "herb_common_bullrush",
    ["CREEKPLUM_DEF"] = "herb_creek_plum",
    ["CREEPING_THYME_DEF"] = "herb_creeping_thyme",
    ["CROWS_GARLIC_DEF"] = "herb_crows_garlic",
    ["DESERT_SAGE_DEF"] = "herb_desert_sage",
    ["ENGLISH_MACE_DEF"] = "herb_english_mace",
    ["EVERGREEN_HUCKLEBERRY_DEF"] = "herb_evergreen_huckleberry",
    ["GOLDEN_CURRANT_DEF"] = "herb_golden_currant",
    ["HARRIETUM_OFFICINALIS_DEF"] = "herb_harrietum_officinalis",
    ["HUMMINGBIRD_SAGE_DEF"] = "herb_hummingbird_sage",
    ["INDIAN_TOBACCO_DEF"] = "herb_indian_tobacco",
    ["MILKWEED_DEF"] = "herb_milkweed",
    ["OLEANDER_SAGE_DEF"] = "herb_oleander_sage",
    ["OREGANO_DEF"] = "herb_oregano",
    ["PARASOL_MUSHROOM_DEF"] = "herb_parasol_mushroom",
    ["PRAIRIE_POPPY_DEF"] = "herb_prairie_poppy",
    ["RAMS_HEAD_DEF"] = "herb_rams_head",
    ["RED_RASPBERRY_DEF"] = "herb_red_raspberry",
    ["RED_SAGE_DEF"] = "herb_red_sage",
    ["SALTBUSH_DEF"] = "herb_saltbush",
    ["TEXAS_BONNET_DEF"] = "herb_texas_blue_bonnet",
    ["VIOLET_SNOWDROP_DEF"] = "herb_violet_snowdrop",
    ["WILD_CARROT_DEF"] = "herb_wild_carrot",
    ["WILD_FEVERFEW_DEF"] = "herb_wild_feverfew",
    ["WILD_MINT_DEF"] = "herb_wild_mint",
    ["WILD_RHUBARB_DEF"] = "herb_wild_rhubarb",
    ["WINTERGREEN_BERRY_DEF"] = "herb_wintergreen_berry",
    ["WISTERIA_DEF"] = "herb_wisteria",
    ["YARROW_DEF"] = "herb_yarrow",
    -- orchid
    ["ORCHID_ACUNA_STAR_DEF"] = "herb_acuna_star_orchid",
    ["ORCHID_CIGAR_DEF"] = "herb_cigar_orchid",
    ["ORCHID_CLAM_SHELL_DEF"] = "herb_clam_shell_orchid",
    ["ORCHID_DRAGONS_DEF"] = "herb_dragons_mouth_orchid",
    ["ORCHID_GHOST_DEF"] = "herb_ghost_orchid",
    ["ORCHID_LADY_NIGHT_DEF"] = "herb_lady_of_the_night_orchid",
    ["ORCHID_LADY_SLIPPER_DEF"] = "herb_lady_slipper",
    ["ORCHID_MOCCASIN_DEF"] = "herb_moccasin_flower_orchid",
    ["ORCHID_NIGHT_SCENTED_DEF"] = "herb_night_scented_orchid",
    ["ORCHID_QUEENS_DEF"] = "herb_queens_orchid",
    ["ORCHID_RAT_TAIL_DEF"] = "herb_rat_tail_orchid",
    ["ORCHID_SPARROWS_DEF"] = "herb_sparrows_egg_orchid",
    ["ORCHID_SPIDER_DEF"] = "herb_spider_orchid",
    ["ORCHID_VANILLA_DEF"] = "herb_vanilla_orchid",
}

local SUPPRESSION_WEAROFF_SECONDS = Config.SuppressionWearoffSeconds
local GATHER_COOLDOWN_MS = Config.GatherCooldownMs
local SCOPE_RANGE_GATHER = Config.ScopeRangeGather

local suppressed = {}

-- Build a trusted lookup of every valid spawn point from the shared zone
-- data, keyed the same way the client keys them. This is authoritative:
-- the client is only ever trusted to tell us *which* coordKey it thinks it
-- gathered from, never the coordinates or plant type themselves.
--
-- currentPlant tracks which composite is actually "live" at each coordKey
-- right now (mirrors the client's default assignment until a node regrows
-- into something else). Gather requests are validated against this, not
-- just "is this item valid somewhere in the zone" - otherwise a modified
-- client could claim any item the zone is capable of spawning, regardless
-- of what's actually there.
local function coordKeyOf(coord)
    return string.format("%.1f_%.1f_%.1f", coord.x, coord.y, coord.z)
end

local validSpawns = {}
local defaultPlant = {}
local currentPlant = {}
for zoneId, zone in pairs(Config.Zones) do
    local plants = zone.plants
    for ci, coord in ipairs(zone.coords) do
        local key = coordKeyOf(coord)
        local plant = plants[((ci - 1) % #plants) + 1]
        validSpawns[key] = { coord = vec3(coord.x, coord.y, coord.z), zone = zoneId }
        defaultPlant[key] = plant
        currentPlant[key] = plant
    end
end

local function StripComposite(plant)
    return plant:gsub("COMPOSITE_LOOTABLE_", ""):gsub("_INTERACTABLE", "")
end

local lastGatherAt = {}

RegisterNetEvent('rsg-herbalist:server:gathered', function(compositeTypeFormatted, coordKey)
    local src = source
    Debug('src=' .. src .. ' key=' .. tostring(coordKey))

    local spawn = validSpawns[coordKey]
    if not spawn then
        Debug('unknown spawn key=' .. tostring(coordKey))
        Webhook.FlagSuspicious(src, 'gather_unknown_spawn_key', 'coordKey=' .. tostring(coordKey))
        return
    end

    if suppressed[coordKey] then
        Debug('suppressed key=' .. coordKey)
        return
    end

    local now = GetGameTimer()
    if lastGatherAt[src] and (now - lastGatherAt[src]) < GATHER_COOLDOWN_MS then
        Debug('cooldown src=' .. src)
        Webhook.FlagSuspicious(src, 'gather_cooldown', 'fired again ' .. (now - lastGatherAt[src]) .. 'ms after previous gather')
        return
    end

    local livePlant = currentPlant[coordKey]
    local liveStripped = livePlant and StripComposite(livePlant)
    if not liveStripped or liveStripped ~= compositeTypeFormatted then
        Debug('plant mismatch key=' .. coordKey .. ' claimed=' .. tostring(compositeTypeFormatted) .. ' live=' .. tostring(liveStripped))
        Webhook.FlagSuspicious(src, 'gather_plant_mismatch', ('claimed=%s live=%s'):format(tostring(compositeTypeFormatted), tostring(liveStripped)))
        return
    end

    local item = toItem[compositeTypeFormatted]
    if not item then Debug('no item mapping for ' .. tostring(compositeTypeFormatted)); return end

    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then Debug('no player'); return end

    local ped = GetPlayerPed(src)
    if ped == 0 then Debug('invalid ped src=' .. src); return end

    local playerPos = GetEntityCoords(ped)
    local dist = #(playerPos - spawn.coord)
    if dist > SCOPE_RANGE_GATHER then
        Debug('too far')
        Webhook.FlagSuspicious(src, 'gather_distance', ('dist=%.1f max=%.1f'):format(dist, SCOPE_RANGE_GATHER))
        return
    end

    -- Reserve the cooldown slot before touching inventory so two gather
    -- events fired back-to-back for the same player (e.g. a client sending
    -- the event twice) can't both slip through while the first is still
    -- being processed.
    lastGatherAt[src] = now

    local added = Player.Functions.AddItem(item, 1)
    if added then
        suppressed[coordKey] = os.time() + SUPPRESSION_WEAROFF_SECONDS
        TriggerClientEvent('rsg-herbalist:client:SetSuppressed', -1, coordKey, true)
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[item], 'add', 1)
        Webhook.LogGather(src, RSGCore.Shared.Items[item] and RSGCore.Shared.Items[item].label or item, coordKey)
    else
        TriggerClientEvent('ox_lib:notify', src, {
            title = locale('inventory_full_title'),
            description = locale('inventory_full_description'),
            type = 'error',
            duration = 5000
        })
        TriggerClientEvent('rsg-herbalist:client:ForceReload', src, coordKey)
    end
end)

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(60 * 1000)
        local timestamp = os.time()
        for coordKey, wearoff in pairs(suppressed) do
            if wearoff <= timestamp then
                suppressed[coordKey] = nil

                -- Regrowth: pick the node's next plant here, server-side, so
                -- every client ends up displaying (and can only gather) the
                -- same thing. Previously each client re-rolled this locally,
                -- which let players see different plants at the same node
                -- and let a modified client claim any item valid for the zone.
                local spawn = validSpawns[coordKey]
                if spawn then
                    local zone = Config.Zones[spawn.zone]
                    if zone and #zone.plants >= 2 then
                        local current = currentPlant[coordKey]
                        local newPlant
                        repeat
                            newPlant = zone.plants[math.random(#zone.plants)]
                        until newPlant ~= current
                        currentPlant[coordKey] = newPlant
                    end
                end

                TriggerClientEvent('rsg-herbalist:client:SetSuppressed', -1, coordKey, false, currentPlant[coordKey])
            end
        end
    end
end)

RegisterNetEvent('RSGCore:Server:OnPlayerLoaded', function()
    local src = source

    -- Nodes that have regrown into something other than their zone default
    -- need to be sent explicitly, otherwise a client joining mid-session
    -- would build its default-assignment plant for that coordKey and show
    -- something different to everyone else already looking at it.
    local plantOverrides = {}
    for coordKey, plant in pairs(currentPlant) do
        if plant ~= defaultPlant[coordKey] then
            plantOverrides[coordKey] = plant
        end
    end

    TriggerClientEvent('rsg-herbalist:client:SetAllSuppressed', src, suppressed, plantOverrides)
end)

----------------------------------------------------------------------------
-- Tonic crafting
--
-- Server-authoritative, mirroring the gathering flow above: the client only
-- ever tells us *which* recipe it wants, never how much of anything it has
-- or what it should receive. We look the recipe up ourselves, verify the
-- job lock (if enabled), verify the player actually holds every ingredient
-- in the required amount, and only then remove the ingredients and hand
-- back an "ok to start" so the client can play its progress bar. The output
-- item is only granted once the client reports the bar finished, and if the
-- client instead reports a cancel (or disconnects mid-craft) the reserved
-- ingredients are refunded.
--
-- These locals are declared here, ahead of the playerDropped handler below,
-- because Lua locals aren't hoisted - referencing lastCraftAt/pendingCraft
-- from a handler registered before their `local` line would see a nil
-- upvalue (the global of the same name, which is never set) instead of
-- these tables.
----------------------------------------------------------------------------

local tonicsById = {}
for _, tonic in ipairs(Config.Tonics) do
    tonicsById[tonic.id] = tonic
end

local lastCraftAt = {}
-- pendingCraft[src] = { id = tonicId, startedAt = GameTimer } for the one
-- in-flight craft a player is currently allowed to finish/cancel. Anything
-- else (finishing/cancelling a recipe that isn't pending) is ignored.
local pendingCraft = {}
-- lastTonicUseAt[src] = GameTimer of the last tonic that was actually drunk.
-- Shared across every tonic in Config.TonicEffects (not per-item), so
-- Config.TonicUseCooldownMs is a single "how often can you drink a tonic at
-- all" limit rather than a per-flavour one.
local lastTonicUseAt = {}

AddEventHandler('playerDropped', function()
    lastGatherAt[source] = nil
    lastCraftAt[source] = nil
    pendingCraft[source] = nil
    lastTonicUseAt[source] = nil
end)

local function HasHerbalistJob(Player)
    if not Config.LockTonicCraftingToJob then return true end
    local job = Player.PlayerData and Player.PlayerData.job
    return job and job.name == Config.TonicCraftingJobName
end

-- Sums every stack of itemName the player is carrying, rather than trusting
-- GetItemByName to return the true total. GetItemByName only returns a
-- single matching slot; if the player holds the same item split across more
-- than one inventory slot (e.g. two separate pickups that never stacked),
-- relying on it would undercount and could wrongly reject a craft the
-- player can actually afford - inconsistent with CountItem on the client
-- (used for the "have/required" display), which already sums every slot.
local function PlayerItemCount(Player, itemName)
    local items = Player.PlayerData and Player.PlayerData.items
    if not items then return 0 end
    local total = 0
    for _, item in pairs(items) do
        if item and item.name == itemName then
            total = total + (item.amount or 0)
        end
    end
    return total
end

-- Using the mortar & pestle from the inventory is just an alternate entry
-- point into the same crafting menu - it does not itself grant, remove, or
-- validate anything craft-related. The job-lock check happens here too
-- (not just when a craft is actually requested) so a locked-out player
-- can't even get the menu open by using the item, and so they get an
-- explicit "you're not authorized" notification instead of a menu that
-- silently rejects every craft attempt.
RSGCore.Functions.CreateUseableItem('mortarpestle', function(source, item)
    local src = source

    if not Config.TonicCraftingEnabled then return end

    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    if not HasHerbalistJob(Player) then
        Debug('mortarpestle: job lock rejected src=' .. src)
        TriggerClientEvent('ox_lib:notify', src, {
            title = locale('craft_locked_title'),
            description = locale('craft_locked_description'),
            type = 'error',
            duration = 5000
        })
        return
    end

    TriggerClientEvent('rsg-herbalist:client:OpenTonicCrafting', src)
end)

-- Drinking a finished tonic applies its health/stamina boost (see
-- Config.TonicEffects) and consumes one of the item. The inventory resource
-- does NOT remove used items on its own (CreateUseableItem just fires this
-- callback) - RemoveItem has to be called explicitly here, the same way
-- requestCraft/handleConsumption remove their own items. One handler is
-- registered per tonic that has an entry in Config.TonicEffects, so tonics
-- without one (or a modder's own custom tonic that isn't listed) just get
-- RSG's normal "used an item" behaviour with no extra effect and no
-- removal.
for itemName in pairs(Config.TonicEffects) do
    RSGCore.Functions.CreateUseableItem(itemName, function(source, item)
        local src = source
        local Player = RSGCore.Functions.GetPlayer(src)
        if not Player then return end

        local now = GetGameTimer()
        local cooldownMs = Config.TonicUseCooldownMs or 0
        if cooldownMs > 0 and lastTonicUseAt[src] and (now - lastTonicUseAt[src]) < cooldownMs then
            local remainingMs = cooldownMs - (now - lastTonicUseAt[src])
            Debug('tonic use rejected (cooldown) src=' .. src .. ' remainingMs=' .. remainingMs)
            TriggerClientEvent('ox_lib:notify', src, {
                title = locale('tonic_cooldown_title'),
                description = locale('tonic_cooldown_description'),
                type = 'error',
                duration = 5000
            })
            return
        end
        lastTonicUseAt[src] = now

        Player.Functions.RemoveItem(itemName, 1)
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[itemName], 'remove', 1)
        TriggerClientEvent('rsg-herbalist:client:ApplyTonicEffect', src, itemName)
    end)
end

RegisterNetEvent('rsg-herbalist:server:requestCraft', function(tonicId)
    local src = source

    if not Config.TonicCraftingEnabled then return end

    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then Debug('craft: no player src=' .. src); return end

    if pendingCraft[src] then
        Debug('craft: already has a pending craft src=' .. src)
        -- Legitimate UI can't produce this (the client-side isCrafting flag
        -- blocks a second request while one is in flight), so this only
        -- happens from a directly-fired event - i.e. someone bypassing the
        -- NUI entirely.
        Webhook.FlagSuspicious(src, 'craft_double_request', 'requested tonicId=' .. tostring(tonicId) .. ' while another craft was pending')
        return
    end

    local now = GetGameTimer()
    if lastCraftAt[src] and (now - lastCraftAt[src]) < Config.TonicCraftCooldownMs then
        Debug('craft: cooldown src=' .. src)
        Webhook.FlagSuspicious(src, 'craft_cooldown', 'fired again ' .. (now - lastCraftAt[src]) .. 'ms after previous craft request')
        return
    end

    if not HasHerbalistJob(Player) then
        Debug('craft: job lock rejected src=' .. src)
        Webhook.FlagSuspicious(src, 'craft_job_lock', 'requested tonicId=' .. tostring(tonicId) .. ' without the required job')
        TriggerClientEvent('ox_lib:notify', src, {
            title = locale('craft_locked_title'),
            description = locale('craft_locked_description'),
            type = 'error',
            duration = 5000
        })
        return
    end

    local tonic = tonicsById[tonicId]
    if not tonic then
        Debug('craft: unknown tonic id=' .. tostring(tonicId))
        Webhook.FlagSuspicious(src, 'craft_unknown_tonic', 'tonicId=' .. tostring(tonicId))
        return
    end

    for _, ingredient in ipairs(tonic.ingredients) do
        if PlayerItemCount(Player, ingredient.item) < ingredient.amount then
            Debug('craft: missing ingredient=' .. ingredient.item .. ' src=' .. src)
            TriggerClientEvent('ox_lib:notify', src, {
                title = locale('craft_missing_title'),
                description = locale('craft_missing_description'),
                type = 'error',
                duration = 5000
            })
            return
        end
    end

    -- Reserve the cooldown/pending slots before touching inventory, same
    -- reasoning as the gather cooldown above: closes the window for a
    -- double-fired event to slip two crafts through at once.
    lastCraftAt[src] = now

    for _, ingredient in ipairs(tonic.ingredients) do
        Player.Functions.RemoveItem(ingredient.item, ingredient.amount)
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[ingredient.item], 'remove', ingredient.amount)
    end

    pendingCraft[src] = { id = tonicId, startedAt = now }
    TriggerClientEvent('rsg-herbalist:client:StartCraftProgress', src, tonicId, tonic.durationMs)
end)

RegisterNetEvent('rsg-herbalist:server:finishCraft', function()
    local src = source
    local pending = pendingCraft[src]
    pendingCraft[src] = nil
    if not pending then Debug('craft finish: nothing pending src=' .. src); return end

    local tonic = tonicsById[pending.id]
    if not tonic then return end

    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    local added = Player.Functions.AddItem(tonic.output.item, tonic.output.amount)
    if added then
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[tonic.output.item], 'add', tonic.output.amount)
        Webhook.LogCraft(src, tonic, 'success')
    else
        -- No room for the finished tonic - refund the ingredients that were
        -- consumed to make it rather than letting them vanish.
        for _, ingredient in ipairs(tonic.ingredients) do
            Player.Functions.AddItem(ingredient.item, ingredient.amount)
        end
        TriggerClientEvent('ox_lib:notify', src, {
            title = locale('inventory_full_title'),
            description = locale('inventory_full_description'),
            type = 'error',
            duration = 5000
        })
        Webhook.LogCraft(src, tonic, 'refunded')
    end
end)

RegisterNetEvent('rsg-herbalist:server:cancelCraft', function()
    local src = source
    local pending = pendingCraft[src]
    pendingCraft[src] = nil
    if not pending then return end

    local tonic = tonicsById[pending.id]
    if not tonic then return end

    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end

    for _, ingredient in ipairs(tonic.ingredients) do
        Player.Functions.AddItem(ingredient.item, ingredient.amount)
    end
end)

AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        Webhook.LogResourceEvent('started')
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        Webhook.LogResourceEvent('stopped')
    end
end)
