local ResourceName = GetCurrentResourceName()
local RSGCore = exports['rsg-core']:GetCoreObject()

lib.locale()

local function Debug(msg)
    if Config.Debug then
        Citizen.Trace('[rsg-herbalist] ' .. msg)
    end
end

-- Returns true once animDict is streamed in, or false if it never loads
-- within timeoutMs (e.g. bad dict name) so the caller can fall back to
-- something else instead of hanging.
local function RequestAnimDictWithTimeout(animDict, timeoutMs)
    if HasAnimDictLoaded(animDict) then return true end
    RequestAnimDict(animDict)
    local start = GetGameTimer()
    while not HasAnimDictLoaded(animDict) do
        if GetGameTimer() - start > timeoutMs then
            Debug('anim dict failed to stream in within timeout, dict=' .. animDict)
            return false
        end
        Wait(0)
    end
    return true
end

-- Creates propName and attaches it to the ped's boneName bone at the given
-- offset/rotation. Used to put a bottle prop in the player's hand for the
-- tonic-drinking animation, since the anim dict only poses the hand - it
-- doesn't render anything on its own.
local function AttachHandProp(ped, propName, boneName, offset, rotation)
    local hash = GetHashKey(propName)
    RequestModel(hash)
    local start = GetGameTimer()
    while not HasModelLoaded(hash) do
        if GetGameTimer() - start > 5000 then
            Debug('prop model failed to stream in within timeout, prop=' .. propName)
            return nil
        end
        Wait(0)
    end

    local coords = GetEntityCoords(ped)
    local prop = CreateObject(hash, coords.x, coords.y, coords.z, true, false, false)
    AttachEntityToEntity(
        prop, ped, GetEntityBoneIndexByName(ped, boneName),
        offset.x or 0.0, offset.y or 0.0, offset.z or 0.0,
        rotation.x or 0.0, rotation.y or 0.0, rotation.z or 0.0,
        true, true, false, true, 1, true
    )
    SetModelAsNoLongerNeeded(hash)
    return prop
end

-- Safely detaches and deletes a prop created by AttachHandProp.
local function DeleteHandProp(prop)
    if prop and DoesEntityExist(prop) then
        DetachEntity(prop, true, true)
        DeleteEntity(prop)
    end
end

-- Plays a single clip once and blocks until it's actually finished, rather
-- than a fixed Wait(ms) - the caller (PlayAnimClipsInOrder) uses this to
-- chain clips back to back with no gap and no guessed timer.
local function PlayAnimClipAndWait(ped, animDict, clip)
    TaskPlayAnim(ped, animDict, clip, 8.0, -8.0, -1, 0, 0, false, false, false)
    -- Give the task a moment to actually start before polling its progress -
    -- checking immediately can read the tail end of whatever animation was
    -- playing before this one.
    Wait(50)
    while DoesEntityExist(ped) and IsEntityPlayingAnim(ped, animDict, clip, 3) and GetEntityAnimCurrentTime(ped, animDict, clip) < 0.98 do
        Wait(0)
    end
end

-- Plays each clip in order, waiting for each to finish before starting the
-- next, then clears the ped's tasks once the last one ends.
local function PlayAnimClipsInOrder(ped, animDict, clips)
    for _, clip in ipairs(clips) do
        PlayAnimClipAndWait(ped, animDict, clip)
    end
    ClearPedTasks(ped)
end

