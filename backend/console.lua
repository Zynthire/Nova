--[[
    Owner Commands
    Any whitelisted owner can type commands in chat.
    Anyone else in the server who is running this script and matches <name> is affected.

    Commands (type ;cmds to print this list in the F9 console):
      ;kick  <name> [reason]   kick them from the server
      ;kill  <name>            kill their character
      ;fly   <name>            let them fly (WASD + Space/Ctrl)
      ;unfly <name>            stop flying
      ;dog   <name>            make them play the dog animation
      ;undog <name>            stop the dog animation
      ;fling <name>            fling them across the map
      ;cmds                    print every command in the console (only you see it)

    Notes:
      * It only reaches people running this script, in the same server as you.
      * <name> can be a username, a display name, or the start of one (e.g. ";kill bob").
      * Owners can't use commands on each other.
      * Works with the new chat (TextChatService) and the old chat.
]]

-- ====== SETTINGS ======
local PREFIX = ";"

-- Usernames (any capitalisation)
local OWNER_NAMES = {
    "TrulyZynthire",
    "interactionstyle",
    "xIllIllIIl",
}

-- Optional, and safer: UserIds don't change when someone renames.
-- Example: local OWNER_IDS = { 123456789, 987654321 }
local OWNER_IDS = {}

local FLY_SPEED = 60          -- studs per second
local FLING_POWER = 800       -- how hard ;fling throws them
local DOG_ANIMATION_ID = "rbxassetid://100737291015384"

-- ====== STOP DOUBLE INJECTION ======
local env = (getgenv and getgenv()) or _G
for _, key in ipairs({ "OwnerCommands", "OwnerKick" }) do
    if env[key] and env[key].Unload then
        pcall(env[key].Unload) -- reinjecting cleans up the old copy first
    end
end

-- ====== SERVICES ======
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait()
    LocalPlayer = Players.LocalPlayer
end

local connections = {}

-- ====== OWNER CHECK ======
local ownerNameSet, ownerIdSet = {}, {}
for _, n in ipairs(OWNER_NAMES) do ownerNameSet[n:lower()] = true end
for _, id in ipairs(OWNER_IDS) do ownerIdSet[id] = true end

local function isOwner(player)
    if not player then return false end
    return ownerIdSet[player.UserId] == true or ownerNameSet[player.Name:lower()] == true
end

