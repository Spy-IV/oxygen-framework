-- in-memory spawnpoint array for this script execution instance
local spawnPoints = {}

-- auto-spawn enabled flag
local autoSpawnEnabled = false
local autoSpawnCallback

local spawnSkin

-- support for mapmanager maps
AddEventHandler('getMapDirectives', function(add)
    -- call the remote callback
    add('spawnpoint', function(state, model)
        -- return another callback to pass coordinates and so on (as such syntax would be [spawnpoint 'model' { options/coords }])
        return function(opts)
            local x, y, z, heading

            local s, e = pcall(function()
                -- is this a map or an array?
                if opts.x then
                    x = opts.x
                    y = opts.y
                    z = opts.z
                else
                    x = opts[1]
                    y = opts[2]
                    z = opts[3]
                end

                x = x + 0.0001
                y = y + 0.0001
                z = z + 0.0001

                -- get a heading and force it to a float, or just default to null
                heading = opts.heading and (opts.heading + 0.01) or 0

                -- add the spawnpoint
                addSpawnPoint({
                    x = x, y = y, z = z,
                    heading = heading,
                    model = model
                })

                -- recalculate the model for storage
                if not tonumber(model) then
                    model = GetHashKey(model)
                end

                -- store the spawn data in the state so we can erase it later on
                state.add('xyz', { x, y, z })
                state.add('model', model)
            end)

            if not s then
                Citizen.Trace(e .. "\n")
            end
        end
        -- delete callback follows on the next line
    end, function(state, arg)
        -- loop through all spawn points to find one with our state
        for i, sp in ipairs(spawnPoints) do
            -- if it matches...
            if sp.x == state.xyz[1] and sp.y == state.xyz[2] and sp.z == state.xyz[3] and sp.model == state.model then
                -- remove it.
                table.remove(spawnPoints, i)
                return
            end
        end
    end)
end)

-- loads a set of spawn points from a JSON string
function loadSpawns(spawnString)
    -- decode the JSON string
    local data = json.decode(spawnString)

    -- do we have a 'spawns' field?
    if not data.spawns then
        error("no 'spawns' in JSON data")
    end

    -- loop through the spawns
    for i, spawn in ipairs(data.spawns) do
        -- and add it to the list (validating as we go)
        addSpawnPoint(spawn)
    end
end

function addSpawnPoint(spawn)
    -- validate the spawn (position)
    if not tonumber(spawn.x) or not tonumber(spawn.y) or not tonumber(spawn.z) then
        error("invalid spawn position")
    end

    -- heading
    if not tonumber(spawn.heading) then
        error("invalid spawn heading")
    end

    -- model (try integer first, if not, hash it)
    local model = spawn.model

    if not tonumber(spawn.model) then
        model = GetHashKey(spawn.model)
    end

    -- is the model actually a model?
    if not IsModelInCdimage(model) then
        error("invalid spawn model")
    end

    -- is is even a ped?
    if not IsThisModelAPed(model) then
        error("this model ain't a ped!")
    end

    -- overwrite the model in case we hashed it
    spawn.model = model

    -- all OK, add the spawn entry to the list
    table.insert(spawnPoints, spawn)
end

-- changes the auto-spawn flag
function setAutoSpawn(enabled)
    autoSpawnEnabled = enabled
end

-- sets a callback to execute instead of 'native' spawning when trying to auto-spawn
function setAutoSpawnCallback(cb)
    autoSpawnCallback = cb
    autoSpawnEnabled = true
end

-- function as existing in original R* scripts
local function freezePlayer(id, freeze)
    local player = ConvertIntToPlayerindex(id)
    SetPlayerControlForNetwork(player, not freeze, false)

    local ped = GetPlayerChar(player)

    if not freeze then
        if not IsCharVisible(ped) then
            SetCharVisible(ped, true)
        end

        if not IsCharInAnyCar(ped) then
            SetCharCollision(ped, true)
        end

        FreezeCharPosition(ped, false)
        SetCharNeverTargetted(ped, false)
        SetPlayerInvincible(player, false)
    else
        if IsCharVisible(ped) then
            SetCharVisible(ped, false)
        end

        SetCharCollision(ped, false)
        FreezeCharPosition(ped, true)
        SetCharNeverTargetted(ped, true)
        SetPlayerInvincible(player, true)
        RemovePtfxFromPed(ped)

        if not IsCharFatallyInjured(ped) then
            ClearCharTasksImmediately(ped)
        end
    end
