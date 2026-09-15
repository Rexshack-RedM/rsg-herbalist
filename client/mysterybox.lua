----------------------------------------------------------------------------
-- Herb mystery box
--
-- Purely presentational: renders whatever coord the server last told us the
-- box is at (via rsg-herbalist:client:SetMysteryBox), streams the prop in/out
-- as the player moves, and lets them try to open it in range. The server
-- alone decides where the box is and what's inside it - this file never
-- picks a location or grants an item itself.
----------------------------------------------------------------------------

local mb = Config.MysteryBox

Citizen.Trace('[rsg-herbalist:mysterybox] client script loaded, mb=' .. tostring(mb) .. ' enabled=' .. tostring(mb and mb.enabled) .. '\n')

local function Debug(msg)
    if Config.Debug then
        Citizen.Trace('[rsg-herbalist:mysterybox] ' .. msg .. '\n')
    end
end

if not mb or not mb.enabled then
    Citizen.Trace('[rsg-herbalist:mysterybox] disabled or missing config, stopping here\n')
    return
end

local PROP_HASH = GetHashKey(mb.prop)
local SCOPE_RANGE_LOAD = mb.scopeRangeLoad or 100.0
local SCOPE_RANGE_UNLOAD = mb.scopeRangeUnload or 120.0
local PICKUP_RANGE = mb.pickupRange or 3.0

local boxCoord = nil   -- vector3 or nil (no box currently spawned)
local boxEntity = nil
local boxLoading = false
local isOpening = false
local promptShown = false

local function ShowOpenPrompt()
    if promptShown then return end
    promptShown = true
    lib.showTextUI(locale('open_mysterybox_prompt'), { position = 'right-center' })
end

local function HideOpenPrompt()
    if not promptShown then return end
    promptShown = false
    lib.hideTextUI()
end

local function LoadBoxEntity()
    if boxEntity or boxLoading or not boxCoord then return end
    Debug('LoadBoxEntity: streaming model, hash=' .. tostring(PROP_HASH) .. ' coord=' .. tostring(boxCoord))
    boxLoading = true
    CreateThread(function()
        RequestModel(PROP_HASH)
        local start = GetGameTimer()
        while not HasModelLoaded(PROP_HASH) do
            if GetGameTimer() - start > 10000 then
                Debug('box prop failed to stream in within timeout, model=' .. tostring(mb.prop))
                boxLoading = false
                return
            end
            Wait(0)
        end
        Debug('LoadBoxEntity: model loaded')

        -- boxCoord may have changed (or gone nil) while we were streaming.
        if boxCoord and not boxEntity then
            local c = boxCoord
            boxEntity = CreateObject(PROP_HASH, c.x, c.y, c.z, false, false, false)
            if boxEntity and boxEntity ~= 0 then
                PlaceObjectOnGroundProperly(boxEntity)
                FreezeEntityPosition(boxEntity, true)
                Debug('LoadBoxEntity: object created, entity=' .. tostring(boxEntity))
            else
                Debug('LoadBoxEntity: CreateObject returned invalid entity')
                boxEntity = nil
            end
        else
            Debug('LoadBoxEntity: boxCoord changed/cleared while streaming, skipping create')
        end
        SetModelAsNoLongerNeeded(PROP_HASH)
        boxLoading = false
    end)
end

local function UnloadBoxEntity()
    if boxEntity and DoesEntityExist(boxEntity) then
        DeleteEntity(boxEntity)
    end
    boxEntity = nil
end

RegisterNetEvent('rsg-herbalist:client:SetMysteryBox', function(coord)
    Debug('SetMysteryBox received, coord=' .. tostring(coord))
    UnloadBoxEntity()
    boxCoord = coord
end)

-- Ask the server for the current box location as soon as we're ready to
-- receive it, rather than relying solely on the server's one-off broadcast
-- (RelocateBox() on server start) or the OnPlayerLoaded resync, neither of
-- which reliably reaches a client that's already connected when this
-- resource (re)starts.
CreateThread(function()
    TriggerServerEvent('rsg-herbalist:server:requestMysteryBox')
end)

local function TryOpenBox()
    if isOpening or not boxCoord then return end
    isOpening = true
    HideOpenPrompt()

    local ped = PlayerPedId()
    TaskStartScenarioInPlace(ped, 'WORLD_HUMAN_CROUCH_INSPECT', 0, true)
    local completed = lib.progressCircle({
        duration = Config.GatherDurationMs,
        label = locale('opening_mysterybox'),
        position = 'bottom',
        useWhileDead = false,
        canCancel = true,
        disable = { car = true, move = true, combat = true },
    })
    ClearPedTasks(ped)
    if not completed then isOpening = false; return end

    TriggerServerEvent('rsg-herbalist:server:openMysteryBox')
    isOpening = false
end

-- IsPickupControlPressed lives in shared/controls.lua (loaded before this
-- file) so it's not duplicated between this and client/client.lua.

local lastDistDebugAt = 0

CreateThread(function()
    while true do
        local sleep = 1000
        if boxCoord then
            local playerPos = GetEntityCoords(PlayerPedId())
            local dist = #(playerPos - boxCoord)

            if Config.Debug and (GetGameTimer() - lastDistDebugAt) > 5000 then
                lastDistDebugAt = GetGameTimer()
                Debug('dist to box=' .. tostring(dist) .. ' boxEntity=' .. tostring(boxEntity) .. ' playerPos=' .. tostring(playerPos))
            end

            if not boxEntity then
                if dist <= SCOPE_RANGE_LOAD then
                    LoadBoxEntity()
                end
            elseif dist >= SCOPE_RANGE_UNLOAD then
                UnloadBoxEntity()
            end

            if boxEntity and dist <= PICKUP_RANGE and not isOpening then
                sleep = 0
                ShowOpenPrompt()
                if IsPickupControlPressed() then
                    TryOpenBox()
                end
            else
                HideOpenPrompt()
                if boxEntity and dist <= SCOPE_RANGE_LOAD then
                    sleep = 250
                end
            end
        else
            HideOpenPrompt()
        end
        Wait(sleep)
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        UnloadBoxEntity()
        HideOpenPrompt()
    end
end)