-- ====== FIND TARGET ======
-- Every client has the same player list, so they all pick the same person.
local function findTarget(query)
    query = query:lower()
    local players = Players:GetPlayers()

    -- 1) exact username
    for _, p in ipairs(players) do
        if p.Name:lower() == query then return p end
    end

    -- 2) exact display name (only if exactly one person has it)
    local found
    for _, p in ipairs(players) do
        if p.DisplayName:lower() == query then
            if found then return nil end
            found = p
        end
    end
    if found then return found end

    -- 3) start of username / display name (only if it matches exactly one person)
    for _, p in ipairs(players) do
        local n, d = p.Name:lower(), p.DisplayName:lower()
        if n:sub(1, #query) == query or d:sub(1, #query) == query then
            if found then return nil end
            found = p
        end
    end
    return found
end

-- ====== CHARACTER HELPER ======
-- Returns character, humanoid, root part (or nothing if dead / not spawned).
local function getCharacter()
    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    if not hum or not root or hum.Health <= 0 then return end
    return char, hum, root
end

-- ====== FLY ======
local fly = { connection = nil, velocity = nil, gyro = nil }

local function stopFly()
    if fly.connection then fly.connection:Disconnect() end
    if fly.velocity then fly.velocity:Destroy() end
    if fly.gyro then fly.gyro:Destroy() end
    fly.connection, fly.velocity, fly.gyro = nil, nil, nil

    local _, hum = getCharacter()
    if hum then hum.PlatformStand = false end
end

local function startFly()
    stopFly()
    local _, hum, root = getCharacter()
    if not hum then return end

    local velocity = Instance.new("BodyVelocity")
    velocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
    velocity.Velocity = Vector3.new(0, 0, 0)
    velocity.Parent = root

    local gyro = Instance.new("BodyGyro")
    gyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
    gyro.P = 9e4
    gyro.CFrame = root.CFrame
    gyro.Parent = root

    fly.velocity, fly.gyro = velocity, gyro
    hum.PlatformStand = true

    fly.connection = RunService.RenderStepped:Connect(function()
        if not velocity.Parent or hum.Health <= 0 then
            stopFly()
            return
        end

        local cam = workspace.CurrentCamera
        local look, right = cam.CFrame.LookVector, cam.CFrame.RightVector

        -- Keyboard controls
        local forward, side, up = 0, 0, 0
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then forward = forward + 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then forward = forward - 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then side = side + 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then side = side - 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then up = up + 1 end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then up = up - 1 end

        local direction = look * forward + right * side + Vector3.new(0, up, 0)

        -- Mobile / controller fallback: use the thumbstick direction
        if direction.Magnitude == 0 and hum.MoveDirection.Magnitude > 0 then
            direction = hum.MoveDirection
        end

        if direction.Magnitude > 0 then
            velocity.Velocity = direction.Unit * FLY_SPEED
        else
            velocity.Velocity = Vector3.new(0, 0, 0)
        end
        gyro.CFrame = cam.CFrame
    end)
end

-- ====== DOG ANIMATION ======
local dog = { track = nil, token = 0 }
local resolvedDogId = nil -- cached once we find an ID that actually loads

local function stopDog()
    dog.token = dog.token + 1 -- cancels a ;dog that's still loading
    if dog.track then
        pcall(function()
            dog.track:Stop()
            dog.track:Destroy()
        end)
        dog.track = nil
    end
end

-- If the ID is a catalog emote (not a raw animation), the real animation
-- is stored inside it. game:GetObjects lets us pull it out.
local function resolveAnimationId(id)
    local ok, objects = pcall(function()
        return game:GetObjects(id)
    end)
    if not ok or type(objects) ~= "table" then return nil end

    for _, obj in ipairs(objects) do
        if obj:IsA("Animation") then return obj.AnimationId end
        local inner = obj:FindFirstChildWhichIsA("Animation", true)
        if inner then return inner.AnimationId end
    end
    return nil
end

-- Loads a track and waits to see if Roblox actually accepted it.
-- A rejected animation still "loads", but its Length stays 0.
local function loadTrack(hum, id)
    local animation = Instance.new("Animation")
    animation.AnimationId = id

    local loader = hum:FindFirstChildOfClass("Animator") or hum
    local ok, track = pcall(function()
        return loader:LoadAnimation(animation)
    end)
    if not ok or not track then return nil end

    local waited = 0
    while track.Length == 0 and waited < 5 do
        waited = waited + task.wait(0.1)
    end
    if track.Length == 0 then
        track:Destroy()
        return nil
    end
    return track
end

local function startDog()
    stopDog()
    local _, hum = getCharacter()
    if not hum then return end

    local myToken = dog.token

    task.spawn(function()
        -- 1) try the ID as-is (or the one that worked last time)
        local track = loadTrack(hum, resolvedDogId or DOG_ANIMATION_ID)

        -- 2) if that failed, treat it as a catalog emote and dig out the real ID
        if not track and not resolvedDogId then
            local innerId = resolveAnimationId(DOG_ANIMATION_ID)
            if innerId and innerId ~= DOG_ANIMATION_ID then
                track = loadTrack(hum, innerId)
                if track then resolvedDogId = innerId end
            end
        elseif track and not resolvedDogId then
            resolvedDogId = DOG_ANIMATION_ID
        end

        if not track then
            warn("[OwnerCommands] ;dog failed: Roblox wouldn't load " .. DOG_ANIMATION_ID ..
                ". If it's an animation someone uploaded, it only plays in games they own." ..
                " Use a catalog emote's ID instead.")
            return
        end

        -- ;undog / respawn happened while we were loading
        if dog.token ~= myToken or not hum.Parent or hum.Health <= 0 then
            track:Destroy()
            return
        end

        track.Priority = Enum.AnimationPriority.Action4
        track.Looped = true
        track:Play()
        dog.track = track
        print("[OwnerCommands] ;dog playing (" .. tostring(hum.RigType) .. " rig)")
    end)
end

-- ====== KILL ======
local function doKill()
    stopFly()
    stopDog()
    local _, hum = getCharacter()
    if not hum then return end
    hum.Health = 0
    hum:ChangeState(Enum.HumanoidStateType.Dead)
end