end

function loadScene(x, y, z)
    StartLoadScene(x, y, z)

    while not UpdateLoadScene() do
        networkTimer = GetNetworkTimer()

        exports.sessionmanager:serviceHostStuff()
    end
end

-- to prevent trying to spawn multiple times
local spawnLock = false

-- spawns the current player at a certain spawn point index (or a random one, for that matter)
function spawnPlayer(spawnIdx, cb)
    if spawnLock then
        return
    end

    spawnLock = true

    Citizen.CreateThread(function()
        if(not IsScreenFadedOut()) then
            DoScreenFadeOut(500)

            while IsScreenFadingOut() do
                Citizen.Wait(0)
            end
        end

        -- if the spawn isn't set, select a random one
        if not spawnIdx then
            spawnIdx = GenerateRandomIntInRange(1, #spawnPoints + 1)
        end

        -- get the spawn from the array
        local spawn

        if type(spawnIdx) == 'table' then
            spawn = spawnIdx
        else
            spawn = spawnPoints[spawnIdx]
        end

        -- validate the index
        if not spawn then
            Citizen.Trace("tried to spawn at an invalid spawn index\n")

            spawnLock = false

            return
        end

        -- freeze the local player
        freezePlayer(GetPlayerId(), true)

        if spawnSkin then
            spawn.model = spawnSkin
        end

        -- if the spawn has a model set
        if spawn.model then
            RequestModel(spawn.model)

            -- load the model for this spawn
            while not HasModelLoaded(spawn.model) do
                RequestModel(spawn.model)

                Wait(0)
            end

            -- change the player model
            ChangePlayerModel(GetPlayerId(), spawn.model)

            -- release the player model
            MarkModelAsNoLongerNeeded(spawn.model)
        end

        -- preload collisions for the spawnpoint
        RequestCollisionAtPosn(spawn.x, spawn.y, spawn.z)

        -- spawn the player
        ResurrectNetworkPlayer(GetPlayerId(), spawn.x, spawn.y, spawn.z, spawn.heading)

        -- gamelogic-style cleanup stuff
        local ped = GetPlayerChar(-1)

        ClearCharTasksImmediately(ped)
        SetCharHealth(ped, 300) -- TODO: allow configuration of this?
        RemoveAllCharWeapons(ped)
        ClearWantedLevel(GetPlayerId())

        -- why is this even a flag?
        SetCharWillFlyThroughWindscreen(ped, false)

        -- set primary camera heading
        --SetGameCamHeading(spawn.heading)
        CamRestoreJumpcut(GetGameCam())

        -- load the scene; streaming expects us to do it
        --ForceLoadingScreen(true)
        --loadScene(spawn.x, spawn.y, spawn.z)
        ForceLoadingScreen(false)

        DoScreenFadeIn(500)

        while IsScreenFadingIn() do
            Citizen.Wait(0)
        end

        -- and unfreeze the player
        freezePlayer(GetPlayerId(), false)

        TriggerEvent('playerSpawned', spawn)
        TriggerServerEvent('baseevents:printToServer', '[Spawn] ' .. GetPlayerName(GetPlayerId()) .. ' spawned.')

        if cb then
            cb(spawn)
        end

        spawnLock = false
    end)
end
-- automatic spawning monitor thread, too
local respawnForced
Citizen.CreateThread(function()
    -- main loop thing
    while true do
        Citizen.Wait(50)

        -- check if we want to autospawn
        if(exports.oxygen:GetRespawnStatus() == true) then
            if IsNetworkPlayerActive(GetPlayerId()) then
                if (HowLongHasNetworkPlayerBeenDeadFor(GetPlayerId()) > exports.oxygen:GetRespawnTimer()) or respawnForced then
                    if autoSpawnCallback then
                        autoSpawnCallback()
                    else
                        spawnPlayer()
                    end

                    respawnForced = false
                end
            end
        end
    end
end)

function forceRespawn()
    spawnLock = false
    respawnForced = true
end

function setSpawnSkin(model)
    spawnSkin = GetHashKey(model)
end


RegisterNetEvent("playerSpawned")
AddEventHandler("playerSpawned", function()
	Citizen.Trace("Oxygen v1.0 \n")
    Citizen.Trace("Oxygen v1.0 by Spy, Vlados and Lucid\n")
end)