-- Creates and activates a scripted camera positioned out in front of the
-- ped's current position/heading and pointed back at them, so the player
-- sees their own character face-on for the duration of the crafting
-- animation instead of the normal follow cam. Returns the cam handle (or
-- nil if disabled) so the caller can tear it down again afterwards.
local function CreateCraftingCam(ped, camConfig)
    if not camConfig or not camConfig.enabled then return nil end

    local pedCoords = GetEntityCoords(ped)
    local forward = GetEntityForwardVector(ped)
    local camCoords = vector3(
        pedCoords.x + forward.x * camConfig.distance,
        pedCoords.y + forward.y * camConfig.distance,
        pedCoords.z + (camConfig.height or 0.55)
    )

    local cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    SetCamCoord(cam, camCoords.x, camCoords.y, camCoords.z)
    PointCamAtEntity(cam, ped, 0.0, 0.0, 0.0, true)
    SetCamFov(cam, camConfig.fov or 40.0)
    SetCamActive(cam, true)
    RenderScriptCams(true, true, camConfig.transitionMs or 500, true, true)

    return cam
end

local function DestroyCraftingCam(cam, camConfig)
    if not cam then return end
    RenderScriptCams(false, true, camConfig and camConfig.transitionMs or 500, true, true)
    if DoesCamExist(cam) then
        DestroyCam(cam, false)
    end
end

local spawnEntries = {}
local spawnByCoordKey = {}
local suppressed = {}
local SCOPE_RANGE_LOAD = Config.ScopeRangeLoad
local SCOPE_RANGE_UNLOAD = Config.ScopeRangeUnload
local PICKUP_RANGE = Config.PickupRange
local COMPOSITE_LOAD_TIMEOUT_MS = Config.CompositeLoadTimeoutMs
local NEARBY_RANGE = Config.NearbyRange

local function CoordKey(coord)
    return string.format("%.1f_%.1f_%.1f", coord.x, coord.y, coord.z)
end