-- ====== FLING ======
local function doFling()
    stopFly()
    local _, hum, root = getCharacter()
    if not hum then return end

    hum.PlatformStand = true

    -- random sideways direction, plus some upward lift
    local dir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5)
    if dir.Magnitude == 0 then dir = Vector3.new(1, 0, 0) end
    dir = dir.Unit

    root.AssemblyLinearVelocity = dir * FLING_POWER + Vector3.new(0, FLING_POWER * 0.6, 0)
    root.AssemblyAngularVelocity = Vector3.new(
        math.random(-50, 50),
        math.random(-50, 50),
        math.random(-50, 50)
    )

    task.delay(2, function()
        if hum.Parent and not fly.connection then
            hum.PlatformStand = false
        end
    end)
end

-- ====== COMMAND LIST ======
-- Each command runs only on the targeted player's client.
local COMMANDS = {
    {
        name = "kick",
        usage = "kick <name> [reason]",
        desc = "Kicks them from the server (reason is optional)",
        run = function(speaker, reason)
            if reason == "" then
                reason = "You were kicked by " .. speaker.Name
            else
                reason = "Kicked by " .. speaker.Name .. ": " .. reason
            end
            LocalPlayer:Kick(reason)
        end,
    },
    {
        name = "kill",
        usage = "kill <name>",
        desc = "Kills their character",
        run = doKill,
    },
    {
        name = "fly",
        usage = "fly <name>",
        desc = "Lets them fly (WASD to move, Space up, Ctrl down)",
        run = startFly,
    },
    {
        name = "unfly",
        usage = "unfly <name>",
        desc = "Stops them flying",
        run = stopFly,
    },
    {
        name = "dog",
        usage = "dog <name>",
        desc = "Makes them play the dog animation on loop",
        run = startDog,
    },
    {
        name = "undog",
        usage = "undog <name>",
        desc = "Stops the dog animation",
        run = stopDog,
    },
    {
        name = "fling",
        usage = "fling <name>",
        desc = "Flings them across the map",
        run = doFling,
    },
}

local commandByName = {}
for _, c in ipairs(COMMANDS) do commandByName[c.name] = c end

local function printCommands()
    print("========== Owner Commands ==========")
    for _, c in ipairs(COMMANDS) do
        print(PREFIX .. c.usage .. "  -  " .. c.desc)
    end
    print(PREFIX .. "cmds  -  Prints this list (only you see it)")
    print("<name> = username, display name, or the start of one")
    print("====================================")
end

-- ====== COMMAND HANDLER ======
local function onChat(speaker, text)
    if not isOwner(speaker) or type(text) ~= "string" then return end

    text = text:gsub("^%s+", "")
    if text:sub(1, #PREFIX) ~= PREFIX then return end

    local cmdName, rest = text:sub(#PREFIX + 1):match("^(%S+)%s*(.*)$")
    if not cmdName then return end
    cmdName = cmdName:lower()

    -- ;cmds only prints on the owner's own console
    if cmdName == "cmds" then
        if speaker == LocalPlayer then printCommands() end
        return
    end

    local command = commandByName[cmdName]
    if not command then return end

    local query, extra = rest:match("^(%S+)%s*(.*)$")
    if not query then return end

    if isOwner(LocalPlayer) then return end -- owners are immune
    if findTarget(query) ~= LocalPlayer then return end

    local ok, err = pcall(command.run, speaker, extra)
    if not ok then
        warn("[OwnerCommands] ;" .. cmdName .. " failed: " .. tostring(err))
    end
end

-- ====== CHAT HOOKS ======
-- Only hook ONE chat system, otherwise games on the new chat
-- fire both events and every command runs twice.
if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    -- New chat
    table.insert(connections, TextChatService.MessageReceived:Connect(function(message)
        local source = message.TextSource
        if not source then return end -- system messages
        onChat(Players:GetPlayerByUserId(source.UserId), message.Text)
    end))
else
    -- Old chat
    local function hookPlayer(player)
        if not isOwner(player) then return end -- only listen to owners
        table.insert(connections, player.Chatted:Connect(function(text)
            onChat(player, text)
        end))
    end

    for _, p in ipairs(Players:GetPlayers()) do hookPlayer(p) end
    table.insert(connections, Players.PlayerAdded:Connect(hookPlayer))
end

-- Reset fly / dog when the character respawns
table.insert(connections, LocalPlayer.CharacterAdded:Connect(function()
    stopFly()
    dog.track = nil
end))

-- ====== CLEANUP ======
env.OwnerCommands = {
    Unload = function()
        stopFly()
        stopDog()
        for _, c in ipairs(connections) do
            pcall(function() c:Disconnect() end)
        end
        table.clear(connections)
        env.OwnerCommands = nil
    end,
}