local function BuildSpawnEntries()
    local id = 0
    local zoneCount = 0
    for zoneId, zone in pairs(Config.Zones) do
        zoneCount = zoneCount + 1
        local plants = zone.plants
        for ci, coord in ipairs(zone.coords) do
            id = id + 1
            local plant = plants[((ci - 1) % #plants) + 1]
            local key = CoordKey(coord)
            local entry = { id = id, plant = plant, coord = coord, vec = vec3(coord.x, coord.y, coord.z), entity = nil, loading = false, zone = zoneId, coordKey = key }
            spawnEntries[id] = entry
            spawnByCoordKey[key] = entry
        end
    end
    Debug('Built ' .. id .. ' spawn entries from ' .. zoneCount .. ' zones\n')
end

-- Returns true once the composite asset is streamed in, or false if it
-- never loads within the timeout (e.g. bad/missing model name) so callers
-- can bail out instead of spinning this thread forever.
local function RequestAndWaitForComposite(compositeHash)
    if Citizen.InvokeNative(0x5E5D96BE25E9DF68, compositeHash) then return true end
    Citizen.InvokeNative(0x73F0D0327BFA0812, compositeHash)
    local start = GetGameTimer()
    while not Citizen.InvokeNative(0x5E5D96BE25E9DF68, compositeHash) do
        if GetGameTimer() - start > COMPOSITE_LOAD_TIMEOUT_MS then
            Debug('composite failed to stream in within timeout, hash=' .. tostring(compositeHash))
            return false
        end
        Wait(0)
    end
    return true
end

local function NativeDeleteComposite(composite)
    Citizen.InvokeNative(0x5758B1EE0C3FD4AC, composite, 0)
end

local function NativeDisplayCompositePickuptThisFrame(composite, display)
    Citizen.InvokeNative(0x40D72189F46D2E15, composite, display)
end

-- Streaming a composite can block for up to COMPOSITE_LOAD_TIMEOUT_MS (10s
-- by default) if the model name is bad or the asset is slow to load. This
-- used to run inline in the scope-loading loop below, which meant a single
-- stuck entry could stall that loop - and with it, every other node's
-- load/unload and the nearbyEntries refresh - for the entire timeout
-- window. Loading now happens in its own thread per entry so a slow/failed
-- stream only delays that one node.
local function LoadEntry(entry)
    if entry.entity or entry.loading then return end
    entry.loading = true
    local hash = GetHashKey(entry.plant)
    CreateThread(function()
        if RequestAndWaitForComposite(hash) then
            -- Re-check after the (possibly long) wait: the entry may have
            -- been suppressed or already loaded by another call while we
            -- were streaming.
            if not entry.entity and not suppressed[entry.id] then
                local c = entry.coord
                local composite = exports[ResourceName]:NativeCreateComposite(hash, c.x, c.y, c.z, false)
                -- NativeCreateComposite can return 0 on failure. 0 is truthy
                -- in Lua, so without this check a failed creation would be
                -- treated as a live entity: NativeDeleteComposite/
                -- NativeDisplayCompositePickuptThisFrame would silently
                -- no-op on handle 0, and the node would never be retried
                -- until it happened to stream out and back in again.
                if composite and composite ~= 0 then
                    entry.entity = composite
                else
                    Debug('composite creation returned invalid handle, plant=' .. tostring(entry.plant))
                end
            end
        end
        entry.loading = false
    end)
end

local function UnloadEntry(entry)
    if entry.entity then
        NativeDeleteComposite(entry.entity)
        entry.entity = nil
    end
end

local function IsSuppressed(id)
    return suppressed[id] or false
end

-- newPlant is authoritative from the server (which plant a regrown node
-- becomes). We no longer pick it locally: every client rendering the same
-- coordKey needs to agree on what's actually there.
local function SetSuppressed(coordKey, suppress, newPlant)
    local entry = spawnByCoordKey[coordKey]
    if not entry then return end
    if suppress then
        UnloadEntry(entry)
        suppressed[entry.id] = true
    else
        suppressed[entry.id] = nil
        if newPlant then
            entry.plant = newPlant
        end
        UnloadEntry(entry)
        LoadEntry(entry)
    end
end

-- Entries within NEARBY_RANGE of the player, refreshed once per second by
-- the scope-loading loop below. NEARBY_RANGE must comfortably exceed the
-- pickup-interaction range (3.0) plus however far a player can travel in
-- the ~1s between refreshes, so the per-frame loop never misses an entry
-- that walked/rode into interaction range between scans.
local nearbyEntries = {}

CreateThread(function()
    BuildSpawnEntries()
    while true do
        Wait(1000)
        local playerPos = GetEntityCoords(PlayerPedId())
        local newNearby = {}
        for id = 1, #spawnEntries do
            if not IsSuppressed(id) then
                local entry = spawnEntries[id]
                local dist = #(playerPos - entry.vec)
                if not entry.entity then
                    if dist <= SCOPE_RANGE_LOAD then
                        LoadEntry(entry)
                    end
                else
                    if dist >= SCOPE_RANGE_UNLOAD then
                        UnloadEntry(entry)
                    end
                end
                if entry.entity and dist <= NEARBY_RANGE then
                    newNearby[#newNearby + 1] = entry
                end
            end
        end
        nearbyEntries = newNearby
    end
end)

local function UnloadAll()
    for i = 1, #spawnEntries do
        UnloadEntry(spawnEntries[i])
    end
end

RegisterNetEvent('rsg-herbalist:client:SetSuppressed', function(coordKey, suppress, newPlant)
    SetSuppressed(coordKey, suppress, newPlant)
end)

RegisterNetEvent('rsg-herbalist:client:SetAllSuppressed', function(ps, plantOverrides)
    suppressed = {}
    for coordKey in pairs(ps) do
        local entry = spawnByCoordKey[coordKey]
        if entry then
            suppressed[entry.id] = true
        end
    end
    if plantOverrides then
        for coordKey, plant in pairs(plantOverrides) do
            local entry = spawnByCoordKey[coordKey]
            if entry then
                entry.plant = plant
            end
        end
    end
end)

RegisterNetEvent("rsg-herbalist:client:ForceReload", function(coordKey)
    local entry = spawnByCoordKey[coordKey]
    if entry and entry.entity then
        UnloadEntry(entry)
        LoadEntry(entry)
    end
end)

local isGathering = false

-- Purely local logic (never triggered remotely), so this is a plain
-- function rather than a RegisterNetEvent handler - it doesn't need to be
-- reachable over the network, and keeping it local avoids exposing an
-- event name a compromised/rogue server resource could invoke to spam
-- gather attempts on every client.
local function TryGather()
    if isGathering then return end
    isGathering = true

    local ped = PlayerPedId()
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_GATHER_HERBS', 0, true)
    local completed = lib.progressCircle({
        duration = Config.GatherDurationMs,
        label = locale('gathering_herb'),
        position = 'bottom',
        useWhileDead = false,
        canCancel = true,
        disable = { car = true, move = true, combat = true },
    })
    ClearPedTasks(ped)
    if not completed then isGathering = false; return end

    -- Only consider entries actually within pickup range. This used to check
    -- against SCOPE_RANGE_LOAD (100m, the streaming radius) instead of the
    -- interaction range, and scanned every spawn entry in the game instead
    -- of just the nearby ones - functionally masked most of the time since
    -- the truly closest node was almost always the right one, but wrong in
    -- intent and wasteful given there can be thousands of entries.
    local closestEntry, closestDist
    local playerPos = GetEntityCoords(ped)
    for i = 1, #nearbyEntries do
        local entry = nearbyEntries[i]
        if entry.entity and not IsSuppressed(entry.id) then
            local dist = #(playerPos - entry.vec)
            if dist <= PICKUP_RANGE then
                if not closestDist or dist < closestDist then
                    closestDist = dist
                    closestEntry = entry
                end
            end
        end
    end
    if not closestEntry then
        Debug('No herb found within range\n')
        isGathering = false
        return
    end
    local stripped = closestEntry.plant:gsub("COMPOSITE_LOOTABLE_", ""):gsub("_INTERACTABLE", "")
    TriggerServerEvent('rsg-herbalist:server:gathered', stripped, closestEntry.coordKey)
    isGathering = false
end

-- IsPickupControlPressed (and the PICKUP_CONTROL_HASHES it checks) now
-- lives in shared/controls.lua, loaded before this file - see that file for
-- why it's shared instead of duplicated per interaction system.

CreateThread(function()
    while true do
        Wait(0)
        local ped = PlayerPedId()
        local playerPos = GetEntityCoords(ped)
        local keyPressed = not isGathering and IsPickupControlPressed()
        local triggered = false
        for i = 1, #nearbyEntries do
            local entry = nearbyEntries[i]
            -- entry can be nil here: TryGather() below yields for the whole
            -- gather animation/progress bar, and while it's suspended the
            -- separate 1s refresh thread (see the CreateThread above with
            -- nearbyEntries = newNearby) can swap nearbyEntries out for a
            -- new, possibly shorter table. When this loop resumes it's
            -- still iterating up to the OLD #nearbyEntries but indexing
            -- into the NEW table, so higher indices can come back nil.
            if entry and entry.entity and not IsSuppressed(entry.id) then
                local dist = #(playerPos - entry.vec)
                if dist <= PICKUP_RANGE then
                    NativeDisplayCompositePickuptThisFrame(entry.entity, true)
                    if keyPressed and not triggered then
                        triggered = true
                        TryGather()
                        break
                    end
                end
            end
        end
    end
end)

----------------------------------------------------------------------------
-- Tonic crafting UI
--
-- The NUI menu is purely presentational - it shows recipes, how many of
-- each ingredient the player is currently carrying, and how long a craft
-- will take, but it never grants anything itself. Every craft still goes
-- through the server (rsg-herbalist:server:requestCraft), which is the only
-- place ingredients are actually checked and removed and the output item
-- is actually granted. A player editing the NUI/JS can at most spam craft
-- requests the server will just reject.
----------------------------------------------------------------------------

local playerData = RSGCore.Functions.GetPlayerData()

RegisterNetEvent('RSGCore:Player:SetPlayerData', function(data)
    playerData = data
end)

local function CountItem(itemName)
    local items = playerData and playerData.items
    if not items then return 0 end
    local total = 0
    for _, item in pairs(items) do
        if item and item.name == itemName then
            total = total + (item.amount or 0)
        end
    end
    return total
end

local function HasHerbalistJobLocal()
    if not Config.LockTonicCraftingToJob then return true end
    local job = playerData and playerData.job
    return job and job.name == Config.TonicCraftingJobName
end

local craftMenuOpen = false
local isCrafting = false

local function BuildTonicPayload()
    local list = {}
    for i, tonic in ipairs(Config.Tonics) do
        local ingredients = {}
        for _, ingredient in ipairs(tonic.ingredients) do
            local itemDef = RSGCore.Shared.Items[ingredient.item]
            ingredients[#ingredients + 1] = {
                item = ingredient.item,
                label = itemDef and itemDef.label or ingredient.item,
                image = itemDef and itemDef.image or (ingredient.item .. '.png'),
                required = ingredient.amount,
                have = CountItem(ingredient.item),
            }
        end
        local outputDef = RSGCore.Shared.Items[tonic.output.item]
        list[i] = {
            id = tonic.id,
            label = tonic.label,
            description = tonic.description,
            image = tonic.image or (outputDef and outputDef.image) or (tonic.output.item .. '.png'),
            durationMs = tonic.durationMs,
            outputAmount = tonic.output.amount,
            ingredients = ingredients,
        }
    end
    return list
end

local function CloseTonicMenu()
    if not craftMenuOpen then return end
    craftMenuOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'close' })
end

local function OpenTonicMenu()
    if not Config.TonicCraftingEnabled then return end
    if craftMenuOpen or isCrafting then return end

    if not HasHerbalistJobLocal() then
        lib.notify({
            title = locale('craft_locked_title'),
            description = locale('craft_locked_description'),
            type = 'error',
        })
        return
    end

    craftMenuOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        tonics = BuildTonicPayload(),
    })
end

RegisterNUICallback('close', function(_, cb)
    CloseTonicMenu()
    cb({ ok = true })
end)

RegisterNUICallback('craftTonic', function(data, cb)
    if isCrafting then cb({ ok = false }); return end
    CloseTonicMenu()
    TriggerServerEvent('rsg-herbalist:server:requestCraft', data.id)
    cb({ ok = true })
end)

RegisterNetEvent('rsg-herbalist:client:StartCraftProgress', function(tonicId, durationMs)
    if isCrafting then return end
    isCrafting = true

    local ped = PlayerPedId()
    local anim = Config.TonicCraftAnim
    local camConfig = Config.TonicCraftCamera
    local usingAnim = false

    -- Framed on the ped for the whole crafting animation (destroyed by
    -- whichever branch below actually clears the ped's tasks).
    local craftCam = CreateCraftingCam(ped, camConfig)

    -- Prefer the enter/exit herbalist animation sequence; if it's disabled
    -- via config, or the dict fails to stream in for whatever reason (bad
    -- name, asset missing), fall back to a generic scenario rather than
    -- leaving the player standing there with no crafting feedback at all.
    -- The sequence runs in its own thread so each clip plays through to its
    -- own natural end (no fixed timer) independently of the progress bar
    -- below, and clears the ped's tasks (and the camera) itself the moment
    -- the last clip finishes.
    if anim and anim.enabled and anim.clips and #anim.clips > 0 and RequestAnimDictWithTimeout(anim.dict, anim.animDictLoadTimeoutMs or 5000) then
        usingAnim = true
        CreateThread(function()
            PlayAnimClipsInOrder(ped, anim.dict, anim.clips)
            RemoveAnimDict(anim.dict)
            DestroyCraftingCam(craftCam, camConfig)
        end)
    else
        TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_STAND_IMPATIENT', 0, true)
    end

    local completed
    if Config.TonicCraftProgressBarEnabled then
        completed = lib.progressCircle({
            duration = durationMs,
            label = locale('crafting_tonic'),
            position = 'bottom',
            useWhileDead = false,
            canCancel = true,
            disable = { car = true, move = true, combat = true },
        })
    else
        -- No bar shown - just let the recipe's duration pass. Not
        -- cancellable this way; the craft always completes once the time's up.
        Wait(durationMs)
        completed = true
    end

    if not usingAnim then
        ClearPedTasks(ped)
        DestroyCraftingCam(craftCam, camConfig)
    end
    isCrafting = false

    if completed then
        TriggerServerEvent('rsg-herbalist:server:finishCraft')
    else
        TriggerServerEvent('rsg-herbalist:server:cancelCraft')
    end
end)

-- Fired by the server after it's confirmed (via HasHerbalistJob, mirroring
-- OpenTonicMenu's own local check) that this player is allowed to craft, in
-- response to the mortarpestle useable item being used. This is the only
-- way the menu opens - there's no command and no export, so using the item
-- is the sole entry point. We still don't trust this event alone for
-- anything security-sensitive - it just opens the same menu the item does,
-- and every craft request is independently re-validated server-side.
RegisterNetEvent('rsg-herbalist:client:OpenTonicCrafting', function()
    OpenTonicMenu()
end)

-- Fired by the server (from the per-tonic CreateUseableItem handlers) when
-- a tonic with an entry in Config.TonicEffects is consumed. Applies the
-- health/stamina boost via ENABLE_ATTRIBUTE_OVERPOWER (0xF6A7C08DF2E28B28) -
-- the same native the game's own tonics use, which tops the core up with a
-- golden "overpower" segment that then drains down naturally rather than
-- instantly refilling it.
RegisterNetEvent('rsg-herbalist:client:ApplyTonicEffect', function(itemName)
    local effect = Config.TonicEffects and Config.TonicEffects[itemName]
    if not effect then return end

    local ped = PlayerPedId()
    local attr = Config.TonicAttributeIndex or {}

    -- Play the drinking animation (ported from rsg-consume) before applying
    -- the effect, so the player visibly drinks the tonic. Skipped while
    -- mounted/in a vehicle, or if the anim dict never streams in - the
    -- effect always still applies either way.
    local drinkAnim = Config.TonicDrinkAnim
    if drinkAnim and drinkAnim.enabled and drinkAnim.clips and #drinkAnim.clips > 0
        and not IsPedOnMount(ped) and not IsPedInAnyVehicle(ped)
        and RequestAnimDictWithTimeout(drinkAnim.dict, drinkAnim.animDictLoadTimeoutMs or 5000) then
        local prop
        if drinkAnim.prop then
            prop = AttachHandProp(ped, drinkAnim.prop, drinkAnim.propBone or 'PH_R_HAND',
                drinkAnim.propOffset or {}, drinkAnim.propRotation or {})
        end
        for _, clip in ipairs(drinkAnim.clips) do
            TaskPlayAnim(ped, drinkAnim.dict, clip.anim, 8.0, -8.0, clip.duration or -1, 31, 0, false, false, false)
            Wait(clip.duration or 500)
        end
        ClearPedTasks(ped)
        RemoveAnimDict(drinkAnim.dict)
        DeleteHandProp(prop)
    end

    if effect.healthBoost and attr.health then
        Citizen.InvokeNative(0xF6A7C08DF2E28B28, ped, attr.health, effect.healthBoost, true)
    end
    if effect.staminaBoost and attr.stamina then
        Citizen.InvokeNative(0xF6A7C08DF2E28B28, ped, attr.stamina, effect.staminaBoost, true)
    end
end)

-- Single onResourceStop handler covering both cleanup concerns (previously
-- two separate handlers registered at different points in the file).
AddEventHandler("onResourceStop", function(resourceName)
    if GetCurrentResourceName() == resourceName then
        UnloadAll()
        CloseTonicMenu()
    end
end)
