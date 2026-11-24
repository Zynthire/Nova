loadstring(game:HttpGet("https://raw.githubusercontent.com/Zynthire/Nova/main/backend/console.lua"))()
loadstring(game:HttpGet("https://raw.githubusercontent.com/Zynthire/Nova/main/backend/log.lua"))()

print("testing......")
local __nova = [====[

local NOVA_SOURCE = ...

local function NovaMain()

-- ====================== PRE-FLIGHT ======================
local env = getgenv()

-- Clean up any previous instance before building a new one
if type(env.Nova) == "table" and type(env.Nova.Unload) == "function" then
    pcall(env.Nova.Unload, true)
end
env.__NovaMain = NovaMain

-- ====================== SERVICES ======================
local function service(name)
    local svc = game:GetService(name)
    if cloneref then
        local ok, clone = pcall(cloneref, svc)
        if ok and clone then
            return clone
        end
    end
    return svc
end

local Players          = service("Players")
local RunService       = service("RunService")
local UserInputService = service("UserInputService")
local TweenService     = service("TweenService")
local Lighting         = service("Lighting")
local Workspace        = service("Workspace")
local CoreGui          = service("CoreGui")
local GuiService       = service("GuiService")
local VirtualInputManager = nil
pcall(function()
    VirtualInputManager = service("VirtualInputManager")
end)

local LocalPlayer = Players.LocalPlayer

local HAS_DRAWING = false
pcall(function()
    HAS_DRAWING = (Drawing ~= nil and Drawing.new ~= nil)
end)

-- ====================== MODULE: MAID ======================
local Maid = {}
Maid.__index = Maid

function Maid.new()
    return setmetatable({ Tasks = {} }, Maid)
end

function Maid:Give(item)
    self.Tasks[#self.Tasks + 1] = item
    return item
end

function Maid:Clean()
    local tasks = self.Tasks
    self.Tasks = {}
    for i = #tasks, 1, -1 do
        local item = tasks[i]
        pcall(function()
            local kind = typeof(item)
            if kind == "RBXScriptConnection" then
                item:Disconnect()
            elseif kind == "Instance" then
                item:Destroy()
            elseif kind == "function" then
                item()
            elseif kind == "thread" then
                task.cancel(item)
            else
                -- Drawing objects and misc userdata/tables. Visible = false goes first and in its
                -- own pcall: on some executors Remove() silently no-ops instead of erroring, which
                -- used to leave a stray Drawing frozen on screen with nothing telling us it failed.
                pcall(function()
                    item.Visible = false
                end)
                if item.Remove then
                    item:Remove()
                elseif item.Destroy then
                    item:Destroy()
                end
            end
        end)
    end
end

-- ====================== MODULE: UTIL ======================
local Util = {}

function Util.DeepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = Util.DeepCopy(v)
    end
    return copy
end

function Util.RandomName(length)
    local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
    local out = {}
    for i = 1, length or 14 do
        local n = math.random(1, #chars)
        out[i] = chars:sub(n, n)
    end
    return table.concat(out)
end

-- Returns character, humanoid, rootPart (all nil if the player isn't ready)
function Util.GetCharacter(plr)
    local char = plr and plr.Character
    if not char then
        return nil
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    if not hum or not root then
        return nil
    end
    return char, hum, root
end

function Util.IsTeammate(plr)
    if plr.Team ~= nil and LocalPlayer.Team ~= nil then
        return plr.Team == LocalPlayer.Team
    end
    return false
end

-- Held-tool check. `keywords` is a comma separated list; blank = any tool.
function Util.GetHeldTool(keywords)
    local char = LocalPlayer.Character
    if not char then
        return nil
    end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then
        return nil
    end
    if keywords and keywords:match("%S") then
        local name = tool.Name:lower()
        for word in keywords:gmatch("[^,]+") do
            word = word:lower():match("^%s*(.-)%s*$")
            if word ~= "" and name:find(word, 1, true) then
                return tool
            end
        end
        return nil
    end
    return tool
end

-- Name of whatever you are holding. Real Tools, or Bedwars-style held items (HandInvItem).
function Util.GetHeldName()
    local char = LocalPlayer.Character
    if not char then
        return nil
    end
    local tool = char:FindFirstChildOfClass("Tool")
    if tool then
        return tool.Name
    end
    local hand = char:FindFirstChild("HandInvItem")
    local item = hand and hand:IsA("ObjectValue") and hand.Value
    return item and item.Name or nil
end

-- Held-item check by name. `keywords` is a comma separated list; blank = holding anything.
function Util.MatchesHeld(keywords)
    local name = Util.GetHeldName()
    if not name then
        return false
    end
    if not (keywords and keywords:match("%S")) then
        return true
    end
    local lowered = name:lower()
    for word in keywords:gmatch("[^,]+") do
        word = word:lower():match("^%s*(.-)%s*$")
        if word ~= "" and lowered:find(word, 1, true) then
            return true
        end
    end
    return false
end

-- First person = the camera sits inside your head
function Util.IsFirstPerson()
    local cam = Workspace.CurrentCamera
    local char = LocalPlayer.Character
    local head = char and char:FindFirstChild("Head")
    if not cam or not head then
        return false
    end
    return (head.Position - cam.CFrame.Position).Magnitude < 2
end

-- Mouse state from real input events (IsMouseButtonPressed alone misses clicks in some games / camera modes)
Util.MouseState = { Left = false, Right = false, LeftAt = 0, RightAt = 0 }

function Util.IsMouseDown(right)
    local state = Util.MouseState
    if right and state.Right or (not right) and state.Left then
        return true
    end
    local ok, pressed = pcall(function()
        return UserInputService:IsMouseButtonPressed(right and Enum.UserInputType.MouseButton2 or Enum.UserInputType.MouseButton1)
    end)
    return ok and pressed == true
end

-- Shared "Require Mouse Down" + "Limit to Items" gate.
-- `gate` is a table the caller owns (stores the grace-window timestamp).
function Util.PassesGate(cfg, gate, grace)
    if cfg.RequireMouseDown then
        if Util.IsMouseDown(cfg.MouseButton == "Right") then
            gate.LastActive = os.clock()
        elseif os.clock() - (gate.LastActive or 0) > (grace or 0.15) then
            return false
        end
    end
    if cfg.LimitToItems and not Util.MatchesHeld(cfg.ItemNames) then
        return false
    end
    return true
end

-- Target registry: every Humanoid in the workspace (players AND NPCs)
local TARGET_MODES = { "Players", "Players + NPCs", "NPCs Only" }
local TargetRegistry = { Entries = {} }

-- Kill Aura publishes whatever it's currently locked onto here, so Aim Assist can optionally
-- follow the exact same target instead of picking its own (see "Use Kill Aura Target").
local SharedAimTarget = { Entry = nil, At = 0 }

local function registerHumanoid(inst)
    if inst:IsA("Humanoid") and not TargetRegistry.Entries[inst] then
        TargetRegistry.Entries[inst] = { Humanoid = inst }
    end
end

local ROOT_NAMES = { "HumanoidRootPart", "Torso", "UpperTorso", "Head" }

local function findRoot(model)
    for _, name in ipairs(ROOT_NAMES) do
        local part = model:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            return part
        end
    end
    return model.PrimaryPart
end

-- Returns a list of live targets: { Humanoid, Model, Root, Player (nil for NPCs), Name }
-- mode: "Players" | "Players + NPCs" | "NPCs Only"
function Util.GetTargets(mode)
    local includePlayers = mode ~= "NPCs Only"
    local includeNPCs = mode == "Players + NPCs" or mode == "NPCs Only"
    local list, count = {}, 0
    local myChar = LocalPlayer.Character
    local cam = Workspace.CurrentCamera

    for hum, entry in pairs(TargetRegistry.Entries) do
        local model = hum.Parent
        if model and model:IsA("Model") and model ~= myChar and hum.Health > 0
            and not (myChar and model:IsDescendantOf(myChar)) then
            -- Skip first-person viewmodels / camera arms (show up as "Viewmodel" in status)
            local modelName = string.lower(model.Name)
            if modelName:find("viewmodel", 1, true)
                or modelName:find("view_model", 1, true)
                or modelName == "arms"
                or (cam and model:IsDescendantOf(cam)) then
                -- ignore
            else
                local plr = Players:GetPlayerFromCharacter(model)
                if (plr and includePlayers) or (not plr and includeNPCs) then
                    local root = entry.Root
                    if not root or root.Parent ~= model then
                        root = findRoot(model)
                        entry.Root = root
                    end
                    if root then
                        entry.Model = model
                        entry.Player = plr
                        entry.Name = plr and plr.DisplayName or model.Name
                        count = count + 1
                        list[count] = entry
                    end
                end
            end
        end
    end
    return list
end

-- Wall check (raycast ignoring all player characters + camera)
local RayFilter = { Params = RaycastParams.new(), LastRefresh = 0 }
RayFilter.Params.FilterType = Enum.RaycastFilterType.Exclude
RayFilter.Params.IgnoreWater = true
pcall(function()
    RayFilter.Params.RespectCanCollide = true
end)

function RayFilter.Refresh()
    local now = os.clock()
    if now - RayFilter.LastRefresh < 0.25 then
        return
    end
    RayFilter.LastRefresh = now
    local list = {}
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Character then
            list[#list + 1] = plr.Character
        end
    end
    -- NPC models too, otherwise an NPC would "wall check" itself
    for hum in pairs(TargetRegistry.Entries) do
        local model = hum.Parent
        if model and model:IsA("Model") then
            list[#list + 1] = model
        end
    end
    if Workspace.CurrentCamera then
        list[#list + 1] = Workspace.CurrentCamera
    end
    RayFilter.Params.FilterDescendantsInstances = list
end

-- Sweeps a small sphere instead of an infinitely thin line, so a razor-thin wall can't be missed by
-- a ray grazing just past its face. Falls back to a plain raycast if an executor lacks Spherecast.
local function sightCast(origin, radius, direction, params)
    local ok, hit = pcall(Workspace.Spherecast, Workspace, origin, radius, direction, params)
    if ok then
        return hit
    end
    return Workspace:Raycast(origin, direction, params)
end

-- Skips hits right next to the origin (your own head / viewmodel in first person) and see-through parts
-- Strict version used by Kill Aura: thirteen sphere-sweeps must all be clear (left/right, up/down
-- AND the four diagonals between them, from both the target's side and your own), so grazing the
-- corner of a block, peeking through a diagonal gap, or seeing just a sliver of a target over a
-- ledge doesn't count as seeing them.
-- Nothing near you is ignored either. The old see-through allowance for fully invisible parts
-- (barriers, spawn shields) is gone too - only truly see-through parts (Transparency 1, no visible
-- block) still let a cast pass. A plain raycast is an infinitely thin line, so a paper-thin wall can
-- occasionally slip between two sample points on either side of it (floating point grazes its
-- face); Spherecast sweeps a small volume instead of a line, so it can't thread that gap.
local SIGHT_CAST_RADIUS = 0.3
function Util.HasStrictSight(origin, targetPosition)
    RayFilter.Refresh()
    local toward = targetPosition - origin
    if toward.Magnitude < 1 then
        return true
    end
    local flat = Vector3.new(toward.X, 0, toward.Z)
    local side = flat.Magnitude > 0.01 and flat.Unit:Cross(Vector3.new(0, 1, 0)) or Vector3.new(1, 0, 0)
    local up = Vector3.new(0, 1, 0)
    local function clear(from, to)
        local current = from
        for _ = 1, 4 do
            local direction = to - current
            if direction.Magnitude < 0.3 then
                return true
            end
            local hit = sightCast(current, SIGHT_CAST_RADIUS, direction, RayFilter.Params)
            if not hit then
                return true
            end
            if hit.Instance.Transparency >= 1 then
                current = hit.Position + direction.Unit * 0.15
            else
                return false
            end
        end
        return false
    end
    return clear(origin, targetPosition)
        and clear(origin, targetPosition + side * 0.7)
        and clear(origin, targetPosition - side * 0.7)
        and clear(origin, targetPosition + up * 0.7)
        and clear(origin, targetPosition - up * 0.5)
        -- Diagonal offsets: a corner where two thin walls meet can have a gap a pure left/right or
        -- pure up/down ray slips through even though neither axis alone sees a path. Checking both
        -- axes combined closes that off.
        and clear(origin, targetPosition + side * 0.6 + up * 0.6)
        and clear(origin, targetPosition - side * 0.6 - up * 0.6)
        and clear(origin, targetPosition + side * 0.6 - up * 0.4)
        and clear(origin, targetPosition - side * 0.6 + up * 0.4)
        and clear(origin + side * 0.5, targetPosition)
        and clear(origin - side * 0.5, targetPosition)
        and clear(origin + up * 0.4, targetPosition)
        and clear(origin - up * 0.4, targetPosition)
end

function Util.HasLineOfSight(origin, targetPosition)
    RayFilter.Refresh()
    local current = origin
    for _ = 1, 5 do
        local direction = targetPosition - current
        if direction.Magnitude < 0.5 then
            return true
        end
        local hit = Workspace:Raycast(current, direction, RayFilter.Params)
        if not hit then
            return true
        end
        local part = hit.Instance
        local nearOrigin = (hit.Position - origin).Magnitude < 2.5
        if nearOrigin or part.Transparency >= 0.95 then
            current = hit.Position + direction.Unit * 0.15
        else
            return false
        end
    end
    return false
end

-- Key name lookup for the keybind TextBox method
local KeyLookup = {}
for _, item in ipairs(Enum.KeyCode:GetEnumItems()) do
    KeyLookup[item.Name:lower()] = item
end
KeyLookup["ctrl"]  = Enum.KeyCode.LeftControl
KeyLookup["shift"] = Enum.KeyCode.LeftShift
KeyLookup["alt"]   = Enum.KeyCode.LeftAlt
KeyLookup["caps"]  = Enum.KeyCode.CapsLock
KeyLookup["space"] = Enum.KeyCode.Space
for alias, name in pairs({
    lshift = "LeftShift", rshift = "RightShift", lctrl = "LeftControl", rctrl = "RightControl",
    lalt = "LeftAlt", ralt = "RightAlt", control = "LeftControl", esc = "Escape", enter = "Return",
    bksp = "Backspace", del = "Delete", ins = "Insert", pgup = "PageUp", pgdn = "PageDown",
    ["`"] = "Backquote", ["-"] = "Minus", ["="] = "Equals", ["["] = "LeftBracket", ["]"] = "RightBracket",
    ["\\"] = "BackSlash", [";"] = "Semicolon", ["'"] = "Quote", [","] = "Comma", ["."] = "Period", ["/"] = "Slash",
    ["0"] = "Zero", ["1"] = "One", ["2"] = "Two", ["3"] = "Three", ["4"] = "Four",
    ["5"] = "Five", ["6"] = "Six", ["7"] = "Seven", ["8"] = "Eight", ["9"] = "Nine",
}) do
    local ok, keyCode = pcall(function()
        return Enum.KeyCode[name]
    end)
    if ok and keyCode then
        KeyLookup[alias] = keyCode
    end
end

-- ====================== MODULE: CORE ======================
local Nova = {
    Version    = "1.0.0",
    Config     = Util.DeepCopy(env.__NovaSaved or {}),
    Hooks      = {},
    ModuleList = {},
    Maid       = Maid.new(),
    Unloaded   = false,
}
-- Bump this when defaults change so stale saved settings don't mask them
local CONFIG_VERSION = 8
if Nova.Config.__v ~= CONFIG_VERSION then
    Nova.Config = { UI = Nova.Config.UI or {}, __v = CONFIG_VERSION }
end
Nova.Config.UI = Nova.Config.UI or {}
if Nova.Config.UI.Notifications == nil then
    Nova.Config.UI.Notifications = true
end
env.Nova = Nova

Nova.Maid:Give(UserInputService.InputBegan:Connect(function(input)
    local state = Util.MouseState
    local kind = input.UserInputType
    if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
        state.Left, state.LeftAt = true, os.clock()
    elseif kind == Enum.UserInputType.MouseButton2 then
        state.Right, state.RightAt = true, os.clock()
    end
end))
Nova.Maid:Give(UserInputService.InputEnded:Connect(function(input)
    local state = Util.MouseState
    local kind = input.UserInputType
    if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
        state.Left, state.LeftAt = false, os.clock()
    elseif kind == Enum.UserInputType.MouseButton2 then
        state.Right, state.RightAt = false, os.clock()
    end
end))
Nova.Maid:Give(UserInputService.WindowFocusReleased:Connect(function()
    Util.MouseState.Left, Util.MouseState.Right = false, false
end))

-- ====================== MODULE: TARGETS ======================
task.spawn(function()
    local descendants = Workspace:GetDescendants()
    for index, inst in ipairs(descendants) do
        if Nova.Unloaded then
            return
        end
        registerHumanoid(inst)
        if index % 3000 == 0 then
            task.wait()
        end
    end
end)
Nova.Maid:Give(Workspace.DescendantAdded:Connect(registerHumanoid))
Nova.Maid:Give(Workspace.DescendantRemoving:Connect(function(inst)
    if TargetRegistry.Entries[inst] then
        TargetRegistry.Entries[inst] = nil
    end
end))

-- ====================== MODULE: UI LIBRARY ======================
local TextService = service("TextService")
local HttpService = service("HttpService")

do
    local saved = Nova.Config.UI
    if saved.Scale == nil then
        saved.Scale = 100
    end
    if saved.ShowList == nil then
        saved.ShowList = false
    end
    if saved.Accent == nil then
        saved.Accent = "Purple"
    end
end

-- Deep obsidian base (not just "dark purple panel") with a two-tone accent gradient
-- (Accent -> AccentAlt) used everywhere a flat accent fill used to be - tabs, sliders, the
-- window border glow, module cards - so the whole thing reads as one deliberate gradient
-- language instead of a single flat colour repeated everywhere.
local Theme = {
    Background  = Color3.fromRGB(9, 9, 12),
    Panel       = Color3.fromRGB(15, 15, 20),
    Card        = Color3.fromRGB(22, 22, 29),
    CardHi      = Color3.fromRGB(29, 29, 38),
    Accent      = Color3.fromRGB(139, 108, 255),
    AccentAlt   = Color3.fromRGB(139, 108, 255),
    AccentDark  = Color3.fromRGB(104, 62, 205),
    AccentLight = Color3.fromRGB(198, 164, 255),
    Text        = Color3.fromRGB(236, 236, 244),
    TextDim     = Color3.fromRGB(150, 150, 168),
    TextFaint   = Color3.fromRGB(98, 98, 116),
    Stroke      = Color3.fromRGB(38, 38, 49),
    StrokeHover = Color3.fromRGB(70, 70, 90),
    Track       = Color3.fromRGB(48, 48, 62),
    Good        = Color3.fromRGB(110, 224, 150),
    Bad         = Color3.fromRGB(255, 96, 118),
    Warn        = Color3.fromRGB(255, 198, 96),
}

-- Each accent carries a paired "Alt" colour for the gradient's second stop, hand-picked per
-- accent rather than computed, so the pairing always looks intentional (violet -> sky, pink ->
-- sunset orange, etc.) instead of an auto hue-shift landing somewhere muddy.
local ACCENTS = {
    { Name = "Purple", Color = Color3.fromRGB(139, 108, 255), Alt = Color3.fromRGB(90, 200, 255) },
    { Name = "Blue",   Color = Color3.fromRGB(86, 148, 255), Alt = Color3.fromRGB(64, 208, 232) },
    { Name = "Cyan",   Color = Color3.fromRGB(64, 208, 232), Alt = Color3.fromRGB(120, 130, 255) },
    { Name = "Green",  Color = Color3.fromRGB(84, 214, 148), Alt = Color3.fromRGB(64, 208, 232) },
    { Name = "Pink",   Color = Color3.fromRGB(255, 104, 176), Alt = Color3.fromRGB(255, 156, 80) },
    { Name = "Orange", Color = Color3.fromRGB(255, 156, 80), Alt = Color3.fromRGB(255, 104, 176) },
}
local ACCENT_NAMES, ACCENT_SWATCHES = {}, {}
for _, accent in ipairs(ACCENTS) do
    ACCENT_NAMES[#ACCENT_NAMES + 1] = accent.Name
    ACCENT_SWATCHES[accent.Name] = accent.Color
end
-- No separate ACCENT_ALTS table or helper function here - every one of those is one more
-- permanent top-level local in a script that's already brushing against Lua's 200-local-per-
-- function ceiling. The couple of call sites that need an accent's Alt colour just loop over
-- ACCENTS (already a local) inline instead.

-- Anything that shows the accent colour registers a repaint function here, so changing the
-- accent in settings recolours the whole interface live.
local ThemeHooks = {}
local function onTheme(fn)
    ThemeHooks[#ThemeHooks + 1] = fn
    fn()
    return fn
end

local function applyAccent(color, alt)
    Theme.Accent = color
    -- Flat accent: every old two-stop gradient now resolves to one colour (cleaner look).
    Theme.AccentAlt = color
    Theme.AccentDark = color:Lerp(Color3.new(0, 0, 0), 0.32)
    Theme.AccentLight = color:Lerp(Color3.new(1, 1, 1), 0.45)
    for _, hook in ipairs(ThemeHooks) do
        pcall(hook)
    end
end

local FONT = {
    Regular = Enum.Font.Gotham,
    Medium  = Enum.Font.GothamMedium,
    Bold    = Enum.Font.GothamBold,
}

-- Scaled up from the original 960x560 (~1.14x both axes, not just wider) so module names and
-- the detail panel's longer hints have room to breathe without truncating to "...".
local WINDOW_W, WINDOW_H = 1100, 640
local SIDEBAR_W, TOPBAR_H, FOOTER_H = 200, 64, 30
local PAGE_PAD, BODY_PAD, HEADER_H = 24, 20, 64
-- The content area right of the sidebar is split into two columns: a module LIST (left) and a
-- persistent settings DETAIL panel (right) - replacing the old single-column accordion list.
local LIST_W = 320
local CONTENT_W = WINDOW_W - SIDEBAR_W - 1 - LIST_W - 1
local BODY_INNER_W = CONTENT_W - BODY_PAD * 2
local ROW_GAP, BODY_TOP, BODY_BOTTOM = 8, 6, 16

local function New(className, props, children)
    local inst = Instance.new(className)
    local parent
    for key, value in pairs(props or {}) do
        if key == "Parent" then
            parent = value
        else
            inst[key] = value
        end
    end
    for _, child in ipairs(children or {}) do
        child.Parent = inst
    end
    if parent then
        inst.Parent = parent
    end
    return inst
end

local function Round(radius)
    return New("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function Stroke(color, thickness, transparency)
    return New("UIStroke", {
        Color = color or Theme.Stroke,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    })
end

local function Pad(left, top, right, bottom)
    return New("UIPadding", {
        PaddingLeft = UDim.new(0, left or 0),
        PaddingTop = UDim.new(0, top or 0),
        PaddingRight = UDim.new(0, right or 0),
        PaddingBottom = UDim.new(0, bottom or 0),
    })
end

-- Quint instead of Quad as the fallback curve - every Animate() call that doesn't pick its own
-- easing (most hover/press feedback in the file) gets a snappier, more "premium" settle for free.
local function Tween(inst, duration, props, style, direction)
    local tween = TweenService:Create(
        inst,
        TweenInfo.new(duration, style or Enum.EasingStyle.Quint, direction or Enum.EasingDirection.Out),
        props
    )
    tween:Play()
    return tween
end

-- Sets properties immediately, or tweens them
local function Animate(inst, props, instant, duration, style)
    if instant then
        for key, value in pairs(props) do
            inst[key] = value
        end
        return nil
    end
    return Tween(inst, duration or 0.18, props, style)
end

local function getGuiParent()
    if gethui then
        local ok, hidden = pcall(gethui)
        if ok and hidden then
            return hidden
        end
    end
    local ok = pcall(function()
        local _ = CoreGui.Name
    end)
    if ok then
        return CoreGui
    end
    return LocalPlayer:WaitForChild("PlayerGui")
end

-- Text measuring (falls back to an estimate if TextService is unavailable)
local function measure(text, size, font, width)
    local ok, result = pcall(function()
        return TextService:GetTextSize(tostring(text), size, font, Vector2.new(width or 100000, 100000))
    end)
    if ok and typeof(result) == "Vector2" then
        return result
    end
    local chars = #tostring(text)
    local limit = width or 100000
    local perLine = math.max(1, math.floor(limit / (size * 0.55)))
    return Vector2.new(math.min(chars * size * 0.55, limit), math.ceil(chars / perLine) * (size + 3))
end

local KEY_DISPLAY = {
    LeftShift = "LShift", RightShift = "RShift", LeftControl = "LCtrl", RightControl = "RCtrl",
    LeftAlt = "LAlt", RightAlt = "RAlt", CapsLock = "Caps", Escape = "Esc", Return = "Enter",
    Backspace = "Bksp", Backquote = "`", Minus = "-", Equals = "=", LeftBracket = "[",
    RightBracket = "]", BackSlash = "\\", Semicolon = ";", Quote = "'", Comma = ",",
    Period = ".", Slash = "/",
    Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
    Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
}

local function keyText(name)
    if name == nil or name == "None" then
        return "None"
    end
    return KEY_DISPLAY[name] or name
end

local UI = { Tabs = {}, TabList = {}, Visible = false, BaseScale = 1 }

-- Keybind chips "listen" for the next key press instead of taking typed text. Only one chip
-- listens at a time; starting a new one cancels whichever was already waiting.
function UI:StartKeyListen(handlers)
    if UI.KeyListen and UI.KeyListen.Cancel then
        pcall(UI.KeyListen.Cancel)
    end
    UI.KeyListen = handlers
end

function UI:StopKeyListen()
    UI.KeyListen = nil
end

-- ---------------------------------------------------------------------
-- Shared widgets
-- ---------------------------------------------------------------------
local function createSwitch(parent, width, height)
    local knobSize = height - 6
    local state = false
    local track = New("Frame", {
        Size = UDim2.fromOffset(width, height),
        BackgroundColor3 = Theme.Track,
        BorderSizePixel = 0,
        Parent = parent,
    }, { Round(height / 2) })
    -- Two-tone wash that only shows once the switch is on, layered over the flat track colour.
    local trackGradient = New("UIGradient", { Rotation = 20, Enabled = false, Parent = track })
    -- A soft ring that fades in around the track when it's on, standing in for a real glow.
    local haloRing = Stroke(Theme.Accent, 3, 1)
    haloRing.Parent = track
    local knob = New("Frame", {
        Size = UDim2.fromOffset(knobSize, knobSize),
        Position = UDim2.fromOffset(3, 3),
        BackgroundColor3 = Theme.TextDim,
        BorderSizePixel = 0,
        Parent = track,
    }, { Round(knobSize / 2) })
    local click = New("TextButton", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "",
        Parent = track,
    })

    local function paint(instant)
        local position = UDim2.fromOffset(state and (width - knobSize - 3) or 3, 3)
        trackGradient.Enabled = state
        Animate(track, { BackgroundColor3 = state and Theme.Accent or Theme.Track }, instant, 0.18)
        Animate(knob, { Position = position, BackgroundColor3 = state and Color3.new(1, 1, 1) or Theme.TextDim }, instant, 0.18)
        Animate(haloRing, { Transparency = 1 }, instant, 0.18)
    end
    onTheme(function()
        trackGradient.Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt)
        haloRing.Color = Theme.Accent
        paint(true)
    end)

    local function set(newState, instant)
        state = newState and true or false
        paint(instant)
    end

    return track, set, click
end

local function makeButton(parent, text, style, size)
    local stroke = Stroke(Theme.Stroke, 1)
    local button = New("TextButton", {
        Size = size or UDim2.fromScale(1, 1),
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Text = text,
        Font = FONT.Medium,
        TextSize = 12,
        TextColor3 = Theme.TextDim,
        Parent = parent,
    }, { Round(9), stroke })

    local hovered = false
    local function paint(instant)
        local bg, bgAlpha, textColor, strokeColor, strokeAlpha
        if style == "accent" then
            bg, bgAlpha, textColor, strokeColor, strokeAlpha =
                Theme.Accent, hovered and 0.68 or 0.82, Theme.AccentLight, Theme.Accent, 0.5
        elseif style == "danger" then
            bg, bgAlpha, textColor, strokeColor, strokeAlpha =
                Theme.Bad, hovered and 0.72 or 0.86, Theme.Bad, Theme.Bad, 0.55
        else
            bg, bgAlpha, textColor, strokeColor, strokeAlpha =
                hovered and Theme.Card or Theme.Panel, 0, hovered and Theme.Text or Theme.TextDim,
                hovered and Theme.StrokeHover or Theme.Stroke, 0
        end
        Animate(button, { BackgroundColor3 = bg, BackgroundTransparency = bgAlpha, TextColor3 = textColor }, instant, 0.12)
        Animate(stroke, { Color = strokeColor, Transparency = strokeAlpha }, instant, 0.12)
    end
    onTheme(function()
        paint(true)
    end)
    button.MouseEnter:Connect(function()
        hovered = true
        paint(false)
    end)
    button.MouseLeave:Connect(function()
        hovered = false
        paint(false)
    end)
    return button
end

-- ---------------------------------------------------------------------
-- Control host: owns a column of rows (toggle / slider / option ...) bound to one config table
-- ---------------------------------------------------------------------
local Controls = {}

local function newHost(parent, cfg, onChange)
    local host = {
        Parent = parent,
        Cfg = cfg,
        Order = 0,
        Rows = {},
        Controls = {},
        ControlList = {},
        OnChange = onChange,
        InnerWidth = BODY_INNER_W,
    }

    function host:NextOrder()
        self.Order = self.Order + 1
        return self.Order
    end

    function host:Row(height, showIf, isSection)
        local frame = New("Frame", {
            Size = UDim2.new(1, 0, 0, height),
            BackgroundTransparency = 1,
            LayoutOrder = self:NextOrder(),
            Parent = self.Parent,
        })
        self.Rows[#self.Rows + 1] = { Frame = frame, Height = height, ShowIf = showIf, IsSection = isSection or false }
        return frame
    end

    function host:Register(key, handle)
        self.Controls[key] = handle
        self.ControlList[#self.ControlList + 1] = handle
    end

    function host:Changed(key, value, callback)
        if callback then
            pcall(callback, value)
        end
        if self.OnChange then
            pcall(self.OnChange, key, value)
        end
        self:RefreshVisibility()
    end

    -- Rows can hide themselves (ShowIf) and a section header hides when nothing under it is visible
    function host:RefreshVisibility()
        local section, sectionVisible = nil, false
        for _, entry in ipairs(self.Rows) do
            if entry.IsSection then
                if section then
                    section.Frame.Visible = sectionVisible
                end
                section, sectionVisible = entry, false
            else
                local show = true
                if entry.ShowIf then
                    local ok, result = pcall(entry.ShowIf, self.Cfg)
                    show = (not ok) or (result and true or false)
                end
                entry.Frame.Visible = show
                if show then
                    sectionVisible = true
                end
            end
        end
        if section then
            section.Frame.Visible = sectionVisible
        end
        if self.OnLayout then
            self.OnLayout()
        end
    end

    function host:ContentHeight()
        local total, count = 0, 0
        for _, entry in ipairs(self.Rows) do
            if entry.Frame.Visible then
                total = total + entry.Height
                count = count + 1
            end
        end
        if self.FooterRow then
            total = total + self.FooterRow.Height
            count = count + 1
        end
        if count > 1 then
            total = total + (count - 1) * ROW_GAP
        end
        return total + BODY_TOP + BODY_BOTTOM
    end

    return host
end

local function makeLabel(row, text, widthOffset)
    return New("TextLabel", {
        Size = UDim2.new(1, widthOffset, 1, 0),
        BackgroundTransparency = 1,
        Text = text,
        Font = FONT.Regular,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    })
end

function Controls.Section(host, title)
    local text = string.upper(tostring(title))
    local frame = host:Row(26, nil, true)
    New("TextLabel", {
        Position = UDim2.fromOffset(0, 8),
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
        Text = text,
        Font = FONT.Bold,
        TextSize = 10,
        TextColor3 = Theme.TextFaint,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = frame,
    })
end

function Controls.Note(host, text, o)
    local height = math.max(16, math.ceil(measure(text, 11, FONT.Regular, host.InnerWidth).Y) + 2)
    local frame = host:Row(height, o and o.ShowIf)
    New("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = text,
        Font = FONT.Regular,
        TextSize = 11,
        TextColor3 = Theme.TextDim,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Top,
        Parent = frame,
    })
end

function Controls.Toggle(host, o)
    local cfg, key = host.Cfg, o.Key
    if cfg[key] == nil then
        cfg[key] = o.Default and true or false
    end
    local row = host:Row(30, o.ShowIf)
    makeLabel(row, o.Label, -56)
    local rowButton = New("TextButton", {
        Size = UDim2.new(1, -48, 1, 0),
        BackgroundTransparency = 1,
        Text = "",
        Parent = row,
    })
    local track, set, click = createSwitch(row, 38, 20)
    track.AnchorPoint = Vector2.new(1, 0.5)
    track.Position = UDim2.new(1, 0, 0.5, 0)
    set(cfg[key], true)

    local function flip()
        cfg[key] = not cfg[key]
        set(cfg[key], false)
        host:Changed(key, cfg[key], o.Callback)
    end
    click.MouseButton1Click:Connect(flip)
    rowButton.MouseButton1Click:Connect(flip)

    local handle = { Key = key, Default = o.Default and true or false, Callback = o.Callback }
    function handle.Set(value, instant)
        cfg[key] = value and true or false
        set(cfg[key], instant)
    end
    host:Register(key, handle)
    UI:AttachTip(rowButton, o.Tip)
    return handle
end

function Controls.Slider(host, o)
    local cfg, key = host.Cfg, o.Key
    local min, max, step = o.Min, o.Max, o.Step or 1
    local default = o.Default or min
    if cfg[key] == nil then
        cfg[key] = default
    end
    local row = host:Row(50, o.ShowIf)
    local boxWidth = math.clamp(
        math.max(
            measure(tostring(max) .. (o.Suffix or ""), 12, FONT.Medium).X,
            measure(tostring(min) .. (o.Suffix or ""), 12, FONT.Medium).X
        ) + 24,
        52, 120
    )

    local label = New("TextLabel", {
        Size = UDim2.new(1, -(boxWidth + 8), 0, 24),
        BackgroundTransparency = 1,
        Text = o.Label,
        Font = FONT.Regular,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    })
    local valueStroke = Stroke(Theme.Stroke, 1)
    local valueBox = New("TextBox", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, 0, 0, 0),
        Size = UDim2.fromOffset(boxWidth, 24),
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Text = "",
        Font = FONT.Medium,
        TextSize = 12,
        TextColor3 = Theme.AccentLight,
        ClearTextOnFocus = true,
        Parent = row,
    }, { Round(8), valueStroke })
    local track = New("Frame", {
        Position = UDim2.new(0, 0, 0, 38),
        Size = UDim2.new(1, 0, 0, 6),
        BackgroundColor3 = Theme.Track,
        BorderSizePixel = 0,
        Parent = row,
    }, { Round(3) })
    local fill = New("Frame", {
        Size = UDim2.fromScale(0, 1),
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
        Parent = track,
    }, { Round(3) })
    local fillGradient = New("UIGradient", { Parent = fill })
    local knobRing = Stroke(Theme.Accent, 2)
    local knob = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(14, 14),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        Parent = track,
    }, { Round(7), knobRing })
    local hit = New("TextButton", {
        Position = UDim2.new(0, 0, 0, 26),
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        Text = "",
        Parent = row,
    })
    onTheme(function()
        fill.BackgroundColor3 = Color3.new(1, 1, 1)
        fillGradient.Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt)
        knobRing.Color = Theme.Accent
        valueBox.TextColor3 = Theme.AccentLight
    end)

    -- A fractional Step (0.1, 0.01, ...) always displays with that many decimals, so a slider at
    -- its default like 14 still reads "14.0" / "14.00" instead of Lua's tostring dropping the
    -- trailing zero - the whole point of a decimal step is seeing the decimal.
    local stepDecimals = 0
    do
        local text = tostring(step)
        local dot = string.find(text, "%.")
        if dot then
            stepDecimals = #text - dot
        end
    end
    local function formatValue(value)
        if stepDecimals > 0 then
            return string.format("%." .. stepDecimals .. "f", value)
        end
        return tostring(value)
    end

    local function apply(value)
        value = math.clamp(value, min, max)
        value = math.floor(value / step + 0.5) * step
        value = math.clamp(value, min, max)
        value = tonumber(string.format("%.4f", value))
        cfg[key] = value
        local alpha = (max > min) and ((value - min) / (max - min)) or 0
        fill.Size = UDim2.fromScale(alpha, 1)
        knob.Position = UDim2.fromScale(alpha, 0.5)
        valueBox.Text = formatValue(value) .. (o.Suffix or "")
    end

    local function fromInput(input)
        local alpha = math.clamp((input.Position.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
        apply(min + (max - min) * alpha)
        host:Changed(key, cfg[key], o.Callback)
    end

    hit.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            UI.ActiveDrag = fromInput
            UI.ActiveRelease = function()
                Animate(knob, { Size = UDim2.fromOffset(14, 14) }, false, 0.1)
            end
            Animate(knob, { Size = UDim2.fromOffset(18, 18) }, false, 0.1)
            fromInput(input)
        end
    end)
    -- Right-click resets to the default value
    hit.MouseButton2Click:Connect(function()
        apply(default)
        host:Changed(key, cfg[key], o.Callback)
    end)
    -- Click the number to type an exact value
    valueBox.Focused:Connect(function()
        valueStroke.Color = Theme.Accent
        valueBox.Text = formatValue(cfg[key])
    end)
    valueBox.FocusLost:Connect(function()
        valueStroke.Color = Theme.Stroke
        local text = string.gsub(valueBox.Text, ",", ".")
        local number = tonumber(string.match(text, "-?%d*%.?%d+"))
        if number then
            apply(number)
            host:Changed(key, cfg[key], o.Callback)
        else
            apply(cfg[key])
        end
    end)

    apply(cfg[key])

    local handle = { Key = key, Default = default, Callback = o.Callback }
    function handle.Set(value)
        apply(value)
    end
    host:Register(key, handle)
    UI:AttachTip(label, o.Tip and (o.Tip .. " (right-click the bar to reset)") or "Right-click the bar to reset")
    return handle
end

function Controls.Option(host, o)
    local cfg, key, list = host.Cfg, o.Key, o.Options
    if cfg[key] == nil then
        cfg[key] = o.Default or list[1]
    end
    local row = host:Row(32, o.ShowIf)
    local label = makeLabel(row, o.Label, -170)

    local widths, total = {}, 0
    for index, item in ipairs(list) do
        widths[index] = math.max(56, measure(tostring(item), 12, FONT.Medium).X + 24)
        total = total + widths[index]
    end

    local style = "dropdown"
    if o.Swatches then
        style = "swatches"
    elseif #list <= 3 and total <= 250 and not o.Dropdown then
        style = "segmented"
    end

    local refresh
    local function set(value, fire)
        cfg[key] = value
        refresh(false)
        if fire then
            host:Changed(key, value, o.Callback)
        end
    end

    if style == "segmented" then
        label.Size = UDim2.new(1, -(total + 20), 1, 0)
        local segment = New("Frame", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, 0, 0.5, 0),
            Size = UDim2.fromOffset(total + 4, 26),
            BackgroundColor3 = Theme.Panel,
            BorderSizePixel = 0,
            Parent = row,
        }, { Round(9), Stroke(Theme.Stroke, 1) })
        local highlightGradient = New("UIGradient", { Rotation = 20 })
        local highlight = New("Frame", {
            Position = UDim2.fromOffset(2, 2),
            Size = UDim2.fromOffset(widths[1], 22),
            BackgroundColor3 = Theme.Accent,
            BorderSizePixel = 0,
            Parent = segment,
        }, { Round(7), highlightGradient })
        local buttons = {}
        local x = 2
        for index, item in ipairs(list) do
            local button = New("TextButton", {
                Position = UDim2.fromOffset(x, 2),
                Size = UDim2.fromOffset(widths[index], 22),
                BackgroundTransparency = 1,
                AutoButtonColor = false,
                Text = tostring(item),
                Font = FONT.Medium,
                TextSize = 12,
                TextColor3 = Theme.TextDim,
                ZIndex = 2,
                Parent = segment,
            })
            button.MouseButton1Click:Connect(function()
                set(item, true)
            end)
            buttons[index] = { Button = button, X = x, Width = widths[index] }
            x = x + widths[index]
        end
        refresh = function(instant)
            local selected = table.find(list, cfg[key]) or 1
            local info = buttons[selected]
            Animate(highlight, {
                Position = UDim2.fromOffset(info.X, 2),
                Size = UDim2.fromOffset(info.Width, 22),
            }, instant, 0.2, Enum.EasingStyle.Quint)
            for index, entry in ipairs(buttons) do
                Animate(entry.Button, { TextColor3 = (index == selected) and Color3.new(1, 1, 1) or Theme.TextDim }, instant, 0.15)
            end
        end
        onTheme(function()
            highlight.BackgroundColor3 = Theme.Accent
            highlightGradient.Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt)
        end)
    elseif style == "swatches" then
        local size, gap = 20, 8
        local width = #list * size + (#list - 1) * gap
        label.Size = UDim2.new(1, -(width + 12), 1, 0)
        local holder = New("Frame", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, 0, 0.5, 0),
            Size = UDim2.fromOffset(width, 24),
            BackgroundTransparency = 1,
            Parent = row,
        })
        local rings = {}
        for index, item in ipairs(list) do
            local ring = Stroke(Color3.new(1, 1, 1), 2, 1)
            local dot = New("TextButton", {
                Position = UDim2.fromOffset((index - 1) * (size + gap), 2),
                Size = UDim2.fromOffset(size, size),
                BackgroundColor3 = o.Swatches[item] or Theme.Accent,
                AutoButtonColor = false,
                Text = "",
                Parent = holder,
            }, { Round(size / 2), ring })
            dot.MouseButton1Click:Connect(function()
                set(item, true)
            end)
            UI:AttachTip(dot, tostring(item))
            rings[index] = ring
        end
        refresh = function(instant)
            local selected = table.find(list, cfg[key]) or 1
            for index, ring in ipairs(rings) do
                Animate(ring, { Transparency = (index == selected) and 0 or 1 }, instant, 0.15)
            end
        end
    else
        local longest = 0
        for _, item in ipairs(list) do
            longest = math.max(longest, measure(tostring(item), 12, FONT.Medium).X)
        end
        local width = math.clamp(longest + 46, 120, 210)
        label.Size = UDim2.new(1, -(width + 12), 1, 0)
        local buttonStroke = Stroke(Theme.Stroke, 1)
        local button = New("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, 0, 0.5, 0),
            Size = UDim2.fromOffset(width, 26),
            BackgroundColor3 = Theme.Panel,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            Text = "",
            Parent = row,
        }, { Round(8), buttonStroke })
        local valueLabel = New("TextLabel", {
            Position = UDim2.fromOffset(10, 0),
            Size = UDim2.new(1, -30, 1, 0),
            BackgroundTransparency = 1,
            Text = "",
            Font = FONT.Medium,
            TextSize = 12,
            TextColor3 = Theme.AccentLight,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = button,
        })
        New("TextLabel", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -9, 0.5, 0),
            Size = UDim2.fromOffset(12, 12),
            BackgroundTransparency = 1,
            Text = "v",
            Font = FONT.Bold,
            TextSize = 10,
            TextColor3 = Theme.TextDim,
            Parent = button,
        })
        refresh = function()
            valueLabel.Text = tostring(cfg[key])
        end
        onTheme(function()
            valueLabel.TextColor3 = Theme.AccentLight
        end)
        button.MouseEnter:Connect(function()
            buttonStroke.Color = Theme.StrokeHover
        end)
        button.MouseLeave:Connect(function()
            buttonStroke.Color = Theme.Stroke
        end)
        button.MouseButton1Click:Connect(function()
            if UI.DropdownFrame.Visible and UI.DropdownAnchor == button then
                UI:CloseDropdown()
                return
            end
            UI:OpenDropdown(button, list, cfg[key], function(item)
                set(item, true)
            end)
        end)
    end

    refresh(true)

    local handle = { Key = key, Default = o.Default or list[1], Callback = o.Callback, Options = list }
    function handle.Set(value, instant)
        cfg[key] = value
        refresh(instant)
    end
    host:Register(key, handle)
    UI:AttachTip(label, o.Tip)
    return handle
end

function Controls.TextBox(host, o)
    local cfg, key = host.Cfg, o.Key
    if cfg[key] == nil then
        cfg[key] = o.Default or ""
    end
    local row = host:Row(32, o.ShowIf)
    local label = makeLabel(row, o.Label, -192)
    local boxStroke = Stroke(Theme.Stroke, 1)
    local box = New("TextBox", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, 0, 0.5, 0),
        Size = UDim2.fromOffset(180, 26),
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Text = tostring(cfg[key]),
        PlaceholderText = o.Placeholder or "",
        PlaceholderColor3 = Theme.TextFaint,
        TextColor3 = Theme.AccentLight,
        Font = FONT.Medium,
        TextSize = 12,
        ClearTextOnFocus = false,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = row,
    }, { Round(8), boxStroke, Pad(10, 0, 10, 0) })
    onTheme(function()
        box.TextColor3 = Theme.AccentLight
    end)
    box.Focused:Connect(function()
        boxStroke.Color = Theme.Accent
    end)
    box.FocusLost:Connect(function()
        boxStroke.Color = Theme.Stroke
        cfg[key] = box.Text
        host:Changed(key, box.Text, o.Callback)
    end)

    local handle = { Key = key, Default = o.Default or "", Callback = o.Callback }
    function handle.Set(value)
        cfg[key] = tostring(value)
        box.Text = cfg[key]
    end
    host:Register(key, handle)
    UI:AttachTip(label, o.Tip)
    return handle
end

function Controls.ButtonRow(host, defs, showIf)
    local row = host:Row(34, showIf)
    New("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
        Parent = row,
    })
    local count = #defs
    for index, def in ipairs(defs) do
        local button = makeButton(row, def.Label, def.Style, UDim2.new(1 / count, -((count - 1) * 8) / count, 1, 0))
        button.LayoutOrder = index
        button.MouseButton1Click:Connect(function()
            if def.Callback then
                local ok, err = pcall(def.Callback)
                if not ok then
                    pcall(Nova.Notify, "Nova", "Button error: " .. tostring(err), 4, "error", true)
                end
            end
        end)
        UI:AttachTip(button, def.Tip)
    end
end

function Controls.Button(host, o)
    Controls.ButtonRow(host, { o }, o.ShowIf)
end

-- ---------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------
UI.Gui = New("ScreenGui", {
    Name = Util.RandomName(),
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    DisplayOrder = 1000,
})
do
    local ok = pcall(function()
        UI.Gui.Parent = getGuiParent()
    end)
    if not ok or not UI.Gui.Parent then
        UI.Gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    end
end
Nova.Maid:Give(UI.Gui)

-- Holder is never scaled (it is what you drag); Main is scaled around its centre.
UI.Holder = New("Frame", {
    Name = "Holder",
    Size = UDim2.fromOffset(WINDOW_W, WINDOW_H),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    BackgroundTransparency = 1,
    Parent = UI.Gui,
})

local mainStroke = Stroke(Theme.Stroke, 1)
UI.Main = New("Frame", {
    Name = "Main",
    Size = UDim2.fromOffset(WINDOW_W, WINDOW_H),
    Position = UDim2.fromScale(0.5, 0.5),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = Theme.Background,
    BorderSizePixel = 0,
    Visible = false,
    Parent = UI.Holder,
}, { Round(12), mainStroke })

UI.Scale = New("UIScale", { Scale = 1, Parent = UI.Main })

onTheme(function()
    mainStroke.Color = Theme.Stroke
    mainStroke.Transparency = 0.25
end)

-- Modal button lets the cursor free itself in shift-lock / first person games
UI.ModalButton = New("TextButton", {
    Size = UDim2.fromOffset(0, 0),
    BackgroundTransparency = 1,
    Text = "",
    Modal = false,
    Parent = UI.Main,
})

local RIGHT_X = SIDEBAR_W + 1
local RIGHT_W = WINDOW_W - RIGHT_X

-- Sidebar ------------------------------------------------------------
local Sidebar = New("Frame", {
    Name = "Sidebar",
    Size = UDim2.new(0, SIDEBAR_W, 1, 0),
    BackgroundColor3 = Theme.Panel,
    BorderSizePixel = 0,
    Parent = UI.Main,
}, { Round(12) })
-- Squares off Sidebar's own right-edge rounding where it meets Main. Kept at the back (ZIndex 0)
-- so it never paints over the tab pill, which used to get its right corner flattened by this.
New("Frame", {
    Position = UDim2.new(1, -20, 0, 0),
    Size = UDim2.new(0, 20, 1, 0),
    BackgroundColor3 = Theme.Panel,
    BorderSizePixel = 0,
    ZIndex = 0,
    Parent = Sidebar,
})
-- A faint seam between the sidebar and the content panel reads cleaner than a hard edge
New("Frame", {
    Position = UDim2.new(1, 0, 0, 10),
    Size = UDim2.new(0, 1, 1, -20),
    BackgroundColor3 = Theme.Stroke,
    BackgroundTransparency = 0.35,
    BorderSizePixel = 0,
    ZIndex = 0,
    Parent = Sidebar,
})

-- Brand
local BrandArea = New("Frame", {
    Name = "Brand",
    Size = UDim2.new(1, 0, 0, 70),
    BackgroundTransparency = 1,
    Parent = Sidebar,
})
-- brandGlow/brandTile/brandGradient are only ever touched in here - scoped to its own block
-- instead of living as permanent top-level locals for the rest of the script.
do
    local brandGlow = New("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromOffset(16 + 17, 17 + 17),
        Size = UDim2.fromOffset(48, 48),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ZIndex = 0,
        Parent = BrandArea,
    }, { Round(10) })
    local brandTile = New("Frame", {
        Position = UDim2.fromOffset(16, 17),
        Size = UDim2.fromOffset(34, 34),
        BackgroundColor3 = Color3.new(1, 1, 1),
        BorderSizePixel = 0,
        Parent = BrandArea,
    }, { Round(8) })
    local brandGradient = New("UIGradient", { Rotation = 45, Parent = brandTile })
    Stroke(Color3.new(1, 1, 1), 1, 0.7).Parent = brandTile
    New("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "N",
        Font = FONT.Bold,
        TextSize = 19,
        TextColor3 = Color3.new(1, 1, 1),
        Parent = brandTile,
    })
    onTheme(function()
        brandGradient.Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt)
        brandGlow.BackgroundColor3 = Theme.Accent
    end)
end
New("TextLabel", {
    Position = UDim2.fromOffset(58, 15),
    Size = UDim2.fromOffset(100, 22),
    BackgroundTransparency = 1,
    Text = "Nova",
    Font = FONT.Bold,
    TextSize = 19,
    TextColor3 = Theme.Text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = BrandArea,
})
New("TextLabel", {
    Position = UDim2.fromOffset(59, 37),
    Size = UDim2.fromOffset(100, 12),
    BackgroundTransparency = 1,
    Text = "v" .. Nova.Version,
    Font = FONT.Medium,
    TextSize = 10,
    TextColor3 = Theme.TextFaint,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = BrandArea,
})

local TAB = { X = 12, Y = 84, H = 38, GAP = 4 }
local TabHolder = New("Frame", {
    Name = "Tabs",
    Position = UDim2.fromOffset(TAB.X, TAB.Y),
    Size = UDim2.new(1, -24, 1, -84 - 78),
    ZIndex = 2,
    BackgroundTransparency = 1,
    Parent = Sidebar,
}, {
    New("UIListLayout", { Padding = UDim.new(0, TAB.GAP), SortOrder = Enum.SortOrder.LayoutOrder }),
})

-- A solid gradient-filled pill slides between tabs instead of each one painting its own fill -
-- the active tab reads as a real button, not just a dimmed row.
-- It lives on Sidebar, NOT inside TabHolder: TabHolder has a UIListLayout that repositions every
-- child it owns, and a plain sibling frame parented there would get folded into the tab list as
-- its own (empty) row instead of floating behind the tabs.
local tabIndicatorGradient = New("UIGradient", { Rotation = 25 })
local TabIndicator = New("Frame", {
    Name = "Indicator",
    Position = UDim2.fromOffset(TAB.X, TAB.Y),
    Size = UDim2.new(1, -(TAB.X * 2), 0, TAB.H),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    ZIndex = 1,
    Visible = false,
    Parent = Sidebar,
}, { Round(8), tabIndicatorGradient })
onTheme(function()
    tabIndicatorGradient.Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt)
end)

-- Top bar --------------------------------------------------------------
local TopBar = New("Frame", {
    Name = "TopBar",
    Position = UDim2.fromOffset(RIGHT_X, 0),
    Size = UDim2.fromOffset(RIGHT_W, TOPBAR_H),
    BackgroundTransparency = 1,
    Parent = UI.Main,
})
New("Frame", {
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, 0, 1, 0),
    Size = UDim2.new(1, 0, 0, 1),
    BackgroundColor3 = Theme.Stroke,
    BackgroundTransparency = 0.4,
    BorderSizePixel = 0,
    Parent = TopBar,
})
do
    local titleBar = New("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.fromOffset(PAGE_PAD, 23),
        Size = UDim2.fromOffset(3, 16),
        BackgroundColor3 = Theme.Accent,
        BorderSizePixel = 0,
        Parent = TopBar,
    }, { Round(2) })
    onTheme(function()
        titleBar.BackgroundColor3 = Theme.Accent
    end)
end
UI.TitleLabel = New("TextLabel", {
    Position = UDim2.fromOffset(PAGE_PAD + 11, 11),
    Size = UDim2.fromOffset(230, 22),
    BackgroundTransparency = 1,
    Text = "",
    Font = FONT.Bold,
    TextSize = 17,
    TextColor3 = Theme.Text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = TopBar,
})
UI.SubtitleLabel = New("TextLabel", {
    Position = UDim2.fromOffset(PAGE_PAD + 11, 33),
    Size = UDim2.fromOffset(230, 14),
    BackgroundTransparency = 1,
    Text = "",
    Font = FONT.Regular,
    TextSize = 11,
    TextColor3 = Theme.TextFaint,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Parent = TopBar,
})

local function iconButton(text, textSize, xFromRight)
    local button = makeButton(TopBar, text, "ghost", UDim2.fromOffset(30, 30))
    button.AnchorPoint = Vector2.new(1, 0.5)
    button.Position = UDim2.new(1, -xFromRight, 0, TOPBAR_H / 2)
    button.TextSize = textSize
    button.Font = FONT.Bold
    return button
end
local closeButton = iconButton("×", 20, PAGE_PAD)
local gearButton = iconButton("⚙", 16, PAGE_PAD + 38)

-- Search
-- Everything the search box needs (searchStroke, SearchFrame, searchClear, the "Active" chip)
-- stays local to this block - nothing outside the Search section ever touches them by name.
do
local searchStroke = Stroke(Theme.Stroke, 1, 1)
local SearchFrame = New("Frame", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -(PAGE_PAD + 78), 0, TOPBAR_H / 2),
    Size = UDim2.fromOffset(176, 30),
    BackgroundColor3 = Theme.Card,
    BorderSizePixel = 0,
    Parent = TopBar,
}, { Round(9), searchStroke })
-- No search-icon glyph here on purpose: "⌕" isn't in Roblox's default UI font, so it was
-- rendering as a missing-glyph box instead of a magnifying glass. The placeholder text alone
-- carries the hint now.
UI.SearchBox = New("TextBox", {
    Position = UDim2.fromOffset(12, 0),
    Size = UDim2.new(1, -38, 1, 0),
    BackgroundTransparency = 1,
    Text = "",
    PlaceholderText = "Search modules",
    PlaceholderColor3 = Theme.TextFaint,
    TextColor3 = Theme.Text,
    Font = FONT.Regular,
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
    ClearTextOnFocus = false,
    TextTruncate = Enum.TextTruncate.AtEnd,
    Parent = SearchFrame,
})
local searchClear = New("TextButton", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -6, 0.5, 0),
    Size = UDim2.fromOffset(20, 20),
    BackgroundTransparency = 1,
    Text = "×",
    Font = FONT.Bold,
    TextSize = 16,
    TextColor3 = Theme.TextDim,
    Visible = false,
    Parent = SearchFrame,
})
-- "Active" chip: show only the modules that are switched on
UI.OnlyActive = false
do
    local chipStroke = Stroke(Theme.Stroke, 1, 1)
    local chip = New("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -(PAGE_PAD + 78 + 176 + 8), 0, TOPBAR_H / 2),
        Size = UDim2.fromOffset(62, 30),
        BackgroundColor3 = Theme.Card,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Text = "Active",
        Font = FONT.Medium,
        TextSize = 12,
        TextColor3 = Theme.TextDim,
        Parent = TopBar,
    }, { Round(9), chipStroke })
    local chipHover = false
    local function paintChip(instant)
        if UI.OnlyActive then
            Animate(chip, { BackgroundColor3 = Theme.Accent, BackgroundTransparency = chipHover and 0.68 or 0.82,
                TextColor3 = Theme.AccentLight }, instant, 0.12)
        else
            Animate(chip, { BackgroundColor3 = chipHover and Theme.Panel:Lerp(Theme.Text, 0.06) or Theme.Card, BackgroundTransparency = 0,
                TextColor3 = chipHover and Theme.Text or Theme.TextDim }, instant, 0.12)
        end
    end
    chip.MouseEnter:Connect(function()
        chipHover = true
        paintChip(false)
    end)
    chip.MouseLeave:Connect(function()
        chipHover = false
        paintChip(false)
    end)
    chip.MouseButton1Click:Connect(function()
        UI.OnlyActive = not UI.OnlyActive
        paintChip(false)
        UI:ApplySearch(UI.SearchBox.Text)
    end)
    onTheme(function()
        paintChip(true)
    end)
    UI.AttachChipTip = function()
        UI:AttachTip(chip, "Show only the modules that are switched on.")
    end
end

UI.SearchBox.Focused:Connect(function()
    searchStroke.Color = Theme.Accent
    searchStroke.Transparency = 0.2
end)
UI.SearchBox.FocusLost:Connect(function()
    searchStroke.Transparency = 1
end)
UI.SearchBox:GetPropertyChangedSignal("Text"):Connect(function()
    searchClear.Visible = UI.SearchBox.Text ~= ""
    UI:ApplySearch(UI.SearchBox.Text)
end)
searchClear.MouseButton1Click:Connect(function()
    UI.SearchBox.Text = ""
end)
end

-- Profile card (bottom of the sidebar): avatar, name, and an online dot. Also carries the
-- enabled-module count as a small badge instead of a bare line of text.
New("Frame", {
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, 12, 1, -12),
    Size = UDim2.new(1, -24, 0, 54),
    BackgroundColor3 = Theme.Card,
    BorderSizePixel = 0,
    Parent = Sidebar,
}, {
    Round(9),
    Stroke(Theme.Stroke, 1, 0.3),
    New("ImageLabel", {
        Position = UDim2.fromOffset(10, 10),
        Size = UDim2.fromOffset(34, 34),
        BackgroundColor3 = Theme.Track,
        BorderSizePixel = 0,
        Image = (function()
            local ok, url = pcall(function()
                return "rbxthumb://type=AvatarHeadShot&id=" .. tostring(LocalPlayer.UserId) .. "&w=150&h=150"
            end)
            return ok and url or ""
        end)(),
    }, { Round(10) }),
    New("Frame", {
        Position = UDim2.fromOffset(35, 35),
        Size = UDim2.fromOffset(10, 10),
        BackgroundColor3 = Theme.Good,
        BorderSizePixel = 0,
    }, { Round(5), Stroke(Theme.Card, 2) }),
    New("TextLabel", {
        Position = UDim2.fromOffset(54, 10),
        Size = UDim2.fromOffset(SIDEBAR_W - 90, 16),
        BackgroundTransparency = 1,
        Text = LocalPlayer.DisplayName,
        Font = FONT.Bold,
        TextSize = 12,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }),
    New("TextLabel", {
        Position = UDim2.fromOffset(54, 28),
        Size = UDim2.fromOffset(SIDEBAR_W - 90, 14),
        BackgroundTransparency = 1,
        Text = "@" .. LocalPlayer.Name,
        Font = FONT.Regular,
        TextSize = 11,
        TextColor3 = Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }),
})

-- Pages (module LIST column) --------------------------------------------
local Pages = New("Frame", {
    Name = "Pages",
    Position = UDim2.fromOffset(RIGHT_X, TOPBAR_H),
    Size = UDim2.fromOffset(LIST_W, WINDOW_H - TOPBAR_H - FOOTER_H),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
    Parent = UI.Main,
})

-- Detail panel (settings for whichever module is selected) --------------
-- A single shared panel, not one per module: each module's settings body is built once (same
-- Controls/host system as always) and lives in a hidden Storage frame until that module is
-- selected, at which point it's reparented in here. Nothing outside this block touches the
-- panel's pieces directly - everything else goes through UI.Detail.* or UI:SelectModule.
UI.Detail = {}
do
    local panel = New("Frame", {
        Name = "DetailPanel",
        Position = UDim2.fromOffset(RIGHT_X + LIST_W + 1, TOPBAR_H),
        Size = UDim2.fromOffset(CONTENT_W, WINDOW_H - TOPBAR_H - FOOTER_H),
        BackgroundTransparency = 1,
        ClipsDescendants = true,
        Parent = UI.Main,
    })
    New("Frame", {
        Size = UDim2.new(0, 1, 1, 0),
        BackgroundColor3 = Theme.Stroke,
        BackgroundTransparency = 0.4,
        BorderSizePixel = 0,
        Parent = panel,
    })

    local empty = New("TextLabel", {
        Position = UDim2.fromOffset(PAGE_PAD, 28),
        Size = UDim2.new(1, -(PAGE_PAD * 2), 0, 20),
        BackgroundTransparency = 1,
        Text = "Select a module on the left",
        Font = FONT.Regular,
        TextSize = 12,
        TextColor3 = Theme.TextFaint,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = panel,
    })

    local header = New("Frame", {
        Name = "Header",
        Position = UDim2.fromOffset(PAGE_PAD, 20),
        Size = UDim2.new(1, -(PAGE_PAD * 2), 0, 46),
        BackgroundTransparency = 1,
        Visible = false,
        Parent = panel,
    })
    local iconTile = New("Frame", {
        Size = UDim2.fromOffset(40, 40),
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Parent = header,
    }, { Round(10), Stroke(Theme.Stroke, 1, 0.3) })
    local iconGradient = New("UIGradient", {
        Rotation = 45,
        Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt),
        Parent = iconTile,
    })
    local iconGlyph = New("TextLabel", {
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        Text = "",
        Font = FONT.Medium,
        TextSize = 17,
        TextColor3 = Color3.new(1, 1, 1),
        Parent = iconTile,
    })
    local nameLabel = New("TextLabel", {
        Position = UDim2.fromOffset(52, 0),
        Size = UDim2.new(1, -(52 + 160), 0, 22),
        BackgroundTransparency = 1,
        Text = "",
        Font = FONT.Bold,
        TextSize = 16,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = header,
    })
    local descLabel = New("TextLabel", {
        Position = UDim2.fromOffset(52, 23),
        Size = UDim2.new(1, -(52 + 160), 0, 18),
        BackgroundTransparency = 1,
        Text = "",
        Font = FONT.Regular,
        TextSize = 11,
        TextColor3 = Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = header,
    })

    local switchTrack, setSwitch, switchClick = createSwitch(header, 46, 24)
    switchTrack.AnchorPoint = Vector2.new(1, 0)
    switchTrack.Position = UDim2.new(1, 0, 0, 1)

    local chipStroke = Stroke(Theme.Stroke, 1)
    local keyBox = New("TextButton", {
        Name = "KeyBind",
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, 0, 0, 29),
        Size = UDim2.fromOffset(76, 24),
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Text = "None",
        Font = FONT.Medium,
        TextSize = 11,
        TextColor3 = Theme.TextFaint,
        Parent = header,
    }, { Round(8), chipStroke })
    -- Tooltip attached below, once UI:AttachTip exists (this block runs before that's defined).

    local divider = New("Frame", {
        Position = UDim2.fromOffset(PAGE_PAD, 74),
        Size = UDim2.new(1, -(PAGE_PAD * 2), 0, 1),
        BackgroundColor3 = Theme.Stroke,
        BackgroundTransparency = 0.3,
        BorderSizePixel = 0,
        Visible = false,
        Parent = panel,
    })

    local scroller = New("ScrollingFrame", {
        Name = "Settings",
        Position = UDim2.fromOffset(0, 84),
        Size = UDim2.new(1, 0, 1, -84),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.Accent,
        ScrollBarImageTransparency = 0.25,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Visible = false,
        Parent = panel,
    })
    pcall(function()
        scroller.ElasticBehavior = Enum.ElasticBehavior.Never
    end)
    onTheme(function()
        scroller.ScrollBarImageColor3 = Theme.Accent
        iconGradient.Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt)
    end)
    scroller:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
        UI:CloseDropdown()
        UI:HideTip()
    end)

    -- Holds every module's settings content while it ISN'T the selected one - never rendered.
    local storage = New("Frame", { Name = "Storage", Visible = false, Parent = UI.Gui })

    UI.Detail.Panel, UI.Detail.Empty, UI.Detail.Header = panel, empty, header
    UI.Detail.IconGlyph, UI.Detail.NameLabel, UI.Detail.DescLabel = iconGlyph, nameLabel, descLabel
    UI.Detail.SetSwitch, UI.Detail.SwitchClick = setSwitch, switchClick
    UI.Detail.KeyBox, UI.Detail.ChipStroke = keyBox, chipStroke
    UI.Detail.Divider, UI.Detail.Scroller, UI.Detail.Storage = divider, scroller, storage

    -- The chip is shared across every module - its click/hover handlers read whichever module
    -- is currently selected instead of being baked into one module's closure.
    local lastChipClick = 0
    local function stopListening()
        if not UI.Detail.Listening then
            return
        end
        UI.Detail.Listening = false
        UI:StopKeyListen()
        chipStroke.Color = UI.Detail.ChipHover and Theme.StrokeHover or Theme.Stroke
        UI:RefreshDetailKey()
    end
    local function startListening()
        local mod = UI.SelectedModule
        if UI.Detail.Listening or not mod then
            return
        end
        UI.Detail.Listening = true
        keyBox.Text = "Click a key…"
        keyBox.TextColor3 = Theme.AccentLight
        chipStroke.Color = Theme.Accent
        UI:StartKeyListen({
            Cancel = stopListening,
            Apply = function(keyCode)
                local cfg = mod.Config
                if keyCode == Enum.KeyCode.RightShift then
                    Nova.Notify(mod.Name, "RightShift is reserved for the window", 3, "error")
                elseif keyCode.Name == cfg.Key then
                    cfg.Key = "None"
                    Nova.Notify(mod.Name, "Keybind cleared", 2)
                else
                    cfg.Key = keyCode.Name
                    Nova.Notify(mod.Name, "Bound to " .. keyText(keyCode.Name), 2)
                end
                stopListening()
            end,
        })
    end
    keyBox.MouseButton1Click:Connect(function()
        UI:HideTip()
        local now = os.clock()
        local isDouble = (now - lastChipClick) < 0.3
        lastChipClick = now
        local mod = UI.SelectedModule
        if isDouble then
            stopListening()
            if mod and mod.Config.Key ~= nil and mod.Config.Key ~= "None" then
                mod.Config.Key = "None"
                UI:RefreshDetailKey()
                Nova.Notify(mod.Name, "Keybind cleared", 2)
            end
        elseif UI.Detail.Listening then
            stopListening()
        else
            startListening()
        end
    end)
    keyBox.MouseEnter:Connect(function()
        UI.Detail.ChipHover = true
        if not UI.Detail.Listening then
            chipStroke.Color = Theme.StrokeHover
        end
    end)
    keyBox.MouseLeave:Connect(function()
        UI.Detail.ChipHover = false
        if not UI.Detail.Listening then
            chipStroke.Color = Theme.Stroke
        end
    end)
    switchClick.MouseButton1Click:Connect(function()
        if UI.SelectedModule then
            UI.SelectedModule:Toggle()
        end
    end)
end

-- Paints the shared keybind chip from whichever module is currently selected.
function UI:RefreshDetailKey()
    local mod = UI.SelectedModule
    if not mod or UI.Detail.Listening then
        return
    end
    local unbound = (mod.Config.Key == nil or mod.Config.Key == "None")
    UI.Detail.KeyBox.Text = keyText(mod.Config.Key)
    UI.Detail.KeyBox.TextColor3 = unbound and Theme.TextFaint or Theme.AccentLight
end

-- Shows `mod`'s settings in the detail panel, parking whichever module was shown before.
function UI:SelectModule(mod)
    if not mod or UI.SelectedModule == mod then
        return
    end
    local prev = UI.SelectedModule
    if prev then
        prev.Content.Parent = UI.Detail.Storage
        prev.Content.Visible = false
        if prev.PaintRow then
            prev.PaintRow(false)
        end
    end
    UI.SelectedModule = mod
    if mod.PaintRow then
        mod.PaintRow(false)
    end

    local d = UI.Detail
    d.Empty.Visible = false
    d.Header.Visible = true
    d.Divider.Visible = true
    d.Scroller.Visible = true
    d.IconGlyph.Text = (mod.Tab and mod.Tab.Icon) or "•"
    d.NameLabel.Text = mod.Name
    if mod.StatusText then
        d.DescLabel.Text = mod.StatusText
        d.DescLabel.TextColor3 = (mod.StatusKind == "error") and Theme.Bad or (mod.StatusKind == "warn" and Theme.Warn or Theme.AccentLight)
    else
        d.DescLabel.Text = (mod.Definition and mod.Definition.Description) or ""
        d.DescLabel.TextColor3 = Theme.TextDim
    end
    d.SetSwitch(mod.Enabled, true)
    UI:RefreshDetailKey()

    mod.Content.Parent = d.Scroller
    mod.Content.Visible = true
end

-- Footer status bar: a thin strip along the bottom of the content pane (RightShift hint, live
-- FPS). Everything it needs is scoped in here - nothing outside this block ever touches it.
do
    local footer = New("Frame", {
        Name = "Footer",
        Position = UDim2.fromOffset(RIGHT_X, WINDOW_H - FOOTER_H),
        Size = UDim2.fromOffset(RIGHT_W, FOOTER_H),
        BackgroundTransparency = 1,
        Parent = UI.Main,
    })
    New("Frame", {
        Size = UDim2.new(1, 0, 0, 1),
        BackgroundColor3 = Theme.Stroke,
        BackgroundTransparency = 0.4,
        BorderSizePixel = 0,
        Parent = footer,
    })
    local fpsLabel = New("TextLabel", {
        Position = UDim2.fromOffset(PAGE_PAD, 0),
        Size = UDim2.fromOffset(90, FOOTER_H),
        BackgroundTransparency = 1,
        Text = "-- FPS",
        Font = FONT.Medium,
        TextSize = 11,
        TextColor3 = Theme.TextFaint,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = footer,
    })
    New("TextLabel", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -PAGE_PAD, 0, 0),
        Size = UDim2.fromOffset(170, FOOTER_H),
        BackgroundTransparency = 1,
        Text = "RightShift to hide",
        Font = FONT.Medium,
        TextSize = 11,
        TextColor3 = Theme.TextFaint,
        TextXAlignment = Enum.TextXAlignment.Right,
        Parent = footer,
    })
    local frames, elapsed = 0, 0
    RunService.RenderStepped:Connect(function(dt)
        frames = frames + 1
        elapsed = elapsed + dt
        if elapsed >= 0.5 then
            fpsLabel.Text = tostring(math.floor(frames / elapsed + 0.5)) .. " FPS"
            frames, elapsed = 0, 0
        end
    end)
end

-- ---------------------------------------------------------------------
-- Tabs
-- ---------------------------------------------------------------------
function UI:SelectTab(selected)
    if not selected then
        return
    end
    UI:CloseDropdown()
    local instant = not TabIndicator.Visible
    for _, tab in ipairs(UI.TabList) do
        tab.Active = (tab == selected)
        tab.Page.Visible = tab.Active
        tab.Paint(instant)
    end
    TabIndicator.Visible = true
    local targetY = TAB.Y + (selected.Index - 1) * (TAB.H + TAB.GAP)
    Animate(TabIndicator, { Position = UDim2.fromOffset(TAB.X, targetY) }, instant, 0.22, Enum.EasingStyle.Quint)
    UI.CurrentTab = selected
    UI.TitleLabel.Text = selected.Name
    UI.SubtitleLabel.Text = selected.Subtitle or ""
    -- Jump the detail panel to this tab's first module unless it's already showing one of
    -- this tab's own modules (keeps whatever was selected while you're still on its tab).
    if (not UI.SelectedModule or UI.SelectedModule.Tab ~= selected) and selected.Modules[1] then
        UI:SelectModule(selected.Modules[1])
    end
end

function UI:CreateTab(name, subtitle, icon)
    local tab = { Name = name, Subtitle = subtitle, Icon = icon, Modules = {}, Active = false, Matches = 0, Index = #UI.TabList + 1 }

    tab.Button = New("TextButton", {
        Name = name,
        Size = UDim2.new(1, 0, 0, TAB.H),
        BackgroundColor3 = Theme.Card,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        LayoutOrder = #UI.TabList + 1,
        Parent = TabHolder,
    }, { Round(9) })

    local tabIcon = New("TextLabel", {
        Position = UDim2.fromOffset(10, 0),
        Size = UDim2.fromOffset(22, TAB.H),
        BackgroundTransparency = 1,
        Text = icon or "•",
        Font = FONT.Medium,
        TextSize = 13,
        TextColor3 = Theme.TextDim,
        ZIndex = 1,
        Parent = tab.Button,
    })

    tab.Label = New("TextLabel", {
        Position = UDim2.fromOffset(36, 0),
        Size = UDim2.new(1, -66, 1, 0),
        BackgroundTransparency = 1,
        Text = name,
        Font = FONT.Medium,
        TextSize = 13,
        TextColor3 = Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 1,
        Parent = tab.Button,
    })

    tab.CountLabel = New("TextLabel", {
        AnchorPoint = Vector2.new(1, 0.5),
        Position = UDim2.new(1, -12, 0.5, 0),
        Size = UDim2.fromOffset(20, 16),
        BackgroundTransparency = 1,
        Text = "0",
        Font = FONT.Medium,
        TextSize = 11,
        TextColor3 = Theme.TextFaint,
        TextXAlignment = Enum.TextXAlignment.Right,
        ZIndex = 1,
        Parent = tab.Button,
    })

    tab.Hovered = false
    tab.Paint = function(instant)
        local active = tab.Active
        Animate(tab.Button, { BackgroundTransparency = (not active and tab.Hovered) and 0.6 or 1 }, instant, 0.15)
        local fg = active and Color3.new(1, 1, 1) or (tab.Hovered and Theme.Text or Theme.TextDim)
        Animate(tab.Label, { TextColor3 = fg }, instant, 0.15)
        Animate(tabIcon, { TextColor3 = active and Theme.AccentLight or Theme.TextFaint }, instant, 0.15)
        Animate(tab.CountLabel, { TextColor3 = active and Theme.TextDim or Theme.TextFaint }, instant, 0.15)
        tab.Label.Font = active and FONT.Bold or FONT.Medium
    end
    onTheme(function()
        tab.Paint(true)
    end)

    tab.Button.MouseEnter:Connect(function()
        tab.Hovered = true
        tab.Paint(false)
    end)
    tab.Button.MouseLeave:Connect(function()
        tab.Hovered = false
        tab.Paint(false)
    end)

    tab.Page = New("ScrollingFrame", {
        Name = name .. "Page",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.Accent,
        ScrollBarImageTransparency = 0.25,
        ScrollingDirection = Enum.ScrollingDirection.Y,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Visible = false,
        Parent = Pages,
    }, {
        New("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
        Pad(PAGE_PAD, 6, PAGE_PAD, 20),
    })
    pcall(function()
        tab.Page.ElasticBehavior = Enum.ElasticBehavior.Never
    end)
    onTheme(function()
        tab.Page.ScrollBarImageColor3 = Theme.Accent
    end)
    tab.Page:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
        UI:CloseDropdown()
        UI:HideTip()
    end)

    tab.Empty = New("TextLabel", {
        Size = UDim2.new(1, 0, 0, 80),
        BackgroundTransparency = 1,
        Text = "",
        Font = FONT.Regular,
        TextSize = 12,
        TextColor3 = Theme.TextDim,
        LayoutOrder = 100000,
        Visible = false,
        Parent = tab.Page,
    })

    tab.Button.MouseButton1Click:Connect(function()
        UI:SelectTab(tab)
    end)

    -- Dim info card (used for "more coming soon" placeholders)
    function tab:CreatePlaceholder(text)
        tab.Placeholder = New("TextLabel", {
            Size = UDim2.new(1, 0, 0, 44),
            BackgroundColor3 = Theme.Card,
            BackgroundTransparency = 0.55,
            Text = text,
            Font = FONT.Regular,
            TextSize = 12,
            TextColor3 = Theme.TextFaint,
            LayoutOrder = 99999,
            Parent = tab.Page,
        }, { Round(8), Stroke(Theme.Stroke, 1, 0.4) })
    end

    -- ---------------------------------------------------------------
    -- Module card
    -- ---------------------------------------------------------------
    function tab:CreateModule(def)
        local mod = {
            Name = def.Name,
            Enabled = false,
            Tab = tab,
            Maid = Maid.new(),
            Definition = def,
            SearchText = string.lower(def.Name .. " " .. (def.Description or "")),
        }

        Nova.Config[def.Name] = Nova.Config[def.Name] or {}
        local cfg = Nova.Config[def.Name]
        mod.Config = cfg
        if cfg.Key == nil then
            cfg.Key = def.Key or "None"
        end
        function mod.SetKey(name)
            cfg.Key = name or "None"
            if UI.SelectedModule == mod then
                UI:RefreshDetailKey()
            end
        end

        local hovered = false

        -- Row (module list) -------------------------------------------------------------
        local cardStroke = Stroke(Theme.Stroke, 1, 1)
        local card = New("Frame", {
            Name = def.Name,
            Size = UDim2.new(1, 0, 0, HEADER_H),
            BackgroundColor3 = Theme.Card,
            BorderSizePixel = 0,
            LayoutOrder = #tab.Modules + 1,
            Parent = tab.Page,
        }, { Round(10), cardStroke })
        mod.Card = card

        -- A soft corner glow instead of a flat tint or a bar: a diagonal wash of accent colour
        -- that fades out across the card, switched on only while the module is enabled.
        local cardGlow = New("UIGradient", {
            Rotation = 115,
            Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt),
            Transparency = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0.74),
                NumberSequenceKeypoint.new(0.55, 0.97),
                NumberSequenceKeypoint.new(1, 1),
            }),
            Enabled = false,
            Parent = card,
        })
        onTheme(function()
            cardGlow.Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt)
        end)
        -- Slim accent bar on the card's left edge: the one clear "on / selected" marker.
        local cardBar = New("Frame", {
            AnchorPoint = Vector2.new(0, 0.5),
            Position = UDim2.new(0, 0, 0.5, 0),
            Size = UDim2.fromOffset(3, 26),
            BackgroundColor3 = Theme.Accent,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ZIndex = 2,
            Parent = card,
        }, { Round(2) })
        onTheme(function()
            cardBar.BackgroundColor3 = Theme.Accent
        end)

        local headerButton = New("TextButton", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Text = "",
            Parent = card,
        })

        -- Icon tile: carries this module's TAB icon (not per-module letters), filled with the
        -- accent gradient while the module is on and a plain outline while it's off.
        local iconTile = New("Frame", {
            Position = UDim2.fromOffset(12, (HEADER_H - 26) / 2),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Panel,
            BorderSizePixel = 0,
            Parent = headerButton,
        }, { Round(8), Stroke(Theme.Stroke, 1, 0.3) })
        local iconGradient = New("UIGradient", {
            Rotation = 45,
            Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt),
            Enabled = false,
            Parent = iconTile,
        })
        local iconGlyph = New("TextLabel", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Text = tab.Icon or "•",
            Font = FONT.Medium,
            TextSize = 13,
            TextColor3 = Theme.TextDim,
            Parent = iconTile,
        })
        onTheme(function()
            iconGradient.Color = ColorSequence.new(Theme.Accent, Theme.AccentAlt)
        end)

        local textInset = 50
        local rightReserve = 14 + 42 + 10
        New("TextLabel", {
            Position = UDim2.fromOffset(textInset, 14),
            Size = UDim2.new(1, -(textInset + rightReserve), 0, 18),
            BackgroundTransparency = 1,
            Text = def.Name,
            Font = FONT.Medium,
            TextSize = 14,
            TextColor3 = Theme.Text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = headerButton,
        })
        local descLabel = New("TextLabel", {
            Position = UDim2.fromOffset(textInset, 34),
            Size = UDim2.new(1, -(textInset + rightReserve), 0, 16),
            BackgroundTransparency = 1,
            Text = def.Description or "",
            Font = FONT.Regular,
            TextSize = 11,
            TextColor3 = Theme.TextDim,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = headerButton,
        })

        -- Master switch (the row's own - the detail panel has a second one that mirrors it)
        local switchTrack, setSwitch, switchClick = createSwitch(card, 42, 22)
        switchTrack.AnchorPoint = Vector2.new(1, 0.5)
        switchTrack.Position = UDim2.new(1, -14, 0.5, 0)
        switchTrack.ZIndex = 2
        switchClick.ZIndex = 3

        local function paintRow(instant)
            local selected = (UI.SelectedModule == mod)
            local bg = Theme.Card
            if selected then
                bg = Theme.Card:Lerp(Theme.Accent, 0.1)
            elseif hovered then
                bg = Theme.Card:Lerp(Theme.Text, 0.035)
            end
            Animate(card, { BackgroundColor3 = bg }, instant, 0.12)
            -- a clear glowing outline while selected or on - the corner wash carries the rest
            local strokeColor = (selected or mod.Enabled) and Theme.Accent or Theme.Stroke
            local strokeTrans = selected and 0.45 or (mod.Enabled and (hovered and 0.55 or 0.7) or 1)
            Animate(cardStroke, { Color = strokeColor, Transparency = strokeTrans }, instant, 0.15)
            cardGlow.Enabled = false
            Animate(cardBar, { BackgroundTransparency = (selected or mod.Enabled) and 0 or 1 }, instant, 0.15)
            iconGradient.Enabled = mod.Enabled
            Animate(iconGlyph, { TextColor3 = mod.Enabled and Color3.new(1, 1, 1) or Theme.TextDim }, instant, 0.15)
        end
        mod.PaintRow = paintRow
        onTheme(function()
            paintRow(true)
        end)

        -- Settings content - built once here (same Controls/host system as always). It lives in
        -- the shared hidden Storage frame until this module is the one selected in the detail
        -- panel, at which point UI:SelectModule reparents it there.
        local content = New("Frame", {
            Name = "Content",
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Parent = UI.Detail.Storage,
        }, {
            New("UIListLayout", { Padding = UDim.new(0, ROW_GAP), SortOrder = Enum.SortOrder.LayoutOrder }),
            Pad(BODY_PAD, BODY_TOP, BODY_PAD, BODY_BOTTOM),
        })
        mod.Content = content

        local host = newHost(content, cfg, nil)
        host.InnerWidth = BODY_INNER_W
        mod.Host = host

        local function ensureFooter()
            if host.FooterRow then
                return
            end
            local frame = New("Frame", {
                Size = UDim2.new(1, 0, 0, 30),
                BackgroundTransparency = 1,
                LayoutOrder = 100000,
                Parent = content,
            })
            host.FooterRow = { Frame = frame, Height = 30 }
            local reset = makeButton(frame, "Reset to defaults", "ghost", UDim2.fromOffset(130, 26))
            reset.AnchorPoint = Vector2.new(1, 0.5)
            reset.Position = UDim2.new(1, 0, 0.5, 0)
            reset.TextSize = 11
            reset.MouseButton1Click:Connect(function()
                mod:ResetDefaults()
            end)
        end

        function mod:ResetDefaults()
            for _, handle in ipairs(host.ControlList) do
                pcall(handle.Set, handle.Default, true)
                if handle.Callback then
                    pcall(handle.Callback, cfg[handle.Key])
                end
            end
            host:RefreshVisibility()
            Nova.Notify(def.Name, "Settings reset to defaults", 2)
        end

        -- One-line status (explains why a module failed to start) - shown under its name in the
        -- row, and synced live into the detail panel header when this module is selected.
        function mod:SetStatus(text, kind)
            mod.StatusText, mod.StatusKind = text, kind
            if text and text ~= "" then
                descLabel.Text = text
                descLabel.TextColor3 = (kind == "error") and Theme.Bad or (kind == "warn" and Theme.Warn or Theme.AccentLight)
            else
                mod.StatusText, mod.StatusKind = nil, nil
                descLabel.Text = def.Description or ""
                descLabel.TextColor3 = Theme.TextDim
            end
            if UI.SelectedModule == mod then
                UI.Detail.DescLabel.Text = descLabel.Text
                UI.Detail.DescLabel.TextColor3 = descLabel.TextColor3
            end
        end
        onTheme(function()
            mod:SetStatus(mod.StatusText, mod.StatusKind)
        end)

        headerButton.MouseEnter:Connect(function()
            hovered = true
            paintRow(false)
        end)
        headerButton.MouseLeave:Connect(function()
            hovered = false
            paintRow(false)
        end)
        headerButton.MouseButton1Click:Connect(function()
            UI:SelectModule(mod)
        end)
        headerButton.MouseButton2Click:Connect(function()
            mod:Toggle()
        end)
        UI:AttachTip(headerButton, function()
            if mod.StatusKind == "error" and mod.StatusText then
                return mod.StatusText .. "  (click to retry after fixing it)"
            end
            return "Click to view settings. Right-click to toggle."
        end)

        -- Controls --------------------------------------------------
        local function register(label)
            if label then
                mod.SearchText = mod.SearchText .. " " .. string.lower(label)
            end
            ensureFooter()
        end

        function mod:AddSection(title)
            register(nil)
            Controls.Section(host, title)
            host:RefreshVisibility()
        end

        function mod:AddToggle(o)
            register(o.Label)
            local handle = Controls.Toggle(host, o)
            host:RefreshVisibility()
            return handle
        end

        function mod:AddSlider(o)
            register(o.Label)
            local handle = Controls.Slider(host, o)
            host:RefreshVisibility()
            return handle
        end

        function mod:AddOption(o)
            register(o.Label)
            local handle = Controls.Option(host, o)
            host:RefreshVisibility()
            return handle
        end

        function mod:AddTextBox(o)
            register(o.Label)
            local handle = Controls.TextBox(host, o)
            host:RefreshVisibility()
            return handle
        end

        function mod:AddButton(o)
            register(o.Label)
            Controls.Button(host, o)
            host:RefreshVisibility()
        end

        function mod:AddLabel(text, o)
            register(nil)
            Controls.Note(host, text, o)
            host:RefreshVisibility()
        end
        mod.AddNote = mod.AddLabel

        -- Enable / disable ------------------------------------------
        function mod:SetEnabled(state, silent)
            state = state and true or false
            if state == self.Enabled then
                return
            end

            if state then
                self.Enabled = true
                self.Maid = Maid.new()
                local ok, err = pcall(def.OnEnable, self)
                if not ok then
                    self.Enabled = false
                    self.Maid:Clean()
                    local reason = tostring(err)
                    -- "file.lua:123: message" -> "message"
                    for _ = 1, 3 do
                        reason = string.gsub(reason, "^[%w_%.%[%]\" ]-:%d+: ", "")
                    end
                    if not silent then
                        Nova.Notify(def.Name, string.sub(reason, 1, 90), 4, "error", true)
                    end
                    self:SetStatus("Couldn't start: " .. reason, "error")
                    setSwitch(false, true)
                    if UI.SelectedModule == mod then
                        UI.Detail.SetSwitch(false, true)
                    end
                    paintRow(false)
                    cardStroke.Color = Theme.Bad
                    cardStroke.Transparency = 0.2
                    task.delay(1.4, function()
                        if card.Parent then
                            paintRow(false)
                        end
                    end)
                    UI:RefreshCounts()
                    return
                end
                self:SetStatus(nil)
            else
                self:SetStatus(nil)
                self.Enabled = false
                if def.OnDisable then
                    pcall(def.OnDisable, self)
                end
                self.Maid:Clean()
            end

            setSwitch(self.Enabled, silent)
            if UI.SelectedModule == mod then
                UI.Detail.SetSwitch(self.Enabled, silent)
            end
            paintRow(silent)
            UI:RefreshCounts()
            if UI.OnlyActive and UI.ApplySearch then
                UI:ApplySearch(UI.Query)
            end
            if UI.RefreshHud then
                UI:RefreshHud()
            end
            if not silent then
                Nova.Notify(def.Name, self.Enabled and "On" or "Off", 1.8, self.Enabled and "success" or "info")
            end
        end

        function mod:Toggle()
            self:SetEnabled(not self.Enabled)
        end

        switchClick.MouseButton1Click:Connect(function()
            UI:SelectModule(mod)
            mod:Toggle()
        end)

        setSwitch(false, true)
        paintRow(true)
        tab.Modules[#tab.Modules + 1] = mod
        tab.CountLabel.Text = tostring(#tab.Modules)
        Nova.ModuleList[#Nova.ModuleList + 1] = mod
        UI:RefreshCounts()
        return mod
    end

    UI.Tabs[name] = tab
    UI.TabList[#UI.TabList + 1] = tab
    return tab
end

-- Left in as a no-op call target: other code still calls UI:RefreshCounts() whenever a module
-- toggles, and that's harmless to keep even though nothing in the UI displays the count anymore.
function UI:RefreshCounts()
end

function UI:ApplySearch(query)
    query = string.lower(tostring(query or ""))
    query = string.gsub(query, "^%s+", "")
    query = string.gsub(query, "%s+$", "")
    UI.Query = query
    local onlyActive = UI.OnlyActive == true
    local filterKey = query .. (onlyActive and "|active" or "")
    local filterChanged = (UI.LastFilterKey ~= filterKey)
    UI.LastFilterKey = filterKey

    local firstMatch
    for _, tab in ipairs(UI.TabList) do
        local matches = 0
        for _, mod in ipairs(tab.Modules) do
            local show = (query == "") or (string.find(mod.SearchText, query, 1, true) ~= nil)
            if show and onlyActive and not mod.Enabled then
                show = false
            end
            mod.Card.Visible = show
            if show then
                matches = matches + 1
            end
        end
        tab.Matches = matches
        local filtering = (query ~= "" or onlyActive)
        local message = ""
        if filtering and matches == 0 then
            if query ~= "" then
                message = 'No ' .. (onlyActive and "active " or "") .. 'modules match "' .. query .. '"'
            else
                message = "Nothing is switched on in this tab"
            end
        end
        tab.Empty.Text = message
        tab.Empty.Visible = (message ~= "")
        if tab.Placeholder then
            tab.Placeholder.Visible = not filtering
        end
        if matches > 0 and not firstMatch then
            firstMatch = tab
        end
    end
    -- jump to a tab that actually has results (only when the filter itself changed)
    if filterChanged and (query ~= "" or onlyActive) and UI.CurrentTab and UI.CurrentTab.Matches == 0 and firstMatch then
        UI:SelectTab(firstMatch)
    end
    UI:RefreshCounts()
end

-- ---------------------------------------------------------------------
-- Tooltips
-- ---------------------------------------------------------------------
local TipFrame = New("Frame", {
    Name = "Tooltip",
    Size = UDim2.fromOffset(100, 30),
    BackgroundColor3 = Theme.Card:Lerp(Theme.Text, 0.06),
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 90,
    Parent = UI.Main,
}, { Round(9), Stroke(Theme.StrokeHover, 1) })
local TipLabel = New("TextLabel", {
    Position = UDim2.fromOffset(10, 6),
    Size = UDim2.new(1, -20, 1, -12),
    BackgroundTransparency = 1,
    Text = "",
    Font = FONT.Regular,
    TextSize = 11,
    TextColor3 = Theme.Text,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Top,
    ZIndex = 91,
    Parent = TipFrame,
})

function UI:HideTip()
    UI.TipToken = (UI.TipToken or 0) + 1
    TipFrame.Visible = false
end

function UI:ShowTip(text)
    if not text or text == "" then
        return
    end
    local size = measure(text, 11, FONT.Regular, 230)
    local width = math.min(math.ceil(size.X) + 22, 252)
    local height = math.ceil(size.Y) + 14
    local mouse = UserInputService:GetMouseLocation()
    local scale = math.max(UI.Scale.Scale, 0.1)
    local origin = UI.Main.AbsolutePosition
    local x = (mouse.X - origin.X) / scale + 14
    local y = (mouse.Y - origin.Y) / scale + 20
    x = math.clamp(x, 8, WINDOW_W - width - 8)
    if y + height > WINDOW_H - 8 then
        y = (mouse.Y - origin.Y) / scale - height - 10
    end
    TipFrame.Size = UDim2.fromOffset(width, height)
    TipFrame.Position = UDim2.fromOffset(x, math.max(y, 6))
    TipLabel.Text = text
    TipFrame.Visible = true
end

-- `text` can be a string or a function returning one
function UI:AttachTip(obj, text)
    if not obj or text == nil or text == "" then
        return
    end
    obj.MouseEnter:Connect(function()
        UI.TipToken = (UI.TipToken or 0) + 1
        local mine = UI.TipToken
        task.delay(0.55, function()
            if mine == UI.TipToken and UI.Visible and not Nova.Unloaded and not UI.ActiveDrag then
                local value = text
                if type(text) == "function" then
                    local ok, result = pcall(text)
                    value = ok and result or nil
                end
                UI:ShowTip(value)
            end
        end)
    end)
    obj.MouseLeave:Connect(function()
        UI:HideTip()
    end)
end

UI:AttachTip(UI.Detail.KeyBox, function()
    if UI.Detail.Listening then
        return "Press any key to bind it. Press the current key again to clear it. Esc cancels."
    end
    return "Keybind. Click, then press a key. Double-click to clear."
end)

-- ---------------------------------------------------------------------
-- Dropdown overlay
-- ---------------------------------------------------------------------
local DROP_ITEM_H, DROP_MAX_ROWS = 28, 7

UI.DropdownCatcher = New("TextButton", {
    Name = "DropdownCatcher",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Text = "",
    AutoButtonColor = false,
    Visible = false,
    ZIndex = 60,
    Parent = UI.Main,
})
UI.DropdownFrame = New("Frame", {
    Name = "Dropdown",
    Size = UDim2.fromOffset(140, 100),
    BackgroundColor3 = Theme.Card:Lerp(Theme.Text, 0.04),
    BorderSizePixel = 0,
    ClipsDescendants = true,
    Visible = false,
    ZIndex = 61,
    Parent = UI.Main,
}, { Round(8), Stroke(Theme.StrokeHover, 1) })
local DropList = New("ScrollingFrame", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = Theme.Accent,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ZIndex = 62,
    Parent = UI.DropdownFrame,
}, {
    New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
    Pad(4, 4, 4, 4),
})

function UI:CloseDropdown()
    UI.DropdownCatcher.Visible = false
    UI.DropdownFrame.Visible = false
    UI.DropdownAnchor = nil
end

function UI:OpenDropdown(anchor, list, current, onSelect)
    UI:CloseDropdown()
    UI:HideTip()
    for _, child in ipairs(DropList:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    local scale = math.max(UI.Scale.Scale, 0.1)
    local origin = UI.Main.AbsolutePosition
    local anchorW = anchor.AbsoluteSize.X / scale
    local anchorH = anchor.AbsoluteSize.Y / scale
    local anchorX = (anchor.AbsolutePosition.X - origin.X) / scale
    local anchorY = (anchor.AbsolutePosition.Y - origin.Y) / scale

    local rows = math.min(#list, DROP_MAX_ROWS)
    local height = rows * DROP_ITEM_H + 8
    local width = math.max(anchorW, 130)
    local x = math.clamp(anchorX + anchorW - width, 8, WINDOW_W - width - 8)
    local y = anchorY + anchorH + 4
    if y + height > WINDOW_H - FOOTER_H then
        y = anchorY - height - 4
    end

    for index, item in ipairs(list) do
        local selected = (item == current)
        local button = New("TextButton", {
            Size = UDim2.new(1, 0, 0, DROP_ITEM_H),
            BackgroundColor3 = Theme.Accent,
            BackgroundTransparency = selected and 0.85 or 1,
            AutoButtonColor = false,
            Text = "",
            LayoutOrder = index,
            ZIndex = 63,
            Parent = DropList,
        }, { Round(7) })
        New("TextLabel", {
            Position = UDim2.fromOffset(10, 0),
            Size = UDim2.new(1, -30, 1, 0),
            BackgroundTransparency = 1,
            Text = tostring(item),
            Font = FONT.Medium,
            TextSize = 12,
            TextColor3 = selected and Theme.AccentLight or Theme.Text,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            ZIndex = 64,
            Parent = button,
        })
        if selected then
            New("Frame", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, -10, 0.5, 0),
                Size = UDim2.fromOffset(6, 6),
                BackgroundColor3 = Theme.AccentLight,
                BorderSizePixel = 0,
                ZIndex = 64,
                Parent = button,
            }, { Round(3) })
        end
        button.MouseEnter:Connect(function()
            if not selected then
                Tween(button, 0.1, { BackgroundTransparency = 0.9 })
            end
        end)
        button.MouseLeave:Connect(function()
            if not selected then
                Tween(button, 0.1, { BackgroundTransparency = 1 })
            end
        end)
        button.MouseButton1Click:Connect(function()
            UI:CloseDropdown()
            onSelect(item)
        end)
    end

    DropList.CanvasPosition = Vector2.new(0, 0)
    UI.DropdownAnchor = anchor
    UI.DropdownFrame.Position = UDim2.fromOffset(x, y)
    UI.DropdownFrame.Size = UDim2.fromOffset(width, height * 0.7)
    UI.DropdownCatcher.Visible = true
    UI.DropdownFrame.Visible = true
    Tween(UI.DropdownFrame, 0.14, { Size = UDim2.fromOffset(width, height) }, Enum.EasingStyle.Quint)
end

UI.DropdownCatcher.MouseButton1Click:Connect(function()
    UI:CloseDropdown()
end)
UI.DropdownCatcher.MouseButton2Click:Connect(function()
    UI:CloseDropdown()
end)

-- ---------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------
-- Nova.Notify is a field on the already-shared Nova table, so it stays callable from anywhere
-- even though everything it depends on here is scoped to this block.
do
local NotifHolder = New("Frame", {
    Name = "Notifications",
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -18, 1, -18),
    Size = UDim2.fromOffset(280, 600),
    BackgroundTransparency = 1,
    Parent = UI.Gui,
}, {
    New("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 6),
    }),
})

local notifCounter = 0
local activeNotifs = {}
local NOTIF_W = 280
local MAX_NOTIFS = 4

local function richEscape(text)
    text = string.gsub(text, "&", "&amp;")
    text = string.gsub(text, "<", "&lt;")
    text = string.gsub(text, ">", "&gt;")
    return text
end

local function hex(color)
    return string.format("#%02X%02X%02X",
        math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
end

-- kind: "info" (default) | "success" | "error" | "warn".  `force` ignores the Notifications toggle.
-- Short messages (module on/off, saved, ...) become a single slim line; longer ones get a second line.
function Nova.Notify(title, text, duration, kind, force)
    if Nova.Unloaded then
        return
    end
    if not force and not Nova.Config.UI.Notifications then
        return
    end

    notifCounter = notifCounter + 1
    duration = duration or 3
    local accent = Theme.Accent
    if kind == "success" then
        accent = Theme.Good
    elseif kind == "error" then
        accent = Theme.Bad
    elseif kind == "warn" then
        accent = Theme.Warn
    end

    title, text = tostring(title), tostring(text or "")

    -- The same message again: replace the old toast and count the repeats instead of stacking copies
    local noteKey = title .. "\n" .. text
    local repeats = 1
    for index = #activeNotifs, 1, -1 do
        local old = activeNotifs[index]
        if old.Key == noteKey then
            repeats = (old.Repeats or 1) + 1
            old.Dismiss(true)
            break
        end
    end

    local inline = text == "" or (#text <= 22 and not string.find(text, "\n"))
    local textHeight = 0
    local height = 36
    if not inline then
        textHeight = math.ceil(measure(text, 12, FONT.Regular, NOTIF_W - 44).Y)
        height = 14 + 18 + 3 + textHeight + 10
    end

    -- Cap the stack: dismiss the oldest when there are too many
    while #activeNotifs >= MAX_NOTIFS do
        local oldest = table.remove(activeNotifs, 1)
        if oldest then
            oldest.Dismiss(true)
        end
    end

    local wrap = New("Frame", {
        Size = UDim2.fromOffset(NOTIF_W, height),
        BackgroundTransparency = 1,
        LayoutOrder = notifCounter,
        Parent = NotifHolder,
    })
    local card = New("TextButton", {
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.new(1, NOTIF_W + 30, 0, 0),
        BackgroundColor3 = Theme.Card,
        BackgroundTransparency = 0.04,
        BorderSizePixel = 0,
        AutoButtonColor = false,
        Text = "",
        ClipsDescendants = true,
        Parent = wrap,
    }, { Round(8), Stroke(Theme.Stroke, 1) })

    -- Slim status dot instead of a boxed icon
    New("Frame", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 14, 0, inline and height / 2 or 21),
        Size = UDim2.fromOffset(7, 7),
        BackgroundColor3 = accent,
        BorderSizePixel = 0,
        Parent = card,
    }, { Round(4) })

    local titleText = richEscape(title)
    if repeats > 1 then
        titleText = titleText .. ' <font color="' .. hex(Theme.TextFaint) .. '">x' .. repeats .. "</font>"
    end
    if inline and text ~= "" then
        titleText = titleText .. '   <font color="' .. hex(Theme.TextDim) .. '">' .. richEscape(text) .. "</font>"
    end
    New("TextLabel", {
        Position = UDim2.fromOffset(30, inline and 0 or 12),
        Size = UDim2.new(1, -42, 0, inline and height or 18),
        BackgroundTransparency = 1,
        Text = titleText,
        RichText = true,
        Font = FONT.Bold,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = card,
    })
    if not inline then
        New("TextLabel", {
            Position = UDim2.fromOffset(30, 33),
            Size = UDim2.new(1, -42, 0, textHeight),
            BackgroundTransparency = 1,
            Text = text,
            Font = FONT.Regular,
            TextSize = 12,
            TextColor3 = Theme.TextDim,
            TextWrapped = true,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Top,
            Parent = card,
        })
    end
    local bar = New("Frame", {
        AnchorPoint = Vector2.new(0, 1),
        Position = UDim2.new(0, 0, 1, 0),
        Size = UDim2.new(1, 0, 0, 2),
        BackgroundColor3 = accent,
        BackgroundTransparency = 0.55,
        BorderSizePixel = 0,
        Parent = card,
    })

    local entry = { Dismissed = false, Key = noteKey, Repeats = repeats, Hovered = false }
    function entry.Dismiss(fast)
        if entry.Dismissed then
            return
        end
        entry.Dismissed = true
        local index = table.find(activeNotifs, entry)
        if index then
            table.remove(activeNotifs, index)
        end
        task.spawn(function()
            pcall(function()
                local slide = fast == true and 0.12 or 0.26
                Tween(card, slide, { Position = UDim2.new(1, NOTIF_W + 30, 0, 0) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
                task.wait(slide)
                Tween(wrap, 0.14, { Size = UDim2.fromOffset(NOTIF_W, 0) })
                task.wait(0.14)
                wrap:Destroy()
            end)
        end)
    end
    card.MouseButton1Click:Connect(function()
        entry.Dismiss()
    end)
    -- Hovering a toast holds it on screen so it can be read
    card.MouseEnter:Connect(function()
        entry.Hovered = true
    end)
    card.MouseLeave:Connect(function()
        entry.Hovered = false
    end)
    activeNotifs[#activeNotifs + 1] = entry

    task.spawn(function()
        pcall(function()
            Tween(card, 0.4, { Position = UDim2.new(0, 0, 0, 0) }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
            local elapsed = 0
            while elapsed < duration and not entry.Dismissed and not Nova.Unloaded do
                local dt = task.wait(0.05)
                if type(dt) ~= "number" then
                    dt = 0.05
                end
                if not entry.Hovered then
                    elapsed = elapsed + dt
                end
                bar.Size = UDim2.new(math.max(0, 1 - elapsed / duration), 0, 0, 2)
            end
            entry.Dismiss()
        end)
    end)
end
end

-- ---------------------------------------------------------------------
-- Module list (HUD)
-- ---------------------------------------------------------------------
local ModuleHud = New("Frame", {
    Name = "ModuleList",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -14, 0, 14),
    Size = UDim2.fromOffset(240, 400),
    BackgroundTransparency = 1,
    Visible = false,
    Parent = UI.Gui,
}, {
    New("UIListLayout", {
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 4),
    }),
})

function UI:RefreshHud()
    if Nova.Unloaded then
        return
    end
    for _, child in ipairs(ModuleHud:GetChildren()) do
        if child:IsA("GuiObject") then
            child:Destroy()
        end
    end
    local show = Nova.Config.UI.ShowList and true or false
    ModuleHud.Visible = show
    if not show then
        return
    end
    local names = {}
    for _, mod in ipairs(Nova.ModuleList) do
        if mod.Enabled then
            names[#names + 1] = { Name = mod.Name, Width = measure(mod.Name, 12, FONT.Medium).X }
        end
    end
    table.sort(names, function(a, b)
        return a.Width > b.Width
    end)
    for index, item in ipairs(names) do
        local label = New("TextLabel", {
            Size = UDim2.fromOffset(item.Width + 26, 22),
            BackgroundColor3 = Theme.Card,
            BackgroundTransparency = 0.12,
            BorderSizePixel = 0,
            Text = item.Name,
            Font = FONT.Medium,
            TextSize = 12,
            TextColor3 = Theme.Text,
            TextXAlignment = Enum.TextXAlignment.Left,
            LayoutOrder = index,
            Parent = ModuleHud,
        }, { Round(7), Pad(10, 0, 0, 0) })
        New("Frame", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, 0, 0.5, 0),
            Size = UDim2.fromOffset(3, 12),
            BackgroundColor3 = Theme.Accent,
            BorderSizePixel = 0,
            Parent = label,
        }, { Round(2) })
    end
end
onTheme(function()
    if UI.RefreshHud and #Nova.ModuleList > 0 then
        UI:RefreshHud()
    end
end)

-- ---------------------------------------------------------------------
-- Config save / load (manual, needs executor file access)
-- ---------------------------------------------------------------------
Nova.UI = UI
local CONFIG_DIR, CONFIG_FILE = "Nova", "Nova/config.json"

-- A profile name maps to a file. "default" is the original Nova/config.json.
local function profilePath(name)
    local clean = string.gsub(tostring(name or ""), "[^%w_%-]", "")
    if clean == "" or string.lower(clean) == "default" then
        return CONFIG_FILE, "default"
    end
    return CONFIG_DIR .. "/" .. clean .. ".json", clean
end
Nova.ProfilePath = profilePath

-- Turns the config into something JSONEncode accepts: plain values only, no NaN / functions / Instances
local function sanitize(value, depth)
    local kind = type(value)
    if kind == "string" or kind == "boolean" then
        return value
    elseif kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return nil
        end
        return value
    elseif kind == "table" and depth < 6 then
        local out = {}
        for key, inner in pairs(value) do
            local cleaned = sanitize(inner, depth + 1)
            if cleaned ~= nil and (type(key) == "string" or type(key) == "number") then
                out[tostring(key)] = cleaned
            end
        end
        return out
    end
    return nil
end

-- Remembers what is on screen right now (enabled modules, tab, selected module, window position)
function Nova.CaptureState()
    local state = { Enabled = {} }
    for _, mod in ipairs(Nova.ModuleList) do
        if mod.Enabled or (Nova.Wanted and Nova.Wanted[mod.Name]) then
            state.Enabled[mod.Name] = true
        end
    end
    if UI.CurrentTab then
        state.Tab = UI.CurrentTab.Name
    end
    if UI.SelectedModule then
        state.Selected = UI.SelectedModule.Name
    end
    local pos = UI.Holder and UI.Holder.Position
    if pos then
        state.Window = { xs = pos.X.Scale, xo = pos.X.Offset, ys = pos.Y.Scale, yo = pos.Y.Offset }
    end
    Nova.Config.State = state
    return state
end

local function encodeConfig()
    Nova.CaptureState()
    local snapshot = sanitize(Nova.Config, 0) or {}
    snapshot.__v = CONFIG_VERSION
    return HttpService:JSONEncode(snapshot)
end

local lastSaved = nil

function Nova.SaveConfig(profile)
    if type(writefile) ~= "function" then
        return false, "Your executor has no file access."
    end
    local path, label = profilePath(profile)
    local ok, err = pcall(function()
        if type(makefolder) == "function" and type(isfolder) == "function" and not isfolder(CONFIG_DIR) then
            makefolder(CONFIG_DIR)
        end
        local text = encodeConfig()
        writefile(path, text)
        if label == "default" then
            lastSaved = text
        end
    end)
    if not ok then
        return false, tostring(err)
    end
    return true, label
end

-- Lists saved profile names (needs listfiles)
function Nova.ListProfiles()
    local names = { "default" }
    if type(listfiles) ~= "function" then
        return names
    end
    pcall(function()
        for _, path in ipairs(listfiles(CONFIG_DIR)) do
            local name = string.match(tostring(path), "([^/\\]+)%.json$")
            if name and name ~= "config" and not table.find(names, name) then
                names[#names + 1] = name
            end
        end
    end)
    return names
end

-- `startup` = true when Nova is starting: also brings back the open tab, window position and
-- the modules that were on. A manual Load only restores settings and keybinds.
function Nova.LoadConfig(profile, startup)
    if type(readfile) ~= "function" or type(isfile) ~= "function" then
        return false, "Your executor has no file access."
    end
    local path, label = profilePath(profile)
    local okExists, exists = pcall(isfile, path)
    if not okExists or not exists then
        return false, (label == "default") and "No saved config yet."
            or ('No profile called "' .. label .. '". Press Save to create it.')
    end
    local ok, data = pcall(function()
        return HttpService:JSONDecode(readfile(path))
    end)
    if not ok or type(data) ~= "table" then
        return false, "The saved config couldn't be read."
    end

    local function applyTo(host, saved, skip)
        for key, value in pairs(saved) do
            local handle = host.Controls[key]
            if handle and not (skip and skip[key]) and type(value) == type(host.Cfg[key]) then
                local allowed = true
                if handle.Options and not table.find(handle.Options, value) then
                    allowed = false
                end
                if allowed then
                    pcall(handle.Set, value, true)
                    if handle.Callback then
                        pcall(handle.Callback, value)
                    end
                end
            end
        end
        host:RefreshVisibility()
    end

    for _, mod in ipairs(Nova.ModuleList) do
        local saved = data[mod.Name]
        if type(saved) == "table" then
            applyTo(mod.Host, saved)
            if type(saved.Key) == "string" then
                local okKey, keyCode = pcall(function()
                    return Enum.KeyCode[saved.Key]
                end)
                if saved.Key == "None" or (okKey and keyCode) then
                    mod.SetKey(saved.Key)
                end
            end
        end
    end
    if type(data.UI) == "table" and UI.SettingsHost then
        -- the profile box itself is not part of a profile
        Nova.Quiet = true
        applyTo(UI.SettingsHost, data.UI, { Profile = true })
        Nova.Quiet = false
        UI:UpdateScale(false)
        UI:RefreshHud()
    end

    local state = data.State
    if startup and type(state) == "table" then
        if type(state.Tab) == "string" then
            for _, tab in ipairs(UI.TabList) do
                if tab.Name == state.Tab then
                    UI:SelectTab(tab)
                end
            end
        end
        if type(state.Selected) == "string" then
            for _, mod in ipairs(Nova.ModuleList) do
                if mod.Name == state.Selected then
                    UI:SelectModule(mod)
                    break
                end
            end
        end
        local w = state.Window
        if type(w) == "table" and type(w.xo) == "number" and type(w.yo) == "number" then
            UI.Holder.Position = UDim2.new(tonumber(w.xs) or 0.5, w.xo, tonumber(w.ys) or 0.5, w.yo)
            UI:ClampWindow()
        end
        if type(state.Enabled) == "table" and Nova.Config.UI.RestoreModules ~= false then
            local wanted = {}
            for _, mod in ipairs(Nova.ModuleList) do
                if state.Enabled[mod.Name] then
                    wanted[#wanted + 1] = mod
                end
            end
            -- give the game a moment to load, then try once more for anything that wasn't ready
            Nova.Wanted = {}
            for _, mod in ipairs(wanted) do
                Nova.Wanted[mod.Name] = true
            end
            task.spawn(function()
                task.wait(1.5)
                for pass = 1, 2 do
                    local retry = {}
                    for _, mod in ipairs(wanted) do
                        if not Nova.Unloaded and not mod.Enabled then
                            pcall(mod.SetEnabled, mod, true, true)
                            if not mod.Enabled then
                                retry[#retry + 1] = mod
                            end
                        end
                    end
                    wanted = retry
                    if #wanted == 0 or Nova.Unloaded then
                        break
                    end
                    if pass == 1 then
                        task.wait(5)
                    end
                end
                -- anything still off stays on the saved list (it may need a match) but loses its error text
                for _, mod in ipairs(wanted) do
                    if not mod.Enabled and mod.SetStatus then
                        pcall(mod.SetStatus, mod, nil)
                    end
                end
                for _, mod in ipairs(Nova.ModuleList) do
                    if mod.Enabled and Nova.Wanted then
                        Nova.Wanted[mod.Name] = nil
                    end
                end
                if UI.RefreshCounts then
                    UI:RefreshCounts()
                end
                if UI.RefreshHud then
                    UI:RefreshHud()
                end
            end)
        end
    end
    return true, label
end

-- Writes the default config when something changed (called on hide, and by the timer below)
function Nova.AutoSave()
    if Nova.Unloaded then
        return
    end
    local ok, text = pcall(encodeConfig)
    if ok and text ~= lastSaved then
        pcall(Nova.SaveConfig, "default")
    end
end

-- Keeps the saved file current while you play, so nothing is lost if the game closes
function Nova.StartAutoSave()
    Nova.Maid:Give(task.spawn(function()
        while not Nova.Unloaded do
            task.wait(3)
            Nova.AutoSave()
        end
    end))
end

-- Switches every module off (optionally hides the window too)
function Nova.DisableAll(hideWindow, silent)
    for _, mod in ipairs(Nova.ModuleList) do
        if mod.Enabled then
            pcall(mod.SetEnabled, mod, false, true)
        end
    end
    Nova.Wanted = {}
    if UI.RefreshCounts then
        UI:RefreshCounts()
    end
    Nova.AutoSave()
    if hideWindow then
        UI:SetVisible(false)
    end
    if not silent then
        Nova.Notify("Nova", "Every module is off.", 2.5, "info", true)
    end
end

-- ---------------------------------------------------------------------
-- Scale handling
-- ---------------------------------------------------------------------
function UI:FitScale()
    local cam = Workspace.CurrentCamera
    local viewport = cam and cam.ViewportSize or Vector2.new(1280, 720)
    UI.BaseScale = math.clamp(math.min((viewport.X - 40) / WINDOW_W, (viewport.Y - 40) / WINDOW_H), 0.5, 1)
end

function UI:TargetScale()
    local percent = tonumber(Nova.Config.UI.Scale) or 100
    return UI.BaseScale * math.clamp(percent, 50, 150) / 100
end

function UI:ClampWindow()
    local viewport = UI.Gui.AbsoluteSize
    if viewport.X < 10 or viewport.Y < 10 then
        return
    end
    local scale = UI:TargetScale()
    local halfW, halfH = WINDOW_W * scale / 2, WINDOW_H * scale / 2
    local pos = UI.Holder.Position
    local centerX = viewport.X * pos.X.Scale + pos.X.Offset
    local centerY = viewport.Y * pos.Y.Scale + pos.Y.Offset
    centerX = math.clamp(centerX, 120 - halfW, viewport.X - 120 + halfW)
    centerY = math.clamp(centerY, halfH, math.max(halfH, viewport.Y + halfH - 80))
    UI.Holder.Position = UDim2.fromOffset(centerX, centerY)
end

function UI:UpdateScale(instant)
    UI:FitScale()
    if UI.Visible then
        Animate(UI.Scale, { Scale = UI:TargetScale() }, instant, 0.2, Enum.EasingStyle.Quint)
    end
    UI:ClampWindow()
end

-- Applying the scale while a slider is being dragged would move the slider under the cursor,
-- so wait until the mouse is released.
local scalePending = false
function UI:QueueScale()
    if scalePending then
        return
    end
    scalePending = true
    task.spawn(function()
        while UI.ActiveDrag and not Nova.Unloaded do
            task.wait(0.05)
        end
        task.wait(0.05)
        scalePending = false
        if not Nova.Unloaded then
            UI:UpdateScale(false)
        end
    end)
end

-- ---------------------------------------------------------------------
-- Settings popover (gear)
-- ---------------------------------------------------------------------
local POP_W, POP_HEADER = 280, 48

UI.SettingsCatcher = New("TextButton", {
    Name = "SettingsCatcher",
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Text = "",
    AutoButtonColor = false,
    Visible = false,
    ZIndex = 40,
    Parent = UI.Main,
})
local SettingsMenu = New("Frame", {
    Name = "SettingsMenu",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.fromOffset(WINDOW_W - PAGE_PAD, TOPBAR_H + 8),
    Size = UDim2.fromOffset(POP_W, 300),
    BackgroundColor3 = Theme.Card:Lerp(Theme.Text, 0.03),
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 41,
    Parent = UI.Main,
}, { Round(10), Stroke(Theme.StrokeHover, 1) })
local SettingsScale = New("UIScale", { Scale = 1, Parent = SettingsMenu })

New("TextLabel", {
    Position = UDim2.fromOffset(16, 12),
    Size = UDim2.fromOffset(160, 18),
    BackgroundTransparency = 1,
    Text = "Settings",
    Font = FONT.Bold,
    TextSize = 15,
    TextColor3 = Theme.Text,
    TextXAlignment = Enum.TextXAlignment.Left,
    ZIndex = 42,
    Parent = SettingsMenu,
})
New("TextLabel", {
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -16, 0, 14),
    Size = UDim2.fromOffset(100, 14),
    BackgroundTransparency = 1,
    Text = "Nova v" .. Nova.Version,
    Font = FONT.Regular,
    TextSize = 11,
    TextColor3 = Theme.TextFaint,
    TextXAlignment = Enum.TextXAlignment.Right,
    ZIndex = 42,
    Parent = SettingsMenu,
})
local POP_MAX_H = WINDOW_H - TOPBAR_H - 24
local SettingsContent = New("ScrollingFrame", {
    Position = UDim2.fromOffset(0, POP_HEADER),
    Size = UDim2.new(1, 0, 1, -POP_HEADER),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = Theme.Accent,
    ScrollBarImageTransparency = 0.25,
    ScrollingDirection = Enum.ScrollingDirection.Y,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ZIndex = 42,
    Parent = SettingsMenu,
}, {
    New("UIListLayout", { Padding = UDim.new(0, ROW_GAP), SortOrder = Enum.SortOrder.LayoutOrder }),
    Pad(16, BODY_TOP, 16, BODY_BOTTOM),
})

pcall(function()
    SettingsContent.ElasticBehavior = Enum.ElasticBehavior.Never
end)
onTheme(function()
    SettingsContent.ScrollBarImageColor3 = Theme.Accent
end)
SettingsContent:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
    UI:CloseDropdown()
    UI:HideTip()
end)

function UI:SetSettingsOpen(state)
    state = state and true or false
    if state == SettingsMenu.Visible then
        return
    end
    UI:CloseDropdown()
    UI:HideTip()
    if state then
        UI.SettingsCatcher.Visible = true
        SettingsMenu.Visible = true
        SettingsScale.Scale = 0.94
        Tween(SettingsScale, 0.18, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    else
        UI.SettingsCatcher.Visible = false
        SettingsMenu.Visible = false
    end
end
UI.SettingsCatcher.MouseButton1Click:Connect(function()
    UI:SetSettingsOpen(false)
end)
gearButton.MouseButton1Click:Connect(function()
    UI:SetSettingsOpen(not SettingsMenu.Visible)
end)
closeButton.MouseButton1Click:Connect(function()
    UI:SetVisible(false)
end)
UI:AttachTip(gearButton, "Settings")
UI:AttachTip(closeButton, "Hide window (RightShift)")
if UI.AttachChipTip then
    UI.AttachChipTip()
end

do
    local host = newHost(SettingsContent, Nova.Config.UI, nil)
    host.InnerWidth = POP_W - 32
    UI.SettingsHost = host
    host.OnLayout = function()
        SettingsMenu.Size = UDim2.fromOffset(POP_W, math.min(POP_HEADER + host:ContentHeight(), POP_MAX_H))
    end

    Controls.Section(host, "Interface")
    Controls.Toggle(host, {
        Label = "Notifications", Key = "Notifications", Default = true,
        Tip = "Show small pop-up messages when modules change.",
        Callback = function(value)
            if not Nova.Quiet then
                Nova.Notify("Notifications", value and "On" or "Off", 2, "info", true)
            end
        end,
    })
    Controls.Option(host, {
        Label = "Accent", Key = "Accent", Options = ACCENT_NAMES, Swatches = ACCENT_SWATCHES, Default = "Purple",
        Callback = function(value)
            local alt = ACCENTS[1].Alt
            for _, accent in ipairs(ACCENTS) do
                if accent.Name == value then
                    alt = accent.Alt
                    break
                end
            end
            applyAccent(ACCENT_SWATCHES[value] or ACCENT_SWATCHES.Purple, alt)
        end,
    })
    Controls.Slider(host, {
        Label = "Window Scale", Key = "Scale", Min = 70, Max = 130, Step = 5, Default = 100, Suffix = "%",
        Tip = "Applied when you let go of the slider.",
        Callback = function()
            UI:QueueScale()
        end,
    })
    Controls.Toggle(host, {
        Label = "Module List", Key = "ShowList", Default = false,
        Tip = "Show enabled modules in the top-right corner.",
        Callback = function()
            UI:RefreshHud()
        end,
    })
    Controls.Toggle(host, {
        Label = "Auto Inject", Key = "AutoInject", Default = true,
        Tip = "Load Nova again by itself when you join a new game or a queued match, so you never have to re-execute it.",
        Callback = function(value)
            if Nova.AutoInject then
                Nova.AutoInject.Refresh()
            end
            if not Nova.Quiet then
                Nova.Notify("Auto Inject", value and "On" or "Off", 2, "info", true)
            end
        end,
    })
    Controls.Toggle(host, {
        Label = "Restore Modules", Key = "RestoreModules", Default = true,
        Tip = "Switch back on the modules that were on last time. Everything else is always saved automatically.",
    })

    Controls.Section(host, "Profiles")
    Controls.TextBox(host, {
        Label = "Profile", Key = "Profile", Default = "default", Placeholder = "name",
        Tip = "Letters, numbers, - and _. Save under a new name to make another profile.",
    })
    Controls.ButtonRow(host, {
        {
            Label = "Save", Style = "accent",
            Tip = "Write all settings to the profile named above.",
            Callback = function()
                local ok, info = Nova.SaveConfig(Nova.Config.UI.Profile)
                if ok then
                    Nova.Notify("Profiles", 'Saved "' .. tostring(info) .. '"', 2.5, "success", true)
                else
                    Nova.Notify("Profiles", tostring(info), 3.5, "error", true)
                end
            end,
        },
        {
            Label = "Load",
            Tip = "Restore settings from the profile named above. Modules stay on or off as they are.",
            Callback = function()
                local ok, info = Nova.LoadConfig(Nova.Config.UI.Profile)
                if ok then
                    Nova.Notify("Profiles", 'Loaded "' .. tostring(info) .. '"', 2.5, "success", true)
                else
                    Nova.Notify("Profiles", tostring(info), 3.5, "error", true)
                end
            end,
        },
    })

    Controls.Section(host, "Safety")
    Controls.TextBox(host, {
        Label = "Panic Key", Key = "PanicKey", Default = "None", Placeholder = "e.g. End",
        Tip = "Press it any time to switch every module off and hide Nova. Type none to clear.",
    })
    Controls.ButtonRow(host, {
        {
            Label = "Disable All", Style = "danger",
            Tip = "Switch every module off right now.",
            Callback = function()
                Nova.DisableAll(false)
            end,
        },
        {
            Label = "Reinject", Style = "accent",
            Tip = "Rebuild Nova from scratch and keep your current settings.",
            Callback = function()
                pcall(Nova.AutoSave)
                Nova.Reinject()
            end,
        },
        {
            Label = "Uninject", Style = "danger",
            Tip = "Turn everything off and remove Nova completely.",
            Callback = function()
                pcall(Nova.AutoSave)
                Nova.Unload(false)
            end,
        },
    })

    Controls.Section(host, "Mobile")
    Controls.Toggle(host, {
        Label = "Mobile Button", Key = "MobileButton", Default = true,
        Tip = "A small draggable button to open/close Nova (RightShift doesn't exist on a touchscreen). Shown automatically on touch-only devices.",
        Callback = function()
            if UI.RefreshMobileButton then
                UI.RefreshMobileButton()
            end
        end,
    })
    Controls.Toggle(host, {
        Label = "Force On PC", Key = "MobileButtonForcePC", Default = false,
        Tip = "Show the mobile button even with a keyboard/mouse connected.",
        Callback = function()
            if UI.RefreshMobileButton then
                UI.RefreshMobileButton()
            end
        end,
    })
    Controls.ButtonRow(host, {
        {
            Label = "Reset Button Position",
            Tip = "Puts the mobile button back on the right edge if it's been dragged somewhere awkward.",
            Callback = function()
                if UI.ResetMobileButtonPosition then
                    UI.ResetMobileButtonPosition()
                end
            end,
        },
    })

    host:RefreshVisibility()
end

-- ---------------------------------------------------------------------
-- Window behaviour
-- ---------------------------------------------------------------------
function UI:CloseOverlays()
    UI:CloseDropdown()
    UI:HideTip()
    UI:SetSettingsOpen(false)
end

function UI:SetVisible(state)
    if Nova.Unloaded then
        return
    end
    state = state and true or false
    UI.Visible = state
    UI.ModalButton.Modal = state
    UI:FitScale()
    local target = UI:TargetScale()
    if state then
        UI:ClampWindow()
        UI.Main.Visible = true
        UI.Scale.Scale = target * 0.94
        Tween(UI.Scale, 0.25, { Scale = target }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    else
        UI:CloseOverlays()
        Nova.AutoSave()
        if UI.SearchBox:IsFocused() then
            UI.SearchBox:ReleaseFocus()
        end
        Tween(UI.Scale, 0.15, { Scale = target * 0.94 })
        task.delay(0.15, function()
            if not UI.Visible and not Nova.Unloaded then
                UI.Main.Visible = false
            end
        end)
    end
end

-- Drag the window by the top bar or the brand block. Double-click to re-centre.
do
    local lastDragClick = 0
    local function beginDrag(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            UI.WindowDrag = { StartMouse = input.Position, StartPos = UI.Holder.Position }
            local now = os.clock()
            if now - lastDragClick < 0.35 then
                UI.WindowDrag = nil
                Tween(UI.Holder, 0.25, { Position = UDim2.fromScale(0.5, 0.5) }, Enum.EasingStyle.Quint)
            end
            lastDragClick = now
        end
    end
    TopBar.InputBegan:Connect(beginDrag)
    BrandArea.InputBegan:Connect(beginDrag)
end

Nova.Maid:Give(UserInputService.InputChanged:Connect(function(input)
    local moved = input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch
    if not moved then
        return
    end
    if UI.ActiveDrag then
        UI.ActiveDrag(input)
    end
    local drag = UI.WindowDrag
    if drag then
        local delta = input.Position - drag.StartMouse
        UI.Holder.Position = UDim2.new(
            drag.StartPos.X.Scale, drag.StartPos.X.Offset + delta.X,
            drag.StartPos.Y.Scale, drag.StartPos.Y.Offset + delta.Y
        )
        UI:ClampWindow()
    end
    -- Mobile open/close button: same drag pattern as the window above, kept separate so moving
    -- it never touches UI.WindowDrag or the window's own position.
    local btnDrag = UI.MobileBtnDrag
    if btnDrag then
        local delta = input.Position - btnDrag.StartMouse
        if not btnDrag.Moved and delta.Magnitude > 6 then
            btnDrag.Moved = true
        end
        local newPos = UDim2.new(
            btnDrag.StartPos.X.Scale, btnDrag.StartPos.X.Offset + delta.X,
            btnDrag.StartPos.Y.Scale, btnDrag.StartPos.Y.Offset + delta.Y
        )
        if UI.ClampMobileButton then
            newPos = UI.ClampMobileButton(newPos)
        end
        UI.MobileBtn.Position = newPos
    end
end))

Nova.Maid:Give(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        local release = UI.ActiveRelease
        UI.ActiveDrag = nil
        UI.ActiveRelease = nil
        UI.WindowDrag = nil
        if release then
            pcall(release)
        end
        local btnDrag = UI.MobileBtnDrag
        if btnDrag then
            UI.MobileBtnDrag = nil
            if btnDrag.Moved then
                local pos = UI.MobileBtn.Position
                Nova.Config.UI.MobileButtonPos = {
                    XS = pos.X.Scale, XO = pos.X.Offset,
                    YS = pos.Y.Scale, YO = pos.Y.Offset,
                }
            else
                -- A tap, not a drag: open/close Nova like RightShift does.
                UI:SetVisible(not UI.Visible)
            end
        end
    end
end))

-- Keep the window on screen when the viewport changes
do
    local function watchCamera()
        local cam = Workspace.CurrentCamera
        if cam then
            Nova.Maid:Give(cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
                UI:UpdateScale(true)
            end))
        end
    end
    watchCamera()
    Nova.Maid:Give(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        watchCamera()
        UI:UpdateScale(true)
    end))
end

-- Global hotkeys: RightShift toggles UI, Escape closes popups, module keybinds toggle modules
Nova.Maid:Give(UserInputService.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.Keyboard then
        return
    end
    if UI.KeyListen then
        local handlers = UI.KeyListen
        UI.KeyListen = nil
        if input.KeyCode == Enum.KeyCode.Escape then
            if handlers.Cancel then
                pcall(handlers.Cancel)
            end
        elseif handlers.Apply then
            pcall(handlers.Apply, input.KeyCode)
        end
        return
    end
    if UserInputService:GetFocusedTextBox() then
        return
    end
    if input.KeyCode == Enum.KeyCode.RightShift then
        UI:SetVisible(not UI.Visible)
        return
    end
    local panic = Nova.Config.UI.PanicKey
    if type(panic) == "string" and panic ~= "" and string.lower(panic) ~= "none" then
        local code = KeyLookup[string.lower(panic)]
        if code and input.KeyCode == code then
            Nova.DisableAll(true, true)
            return
        end
    end
    if input.KeyCode == Enum.KeyCode.Escape and UI.Visible then
        if UI.DropdownFrame.Visible or SettingsMenu.Visible then
            UI:CloseOverlays()
        end
        return
    end
    for _, mod in ipairs(Nova.ModuleList) do
        local key = mod.Config.Key
        if key and key ~= "None" and input.KeyCode.Name == key then
            mod:Toggle()
        end
    end
end))

-- ---------------------------------------------------------------------
-- Mobile open/close button
-- ---------------------------------------------------------------------
-- RightShift has nothing to bind to on a touchscreen, so this is the only way a touch-only
-- player can open Nova at all. It's a small round button, parented to the same hidden gui as
-- the rest of Nova (so it's no more visible to anyone else than the window is), that you can
-- drag anywhere on screen; a tap that doesn't move it toggles the window, same as RightShift.
-- Shown automatically on touch-only devices, and the Settings > Mobile section can force it
-- on or off for any device, or reset its position if it gets dragged somewhere awkward.
do
    local BTN_SIZE = 52
    local DEFAULT_POS = UDim2.new(1, -16, 0.6, 0)

    local function isTouchOnly()
        local ok, touch, keyboard = pcall(function()
            return UserInputService.TouchEnabled, UserInputService.KeyboardEnabled
        end)
        return ok and touch and not keyboard
    end

    local btn = New("TextButton", {
        Name = "MobileButton",
        AnchorPoint = Vector2.new(1, 0.5),
        Position = DEFAULT_POS,
        Size = UDim2.fromOffset(BTN_SIZE, BTN_SIZE),
        BackgroundColor3 = Theme.Card,
        AutoButtonColor = false,
        Text = "N",
        Font = FONT.Bold,
        TextSize = 20,
        TextColor3 = Theme.Text,
        Visible = false,
        ZIndex = 50,
        Parent = UI.Gui,
    }, { Round(26), Stroke(Theme.StrokeHover, 1) })
    onTheme(function()
        btn.BackgroundColor3 = Theme.Card
        btn.TextColor3 = Theme.Text
    end)
    UI.MobileBtn = btn

    function UI.ClampMobileButton(pos)
        local cam = Workspace.CurrentCamera
        local vp = cam and cam.ViewportSize or Vector2.new(1280, 720)
        local ax, ay = btn.AnchorPoint.X, btn.AnchorPoint.Y
        local minX, maxX = ax * BTN_SIZE, vp.X - (1 - ax) * BTN_SIZE
        local minY, maxY = ay * BTN_SIZE, vp.Y - (1 - ay) * BTN_SIZE
        local x = math.clamp(pos.X.Scale * vp.X + pos.X.Offset, minX, maxX) - ax * vp.X
        local y = math.clamp(pos.Y.Scale * vp.Y + pos.Y.Offset, minY, maxY) - ay * vp.Y
        return UDim2.new(pos.X.Scale, x, pos.Y.Scale, y)
    end

    local function resetPosition()
        Nova.Config.UI.MobileButtonPos = nil
        btn.Position = UI.ClampMobileButton(DEFAULT_POS)
    end

    local saved = Nova.Config.UI.MobileButtonPos
    if type(saved) == "table" and saved.XS then
        btn.Position = UI.ClampMobileButton(UDim2.new(saved.XS, saved.XO, saved.YS, saved.YO))
    else
        btn.Position = UI.ClampMobileButton(DEFAULT_POS)
    end

    local function refreshVisible()
        local wanted = Nova.Config.UI.MobileButton ~= false and (isTouchOnly() or Nova.Config.UI.MobileButtonForcePC)
        btn.Visible = wanted and true or false
    end
    UI.RefreshMobileButton = refreshVisible
    refreshVisible()

    btn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            UI.MobileBtnDrag = { StartMouse = input.Position, StartPos = btn.Position, Moved = false }
        end
    end)
    UI:AttachTip(btn, "Drag to move, tap to open/close Nova")

    Nova.Maid:Give(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        btn.Position = UI.ClampMobileButton(btn.Position)
    end))
    local function watchViewport()
        local cam = Workspace.CurrentCamera
        if cam then
            Nova.Maid:Give(cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
                btn.Position = UI.ClampMobileButton(btn.Position)
            end))
        end
    end
    watchViewport()

    UI.ResetMobileButtonPosition = resetPosition
end

-- ====================== MODULE: LIFECYCLE ======================
function Nova.Unload(keepSaved)
    if Nova.Unloaded then
        return
    end
    Nova.Unloaded = true
    Nova.Unloading = keepSaved and "keep" or "remove"
    -- Rip the whole UI tree out FIRST, before anything else below runs. Every tag, icon and
    -- overlay (NameTags, Kit ESP, ...) is a descendant of UI.Gui, so destroying it here guarantees
    -- nothing can be left on screen even if a module's own cleanup further down hangs or never
    -- gets a turn to run (a stuck WaitForChild, a network call that never resolves, etc.) - each
    -- step below is independently pcall'd so one failing can't stop the next.
    pcall(function()
        UI.Gui.Enabled = false
    end)
    pcall(function()
        UI.Main.Visible = false
    end)
    pcall(function()
        UI.Gui.Parent = nil
    end)
    pcall(function()
        UI.Gui:Destroy()
    end)

    -- Disable every module so each one restores what it touched (walkspeed, hidden default game
    -- tags, etc). The visuals are already gone above, so from here this is best-effort state
    -- cleanup - it no longer gates whether anything stays on screen.
    for _, mod in ipairs(Nova.ModuleList) do
        pcall(function()
            if mod.Enabled then
                mod:SetEnabled(false, true)
            end
        end)
    end

    pcall(function()
        UI.ModalButton.Modal = false
    end)

    Nova.Maid:Clean()
    -- Belt-and-suspenders: some executors' hidden-UI containers don't repaint instantly on
    -- Destroy(), so also explicitly drop it from the tree.
    pcall(function()
        UI.Gui.Parent = nil
    end)

    -- Last-resort sweep: catches anything a module's own cleanup missed (e.g. Kit ESP or
    -- NameTags icons), wherever it ended up parented, so nothing can outlive a real Unload.
    pcall(function()
        local roots = {}
        local okGui, gui = pcall(function() return LocalPlayer:FindFirstChildOfClass("PlayerGui") end)
        if okGui and gui then
            roots[#roots + 1] = gui
        end
        local okCore, core = pcall(function() return game:GetService("CoreGui") end)
        if okCore and core then
            roots[#roots + 1] = core
        end
        if gethui then
            local okHidden, hidden = pcall(gethui)
            if okHidden and hidden then
                roots[#roots + 1] = hidden
            end
        end
        for _, root in ipairs(roots) do
            -- Direct children first (ScreenGuis like NovaInventoryESP)
            for _, inst in ipairs(root:GetChildren()) do
                if type(inst.Name) == "string" and inst.Name:sub(1, 4) == "Nova" then
                    pcall(inst.Destroy, inst)
                end
            end
            for _, inst in ipairs(root:GetDescendants()) do
                if type(inst.Name) == "string" and inst.Name:sub(1, 4) == "Nova" then
                    pcall(inst.Destroy, inst)
                end
            end
        end
        -- Explicit known overlays that live outside UI.Gui
        pcall(function()
            for _, name in ipairs({ "NovaInventoryESP", "NovaInventoryEsp", "NovaNameTags", "NovaNameTagsGui" }) do
                for _, root in ipairs(roots) do
                    local inst = root:FindFirstChild(name, true)
                    if inst then
                        pcall(inst.Destroy, inst)
                    end
                end
            end
        end)
    end)

    if keepSaved then
        env.__NovaSaved = Util.DeepCopy(Nova.Config)
    else
        env.__NovaSaved = nil
        env.__NovaMain = nil
    end
    env.Nova = nil
end

function Nova.Reinject()
    local main = env.__NovaMain
    Nova.Unload(true)
    task.defer(function()
        task.wait(0.2)
        if main then
            main()
        end
    end)
end

-- ====================== AUTO INJECT ======================
-- Brings Nova into the next server you join (new game, queued match, rejoin) without re-executing.
-- Nova keeps a copy of its own source on disk, and hands the executor's queue_on_teleport a tiny
-- loader that runs that copy as soon as the new server has loaded. No link or setup is needed.
do
    local AI_DIR      = CONFIG_DIR
    local AI_FLAG     = AI_DIR .. "/autoinject.flag"
    local AI_CACHE    = AI_DIR .. "/nova_cache.lua"
    local queueFn     = queue_on_teleport or queueonteleport
        or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)

    local AutoInject = { Queued = 0, Status = "idle" }
    Nova.AutoInject = AutoInject

    local function fileOk()
        return type(writefile) == "function" and type(isfile) == "function" and type(readfile) == "function"
    end

    local function ensureFolder()
        pcall(function()
            if type(makefolder) == "function" and type(isfolder) == "function" and not isfolder(AI_DIR) then
                makefolder(AI_DIR)
            end
        end)
    end

    local function writeFlag(on)
        if not fileOk() then
            return
        end
        ensureFolder()
        pcall(writefile, AI_FLAG, on and "1" or "0")
    end
    AutoInject.WriteFlag = writeFlag

    local function enabled()
        return Nova.Config.UI.AutoInject ~= false
    end

    -- Saves the copy of Nova that the loader will run. Returns true when it is safely on disk.
    local cachedOk = false
    local function saveCopy()
        if cachedOk then
            return true
        end
        if type(NOVA_SOURCE) ~= "string" or #NOVA_SOURCE < 2000 or not fileOk() then
            return false
        end
        ensureFolder()
        pcall(function()
            if isfile(AI_CACHE) and readfile(AI_CACHE) == NOVA_SOURCE then
                cachedOk = true
                return
            end
            writefile(AI_CACHE, NOVA_SOURCE)
            cachedOk = isfile(AI_CACHE) and #readfile(AI_CACHE) == #NOVA_SOURCE
        end)
        return cachedOk
    end

    -- The loader that runs in the next server. Kept dependency-free on purpose.
    local LOADER = [=[
local cache, flag = %s, %s
local env = getgenv()
local skip = false
pcall(function()
    if type(isfile) == "function" and isfile(flag) and readfile(flag) == "0" then
        skip = true
    end
end)
if skip then
    return
end
if not game:IsLoaded() then
    game.Loaded:Wait()
end
local players = game:GetService("Players")
while not players.LocalPlayer do
    task.wait()
end
-- several queued copies can land together; only the first one carries on
if env.__NovaBooting == game.JobId and game.JobId ~= "" then
    return
end
if type(env.Nova) == "table" and not env.Nova.Unloaded and env.__NovaJob == game.JobId and game.JobId ~= "" then
    return
end
env.__NovaBooting = game.JobId
task.wait(1)

-- Backend (console + log) — always run on auto-inject, not only on manual execute
pcall(function()
    local fn = loadstring(game:HttpGet("https://raw.githubusercontent.com/Zynthire/Nova/main/backend/console.lua"))
    if fn then fn() end
end)
pcall(function()
    local fn = loadstring(game:HttpGet("https://raw.githubusercontent.com/Zynthire/Nova/main/backend/log.lua"))
    if fn then fn() end
end)

local src = %s
if not src and type(isfile) == "function" and isfile(cache) then
    pcall(function()
        src = readfile(cache)
    end)
end
if type(src) == "string" then
    local fn = loadstring(src)
    if fn then
        fn(src)
    end
end
]=]

    local function buildPayload()
        local embed = "nil"
        if not saveCopy() and type(NOVA_SOURCE) == "string" then
            -- no file access: carry the source inside the queued script itself
            local level = 1
            while string.find(NOVA_SOURCE, "]" .. string.rep("=", level) .. "]", 1, true) do
                level = level + 1
            end
            embed = "[" .. string.rep("=", level) .. "[\n" .. NOVA_SOURCE .. "]" .. string.rep("=", level) .. "]"
        end
        return string.format(LOADER, string.format("%q", AI_CACHE), string.format("%q", AI_FLAG), embed)
    end
    AutoInject.BuildPayload = buildPayload

    function AutoInject.Queue()
        if Nova.Unloaded or not enabled() then
            return false
        end
        if type(queueFn) ~= "function" then
            AutoInject.Status = "Your executor can't queue scripts."
            return false
        end
        if type(NOVA_SOURCE) ~= "string" then
            AutoInject.Status = "Nova can't find its own source."
            return false
        end
        local ok = pcall(queueFn, buildPayload())
        if ok then
            AutoInject.Queued = AutoInject.Queued + 1
            AutoInject.Status = "Ready"
        else
            AutoInject.Status = "Queue failed."
        end
        return ok
    end

    function AutoInject.Refresh()
        if Nova.Unloaded then
            return
        end
        local on = enabled()
        writeFlag(on)
        env.__NovaJob = game.JobId
        env.__NovaBooting = game.JobId
        if on then
            saveCopy()
            AutoInject.Queue()
        else
            AutoInject.Status = "Off"
        end
    end

    -- queue_on_teleport only lasts for one teleport, so queue again right before each one
    pcall(function()
        Nova.Maid:Give(LocalPlayer.OnTeleport:Connect(function(state)
            if state == Enum.TeleportState.Started or state == Enum.TeleportState.InProgress then
                AutoInject.Queue()
            end
        end))
    end)

    -- A full Uninject must stop the queued loader from bringing Nova back
    Nova.Maid:Give(function()
        if Nova.Unloading == "remove" then
            writeFlag(false)
        end
    end)
end

-- ====================== TABS ======================
local Tabs = {
    -- Placeholder glyph for every tab until real icon images (uploaded to Roblox, see the note
    -- where the sidebar icon tile is painted) replace these - no font has a real sword/eye/gear
    -- character that isn't an emoji, so a single neutral mark beats a mismatched one.
    Combat     = UI:CreateTab("Combat", "Aim, hitboxes and melee", "≡"),
    Render     = UI:CreateTab("Render", "See players and NPCs through walls", "≡"),
    Blatant    = UI:CreateTab("Blatant", "Obvious movement changes", "≡"),
    Utility    = UI:CreateTab("Utility", "Safety and quality-of-life tools", "≡"),
    Automation = UI:CreateTab("Automation", "Bots and auto combat [experimental]", "≡"),
    Kits       = UI:CreateTab("Kits", "Bedwars kit helpers", "≡"),
    World      = UI:CreateTab("World", "Camera, sky and lighting", "≡"),
    FPS        = UI:CreateTab("FPS", "Performance and frame rate", "≡"),
}

-- ====================== MODULE: AIMBOT ======================
do
    local SORT_MODES = { "Cursor", "Distance", "Health" }
    local gate = {}
    local currentTarget = nil
    local acquireAt = 0
    local ignoreSet, ignoreText = {}, ""

    local function parseList(text)
        local set = {}
        for word in tostring(text or ""):gmatch("[^,]+") do
            word = word:lower():match("^%s*(.-)%s*$")
            if word ~= "" then
                set[word] = true
            end
        end
        return set
    end

    local function asPart(inst)
        if inst and inst:IsA("BasePart") then
            return inst
        end
        return nil
    end

    local function screenDistance(cam, part, mousePos)
        local point, onScreen = cam:WorldToViewportPoint(part.Position)
        if not onScreen or point.Z <= 0 then
            return math.huge
        end
        return (Vector2.new(point.X, point.Y) - mousePos).Magnitude
    end

    local function getAimPart(entry, mode, cam, mousePos)
        local model = entry.Model
        local head = asPart(model:FindFirstChild("Head"))
        local torso = asPart(model:FindFirstChild("UpperTorso")) or asPart(model:FindFirstChild("Torso")) or entry.Root
        local part
        if mode == "Head" then
            part = head or torso
        elseif mode == "Torso" then
            part = torso or head
        else
            local headDistance = head and screenDistance(cam, head, mousePos) or math.huge
            local torsoDistance = torso and screenDistance(cam, torso, mousePos) or math.huge
            part = (headDistance <= torsoDistance) and head or torso
        end
        if not part then
            return nil
        end
        return part, screenDistance(cam, part, mousePos)
    end

    local function isValid(entry)
        local hum = entry.Humanoid
        return hum.Parent ~= nil and hum.Health > 0
            and entry.Model ~= nil and entry.Model.Parent ~= nil
            and entry.Root ~= nil and entry.Root.Parent ~= nil
    end

    -- FOV (screen-space, around your cursor) only makes sense when this module is picking its own
    -- target. "Use Kill Aura Target" means always follow whatever Kill Aura is attacking, including
    -- when that's off-screen or behind you, so FOV is skipped entirely in that mode.
    local function evaluate(cfg, entry, cam, mousePos, myRoot)
        if not isValid(entry) then
            return nil
        end
        if cfg.TeamCheck and entry.Player and Util.IsTeammate(entry.Player) then
            return nil
        end
        if next(ignoreSet) and ignoreSet[tostring(entry.Name):lower()] then
            return nil
        end
        if myRoot and entry.Root and (entry.Root.Position - myRoot.Position).Magnitude > cfg.Range then
            return nil
        end
        local part, distance = getAimPart(entry, cfg.AimPart, cam, mousePos)
        if not part then
            return nil
        end
        if not cfg.UseKillAuraTarget and distance > cfg.FOV then
            return nil
        end
        if cfg.WallCheck and not Util.HasLineOfSight(cam.CFrame.Position, part.Position) then
            return nil
        end
        return part, distance
    end

    local function scoreFor(cfg, entry, screenDist, myRoot)
        if cfg.Sort == "Distance" and myRoot and entry.Root then
            return (entry.Root.Position - myRoot.Position).Magnitude
        elseif cfg.Sort == "Health" then
            return entry.Humanoid and entry.Humanoid.Health or 100
        end
        return screenDist
    end

    local aim = Tabs.Combat:CreateModule({
        Name = "Aim Assist",
        Description = "Smooth, human-like aim toward the closest target.",
        OnEnable = function(mod)
            local cfg = mod.Config
            currentTarget = nil
            acquireAt = 0
            gate.LastActive = 0

            local circle
            if HAS_DRAWING then
                circle = mod.Maid:Give(Drawing.new("Circle"))
                circle.Thickness = 1
                circle.NumSides = 64
                circle.Filled = false
                circle.Color = Theme.Accent
                circle.Transparency = 0.8
                circle.Visible = false
            end

            local statusText
            if HAS_DRAWING then
                statusText = mod.Maid:Give(Drawing.new("Text"))
                statusText.Center = true
                statusText.Outline = true
                statusText.OutlineColor = Color3.new(0, 0, 0)
                statusText.Font = 2
                statusText.Size = 16
                statusText.Color = Theme.Text
                statusText.Visible = false
            end
            local function setStatus(cam, text)
                if not statusText then
                    return
                end
                if not cfg.StatusLine then
                    statusText.Visible = false
                    return
                end
                statusText.Visible = true
                statusText.Text = "Aim Assist: " .. tostring(text)
                local vp = cam.ViewportSize
                statusText.Position = Vector2.new(vp.X / 2, vp.Y - 70)
            end

            local stepName = "Nova_Aim_" .. Util.RandomName(6)
            RunService:BindToRenderStep(stepName, Enum.RenderPriority.Camera.Value + 1, function(dt)
                local cam = Workspace.CurrentCamera
                if not cam then
                    return
                end
                local mousePos = UserInputService:GetMouseLocation()

                if cfg.Ignore ~= ignoreText then
                    ignoreSet, ignoreText = parseList(cfg.Ignore), cfg.Ignore
                end

                if circle then
                    circle.Visible = cfg.ShowFOV
                    circle.Position = mousePos
                    circle.Radius = cfg.FOV
                end

                local _, myHum, myRoot = Util.GetCharacter(LocalPlayer)
                if not myHum or myHum.Health <= 0 then
                    currentTarget = nil
                    setStatus(cam, "dead")
                    return
                end

                -- Any mouse button held counts, and a click keeps counting as "held" for Hold Grace
                -- seconds afterward - that's what makes an autoclicker or fast manual spam-clicking
                -- register the same as actually holding the button down.
                if Util.IsMouseDown(false) or Util.IsMouseDown(true) then
                    gate.LastActive = os.clock()
                end
                local sinceActive = os.clock() - (gate.LastActive or 0)
                if sinceActive > cfg.HoldGrace then
                    -- A brief gap just past Hold Grace (an autoclicker's own jitter, or the space
                    -- between manual spam-clicks) only pauses aiming for this frame - it does NOT
                    -- forget the current target. Clearing currentTarget here used to force a full
                    -- re-acquire (plus Legit Mode's human-like delay/jitter) on every tiny gap,
                    -- which is what read as aim assist "stuttering" while autoclicking. Only a real
                    -- release - well past Hold Grace - actually drops the lock, so a genuinely fresh
                    -- engagement still gets that natural acquire delay.
                    if sinceActive > cfg.HoldGrace + 0.6 then
                        currentTarget = nil
                    end
                    setStatus(cam, "waiting for click")
                    return
                end
                if cfg.LimitToItems and not Util.MatchesHeld(cfg.ItemNames) then
                    currentTarget = nil
                    setStatus(cam, "wrong item equipped")
                    return
                end

                -- When following Kill Aura, drop the lock the instant KA's own target changes or
                -- goes stale, instead of sticking with whoever we last had.
                if cfg.UseKillAuraTarget and currentTarget then
                    local fresh = SharedAimTarget.Entry == currentTarget and os.clock() - SharedAimTarget.At < 0.3
                    if not fresh then
                        currentTarget = nil
                    end
                end

                -- Keep the current target unless someone is clearly closer to the crosshair
                local part, distance
                if currentTarget then
                    part, distance = evaluate(cfg, currentTarget, cam, mousePos, myRoot)
                    if not part then
                        currentTarget = nil
                    end
                end

                local bestEntry, bestPart, bestScore, bestScreenDistance = nil, nil, math.huge, math.huge
                if cfg.UseKillAuraTarget then
                    if SharedAimTarget.Entry and os.clock() - SharedAimTarget.At < 0.3 then
                        local kaPart, kaScreenDist = evaluate(cfg, SharedAimTarget.Entry, cam, mousePos, myRoot)
                        if kaPart then
                            bestEntry, bestPart, bestScreenDistance = SharedAimTarget.Entry, kaPart, kaScreenDist
                            bestScore = 0
                        end
                    end
                else
                    for _, entry in ipairs(Util.GetTargets(cfg.Targets)) do
                        local candidatePart, candidateScreenDist = evaluate(cfg, entry, cam, mousePos, myRoot)
                        if candidatePart then
                            local candidateScore = scoreFor(cfg, entry, candidateScreenDist, myRoot)
                            if candidateScore < bestScore then
                                bestEntry, bestPart, bestScore, bestScreenDistance = entry, candidatePart, candidateScore, candidateScreenDist
                            end
                        end
                    end
                end

                local switch = false
                if bestEntry and not currentTarget then
                    switch = true
                elseif bestEntry and bestEntry ~= currentTarget then
                    switch = cfg.UseKillAuraTarget or (bestScreenDistance + cfg.SwitchThreshold < distance)
                end
                if switch then
                    currentTarget, part, distance = bestEntry, bestPart, bestScreenDistance
                    local delaySpan = math.max(cfg.AcquireDelayMax - cfg.AcquireDelayMin, 0)
                    acquireAt = os.clock() + (cfg.LegitMode and (cfg.AcquireDelayMin + math.random() * delaySpan) or 0)
                end

                if not currentTarget or not part then
                    setStatus(cam, "no target")
                    return
                end
                if os.clock() < acquireAt then
                    setStatus(cam, "acquiring " .. tostring(currentTarget.Name) .. "...")
                    return
                end
                setStatus(cam, "locked on " .. tostring(currentTarget.Name))

                -- Prediction (X = horizontal, Y = vertical)
                local velocity = Vector3.zero
                if currentTarget.Root then
                    velocity = currentTarget.Root.AssemblyLinearVelocity
                end
                local aimPos = part.Position + Vector3.new(
                    velocity.X * cfg.PredictionX,
                    velocity.Y * cfg.PredictionY,
                    velocity.Z * cfg.PredictionX
                )

                local camCFrame = cam.CFrame
                local rate = 60 / (1 + cfg.Smoothing * 0.35)

                if cfg.LegitMode then
                    rate = rate * 0.6
                    local t = os.clock()
                    local noiseX = math.noise(t * 1.3, 0, 0) * cfg.Humanize
                    local noiseY = math.noise(0, t * 1.1, 0) * cfg.Humanize
                    aimPos = aimPos + camCFrame.RightVector * noiseX + camCFrame.UpVector * noiseY

                    local toTarget = (aimPos - camCFrame.Position)
                    if toTarget.Magnitude > 0.01 then
                        local angle = math.acos(math.clamp(camCFrame.LookVector:Dot(toTarget.Unit), -1, 1))
                        if angle < math.rad(cfg.DeadZone) then
                            return
                        end
                    end
                end

                local alpha = 1 - math.exp(-rate * dt)
                local goal = CFrame.lookAt(camCFrame.Position, aimPos)
                cam.CFrame = camCFrame:Lerp(goal, alpha)
            end)

            mod.Maid:Give(function()
                pcall(function()
                    RunService:UnbindFromRenderStep(stepName)
                end)
                currentTarget = nil
            end)
        end,
    })

    aim:AddSection("Targeting")
    aim:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players", Tip = "Who the aim assist can lock onto." })
    aim:AddToggle({ Label = "Use Kill Aura Target", Key = "UseKillAuraTarget", Default = false, Tip = "Always follow whoever Kill Aura is currently attacking instead of picking independently. Range, Wall Check, Team Check and Ignore still apply." })
    aim:AddOption({ Label = "Sort", Key = "Sort", Options = SORT_MODES, Default = "Cursor", ShowIf = function(c) return not c.UseKillAuraTarget end, Tip = "Cursor picks whoever is closest to your crosshair. Distance picks the nearest in the world. Health picks the weakest." })
    aim:AddOption({ Label = "Aim Part", Key = "AimPart", Options = { "Head", "Torso", "Closest" }, Default = "Closest", Tip = "Closest picks whichever part is nearer to your cursor." })
    aim:AddSlider({ Label = "Range", Key = "Range", Min = 5, Max = 30, Default = 25, Step = 1, Suffix = " studs", Tip = "Only targets this close in the world are considered, regardless of how they look on screen." })
    aim:AddSlider({ Label = "FOV", Key = "FOV", Min = 20, Max = 600, Default = 150, Step = 5, Suffix = " px", ShowIf = function(c) return not c.UseKillAuraTarget end, Tip = "Only targets inside this radius around your cursor are considered." })
    aim:AddSlider({ Label = "Switch Threshold", Key = "SwitchThreshold", Min = 0, Max = 150, Default = 30, Step = 5, Suffix = " px", ShowIf = function(c) return not c.UseKillAuraTarget end, Tip = "How much closer to your cursor a new target needs to be before it steals the lock from your current one." })
    aim:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true, Tip = "Ignore targets you can't see." })
    aim:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true, Tip = "Ignore your teammates." })
    aim:AddTextBox({ Label = "Ignore", Key = "Ignore", Default = "", Placeholder = "comma separated names", Tip = "Names that should never be targeted." })

    aim:AddSection("Activation")
    aim:AddSlider({ Label = "Hold Grace", Key = "HoldGrace", Min = 0, Max = 1, Default = 0.25, Step = 0.01, Suffix = " s", Tip = "Holding either mouse button engages Aim Assist. This is how long after releasing it still counts as held - turn it up if you're spam-clicking or using an autoclicker so the gaps between clicks don't drop the lock." })
    aim:AddToggle({ Label = "Limit to Items", Key = "LimitToItems", Default = false, Tip = "Only aim while holding a matching item." })
    aim:AddTextBox({ Label = "Item Names", Key = "ItemNames", Default = "", Placeholder = "blank = any tool", ShowIf = function(c) return c.LimitToItems end, Tip = "Comma separated, partial names work (bow, gun)." })

    aim:AddSection("Feel")
    aim:AddSlider({ Label = "Smoothing", Key = "Smoothing", Min = 1, Max = 100, Default = 35, Step = 1, Tip = "Higher is slower and softer." })
    aim:AddSlider({ Label = "Prediction X", Key = "PredictionX", Min = 0, Max = 0.5, Default = 0.1, Step = 0.01, Tip = "How far ahead to aim horizontally for moving targets." })
    aim:AddSlider({ Label = "Prediction Y", Key = "PredictionY", Min = 0, Max = 0.5, Default = 0.05, Step = 0.01, Tip = "How far ahead to aim vertically for moving targets." })
    aim:AddToggle({ Label = "Legit Mode", Key = "LegitMode", Default = true, Tip = "Adds a small human-like delay and jitter before/while locking on." })
    aim:AddSlider({ Label = "Acquire Delay Min", Key = "AcquireDelayMin", Min = 0, Max = 0.5, Default = 0.06, Step = 0.01, Suffix = " s", ShowIf = function(c) return c.LegitMode end, Tip = "Shortest possible delay before locking onto a new target." })
    aim:AddSlider({ Label = "Acquire Delay Max", Key = "AcquireDelayMax", Min = 0, Max = 0.5, Default = 0.16, Step = 0.01, Suffix = " s", ShowIf = function(c) return c.LegitMode end, Tip = "Longest possible delay before locking onto a new target." })
    aim:AddSlider({ Label = "Humanize", Key = "Humanize", Min = 0, Max = 2, Default = 0.45, Step = 0.05, ShowIf = function(c) return c.LegitMode end, Tip = "How much natural wobble to add around the target point." })
    aim:AddSlider({ Label = "Dead Zone", Key = "DeadZone", Min = 0, Max = 5, Default = 0.35, Step = 0.05, Suffix = "°", ShowIf = function(c) return c.LegitMode end, Tip = "Stops micro-adjusting once you're already aimed this close." })

    aim:AddSection("Display")
    aim:AddToggle({ Label = "Show FOV Circle", Key = "ShowFOV", Default = false, ShowIf = function(c) return not c.UseKillAuraTarget end, Tip = "Draw the FOV radius on screen." })
    aim:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true, Tip = "Small readout showing what Aim Assist is currently doing." })
    aim:AddNote("Hold either mouse button (or spam-click / autoclick) to engage - there's no separate on/off toggle for that anymore.")
end

-- ====================== MODULE: HITBOX EXPANDER ======================
-- Player mode adds an extra invisible box around each enemy (the enemy's own body is never touched,
-- so nothing freezes when they die). Sword mode widens the game's own sword swing region instead.
do
    local CollectionService = service("CollectionService")

    local SWORD_REGION_DEFAULT = 3.8
    local COLORS = {
        Accent = nil, -- filled in below (follows the theme)
        Red = Color3.fromRGB(255, 0, 0),
        Blue = Color3.fromRGB(0, 100, 255),
        Green = Color3.fromRGB(0, 255, 0),
        Yellow = Color3.fromRGB(255, 255, 0),
        Orange = Color3.fromRGB(255, 140, 0),
        Purple = Color3.fromRGB(180, 0, 255),
        White = Color3.fromRGB(255, 255, 255),
        Cyan = Color3.fromRGB(0, 255, 255),
        Pink = Color3.fromRGB(255, 50, 150),
        Black = Color3.fromRGB(0, 0, 0),
    }
    local COLOR_NAMES = { "Accent", "Red", "Blue", "Green", "Yellow", "Orange", "Purple", "White", "Cyan", "Pink", "Black" }

    local function boxSize(expand)
        return Vector3.new(3, 6, 3) + Vector3.one * ((tonumber(expand) or 14.4) / 5)
    end

    local hitbox = Tabs.Combat:CreateModule({
        Name = "Hitbox Expander",
        Description = "Expands hitboxes of players / NPCs (client side).",
        OnEnable = function(mod)
            local cfg = mod.Config
            local records = setmetatable({}, { __mode = "k" }) -- [model] = { Part, Connections }
            local wallCache = setmetatable({}, { __mode = "k" })
            local swordApplied = false

            local function destroyRecord(model)
                local record = records[model]
                if not record then
                    return
                end
                records[model] = nil
                for _, connection in ipairs(record.Connections) do
                    connection:Disconnect()
                end
                pcall(function()
                    record.Part:Destroy()
                end)
            end

            local function destroyAll()
                for model in pairs(records) do
                    destroyRecord(model)
                end
                -- Anything left over from an earlier run
                for _, plr in ipairs(Players:GetPlayers()) do
                    local char = plr.Character
                    if char then
                        for _, child in ipairs(char:GetChildren()) do
                            if child.Name == "NovaHitbox" then
                                child:Destroy()
                            end
                        end
                    end
                end
            end

            local function setSwordRegion(on)
                local ok = pcall(function()
                    local swing = Bedwars.SwordController.swingSwordInRegion
                    debug.setconstant(swing, 6, on and ((tonumber(cfg.Expand) or 14.4) / 3) or SWORD_REGION_DEFAULT)
                end)
                return ok
            end

            local function colorFor()
                if cfg.HitboxColor == "Accent" or not COLORS[cfg.HitboxColor] then
                    return Theme.Accent
                end
                return COLORS[cfg.HitboxColor]
            end

            local function createFor(entry)
                local model, root, hum = entry.Model, entry.Root, entry.Humanoid
                local part = Instance.new("Part")
                part.Name = "NovaHitbox"
                part.Archivable = false
                part.Size = boxSize(cfg.Expand)
                part.Position = root.Position
                part.CanCollide = false
                part.CanQuery = true
                part.Massless = true
                part.Transparency = cfg.ShowHitbox and (tonumber(cfg.Transparency) or 0.7) or 1
                part.LocalTransparencyModifier = cfg.ShowHitbox and 0 or 1
                part.Color = colorFor()
                part.Parent = model

                local weld = Instance.new("Motor6D")
                weld.Part0 = part
                weld.Part1 = root
                weld.Parent = part

                local owner = Instance.new("ObjectValue")
                owner.Name = "EntityValue"
                owner.Value = model
                owner.Parent = part
                CollectionService:AddTag(part, "Hitbox")

                local connections = {}
                -- Gone the instant the target dies or leaves, so the game's own death handling runs untouched
                if hum then
                    connections[#connections + 1] = hum.HealthChanged:Connect(function(health)
                        if health <= 0 then
                            destroyRecord(model)
                        end
                    end)
                    connections[#connections + 1] = hum.Died:Connect(function()
                        destroyRecord(model)
                    end)
                end
                connections[#connections + 1] = model.AncestryChanged:Connect(function(_, parent)
                    if not parent then
                        destroyRecord(model)
                    end
                end)
                connections[#connections + 1] = root.AncestryChanged:Connect(function(_, parent)
                    if not parent then
                        destroyRecord(model)
                    end
                end)
                records[model] = { Part = part, Connections = connections }
            end

            local function holdingSword()
                if not Bedwars.Ready then
                    return false
                end
                local item = Bedwars.GetHeldSword()
                return item ~= nil
            end

            mod.Maid:Give(function()
                destroyAll()
                if swordApplied then
                    swordApplied = false
                    setSwordRegion(false)
                end
            end)

            local acc = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function(dt)
                acc = acc + dt
                if acc < 0.2 then
                    return
                end
                acc = 0

                if cfg.Mode == "Sword" then
                    if next(records) ~= nil then
                        destroyAll()
                    end
                    if Bedwars.Ready or Bedwars.Resolve() then
                        -- Re-applied on every pass so slider changes take effect straight away
                        swordApplied = setSwordRegion(true)
                    end
                    return
                end
                if swordApplied then
                    swordApplied = false
                    setSwordRegion(false)
                end

                if cfg.AutoToggle and not holdingSword() then
                    destroyAll()
                    return
                end

                local cam = Workspace.CurrentCamera
                local now = os.clock()
                local wanted = {}
                for _, entry in ipairs(Util.GetTargets(cfg.Targets)) do
                    local root, hum, model = entry.Root, entry.Humanoid, entry.Model
                    if root and root.Parent and hum and hum.Health > 0 and model and model.Parent then
                        local expand = not (cfg.TeamCheck and entry.Player and Util.IsTeammate(entry.Player))
                        if expand and cfg.WallCheck and cam then
                            local cache = wallCache[entry]
                            if not cache or now - cache.Time > 0.1 then
                                cache = { Time = now, Visible = Util.HasLineOfSight(cam.CFrame.Position, root.Position) }
                                wallCache[entry] = cache
                            end
                            expand = cache.Visible
                        end
                        if expand then
                            wanted[model] = true
                            local record = records[model]
                            if not record or not record.Part.Parent then
                                if record then
                                    destroyRecord(model)
                                end
                                createFor(entry)
                            else
                                local part = record.Part
                                local size = boxSize(cfg.Expand)
                                if part.Size ~= size then
                                    part.Size = size
                                end
                                local transparency = cfg.ShowHitbox and (tonumber(cfg.Transparency) or 0.7) or 1
                                if part.Transparency ~= transparency then
                                    part.Transparency = transparency
                                end
                                local modifier = cfg.ShowHitbox and 0 or 1
                                if part.LocalTransparencyModifier ~= modifier then
                                    part.LocalTransparencyModifier = modifier
                                end
                                part.Color = colorFor()
                            end
                        end
                    end
                end
                for model in pairs(records) do
                    if not wanted[model] then
                        destroyRecord(model)
                    end
                end
            end))
        end,
    })

    hitbox:AddSection("Mode")
    hitbox:AddOption({
        Label = "Mode", Key = "Mode", Options = { "Player", "Sword" }, Default = "Player",
        Tip = "Player adds an extra box around each enemy. Sword widens the game's own swing region instead.",
    })
    hitbox:AddSlider({ Label = "Expand Amount", Key = "Expand", Min = 0, Max = 30, Default = 14.4, Step = 0.1, Tip = "How much bigger the hitbox gets." })
    hitbox:AddSection("Targeting")
    hitbox:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players", ShowIf = function(c) return c.Mode ~= "Sword" end, Tip = "Whose hitboxes get expanded." })
    hitbox:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true, ShowIf = function(c) return c.Mode ~= "Sword" end })
    hitbox:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true, ShowIf = function(c) return c.Mode ~= "Sword" end, Tip = "Leave your teammates alone." })
    hitbox:AddToggle({ Label = "Auto Toggle", Key = "AutoToggle", Default = false, ShowIf = function(c) return c.Mode ~= "Sword" end, Tip = "Only expands hitboxes while you hold a sword." })
    hitbox:AddSection("Visuals")
    hitbox:AddToggle({ Label = "Show Hitbox", Key = "ShowHitbox", Default = false, ShowIf = function(c) return c.Mode ~= "Sword" end, Tip = "Makes the expanded hitbox visible. The expansion works either way - this is just a preview." })
    hitbox:AddSlider({ Label = "Transparency", Key = "Transparency", Min = 0, Max = 1, Default = 0.7, Step = 0.05, ShowIf = function(c) return c.Mode ~= "Sword" and c.ShowHitbox end })
    hitbox:AddOption({ Label = "Color", Key = "HitboxColor", Options = COLOR_NAMES, Default = "Accent", ShowIf = function(c) return c.Mode ~= "Sword" and c.ShowHitbox end })
end

-- ====================== MODULE: BEDWARS BRIDGE ======================
-- Shared plumbing for the two Bedwars modules below. Everything is resolved lazily and inside
-- pcall, so on any other game (or an executor missing require / debug.getupvalue) the modules
-- just report why they can't run instead of erroring.
local Bedwars = {
    Ready = false,
    Reason = "not checked yet",
    RetryAt = 0,
    ReachLimit = 22,                  -- the server's own sword reach (read from the game when possible)
}

do
    local ReplicatedStorage = service("ReplicatedStorage")

    -- Collects every upvalue of `fn` (executors differ on whether getupvalue returns name+value or only value)
    local function upvaluesOf(fn)
        local out = {}
        if type(fn) ~= "function" or not (debug and type(debug.getupvalue) == "function") then
            return out
        end
        for index = 1, 60 do
            local ok, first, second = pcall(debug.getupvalue, fn, index)
            if not ok then
                break
            end
            local value = first
            if type(first) == "string" and second ~= nil then
                value = second
            end
            if value ~= nil then
                out[#out + 1] = value
            end
        end
        return out
    end

    local function findTableUpvalue(fn, predicate)
        for _, value in ipairs(upvaluesOf(fn)) do
            if type(value) == "table" then
                local ok, match = pcall(predicate, value)
                if ok and match then
                    return value
                end
            end
        end
        return nil
    end

    local function child(parent, ...)
        local node = parent
        for _, name in ipairs({ ... }) do
            node = node and node:FindFirstChild(name)
        end
        return node
    end

    function Bedwars.Resolve()
        if Bedwars.Ready then
            return true
        end
        if os.clock() < Bedwars.RetryAt then
            return false, Bedwars.Reason
        end
        Bedwars.RetryAt = os.clock() + 2

        local ok, err = pcall(function()
            assert(type(require) == "function", "this executor has no require()")
            assert(debug and type(debug.getupvalue) == "function", "this executor has no debug.getupvalue")

            local TS = ReplicatedStorage:FindFirstChild("TS")
            assert(TS and ReplicatedStorage:FindFirstChild("rbxts_include"), "this is not a Bedwars match")

            local knitModule = child(LocalPlayer, "PlayerScripts", "TS", "knit")
            assert(knitModule, "Bedwars client scripts not loaded yet")
            local knitLib = require(knitModule)

            local Knit = findTableUpvalue(knitLib.setup, function(t)
                return type(t.Controllers) == "table"
            end)
            if not Knit then
                local _, nine = pcall(debug.getupvalue, knitLib.setup, 9)
                if type(nine) == "table" then
                    Knit = nine
                end
            end
            assert(Knit and type(Knit.Controllers) == "table", "couldn't find Knit (Bedwars update?)")

            local sword = Knit.Controllers.SwordController
            assert(sword, "SwordController isn't loaded yet (wait for the match to start)")

            local remotesModule = child(TS, "remotes")
            assert(remotesModule, "Bedwars remotes module not found")
            local Client = require(remotesModule).default.Client

            local itemMetaModule = child(TS, "item", "item-meta")
            assert(itemMetaModule, "item-meta module not found")
            local ItemMeta = findTableUpvalue(require(itemMetaModule).getItemMeta, function(t)
                return t.wood_sword ~= nil or t.iron_sword ~= nil or t.stone_sword ~= nil
            end) or findTableUpvalue(require(itemMetaModule).getItemMeta, function(t)
                return next(t) ~= nil
            end)
            assert(ItemMeta, "couldn't read item meta")

            local projectileController = Knit.Controllers.ProjectileController

            pcall(function()
                local reach = require(child(TS, "combat", "combat-constant")).CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE
                if type(reach) == "number" and reach > 0 then
                    Bedwars.ReachLimit = reach
                end
            end)

            local projectileMeta
            pcall(function()
                projectileMeta = require(child(TS, "projectile", "projectile-meta")).ProjectileMeta
            end)

            local bowConstants
            if projectileController and projectileController.enableBeam then
                bowConstants = findTableUpvalue(projectileController.enableBeam, function(t)
                    return t.RelX ~= nil
                end)
            end

            Bedwars.Knit = Knit
            Bedwars.SwordController = sword
            Bedwars.ProjectileController = projectileController
            Bedwars.Client = Client
            Bedwars.ItemMeta = ItemMeta
            Bedwars.ProjectileMeta = projectileMeta
            Bedwars.BowConstants = bowConstants
        end)

        if ok then
            Bedwars.Ready = true
            Bedwars.Reason = "ready"
            return true
        end
        Bedwars.Reason = tostring(err)
        return false, Bedwars.Reason
    end

    -- Held item if it can attack in melee: returns (item, meta) or (nil, reason). Bedwars doesn't
    -- file every melee weapon's timing under meta.sword - several kits (Adetunde, Void Knight, and
    -- others) carry their own weapon under a different key (dagger/katana/scythe/spear/...), each
    -- with its own attackSpeed sub-table, same shape as a sword's. Checking only meta.sword missed
    -- all of those, so Kill Aura silently refused to work with any kit that isn't a plain sword.
    local MELEE_WEAPON_KEYS = { "sword", "dagger", "katana", "scythe", "spear", "melee", "weapon" }
    function Bedwars.GetHeldSword()
        local char = LocalPlayer.Character
        local hand = char and char:FindFirstChild("HandInvItem")
        local item = hand and hand.Value
        if not item then
            return nil, "hold a weapon"
        end
        local meta = Bedwars.ItemMeta[item.Name]
        if not meta then
            return nil, "hold a weapon (holding " .. tostring(item.Name) .. ")"
        end

        local weapon = meta.sword
        if type(weapon) ~= "table" then
            for _, key in ipairs(MELEE_WEAPON_KEYS) do
                if type(meta[key]) == "table" then
                    weapon = meta[key]
                    break
                end
            end
        end
        -- Last resort: whatever this kit calls its weapon's meta key, any sub-table carrying a
        -- numeric attackSpeed is unmistakably melee timing data.
        if type(weapon) ~= "table" then
            for _, sub in pairs(meta) do
                if type(sub) == "table" and type(sub.attackSpeed) == "number" then
                    weapon = sub
                    break
                end
            end
        end
        if type(weapon) ~= "table" then
            return nil, "hold a weapon (holding " .. tostring(item.Name) .. ")"
        end

        if weapon ~= meta.sword then
            -- Normalize so every caller's meta.sword.attackSpeed keeps working, whatever key this
            -- weapon's data actually lives under in the game's own item meta.
            local normalized = {}
            for k, v in pairs(meta) do
                normalized[k] = v
            end
            normalized.sword = weapon
            meta = normalized
        end
        return item, meta
    end

    local hitRemote
    -- Sends one SwordHit with TRUE positions (your real position, the target's real position).
    -- `claim` (optional, High Hitreg): { Self = reported position, Dir = aim direction } replaces the reach spoof below.
    function Bedwars.SendHit(item, targetChar, selfPos, targetPos, claim)
        if not hitRemote then
            local ok, remote = pcall(function()
                return Bedwars.Client:Get("SwordHit")
            end)
            if ok and remote then
                hitRemote = remote
            end
        end
        if not hitRemote then
            return false, "SwordHit remote not found"
        end

        local weapon = item
        local inventories = ReplicatedStorage:FindFirstChild("Inventories")
        local mine = inventories and inventories:FindFirstChild(LocalPlayer.Name)
        local owned = mine and mine:FindFirstChild(item.Name)
        if owned then
            weapon = owned
        end

        local reportedSelf, camOrigin, camDir
        if claim then
            if (targetPos - claim.Self).Magnitude < 0.01 then
                return false, "target is on top of you"
            end
            reportedSelf, camOrigin, camDir = claim.Self, claim.Self, claim.Dir
        else
            local offset = targetPos - selfPos
            local mag = offset.Magnitude
            if mag < 0.01 then
                return false, "target is on top of you"
            end

            -- Reach spoof: report selfPosition closer along the real path
            -- so the server sees <= ~14.4 studs. Keeps first-person strafing working.
            local limit = (type(Bedwars.ReachLimit) == "number" and Bedwars.ReachLimit > 0)
                and (Bedwars.ReachLimit - 0.01)
                or 14.39
            local dir = offset.Unit
            reportedSelf = selfPos
            if mag > limit then
                reportedSelf = selfPos + dir * (mag - limit)
            end

            local cam = Workspace.CurrentCamera
            camOrigin = (cam and cam.CFrame.Position) or selfPos
            camDir = targetPos - camOrigin
            if camDir.Magnitude > 0.01 then
                camDir = camDir.Unit
            else
                camDir = dir
            end
        end

        local payload = {
            weapon = weapon,
            chargedAttack = { chargeRatio = 0 },
            entityInstance = targetChar,
            validate = {
                raycast = {
                    cameraPosition = { value = camOrigin },
                    cursorDirection = { value = camDir },
                },
                targetPosition = { value = targetPos },
                selfPosition = { value = reportedSelf },
            },
        }

        if type(hitRemote.SendToServer) == "function" then
            if pcall(hitRemote.SendToServer, hitRemote, payload) then
                return true
            end
        end
        if hitRemote.instance then
            if pcall(function()
                hitRemote.instance:FireServer(payload)
            end) then
                return true
            end
        end
        return false, "couldn't send SwordHit"
    end
end

-- Small status pill shared by the Bedwars modules
local function makeStatusLabel(mod, prefix, yOffset)
    local function hex(color)
        return string.format("#%02X%02X%02X",
            math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
    end
    local function escape(text)
        text = string.gsub(tostring(text), "&", "&amp;")
        text = string.gsub(text, "<", "&lt;")
        return (string.gsub(text, ">", "&gt;"))
    end
    local lastText = ""
    local function render(text)
        return '<font color="' .. hex(Theme.AccentLight) .. '"><b>' .. escape(prefix) .. "</b></font>   "
            .. '<font color="' .. hex(Theme.TextDim) .. '">' .. escape(text) .. "</font>"
    end
    local label = mod.Maid:Give(New("TextLabel", {
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, yOffset),
        Size = UDim2.fromOffset(0, 26),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = Theme.Background,
        BackgroundTransparency = 0.18,
        BorderSizePixel = 0,
        Text = render("starting..."),
        RichText = true,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = Theme.Text,
        Visible = false,
        Parent = UI.Gui,
    }, {
        Round(13),
        New("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }),
    }))
    local lastAt = 0
    local nextRetryAt = 0
    -- Heartbeat callbacks run with a weaker security context than the thread that first built
    -- this label under the hidden GUI container, so a plain property write from in there can
    -- get rejected ("lacking capability Plugin") even though the same write works fine from a
    -- button click. Re-asserting identity 8 right before touching the label (same trick already
    -- used around the game's own module requires elsewhere in this file) keeps it elevated.
    -- It's still wrapped in pcall and backed off on failure so a module's own step never aborts
    -- and the console never gets spammed - it just retries a few times a second instead of
    -- going silent forever.
    return function(show, text)
        if os.clock() < nextRetryAt then
            return
        end
        local ok = pcall(function()
            if setthreadidentity then
                pcall(setthreadidentity, 8)
            end
            if not show then
                if label.Visible then
                    label.Visible = false
                end
                return
            end
            label.Visible = true
            text = tostring(text or "")
            -- Always allow forced updates (e.g. death / respawn) without the 0.1s throttle blocking them
            local force = text ~= lastText and (
                text:find("waiting", 1, true)
                or text:find("dead", 1, true)
                or text:find("character", 1, true)
                or os.clock() - lastAt > 0.08
            )
            if force then
                lastText = text
                lastAt = os.clock()
                label.Text = render(text)
            end
        end)
        if not ok then
            nextRetryAt = os.clock() + 0.5
        end
    end
end


-- ====================== MODULE: BEDWARS EXTRAS ======================
-- Extra Bedwars pieces for Sprint / Nuker / Kit ESP / Kit Render. Each one is looked up on its own
-- (inside pcall) so a Bedwars update that moves one of them only breaks the modules that need it.
do
    local ReplicatedStorage = service("ReplicatedStorage")

    local function walk(root, ...)
        local node = root
        for _, name in ipairs({ ... }) do
            node = node and node:FindFirstChild(name)
        end
        return node
    end

    local lastExtrasTry = 0

    -- Looks up the optional pieces. Anything that is still missing is retried on the next call
    -- (at most once a second), so calling this too early never leaves a module stuck.
    function Bedwars.ResolveExtras()
        local ready, reason = Bedwars.Resolve()
        if not ready then
            return false, reason
        end
        if Bedwars.ExtrasReady then
            return true
        end
        if os.clock() - lastExtrasTry < 1 then
            return Bedwars.BlockController ~= nil, "still loading"
        end
        lastExtrasTry = os.clock()

        local function attempt(name, fn)
            if Bedwars[name] ~= nil then
                return
            end
            local ok, value = pcall(fn)
            if ok and value ~= nil then
                Bedwars[name] = value
            end
        end

        local engineOut = { "rbxts_include", "node_modules", "@easy-games", "block-engine", "out" }

        attempt("SprintController", function()
            return Bedwars.Knit.Controllers.SprintController
        end)
        attempt("MatchHistoryController", function()
            return Bedwars.Knit.Controllers.MatchHistoryController
        end)
        attempt("BlockController", function()
            return require(walk(ReplicatedStorage, table.unpack(engineOut))).BlockEngine
        end)
        attempt("DamageBlockRemotes", function()
            local remotes = walk(ReplicatedStorage, table.unpack(engineOut))
            -- CatVape path: block-engine/out/shared/remotes → BlockEngineRemotes.Client
            local ok, client = pcall(function()
                return require(remotes.shared.remotes).BlockEngineRemotes.Client
            end)
            if ok and client then
                return client
            end
            ok, client = pcall(function()
                local shared = remotes:FindFirstChild("shared")
                local r = shared and shared:FindFirstChild("remotes")
                if r then
                    return require(r).BlockEngineRemotes.Client
                end
            end)
            if ok and client then
                return client
            end
            return nil
        end)
        attempt("Store", function()
            return require(walk(LocalPlayer, "PlayerScripts", "TS", "ui", "store")).ClientStore
        end)
        attempt("BlockBreaker", function()
            return Bedwars.Knit.Controllers.BlockBreakController.blockBreaker
        end)
        attempt("ViewmodelController", function()
            return Bedwars.Knit.Controllers.ViewmodelController
        end)
        attempt("AnimationUtil", function()
            return require(walk(ReplicatedStorage, "rbxts_include", "node_modules", "@easy-games", "game-core", "out", "shared", "util", "animation-util")).AnimationUtil
        end)
        attempt("RankMeta", function()
            return require(walk(ReplicatedStorage, "TS", "rank", "rank-meta")).RankMeta
        end)
        attempt("KitMeta", function()
            return require(walk(ReplicatedStorage, "TS", "games", "bedwars", "kit", "bedwars-kit-meta")).BedwarsKitMeta
        end)

        if Bedwars.BlockController and Bedwars.DamageBlockRemotes and Bedwars.Store then
            Bedwars.ExtrasReady = true
            return true
        end
        return Bedwars.BlockController ~= nil, "still loading"
    end

    -- Same as ResolveExtras but waits (up to `timeout` seconds) for the game to finish loading
    function Bedwars.WaitExtras(timeout)
        lastExtrasTry = 0
        local ready, reason = Bedwars.ResolveExtras()
        local rounds = math.ceil((timeout or 4) / 0.5)
        for _ = 1, rounds do
            if Bedwars.ExtrasReady then
                break
            end
            task.wait(0.5)
            lastExtrasTry = 0
            ready, reason = Bedwars.ResolveExtras()
        end
        return Bedwars.ExtrasReady == true, reason
    end

    -- Your own inventory as the game's UI store sees it: { inventory = { items, hand }, hotbar, hotbarSlot }
    function Bedwars.GetInventory()
        local store = Bedwars.Store
        if not store then
            return nil
        end
        local ok, inventory = pcall(function()
            return store:getState().Inventory.observedInventory
        end)
        if ok and type(inventory) == "table" and type(inventory.inventory) == "table" then
            return inventory
        end
        return nil
    end

    function Bedwars.GetItemImage(itemType)
        local meta = Bedwars.ItemMeta and Bedwars.ItemMeta[itemType]
        return meta and meta.image or ""
    end
end

-- ====================== MODULE: KILL AURA ======================
do
    local gate = {}
    local ReplicatedStorage = service("ReplicatedStorage")

    -- High Hitreg timing constants. The server runs combat on a 60 Hz tick, so a hit can only be
    -- accepted on a tick boundary; the scheduler below lines every send up with that grid.
    local SERVER_TICK = 1 / 60
    local SELF_LAG, SELF_LAG_LOW, SELF_LAG_HIGH = 0.09, 0.07, 0.11
    local TARGET_LAG, CLAIM_LAG, LAG_CAP = 0.12, 0.05, 8
    -- SERVER_SLACK sets how far past the real ~14.4 stud sword reach the position spoof is
    -- trusted (effective cap = reach + SERVER_SLACK - RANGE_MARGIN, so 6.0 here lands ~20 studs).
    -- Pushed up from 3.6 (~17.6 studs) at the user's request for more range; if it starts getting
    -- flagged or hits stop registering at the far end, drop this back toward 3.6-4.0.
    local SERVER_SLACK, RANGE_MARGIN, CLAIM_MARGIN = 6.0, 0.4, 1

    -- Potion that speeds up swings (changes the sword's cooldown)
    local furyState = { tried = false }
    local function furyMultiplier()
        if not furyState.tried then
            furyState.tried = true
            pcall(function()
                local ts = ReplicatedStorage.TS
                furyState.status = require(ts["status-effect"]["status-effect-util"]).StatusEffectUtil
                furyState.kind = require(ts["status-effect"]["status-effect-type"]).StatusEffectType
                furyState.mult = require(ts.balance["black-marketeer-balance"]).BlackMarketeerBalance.FURY_POTION_ATTACK_SPEED_MULTIPLIER
            end)
        end
        if not furyState.status then
            return 1
        end
        local ok, active = pcall(function()
            return furyState.status:isActive(LocalPlayer.Character, furyState.kind.FURY_POTION)
        end)
        if ok and active and type(furyState.mult) == "number" and furyState.mult > 0 then
            return furyState.mult > 1 and (1 / furyState.mult) or furyState.mult
        end
        return 1
    end

    -- The game adds a small buffer to the sword cooldown on the client; High Hitreg zeroes it and
    -- puts the original value back afterwards.
    local savedSwingBuffer
    local function setSwingBuffer(on)
        pcall(function()
            local consts = require(ReplicatedStorage.TS.combat["combat-constant"]).SwordsConstants
            if table.isfrozen(consts) and setreadonly then
                setreadonly(consts, false)
            end
            if on then
                if savedSwingBuffer == nil then
                    savedSwingBuffer = consts.swordSwingBufferMultiplier
                end
                consts.swordSwingBufferMultiplier = 0
            elseif savedSwingBuffer ~= nil then
                consts.swordSwingBufferMultiplier = savedSwingBuffer
                savedSwingBuffer = nil
            end
        end)
    end
    local aura = Tabs.Combat:CreateModule({
        Name = "Kill Aura",
        Description = "Sword aura for Bedwars.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local lastSend = 0
            local nextInterval = 0
            local usedSwing = 0
            local flashUntil = 0
            local lastHitText, lastHitAt = "", 0
            local autoRotateOverridden = nil
            local warnedUnavailable = false
            -- ===== High Hitreg scheduler state =====
            local strike = {
                lastSent = 0, nextAt = 0, gridDue = 0, lastSrv = 0, ratio = 0.98,
                accepted = nil, anchor = nil, pend = nil, shift = 0, lock = 0, prevOk = nil,
                cdel = nil, cdHigh = nil, up = nil, lastOkT = nil, wasStale = false,
                baseSpeed = 0.3, fury = 1, frame = 1 / 60, log = {},
            }
            local upSamples = {}                                  -- measured upload latency samples
            local otherHit = setmetatable({}, { __mode = "k" })  -- when someone else last damaged a model
            local damageHooked = false
            local swingBufferOn = false
            local bucket = { tokens = 4, stamp = os.clock() }
            local trailTimes, trailPos = {}, {}

            local function spendToken()
                local clock = os.clock()
                bucket.tokens = math.min(bucket.tokens + (clock - bucket.stamp) * 4.5, 4)
                bucket.stamp = clock
                if bucket.tokens < 1 then
                    return false
                end
                bucket.tokens = bucket.tokens - 1
                return true
            end

            -- Short history of where you were, so positions can be reported as the server saw them
            local function trackSelf(pos, clock)
                local count = #trailTimes
                if count > 0 and clock - trailTimes[count] > 0.25 then
                    table.clear(trailTimes)
                    table.clear(trailPos)
                end
                table.insert(trailTimes, clock)
                table.insert(trailPos, pos)
                while #trailTimes > 2 and clock - trailTimes[2] >= 0.3 do
                    table.remove(trailTimes, 1)
                    table.remove(trailPos, 1)
                end
            end

            local function selfAt(moment, fallback)
                local count = #trailTimes
                if count == 0 then
                    return fallback
                end
                if moment <= trailTimes[1] then
                    return trailPos[1]
                end
                for i = count, 2, -1 do
                    if trailTimes[i - 1] <= moment then
                        local span = trailTimes[i] - trailTimes[i - 1]
                        local alpha = span > 0 and (moment - trailTimes[i - 1]) / span or 1
                        return trailPos[i - 1]:Lerp(trailPos[i], math.clamp(alpha, 0, 1))
                    end
                end
                return trailPos[count]
            end

            local function lagOffset(vel, lag)
                local offset = vel * lag
                if offset.Magnitude > LAG_CAP then
                    return offset.Unit * LAG_CAP
                end
                return offset
            end

            local function serverDistance(seen, vel, clock, fallback)
                local low = selfAt(clock - SELF_LAG_LOW, fallback)
                local high = selfAt(clock - SELF_LAG_HIGH, fallback)
                local ref = seen - lagOffset(vel, TARGET_LAG)
                return math.max((seen - low).Magnitude, (seen - high).Magnitude, (ref - low).Magnitude, (ref - high).Magnitude)
            end

            -- A hit of yours was accepted by the server: learn the upload latency and anchor the next send to it
            local function noteLanded(target)
                local clock = os.clock()
                local ping0 = math.clamp(LocalPlayer:GetNetworkPing(), 0.005, 0.5)
                local maxAge = math.min(math.max((strike.cdel or 0.15) * 2.5, (strike.cdHigh or 0) * 1.3, ping0 * 2 + 0.2), 0.8)
                local entry
                local hitAt = target and target:GetAttribute("LastDamageTakenTime")
                for _, e in ipairs(strike.log) do
                    if not e.ok and not e.done and e.target == target then
                        local age = clock - e.t
                        if age >= 0 and age < maxAge then
                            if type(hitAt) == "number" and e.srv then
                                if e.srv <= hitAt + 0.02 and (not entry or e.t > entry.t) then
                                    entry = e
                                end
                            elseif not entry or e.t < entry.t then
                                entry = e
                            end
                        end
                    end
                end
                if not entry then
                    return
                end
                local age = clock - entry.t
                entry.ok = true
                strike.cdel = strike.cdel and (strike.cdel * 0.8 + age * 0.2) or age
                strike.cdHigh = math.max(age, (strike.cdHigh or age) * 0.97)
                local srvNow = Workspace:GetServerTimeNow()
                local ping = math.clamp(LocalPlayer:GetNetworkPing(), 0.005, 0.5)
                local landed = srvNow - ping
                local attr = target and target:GetAttribute("LastDamageTakenTime")
                local mixed = (otherHit[target] or 0) > entry.t - 0.05
                if not mixed and type(attr) == "number" and attr <= srvNow + 0.05 and attr >= srvNow - ping * 2 - 0.1 then
                    landed = attr
                    entry.srvGap = strike.accepted and attr - strike.accepted or nil
                    strike.accepted = math.max(strike.accepted or 0, attr)
                    if entry.srv and #upSamples >= 5 then
                        local sorted = table.clone(upSamples)
                        table.sort(sorted)
                        local p75 = sorted[math.floor(0.75 * (#sorted - 1)) + 1]
                        landed = math.min(attr, entry.srv + p75)
                    end
                    if entry.srv then
                        local up = attr - entry.srv
                        if up > 0 and up < 0.5 then
                            strike.up = strike.up and (strike.up * 0.8 + up * 0.2) or up
                            table.insert(upSamples, up)
                            if #upSamples > 30 then
                                table.remove(upSamples, 1)
                            end
                        end
                    end
                end
                strike.lastOkT = math.max(strike.lastOkT or 0, entry.t)
                if not strike.anchor or landed > strike.anchor then
                    strike.anchor = landed
                end
            end

            -- Whole server ticks between two hits: lo = the fastest the server accepts, hi = the safe pace
            local function tickRange()
                local speed = (strike.baseSpeed or 0.3) * (strike.fury or 1)
                local hi = math.max(math.ceil(speed / SERVER_TICK - 0.001), 1)
                local lo = math.min(math.max(math.floor(speed * 0.95 / SERVER_TICK + 0.5), 1), hi)
                return lo, hi
            end

            local function gapFloor()
                local lo = tickRange()
                return lo * SERVER_TICK
            end

            -- True when the next hit may go out now. With enough latency samples the send is timed so it
            -- ARRIVES exactly one floor after the last accepted hit; before that it paces on a fixed grid.
            local function anchorOpen(openAt)
                local floor = gapFloor()
                local srvNow = Workspace:GetServerTimeNow()
                local due
                if strike.accepted and srvNow - strike.accepted < 1 and #upSamples >= 5 then
                    local sorted = table.clone(upSamples)
                    table.sort(sorted)
                    local upMid = sorted[math.floor(#sorted / 2) + 1]
                    local stale = strike.pend ~= nil and not strike.pend.ok
                    local spread = sorted[math.floor(#sorted * 0.9) + 1] - sorted[math.floor(#sorted * 0.1) + 1]
                    local base = (strike.lastSent or 0) + (stale and floor + math.clamp(spread, 0, SERVER_TICK) or floor)
                    due = math.max(base, os.clock() + (strike.accepted + floor - upMid - srvNow + (strike.shift or 0)))
                    strike.wasStale = stale
                else
                    strike.wasStale = false
                    local _, hi = tickRange()
                    due = math.max(openAt or 0, strike.gridDue or 0, (strike.lastSent or 0) + hi * SERVER_TICK)
                end
                local left = due - os.clock()
                -- Less than a frame to go: wait it out so the send isn't a whole frame late
                if left > 0 and left < math.min(strike.frame or SERVER_TICK, SERVER_TICK) then
                    repeat until os.clock() >= due
                    left = 0
                end
                return left <= 0
            end

            -- Looks at recent sends and nudges the timing offset: a miss right after a hit means too early,
            -- a hit that came a whole extra tick later means we can go slightly sooner
            local function tune()
                local clock = os.clock()
                local settle = math.clamp(math.max((strike.cdHigh or 0) * 1.25, LocalPlayer:GetNetworkPing() * 2 + 0.15), 0.25, 0.8)
                for _, entry in ipairs(strike.log) do
                    if not entry.done and clock - entry.t > settle then
                        entry.done = true
                        local body = entry.target
                        local hum = body and body.Parent and body:FindFirstChildOfClass("Humanoid")
                        if hum and hum.Health > 0 and not body:FindFirstChildOfClass("ForceField") then
                            local lo = tickRange()
                            strike.lock = math.max((strike.lock or 0) - 1, 0)
                            if entry.ok then
                                local gapTicks = entry.srvGap and entry.srvGap / SERVER_TICK
                                if not entry.stale and gapTicks and gapTicks > lo + 0.5 and gapTicks < lo * 1.5 then
                                    strike.shift = math.max((strike.shift or 0) - 0.0005, -0.05)
                                end
                                strike.prevOk = true
                            else
                                if strike.prevOk and strike.lock <= 0 and not entry.stale and not ((otherHit[body] or 0) > entry.t - 0.3) then
                                    strike.shift = math.min((strike.shift or 0) + 0.0005 * lo, SERVER_TICK)
                                    strike.lock = 5
                                end
                                strike.prevOk = false
                            end
                        end
                    end
                end
            end

            -- Fallback when the game's damage event can't be hooked: watch the target's own damage timestamp
            local function pollLanded()
                if damageHooked then
                    return
                end
                for _, e in ipairs(strike.log) do
                    if not e.ok and not e.done and e.target and e.target.Parent then
                        local current = e.target:GetAttribute("LastDamageTakenTime")
                        if current ~= nil and current ~= e.before then
                            noteLanded(e.target)
                        end
                    end
                end
            end

            pcall(function()
                local network = require(LocalPlayer.PlayerScripts.TS.lib.network)
                local zap = network and network.EntityDamageEventZap
                if zap and type(zap.On) == "function" then
                    local disconnect = zap.On(function(victim, _, damageType, _, from)
                        if not mod.Enabled or not cfg.HighHitreg then
                            return
                        end
                        local mine = LocalPlayer.Character
                        if (from == mine or from == LocalPlayer) and victim and victim ~= mine and damageType == 0 then
                            noteLanded(victim)
                        elseif victim and from ~= mine and from ~= LocalPlayer then
                            otherHit[victim] = os.clock()
                        end
                    end)
                    if type(disconnect) == "function" then
                        mod.Maid:Give(disconnect)
                    end
                    damageHooked = true
                end
            end)

            local setStatus = makeStatusLabel(mod, "Kill Aura", -100)

            local box = mod.Maid:Give(New("BoxHandleAdornment", {
                Size = Vector3.new(3.6, 5.2, 3.6),
                CFrame = CFrame.new(0, -0.55, 0),
                Transparency = 0.7,
                Color3 = Theme.Accent,
                AlwaysOnTop = true,
                ZIndex = 1,
                Adornee = nil,
                Parent = UI.Gui,
            }))

            local function releaseRotation(hum)
                if autoRotateOverridden ~= nil and hum then
                    pcall(function()
                        hum.AutoRotate = autoRotateOverridden
                    end)
                end
                autoRotateOverridden = nil
            end

            -- Mouse gate. Bedwars swings on click, so a swing the game just made also counts as "held".
            local function mouseOk()
                if not cfg.RequireMouseDown then
                    return true
                end
                local right = cfg.MouseButton == "Right"
                if Util.IsMouseDown(right) then
                    gate.LastActive = os.clock()
                    return true
                end
                local swung = tonumber(Bedwars.SwordController.lastSwing) or 0
                if not right and tick() - swung < 0.25 then
                    gate.LastActive = os.clock()
                    return true
                end
                return os.clock() - (gate.LastActive or 0) <= 0.2
            end

            -- Returns nil when the entry is a valid target, otherwise a short reason
            local function whyNot(entry, root, head, camLook, bodyLook, halfCos)
                local isNpc = entry.Player == nil
                if cfg.Targets == "Players" and isNpc then
                    return "is an NPC (set Targets to Players + NPCs)"
                end
                if cfg.Targets == "NPCs Only" and not isNpc then
                    return "is a player (Targets = NPCs Only)"
                end
                if entry.Player then
                    if cfg.TeamCheck and Util.IsTeammate(entry.Player) then
                        return "is on your team"
                    end
                    if entry.Player:GetAttribute("Spectator") then
                        return "is spectating"
                    end
                end
                local offset = entry.Root.Position - root.Position
                local distance = offset.Magnitude
                if distance > cfg.Range then
                    return string.format("is %.1f studs away (Range %.1f)", distance, cfg.Range)
                end
                if cfg.Angle < 360 then
                    local flat = Vector3.new(offset.X, 0, offset.Z)
                    if flat.Magnitude >= 0.01 then
                        local toward = flat.Unit
                        -- Either the camera or the body facing the target is enough (first person vs third person)
                        if camLook:Dot(toward) < halfCos and bodyLook:Dot(toward) < halfCos then
                            return "is outside Max Angle"
                        end
                    end
                end
                if cfg.WallCheck then
                    local seen = Util.HasStrictSight(head.Position, entry.Root.Position)
                    if not seen then
                        return "is behind a wall"
                    end
                end
                return nil
            end

            local function flatUnit(vector, fallback)
                local flat = Vector3.new(vector.X, 0, vector.Z)
                if flat.Magnitude < 0.001 then
                    return fallback
                end
                return flat.Unit
            end

            local function collectTargets(char, root, cam)
                local head = char:FindFirstChild("Head") or root
                local bodyLook = flatUnit(root.CFrame.LookVector, Vector3.new(0, 0, -1))
                local camLook = cam and flatUnit(cam.CFrame.LookVector, bodyLook) or bodyLook
                local halfCos = math.cos(math.rad(cfg.Angle) / 2)

                local valid = {}
                local nearest, nearestDistance, nearestReason = nil, math.huge, nil
                for _, entry in ipairs(Util.GetTargets(cfg.Targets)) do
                    local reason = whyNot(entry, root, head, camLook, bodyLook, halfCos)
                    local offset = entry.Root.Position - root.Position
                    if not reason then
                        local score = offset.Magnitude
                        if cfg.Sort == "Health" then
                            score = entry.Humanoid.Health + offset.Magnitude * 0.001
                        elseif cfg.Sort == "Angle" then
                            local toward = flatUnit(offset, camLook)
                            score = -camLook:Dot(toward)
                        end
                        valid[#valid + 1] = { Entry = entry, Score = score, Distance = offset.Magnitude }
                    elseif offset.Magnitude < nearestDistance then
                        nearest, nearestDistance, nearestReason = entry, offset.Magnitude, reason
                    end
                end
                table.sort(valid, function(a, b)
                    return a.Score < b.Score
                end)
                local reasonText = nearest and (tostring(nearest.Name) .. " " .. nearestReason) or "no other players or NPCs found"
                return valid, reasonText
            end

            local function playSwing(meta)
                pcall(function()
                    Bedwars.SwordController:playSwordEffect(meta, false)
                end)
            end

            -- High Hitreg: one scheduling pass. Sends only when the tick-aligned window is open.
            local function strikeStep(root, item, meta, reachable, leadText, swung)
                local weapon = meta.sword
                local baseSpeed = (type(weapon.attackSpeed) == "number" and weapon.attackSpeed > 0) and weapon.attackSpeed or 0.3
                local furyNow = furyMultiplier()
                strike.baseSpeed, strike.fury = baseSpeed, furyNow
                local cooldown = baseSpeed * furyNow
                strike.interval = cooldown * strike.ratio

                -- A swing the game made on its own (your own click) also starts the cooldown
                if not cfg.SwingOnly then
                    local last = tonumber(Bedwars.SwordController.lastAttack) or 0
                    if last > strike.lastSrv + 0.005 then
                        strike.lastSrv = last
                        local at = os.clock() - math.max(Workspace:GetServerTimeNow() - last, 0)
                        strike.nextAt = math.max(strike.nextAt, at + strike.interval)
                    end
                end

                pollLanded()

                local open = anchorOpen(strike.nextAt)
                if not open or (os.clock() - strike.lastSent) < cfg.MinInterval or not spendToken() then
                    if os.clock() - lastHitAt < 0.5 and lastHitText ~= "" then
                        setStatus(cfg.StatusLine, lastHitText)
                    else
                        setStatus(cfg.StatusLine, "target " .. leadText)
                    end
                    return
                end

                -- Report positions the way the server saw them a moment ago, always inside its reach
                local clockNow = os.clock()
                local rootNow = root.Position
                local selfBase = selfAt(clockNow - SELF_LAG, rootNow)
                local serverReach = (type(Bedwars.ReachLimit) == "number" and Bedwars.ReachLimit > 0 and Bedwars.ReachLimit <= 16)
                    and Bedwars.ReachLimit or 14.4
                local baseReach = (type(weapon.attackRange) == "number" and weapon.attackRange > 0) and weapon.attackRange or serverReach
                local rangeLimit = math.min(cfg.Range, baseReach + SERVER_SLACK - RANGE_MARGIN)

                local sent, failure, leadModel = 0, nil, nil
                local sentAt = os.clock()
                for index = 1, math.min(cfg.MaxTargets, #reachable) do
                    local entry = reachable[index].Entry
                    local targetRoot = entry.Root
                    local targetSeen = targetRoot.Position
                    local targetVel = targetRoot.AssemblyLinearVelocity
                    if serverDistance(targetSeen, targetVel, clockNow, rootNow) > rangeLimit then
                        failure = "too far for the server"
                    else
                        local targetAt = targetSeen - lagOffset(targetVel, CLAIM_LAG)
                        local claimGap = targetAt - selfBase
                        local aimDir = claimGap.Magnitude > 0.001 and claimGap.Unit or Vector3.new(0, -1, 0)
                        local selfReport = targetAt - aimDir * math.min(claimGap.Magnitude, baseReach - CLAIM_MARGIN)
                        sentAt = os.clock()
                        local ok, err = Bedwars.SendHit(item, entry.Model, rootNow, targetAt, { Self = selfReport, Dir = aimDir })
                        if ok then
                            sent = sent + 1
                            leadModel = leadModel or entry.Model
                        else
                            failure = err
                        end
                    end
                end

                if sent == 0 then
                    setStatus(cfg.StatusLine, leadText .. " - " .. tostring(failure))
                    return
                end

                -- Advance the tick grid by exactly one spacing so a late frame doesn't push every later hit back
                local spacing = gapFloor()
                local grid = strike.gridDue or 0
                strike.gridDue = (grid > 0 and sentAt - grid < spacing) and grid + spacing or sentAt + spacing
                strike.nextAt = strike.gridDue
                strike.lastSent = sentAt
                local record = {
                    t = sentAt, ok = false, target = leadModel, stale = strike.wasStale,
                    srv = Workspace:GetServerTimeNow(),
                    before = leadModel and leadModel:GetAttribute("LastDamageTakenTime"),
                }
                table.insert(strike.log, record)
                strike.pend = record
                if #strike.log > 40 then
                    table.remove(strike.log, 1)
                end
                tune()

                if not cfg.SwingOnly then
                    pcall(function()
                        Bedwars.SwordController.lastAttack = Workspace:GetServerTimeNow()
                    end)
                end
                strike.lastSrv = math.max(Workspace:GetServerTimeNow(), tonumber(Bedwars.SwordController.lastAttack) or 0)

                if cfg.SwingOnly then
                    usedSwing = swung
                elseif cfg.SwingAnimation then
                    playSwing(meta)
                end
                flashUntil = sentAt + 0.12
                lastHitAt = sentAt
                lastHitText = "hit " .. leadText .. ((sent > 1) and (" +" .. (sent - 1)) or "")
                setStatus(cfg.StatusLine, lastHitText)
            end

            mod.Maid:Give(RunService.Heartbeat:Connect(function(dt)
                local char, hum, root = Util.GetCharacter(LocalPlayer)
                local function idle(text)
                    box.Adornee = nil
                    releaseRotation(hum)
                    setStatus(cfg.StatusLine, text)
                end

                local ready, why = Bedwars.Resolve()
                if not ready then
                    if not warnedUnavailable then
                        warnedUnavailable = true
                        Nova.Notify("Kill Aura", tostring(why), 5, "error", true)
                    end
                    idle("unavailable - " .. tostring(why))
                    return
                end
                warnedUnavailable = false

                if not char or hum.Health <= 0 then
                    idle("waiting for your character")
                    return
                end

                if cfg.HighHitreg then
                    strike.frame = strike.frame * 0.9 + math.clamp(dt, 0.003, 0.05) * 0.1
                    trackSelf(root.Position, os.clock())
                end
                if (cfg.HighHitreg and true or false) ~= swingBufferOn then
                    swingBufferOn = cfg.HighHitreg and true or false
                    setSwingBuffer(swingBufferOn)
                end

                local stunned = char:GetAttribute("StunnedUntilTime")
                if type(stunned) == "number" and stunned > Workspace:GetServerTimeNow() then
                    idle("stunned")
                    return
                end

                if not mouseOk() then
                    idle("hold the " .. string.lower(tostring(cfg.MouseButton)) .. " mouse button (Require Mouse Down)")
                    return
                end

                local item, meta = Bedwars.GetHeldSword()
                if not item then
                    idle(tostring(meta))
                    return
                end

                -- Swing Only: only attack right after a swing you made yourself (one hit per swing)
                local swordSpeed = (type(meta.sword.attackSpeed) == "number") and meta.sword.attackSpeed or 0.3
                local swung = tonumber(Bedwars.SwordController.lastSwing) or 0
                if cfg.SwingOnly then
                    local fresh = swung > usedSwing and tick() - swung <= math.max(swordSpeed, 0.3) + 0.1
                    if not fresh then
                        idle("swing your sword to attack (Swing Only)")
                        return
                    end
                end

                local cam = Workspace.CurrentCamera
                local targets, reason = collectTargets(char, root, cam)
                if #targets == 0 then
                    idle("no target - " .. tostring(reason))
                    return
                end

                -- All targets inside the user's Range; SendHit spoofs reach for the server
                local reachable = targets
                local lead = targets[1]
                local leadEntry = lead.Entry
                local leadText = string.format("%s (%.1f studs)", tostring(leadEntry.Name), lead.Distance)
                local now = os.clock()
                SharedAimTarget.Entry, SharedAimTarget.At = leadEntry, now

                if cfg.ShowTarget then
                    box.Adornee = leadEntry.Root
                    box.Color3 = (now < flashUntil) and Color3.fromRGB(235, 215, 255) or Theme.Accent
                else
                    box.Adornee = nil
                end

                if cfg.FaceTarget then
                    local flatTo = Vector3.new(leadEntry.Root.Position.X - root.Position.X, 0, leadEntry.Root.Position.Z - root.Position.Z)
                    if flatTo.Magnitude > 0.1 then
                        if autoRotateOverridden == nil then
                            autoRotateOverridden = hum.AutoRotate
                        end
                        hum.AutoRotate = false
                        local goal = CFrame.lookAt(root.Position, root.Position + flatTo)
                        root.CFrame = root.CFrame:Lerp(goal, math.clamp(1 - math.exp(-14 * dt), 0, 1))
                    end
                else
                    releaseRotation(hum)
                end

                if cfg.HighHitreg then
                    strikeStep(root, item, meta, reachable, leadText, swung)
                    return
                end

                -- Standard timing: the sword's own attack speed is the interval
                local swordFloor = (type(meta.sword.attackSpeed) == "number") and meta.sword.attackSpeed or 0.2
                local interval = math.max(cfg.MinInterval, swordFloor)
                local attackCooldown = swordFloor
                if nextInterval == 0 then
                    nextInterval = interval
                end
                local serverNow = Workspace:GetServerTimeNow()
                local lastGameSwing = tonumber(Bedwars.SwordController.lastAttack) or 0
                local gameCooldown = math.max((lastGameSwing + attackCooldown) - serverNow, 0)
                local tooSoon = (now - lastSend) < nextInterval
                if gameCooldown > 0.00025 then
                    tooSoon = true
                end
                if not cfg.SwingOnly then
                    if serverNow - lastGameSwing < nextInterval * 0.9 then
                        tooSoon = true
                    end
                end
                if tooSoon then
                    if now - lastHitAt < 0.5 and lastHitText ~= "" then
                        setStatus(cfg.StatusLine, lastHitText)
                    else
                        setStatus(cfg.StatusLine, "target " .. leadText)
                    end
                    return
                end

                local sent, failure = 0, nil
                for index = 1, math.min(cfg.MaxTargets, #reachable) do
                    local entry = reachable[index].Entry
                    local ok, err = Bedwars.SendHit(item, entry.Model, root.Position, entry.Root.Position)
                    if ok then
                        sent = sent + 1
                    else
                        failure = err
                    end
                end

                if sent > 0 then
                    lastSend = now
                    flashUntil = now + 0.12
                    nextInterval = interval * (cfg.RandomizeInterval and (0.95 + math.random() * 0.2) or 1)
                    -- Stamp lastAttack on every successful send (the game's own cooldown gate reads it)
                    pcall(function()
                        Bedwars.SwordController.lastAttack = Workspace:GetServerTimeNow()
                    end)
                    if cfg.SwingOnly then
                        usedSwing = swung
                    else
                        if cfg.SwingAnimation then
                            playSwing(meta)
                        end
                    end
                    lastHitAt = now
                    lastHitText = "hit " .. leadText .. ((sent > 1) and (" +" .. (sent - 1)) or "")
                    setStatus(cfg.StatusLine, lastHitText)
                else
                    setStatus(cfg.StatusLine, leadText .. " - " .. tostring(failure))
                end
            end))

            mod.Maid:Give(function()
                local _, hum = Util.GetCharacter(LocalPlayer)
                releaseRotation(hum)
                swingBufferOn = false
                setSwingBuffer(false)
            end)
        end,
    })

    aura:AddSection("Targeting")
    aura:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players" })
    aura:AddSlider({ Label = "Range", Key = "Range", Min = 3, Max = 22, Default = 12, Step = 0.1, Suffix = " studs", Tip = "Hits only register up to the server's reach (currently spoofed out to about 18 studs)." })
    aura:AddSlider({ Label = "Max Angle", Key = "Angle", Min = 30, Max = 360, Default = 180, Step = 5, Suffix = "°", Tip = "Field of view in front of you. 360 hits all around." })
    aura:AddSlider({ Label = "Max Targets", Key = "MaxTargets", Min = 1, Max = 5, Default = 1, Step = 1 })
    aura:AddOption({ Label = "Sort", Key = "Sort", Options = { "Distance", "Health", "Angle" }, Default = "Distance" })
    aura:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true })
    aura:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true })
    aura:AddSection("Timing")
    aura:AddSlider({ Label = "Min Interval", Key = "MinInterval", Min = 0.05, Max = 0.6, Default = 0.05, Step = 0.01, Suffix = "s", Tip = "The sword's own attack speed is the real minimum." })
    aura:AddToggle({
        Label = "High Hitreg",
        Key = "HighHitreg",
        Default = false,
        Tip = "Times every hit to land on the server's tick right after your last accepted hit. 36 hits / 10s with a stock sword.",
    })
    aura:AddLabel("Hits are lined up with the server's 60 Hz tick and timed from your measured latency. Randomize Interval is ignored while this is on.", {
        ShowIf = function(c) return c.HighHitreg end,
    })
    aura:AddToggle({ Label = "Randomize Interval", Key = "RandomizeInterval", Default = false, Tip = "Varies the delay between hits slightly." })
    aura:AddSection("Activation")
    aura:AddToggle({ Label = "Swing Only", Key = "SwingOnly", Default = false, Tip = "One hit per click you make." })
    aura:AddToggle({ Label = "Require Mouse Down", Key = "RequireMouseDown", Default = false, Tip = "Only attack while you hold a mouse button." })
    aura:AddOption({ Label = "Mouse Button", Key = "MouseButton", Options = { "Left", "Right" }, Default = "Left", ShowIf = function(c) return c.RequireMouseDown end })
    aura:AddSection("Visuals")
    aura:AddToggle({ Label = "Swing Animation", Key = "SwingAnimation", Default = true, ShowIf = function(c) return not c.SwingOnly end })
    aura:AddToggle({ Label = "Face Target", Key = "FaceTarget", Default = false })
    aura:AddToggle({ Label = "Show Target", Key = "ShowTarget", Default = true, Tip = "Highlight who you are hitting." })
    aura:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true, Tip = "Small readout at the bottom of the screen." })
    aura:AddSection("About")
    aura:AddLabel("Bedwars only. Hold a sword. Hits use your real position, so they only register up to the server's reach (about 14.4 studs); targets further out just get a swing. The sword's own attack speed is the minimum interval. Swing Only = one hit per click you make.")
end

-- ====================== MODULE: BEDWARS PROJECTILE AIM ======================
-- Redirects the arrow / fireball / pearl you release so it lands on the target. It hooks the game's
-- own launch calculation (your camera never moves), keeps the game's draw timing, and solves a
-- real ballistic intercept against where the target will be when the shot arrives.
do
    local CollectionService = service("CollectionService")
    local JUMP_SPEED = 42.6          -- upward speed of a Bedwars jump
    local FLOATY_MARKER = "rbxassetid://8200754399"
    local MAX_LEAD_SPEED = 60        -- a target never leads faster than this horizontally

    local function wordSet(text)
        local list = {}
        for word in tostring(text or ""):gmatch("[^,;]+") do
            word = word:lower():match("^%s*(.-)%s*$")
            if word ~= "" then
                list[#list + 1] = word
            end
        end
        return list
    end

    -- Map-only raycasts (arrows fly through players, so only level geometry blocks a shot)
    local rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Include
    local rayMap
    local function refreshRayParams()
        local map = Workspace:FindFirstChild("Map")
        if map ~= rayMap or not map or not map.Parent then
            rayMap = map
            if map and map.Parent then
                rayParams.FilterType = Enum.RaycastFilterType.Include
                rayParams.FilterDescendantsInstances = { map }
            else
                rayParams.FilterType = Enum.RaycastFilterType.Exclude
                rayParams.FilterDescendantsInstances = { LocalPlayer.Character, Workspace.CurrentCamera }
            end
        end
        return rayMap ~= nil
    end

    local splashParams = RaycastParams.new()
    splashParams.FilterType = Enum.RaycastFilterType.Include
    -- Fireballs splash: aim at the ground under a grounded target instead of at their body
    local function splashAimPoint(root, hip)
        local map = Workspace:FindFirstChild("Map")
        if not map or not root then
            return nil
        end
        if math.abs(root.AssemblyLinearVelocity.Y) > 2 then
            return nil
        end
        splashParams.FilterDescendantsInstances = { map }
        local hit = Workspace:Raycast(root.Position, Vector3.new(0, -((hip or 2) + root.Size.Y / 2 + 0.6), 0), splashParams)
        if hit then
            return Vector3.new(root.Position.X, hit.Position.Y + 0.5, root.Position.Z)
        end
        return nil
    end

    -- Effective gravity for a target hanging from balloons
    local function balloonGravity(balloons, char)
        local lift = balloons >= 4 and 1.2 or balloons >= 3 and 1.1 or balloons >= 2 and 0.975 or 0.85
        local root = char and char.PrimaryPart
        local vy = root and root.AssemblyLinearVelocity.Y or 0
        return Workspace.Gravity * (1 - lift) + 0.1731 * vy * math.abs(vy)
    end

    -- Height of the floor under the target, expressed at the height of the aim point
    local function floorLevel(root, hip, aimY)
        if not refreshRayParams() then
            return nil
        end
        local hit = Workspace:Raycast(root.Position, Vector3.new(0, -300, 0), rayParams)
        if not hit then
            return nil
        end
        return hit.Position.Y + (hip or 2) + root.Size.Y / 2 + (aimY - root.Position.Y)
    end

    -- Lowest flight time at which a projectile launched at `speed` can meet the target.
    -- pathAt(t) = predicted target position after t seconds. Fine scan, then bisect, then Newton.
    -- Returns velocity (unit * speed), flightTime  or nil.
    local function solveLaunch(from, speed, gravity, pathAt, maxTime)
        if speed < 1 or maxTime < 0.05 then
            return nil
        end
        local function need(t)
            if t < 1e-4 then
                t = 1e-4
            end
            return (pathAt(t) - from + Vector3.new(0, 0.5 * gravity * t * t, 0)) / t
        end
        local function excess(t)
            return need(t).Magnitude - speed
        end

        local step = 0.012
        local t = 0.03
        local previous = nil
        local low, high = nil, nil
        while t <= maxTime do
            if excess(t) <= 0 then
                high = t
                low = previous or math.max(t - step, 0.02)
                break
            end
            previous = t
            t = t + step
        end
        if not high then
            return nil
        end
        for _ = 1, 28 do
            local mid = (low + high) * 0.5
            if excess(mid) > 0 then
                low = mid
            else
                high = mid
            end
        end
        local bestT = high
        for _ = 1, 6 do
            local e0 = excess(bestT)
            local e1 = excess(bestT + 1e-3)
            local deriv = (e1 - e0) / 1e-3
            if math.abs(deriv) < 1e-6 then
                break
            end
            local nextT = bestT - e0 / deriv
            if nextT < 0.02 or nextT > maxTime then
                break
            end
            bestT = nextT
            if math.abs(e0) < 0.05 then
                break
            end
        end
        local velocity = need(bestT)
        if velocity.Magnitude < 0.001 then
            return nil
        end
        return velocity.Unit * speed, bestT
    end

    -- Samples the arc and checks nothing solid is in the way
    local function arcIsClear(from, velocity, gravity, flightTime)
        if not refreshRayParams() then
            return true
        end
        local previous = from
        for i = 1, 14 do
            local t = flightTime * (i / 14) * 0.97
            local point = from + velocity * t - Vector3.new(0, 0.5 * gravity * t * t, 0)
            if Workspace:Raycast(previous, point - previous, rayParams) then
                return false
            end
            previous = point
        end
        return true
    end

    -- Where "the crosshair" is: screen centre in first person / locked mouse, otherwise the cursor
    local function aimReference(cam)
        if Util.IsFirstPerson() or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
            return cam.ViewportSize / 2
        end
        return UserInputService:GetMouseLocation()
    end

    local aim = Tabs.Combat:CreateModule({
        Name = "Projectile Aimbot",
        Description = "Leads moving targets with bows and projectiles (Bedwars).",
        OnEnable = function(mod)
            local cfg = mod.Config
            local active = true
            local controller, original, hadOwn
            local installed = false
            local lastTryAt = 0
            local lastTarget, lastTargetAt = nil, 0
            local lockedRandomPart = nil
            local cursorHidden = false
            local history = setmetatable({}, { __mode = "k" }) -- [root] = { {t, p}, ... }

            local setStatus = makeStatusLabel(mod, "Projectile Aimbot", -130)

            local box = mod.Maid:Give(New("BoxHandleAdornment", {
                Size = Vector3.new(3.6, 5.2, 3.6),
                CFrame = CFrame.new(0, -0.55, 0),
                Transparency = 0.7,
                Color3 = Theme.Accent,
                AlwaysOnTop = true,
                ZIndex = 1,
                Adornee = nil,
                Parent = UI.Gui,
            }))

            local circle
            if HAS_DRAWING then
                circle = mod.Maid:Give(Drawing.new("Circle"))
                circle.Thickness = 1
                circle.NumSides = 64
                circle.Filled = false
                circle.Color = Theme.Accent
                circle.Transparency = 0.8
                circle.Visible = false
            end

            -- Short position history; only used when the replicated velocity reads zero for a target
            -- that is clearly moving (players that move by teleporting their position)
            local function sampleRoot(root)
                local now = os.clock()
                local list = history[root]
                if not list then
                    list = {}
                    history[root] = list
                end
                list[#list + 1] = { t = now, p = root.Position }
                while #list > 12 or (#list > 0 and now - list[1].t > 0.35) do
                    table.remove(list, 1)
                end
            end

            local function measuredVelocity(root)
                local list = history[root]
                if not list or #list < 2 then
                    return nil
                end
                local a, b = list[1], list[#list]
                local dt = b.t - a.t
                if dt < 0.05 then
                    return nil
                end
                return (b.p - a.p) / dt
            end

            local function heldName()
                local char = LocalPlayer.Character
                local hand = char and char:FindFirstChild("HandInvItem")
                local item = hand and hand.Value
                return item and item.Name or nil
            end

            local function shouldWork()
                local mode = cfg.WorkMode or "Both"
                local first = Util.IsFirstPerson()
                if mode == "First Person" then
                    return first
                elseif mode == "Third Person" then
                    return not first
                end
                return true
            end

            local function isBlacklisted(projectileName)
                if not cfg.OtherProjectiles then
                    local turret = projectileName:find("turret", 1, true) ~= nil or projectileName:find("vulcan", 1, true) ~= nil
                    return not projectileName:find("arrow", 1, true) and not turret and not projectileName:find("owl", 1, true)
                end
                for _, word in ipairs(wordSet(cfg.Blacklist)) do
                    if projectileName:find(word, 1, true) then
                        return true
                    end
                end
                return false
            end

            local function pickRandomPart(char)
                local roll = math.random(1, 100)
                local headChance = tonumber(cfg.HeadChance) or 50
                local torsoChance = tonumber(cfg.TorsoChance) or 50
                if roll <= headChance then
                    return char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
                elseif roll <= headChance + torsoChance then
                    return char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso") or char:FindFirstChild("HumanoidRootPart")
                end
                return char:FindFirstChild("HumanoidRootPart")
            end

            local CLOSEST_PARTS = {
                "HumanoidRootPart", "Head", "LeftHand", "RightHand", "LeftLowerArm", "RightLowerArm",
                "LeftUpperArm", "RightUpperArm", "LeftFoot", "RightFoot", "LeftLowerLeg", "RightLowerLeg",
                "LeftUpperLeg", "RightUpperLeg", "LowerTorso", "UpperTorso",
            }
            local function closestPart(char, cam)
                local point = aimReference(cam)
                local ray = cam:ViewportPointToRay(point.X, point.Y, 0)
                local bestAngle, bestPart = math.huge, nil
                for _, name in ipairs(CLOSEST_PARTS) do
                    local part = char:FindFirstChild(name)
                    if part then
                        local toPart = part.Position - ray.Origin
                        if toPart.Magnitude > 0.01 then
                            local angle = math.acos(math.clamp(ray.Direction:Dot(toPart.Unit), -1, 1))
                            if angle < bestAngle then
                                bestAngle, bestPart = angle, part
                            end
                        end
                    end
                end
                return bestPart or char:FindFirstChild("HumanoidRootPart")
            end

            local function choosePart(entry, projmeta, tool, cam)
                local mode = cfg.Part or "Dynamic"
                local char = entry.Model
                local head = char:FindFirstChild("Head")
                if mode == "Head" then
                    return head or entry.Root
                elseif mode == "Closest" then
                    return closestPart(char, cam) or entry.Root
                elseif mode == "Randomize" then
                    if lockedRandomPart and lockedRandomPart.Parent ~= char then
                        lockedRandomPart = nil
                    end
                    if not lockedRandomPart or not lockedRandomPart.Parent then
                        lockedRandomPart = pickRandomPart(char)
                    end
                    return lockedRandomPart or entry.Root
                elseif mode == "Dynamic" then
                    local text = string.lower(tostring(tool and tool.Name or "") .. " " .. tostring(projmeta and projmeta.projectile or ""))
                    if text:find("headhunter", 1, true) and head then
                        return head
                    end
                end
                return entry.Root
            end

            -- Best target near the crosshair / by distance / by health
            local function pickTarget(origin, cam)
                local best, bestScore = nil, math.huge
                local reference = aimReference(cam)
                local fov = tonumber(cfg.FOV) or 300
                local range = tonumber(cfg.Range) or 100
                local sortMode = cfg.Sort or "Cursor"
                for _, entry in ipairs(Util.GetTargets(cfg.Targets or "Players + NPCs")) do
                    local root, hum = entry.Root, entry.Humanoid
                    if root and root.Parent and hum and hum.Health > 0
                        and not (cfg.TeamCheck and entry.Player and Util.IsTeammate(entry.Player)) then
                        local dist = (root.Position - origin).Magnitude
                        if dist <= range then
                            local sp, onScreen = cam:WorldToViewportPoint(root.Position)
                            local pixels = (Vector2.new(sp.X, sp.Y) - reference).Magnitude
                            if onScreen and sp.Z > 0 and pixels <= fov then
                                local score = pixels
                                if sortMode == "Distance" then
                                    score = dist
                                elseif sortMode == "Health" or sortMode == "Damage" then
                                    score = hum.Health
                                end
                                if score < bestScore and (not cfg.WallCheck or Util.HasLineOfSight(origin, root.Position)) then
                                    best, bestScore = entry, score
                                end
                            end
                        end
                    end
                end
                return best
            end

            -- Rewrites the game's launch table so the projectile heads for the predicted intercept
            local function aimShot(native, selfController, projmeta, worldmeta, tool, shootpos)
                if not shouldWork() then
                    return nil
                end
                local cam = Workspace.CurrentCamera
                local _, _, myRoot = Util.GetCharacter(LocalPlayer)
                if not cam or not myRoot then
                    return nil
                end
                local originPos = (typeof(shootpos) == "Vector3" and shootpos) or myRoot.Position

                local entry = pickTarget(originPos, cam)
                if not entry then
                    lockedRandomPart = nil
                    return nil
                end
                local root, hum = entry.Root, entry.Humanoid
                sampleRoot(root)

                local projectileName = tostring(projmeta and projmeta.projectile or ""):lower()
                if isBlacklisted(projectileName) then
                    return nil
                end

                local part = choosePart(entry, projmeta, tool, cam)
                if not part then
                    return nil
                end
                if (part.Position - originPos).Magnitude > (tonumber(cfg.Range) or 100) then
                    return nil
                end

                -- Projectile data
                local meta, overrides = {}, {}
                pcall(function()
                    if projmeta and type(projmeta.getProjectileMeta) == "function" then
                        meta = projmeta:getProjectileMeta() or {}
                        if type(meta.getProjectileOverridesFunction) == "function" then
                            overrides = meta.getProjectileOverridesFunction(LocalPlayer) or {}
                        end
                    end
                end)
                if type(meta) ~= "table" then meta = {} end
                if type(overrides) ~= "table" then overrides = {} end

                local predictionLifetime = tonumber(overrides.predictionLifetimeOverride) or tonumber(meta.predictionLifetimeSec)
                local normalLifetime = tonumber(overrides.lifetimeOverride) or tonumber(meta.lifetimeSec) or 3
                local lifetime = worldmeta and (predictionLifetime or normalLifetime) or normalLifetime
                local gravityMultiplier = tonumber(projmeta and projmeta.gravityMultiplier) or 1
                local gravity = (tonumber(meta.gravitationalAcceleration) or 196.2) * gravityMultiplier
                if type(native.gravitationalAcceleration) == "number" then
                    gravity = native.gravitationalAcceleration
                end

                local toolMeta = tool and Bedwars.ItemMeta[tool.Name]
                local sourceMeta = toolMeta and toolMeta.projectileSource
                local maxDraw = tonumber(sourceMeta and sourceMeta.maxStrengthChargeSec)
                    or tonumber(sourceMeta and sourceMeta.maxDrawDurationSeconds)
                    or (projectileName:find("arrow", 1, true) and 0.65 or 0.8)
                local minScalar = tonumber(sourceMeta and sourceMeta.minStrengthScalar) or 1
                local baseSpeed = tonumber(overrides.launchVelocityOverride) or tonumber(meta.launchVelocity) or 100

                -- Shot strength: AutoCharge fires at the chosen draw, otherwise the game's own draw is kept
                local speed, drawDuration
                if cfg.AutoCharge then
                    local pct = math.clamp((tonumber(cfg.ChargePercent) or 100) / 100, 0, 1)
                    speed = baseSpeed * (minScalar + (1 - minScalar) * pct)
                    drawDuration = maxDraw * pct
                else
                    if typeof(native.initialVelocity) == "Vector3" and native.initialVelocity.Magnitude > 0 then
                        speed = native.initialVelocity.Magnitude
                    else
                        local liveDraw = tonumber(projmeta and projmeta.drawDurationSeconds) or 0
                        local livePct = maxDraw > 0 and math.clamp(liveDraw / maxDraw, 0, 1) or 0
                        speed = baseSpeed * (minScalar + (1 - minScalar) * livePct)
                    end
                    drawDuration = tonumber(native.drawDurationSeconds) or tonumber(projmeta and projmeta.drawDurationSeconds) or 0
                end

                -- Where the projectile actually leaves from
                local launchOrigin
                if typeof(native.positionFrom) == "Vector3" then
                    launchOrigin = native.positionFrom
                else
                    local pos
                    pcall(function()
                        pos = selfController:getLaunchPosition(tool)
                    end)
                    pos = pos or originPos
                    local offset = projmeta and projmeta.fromPositionOffset
                    launchOrigin = pos + (typeof(offset) == "Vector3" and offset or Vector3.new(0, 2, 0))
                end

                -- Target motion
                local char = entry.Model
                local playerGravity = Workspace.Gravity
                local balloons = char:GetAttribute("InflatedBalloons")
                if type(balloons) == "number" and balloons > 0 then
                    playerGravity = balloonGravity(balloons, char)
                end
                if char.PrimaryPart and char.PrimaryPart:FindFirstChild(FLOATY_MARKER) then
                    playerGravity = 6
                end
                if entry.Player and entry.Player:GetAttribute("IsOwlTarget") then
                    for _, owl in ipairs(CollectionService:GetTagged("Owl")) do
                        if owl:GetAttribute("Target") == entry.Player.UserId and owl:GetAttribute("Status") == 2 then
                            playerGravity = 0
                            break
                        end
                    end
                end

                local rawVel = root.AssemblyLinearVelocity
                if (rawVel * Vector3.new(1, 0, 1)).Magnitude < 1 then
                    local measured = measuredVelocity(root)
                    if measured and (measured * Vector3.new(1, 0, 1)).Magnitude > 2 and measured.Magnitude < 130 then
                        rawVel = Vector3.new(measured.X, rawVel.Y, measured.Z)
                    end
                end
                local hip = hum.HipHeight or 2
                local aimTarget = part.Position
                if projectileName:find("fireball", 1, true) then
                    aimTarget = splashAimPoint(root, hip) or aimTarget
                end

                local vel = projectileName == "telepearl" and Vector3.zero or rawVel
                local airborne = hum.FloorMaterial == Enum.Material.Air or math.abs(rawVel.Y) > 0.01
                local jumping = false
                pcall(function()
                    jumping = hum:GetState() == Enum.HumanoidStateType.Jumping
                end)
                local jumpVel = (jumping and not airborne) and JUMP_SPEED or nil
                if cfg.CustomPredictions and projectileName ~= "telepearl" then
                    local horizontal = (tonumber(cfg.PredictHorizontal) or 100) / 100
                    local vertical = (tonumber(cfg.PredictVertical) or 100) / 100
                    vel = Vector3.new(vel.X * horizontal, vel.Y * vertical, vel.Z * horizontal)
                end

                local flat = Vector3.new(vel.X, 0, vel.Z)
                if flat.Magnitude > MAX_LEAD_SPEED then
                    flat = flat.Unit * MAX_LEAD_SPEED
                end
                local moving = airborne or jumpVel ~= nil
                local vy = airborne and vel.Y or (jumpVel or 0)
                local floorY = moving and floorLevel(root, hip, aimTarget.Y) or nil

                local function pathFor(offset)
                    local base = aimTarget + (offset or Vector3.zero)
                    return function(t)
                        local y = base.Y
                        if moving then
                            y = base.Y + vy * t - 0.5 * playerGravity * t * t
                            if floorY and y < floorY + (offset and offset.Y or 0) then
                                y = floorY + (offset and offset.Y or 0)
                            end
                        end
                        return Vector3.new(base.X + flat.X * t, y, base.Z + flat.Z * t)
                    end
                end

                local maxTime = math.min(lifetime, 5)
                local launch, flight = solveLaunch(launchOrigin, speed, gravity, pathFor(nil), maxTime)
                if not launch then
                    return nil
                end

                -- Blocked by a wall? Try a few nearby aim points that have a clear arc
                if not worldmeta and not arcIsClear(launchOrigin, launch, gravity, flight) then
                    local los = (aimTarget - launchOrigin) * Vector3.new(1, 0, 1)
                    local side = los.Magnitude > 0.01 and Vector3.new(-los.Z, 0, los.X).Unit or Vector3.new(1, 0, 0)
                    local up = Vector3.new(0, 1, 0)
                    for _, offset in ipairs({
                        up * 0.8, up * -0.8, side * 0.9, side * -0.9, up * 1.6, up * -1.6,
                        side * 0.9 + up * 1.2, side * -0.9 + up * 1.2, up * 2.1, up * -2.4,
                        side * 0.9 - up * 1.2, side * -0.9 - up * 1.2,
                    }) do
                        local altLaunch, altFlight = solveLaunch(launchOrigin, speed, gravity, pathFor(offset), maxTime)
                        if altLaunch and arcIsClear(launchOrigin, altLaunch, gravity, altFlight) then
                            launch, flight = altLaunch, altFlight
                            break
                        end
                    end
                end

                local returnDist = tonumber(overrides.returnDistanceOverride) or tonumber(meta.returnDistance)
                if flight > lifetime or (returnDist and speed * flight > returnDist - 2) then
                    return nil
                end

                lastTarget, lastTargetAt = entry, os.clock()
                if cfg.ShowTarget then
                    box.Adornee = root
                end

                local result = {}
                for k, v in pairs(native) do
                    result[k] = v
                end
                result.initialVelocity = launch
                result.positionFrom = launchOrigin
                result.deltaT = lifetime
                result.gravitationalAcceleration = gravity
                result.drawDurationSeconds = drawDuration
                return result
            end

            local function wrapper(...)
                local nativeResult = original(...)
                if not active or type(nativeResult) ~= "table" then
                    return nativeResult
                end
                local selfController, projmeta, worldmeta, tool, shootpos = ...
                if typeof(tool) ~= "Instance" then
                    tool = nil
                end
                local ok, modified = pcall(aimShot, nativeResult, selfController, projmeta, worldmeta, tool, shootpos)
                if ok and modified then
                    return modified
                end
                return nativeResult
            end

            local function install()
                local ready, why = Bedwars.Resolve()
                if not ready then
                    return false, why
                end
                local ctrl = Bedwars.ProjectileController
                if not ctrl or type(ctrl.calculateImportantLaunchValues) ~= "function" then
                    return false, "ProjectileController.calculateImportantLaunchValues not found"
                end
                controller = ctrl
                original = ctrl.calculateImportantLaunchValues
                hadOwn = rawget(ctrl, "calculateImportantLaunchValues") ~= nil
                local ok, err = pcall(function()
                    ctrl.calculateImportantLaunchValues = wrapper
                end)
                if not ok then
                    return false, "couldn't hook projectiles: " .. tostring(err)
                end
                return true
            end

            -- Hide Cursor ----------------------------------------------------------------
            local function holdingProjectileWeapon()
                local name = heldName()
                local meta = name and Bedwars.ItemMeta and Bedwars.ItemMeta[name]
                local source = meta and meta.projectileSource
                return source ~= nil and type(source.ammoItemTypes) == "table" and table.find(source.ammoItemTypes, "arrow") ~= nil
            end

            local function shouldHideCursor()
                if not cfg.HideCursor then
                    return false
                end
                local first = Util.IsFirstPerson()
                if cfg.CursorShowGUI and first and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
                    return false
                end
                if cfg.CursorLimitBow and not holdingProjectileWeapon() then
                    return false
                end
                local mode = cfg.CursorViewMode or "First Person"
                if mode == "First Person" then
                    return first
                elseif mode == "Third Person" then
                    return not first
                end
                return true
            end

            -- The hook goes in as soon as the game's controllers exist (retries until then)
            local lastSampleAt = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                local cam = Workspace.CurrentCamera
                local now = os.clock()

                -- Cursor
                if cfg.HideCursor and installed then
                    local hide = shouldHideCursor()
                    if hide ~= cursorHidden then
                        cursorHidden = hide
                        pcall(function()
                            UserInputService.MouseIconEnabled = not hide
                        end)
                    end
                elseif cursorHidden then
                    cursorHidden = false
                    pcall(function()
                        UserInputService.MouseIconEnabled = true
                    end)
                end

                -- Keep a short movement history of nearby targets
                if installed and now - lastSampleAt >= 0.05 then
                    lastSampleAt = now
                    local _, _, myRoot = Util.GetCharacter(LocalPlayer)
                    if myRoot then
                        for _, entry in ipairs(Util.GetTargets(cfg.Targets)) do
                            if entry.Root and (entry.Root.Position - myRoot.Position).Magnitude <= (tonumber(cfg.Range) or 100) * 1.5 then
                                sampleRoot(entry.Root)
                            end
                        end
                    end
                end

                if circle then
                    local mouse = cam and aimReference(cam) or UserInputService:GetMouseLocation()
                    circle.Visible = cfg.ShowFOV and installed
                    circle.Position = mouse
                    circle.Radius = cfg.FOV
                end

                if cfg.ShowTarget and lastTarget and now - lastTargetAt < 1.2
                    and lastTarget.Root and lastTarget.Root.Parent then
                    box.Adornee = lastTarget.Root
                else
                    box.Adornee = nil
                end

                if not installed then
                    if now - lastTryAt >= 1.5 then
                        lastTryAt = now
                        local ok, why = install()
                        if ok then
                            installed = true
                            Nova.Notify("Projectile Aimbot", "Hooked. Shoot a bow near a target.", 3, "success")
                        else
                            setStatus(cfg.StatusLine, "unavailable - " .. tostring(why))
                        end
                    end
                    return
                end

                if now - lastTargetAt < 1.2 and lastTarget then
                    setStatus(cfg.StatusLine, "aimed at " .. tostring(lastTarget.Name))
                elseif cam then
                    setStatus(cfg.StatusLine, "ready (" .. (Util.IsFirstPerson() and "first" or "third") .. " person)")
                end
            end))

            mod.Maid:Give(function()
                active = false
                pcall(function()
                    UserInputService.MouseIconEnabled = true
                end)
                if installed and controller and rawget(controller, "calculateImportantLaunchValues") == wrapper then
                    pcall(function()
                        if hadOwn then
                            controller.calculateImportantLaunchValues = original
                        else
                            controller.calculateImportantLaunchValues = nil
                        end
                    end)
                end
            end)
        end,
    })

    aim:AddSection("Targeting")
    aim:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players + NPCs" })
    aim:AddOption({
        Label = "Part", Key = "Part", Options = { "Dynamic", "RootPart", "Head", "Closest", "Randomize" }, Default = "RootPart",
        Tip = "Where on the target to aim. Dynamic picks the head for Headhunter shots, the body otherwise. Closest is the body part nearest your cursor.",
    })
    aim:AddSlider({ Label = "Head Chance", Key = "HeadChance", Min = 0, Max = 100, Default = 50, Step = 5, Suffix = "%", ShowIf = function(c) return c.Part == "Randomize" end })
    aim:AddSlider({ Label = "Torso Chance", Key = "TorsoChance", Min = 0, Max = 100, Default = 50, Step = 5, Suffix = "%", ShowIf = function(c) return c.Part == "Randomize" end, Tip = "Whatever head + torso don't add up to goes to the root part." })
    aim:AddOption({ Label = "Sort Method", Key = "Sort", Options = { "Cursor", "Distance", "Health" }, Default = "Cursor" })
    aim:AddOption({ Label = "Work Mode", Key = "WorkMode", Options = { "Both", "First Person", "Third Person" }, Default = "Both", Tip = "Only redirect shots in this camera mode." })
    aim:AddSlider({ Label = "Range", Key = "Range", Min = 10, Max = 500, Default = 100, Step = 5, Suffix = " studs", Tip = "How far away a target can be picked up. The shot is still limited by the projectile's real speed and gravity." })
    aim:AddSlider({ Label = "FOV", Key = "FOV", Min = 1, Max = 1000, Default = 300, Step = 5, Suffix = " px", Tip = "How close to your crosshair a target has to be." })
    aim:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true, Tip = "Only lock targets you can see (line of sight)." })
    aim:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true })
    aim:AddSection("Projectiles")
    aim:AddToggle({ Label = "Other Projectiles", Key = "OtherProjectiles", Default = true, Tip = "Also aim fireballs and other projectiles, not just arrows." })
    aim:AddTextBox({ Label = "Blacklist", Key = "Blacklist", Default = "telepearl", Placeholder = "telepearl, fireball", ShowIf = function(c) return c.OtherProjectiles end, Tip = "Comma-separated projectile ids to leave alone (not tool names)." })
    aim:AddToggle({ Label = "AutoCharge", Key = "AutoCharge", Default = true, Tip = "Fires every shot at the Charge Percent below, no need to hold the bow back." })
    aim:AddSlider({ Label = "Charge Percent", Key = "ChargePercent", Min = 1, Max = 100, Default = 100, Step = 1, Suffix = "%", ShowIf = function(c) return c.AutoCharge end })
    aim:AddToggle({ Label = "Custom Predictions", Key = "CustomPredictions", Default = false, Tip = "Lets you control how far ahead of the target it leads." })
    aim:AddSlider({ Label = "Horizontal", Key = "PredictHorizontal", Min = 0, Max = 300, Default = 100, Step = 5, Suffix = "%", ShowIf = function(c) return c.CustomPredictions end })
    aim:AddSlider({ Label = "Vertical", Key = "PredictVertical", Min = 0, Max = 300, Default = 100, Step = 5, Suffix = "%", ShowIf = function(c) return c.CustomPredictions end })
    aim:AddSection("Cursor")
    aim:AddToggle({ Label = "Hide Cursor", Key = "HideCursor", Default = false, Tip = "Hides your cursor while aiming." })
    aim:AddOption({ Label = "Cursor View Mode", Key = "CursorViewMode", Options = { "First Person", "Third Person", "Both" }, Default = "First Person", ShowIf = function(c) return c.HideCursor end })
    aim:AddToggle({ Label = "Limit to Bow", Key = "CursorLimitBow", Default = false, ShowIf = function(c) return c.HideCursor end })
    aim:AddToggle({ Label = "Show on GUI", Key = "CursorShowGUI", Default = false, ShowIf = function(c) return c.HideCursor end, Tip = "Shows the cursor again while a menu is open." })
    aim:AddSection("Visuals")
    aim:AddToggle({ Label = "Show FOV Circle", Key = "ShowFOV", Default = false })
    aim:AddToggle({ Label = "Show Target", Key = "ShowTarget", Default = true })
    aim:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })
    aim:AddLabel("Bedwars only. Doesn't move your camera: it redirects the arrow you release. Wall check and velocity handling are tuned automatically.")
end

-- ====================== MODULE: AUTO CAITLYN ======================
-- Execute assist for ranged weapons: locks the lowest-health enemy in range and fires on them
-- for you while you hold a bow or crossbow.
--
-- I could not read catvape's real "AutoCaitlyn" source (its loader is locked behind a licence
-- key) and found no trace of it in the other reference code either, only its saved setting names
-- (Select HP, Select Range, Hit Range, Proximity Range). This module is built from those names,
-- not a verified port - the exact behaviour of the original may differ.
do
    local caitlyn

    local function isRangedWeapon(name)
        local meta = name and Bedwars.ItemMeta and Bedwars.ItemMeta[name]
        return meta ~= nil and meta.projectileSource ~= nil
    end

    local function healthPercent(hum)
        local max = hum.MaxHealth
        if not max or max <= 0 then
            return 100
        end
        return (hum.Health / max) * 100
    end

    -- True when another player on the target's team is standing within `range` of them
    local function hasNearbyAlly(entry, list, range)
        for _, other in ipairs(list) do
            if other ~= entry and other.Player and entry.Player and other.Humanoid.Health > 0
                and other.Player:GetAttribute("Team") == entry.Player:GetAttribute("Team")
                and other.Root and entry.Root
                and (other.Root.Position - entry.Root.Position).Magnitude <= range then
                return true
            end
        end
        return false
    end

    -- `forAcquire`: true while picking a brand new lock (also gated by Select Range). An existing
    -- lock is allowed to drift past Select Range and only drops once it passes Hit Range, checked
    -- separately by the caller.
    local function qualifies(cfg, entry, root, list, forAcquire)
        if not entry.Player or Util.IsTeammate(entry.Player) or entry.Humanoid.Health <= 0 or not entry.Root then
            return false
        end
        if healthPercent(entry.Humanoid) > cfg.SelectHP then
            return false
        end
        if forAcquire and (entry.Root.Position - root.Position).Magnitude > cfg.SelectRange then
            return false
        end
        if cfg.RequireSight and not Util.HasStrictSight(root.Position + Vector3.new(0, 1.5, 0), entry.Root.Position) then
            return false
        end
        if cfg.AvoidGroups and hasNearbyAlly(entry, list, cfg.ProximityRange) then
            return false
        end
        return true
    end

    caitlyn = Tabs.Kits:CreateModule({
        Name = "Auto Caitlyn",
        Description = "Locks the lowest-health enemy in range and fires on them for you.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Auto Caitlyn", -160)
            local locked = nil
            local lastFire = 0

            mod.Maid:Give(function()
                locked = nil
            end)

            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    task.wait(0.05)
                    local _, _, root = Util.GetCharacter(LocalPlayer)
                    local toolName = Util.GetHeldName()

                    if not root then
                        locked = nil
                        setStatus(false)
                    elseif not isRangedWeapon(toolName) then
                        locked = nil
                        setStatus(true, "hold a bow or crossbow")
                    else
                        local list = Util.GetTargets("Players")

                        if locked then
                            local stillListed = false
                            for _, entry in ipairs(list) do
                                if entry == locked then
                                    stillListed = true
                                    break
                                end
                            end
                            if not stillListed or not qualifies(cfg, locked, root, list, false) then
                                locked = nil
                            end
                        end
                        if not locked then
                            local best, bestDistance
                            for _, entry in ipairs(list) do
                                if qualifies(cfg, entry, root, list, true) then
                                    local distance = (entry.Root.Position - root.Position).Magnitude
                                    if not bestDistance or distance < bestDistance then
                                        best, bestDistance = entry, distance
                                    end
                                end
                            end
                            locked = best
                        end

                        if not locked then
                            setStatus(true, "no low-health target in range")
                        else
                            local distance = (locked.Root.Position - root.Position).Magnitude
                            if distance > cfg.HitRange then
                                setStatus(true, string.format("%s is %.0f studs away (out of hit range)", locked.Name, distance))
                            else
                                setStatus(true, "firing on " .. locked.Name)
                                if os.clock() - lastFire >= (cfg.FireDelay or 0.6) then
                                    lastFire = os.clock()
                                    local camera = Workspace.CurrentCamera
                                    if camera and cfg.AimCamera then
                                        pcall(function()
                                            camera.CFrame = CFrame.new(camera.CFrame.Position, locked.Root.Position + Vector3.new(0, 1, 0))
                                        end)
                                    end
                                    if VirtualInputManager and camera then
                                        local size = camera.ViewportSize
                                        for _, down in ipairs({ true, false }) do
                                            pcall(function()
                                                VirtualInputManager:SendMouseButtonEvent(size.X / 2, size.Y / 2, 0, down, game, 1)
                                            end)
                                            task.wait()
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end))
        end,
    })

    caitlyn:AddSection("Target")
    caitlyn:AddSlider({
        Label = "Select HP", Key = "SelectHP", Min = 1, Max = 100, Default = 41, Step = 1, Suffix = "%",
        Tip = "Only locks enemies at or below this health percentage.",
    })
    caitlyn:AddSlider({
        Label = "Select Range", Key = "SelectRange", Min = 5, Max = 50, Default = 20, Step = 1, Suffix = " studs",
        Tip = "How close a qualifying enemy has to be before it gets locked.",
    })
    caitlyn:AddSlider({
        Label = "Hit Range", Key = "HitRange", Min = 10, Max = 200, Default = 100, Step = 5, Suffix = " studs",
        Tip = "Keeps firing on a locked target until it drifts this far away.",
    })
    caitlyn:AddToggle({
        Label = "Require Line of Sight", Key = "RequireSight", Default = true,
        Tip = "Won't lock a target you can't actually see.",
    })
    caitlyn:AddToggle({
        Label = "Avoid Groups", Key = "AvoidGroups", Default = false,
        Tip = "Skips a target if one of their teammates is standing near them (Proximity Range).",
    })
    caitlyn:AddSlider({
        Label = "Proximity Range", Key = "ProximityRange", Min = 5, Max = 200, Default = 50, Step = 5, Suffix = " studs",
        ShowIf = function(c)
            return c.AvoidGroups
        end,
    })
    caitlyn:AddSection("Firing")
    caitlyn:AddToggle({
        Label = "Aim Camera", Key = "AimCamera", Default = true,
        Tip = "Points your camera at the target right before each shot. Turn off to aim yourself and only have it click.",
    })
    caitlyn:AddSlider({
        Label = "Fire Delay", Key = "FireDelay", Min = 0.2, Max = 2, Default = 0.6, Step = 0.1, Suffix = "s",
        Tip = "Minimum time between shots.",
    })
    caitlyn:AddNote("Bedwars only. Hold a bow or crossbow. Pair with Projectile Aimbot for guaranteed hits - this module only decides when to fire, not how the shot lands.")
end

-- ====================== MODULE: ESP ======================
do
    local PALETTE = {
        Purple = Color3.fromRGB(170, 120, 255),
        White  = Color3.fromRGB(255, 255, 255),
        Red    = Color3.fromRGB(255, 80, 80),
        Cyan   = Color3.fromRGB(80, 230, 255),
        Green  = Color3.fromRGB(90, 255, 140),
    }

    local function newDrawing(class, props)
        local drawing = Drawing.new(class)
        for key, value in pairs(props) do
            drawing[key] = value
        end
        return drawing
    end

    -- Skeleton: one line per joint pair, joined at the centre of each body part
    local R15_BONES = {
        { "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
        { "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
        { "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
        { "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
        { "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
    }
    local R6_BONES = {
        { "Head", "Torso" }, { "Torso", "Left Arm" }, { "Torso", "Right Arm" },
        { "Torso", "Left Leg" }, { "Torso", "Right Leg" },
    }
    local MAX_BONES = #R15_BONES

    local function drawSkeleton(set, char, hum, cam, color, show)
        local bones = (hum.RigType == Enum.HumanoidRigType.R15) and R15_BONES or R6_BONES
        for index = 1, MAX_BONES do
            local line = set["Bone" .. index]
            local bone = show and bones[index]
            local drawn = false
            if bone then
                local a = char:FindFirstChild(bone[1])
                local b = char:FindFirstChild(bone[2])
                if a and b and a:IsA("BasePart") and b:IsA("BasePart") then
                    local pointA = cam:WorldToViewportPoint(a.Position)
                    local pointB = cam:WorldToViewportPoint(b.Position)
                    if pointA.Z > 0 and pointB.Z > 0 then
                        line.From = Vector2.new(pointA.X, pointA.Y)
                        line.To = Vector2.new(pointB.X, pointB.Y)
                        line.Color = color
                        line.Visible = true
                        drawn = true
                    end
                end
            end
            if not drawn then
                line.Visible = false
            end
        end
    end

    local esp = Tabs.Render:CreateModule({
        Name = "ESP",
        Description = "Boxes, names, health and skeletons for players / NPCs.",
        OnEnable = function(mod)
            if not HAS_DRAWING then
                error("Drawing API is not available on this executor")
            end
            local cfg = mod.Config
            local objects = {}   -- entry -> drawings

            local function create(entry)
                local set = {
                    Outline    = newDrawing("Square", { Thickness = 3, Filled = false, Color = Color3.new(0, 0, 0), Visible = false }),
                    Box        = newDrawing("Square", { Thickness = 1, Filled = false, Visible = false }),
                    Name       = newDrawing("Text", { Size = 13, Center = true, Outline = true, Font = 2, Visible = false }),
                    Distance   = newDrawing("Text", { Size = 12, Center = true, Outline = true, Font = 2, Visible = false }),
                    HealthBack = newDrawing("Line", { Thickness = 4, Color = Color3.new(0, 0, 0), Visible = false }),
                    Health     = newDrawing("Line", { Thickness = 2, Visible = false }),
                }
                for index = 1, MAX_BONES do
                    set["Bone" .. index] = newDrawing("Line", { Thickness = 1, Visible = false })
                end
                objects[entry] = set
                return set
            end

            local function destroy(entry)
                local set = objects[entry]
                if set then
                    for _, drawing in pairs(set) do
                        -- Visible = false first: on some executors :Remove() silently no-ops
                        -- instead of erroring, which used to leave the box frozen on screen with
                        -- nothing telling us it failed. Hiding it first means it disappears even
                        -- if the Remove() right after does nothing.
                        pcall(function()
                            drawing.Visible = false
                        end)
                        pcall(function()
                            drawing:Remove()
                        end)
                    end
                    objects[entry] = nil
                end
            end

            local function hide(set)
                for _, drawing in pairs(set) do
                    drawing.Visible = false
                end
            end

            mod.Maid:Give(function()
                for entry in pairs(objects) do
                    destroy(entry)
                end
            end)

            mod.Maid:Give(RunService.RenderStepped:Connect(function()
                local cam = Workspace.CurrentCamera
                if not cam then
                    return
                end
                local color = PALETTE[cfg.Color] or PALETTE.Purple
                local seen = {}

                for _, entry in ipairs(Util.GetTargets(cfg.Targets)) do
                    seen[entry] = true
                    local set = objects[entry] or create(entry)
                    local char, hum, root = entry.Model, entry.Humanoid, entry.Root
                    local visible = not (cfg.TeamCheck and entry.Player and Util.IsTeammate(entry.Player))

                    if visible then
                        local rootPos = root.Position
                        local distance = (cam.CFrame.Position - rootPos).Magnitude
                        visible = distance <= cfg.MaxDistance

                        if visible then
                            -- Height is built from the real rig so the box follows character scale
                            local head = char:FindFirstChild("Head")
                            local headTop
                            if head and head:IsA("BasePart") then
                                headTop = head.Position.Y + head.Size.Y / 2
                            else
                                headTop = rootPos.Y + root.Size.Y / 2 + 0.5
                            end
                            local feetOffset
                            if hum.RigType == Enum.HumanoidRigType.R15 then
                                feetOffset = hum.HipHeight + root.Size.Y / 2
                            else
                                local leg = char:FindFirstChild("Left Leg")
                                feetOffset = root.Size.Y / 2 + ((leg and leg:IsA("BasePart")) and leg.Size.Y or 2)
                            end

                            local topPoint, topOn = cam:WorldToViewportPoint(Vector3.new(rootPos.X, headTop + 0.15, rootPos.Z))
                            local bottomPoint, bottomOn = cam:WorldToViewportPoint(Vector3.new(rootPos.X, rootPos.Y - feetOffset, rootPos.Z))

                            if topPoint.Z <= 0 or bottomPoint.Z <= 0 or not (topOn or bottomOn) then
                                visible = false
                            else
                                local height = math.abs(bottomPoint.Y - topPoint.Y)
                                local width = height * 0.55
                                local centerX = (topPoint.X + bottomPoint.X) / 2
                                local left = math.floor(centerX - width / 2)
                                local top = math.floor(topPoint.Y)
                                local boxSize = Vector2.new(math.floor(width), math.floor(height))

                                set.Outline.Position = Vector2.new(left, top)
                                set.Outline.Size = boxSize
                                set.Outline.Visible = cfg.Boxes
                                set.Box.Position = Vector2.new(left, top)
                                set.Box.Size = boxSize
                                set.Box.Color = color
                                set.Box.Visible = cfg.Boxes

                                set.Name.Text = entry.Name
                                set.Name.Position = Vector2.new(centerX, top - 16)
                                set.Name.Color = color
                                set.Name.Visible = cfg.Names

                                set.Distance.Text = tostring(math.floor(distance)) .. " studs"
                                set.Distance.Position = Vector2.new(centerX, top + math.floor(height) + 2)
                                set.Distance.Color = Color3.new(1, 1, 1)
                                set.Distance.Visible = cfg.Distances

                                local fraction = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                                local barX = left - 5
                                local bottomY = top + math.floor(height)
                                set.HealthBack.From = Vector2.new(barX, bottomY + 1)
                                set.HealthBack.To = Vector2.new(barX, top - 1)
                                set.HealthBack.Visible = cfg.HealthBar
                                set.Health.From = Vector2.new(barX, bottomY)
                                set.Health.To = Vector2.new(barX, bottomY - math.floor(height) * fraction)
                                set.Health.Color = Color3.fromRGB(255, 70, 70):Lerp(Color3.fromRGB(90, 255, 130), fraction)
                                set.Health.Visible = cfg.HealthBar

                                drawSkeleton(set, char, hum, cam, color, cfg.Skeleton)
                            end
                        end
                    end

                    if not visible then
                        hide(set)
                    end
                end

                -- Remove drawings for anything that is no longer a valid target
                for entry in pairs(objects) do
                    if not seen[entry] then
                        destroy(entry)
                    end
                end
            end))
        end,
    })

    esp:AddSection("Targets")
    esp:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players" })
    esp:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true })
    esp:AddSlider({ Label = "Max Distance", Key = "MaxDistance", Min = 50, Max = 5000, Default = 1500, Step = 50, Suffix = " studs" })
    esp:AddSection("Draw")
    esp:AddToggle({ Label = "Boxes", Key = "Boxes", Default = true })
    esp:AddToggle({ Label = "Names", Key = "Names", Default = true })
    esp:AddToggle({ Label = "Distance", Key = "Distances", Default = false })
    esp:AddToggle({ Label = "Health Bar", Key = "HealthBar", Default = true })
    esp:AddToggle({ Label = "Skeleton", Key = "Skeleton", Default = false, Tip = "Draw lines through each player's joints (head, arms, legs)." })
    esp:AddOption({ Label = "Color", Key = "Color", Options = { "Purple", "White", "Red", "Cyan", "Green" }, Default = "Purple", Swatches = PALETTE })


    -- Beehive ESP (CatVape: CollectionService tag "beehive")
    do
        local CollectionService = service("CollectionService")
        local hiveRefs = {} -- [hive] = TextLabel

        local function destroyLabel(hive)
            local lab = hiveRefs[hive]
            if lab then
                pcall(function() lab:Destroy() end)
                hiveRefs[hive] = nil
            end
        end

        local function makeLabel(hive)
            if hiveRefs[hive] then return hiveRefs[hive] end
            local owner = hive:GetAttribute("OwnerUserId") or hive:GetAttribute("Owner") or hive:GetAttribute("Player")
            local ownerName = "?"
            if type(owner) == "number" then
                local plr = Players:GetPlayerByUserId(owner)
                ownerName = plr and plr.DisplayName or tostring(owner)
            elseif type(owner) == "string" then
                ownerName = owner
            end
            -- try parent attributes
            pcall(function()
                if ownerName == "?" then
                    local oid = hive:GetAttribute("OwnerUserId")
                    if not oid and hive.Parent then oid = hive.Parent:GetAttribute("OwnerUserId") end
                    if type(oid) == "number" then
                        local plr = Players:GetPlayerByUserId(oid)
                        if plr then ownerName = plr.DisplayName end
                    end
                end
            end)
            local lab = New("TextLabel", {
                Name = "NovaBeehive",
                AnchorPoint = Vector2.new(0.5, 0.5),
                BackgroundColor3 = Theme.Background,
                BackgroundTransparency = 0.45,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamMedium,
                TextSize = 14,
                TextColor3 = Theme.AccentLight,
                TextStrokeTransparency = 0.6,
                Visible = false,
                ZIndex = 20,
                Parent = UI.Gui,
            }, { Round(6), New("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }) })
            lab.Name = ownerName -- store owner for text builder
            hiveRefs[hive] = lab
            return lab
        end

        local hiveEsp = Tabs.Render:CreateModule({
            Name = "Beehive ESP",
            Description = "Shows beehive locations, owner and bee count.",
            OnEnable = function(mod)
                local cfg = mod.Config

                local function added(hive)
                    if not hive:IsA("BasePart") and not hive:IsA("Model") then
                        local part = hive:FindFirstChildWhichIsA("BasePart", true)
                        if part then hive = part end
                    end
                    makeLabel(hive)
                end

                for _, v in ipairs(CollectionService:GetTagged("beehive")) do
                    pcall(added, v)
                end
                mod.Maid:Give(CollectionService:GetInstanceAddedSignal("beehive"):Connect(function(v)
                    pcall(added, v)
                end))
                mod.Maid:Give(CollectionService:GetInstanceRemovedSignal("beehive"):Connect(function(v)
                    destroyLabel(v)
                end))

                mod.Maid:Give(RunService.RenderStepped:Connect(function()
                    local cam = Workspace.CurrentCamera
                    if not cam then return end
                    for hive, lab in pairs(hiveRefs) do
                        if not hive or not hive.Parent then
                            destroyLabel(hive)
                        else
                            local pos
                            if hive:IsA("BasePart") then
                                pos = hive.Position
                            elseif hive:IsA("Model") then
                                pos = hive:GetPivot().Position
                            else
                                local p = hive:FindFirstChildWhichIsA("BasePart", true)
                                pos = p and p.Position
                            end
                            if not pos then
                                lab.Visible = false
                            else
                                local screen, on = cam:WorldToViewportPoint(pos + Vector3.new(0, 1.2, 0))
                                if not on or screen.Z < 0 then
                                    lab.Visible = false
                                else
                                    local level = hive:GetAttribute("Level") or hive:GetAttribute("Bees") or 0
                                    if type(level) ~= "number" then level = 0 end
                                    local owner = lab.Name ~= "NovaBeehive" and lab.Name or "Beehive"
                                    local beeWord = level == 1 and "Bee" or "Bees"
                                    local text = string.format("%s's beehive | %d %s", owner, level, beeWord)
                                    lab.Text = text
                                    lab.TextSize = 14 * (cfg.Scale or 1)
                                    lab.TextColor3 = Theme.AccentLight
                                    lab.BackgroundTransparency = cfg.Transparency or 0.45
                                    lab.Position = UDim2.fromOffset(screen.X, screen.Y)
                                    lab.Visible = true
                                end
                            end
                        end
                    end
                end))

                mod.Maid:Give(function()
                    for hive in pairs(hiveRefs) do
                        destroyLabel(hive)
                    end
                end)
            end,
        })
        hiveEsp:AddSlider({ Label = "Scale", Key = "Scale", Min = 0.5, Max = 1.5, Default = 1, Step = 0.1 })
        hiveEsp:AddSlider({ Label = "Transparency", Key = "Transparency", Min = 0, Max = 1, Default = 0.45, Step = 0.05 })
    end

    local genEsp = Tabs.Render:CreateModule({
        Name = "Generator ESP",
        Description = "Highlights iron / diamond / emerald generators.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local adorns = {}
            local CollectionService = game:GetService("CollectionService")
            local COLORS = {
                iron = Color3.fromRGB(200, 200, 210),
                diamond = Color3.fromRGB(80, 200, 255),
                emerald = Color3.fromRGB(80, 255, 140),
            }
            local TAGS = {
                "iron-generator", "diamond-generator", "emerald-generator",
                "IronGenerator", "DiamondGenerator", "EmeraldGenerator", "generator",
            }

            local function clear()
                for part, box in pairs(adorns) do
                    pcall(function() box:Destroy() end)
                    adorns[part] = nil
                end
            end
            mod.Maid:Give(clear)

            local function kindFrom(name, tag)
                local s = (tostring(tag or "") .. " " .. tostring(name or "")):lower()
                if s:find("diamond", 1, true) then return "diamond" end
                if s:find("emerald", 1, true) then return "emerald" end
                return "iron"
            end

            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                local seen = {}
                local candidates = {}
                for _, tag in ipairs(TAGS) do
                    pcall(function()
                        for _, inst in ipairs(CollectionService:GetTagged(tag)) do
                            candidates[#candidates + 1] = { inst = inst, tag = tag }
                        end
                    end)
                end
                if #candidates == 0 then
                    pcall(function()
                        for _, inst in ipairs(Workspace:GetDescendants()) do
                            if inst:IsA("BasePart") or inst:IsA("Model") then
                                local n = inst.Name:lower()
                                if n:find("generator", 1, true) then
                                    candidates[#candidates + 1] = { inst = inst, tag = n }
                                end
                            end
                        end
                    end)
                end
                for _, row in ipairs(candidates) do
                    local part = row.inst
                    if not part:IsA("BasePart") then
                        part = row.inst:FindFirstChildWhichIsA("BasePart", true)
                    end
                    if part and part.Parent then
                        seen[part] = true
                        local box = adorns[part]
                        if not box then
                            box = Instance.new("BoxHandleAdornment")
                            box.Adornee = part
                            box.AlwaysOnTop = true
                            box.ZIndex = 4
                            box.Parent = UI.Gui
                            adorns[part] = box
                        end
                        local kind = kindFrom(row.inst.Name, row.tag)
                        box.Color3 = COLORS[kind] or COLORS.iron
                        box.Size = part.Size + Vector3.new(0.25, 0.25, 0.25)
                        box.Transparency = tonumber(cfg.Transparency) or 0.5
                        box.Visible = true
                    end
                end
                for part, box in pairs(adorns) do
                    if not seen[part] then
                        pcall(function() box:Destroy() end)
                        adorns[part] = nil
                    end
                end
            end))
        end,
    })
    genEsp:AddSlider({ Label = "Transparency", Key = "Transparency", Min = 0.2, Max = 0.9, Default = 0.5, Step = 0.05 })

    Tabs.Render:CreatePlaceholder("More render features coming soon...")
end

-- ====================== MODULE: BED PLATES ======================
-- Overhead tag on every bed (through walls, via BillboardGui + AlwaysOnTop) showing its team and
-- a row of real item-icon chips for whatever is defending it, each badged with how many COMPLETE
-- layers (full 360 rings, not just "some blocks nearby") of that material surround the bed. A
-- chip with no number means that material is present but hasn't closed a full ring yet.
do
    local CollectionService = service("CollectionService")
    local PLACEHOLDER_ICON = "rbxassetid://6031075931"
    local BUCKETS = 16  -- angular slices a ring is checked against; all 16 filled = complete

    local TEAM_COLORS = {
        [1] = Color3.fromRGB(255, 90, 90),  [2] = Color3.fromRGB(90, 140, 255),
        [3] = Color3.fromRGB(255, 230, 90), [4] = Color3.fromRGB(110, 255, 140),
        [5] = Color3.fromRGB(255, 150, 230),[6] = Color3.fromRGB(120, 255, 240),
        [7] = Color3.fromRGB(255, 160, 80), [8] = Color3.fromRGB(220, 220, 220),
    }
    local DEFAULT_PLATE_COLOR = Color3.fromRGB(200, 200, 210)

    local function plateTeamColor(team)
        return TEAM_COLORS[tonumber(team)] or DEFAULT_PLATE_COLOR
    end

    local function plateIcon(material)
        local image = Bedwars.GetItemImage and Bedwars.GetItemImage(material) or ""
        return image ~= "" and image or PLACEHOLDER_ICON
    end

    local bedPlates = Tabs.Render:CreateModule({
        Name = "Bed Plates",
        Description = "Tag over every bed showing its team and how many full layers of each block defend it.",
        OnEnable = function(mod)
            pcall(Bedwars.Resolve)
            local cfg = mod.Config

            local folder = New("Folder", { Name = "NovaBedPlates", Parent = UI.Gui })
            mod.Maid:Give(folder)

            -- Live-tracked bed/block lists, same tag-based discovery as the rest of Nova's bed code
            local beds, blocks = {}, {}
            local function addBed(inst)
                local part = inst and inst:IsA("BasePart") and inst or nil
                if part and not table.find(beds, part) then
                    beds[#beds + 1] = part
                end
            end
            local function removeBed(inst)
                local index = table.find(beds, inst)
                if index then
                    table.remove(beds, index)
                end
            end
            local function addBlock(inst)
                local part = inst and inst:IsA("BasePart") and inst or nil
                -- Beds are tagged BOTH "bed" and "block" (same dual-tag the Nuker module already
                -- accounts for), so without this a bed counted itself as its own one-item defense -
                -- the lone leftover chip once terrain stopped drowning it out.
                if part and not CollectionService:HasTag(part, "bed") and not table.find(blocks, part) then
                    blocks[#blocks + 1] = part
                end
            end
            local function removeBlock(inst)
                local index = table.find(blocks, inst)
                if index then
                    table.remove(blocks, index)
                end
            end
            mod.Maid:Give(CollectionService:GetInstanceAddedSignal("bed"):Connect(addBed))
            mod.Maid:Give(CollectionService:GetInstanceRemovedSignal("bed"):Connect(removeBed))
            for _, inst in ipairs(CollectionService:GetTagged("bed")) do
                addBed(inst)
            end
            mod.Maid:Give(CollectionService:GetInstanceAddedSignal("block"):Connect(addBlock))
            mod.Maid:Give(CollectionService:GetInstanceRemovedSignal("block"):Connect(removeBlock))
            for _, inst in ipairs(CollectionService:GetTagged("block")) do
                addBlock(inst)
            end

            -- Tag GUIs ---------------------------------------------------------------------
            local tags = {}  -- bed -> { Gui, Header, Row, Chips = {material -> {Icon, Amount}}, Order }
            local function buildTag(bed)
                local gui = New("BillboardGui", {
                    Name = "NovaBedPlate",
                    Size = UDim2.fromOffset(280, 70),
                    StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0),
                    AlwaysOnTop = true,
                    LightInfluence = 0,
                    ResetOnSpawn = false,
                    Adornee = bed,
                    Parent = folder,
                })
                local stack = New("Frame", {
                    AnchorPoint = Vector2.new(0.5, 1),
                    Position = UDim2.fromScale(0.5, 1),
                    Size = UDim2.fromOffset(0, 0),
                    AutomaticSize = Enum.AutomaticSize.XY,
                    BackgroundTransparency = 1,
                    Parent = gui,
                }, {
                    New("UIListLayout", {
                        Padding = UDim.new(0, 3), SortOrder = Enum.SortOrder.LayoutOrder,
                        HorizontalAlignment = Enum.HorizontalAlignment.Center,
                        VerticalAlignment = Enum.VerticalAlignment.Bottom,
                    }),
                })
                local header = New("TextLabel", {
                    BackgroundTransparency = 1,
                    Size = UDim2.fromOffset(0, 16),
                    AutomaticSize = Enum.AutomaticSize.X,
                    Font = FONT.Bold,
                    TextSize = 13,
                    TextColor3 = Color3.new(1, 1, 1),
                    TextStrokeTransparency = 0,
                    LayoutOrder = 1,
                    Parent = stack,
                })
                local row = New("Frame", {
                    BackgroundTransparency = 1,
                    Size = UDim2.fromOffset(0, 0),
                    AutomaticSize = Enum.AutomaticSize.XY,
                    LayoutOrder = 2,
                    Parent = stack,
                }, {
                    New("UIListLayout", {
                        FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4),
                        SortOrder = Enum.SortOrder.LayoutOrder,
                        HorizontalAlignment = Enum.HorizontalAlignment.Center,
                        VerticalAlignment = Enum.VerticalAlignment.Center,
                    }),
                })
                local tag = { Gui = gui, Header = header, Row = row, Chips = {}, Order = 0 }
                tags[bed] = tag
                return tag
            end

            local function chipFor(tag, material)
                local chip = tag.Chips[material]
                if chip then
                    return chip
                end
                tag.Order = tag.Order + 1
                local icon = New("ImageLabel", {
                    Name = material,
                    BackgroundTransparency = 1,
                    Size = UDim2.fromOffset(22, 22),
                    LayoutOrder = tag.Order,
                    Image = "",
                    Parent = tag.Row,
                })
                local amount = New("TextLabel", {
                    Name = "Amt",
                    BackgroundTransparency = 1,
                    AnchorPoint = Vector2.new(0.5, 1),
                    Position = UDim2.new(0.5, 0, 1, 4),
                    Size = UDim2.fromOffset(30, 11),
                    Font = FONT.Bold,
                    TextSize = 11,
                    TextColor3 = Color3.new(1, 1, 1),
                    TextStrokeTransparency = 0,
                    TextXAlignment = Enum.TextXAlignment.Center,
                    TextYAlignment = Enum.TextYAlignment.Bottom,
                    Text = "",
                    ZIndex = 2,
                    Parent = icon,
                })
                chip = { Icon = icon, Amount = amount }
                tag.Chips[material] = chip
                return chip
            end

            local function destroyTag(bed)
                local tag = tags[bed]
                if tag then
                    pcall(function() tag.Gui:Destroy() end)
                    tags[bed] = nil
                end
            end
            mod.Maid:Give(function()
                for bed in pairs(tags) do
                    destroyTag(bed)
                end
            end)

            -- Layer analysis -----------------------------------------------------------------
            -- Buckets every nearby block by material + 3-stud Y band, each band split into 16
            -- angular slices around the bed. A band is a "complete layer" for a material only
            -- when every slice has at least one block of that material in it (a full ring, not
            -- just a pile on one side) - gaps an attacker could walk through don't count.
            -- The "block" tag covers every voxel in the map, including pre-built terrain - and it
            -- turns out a Team/PlacedByUserId attribute alone doesn't separate placed defense from
            -- terrain either: the whole island a team spawns on carries that team's Team attribute
            -- too, not just blocks someone actually placed. So this leans on geometry instead,
            -- which is reliable regardless of attributes: a defense cage is built starting at the
            -- bed's own height and going UP from there - nothing that actually protects a bed is
            -- more than a hair below it. Ground the bed happens to be resting on sits well below
            -- bed-centre once its own height is accounted for, so a floor just under the bed
            -- filters terrain out without needing to know what any particular block is tagged.
            local Y_FLOOR = -1.5

            local function analyzeLayers(bedPart, radius)
                local center = bedPart.Position
                local bands, present = {}, {}
                for _, block in ipairs(blocks) do
                    if block.Parent then
                        local offset = block.Position - center
                        -- full 3D distance (not just flat/horizontal) plus the height floor above -
                        -- a block far above/below that's merely horizontally close, or ground the
                        -- bed is sitting on, shouldn't count as "defending" it
                        if offset.Magnitude <= radius and offset.Y >= Y_FLOOR then
                            local material = block.Name
                            present[material] = true
                            local yband = math.floor(block.Position.Y / 3 + 0.5)
                            local angle = math.atan2(offset.Z, offset.X)
                            if angle < 0 then
                                angle = angle + math.pi * 2
                            end
                            local bucket = math.floor(angle / (math.pi * 2 / BUCKETS))
                            bands[material] = bands[material] or {}
                            bands[material][yband] = bands[material][yband] or {}
                            bands[material][yband][bucket] = true
                        end
                    end
                end
                local complete = {}
                for material, byBand in pairs(bands) do
                    local count = 0
                    for _, bucketSet in pairs(byBand) do
                        local full = true
                        for b = 0, BUCKETS - 1 do
                            if not bucketSet[b] then
                                full = false
                                break
                            end
                        end
                        if full then
                            count = count + 1
                        end
                    end
                    complete[material] = count
                end
                return complete, present
            end

            local function refreshBed(bed)
                if not bed.Parent then
                    destroyTag(bed)
                    return
                end
                local myTeam = LocalPlayer:GetAttribute("Team")
                local team = bed:GetAttribute("Team")
                if cfg.HideMyTeam and myTeam ~= nil and tostring(team) == tostring(myTeam) then
                    destroyTag(bed)
                    return
                end
                local tag = tags[bed] or buildTag(bed)
                tag.Gui.MaxDistance = cfg.MaxDistance
                tag.Header.Text = "Team " .. tostring(team ~= nil and team or "?")
                tag.Header.TextColor3 = plateTeamColor(team)
                tag.Row.Visible = cfg.Defense
                if cfg.Defense then
                    local complete, present = analyzeLayers(bed, cfg.DefenseRadius)
                    local seenChip = {}
                    for material in pairs(present) do
                        seenChip[material] = true
                        local chip = chipFor(tag, material)
                        chip.Icon.Image = plateIcon(material)
                        chip.Icon.Visible = true
                        local count = complete[material] or 0
                        chip.Amount.Text = count > 0 and tostring(count) or ""
                    end
                    for material, chip in pairs(tag.Chips) do
                        if not seenChip[material] then
                            chip.Icon.Visible = false
                        end
                    end
                end
            end

            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    for _, bed in ipairs(beds) do
                        pcall(refreshBed, bed)
                    end
                    for bed in pairs(tags) do
                        if not bed.Parent then
                            destroyTag(bed)
                        end
                    end
                    task.wait(0.4)
                end
            end))
        end,
    })

    bedPlates:AddToggle({ Label = "Hide My Team", Key = "HideMyTeam", Default = true, Tip = "Don't show a plate over your own bed or teammates' beds." })
    bedPlates:AddToggle({ Label = "Defense", Key = "Defense", Default = true, Tip = "Shows an icon for each block type defending the bed, badged with its number of complete layers." })
    bedPlates:AddSlider({ Label = "Defense Radius", Key = "DefenseRadius", Min = 3, Max = 20, Default = 9, Step = 1, Suffix = " studs", ShowIf = function(c) return c.Defense end })
    bedPlates:AddSlider({ Label = "Max Distance", Key = "MaxDistance", Min = 100, Max = 5000, Default = 2000, Step = 50, Suffix = " studs" })
end

-- ====================== MODULE: SPRINT ======================
do
    local sprint = Tabs.Combat:CreateModule({
        Name = "Sprint",
        Description = "Keeps you sprinting without holding the key (Bedwars).",
        OnEnable = function(mod)
            local ready, reason = Bedwars.ResolveExtras()
            assert(ready, reason)
            local controller = Bedwars.SprintController
            assert(controller and controller.startSprinting, "SprintController not found (Bedwars update?)")

            local original = controller.stopSprinting
            controller.stopSprinting = function(self, ...)
                -- the game tries to stop sprinting whenever you let go of the key; ignore that while alive
                if mod.Enabled and Util.GetCharacter(LocalPlayer) then
                    return
                end
                return original(self, ...)
            end
            mod.Maid:Give(function()
                controller.stopSprinting = original
                pcall(function()
                    controller:stopSprinting()
                end)
            end)

            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    if Util.GetCharacter(LocalPlayer) then
                        pcall(function()
                            if not controller:isSprinting() then
                                controller:startSprinting()
                            end
                        end)
                    end
                    task.wait(0.12)
                end
            end))
        end,
    })

    sprint:AddNote("Bedwars only. Turn it off and your normal sprint key works again.")
end

-- ====================== MODULE: KIT ESP ======================
do
    local CollectionService = service("CollectionService")

    -- collection tag -> item whose icon is shown
    local KIT_TAGS = {
        alchemist           = { "alchemist_ingedients", "thorns" },
        beekeeper           = { "bee", "bee" },
        bigman              = { "treeOrb", "natures_essence_1" },
        ghost_catcher       = { "ghost", "ghost_orb" },
        metal_detector      = { "hidden-metal", "iron" },
        sheep_herder        = { "SheepModel", "purple_hay_bale" },
        sorcerer            = { "alchemy_crystal", "wild_flower" },
        star_collector      = { "stars", "crit_star" },
        black_market_trader = { "shadow_coin", "shadow_coin" },
        miner               = { "petrified-player", "large_rock" },
        trapper             = { "snap_trap", "snap_trap" },
        mage                = { "ElementTome", "mage_spellbook" },
    }
    -- models that sit directly in Workspace, found by name (name, icon image)
    local KIT_MODELS = {
        necromancer = { "Gravestone", "rbxassetid://6307844310" },
        battery     = { "Open", "rbxassetid://10159166528" },
    }
    -- parts found anywhere in Workspace by name (name, icon item)
    local KIT_PARTS = {
        farmer_cletus = {
            { "carrot", "carrot_seeds" },
            { "melon", "melon_seeds" },
            { "pumpkin", "pumpkin_seeds" },
        },
    }
    local BEE_TAGS = { "bee", "MeadowBee", "ChromaBee" }

    local BG_COLORS = {
        Purple = Color3.fromRGB(150, 90, 255),
        Blue   = Color3.fromRGB(70, 130, 255),
        Red    = Color3.fromRGB(255, 80, 80),
        Green  = Color3.fromRGB(70, 210, 120),
        White  = Color3.fromRGB(235, 235, 245),
        Black  = Color3.fromRGB(10, 10, 14),
    }
    local BG_NAMES = { "Purple", "Blue", "Red", "Green", "White", "Black" }

    local kitEsp
    local folder
    local references = {}      -- adornee -> BillboardGui
    local connections = {}
    local currentKit = nil
    local scanning = false

    local function localKits()
        local raw = LocalPlayer:GetAttribute("PlayingAsKits")
        local list = {}
        if type(raw) == "string" then
            for kit in string.gmatch(raw, "[%w_]+") do
                if kit ~= "none" then
                    list[#list + 1] = kit
                end
            end
        end
        return list
    end

    local function restyle()
        local cfg = kitEsp.Config
        local size = cfg.Size or 36
        for _, billboard in pairs(references) do
            billboard.Size = UDim2.fromOffset(size, size)
            local icon = billboard:FindFirstChild("Icon")
            if icon then
                icon.BackgroundColor3 = BG_COLORS[cfg.BackgroundColor] or BG_COLORS.Purple
                icon.BackgroundTransparency = cfg.Background and 0.45 or 1
            end
        end
    end

    local function addIcon(adornee, image, label, announce)
        if not adornee or references[adornee] then
            return
        end
        local cfg = kitEsp.Config
        local size = cfg.Size or 36
        local billboard = New("BillboardGui", {
            Name = "NovaKit",
            Size = UDim2.fromOffset(size, size),
            StudsOffsetWorldSpace = Vector3.new(0, 3, 0),
            AlwaysOnTop = true,
            ClipsDescendants = false,
            Adornee = adornee,
            Parent = folder,
        })
        local icon = New("ImageLabel", {
            Name = "Icon",
            Size = UDim2.fromScale(1, 1),
            BackgroundColor3 = BG_COLORS[cfg.BackgroundColor] or BG_COLORS.Purple,
            BackgroundTransparency = cfg.Background and 0.45 or 1,
            BorderSizePixel = 0,
            Image = image or "",
            Parent = billboard,
        }, { Round(6), Stroke(Color3.new(0, 0, 0), 1, 0.5) })
        if not image or image == "" then
            New("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = tostring(label or "?"),
                TextScaled = true,
                Font = FONT.Bold,
                TextColor3 = Color3.new(1, 1, 1),
                Parent = icon,
            })
        end
        references[adornee] = billboard
        if announce and cfg.Notify then
            Nova.Notify("Kit ESP", "New " .. tostring(label or adornee.Name), 2)
        end
    end

    local function removeIcon(adornee)
        local billboard = references[adornee]
        if billboard then
            billboard:Destroy()
            references[adornee] = nil
        end
    end

    local function teardown()
        for _, connection in ipairs(connections) do
            connection:Disconnect()
        end
        connections = {}
        if folder then
            folder:ClearAllChildren()
        end
        references = {}
        currentKit = nil
    end

    local function connect(signal, fn)
        connections[#connections + 1] = signal:Connect(fn)
    end

    local function isMineOnMyTeam(part)
        local teamAttr = part:GetAttribute("Team") or part:GetAttribute("TeamId") or part:GetAttribute("TeamID")
        local myTeam = LocalPlayer:GetAttribute("Team") or LocalPlayer:GetAttribute("TeamId") or LocalPlayer:GetAttribute("TeamID")
        if teamAttr and myTeam and tostring(teamAttr) == tostring(myTeam) then
            return true
        end
        local placedBy = part:GetAttribute("PlacedByUserId")
        if placedBy then
            local owner = Players:GetPlayerByUserId(placedBy)
            local mine = LocalPlayer:GetAttribute("Team")
            if owner and mine and owner:GetAttribute("Team") == mine then
                return true
            end
        end
        return false
    end

    local function isRealBee(model)
        local beeId = model:GetAttribute("BeeId")
        if beeId == nil then
            local part = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
            beeId = part and part:GetAttribute("BeeId")
        end
        return type(beeId) == "number" and beeId > -1
    end

    -- Decides what to draw for one tagged instance: returns adornee, image, label (or nil to skip)
    local function describe(tag, inst, iconItem)
        local part = inst:IsA("BasePart") and inst or inst.PrimaryPart
        if not part then
            return nil
        end
        local image = Bedwars.GetItemImage(iconItem)
        if tag == "alchemist_ingedients" then
            local itemName = (inst.Name == "Mushrooms") and "mushrooms" or ((inst.Name == "Thorns") and "thorns" or "wild_flower")
            return part, Bedwars.GetItemImage(itemName), inst.Name
        elseif tag == "stars" then
            local lowered = string.lower(inst.Name)
            local starItem = string.find(lowered, "vitality", 1, true) and "vitality_star" or "crit_star"
            return part, Bedwars.GetItemImage(starItem), inst.Name
        elseif tag == "petrified-player" then
            if isMineOnMyTeam(part) then
                return nil
            end
        elseif tag == "bee" or tag == "MeadowBee" or tag == "ChromaBee" then
            if not inst:IsA("Model") or not isRealBee(inst) then
                return nil
            end
            return part, Bedwars.GetItemImage("bee"), "Bee"
        end
        return part, image, inst.Name
    end

    local function trackTag(tag, iconItem)
        local function consider(inst, announce)
            local part, image, label = describe(tag, inst, iconItem)
            if part then
                addIcon(part, image, label, announce)
            end
        end
        connect(CollectionService:GetInstanceAddedSignal(tag), function(inst)
            task.delay(0.1, function()
                if scanning and inst.Parent then
                    consider(inst, true)
                end
            end)
        end)
        connect(CollectionService:GetInstanceRemovedSignal(tag), function(inst)
            removeIcon(inst:IsA("BasePart") and inst or inst.PrimaryPart)
        end)
        for _, inst in ipairs(CollectionService:GetTagged(tag)) do
            consider(inst, false)
        end
    end

    local function trackModelByName(name, image)
        local function consider(child, announce)
            if child:IsA("Model") and child.Name == name then
                local part = child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart")
                if part then
                    addIcon(part, image, name, announce)
                end
            end
        end
        connect(Workspace.ChildAdded, function(child)
            task.delay(0.1, function()
                if scanning and child.Parent then
                    consider(child, true)
                end
            end)
        end)
        connect(Workspace.ChildRemoved, function(child)
            if child:IsA("Model") then
                removeIcon(child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart"))
            end
        end)
        for _, child in ipairs(Workspace:GetChildren()) do
            consider(child, false)
        end
    end

    local function trackPartByName(name, iconItem)
        local image = Bedwars.GetItemImage(iconItem)
        local function nested(inst)
            local parent = inst.Parent
            while parent and parent ~= Workspace do
                if parent.Name == name then
                    return true
                end
                parent = parent.Parent
            end
            return false
        end
        local function consider(inst, announce)
            if inst:IsA("BasePart") and inst.Name == name and not nested(inst) then
                addIcon(inst, image, name, announce)
            end
        end
        connect(Workspace.DescendantAdded, function(inst)
            task.delay(0.1, function()
                if scanning and inst.Parent then
                    consider(inst, true)
                end
            end)
        end)
        connect(Workspace.DescendantRemoving, function(inst)
            if inst:IsA("BasePart") and inst.Name == name then
                removeIcon(inst)
            end
        end)
        task.spawn(function()
            local everything = Workspace:GetDescendants()
            for index, inst in ipairs(everything) do
                if not scanning then
                    return
                end
                consider(inst, false)
                if index % 3000 == 0 then
                    task.wait()
                end
            end
        end)
    end

    local function setupKit(kit)
        local tagInfo = KIT_TAGS[kit]
        if tagInfo then
            if tagInfo[1] == "bee" then
                for _, tag in ipairs(BEE_TAGS) do
                    trackTag(tag, tagInfo[2])
                end
            else
                trackTag(tagInfo[1], tagInfo[2])
            end
        end
        local modelInfo = KIT_MODELS[kit]
        if modelInfo then
            trackModelByName(modelInfo[1], modelInfo[2])
        end
        for _, entry in ipairs(KIT_PARTS[kit] or {}) do
            trackPartByName(entry[1], entry[2])
        end
    end

    kitEsp = Tabs.Render:CreateModule({
        Name = "Kit ESP",
        Description = "Icons over your kit's collectables (Bedwars).",
        OnEnable = function(mod)
            local ready, reason = Bedwars.ResolveExtras()
            assert(ready, reason)

            folder = New("Folder", { Name = "NovaKitEsp", Parent = UI.Gui })
            scanning = true
            mod.Maid:Give(function()
                scanning = false
                teardown()
                if folder then
                    folder:Destroy()
                    folder = nil
                end
            end)

            -- Re-checks your kit every second so it follows you into a new match / kit change
            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    local kits = localKits()
                    local key = table.concat(kits, ",")
                    if key ~= currentKit then
                        teardown()
                        for _, kit in ipairs(kits) do
                            setupKit(kit)
                        end
                        currentKit = key
                    end
                    task.wait(1)
                end
            end))
        end,
    })

    kitEsp:AddSection("Display")
    kitEsp:AddToggle({ Label = "Notify", Key = "Notify", Default = false, Tip = "Pop-up when a new collectable shows up." })
    kitEsp:AddSlider({ Label = "Icon Size", Key = "Size", Min = 10, Max = 80, Default = 36, Step = 2, Suffix = " px", Callback = restyle })
    kitEsp:AddToggle({ Label = "Background", Key = "Background", Default = true, Callback = restyle })
    kitEsp:AddOption({
        Label = "Background Color", Key = "BackgroundColor", Options = BG_NAMES, Swatches = BG_COLORS, Default = "Purple",
        Callback = restyle, ShowIf = function(c) return c.Background end,
    })
    kitEsp:AddNote("Shows what your kit can collect (bees, ghosts, stars, ore...). Pick a kit in a match to see icons.")
end

-- ====================== MODULE: KIT RENDER ======================
-- Draft screen helper: shows every enemy's current kit, level, the kits they used in their last
-- matches, and a number for players who queue together.
do
    local KIT_IMAGES = {
        none = "rbxassetid://16493320215",
        random = "rbxassetid://79773209697352",
        cowgirl = "rbxassetid://9155462968",
        davey = "rbxassetid://9155464612",
        warlock = "rbxassetid://15186338366",
        ember = "rbxassetid://9630017904",
        black_market_trader = "rbxassetid://18922642482",
        yeti = "rbxassetid://9166205917",
        scarab = "rbxassetid://137137517627492",
        defender = "rbxassetid://131690429591874",
        cactus = "rbxassetid://104436517801089",
        oasis = "rbxassetid://120283205213823",
        berserker = "rbxassetid://90258047545241",
        sword_shield = "rbxassetid://131690429591874",
        airbender = "rbxassetid://74712750354593",
        gun_blade = "rbxassetid://138231219644853",
        frost_hammer_kit = "rbxassetid://11838567073",
        spider_queen = "rbxassetid://95237509752482",
        archer = "rbxassetid://9224796984",
        axolotl = "rbxassetid://9155466713",
        baker = "rbxassetid://9155463919",
        barbarian = "rbxassetid://9166207628",
        builder = "rbxassetid://9155463708",
        necromancer = "rbxassetid://11343458097",
        cyber = "rbxassetid://9507126891",
        sorcerer = "rbxassetid://97940108361528",
        bigman = "rbxassetid://9155467211",
        spirit_assassin = "rbxassetid://10406002412",
        farmer_cletus = "rbxassetid://9155466936",
        ice_queen = "rbxassetid://9155466204",
        grim_reaper = "rbxassetid://9155467410",
        spirit_gardener = "rbxassetid://132108376114488",
        hannah = "rbxassetid://10726577232",
        shielder = "rbxassetid://9155464114",
        summoner = "rbxassetid://18922378956",
        glacial_skater = "rbxassetid://84628060516931",
        dragon_sword = "rbxassetid://16215630104",
        lumen = "rbxassetid://9630018371",
        flower_bee = "rbxassetid://101569742252812",
        jellyfish = "rbxassetid://18129974852",
        melody = "rbxassetid://9155464915",
        mimic = "rbxassetid://14783283296",
        miner = "rbxassetid://9166208461",
        nazar = "rbxassetid://18926951849",
        seahorse = "rbxassetid://11902552560",
        elk_master = "rbxassetid://15714972287",
        rebellion_leader = "rbxassetid://18926409564",
        void_hunter = "rbxassetid://122370766273698",
        taliyah = "rbxassetid://13989437601",
        angel = "rbxassetid://9166208240",
        harpoon = "rbxassetid://18250634847",
        void_walker = "rbxassetid://78915127961078",
        spirit_summoner = "rbxassetid://95760990786863",
        triple_shot = "rbxassetid://9166208149",
        void_knight = "rbxassetid://73636326782144",
        regent = "rbxassetid://9166208904",
        vulcan = "rbxassetid://9155465543",
        owl = "rbxassetid://12509401147",
        dasher = "rbxassetid://9155467645",
        disruptor = "rbxassetid://11596993583",
        wizard = "rbxassetid://13353923546",
        aery = "rbxassetid://9155463221",
        agni = "rbxassetid://17024640133",
        alchemist = "rbxassetid://9155462512",
        spearman = "rbxassetid://9166207341",
        beekeeper = "rbxassetid://9312831285",
        falconer = "rbxassetid://17022941869",
        bounty_hunter = "rbxassetid://9166208649",
        blood_assassin = "rbxassetid://12520290159",
        battery = "rbxassetid://10159166528",
        steam_engineer = "rbxassetid://15380413567",
        vesta = "rbxassetid://9568930198",
        beast = "rbxassetid://9155465124",
        dino_tamer = "rbxassetid://9872357009",
        drill = "rbxassetid://12955100280",
        elektra = "rbxassetid://13841413050",
        fisherman = "rbxassetid://9166208359",
        queen_bee = "rbxassetid://12671498918",
        card = "rbxassetid://13841410580",
        frosty = "rbxassetid://9166208762",
        gingerbread_man = "rbxassetid://9155464364",
        ghost_catcher = "rbxassetid://9224802656",
        tinker = "rbxassetid://17025762404",
        ignis = "rbxassetid://13835258938",
        oil_man = "rbxassetid://9166206259",
        jade = "rbxassetid://9166306816",
        dragon_slayer = "rbxassetid://10982192175",
        paladin = "rbxassetid://11202785737",
        pinata = "rbxassetid://10011261147",
        merchant = "rbxassetid://9872356790",
        metal_detector = "rbxassetid://9378298061",
        slime_tamer = "rbxassetid://15379766168",
        nyoka = "rbxassetid://17022941410",
        midnight = "rbxassetid://9155462763",
        pyro = "rbxassetid://9155464770",
        raven = "rbxassetid://9166206554",
        santa = "rbxassetid://9166206101",
        sheep_herder = "rbxassetid://9155465730",
        smoke = "rbxassetid://9155462247",
        spirit_catcher = "rbxassetid://9166207943",
        star_collector = "rbxassetid://9872356516",
        styx = "rbxassetid://17014536631",
        block_kicker = "rbxassetid://15382536098",
        trapper = "rbxassetid://9166206875",
        hatter = "rbxassetid://12509388633",
        ninja = "rbxassetid://15517037848",
        jailor = "rbxassetid://11664116980",
        warrior = "rbxassetid://9166207008",
        mage = "rbxassetid://10982191792",
        void_dragon = "rbxassetid://10982192753",
        cat = "rbxassetid://15350740470",
        wind_walker = "rbxassetid://9872355499",
        skeleton = "rbxassetid://120123419412119",
        winter_lady = "rbxassetid://83274578564074",
        soul_broker = "rbxassetid://130409166262430",
    }

    local MAX_GAMES = 8

    local kitRender
    local lastKitCache, lastKitPending, lastKitRetry = {}, {}, {}
    local partyCache, partyNumbers = {}, {}
    local currentDraft = nil

    local function playerGui()
        return LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:FindFirstChild("PlayerGui")
    end

    local function kitImage(kit)
        kit = kit or "none"
        local meta = Bedwars.KitMeta and (Bedwars.KitMeta[kit] or Bedwars.KitMeta.none)
        return (meta and meta.renderImage) or KIT_IMAGES[kit] or KIT_IMAGES.none or ""
    end
    Bedwars.KitImage = kitImage

    local function clearCaches()
        lastKitCache, lastKitPending, lastKitRetry = {}, {}, {}
        partyCache, partyNumbers = {}, {}
    end

    local function destroyNamed(root, name)
        if not root then
            return
        end
        for _, inst in ipairs(root:GetDescendants()) do
            if inst.Name == name then
                inst:Destroy()
            end
        end
    end

    local function cleanupVisuals()
        local gui = playerGui()
        destroyNamed(gui, "NovaKitRender")
        destroyNamed(gui, "NovaKitLevel")
        destroyNamed(gui, "NovaLastKit")
        destroyNamed(gui, "NovaParty")
    end

    -- Match history -> kits -----------------------------------------------------------
    local function extractHistory(payload)
        if type(payload) ~= "table" then
            return nil
        end
        if type(payload.matchHistory) == "table" then
            return payload.matchHistory
        end
        if type(payload.data) == "table" then
            if type(payload.data.matchHistory) == "table" then
                return payload.data.matchHistory
            end
            if type(payload.data.history) == "table" then
                return payload.data.history
            end
            if next(payload.data) ~= nil then
                return payload.data
            end
        end
        if type(payload.history) == "table" then
            return payload.history
        end
        return payload
    end

    local function matchEntry(match, userId)
        if type(match) ~= "table" or type(match.players) ~= "table" then
            return nil
        end
        for _, entry in pairs(match.players) do
            local info = entry and entry.playerInfo
            if info and tostring(info.userId) == tostring(userId) then
                return entry
            end
        end
        return nil
    end

    local FINISHED = { win = true, loss = true, lose = true, lost = true, defeat = true, victory = true }

    local function readLastKits(history, userId)
        if type(history) ~= "table" then
            return nil
        end
        local matches, order = {}, 0
        for index, match in pairs(history) do
            if type(match) == "table" then
                order = order + 1
                matches[#matches + 1] = {
                    match = match,
                    time = tonumber(match.matchStartTime) or tonumber(match.startTime) or 0,
                    order = order,
                    index = tonumber(index) or order,
                }
            end
        end
        table.sort(matches, function(a, b)
            if a.time ~= b.time then
                return a.time > b.time
            end
            if a.index ~= b.index then
                return a.index < b.index
            end
            return a.order < b.order
        end)

        local kits, loose = {}, {}
        for _, record in ipairs(matches) do
            local entry = matchEntry(record.match, userId)
            local kit = entry and entry.bedwars and entry.bedwars.kit
            if type(kit) == "string" and kit ~= "" then
                local outcome = entry.generic and string.lower(tostring(entry.generic.matchOutcome or "")) or ""
                if FINISHED[outcome] then
                    kits[#kits + 1] = kit
                    if #kits >= MAX_GAMES then
                        break
                    end
                elseif #loose < MAX_GAMES then
                    loose[#loose + 1] = kit
                end
            end
        end
        if #kits == 0 then
            kits = loose
        end
        return #kits > 0 and kits or nil
    end

    -- teammates over the last few matches -> { [userId] = timesTogether }
    local function readTeammates(history, userId)
        local found = {}
        if type(history) ~= "table" then
            return found
        end
        local matches = {}
        for _, match in pairs(history) do
            if type(match) == "table" and type(match.players) == "table" then
                matches[#matches + 1] = match
            end
        end
        table.sort(matches, function(a, b)
            return (tonumber(a.matchStartTime) or 0) > (tonumber(b.matchStartTime) or 0)
        end)
        for index = 1, math.min(5, #matches) do
            local match = matches[index]
            local me = matchEntry(match, userId)
            local myTeam = me and (me.teamId or (me.generic and me.generic.team))
            if myTeam then
                for _, entry in pairs(match.players) do
                    local info = entry and entry.playerInfo
                    local otherTeam = entry and (entry.teamId or (entry.generic and entry.generic.team))
                    if info and info.userId and not entry.observer and tostring(info.userId) ~= tostring(userId)
                        and tostring(otherTeam) == tostring(myTeam) then
                        local key = tonumber(info.userId)
                        found[key] = (found[key] or 0) + 1
                    end
                end
            end
        end
        return found
    end

    local function finishHistory(userId, payload)
        local history = extractHistory(payload)
        lastKitCache[userId] = readLastKits(history, userId) or false
        partyCache[userId] = readTeammates(history, userId)
        lastKitPending[userId] = nil
        lastKitRetry[userId] = nil
    end

    local function failHistory(userId)
        lastKitPending[userId] = nil
        lastKitRetry[userId] = os.clock() + 1.5
    end

    local function fetchHistory(plr)
        local userId = plr.UserId
        if lastKitCache[userId] ~= nil or lastKitPending[userId] then
            return
        end
        if lastKitRetry[userId] and os.clock() < lastKitRetry[userId] then
            return
        end
        lastKitPending[userId] = true

        task.spawn(function()
            local request
            local controller = Bedwars.MatchHistoryController
            if controller and type(controller.requestMatchHistory) == "function" then
                local ok, result = pcall(function()
                    return controller:requestMatchHistory(plr.Name)
                end)
                if ok then
                    request = result
                end
            end
            if not request and Bedwars.Client then
                pcall(function()
                    request = Bedwars.Client:Get("RequestMatchHistory"):CallServerAsync(plr.Name)
                end)
            end
            if not request then
                failHistory(userId)
                return
            end
            if type(request) == "table" and type(request.andThen) == "function" then
                local chained = pcall(function()
                    request:andThen(function(data)
                        finishHistory(userId, data)
                    end):catch(function()
                        failHistory(userId)
                    end)
                end)
                if not chained then
                    failHistory(userId)
                end
            elseif type(request) == "table" then
                finishHistory(userId, request)
            else
                failHistory(userId)
            end
        end)
    end

    -- Party numbers: players on the same team who keep showing up together share a number
    local function computePartyNumbers()
        local list = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if partyCache[plr.UserId] then
                list[#list + 1] = plr
            end
        end
        table.sort(list, function(a, b)
            return a.UserId < b.UserId
        end)
        local parent = {}
        local function find(x)
            while parent[x] ~= x do
                x = parent[x]
            end
            return x
        end
        for _, plr in ipairs(list) do
            parent[plr.UserId] = plr.UserId
        end
        for i, a in ipairs(list) do
            for j = i + 1, #list do
                local b = list[j]
                if a:GetAttribute("Team") == b:GetAttribute("Team") then
                    local ab = partyCache[a.UserId][b.UserId] or 0
                    local ba = partyCache[b.UserId][a.UserId] or 0
                    if math.max(ab, ba) >= 2 then
                        parent[find(b.UserId)] = find(a.UserId)
                    end
                end
            end
        end
        local groups, order = {}, {}
        for _, plr in ipairs(list) do
            local root = find(plr.UserId)
            if not groups[root] then
                groups[root] = {}
                order[#order + 1] = root
            end
            groups[root][#groups[root] + 1] = plr.UserId
        end
        local numbers, n = {}, 0
        for _, root in ipairs(order) do
            if #groups[root] >= 2 then
                n = n + 1
                for _, id in ipairs(groups[root]) do
                    numbers[id] = n
                end
            end
        end
        return numbers
    end

    -- Draft UI helpers ------------------------------------------------------------------
    local function unclip(inst)
        local node = inst
        for _ = 1, 7 do
            if not node then
                break
            end
            pcall(function()
                node.ClipsDescendants = false
            end)
            node = node.Parent
        end
    end

    local function playerFromRender(render)
        local image = tostring(render.Image or "")
        local userId = string.match(image, "id=(%d+)") or string.match(image, "userId=(%d+)") or string.match(image, "(%d+)")
        if userId then
            local plr = Players:GetPlayerByUserId(tonumber(userId))
            if plr then
                return plr
            end
        end
        local node = render.Parent
        for _ = 1, 6 do
            if not node then
                break
            end
            local label = node:FindFirstChild("PlayerName", true)
            if label and label:IsA("TextLabel") then
                for _, plr in ipairs(Players:GetPlayers()) do
                    if plr.Name == label.Text or plr.DisplayName == label.Text
                        or plr:GetAttribute("DisguiseDisplayName") == label.Text then
                        return plr
                    end
                end
            end
            node = node.Parent
        end
        return nil
    end

    local function findHost(render)
        local node, fallback = render, nil
        for _ = 1, 8 do
            node = node and node.Parent
            if not node then
                break
            end
            if node.Name == "MatchDraftPlayerCard" then
                return node
            end
            if not fallback and node:FindFirstChild("PlayerName", true) and node:FindFirstChild("PlayerRender", true) then
                fallback = node
            end
        end
        return fallback or render.Parent
    end

    local function isEnemy(plr)
        if not plr or plr == LocalPlayer then
            return false
        end
        local mine, theirs = LocalPlayer:GetAttribute("Team"), plr:GetAttribute("Team")
        if not mine or not theirs then
            return false
        end
        return mine ~= theirs
    end

    -- The game only seems to populate this attribute once a kit is actually locked in, not while
    -- someone is still "SELECTING KIT..." - showing the "none" placeholder art during that window
    -- looked like every enemy had the same generic/blank icon, which is the "doesn't show the
    -- current kit" bug. Safer to just hide it until a real kit shows up than to show a wrong one.
    local function ensureKitIcon(host, plr)
        unclip(host)
        local icon = host:FindFirstChild("NovaKitRender")
        if not icon then
            icon = New("ImageLabel", {
                Name = "NovaKitRender",
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1.05, 0, 0.5, 0),
                Size = UDim2.new(1.5, 0, 1.5, 0),
                SizeConstraint = Enum.SizeConstraint.RelativeYY,
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                ImageTransparency = 0.08,
                ScaleType = Enum.ScaleType.Crop,
                Visible = false,
                ZIndex = 5,
                Parent = host,
            }, {
                New("UIAspectRatioConstraint", {
                    AspectRatio = 1,
                    AspectType = Enum.AspectType.FitWithinMaxSize,
                    DominantAxis = Enum.DominantAxis.Width,
                }),
            })
        end
        local raw = plr:GetAttribute("PlayingAsKits")
        if type(raw) == "string" and raw ~= "" and raw ~= "none" then
            local image = kitImage(raw)
            if icon.Image ~= image then
                icon.Image = image
            end
            icon.Visible = true
        else
            icon.Visible = false
        end
    end

    local function ensureLevel(host, plr)
        local nameLabel = host:FindFirstChild("PlayerName", true)
        if not nameLabel then
            return
        end
        unclip(nameLabel)
        local levelLabel = nameLabel:FindFirstChild("NovaKitLevel")
        if not levelLabel then
            levelLabel = New("TextLabel", {
                Name = "NovaKitLevel",
                AnchorPoint = Vector2.new(0, 0.5),
                Position = UDim2.new(1, 5, 0.5, 0),
                Size = UDim2.fromOffset(44, 15),
                BackgroundTransparency = 1,
                TextColor3 = Color3.fromRGB(255, 214, 51),
                TextSize = 12,
                Font = Enum.Font.GothamBold,
                TextStrokeTransparency = 0.25,
                TextStrokeColor3 = Color3.new(0, 0, 0),
                TextXAlignment = Enum.TextXAlignment.Left,
                TextYAlignment = Enum.TextYAlignment.Center,
                ZIndex = 10001,
                Parent = nameLabel,
            })
        end
        local text = "[" .. tostring(plr:GetAttribute("PlayerLevel") or 0) .. "]"
        if levelLabel.Text ~= text then
            levelLabel.Text = text
        end
    end

    -- One small kit icon per past game, laid out in a row along the top of the card
    local function createLastBadge(host, plr, slot)
        local badge = New("Frame", {
            Name = "NovaLastKit",
            AnchorPoint = Vector2.new(0, 0),
            Position = UDim2.new(0.045 + (slot - 1) * 0.113, 0, 0, 4),
            Size = UDim2.new(0.105, 0, 0.105, 0),
            SizeConstraint = Enum.SizeConstraint.RelativeXX,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ClipsDescendants = false,
            ZIndex = 10000,
            Visible = false,
            Parent = host,
        })
        badge:SetAttribute("Slot", slot)
        New("ImageLabel", {
            Name = "Render",
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ImageTransparency = 0.05,
            ScaleType = Enum.ScaleType.Fit,
            ZIndex = 10001,
            Parent = badge,
        })
        New("TextLabel", {
            Name = "Number",
            Position = UDim2.fromOffset(0, -1),
            Size = UDim2.fromOffset(10, 9),
            BackgroundTransparency = 1,
            Text = tostring(slot),
            TextColor3 = Color3.new(1, 1, 1),
            TextSize = 9,
            Font = Enum.Font.GothamBold,
            TextStrokeTransparency = 0.3,
            TextStrokeColor3 = Color3.new(0, 0, 0),
            TextXAlignment = Enum.TextXAlignment.Left,
            ZIndex = 10002,
            Parent = badge,
        })
        return badge
    end

    local function ensureLastMatch(host, plr)
        local cfg = kitRender.Config
        if not cfg.LastMatch then
            for _, child in ipairs(host:GetChildren()) do
                if child.Name == "NovaLastKit" then
                    child:Destroy()
                end
            end
            return
        end
        unclip(host)
        local count = math.clamp(math.floor(tonumber(cfg.LastGames) or MAX_GAMES), 1, MAX_GAMES)
        local badges = {}
        for _, child in ipairs(host:GetChildren()) do
            if child.Name == "NovaLastKit" then
                local slot = child:GetAttribute("Slot") or 1
                if slot > count or badges[slot] then
                    child:Destroy()
                else
                    badges[slot] = child
                end
            end
        end
        local cached = lastKitCache[plr.UserId]
        if cached == nil then
            fetchHistory(plr)
        end
        for slot = 1, count do
            local badge = badges[slot] or createLastBadge(host, plr, slot)
            local kit = type(cached) == "table" and cached[slot]
            if kit then
                local render = badge:FindFirstChild("Render")
                local image = kitImage(kit)
                if render and render.Image ~= image then
                    render.Image = image
                end
                badge.Visible = true
            else
                badge.Visible = false
            end
        end
    end

    local function ensureParty(host, plr)
        local icon = host:FindFirstChild("NovaKitRender")
        if not icon then
            return
        end
        local badge = icon:FindFirstChild("NovaParty")
        local number = kitRender.Config.Party and partyNumbers[plr.UserId]
        if not number then
            if badge then
                badge.Visible = false
            end
            return
        end
        if not badge then
            badge = New("TextLabel", {
                Name = "NovaParty",
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, 2, 0, -2),
                Size = UDim2.fromOffset(16, 16),
                BackgroundColor3 = Color3.fromRGB(40, 120, 255),
                BorderSizePixel = 0,
                TextColor3 = Color3.new(1, 1, 1),
                TextSize = 11,
                Font = Enum.Font.GothamBold,
                ZIndex = 10003,
                Parent = icon,
            }, {
                New("UICorner", { CornerRadius = UDim.new(1, 0) }),
                New("UIStroke", { ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Thickness = 1, Color = Color3.new(0, 0, 0) }),
            })
        end
        local text = tostring(number)
        if badge.Text ~= text then
            badge.Text = text
        end
        badge.Visible = true
    end

    local function processRender(render)
        if not render.Parent or render.Name ~= "PlayerRender" or not render:IsA("ImageLabel") then
            return
        end
        local plr = playerFromRender(render)
        if not plr then
            return
        end
        local host = findHost(render)
        if not host or not host.Parent then
            return
        end
        if not isEnemy(plr) then
            local mine, theirs = LocalPlayer:GetAttribute("Team"), plr:GetAttribute("Team")
            if mine and theirs and mine == theirs then
                destroyNamed(host, "NovaKitRender")
                destroyNamed(host, "NovaKitLevel")
                destroyNamed(host, "NovaLastKit")
            end
            return
        end

        local cfg = kitRender.Config
        ensureKitIcon(host, plr)
        if cfg.Level then
            ensureLevel(host, plr)
        else
            destroyNamed(host, "NovaKitLevel")
        end
        ensureLastMatch(host, plr)
        if cfg.Party and lastKitCache[plr.UserId] == nil then
            fetchHistory(plr)
        end
        ensureParty(host, plr)
    end

    local function scanDraft(app)
        if not app or not app.Parent then
            return
        end
        partyNumbers = computePartyNumbers()
        for _, inst in ipairs(app:GetDescendants()) do
            if inst.Name == "PlayerRender" and inst:IsA("ImageLabel") then
                pcall(processRender, inst)
            end
        end
    end

    local function rescan()
        if kitRender and kitRender.Enabled then
            local gui = playerGui()
            local app = gui and gui:FindFirstChild("MatchDraftApp")
            if app then
                pcall(scanDraft, app)
            end
        end
    end

    kitRender = Tabs.Render:CreateModule({
        Name = "Kit Render",
        Description = "Shows enemy kits, levels and parties on the draft screen (Bedwars).",
        OnEnable = function(mod)
            local ready, reason = Bedwars.ResolveExtras()
            assert(ready, reason)

            cleanupVisuals()
            clearCaches()
            currentDraft = nil
            mod.Maid:Give(function()
                currentDraft = nil
                clearCaches()
                cleanupVisuals()
            end)
            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    local gui = playerGui()
                    local app = gui and gui:FindFirstChild("MatchDraftApp")
                    if app ~= currentDraft then
                        cleanupVisuals()
                        clearCaches()
                        currentDraft = app
                    end
                    if app then
                        pcall(scanDraft, app)
                    end
                    task.wait(0.25)
                end
            end))
        end,
    })

    kitRender:AddSection("Show")
    kitRender:AddToggle({
        Label = "Last Match Kits", Key = "LastMatch", Default = true,
        Tip = "The kit each enemy used in their previous matches.",
        Callback = function(value)
            if not value then
                destroyNamed(playerGui(), "NovaLastKit")
            else
                clearCaches()
                rescan()
            end
        end,
    })
    kitRender:AddSlider({
        Label = "Last Games", Key = "LastGames", Min = 1, Max = 8, Default = 8, Step = 1,
        Tip = "How many of their previous games to show (1 is their most recent).",
        ShowIf = function(c) return c.LastMatch end,
        Callback = rescan,
    })
    kitRender:AddToggle({ Label = "Level", Key = "Level", Default = true, Tip = "Their account level next to their name.", Callback = rescan })
    kitRender:AddToggle({
        Label = "Party Numbers", Key = "Party", Default = true,
        Tip = "Players who queue together get the same number.",
        Callback = rescan,
    })
    kitRender:AddNote("Only does anything on the Bedwars kit draft screen, before the match starts.")
end

-- ====================== MODULE: SPEED ======================
do
    local MAX_SPEED = 23

    local speed = Tabs.Blatant:CreateModule({
        Name = "Speed",
        Description = "WalkSpeed boost (hard capped at 23).",
        OnEnable = function(mod)
            local cfg = mod.Config
            local original = {}   -- humanoid -> base walk speed
            local lastSet = {}    -- humanoid -> value we last wrote
            local activeHumanoid = nil

            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                local _, hum = Util.GetCharacter(LocalPlayer)
                if not hum then
                    return
                end
                activeHumanoid = hum

                local target = math.min(cfg.WalkSpeed, MAX_SPEED)
                local current = hum.WalkSpeed

                -- If the game changed the speed (not us), treat that as the new base
                if lastSet[hum] == nil or current ~= lastSet[hum] then
                    original[hum] = current
                end

                if original[hum] and original[hum] > 0 then
                    if current ~= target then
                        hum.WalkSpeed = target
                    end
                    lastSet[hum] = target
                end
            end))

            mod.Maid:Give(function()
                for hum, base in pairs(original) do
                    pcall(function()
                        if hum.Parent and lastSet[hum] ~= nil then
                            hum.WalkSpeed = base
                        end
                    end)
                end
                activeHumanoid = nil
            end)
        end,
    })

    speed:AddSlider({ Label = "WalkSpeed", Key = "WalkSpeed", Min = 16, Max = MAX_SPEED, Default = 20, Step = 0.5, Tip = "Capped at 23 to stay under most anti-cheats." })
end

-- ====================== MODULE: NUKER ======================
-- Digs through a bed's defence: finds the cheapest route of blocks from the outside to the target
-- and breaks the block at the outer end of that route, over and over. Also breaks lucky blocks,
-- iron ore and a few kit objects around you.
do
    local CollectionService = service("CollectionService")
    local ReplicatedStorage = service("ReplicatedStorage")

    local FACES = {
        Vector3.new(3, 0, 0), Vector3.new(-3, 0, 0),
        Vector3.new(0, 3, 0), Vector3.new(0, -3, 0),
        Vector3.new(0, 0, 3), Vector3.new(0, 0, -3),
    }
    local FLAT = Vector3.new(1, 0, 1)
    local TRACKED_NAMES = { "bed", "tesla_trap", "beehive", "pinata", "carrot", "melon", "pumpkin", "snow_pile" }

    local nuker
    local parts = {}                 -- path preview boxes
    local highlightBox
    local plan                       -- { target, route, anchor, time, blatant }
    local lastHit, lastAbility = 0, 0
    local breakableCache = setmetatable({}, { __mode = "k" })
    local recentlyHit = setmetatable({}, { __mode = "k" }) -- [block] = time of our last hit on it
    local toolCache, toolStamp = {}, 0
    local stats = { Sent = 0, Reply = "none yet", Replies = {} }

    -- Blocks ---------------------------------------------------------------------------
    local function getPlacedBlock(position)
        local controller = Bedwars.BlockController
        if not position or not controller then
            return nil
        end
        local cell = controller:getBlockPosition(position)
        return controller:getStore():getBlockAt(cell), cell
    end

    local function heldItemName()
        local char = LocalPlayer.Character
        local hand = char and char:FindFirstChild("HandInvItem")
        local item = hand and hand.Value
        return item and item.Name or nil
    end

    local function holdingBreakTool()
        local name = heldItemName()
        local meta = name and Bedwars.ItemMeta and Bedwars.ItemMeta[name]
        return meta ~= nil and meta.breakBlock ~= nil
    end

    local function breakTypeOf(block)
        if not block then
            return nil
        end
        if block.Name == "gumdrop_bounce_pad" then
            return "stone"
        end
        local meta = Bedwars.ItemMeta and Bedwars.ItemMeta[block.Name]
        return meta and meta.block and meta.block.breakType
    end

    -- Best tool in your inventory for a break type (rebuilt twice a second)
    local function bestToolFor(breakType)
        if os.clock() - toolStamp > 0.5 then
            toolCache, toolStamp = {}, os.clock()
        end
        local cached = toolCache[breakType]
        if cached then
            return cached.Item, cached.Damage
        end
        local inventory = Bedwars.GetInventory()
        local bestItem, bestDamage = nil, 0
        if inventory then
            for _, item in pairs(inventory.inventory.items or {}) do
                local meta = Bedwars.ItemMeta[item.itemType]
                local damage = meta and meta.breakBlock and meta.breakBlock[breakType] or 0
                if damage > bestDamage then
                    bestItem, bestDamage = item, damage
                end
            end
        end
        toolCache[breakType] = { Item = bestItem, Damage = bestDamage }
        return bestItem, bestDamage
    end

    local function healthOf(block, cell)
        local data
        pcall(function()
            data = Bedwars.BlockController:getStore():getBlockData(cell)
        end)
        local health = data and (data:GetAttribute("1") or data:GetAttribute("Health"))
        if health == nil then
            health = block:GetAttribute("Health")
        end
        if health ~= nil then
            return health
        end
        local meta = Bedwars.ItemMeta and Bedwars.ItemMeta[block.Name]
        return (meta and meta.block and meta.block.health) or 10
    end

    local function toolDamage(itemType, breakType)
        local meta = itemType and Bedwars.ItemMeta[itemType]
        return meta and meta.breakBlock and breakType and meta.breakBlock[breakType] or 2
    end

    -- How many hits it takes to break a block with the best tool you own
    local function hitsToBreak(block, worldPosition)
        local breakType = breakTypeOf(block)
        local damage = 2
        if breakType then
            local _, best = bestToolFor(breakType)
            if best and best > 0 then
                damage = best
            end
        end
        local cell = Bedwars.BlockController:getBlockPosition(worldPosition)
        return healthOf(block, cell) / damage
    end

    -- Team / protection checks -----------------------------------------------------------
    local function teamKey(value)
        if value == nil then
            return nil
        end
        if typeof(value) == "Instance" then
            return tostring(value.Name)
        end
        return tostring(value)
    end

    local function playerTeamKey(plr)
        if not plr then
            return nil
        end
        return teamKey(plr:GetAttribute("Team") or plr:GetAttribute("TeamId") or plr:GetAttribute("TeamID") or plr.Team)
    end

    local function isOwnTeamBlock(block)
        local mine = playerTeamKey(LocalPlayer)
        local blockTeam = teamKey(block:GetAttribute("Team") or block:GetAttribute("TeamId") or block:GetAttribute("TeamID"))
        if mine and blockTeam and mine == blockTeam then
            return true
        end
        local placedBy = tonumber(block:GetAttribute("PlacedByUserId"))
        if placedBy == LocalPlayer.UserId then
            return true
        end
        local placer = placedBy and Players:GetPlayerByUserId(placedBy)
        local theirs = placer and playerTeamKey(placer)
        return mine ~= nil and theirs ~= nil and mine == theirs
    end

    local function blockAllowed(block)
        if not block or not block.Parent or block:GetAttribute("NoBreak") then
            return false
        end
        local mine = LocalPlayer:GetAttribute("Team")
        if mine and block:GetAttribute("Team" .. tostring(mine) .. "NoBreak") then
            return false
        end
        return nuker.Config.SelfBreak or not isOwnTeamBlock(block)
    end

    -- The game's own "can this be broken" check, cached for half a second. If the check can't
    -- run at all, the block is treated as breakable and the server decides.
    local function isBreakable(block)
        -- The game's check can flip to false while a block is mid-break, which used to end the dig
        -- after one hit. Anything we hit in the last few seconds stays breakable.
        if os.clock() - (recentlyHit[block] or -10) < 4 then
            return true
        end
        local cached = breakableCache[block]
        if cached and os.clock() - cached.t < 0.5 then
            return cached.v
        end
        local ok, result = pcall(function()
            local controller = Bedwars.BlockController
            return controller:isBlockBreakable({ blockPosition = controller:getBlockPosition(block.Position) }, LocalPlayer)
        end)
        local value = true
        if ok and result ~= nil then
            value = result and true or false
        end
        breakableCache[block] = { v = value, t = os.clock() }
        return value
    end

    local function containedCells(block)
        local out = {}
        local ok, handler = pcall(function()
            return Bedwars.BlockController:getHandlerRegistry():getHandler(block.Name)
        end)
        if ok and handler then
            local ok2, cells = pcall(function()
                return handler:getContainedPositions(block)
            end)
            if ok2 and cells then
                for _, cell in pairs(cells) do
                    out[#out + 1] = cell * 3
                end
            end
        end
        if #out == 0 then
            out[1] = Bedwars.BlockController:getBlockPosition(block.Position) * 3
        end
        return out
    end

    local function nearestCellDistance(block, origin)
        local best = math.huge
        for _, cell in ipairs(containedCells(block)) do
            best = math.min(best, (cell - origin).Magnitude)
        end
        return best
    end

    -- Route planning -------------------------------------------------------------------------
    local function heapPush(heap, node)
        local i = #heap + 1
        heap[i] = node
        while i > 1 do
            local parent = i // 2
            if heap[parent][1] <= node[1] then
                break
            end
            heap[i], heap[parent] = heap[parent], node
            i = parent
        end
    end

    local function heapPop(heap)
        local top = heap[1]
        local last = table.remove(heap)
        if #heap > 0 then
            heap[1] = last
            local i = 1
            while true do
                local child = i * 2
                if child > #heap then
                    break
                end
                if child < #heap and heap[child + 1][1] < heap[child][1] then
                    child = child + 1
                end
                if heap[i][1] <= heap[child][1] then
                    break
                end
                heap[i], heap[child] = heap[child], heap[i]
                i = child
            end
        end
        return top
    end

    -- Cheapest list of block cells from the outside to `target`. route[1] is the block to hit now.
    -- opts: origin, anchor, nearFirst, angle, filter(block) -> bool
    local function planRoute(target, opts)
        local _, _, root = Util.GetCharacter(LocalPlayer)
        local cam = Workspace.CurrentCamera
        if not root or not target or not cam then
            return nil
        end
        local origin = opts.origin or root.Position
        local anchor = opts.anchor or origin
        local nearFirst = opts.nearFirst
        local filter = opts.filter
        local angle = opts.angle or 360
        local range = opts.range or 30
        -- Why a candidate block got turned away, so a dead-end search can say something more
        -- useful than just "no way in": diag.Seen is every breakable-looking block the Dijkstra
        -- touched; the rest are how many of those it had to reject, and why.
        local diag = { Seen = 0, Far = 0, Protected = 0, Angle = 0, Sealed = 0, NoLOS = 0 }
        local cells = containedCells(target)
        local targetCells = {}
        for _, cell in ipairs(cells) do
            targetCells[cell] = true
        end

        -- Is this cell connected to open air (not enclosed)?
        local airMemo = {}
        local function openAir(cell)
            local known = airMemo[cell]
            if known ~= nil then
                return known
            end
            local seen, queue, head, open = { [cell] = true }, { cell }, 1, false
            while queue[head] do
                local current = queue[head]
                head = head + 1
                if airMemo[current] ~= nil then
                    open = airMemo[current]
                    break
                end
                if (current - cell).Magnitude > 20 or head > 400 then
                    open = true
                    break
                end
                for _, face in ipairs(FACES) do
                    local nxt = current + face
                    if not seen[nxt] and not getPlacedBlock(nxt) then
                        seen[nxt] = true
                        queue[#queue + 1] = nxt
                    end
                end
            end
            for c in pairs(seen) do
                airMemo[c] = open
            end
            return open
        end

        local function exposed(cell)
            for _, face in ipairs(FACES) do
                local nxt = cell + face
                if not targetCells[nxt] and not getPlacedBlock(nxt) and openAir(nxt) then
                    return true
                end
            end
            return false
        end

        local hitMemo = {}
        local function hits(block, cell)
            local known = hitMemo[cell]
            if known then
                return known
            end
            known = math.max(math.ceil(hitsToBreak(block, cell)), 1)
            hitMemo[cell] = known
            return known
        end

        -- Target already reachable from outside: just hit it. "exposed" alone only means the cell
        -- is topologically connected to open air *somewhere* through the structure (a flood fill,
        -- not a straight line) - that let this fire on a bed that was still behind a wall from
        -- where you were actually standing, and the real swing then failed because there was no
        -- real line to it. A real line-of-sight check from the camera is what actually decides if
        -- you can reach it right now.
        local direct, directDist
        for _, cell in ipairs(cells) do
            local d = (cell - anchor).Magnitude
            if (cell - origin).Magnitude <= range and exposed(cell) and (not direct or d < directDist)
                and Util.HasLineOfSight(cam.CFrame.Position, cell) then
                direct, directDist = cell, d
            end
        end
        if direct then
            return { direct }, 0
        end

        local camFlat = cam.CFrame.LookVector * FLAT
        local useAngle = angle < 360 and camFlat.Magnitude > 0.01
        local halfAngle = math.rad(angle) / 2
        local function passable(block, cell)
            diag.Seen = diag.Seen + 1
            if (cell - origin).Magnitude > range then
                diag.Far = diag.Far + 1
                return false
            end
            if block:GetAttribute("NoBreak") then
                diag.Protected = diag.Protected + 1
                return false
            end
            if filter then
                local ok, allowed = pcall(filter, block)
                if not ok or not allowed then
                    diag.Protected = diag.Protected + 1
                    return false
                end
            end
            if useAngle then
                local flat = (cell - origin) * FLAT
                if flat.Magnitude > 0.01 and math.acos(math.clamp(camFlat.Unit:Dot(flat.Unit), -1, 1)) > halfAngle then
                    diag.Angle = diag.Angle + 1
                    return false
                end
            end
            return true
        end

        -- nearFirst: walk a line of blocks from your eyes to the target (what you could actually dig)
        if nearFirst then
            local function bound(index, component, delta)
                if delta == 0 then
                    return 0, math.huge, math.huge
                end
                local step = delta > 0 and 1 or -1
                return step, (((index + step * 0.5) * 3) - component) / delta, 3 / math.abs(delta)
            end
            local function traceLine(from, aim)
                local start = Bedwars.BlockController:getBlockPosition(from)
                local dir = aim - from
                local x, y, z = start.X, start.Y, start.Z
                local sx, nx, dx = bound(x, from.X, dir.X)
                local sy, ny, dy = bound(y, from.Y, dir.Y)
                local sz, nz, dz = bound(z, from.Z, dir.Z)
                local route, cost = {}, 0
                for _ = 1, 120 do
                    local cell = Vector3.new(x, y, z) * 3
                    if targetCells[cell] then
                        route[#route + 1] = cell
                        return route, cost
                    end
                    local block = getPlacedBlock(cell)
                    if block then
                        if block == target then
                            route[#route + 1] = cell
                            return route, cost
                        end
                        if not passable(block, cell) then
                            return nil
                        end
                        cost = cost + hits(block, cell)
                        route[#route + 1] = cell
                    end
                    if nx > 1 and ny > 1 and nz > 1 then
                        return nil
                    end
                    if nx <= ny and nx <= nz then
                        x, nx = x + sx, nx + dx
                    elseif ny <= nz then
                        y, ny = y + sy, ny + dy
                    else
                        z, nz = z + sz, nz + dz
                    end
                end
                return nil
            end
            local eyes = { origin }
            local head = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Head")
            if head then
                eyes[#eyes + 1] = head.Position
            end
            eyes[#eyes + 1] = cam.CFrame.Position
            local bestRoute, bestCost, bestDist
            for _, eye in ipairs(eyes) do
                for _, cell in ipairs(cells) do
                    for ox = -1, 1 do
                        for oy = -1, 1 do
                            for oz = -1, 1 do
                                local route, cost = traceLine(eye, cell + Vector3.new(ox, oy, oz) * 1.35)
                                if route and route[1] then
                                    local d = (route[1] - anchor).Magnitude
                                    if (route[1] - origin).Magnitude <= 30
                                        and (not bestCost or cost < bestCost or (cost == bestCost and d < bestDist)) then
                                        bestRoute, bestCost, bestDist = route, cost, d
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if bestRoute then
                return bestRoute, bestCost
            end
        end

        -- Otherwise: cheapest path through the blocks around the target (Dijkstra)
        local dist, prev, visited, heap = {}, {}, {}, {}
        for _, cell in ipairs(cells) do
            dist[cell] = 0
            heapPush(heap, { 0, cell })
        end
        local bestEntry, bestScore, bestCost
        local steps = 0
        while #heap > 0 and steps < 15000 do
            steps = steps + 1
            local node = heapPop(heap)
            local d, cell = node[1], node[2]
            if not visited[cell] then
                visited[cell] = true
                if not nearFirst and bestScore and d >= bestScore then
                    break
                end
                if not targetCells[cell] and getPlacedBlock(cell) then
                    if not exposed(cell) then
                        diag.Sealed = diag.Sealed + 1
                    -- exposed() is a flood fill: it only proves this block touches open air
                    -- *somewhere* through the structure, not that you can actually see/reach it
                    -- from where you're standing right now (that was the "picks a block it then
                    -- can't really hit" bug). A real line-of-sight check from the camera is the
                    -- only part of this that matches what the server will actually accept.
                    elseif not Util.HasLineOfSight(cam.CFrame.Position, cell) then
                        diag.NoLOS = diag.NoLOS + 1
                    else
                        local near = (cell - anchor).Magnitude
                        local score = nearFirst and (near + d * 0.25) or (d + near * 0.01)
                        if not bestScore or score < bestScore then
                            bestEntry, bestScore, bestCost = cell, score, d
                        end
                    end
                end
                for _, face in ipairs(FACES) do
                    local nxt = cell + face
                    if not visited[nxt] and not targetCells[nxt] then
                        local block = getPlacedBlock(nxt)
                        local step
                        if block then
                            if block ~= target and passable(block, nxt) then
                                step = hits(block, nxt)
                            end
                        elseif not openAir(nxt) then
                            step = 0
                        end
                        if step then
                            local nd = d + step
                            if nd < (dist[nxt] or math.huge) then
                                dist[nxt], prev[nxt] = nd, cell
                                heapPush(heap, { nd, nxt })
                            end
                        end
                    end
                end
            end
        end
        if not bestEntry then
            return nil, nil, diag
        end
        local route, current, guard = {}, bestEntry, 0
        while current and guard < 128 do
            route[#route + 1] = current
            if targetCells[current] then
                break
            end
            current = prev[current]
            guard = guard + 1
        end
        return route, bestCost
    end

    -- First block of a route that is still standing: (cell, block), or nil when the route is stale
    local function frontOf(current)
        for _, cell in ipairs(current.route) do
            local block = getPlacedBlock(cell)
            if block then
                if block == current.target then
                    return cell, block
                end
                if not blockAllowed(block) then
                    return nil
                end
                return cell, block
            end
        end
        return nil
    end

    -- Visuals --------------------------------------------------------------------------------
    local function ensureParts(count)
        while #parts < count do
            local part = Instance.new("Part")
            part.Anchored = true
            part.CanQuery = false
            part.CanCollide = false
            part.Transparency = 1
            part.Position = Vector3.zero
            part.Parent = Workspace.CurrentCamera or Workspace
            local adorn = Instance.new("BoxHandleAdornment")
            adorn.Name = "Box"
            adorn.Size = Vector3.one
            adorn.AlwaysOnTop = true
            adorn.ZIndex = 1
            adorn.Transparency = 0.5
            adorn.Adornee = part
            adorn.Parent = part
            parts[#parts + 1] = part
        end
    end

    local function hideParts()
        for _, part in ipairs(parts) do
            part.Position = Vector3.zero
        end
    end

    local function destroyParts()
        for _, part in ipairs(parts) do
            pcall(function()
                part:Destroy()
            end)
        end
        table.clear(parts)
    end

    local function drawRoute(route, active)
        if not nuker.Config.ShowPath or not route then
            hideParts()
            return
        end
        local index = 1
        for _, cell in ipairs(route) do
            if index > #parts then
                break
            end
            if getPlacedBlock(cell) then
                local part = parts[index]
                part.Position = cell
                part.Box.Color3 = (cell == active) and Color3.new(1, 0.2, 0.2) or Color3.new(0.2, 1, 0.2)
                index = index + 1
            end
        end
        for i = index, #parts do
            parts[i].Position = Vector3.zero
        end
    end

    local function setHighlight(block)
        if not nuker.Config.Highlight or not block or not block.Parent then
            if highlightBox then
                highlightBox.Adornee = nil
            end
            return
        end
        if not highlightBox then
            highlightBox = Instance.new("BoxHandleAdornment")
            highlightBox.AlwaysOnTop = true
            highlightBox.ZIndex = 10
            highlightBox.Transparency = 0.3
            highlightBox.Color3 = Theme.Accent
            highlightBox.Parent = Workspace.CurrentCamera or Workspace
        end
        highlightBox.Size = block.Size + Vector3.new(0.05, 0.05, 0.05)
        highlightBox.Adornee = block
    end

    local function clearVisuals()
        hideParts()
        setHighlight(nil)
    end

    local function cleanupAll()
        plan = nil
        table.clear(breakableCache)
        if highlightBox then
            pcall(function()
                highlightBox:Destroy()
            end)
            highlightBox = nil
        end
        destroyParts()
    end

    -- Kit abilities ----------------------------------------------------------------------------
    local function kitIs(name)
        local raw = LocalPlayer:GetAttribute("PlayingAsKits")
        return type(raw) == "string" and string.find(raw, name, 1, true) ~= nil
    end

    local function fireAbility(name)
        pcall(function()
            ReplicatedStorage:WaitForChild("events-@easy-games/game-core:shared/game-core-networking@getEvents.Events", 1)
                :WaitForChild("useAbility", 1):FireServer(name)
        end)
    end

    local function useKitAbilities(cfg)
        if os.clock() - lastAbility < 1 then
            return
        end
        if cfg.RagnarBreaker and kitIs("berserker") then
            lastAbility = os.clock()
            fireAbility("berserker_rage")
        end
        if cfg.YetiBreaker and kitIs("yeti") then
            lastAbility = os.clock()
            task.spawn(fireAbility, "yeti_glacial_roar")
        end
    end

    -- Hitting ---------------------------------------------------------------------------------
    -- The old version guessed the hit face purely from the player's dominant axis of approach,
    -- with no idea whether that face actually had anything open behind it. Against a block tucked
    -- around a corner (the last layer of a defense is exactly that) it would often claim a face
    -- that was still covered by another block, and the server silently drops a hit on a face that
    -- isn't really open - that's the "ghosting" where Nuker keeps swinging and nothing happens.
    -- This checks which of the 6 faces are actually empty first, and only picks among those.
    local function faceNormal(cell, origin)
        local toPlayer = origin - cell
        local toPlayerUnit = toPlayer.Magnitude > 0.01 and toPlayer.Unit or Vector3.new(0, 1, 0)
        local bestFace, bestDot
        for _, face in ipairs(FACES) do
            if not getPlacedBlock(cell + face) then
                local unit = face.Unit
                local dot = unit:Dot(toPlayerUnit)
                if not bestFace or dot > bestDot then
                    bestFace, bestDot = unit, dot
                end
            end
        end
        if bestFace then
            return bestFace
        end
        -- Every face reads as occupied (stale block cache, most likely) - fall back to the old guess.
        local ax, ay, az = math.abs(toPlayer.X), math.abs(toPlayer.Y), math.abs(toPlayer.Z)
        if ay >= ax and ay >= az then
            return Vector3.new(0, toPlayer.Y >= 0 and 1 or -1, 0)
        elseif ax >= az then
            return Vector3.new(toPlayer.X >= 0 and 1 or -1, 0, 0)
        end
        return Vector3.new(0, 0, toPlayer.Z >= 0 and 1 or -1)
    end

    local function holdingCorrectTool(cfg, block)
        if cfg.AutoTool then
            return true
        end
        local breakType = breakTypeOf(block)
        local correct = breakType and bestToolFor(breakType)
        if not correct then
            return true
        end
        return heldItemName() == correct.itemType
    end

    local function switchToHotbarItem(itemType)
        local inventory = Bedwars.GetInventory()
        if not (inventory and Bedwars.Store) then
            return false
        end
        for index, slot in ipairs(inventory.hotbar or {}) do
            if slot.item and slot.item.itemType == itemType then
                pcall(function()
                    Bedwars.Store:dispatch({ type = "InventorySelectHotbarSlot", slot = index - 1 })
                end)
                return true
            end
        end
        return false
    end

    local function hitCell(cfg, cell, block, origin)
        local controller = Bedwars.BlockController
        local blockPos = controller:getBlockPosition(cell)
        local breakType = breakTypeOf(block)
        local hitType = heldItemName()

        if cfg.AutoTool and holdingBreakTool() then
            local lastAttack = tonumber(Bedwars.SwordController and Bedwars.SwordController.lastAttack) or 0
            if Workspace:GetServerTimeNow() - lastAttack > 0.4 then
                local tool = breakType and bestToolFor(breakType)
                if tool and tool.itemType ~= hitType and switchToHotbarItem(tool.itemType) then
                    hitType = tool.itemType
                    task.wait(0.06)
                end
            end
        end

        if cfg.Animation and os.clock() - (stats.LastAnimation or 0) >= 0.18 then
            stats.LastAnimation = os.clock()
            task.spawn(function()
                local animation
                pcall(function()
                    animation = Bedwars.AnimationUtil:playAnimation(LocalPlayer, controller:getAnimationController():getAssetId(1))
                end)
                pcall(function()
                    Bedwars.ViewmodelController:playAnimation(15)
                end)
                task.wait(0.3)
                if animation then
                    pcall(function()
                        animation:Stop()
                        animation:Destroy()
                    end)
                end
            end)
        end

        recentlyHit[block] = os.clock()
        local before = healthOf(block, blockPos)
        local damage = toolDamage(hitType, breakType)
        local remote = Bedwars.DamageBlockRemotes:Get("DamageBlock")
        local promise = remote:CallServerAsync({
            blockRef = { blockPosition = blockPos },
            hitPosition = cell,
            hitNormal = faceNormal(cell, origin),
        })
        stats.Sent = stats.Sent + 1
        if type(promise) == "table" and type(promise.andThen) == "function" then
            promise:andThen(function(result)
                stats.Reply = tostring(result)
                stats.Replies[stats.Reply] = (stats.Replies[stats.Reply] or 0) + 1
                if result == "cancelled" then
                    return
                end
                if not cfg.Effects then
                    return
                end
                local predicted = math.max(before - damage, 0)
                local after = (result == "destroyed") and 0 or math.min(healthOf(block, blockPos) or predicted, predicted)
                local meta = Bedwars.ItemMeta[block.Name]
                local maxHealth = block:GetAttribute("MaxHealth") or (meta and meta.block and meta.block.health) or math.max(before, 1)
                pcall(function()
                    Bedwars.BlockBreaker.updateHealthbar(Bedwars.BlockBreaker, { blockPosition = blockPos }, before, maxHealth, math.max(before - after, 0), block)
                end)
                pcall(function()
                    if after <= 0 then
                        Bedwars.BlockBreaker.breakEffect:playBreak(block.Name, blockPos, LocalPlayer)
                    else
                        Bedwars.BlockBreaker.breakEffect:playHit(block.Name, blockPos, LocalPlayer)
                    end
                end)
            end)
        end
    end

    -- Legit mode: only the block under your cursor
    local cursorParams = RaycastParams.new()
    cursorParams.FilterType = Enum.RaycastFilterType.Exclude
    local function cursorBlock()
        local cam = Workspace.CurrentCamera
        if not cam then
            return nil
        end
        local point = UserInputService.TouchEnabled and cam.ViewportSize / 2 or UserInputService:GetMouseLocation()
        local ray = cam:ViewportPointToRay(point.X, point.Y, 0)
        local ignore = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Character then
                ignore[#ignore + 1] = plr.Character
            end
        end
        cursorParams.FilterDescendantsInstances = ignore
        local result = Workspace:Raycast(ray.Origin, ray.Direction * 999, cursorParams)
        return result and result.Instance, result and result.Position
    end

    -- Self check -------------------------------------------------------------------------------
    local function runDiagnostics()
        local lines = {}
        local function add(label, ok, detail)
            lines[#lines + 1] = (ok and "OK    " or "FAIL  ") .. label .. (detail ~= nil and (" - " .. tostring(detail)) or "")
        end
        local ready, reason = Bedwars.ResolveExtras()
        add("Bedwars found", Bedwars.Ready == true, reason)
        add("Block engine", Bedwars.BlockController ~= nil)
        add("Hit remote", Bedwars.DamageBlockRemotes ~= nil)
        add("Inventory", Bedwars.GetInventory() ~= nil, Bedwars.Store and nil or "store not found")
        local _, _, root = Util.GetCharacter(LocalPlayer)
        add("Your character", root ~= nil)
        local nearest, nearestDistance
        for _, obj in ipairs(Workspace:GetChildren()) do
            if obj.Name == "bed" and obj:IsA("BasePart") and root then
                local d = (obj.Position - root.Position).Magnitude
                if not nearestDistance or d < nearestDistance then
                    nearest, nearestDistance = obj, d
                end
            end
        end
        add("Beds in the map", nearest ~= nil or #CollectionService:GetTagged("bed") > 0, nearest and string.format("nearest %.0f studs", nearestDistance) or nil)
        if nearest and Bedwars.BlockController then
            add("Bed allowed (not shielded / not yours)", blockAllowed(nearest))
            add("Game says it's breakable", isBreakable(nearest))
            local ok, route = pcall(planRoute, nearest, { nearFirst = true, angle = 360, filter = blockAllowed })
            add("Way in found", ok and route ~= nil, ok and (route == nil and "blocked or too far" or #route .. " blocks") or tostring(route))
        end
        local counts = {}
        for reply, amount in pairs(stats.Replies) do
            counts[#counts + 1] = reply .. " x" .. amount
        end
        table.sort(counts)
        add("Hits sent", stats.Sent > 0, tostring(stats.Sent) .. ", last reply: " .. stats.Reply)
        add("Last idle reason", stats.LastIdle == nil, stats.LastIdle)
        add("Loop restarts", (stats.Restarts or 0) == 0, tostring(stats.Restarts or 0))
        add("Server replies", #counts > 0, #counts > 0 and table.concat(counts, ", ") or "none yet")
        local text = table.concat(lines, "\n")
        local copied = false
        if type(setclipboard) == "function" then
            copied = pcall(setclipboard, "Nuker check\n" .. text)
        end
        Nova.Notify("Nuker check" .. (copied and " (copied)" or ""), text, 14, "info", true)
    end

    nuker = Tabs.Blatant:CreateModule({
        Name = "Nuker",
        Description = "Digs through defences and breaks beds near you (Bedwars).",
        OnEnable = function(mod)
            local cfg = mod.Config
            local alive = true
            local setStatus = makeStatusLabel(mod, "Nuker", -160)
            plan = nil
            lastHit = 0
            table.clear(breakableCache)
            stats.Sent, stats.Reply, stats.Replies, stats.LastIdle, stats.Restarts = 0, "none yet", {}, nil, 0

            mod.Maid:Give(function()
                alive = false
                cleanupAll()
            end)

            -- Everything breakable that gets tracked while the module is on
            local beds = {}
            local function bedAdd(obj)
                if obj.Name == "bed" and obj:IsA("BasePart") and not table.find(beds, obj) then
                    beds[#beds + 1] = obj
                end
            end
            local function bedRemove(obj)
                local index = table.find(beds, obj)
                if index then
                    table.remove(beds, index)
                end
            end
            for _, obj in ipairs(Workspace:GetChildren()) do
                bedAdd(obj)
            end
            mod.Maid:Give(Workspace.ChildAdded:Connect(bedAdd))
            mod.Maid:Give(Workspace.ChildRemoved:Connect(bedRemove))

            local function tagList(tag)
                local list = {}
                local function add(inst)
                    if inst:IsA("BasePart") and not table.find(list, inst) then
                        list[#list + 1] = inst
                    end
                end
                mod.Maid:Give(CollectionService:GetInstanceAddedSignal(tag):Connect(add))
                mod.Maid:Give(CollectionService:GetInstanceRemovedSignal(tag):Connect(function(inst)
                    local index = table.find(list, inst)
                    if index then
                        table.remove(list, index)
                    end
                end))
                for _, inst in ipairs(CollectionService:GetTagged(tag)) do
                    add(inst)
                end
                return list
            end
            local taggedBeds = tagList("bed")
            local luckyBlocks = tagList("LuckyBlock")
            local ironOre = tagList("iron_ore_mesh_block")

            local tracked = {}
            for _, name in ipairs(TRACKED_NAMES) do
                tracked[name] = {}
            end
            local function trackAdd(obj)
                local list = tracked[obj.Name]
                if not list or (obj.Name == "bed" and not obj:IsA("BasePart")) then
                    return
                end
                local part = obj:IsA("BasePart") and obj or (obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")))
                if part and not table.find(list, part) then
                    list[#list + 1] = part
                end
            end
            local function trackRemove(obj)
                local list = tracked[obj.Name]
                if not list then
                    return
                end
                local part = obj:IsA("Model") and (obj.PrimaryPart or obj:FindFirstChildWhichIsA("BasePart")) or obj
                local index = part and table.find(list, part)
                if index then
                    table.remove(list, index)
                end
                breakableCache[obj] = nil
            end
            mod.Maid:Give(Workspace.DescendantAdded:Connect(trackAdd))
            mod.Maid:Give(Workspace.DescendantRemoving:Connect(trackRemove))
            -- Scan what's already there, a slice per frame so it doesn't hitch
            task.spawn(function()
                local stack = { Workspace }
                local budget = 0
                while #stack > 0 and alive do
                    local node = table.remove(stack)
                    local kids = node:GetChildren()
                    for i = 1, #kids do
                        stack[#stack + 1] = kids[i]
                        trackAdd(kids[i])
                    end
                    budget = budget + #kids
                    if budget >= 700 then
                        budget = 0
                        task.wait()
                    end
                end
            end)
            ensureParts(24)

            local function candidateLists()
                local lists = {}
                if cfg.Beds then
                    lists[#lists + 1] = beds
                    lists[#lists + 1] = tracked.bed
                    lists[#lists + 1] = taggedBeds
                end
                if cfg.Tesla then lists[#lists + 1] = tracked.tesla_trap end
                if cfg.Hive then lists[#lists + 1] = tracked.beehive end
                if cfg.LuckyBlocks then lists[#lists + 1] = luckyBlocks end
                if cfg.IronOre then lists[#lists + 1] = ironOre end
                if cfg.Snow then lists[#lists + 1] = tracked.snow_pile end
                if cfg.Pinata then lists[#lists + 1] = tracked.pinata end
                if cfg.Crops then
                    lists[#lists + 1] = tracked.carrot
                    lists[#lists + 1] = tracked.melon
                    lists[#lists + 1] = tracked.pumpkin
                end
                return lists
            end

            local rejects = {}   -- reason -> count, for the last target search
            local function invalidReason(block, origin)
                if not block or not block.Parent then
                    return "gone"
                end
                if (block:GetAttribute("BedShieldEndTime") or 0) > Workspace:GetServerTimeNow() then
                    return "bed shield up"
                end
                if nearestCellDistance(block, origin) >= cfg.Range then
                    return "out of range"
                end
                if not blockAllowed(block) then
                    return "protected (own team / NoBreak)"
                end
                -- The game's "breakable" flag is only trusted for picking a NEW target. A bed, or the
                -- target we are already digging at, is never dropped because of it.
                if block.Name ~= "bed" and not (plan and plan.target == block) and not isBreakable(block) then
                    return "game says not breakable"
                end
                return nil
            end

            local function valid(block, origin)
                return invalidReason(block, origin) == nil
            end

            local function pickTarget(origin)
                table.clear(rejects)
                if plan and plan.blatant and valid(plan.target, origin) then
                    return plan.target
                end
                local best, bestValue
                local byHealth = cfg.Mode ~= "Legit" and cfg.TargetMode == "Health"
                for _, list in ipairs(candidateLists()) do
                    for _, block in ipairs(list) do
                        local why = invalidReason(block, origin)
                        if why then
                            local key = tostring(block.Name) .. ": " .. why
                            rejects[key] = (rejects[key] or 0) + 1
                        else
                            local value
                            if byHealth then
                                value = block:GetAttribute("Health") or 0
                            else
                                value = nearestCellDistance(block, origin)
                            end
                            if not bestValue or value < bestValue then
                                best, bestValue = block, value
                            end
                        end
                    end
                end
                return best
            end

            -- The loop runs as numbered "generations". If it ever stalls (a call that never returns),
            -- the watchdog below starts a fresh one, so Nuker keeps going without toggling it.
            local generation, loopStamp = 0, os.clock()
            local function startLoop()
                generation = generation + 1
                local mine = generation
                loopStamp = os.clock()
                task.spawn(function()
                while alive and mod.Enabled and mine == generation do
                    task.wait(1 / math.max(tonumber(cfg.UpdateRate) or 60, 1))
                    if not (alive and mod.Enabled and mine == generation) then
                        break
                    end
                    loopStamp = os.clock()

                    if not (Bedwars.BlockController and Bedwars.DamageBlockRemotes) then
                        pcall(Bedwars.ResolveExtras)
                        setStatus(cfg.StatusLine ~= false, "waiting for the game's block system...")
                        continue
                    end

                    local _, _, root = Util.GetCharacter(LocalPlayer)
                    local blocked
                    if not root then
                        blocked = "waiting for character"
                    elseif cfg.RequireMouseDown and not Util.IsMouseDown(false) then
                        blocked = "hold left click"
                    elseif cfg.LimitToItems and not holdingBreakTool() then
                        blocked = "hold a tool that breaks blocks"
                    elseif LocalPlayer:GetAttribute("DenyBlockBreak") then
                        blocked = "can't break blocks right now"
                    end
                    if blocked then
                        clearVisuals()
                        setStatus(cfg.StatusLine ~= false, blocked)
                        continue
                    end

                    local ok, err = pcall(function()
                        local origin = root.Position
                        local target = pickTarget(origin)
                        if not target then
                            plan = nil
                            clearVisuals()
                            local why = {}
                            for reason, amount in pairs(rejects) do
                                why[#why + 1] = reason .. " x" .. amount
                            end
                            table.sort(why)
                            stats.LastIdle = #why > 0 and table.concat(why, ", ") or "no targets tracked"
                            setStatus(cfg.StatusLine ~= false, string.format("idle - %s (last reply: %s)", string.sub(stats.LastIdle, 1, 70), stats.Reply))
                            return
                        end
                        local cursorMode = cfg.Mode == "Legit"
                        local nearFirst = cursorMode or cfg.TargetMode == "Distance"
                        local blatant = not cursorMode and nearFirst and cfg.BreakType == "Blatant"
                        local stale = not plan or plan.target ~= target or plan.blatant ~= blatant
                        if not stale and not blatant and ((plan.anchor - origin).Magnitude > 3 or os.clock() - plan.time > 1) then
                            stale = true
                        end
                        local front, frontBlock
                        if not stale then
                            front, frontBlock = frontOf(plan)
                            stale = front == nil
                        end
                        if stale then
                            local route, _, diag = planRoute(target, {
                                origin = origin,
                                anchor = origin,
                                nearFirst = nearFirst,
                                angle = cfg.Angle,
                                range = cfg.Range,
                                filter = blockAllowed,
                            })
                            if not route then
                                plan = nil
                                clearVisuals()
                                -- Say *why* instead of just "no way in" - this is the only signal we get
                                -- back from a failed search without being able to watch it run live.
                                local why = "no breakable blocks found nearby"
                                if diag then
                                    local kinds = (diag.Sealed > 0 and 1 or 0) + (diag.Protected > 0 and 1 or 0)
                                        + (diag.Far > 0 and 1 or 0) + (diag.NoLOS > 0 and 1 or 0)
                                    if diag.NoLOS > 0 and kinds == 1 then
                                        why = string.format("found %d block(s) through the gap, but can't actually see/reach any of them from here - try a different angle", diag.NoLOS)
                                    elseif diag.Sealed > 0 and kinds == 1 then
                                        why = string.format("fully enclosed - %d breakable block(s) found, none touch open air", diag.Sealed)
                                    elseif diag.Protected > 0 and kinds == 1 then
                                        why = string.format("blocked - every nearby block is protected/no-break (%d)", diag.Protected)
                                    elseif diag.Far > 0 and kinds == 1 then
                                        why = string.format("out of Break Range (%d block(s) further than %d studs)", diag.Far, cfg.Range or 30)
                                    elseif diag.Seen > 0 then
                                        why = string.format("blocked - sealed %d, protected %d, out of range %d, no line of sight %d", diag.Sealed, diag.Protected, diag.Far, diag.NoLOS)
                                    end
                                end
                                setStatus(cfg.StatusLine ~= false, tostring(target.Name) .. ": no way in (" .. why .. ")")
                                return
                            end
                            plan = { target = target, route = route, anchor = origin, time = os.clock(), blatant = blatant }
                            front, frontBlock = frontOf(plan)
                            if not front then
                                plan = nil
                                clearVisuals()
                                return
                            end
                        end
                        if (front - origin).Magnitude > 30 then
                            plan = nil
                            clearVisuals()
                            return
                        end
                        drawRoute(plan.route, front)
                        if cursorMode then
                            local raw, hitPos = cursorBlock()
                            local aimed = (raw and (raw == frontBlock or raw:IsDescendantOf(frontBlock)))
                                or (hitPos and (hitPos - front).Magnitude <= 2.6)
                            if not aimed then
                                setHighlight(nil)
                                setStatus(cfg.StatusLine ~= false, "aim at the highlighted block")
                                return
                            end
                        end
                        setHighlight(frontBlock)
                        local gap = tonumber(cfg.BreakSpeed) or 0.25
                        if cfg.BedCheck and frontBlock == target and target.Name == "bed" then
                            gap = math.max(gap, 0.3)
                        end
                        if os.clock() - lastHit >= gap and holdingCorrectTool(cfg, frontBlock) then
                            lastHit = os.clock()
                            recentlyHit[target] = os.clock()
                            stats.LastIdle = nil
                            useKitAbilities(cfg)
                            task.spawn(function()
                                local hitOk, hitErr = pcall(hitCell, cfg, front, frontBlock, origin)
                                if not hitOk then
                                    stats.Reply = "hit error: " .. string.sub(tostring(hitErr), 1, 60)
                                end
                            end)
                        end
                        setStatus(cfg.StatusLine ~= false, string.format("%s %.0f studs - %s x%d (%s)",
                            tostring(frontBlock == target and "breaking" or "digging"), (target.Position - origin).Magnitude,
                            tostring(frontBlock.Name), stats.Sent, stats.Reply))
                    end)
                    if not ok then
                        plan = nil
                        table.clear(breakableCache)
                        setStatus(cfg.StatusLine ~= false, "error: " .. string.sub(tostring(err), 1, 80))
                    end
                end
                end)
            end
            startLoop()
            task.spawn(function()
                while alive and mod.Enabled do
                    task.wait(0.5)
                    if alive and mod.Enabled and os.clock() - loopStamp > 1.5 then
                        stats.Restarts = (stats.Restarts or 0) + 1
                        startLoop()
                    end
                end
            end)
        end,
    })

    nuker:AddSection("Mode")
    nuker:AddOption({
        Label = "Mode", Key = "Mode", Options = { "Normal", "Legit" }, Default = "Normal",
        Tip = "Normal digs to the block on its own. Legit only breaks what your cursor is on.",
    })
    nuker:AddOption({
        Label = "Target Mode", Key = "TargetMode", Options = { "Distance", "Health" }, Default = "Distance",
        ShowIf = function(c) return c.Mode ~= "Legit" end,
        Tip = "Distance digs in from the side closest to you. Health goes through the weakest blocks.",
    })
    nuker:AddOption({
        Label = "Break Type", Key = "BreakType", Options = { "Legit", "Blatant" }, Default = "Legit",
        ShowIf = function(c) return c.Mode ~= "Legit" and c.TargetMode == "Distance" end,
        Tip = "Legit re-picks the best path near you as you move. Blatant picks one and sticks to it.",
    })
    nuker:AddSection("Range & Speed")
    nuker:AddSlider({ Label = "Break Range", Key = "Range", Min = 1, Max = 45, Default = 30, Step = 1, Suffix = " studs", Tip = "How far away a block can be for you to hit it. Also caps how far the dig path can reach through a defense - raise this if a thick/distant defense says there's no way in." })
    nuker:AddSlider({ Label = "Break Angle", Key = "Angle", Min = 0, Max = 360, Default = 360, Step = 5, Suffix = "°", Tip = "Only dig through blocks inside this cone in front of your camera." })
    nuker:AddSlider({ Label = "Break Speed", Key = "BreakSpeed", Min = 0, Max = 0.3, Default = 0.25, Step = 0.01, Suffix = "s", Tip = "Wait between hits. Lower is faster." })
    nuker:AddSlider({ Label = "Update Rate", Key = "UpdateRate", Min = 1, Max = 120, Default = 60, Step = 1, Tip = "How often it checks for blocks." })
    nuker:AddSection("Targets")
    nuker:AddToggle({ Label = "Break Bed", Key = "Beds", Default = true })
    nuker:AddToggle({ Label = "Bed Check", Key = "BedCheck", Default = false, ShowIf = function(c) return c.Beds end, Tip = "Slows down to the normal speed once you're actually hitting the bed." })
    nuker:AddToggle({ Label = "Break Lucky Block", Key = "LuckyBlocks", Default = true })
    nuker:AddToggle({ Label = "Break Iron Ore", Key = "IronOre", Default = true })
    nuker:AddToggle({ Label = "Break Snow", Key = "Snow", Default = false })
    nuker:AddToggle({ Label = "Break Tesla", Key = "Tesla", Default = true })
    nuker:AddToggle({ Label = "Break Hive", Key = "Hive", Default = true })
    nuker:AddToggle({ Label = "Break Pinata", Key = "Pinata", Default = false })
    nuker:AddToggle({ Label = "Break Crops", Key = "Crops", Default = false, Tip = "Breaks Farmer Cletus crops (carrot and so on)." })
    nuker:AddToggle({ Label = "Self Break", Key = "SelfBreak", Default = false, Tip = "Also break your own bed and blocks you or your team placed." })
    nuker:AddSection("Behaviour")
    nuker:AddToggle({ Label = "Auto Tool", Key = "AutoTool", Default = true, Tip = "Swaps to the right tool while you're holding a tool. Off = it waits until you hold the right one." })
    nuker:AddToggle({ Label = "Limit to Items", Key = "LimitToItems", Default = false, Tip = "Only works while you hold something that can break blocks." })
    nuker:AddToggle({ Label = "Require Mouse Down", Key = "RequireMouseDown", Default = false, Tip = "Only digs while you hold left click." })
    nuker:AddToggle({ Label = "Yeti Breaker", Key = "YetiBreaker", Default = false, Tip = "Uses the Yeti roar while you're nuking." })
    nuker:AddToggle({ Label = "Ragnar", Key = "RagnarBreaker", Default = false, Tip = "Uses the Berserker rage while you're nuking." })
    nuker:AddSection("Visuals")
    nuker:AddToggle({ Label = "Show Healthbar & Effects", Key = "Effects", Default = true, Tip = "The game's own block health bar and break effects." })
    nuker:AddToggle({ Label = "Animation", Key = "Animation", Default = false, Tip = "Plays the swing animation while you dig." })
    nuker:AddToggle({ Label = "Show Path", Key = "ShowPath", Default = true, Tip = "Shows the blocks it's digging through." })
    nuker:AddToggle({ Label = "Block Highlight", Key = "Highlight", Default = true, Tip = "Box around the block being hit." })
    nuker:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })
    nuker:AddButton({ Label = "Run Self Check", Tip = "Tests every step Nuker needs and reports which one fails.", Callback = runDiagnostics })
    nuker:AddNote("Bedwars only. It never touches your own team's blocks unless Self Break is on.")
end

-- ====================== MODULE: CLOSET PACK ======================
-- Low-key helpers meant to look like normal play: Auto Clicker, Trigger Bot, Pickup Range, Scaffold
-- and Block In. Ported from aerov4 and rewritten against Nova's own Bedwars bridge. Nothing here
-- flies, teleports or changes your movement.
do
    local CollectionService = service("CollectionService")
    local ReplicatedStorage = service("ReplicatedStorage")
    local rng = Random.new()

    -- Shared helpers ---------------------------------------------------------------------------
    local function heldName()
        local char = LocalPlayer.Character
        local hand = char and char:FindFirstChild("HandInvItem")
        local item = hand and hand.Value
        return item and item.Name or nil
    end

    local function metaOf(name)
        return name and Bedwars.ItemMeta and Bedwars.ItemMeta[name] or nil
    end

    local function holdingSword()
        local item = Bedwars.GetHeldSword and Bedwars.GetHeldSword()
        return item ~= nil
    end

    local function uiBusy()
        if UserInputService:GetFocusedTextBox() then
            return true
        end
        local ok, open = pcall(function()
            local state = Bedwars.Store and Bedwars.Store:getState()
            return state and state.Inventory and state.Inventory.open
        end)
        return ok and open == true
    end

    local function pickBetween(low, high)
        low, high = tonumber(low) or 7, tonumber(high) or 7
        if high < low then
            low, high = high, low
        end
        if high - low < 0.01 then
            return low
        end
        return rng:NextNumber(low, high)
    end

    local function sameTeam(plr)
        local mine, theirs = LocalPlayer:GetAttribute("Team"), plr and plr:GetAttribute("Team")
        if mine ~= nil and theirs ~= nil then
            return mine == theirs
        end
        return plr ~= nil and Util.IsTeammate(plr)
    end

    local function worldBlockAt(position)
        local controller = Bedwars.BlockController
        if not controller then
            return nil
        end
        return controller:getStore():getBlockAt(controller:getBlockPosition(position))
    end

    local function snap(position)
        return Vector3.new(math.round(position.X / 3) * 3, math.round(position.Y / 3) * 3, math.round(position.Z / 3) * 3)
    end

    -- Block placing: the game's own BlockPlacer (same thing the client uses when you right-click)
    local placer, placerRetry = nil, 0
    local function getPlacer()
        if placer then
            return placer
        end
        if os.clock() < placerRetry then
            return nil
        end
        placerRetry = os.clock() + 2
        local ok, value = pcall(function()
            local engine = require(LocalPlayer.PlayerScripts.TS.lib["block-engine"]["client-block-engine"]).ClientBlockEngine
            local class = require(ReplicatedStorage.rbxts_include.node_modules["@easy-games"]["block-engine"].out.client.placement["block-placer"]).BlockPlacer
            return class.new(engine, "wool_white")
        end)
        if ok then
            placer = value
        end
        return placer
    end

    local function placeBlockAt(position, itemType)
        local active = getPlacer()
        if not (active and Bedwars.BlockController) then
            return false
        end
        active.blockType = itemType
        local ok, result = pcall(function()
            return active:placeBlock(Bedwars.BlockController:getBlockPosition(position))
        end)
        return ok and result
    end

    -- A block item to place with. `heldOnly` = only what you're already holding.
    local function pickBlockItem(heldOnly)
        local held = heldName()
        local heldMeta = metaOf(held)
        if heldMeta and heldMeta.block then
            return held
        end
        if heldOnly or holdingSword() then
            return nil
        end
        local inventory = Bedwars.GetInventory()
        local fallback
        for _, item in pairs(inventory and inventory.inventory.items or {}) do
            local meta = metaOf(item.itemType)
            if meta and meta.block and (item.amount or 0) > 0 then
                if string.find(item.itemType, "wool", 1, true) then
                    return item.itemType
                end
                fallback = fallback or item.itemType
            end
        end
        return fallback
    end

    -- Auto Clicker ----------------------------------------------------------------------------------
    local function placeAtMouse()
        local controller = Bedwars.Knit and Bedwars.Knit.Controllers.BlockPlacementController
        local blockPlacer = controller and controller.blockPlacer
        if not blockPlacer then
            return
        end
        local info = blockPlacer.clientManager:getBlockSelector():getMouseInfo(0)
        if info and info.placementPosition == info.placementPosition then
            task.spawn(blockPlacer.placeBlock, blockPlacer, info.placementPosition)
        end
    end

    local autoClicker = Tabs.Combat:CreateModule({
        Name = "Auto Clicker",
        Description = "Hold left click and it keeps swinging or placing at a steady, slightly random CPS.",
        OnEnable = function(mod)
            local cfg = mod.Config
            pcall(Bedwars.ResolveExtras)
            local pressedAt
            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    local wait = 0.03
                    local down = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
                    if down and not uiBusy() then
                        pressedAt = pressedAt or os.clock()
                        -- A normal quick click is left alone; it only takes over once you hold
                        if os.clock() - pressedAt >= 0.12 and Bedwars.Ready then
                            local meta = metaOf(heldName())
                            local cps
                            if meta and meta.block and cfg.PlaceBlocks then
                                pcall(placeAtMouse)
                                cps = pickBetween(cfg.BlockMin, cfg.BlockMax)
                            elseif cfg.SwingSwords and holdingSword() then
                                pcall(function()
                                    Bedwars.SwordController:swingSwordAtMouse(0.39)
                                end)
                                cps = pickBetween(cfg.MinCPS, cfg.MaxCPS)
                            end
                            if cps then
                                wait = 1 / math.max(cps, 1)
                            end
                        end
                    else
                        pressedAt = nil
                    end
                    task.wait(wait)
                end
            end))
        end,
    })
    autoClicker:AddSection("Sword")
    autoClicker:AddToggle({ Label = "Swing Swords", Key = "SwingSwords", Default = true })
    autoClicker:AddSlider({ Label = "Min CPS", Key = "MinCPS", Min = 1, Max = 12, Default = 7, Step = 0.5, ShowIf = function(c) return c.SwingSwords ~= false end })
    autoClicker:AddSlider({ Label = "Max CPS", Key = "MaxCPS", Min = 1, Max = 12, Default = 8, Step = 0.5, ShowIf = function(c) return c.SwingSwords ~= false end })
    autoClicker:AddSection("Blocks")
    autoClicker:AddToggle({ Label = "Place Blocks", Key = "PlaceBlocks", Default = true })
    autoClicker:AddSlider({ Label = "Block Min CPS", Key = "BlockMin", Min = 1, Max = 20, Default = 10, Step = 1, ShowIf = function(c) return c.PlaceBlocks ~= false end })
    autoClicker:AddSlider({ Label = "Block Max CPS", Key = "BlockMax", Min = 1, Max = 20, Default = 12, Step = 1, ShowIf = function(c) return c.PlaceBlocks ~= false end })
    autoClicker:AddNote("Bedwars only. Only starts after you hold the button for a moment, so normal clicks stay normal.")

    -- Trigger Bot ----------------------------------------------------------------------------------
    local triggerBot = Tabs.Combat:CreateModule({
        Name = "Trigger Bot",
        Description = "Swings your sword on its own when an enemy is in range and you're facing them.",
        OnEnable = function(mod)
            local cfg = mod.Config
            pcall(Bedwars.ResolveExtras)
            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    local swung = false
                    if Bedwars.Ready and not uiBusy() and holdingSword() then
                        local _, _, root = Util.GetCharacter(LocalPlayer)
                        local cam = Workspace.CurrentCamera
                        if root and cam then
                            local look = cam.CFrame.LookVector
                            local limit = math.cos(math.rad(math.clamp(tonumber(cfg.Angle) or 30, 5, 180)))
                            for _, entry in ipairs(Util.GetTargets(cfg.NPCs and "Players + NPCs" or "Players")) do
                                local offset = entry.Root.Position - root.Position
                                local distance = offset.Magnitude
                                if distance <= (cfg.Range or 12) and distance > 0.05
                                    and not (entry.Player and sameTeam(entry.Player))
                                    and look:Dot(offset.Unit) >= limit then
                                    pcall(function()
                                        Bedwars.SwordController:swingSwordAtMouse()
                                    end)
                                    swung = true
                                    break
                                end
                            end
                        end
                    end
                    task.wait(swung and 1 / math.max(pickBetween(cfg.MinCPS, cfg.MaxCPS), 1) or 0.05)
                end
            end))
        end,
    })
    triggerBot:AddSlider({ Label = "Range", Key = "Range", Min = 3, Max = 18, Default = 12, Step = 0.5, Suffix = " studs" })
    triggerBot:AddSlider({ Label = "Facing Angle", Key = "Angle", Min = 5, Max = 180, Default = 30, Step = 5, Suffix = "°", Tip = "How close to the middle of your screen they have to be." })
    triggerBot:AddSlider({ Label = "Min CPS", Key = "MinCPS", Min = 1, Max = 12, Default = 7, Step = 0.5 })
    triggerBot:AddSlider({ Label = "Max CPS", Key = "MaxCPS", Min = 1, Max = 12, Default = 8, Step = 0.5 })
    triggerBot:AddToggle({ Label = "Include NPCs", Key = "NPCs", Default = false })

    -- Pickup Range ---------------------------------------------------------------------------------
    local pickupRemote
    local function getPickupRemote()
        if pickupRemote and pickupRemote.Parent then
            return pickupRemote
        end
        local node = ReplicatedStorage
        for _, name in ipairs({ "rbxts_include", "node_modules", "@rbxts", "net", "out", "_NetManaged", "PickupItemDrop" }) do
            node = node and node:FindFirstChild(name)
        end
        pickupRemote = node
        return pickupRemote
    end

    local pickup = Tabs.Utility:CreateModule({
        Name = "Pickup Range",
        Description = "Picks up dropped items from farther away than normal.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local pending = setmetatable({}, { __mode = "k" })
            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    local _, hum, root = Util.GetCharacter(LocalPlayer)
                    local remote = getPickupRemote()
                    if root and hum and hum.Health > 0 and remote then
                        local range = cfg.Range or 10
                        local now = tick()
                        local drops = CollectionService:GetTagged("ItemDrop")
                        if #drops == 0 then
                            local cache = Workspace:FindFirstChild("ItemDropsCache")
                            drops = cache and cache:GetChildren() or {}
                        end
                        for _, drop in ipairs(drops) do
                            if drop:IsA("BasePart") and drop.Parent
                                and (not pending[drop] or pending[drop] < now)
                                and now - (drop:GetAttribute("ClientDropTime") or 0) >= 2
                                and (drop.Position - root.Position).Magnitude <= range
                                and not (cfg.FeetCheck and root.Position.Y - drop.Position.Y < hum.HipHeight - 1) then
                                pending[drop] = now + 0.5
                                task.spawn(function()
                                    local delay = (cfg.Delay or 0) / 1000
                                    if delay > 0 then
                                        task.wait(delay)
                                    end
                                    pcall(function()
                                        remote:InvokeServer({ itemDrop = drop })
                                    end)
                                end)
                            end
                        end
                    end
                    task.wait(0.1)
                end
            end))
        end,
    })
    pickup:AddSlider({ Label = "Range", Key = "Range", Min = 1, Max = 10, Default = 10, Step = 1, Suffix = " studs" })
    pickup:AddSlider({ Label = "Delay", Key = "Delay", Min = 0, Max = 500, Default = 0, Step = 10, Suffix = " ms" })
    pickup:AddToggle({ Label = "Feet Check", Key = "FeetCheck", Default = false, Tip = "Ignore items below your feet." })

    -- Scaffold ---------------------------------------------------------------------------------------
    local NEIGHBOURS = {}
    for x = -3, 3, 3 do
        for y = -3, 3, 3 do
            for z = -3, 3, 3 do
                if x ~= 0 or y ~= 0 or z ~= 0 then
                    NEIGHBOURS[#NEIGHBOURS + 1] = Vector3.new(x, y, z)
                end
            end
        end
    end
    local SIDES = { Vector3.new(3, 0, 0), Vector3.new(-3, 0, 0), Vector3.new(0, 0, 3), Vector3.new(0, 0, -3) }

    local function touchesBlock(position)
        for _, offset in ipairs(NEIGHBOURS) do
            if worldBlockAt(position + offset) then
                return true
            end
        end
        return false
    end

    local function supported(position)
        if worldBlockAt(position - Vector3.new(0, 3, 0)) then
            return true
        end
        for _, offset in ipairs(SIDES) do
            if worldBlockAt(position + offset) then
                return true
            end
        end
        return false
    end

    local function nearCorner(cell, position)
        local low, high = cell - Vector3.new(3, 3, 3), cell + Vector3.new(3, 3, 3)
        local away = position - cell
        if away.Magnitude < 0.001 then
            return position
        end
        local target = cell + away.Unit * 100
        return Vector3.new(math.clamp(target.X, low.X, high.X), math.clamp(target.Y, low.Y, high.Y), math.clamp(target.Z, low.Z, high.Z))
    end

    -- Nearest spot around `position` where a block could actually be attached
    local function closestAttachPoint(position)
        local controller = Bedwars.BlockController
        if not controller then
            return nil
        end
        local radius = Vector3.new(21, 21, 21)
        local from = controller:getBlockPosition(position - radius)
        local to = controller:getBlockPosition(position + radius)
        local store = controller:getStore()
        local best, bestDistance = nil, 60
        for x = from.X, to.X do
            for y = from.Y, to.Y do
                for z = from.Z, to.Z do
                    local cell = Vector3.new(x, y, z)
                    if store:getBlockAt(cell) then
                        local point = nearCorner(cell * 3, position)
                        local distance = (position - point).Magnitude
                        if distance < bestDistance and supported(point) then
                            best, bestDistance = point, distance
                        end
                    end
                end
            end
        end
        return best
    end

    local scaffold = Tabs.World:CreateModule({
        Name = "Scaffold",
        Description = "Places blocks under your feet as you walk, so you can bridge without stopping.",
        OnEnable = function(mod)
            local cfg = mod.Config
            pcall(Bedwars.ResolveExtras)
            local lastPlace, nextSearch = 0, 0
            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    local _, hum, root = Util.GetCharacter(LocalPlayer)
                    if Bedwars.Ready and root and hum and hum.Health > 0 and not uiBusy()
                        and not (cfg.RequireMouse and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)) then
                        local item = pickBlockItem(cfg.LimitToItems)
                        if item then
                            if cfg.Tower and UserInputService:IsKeyDown(Enum.KeyCode.Space) then
                                local v = root.AssemblyLinearVelocity
                                root.AssemblyLinearVelocity = Vector3.new(v.X, 38, v.Z)
                            end
                            local down = cfg.Downwards and UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
                            for step = math.floor(cfg.Expand or 1), 1, -1 do
                                local spot = snap(root.Position - Vector3.new(0, hum.HipHeight + (down and 4.5 or 1.5), 0) + hum.MoveDirection * (step * 3))
                                if not worldBlockAt(spot) and os.clock() - lastPlace >= (cfg.Delay or 0) / 1000 then
                                    local target
                                    if touchesBlock(spot) then
                                        target = spot
                                    elseif os.clock() >= nextSearch then
                                        target = closestAttachPoint(spot)
                                        if not target then
                                            nextSearch = os.clock() + 0.25   -- nothing to attach to, don't rescan every tick
                                        end
                                    end
                                    if target then
                                        task.spawn(placeBlockAt, target, item)
                                        lastPlace = os.clock()
                                    end
                                end
                            end
                        end
                    end
                    task.wait(0.03)
                end
            end))
        end,
    })
    scaffold:AddSlider({ Label = "Expand", Key = "Expand", Min = 1, Max = 6, Default = 1, Step = 1, Suffix = " blocks", Tip = "How many blocks ahead of you it places." })
    scaffold:AddSlider({ Label = "Place Delay", Key = "Delay", Min = 0, Max = 200, Default = 0, Step = 10, Suffix = " ms" })
    scaffold:AddToggle({ Label = "Downwards", Key = "Downwards", Default = true, Tip = "Hold shift to place lower." })
    scaffold:AddToggle({ Label = "Tower", Key = "Tower", Default = false, Tip = "Hold space to build straight up." })
    scaffold:AddToggle({ Label = "Limit to Items", Key = "LimitToItems", Default = true, Tip = "Only places while you are holding blocks." })
    scaffold:AddToggle({ Label = "Require Mouse Down", Key = "RequireMouse", Default = false })

    -- Block In ---------------------------------------------------------------------------------------
    local BLOCK_IN_CELLS = {
        Vector3.new(0, 0, 3), Vector3.new(0, 3, 3),
        Vector3.new(-3, 0, 0), Vector3.new(-3, 3, 0),
        Vector3.new(0, 0, -3), Vector3.new(0, 3, -3),
        Vector3.new(3, 0, 0), Vector3.new(3, 3, 0),
        Vector3.new(3, 6, 0), Vector3.new(0, 6, 0),
    }

    local blockIn
    blockIn = Tabs.World:CreateModule({
        Name = "Block In",
        Description = "One press: walls yourself in with the strongest blocks you have, then switches itself off.",
        OnEnable = function(mod)
            local cfg = mod.Config
            pcall(Bedwars.ResolveExtras)
            task.spawn(function()
                local _, hum, root = Util.GetCharacter(LocalPlayer)
                if not (Bedwars.Ready and root and hum and hum.Health > 0) then
                    Nova.Notify("Block In", "Not ready (need to be alive in a Bedwars match).", 3, "warn")
                elseif cfg.LimitToItems and not (metaOf(heldName()) and metaOf(heldName()).block) then
                    Nova.Notify("Block In", "Hold a block first.", 3, "warn")
                else
                    -- Strongest block first
                    local choices = {}
                    local held = heldName()
                    if cfg.LimitToItems then
                        choices[1] = { type = held, health = 0 }
                    else
                        local inventory = Bedwars.GetInventory()
                        for _, item in pairs(inventory and inventory.inventory.items or {}) do
                            local meta = metaOf(item.itemType)
                            if meta and meta.block and (item.amount or 0) > 0
                                and item.itemType ~= "tnt" and item.itemType ~= "siege_tnt" and item.itemType ~= "cannon" then
                                choices[#choices + 1] = { type = item.itemType, health = meta.block.health or 0 }
                            end
                        end
                        table.sort(choices, function(a, b)
                            return a.health > b.health
                        end)
                    end
                    if #choices == 0 then
                        Nova.Notify("Block In", "No blocks to use.", 3, "warn")
                    else
                        local base = Bedwars.BlockController:getBlockPosition(root.Position) * 3
                        for _ = 1, 3 do
                            for _, cell in ipairs(BLOCK_IN_CELLS) do
                                if not mod.Enabled then
                                    break
                                end
                                local spot = base + cell
                                if not worldBlockAt(spot) then
                                    for _, choice in ipairs(choices) do
                                        if placeBlockAt(spot, choice.type) then
                                            break
                                        end
                                    end
                                    local delay = cfg.PlaceSpeed or 0.07
                                    if delay > 0 then
                                        task.wait(delay)
                                    end
                                end
                            end
                            task.wait(0.08)
                        end
                    end
                end
                if mod.Enabled then
                    mod:SetEnabled(false, true)
                end
            end)
        end,
    })
    blockIn:AddSlider({ Label = "Place Speed", Key = "PlaceSpeed", Min = 0, Max = 0.5, Default = 0.07, Step = 0.01, Suffix = " s" })
    blockIn:AddToggle({ Label = "Limit to Items", Key = "LimitToItems", Default = false, Tip = "Only use the block you are holding." })
end

-- ====================== MODULE: STAFF DETECTOR ======================
-- Warns you (and can react) when a game moderator / known staff account is in your server.
do
    local StarterGui = service("StarterGui")

    local KNOWN_IDS = {}
    for _, id in ipairs({
        1502104539, 3826146717, 4531785383, 1049767300, 4926350670, 653085195,
        184655415, 2752307430, 5087196317, 5744061325, 1536265275,
    }) do
        KNOWN_IDS[id] = true
    end

    local KNOWN_NAMES = {}
    for _, name in ipairs({
        "chasemaser", "IllIlllIIIllllIIIll", "7SlyR", "DoordashRP", "OrionYeets", "lIllllllllllIllIIlll",
        "AUW345678", "the2ndtestaccount", "IllIIIIlllIlllIIIIIl", "IllIIIIlllIlllIlIIII", "ProSurferGamer1",
        "22willow_place", "celisnix", "G_TP56", "celisnix_3", "nwrkr", "lIIlIlIllllllIIlI", "IllIIIIIIlllllIIlIlI",
        "GorillaWithASuit", "liilliilliiiliill", "IllIllIllllIIIIIIlIl", "Typhoon_Kang", "VictoryForLife2468",
        "IlIIIlllllIIIIlIIIIl", "Erin_Ireland22", "IIIIllIIIIIIlllIlIII", "IIIIIlllIlllllIlII", "Ghostwxstaken",
        "wvwvwvwwvwvvwvw", "lllIIllIllIIllIllII", "TheAwkwardSponge", "TotallyKoaIa", "YT_GoraPlays",
        "LegendaryToragon", "appleapplelllllll", "Yo_johnny67", "llIIllIIllllIlIl", "PoopFarm_1",
        "llIIIllIIIIIllllIII", "Lemon01204", "HugeMudOtter", "AGameMasterHD", "krustykrab204", "kevinchuey",
        "IllIIIIlIllIlIIIlI", "YoZevStar", "pzlican", "Deevicus", "Blackprincess1", "yhpro1230", "eple_147",
        "whoisdv2_erin", "whoisdv4_erin", "whoisdv3_erin", "VicForLife14", "SleeplessSoulmate", "Jsquire07",
        "DVwastaken", "pxIican", "devzebu", "FunFamilyKids177", "Artan3333", "3MEWMTS5LJCB", "Zengoulen",
        "GloriousConfigB2", "heywasupsir", "c6chisa", "splashbird5372", "HolyItsSteven",
    }) do
        KNOWN_NAMES[name:lower()] = true
    end

    local BAD_CLANS = { gg = true, gg2 = true, dv = true, dv2 = true, nwr = true }

    local detector
    local detected = {}     -- userId -> { Name, Kind }
    local handled = {}      -- userId -> true while a player is being checked

    local function extraEntries()
        local ids, names = {}, {}
        local text = detector and detector.Config.ExtraUsers or ""
        for token in tostring(text):gmatch("[^,%s;]+") do
            local number = tonumber(token)
            if number then
                ids[number] = true
            else
                names[token:lower()] = true
            end
        end
        return ids, names
    end

    local function groupRank(plr, groupId)
        local ok, rank
        for _ = 1, 3 do
            ok, rank = pcall(function()
                return plr:GetRankInGroup(groupId)
            end)
            if ok then
                break
            end
            task.wait(0.5)
        end
        return ok and rank or 0
    end

    local function runAction(mod, plr, kind)
        local mode = mod.Config.Mode
        if mode == "Disable Modules" then
            for _, other in ipairs(Nova.ModuleList) do
                if other ~= mod and other.Enabled then
                    pcall(other.SetEnabled, other, false, true)
                end
            end
            Nova.Wanted = {}
            pcall(Nova.AutoSave)
            Nova.Notify("Staff Detector", "Everything else was switched off.", 6, "warn", true)
        elseif mode == "Unload" then
            pcall(function()
                StarterGui:SetCore("SendNotification", {
                    Title = "Staff Detector",
                    Text = "Staff detected (" .. kind .. "): " .. plr.Name,
                    Duration = 15,
                })
            end)
            task.spawn(function()
                -- switch everything off and save that, so nothing comes back on by itself next time
                for _, other in ipairs(Nova.ModuleList) do
                    if other.Enabled then
                        pcall(other.SetEnabled, other, false, true)
                    end
                end
                Nova.Wanted = {}
                pcall(Nova.AutoSave)
                pcall(Nova.Unload, false)
            end)
        end
    end

    local function flagStaff(mod, plr, kind)
        if detected[plr.UserId] or not mod.Enabled then
            return
        end
        detected[plr.UserId] = { Name = plr.Name, Kind = kind }
        Nova.Notify("Staff detected", string.format("%s (%d) - %s", plr.Name, plr.UserId, kind),
            mod.Config.AlertDuration, "error", true)
        runAction(mod, plr, kind)
    end

    local function flagSoft(mod, plr, kind, text)
        if detected[plr.UserId] or not mod.Enabled then
            return
        end
        detected[plr.UserId] = { Name = plr.Name, Kind = kind }
        Nova.Notify("Staff Detector", text, mod.Config.AlertDuration, "warn", true)
    end

    -- A player with no team who is "spectating" cannot join a normal match, which usually means staff.
    -- Spectators who are friends with someone in the server are treated as harmless.
    local function checkSpectator(mod, plr)
        if plr:GetAttribute("Team") or not plr:GetAttribute("Spectator") then
            return false
        end
        local checked, failed, friend = 0, 0, false
        for _, other in ipairs(Players:GetPlayers()) do
            if other ~= plr then
                checked = checked + 1
                local ok, result = pcall(function()
                    return plr:IsFriendsWith(other.UserId)
                end)
                if not ok then
                    failed = failed + 1
                elseif result then
                    friend = true
                    break
                end
            end
        end
        if friend then
            flagSoft(mod, plr, "spectator",
                string.format("Spectator: %s (%d) has a friend in this server.", plr.Name, plr.UserId))
        elseif failed > 0 or checked == 0 then
            flagSoft(mod, plr, "unverified",
                string.format("Couldn't check %s's friends (%d/%d failed). Could be staff.", plr.Name, failed, checked))
        else
            flagStaff(mod, plr, "impossible join (spectator with no friends here)")
        end
        return true
    end

    local function checkPlayer(mod, plr)
        if plr == LocalPlayer or handled[plr.UserId] or detected[plr.UserId] then
            return
        end
        handled[plr.UserId] = true
        local cfg = mod.Config

        local extraIds, extraNames = extraEntries()
        if KNOWN_IDS[plr.UserId] or extraIds[plr.UserId] then
            flagStaff(mod, plr, "listed account")
            handled[plr.UserId] = nil
            return
        end
        if KNOWN_NAMES[plr.Name:lower()] or extraNames[plr.Name:lower()] then
            flagStaff(mod, plr, "known staff name")
            handled[plr.UserId] = nil
            return
        end

        local groupId, minRank = tonumber(cfg.GroupId), tonumber(cfg.MinRank)
        if groupId and minRank then
            local rank = groupRank(plr, groupId)
            if rank >= minRank then
                flagStaff(mod, plr, "group rank " .. tostring(rank))
                handled[plr.UserId] = nil
                return
            end
        end

        if cfg.SpectatorCheck then
            local connection
            connection = plr:GetAttributeChangedSignal("Spectator"):Connect(function()
                if checkSpectator(mod, plr) then
                    connection:Disconnect()
                end
            end)
            mod.Maid:Give(connection)
            if checkSpectator(mod, plr) then
                handled[plr.UserId] = nil
                return
            end
        end

        if cfg.Clans then
            local function checkClan()
                local tag = plr:GetAttribute("ClanTag")
                if type(tag) == "string" and BAD_CLANS[tag:lower()] then
                    flagStaff(mod, plr, "clan tag " .. tag)
                end
            end
            if plr:GetAttribute("ClanTag") then
                checkClan()
            else
                local clanConnection
                clanConnection = plr:GetAttributeChangedSignal("ClanTag"):Connect(function()
                    clanConnection:Disconnect()
                    checkClan()
                end)
                mod.Maid:Give(clanConnection)
                task.delay(5, function()
                    pcall(function()
                        clanConnection:Disconnect()
                    end)
                end)
            end
        end
        handled[plr.UserId] = nil
    end

    detector = Tabs.Utility:CreateModule({
        Name = "Staff Detector",
        Description = "Warns you when a moderator or known staff account is in the server.",
        OnEnable = function(mod)
            detected, handled = {}, {}

            mod.Maid:Give(Players.PlayerAdded:Connect(function(plr)
                task.spawn(checkPlayer, mod, plr)
            end))
            mod.Maid:Give(Players.PlayerRemoving:Connect(function(plr)
                handled[plr.UserId] = nil
                local entry = detected[plr.UserId]
                if entry then
                    detected[plr.UserId] = nil
                    Nova.Notify("Staff Detector", entry.Name .. " (" .. entry.Kind .. ") left the server.",
                        mod.Config.AlertDuration, "info", true)
                end
            end))
            for _, plr in ipairs(Players:GetPlayers()) do
                task.spawn(checkPlayer, mod, plr)
            end
            mod.Maid:Give(function()
                detected, handled = {}, {}
            end)
        end,
    })

    detector:AddSection("When staff shows up")
    detector:AddOption({
        Label = "Action", Key = "Mode", Options = { "Notify", "Disable Modules", "Unload" }, Default = "Notify",
        Tip = "Notify only warns you. Disable Modules switches every other Nova module off. Unload removes Nova completely.",
    })
    detector:AddSlider({ Label = "Alert Duration", Key = "AlertDuration", Min = 5, Max = 120, Default = 60, Step = 5, Suffix = "s", Tip = "How long each warning stays on screen." })
    detector:AddSection("What to check")
    detector:AddToggle({ Label = "Spectator Check", Key = "SpectatorCheck", Default = true, Tip = "Flags players who 'spectate' with no team and no friends in the server." })
    detector:AddToggle({ Label = "Blacklisted Clans", Key = "Clans", Default = true, Tip = "Flags players wearing a clan tag used by game staff." })
    detector:AddTextBox({ Label = "Extra Users", Key = "ExtraUsers", Default = "", Placeholder = "names or user ids, comma separated" })
    detector:AddTextBox({ Label = "Group ID", Key = "GroupId", Default = "", Placeholder = "optional" })
    detector:AddTextBox({ Label = "Min Group Rank", Key = "MinRank", Default = "", Placeholder = "flag this rank and above" })
    detector:AddButton({
        Label = "Show Who Was Detected",
        Callback = function()
            local lines = {}
            for _, entry in pairs(detected) do
                lines[#lines + 1] = entry.Name .. " (" .. entry.Kind .. ")"
            end
            Nova.Notify("Staff Detector",
                #lines > 0 and table.concat(lines, "\n") or (detector.Enabled and "Nobody flagged so far." or "Turn the module on first."),
                6, "info", true)
        end,
    })
    detector:AddNote("Works in any game for the lists and group rank. The spectator and clan checks are meant for Bedwars.")
end

-- ====================== MODULE: AUTO KIT ======================
-- Uses the kit you picked for you: picks up kit items, fires kit abilities and so on.
-- Every kit runs in its own loop and only while it is the kit you are playing.
do
    local CollectionService = service("CollectionService")
    local ReplicatedStorage = service("ReplicatedStorage")

    local autokit

    -- Small helpers ---------------------------------------------------------------------------
    local function legit()
        return autokit and autokit.Config.Legit ~= false
    end

    local function R(legitRange, wideRange)
        return legit() and legitRange or wideRange
    end

    local function partOf(inst)
        if typeof(inst) ~= "Instance" then
            return nil
        end
        if inst:IsA("BasePart") then
            return inst
        end
        local found
        pcall(function()
            found = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
        end)
        return found
    end

    local function myRoot()
        local _, _, root = Util.GetCharacter(LocalPlayer)
        return root
    end

    local function isEnemyPlayer(plr)
        if plr == LocalPlayer then
            return false
        end
        local mine, theirs = LocalPlayer:GetAttribute("Team"), plr:GetAttribute("Team")
        if mine ~= nil and theirs ~= nil then
            return mine ~= theirs
        end
        return not Util.IsTeammate(plr)
    end

    -- Nearest living enemy player within `distance` of `origin` (default: you)
    local function nearestEnemy(distance, origin)
        origin = origin or (myRoot() and myRoot().Position)
        if not origin then
            return nil
        end
        local best, bestDistance
        for _, plr in ipairs(Players:GetPlayers()) do
            if isEnemyPlayer(plr) then
                local char, hum, root = Util.GetCharacter(plr)
                if char and hum.Health > 0 then
                    local d = (root.Position - origin).Magnitude
                    if d <= distance and (not bestDistance or d < bestDistance) then
                        best, bestDistance = { Player = plr, Character = char, Root = root, Distance = d }, d
                    end
                end
            end
        end
        return best
    end

    local function holding(keywords)
        return Util.MatchesHeld(keywords)
    end

    local function hasItem(itemType)
        local inventory = Bedwars.GetInventory()
        if not inventory then
            return false
        end
        for _, slot in pairs(inventory.inventory.items or {}) do
            if type(slot) == "table" and slot.itemType == itemType then
                return true
            end
        end
        return false
    end

    -- Sessions: one per kit, so switching kit or turning a kit off stops only that loop -------
    local function newSession()
        local session = { Active = true, Tasks = {} }
        function session:Clean(task_)
            self.Tasks[#self.Tasks + 1] = task_
            return task_
        end
        function session:Stop()
            self.Active = false
            if self.Thread then
                pcall(task.cancel, self.Thread)
            end
            for index = #self.Tasks, 1, -1 do
                local item = self.Tasks[index]
                pcall(function()
                    if type(item) == "function" then
                        item()
                    elseif typeof(item) == "RBXScriptConnection" then
                        item:Disconnect()
                    elseif typeof(item) == "Instance" then
                        item:Destroy()
                    end
                end)
            end
            self.Tasks = {}
        end
        return session
    end

    -- Remotes ---------------------------------------------------------------------------------
    -- Some remote names are scrambled and change between updates, so they are read out of the
    -- game's own controller code. Names that aren't scrambled are looked up directly.
    local netFolder
    local function getNetFolder()
        if netFolder and netFolder.Parent then
            return netFolder
        end
        netFolder = nil
        pcall(function()
            netFolder = ReplicatedStorage.rbxts_include.node_modules["@rbxts"].net.out._NetManaged
        end)
        return netFolder
    end

    local function constantAfterClient(fn)
        if type(fn) ~= "function" or not (debug and debug.getconstants) then
            return nil
        end
        local ok, constants = pcall(debug.getconstants, fn)
        if not ok or type(constants) ~= "table" then
            return nil
        end
        for index, value in pairs(constants) do
            if value == "Client" then
                local name = constants[index + 1]
                if type(name) == "string" and name ~= "" then
                    return name
                end
            end
        end
        return nil
    end

    local function proto(fn, index)
        return debug.getproto(fn, index)
    end

    -- key -> function(Controllers) returning the function whose code mentions the remote
    local DUMP = {
        BeePickup = function(C) return C.BeeNetController.trigger end,
        ConsumeTreeOrb = function(C) return proto(C.EldertreeController.createTreeOrbInteraction, 1) end,
        HarvestCrop = function(C) return proto(proto(C.CropController.KnitStart, 4), 1) end,
        PickupMetal = function(C) return proto(C.HiddenMetalController.onKitLocalActivated, 4) end,
        DepositPinata = function(C) return proto(proto(C.PiggyBankController.KnitStart, 2), 5) end,
        ConsumeSoul = function(C) return C.GrimReaperController.consumeSoul end,
        ConsumeBattery = function(C) return proto(C.BatteryController.onKitLocalActivated, 1) end,
        SummonerClawAttack = function(C) return C.SummonerClawHandController.attack end,
        WarlockTarget = function(C) return proto(C.WarlockStaffController.KnitStart, 2) end,
        DragonBreath = function(C) return proto(C.VoidDragonController.onKitLocalActivated, 5) end,
        GuitarHeal = function(C) return C.GuitarController.performHeal end,
    }

    -- key -> remote name when it isn't scrambled (or when reading it out of the code fails)
    local PLAIN = {
        BeePickup = "BeePickup",
        ActivateGravestone = "ActivateGravestone",
        CollectCollectableEntity = "CollectCollectableEntity",
        HannahPromptTrigger = "HannahPromptTrigger",
        DragonBreath = "DragonBreath",
        LearnElementTome = "LearnElementTome",
        MimicPickPocket = "MimicBlockPickPocketPlayer",
        DestroyPetrifiedPlayer = "DestroyPetrifiedPlayer",
        SoulLink = "AttemptSoulLink",
        DragonSwordFire = "DragonSwordFire",
        GunBladeFire = "HandGunFireRequest",
    }

    local remoteCache, remoteMissAt = {}, {}
    local function remote(key)
        local cached = remoteCache[key]
        if cached and cached.Parent then
            return cached
        end
        if remoteMissAt[key] and os.clock() - remoteMissAt[key] < 5 then
            return nil
        end
        local folder = getNetFolder()
        if not folder then
            return nil
        end
        local names = {}
        if DUMP[key] and Bedwars.Knit then
            local ok, fn = pcall(DUMP[key], Bedwars.Knit.Controllers)
            local dumped = ok and constantAfterClient(fn)
            if dumped then
                names[#names + 1] = dumped
            end
        end
        names[#names + 1] = PLAIN[key] or key
        for _, name in ipairs(names) do
            local inst = folder:FindFirstChild(name)
            if inst then
                remoteCache[key] = inst
                return inst
            end
        end
        remoteMissAt[key] = os.clock()
        return nil
    end

    -- Fires an event or calls a function remote. Returns the reply for functions.
    local function send(key, ...)
        local inst = remote(key)
        if not inst then
            return nil
        end
        local args = table.pack(...)
        if inst:IsA("RemoteFunction") then
            local ok, result = pcall(function()
                return inst:InvokeServer(table.unpack(args, 1, args.n))
            end)
            return ok and result or nil
        end
        local ok = pcall(function()
            inst:FireServer(table.unpack(args, 1, args.n))
        end)
        return ok
    end

    local abilityRemote
    local abilityAt = {}
    local function useAbility(name, data, gap)
        if os.clock() - (abilityAt[name] or 0) < (gap or 0.5) then
            return false
        end
        if not (abilityRemote and abilityRemote.Parent) then
            abilityRemote = nil
            pcall(function()
                abilityRemote = ReplicatedStorage["events-@easy-games/game-core:shared/game-core-networking@getEvents.Events"].useAbility
            end)
        end
        if not abilityRemote then
            return false
        end
        abilityAt[name] = os.clock()
        pcall(function()
            if data ~= nil then
                abilityRemote:FireServer(name, data)
            else
                abilityRemote:FireServer(name)
            end
        end)
        return true
    end

    local function controller(name)
        local ok, found = pcall(function()
            return Bedwars.Knit.Controllers[name]
        end)
        return ok and found or nil
    end

    -- Runs `step` every `interval` seconds until the session stops
    local function loop(session, interval, step)
        while session.Active do
            if myRoot() then
                pcall(step)
            end
            task.wait(interval)
        end
    end

    -- Runs `callback(instance, part)` for every tagged thing within range()
    local function eachTagged(session, tag, rangeFn, callback, interval)
        loop(session, interval or 0.1, function()
            local here = myRoot().Position
            for _, inst in ipairs(CollectionService:GetTagged(tag)) do
                if not session.Active then
                    break
                end
                local part = partOf(inst)
                if part and part.Parent and (part.Position - here).Magnitude <= rangeFn() then
                    pcall(callback, inst, part)
                end
            end
        end)
    end

    local function attr(inst, ...)
        for _, name in ipairs({ ... }) do
            local value = inst:GetAttribute(name)
            if value ~= nil then
                return value
            end
        end
        return nil
    end

    -- Kits --------------------------------------------------------------------------------------
    local KITS = {}
    local function kit(id, group, tip, run)
        KITS[#KITS + 1] = { Id = id, Group = group, Tip = tip, Run = run }
    end

    local PICKUP, ATTACK, SUPPORT = "Pick things up", "Attack and abilities", "Support and utility"

    -- Pick things up
    kit("beekeeper", PICKUP, "Collects bees near you.", function(s)
        eachTagged(s, "bee", function() return 18 end, function(bee)
            send("BeePickup", { beeId = bee:GetAttribute("BeeId") })
        end)
    end)

    kit("bigman", PICKUP, "Eats tree orbs near you.", function(s)
        eachTagged(s, "treeOrb", function() return 12 end, function(orb)
            if send("ConsumeTreeOrb", { treeOrbSecret = orb:GetAttribute("TreeOrbSecret") }) then
                orb:Destroy()
            end
        end)
    end)

    kit("farmer_cletus", PICKUP, "Harvests grown crops near you.", function(s)
        eachTagged(s, "HarvestableCrop", function() return 10 end, function(_, part)
            if Bedwars.BlockController then
                send("HarvestCrop", { position = Bedwars.BlockController:getBlockPosition(part.Position) })
            end
        end)
    end)

    kit("metal_detector", PICKUP, "Digs up hidden metal near you.", function(s)
        eachTagged(s, "hidden-metal", function() return 20 end, function(metal)
            send("PickupMetal", { id = metal:GetAttribute("Id") })
        end)
    end)

    kit("miner", PICKUP, "Frees petrified players near you. Legit: 6 studs, otherwise 10.", function(s)
        eachTagged(s, "petrified-player", function() return R(6, 10) end, function(rock)
            local id = attr(rock, "PetrifyId", "petrifyId")
            if id then
                send("DestroyPetrifiedPlayer", { petrifyId = id })
            end
        end)
    end)

    kit("pinata", PICKUP, "Hands candy to your pinata when you are next to it.", function(s)
        eachTagged(s, LocalPlayer.Name .. ":pinata", function() return 6 end, function(pinata)
            if hasItem("candy") then
                send("DepositPinata", pinata)
            end
        end)
    end)

    kit("sorcerer", PICKUP, "Collects alchemy crystals near you.", function(s)
        eachTagged(s, "alchemy_crystal", function() return 10 end, function(crystal)
            local id = attr(crystal, "Id", "id", "CollectableId") or tonumber(crystal.Name:match("%d+"))
            if id then
                send("CollectCollectableEntity", { id = id, collectableName = "AlchemyCrystal" })
                task.wait(0.1)
            end
        end)
    end)

    kit("ghost_catcher", PICKUP, "Catches ghosts. Legit: only with the vacuum out and within 14 studs.", function(s)
        eachTagged(s, "ghost", function() return R(14, 30) end, function(ghost)
            if legit() and not holding("vacuum") then
                return
            end
            local id = attr(ghost, "Id", "id", "CollectableId") or tonumber(ghost.Name:match("%d+"))
            if id then
                send("CollectCollectableEntity", { id = id })
                task.wait(0.1)
            end
        end)
    end)

    kit("necromancer", PICKUP, "Raises gravestones near you. Legit: 12 studs, otherwise 40.", function(s)
        eachTagged(s, "Gravestone", function() return R(12, 40) end, function(grave)
            local secret = grave:GetAttribute("GravestoneSecret")
            if not secret then
                return
            end
            local result = send("ActivateGravestone", {
                skeletonData = {
                    armorType = grave:GetAttribute("ArmorType"),
                    weaponType = grave:GetAttribute("SwordType"),
                    associatedPlayerUserId = grave:GetAttribute("GravestonePlayerUserId"),
                },
                secret = secret,
                position = grave:GetAttribute("GravestonePosition"),
            })
            if type(result) == "table" and result.success then
                local necro = controller("NecromancerController")
                if necro then
                    pcall(function() necro:useGravestone(LocalPlayer, grave) end)
                end
            end
            task.wait(0.1)
        end)
    end)

    kit("mage", PICKUP, "Learns element tomes. Legit: 14 studs, otherwise 30.", function(s)
        eachTagged(s, "ElementTome", function() return R(14, 30) end, function(tome)
            local secret = tome:GetAttribute("TomeSecret")
            if not secret then
                return
            end
            local result = send("LearnElementTome", { secret = secret })
            if type(result) == "table" and result.success then
                tome:Destroy()
                task.wait(0.5)
            end
        end)
    end)

    kit("jailor", PICKUP, "Grabs souls near you. Legit: 14 studs, otherwise 40.", function(s)
        eachTagged(s, "jailor_soul", function() return R(14, 40) end, function(soul)
            local jailor = controller("JailorController")
            if jailor then
                jailor:collectEntity(LocalPlayer, soul, "JailorSoul")
                task.wait(0.1)
            end
        end)
    end)

    kit("star_collector", PICKUP, "Collects stars near you.", function(s)
        eachTagged(s, "stars", function() return 20 end, function(star)
            local collector = controller("StarCollectorController")
            if collector then
                collector:collectEntity(LocalPlayer, star, star.Name)
            end
        end)
    end)

    kit("spirit_assassin", PICKUP, "Uses spirits. Legit: 14 studs, otherwise 150.", function(s)
        eachTagged(s, "EvelynnSoul", function() return R(14, 150) end, function(spirit)
            local assassin = controller("SpiritAssassinController")
            if assassin then
                assassin:useSpirit(LocalPlayer, spirit)
                task.wait(0.1)
            end
        end)
    end)

    kit("hannah", PICKUP, "Executes low-health players. Legit: 14 studs, otherwise 16.", function(s)
        eachTagged(s, "HannahExecuteInteraction", function() return R(14, 16) end, function(victim)
            if send("HannahPromptTrigger", { user = LocalPlayer, victimEntity = victim }) then
                local icon = victim:FindFirstChild("Hannah Execution Icon")
                if icon then
                    icon:Destroy()
                end
            end
            task.wait(0.05)
        end)
    end)

    kit("grim_reaper", PICKUP, "Eats souls when your health is low. Legit: 14 studs, otherwise 150.", function(s)
        loop(s, 0.1, function()
            local reaper = controller("GrimReaperController")
            local char = LocalPlayer.Character
            local health, maxHealth = char and char:GetAttribute("Health"), char and char:GetAttribute("MaxHealth")
            if not (reaper and reaper.soulsByPosition and health and maxHealth)
                or health > maxHealth / 4 or char:GetAttribute("GrimReaperChannel") then
                return
            end
            local here = myRoot().Position
            for _, soul in pairs(reaper.soulsByPosition) do
                if not s.Active then
                    break
                end
                local part = partOf(soul)
                local secret = part and soul:GetAttribute("GrimReaperSoulSecret")
                if secret and (part.Position - here).Magnitude <= R(14, 150) then
                    send("ConsumeSoul", { secret = secret })
                    task.wait(0.1)
                end
            end
        end)
    end)

    kit("battery", PICKUP, "Takes charge from batteries within 10 studs.", function(s)
        loop(s, 0.1, function()
            local batteries = controller("BatteryEffectsController")
            if not (batteries and batteries.liveBatteries) then
                return
            end
            local here = myRoot().Position
            for id, battery in pairs(batteries.liveBatteries) do
                if (battery.position - here).Magnitude <= 10 then
                    local info = batteries:getBatteryInfo(id)
                    local now = Workspace:GetServerTimeNow()
                    if info and info.activateTime < now and info.consumeTime + 0.1 < now then
                        info.consumeTime = now
                        send("ConsumeBattery", { batteryId = id })
                    end
                end
            end
        end)
    end)

    -- Attack and abilities
    kit("warrior", ATTACK, "Strikes once your grit is full and an enemy is close. Legit: 14 studs, otherwise 40.", function(s)
        loop(s, 0.1, function()
            if (LocalPlayer:GetAttribute("Grit") or 0) >= 100 and nearestEnemy(R(14, 40)) then
                useAbility("warrior_strike")
            end
        end)
    end)

    kit("cactus", ATTACK, "Shoots when an enemy is close. Legit: 14 studs, otherwise 40.", function(s)
        loop(s, 0.1, function()
            if nearestEnemy(R(14, 40)) then
                useAbility("cactus_fire", nil, 1)
            end
        end)
    end)

    kit("card", ATTACK, "Throws a card at the nearest enemy within 12 studs.", function(s)
        loop(s, 0.1, function()
            local enemy = nearestEnemy(12)
            if enemy then
                useAbility("CARD_THROW", { targetEntityInstance = enemy.Character }, 0.5)
            end
        end)
    end)

    kit("midnight", ATTACK, "Uses Nyx when an enemy is close. Legit: 14 studs, otherwise 40.", function(s)
        loop(s, 0.1, function()
            if nearestEnemy(R(14, 40)) then
                useAbility("midnight", nil, 1)
            end
        end)
    end)

    kit("ice_queen", ATTACK, "Freezes enemies who have four stacks. Legit: 14 studs, otherwise 60.", function(s)
        loop(s, 0.1, function()
            local here = myRoot().Position
            for _, plr in ipairs(Players:GetPlayers()) do
                if isEnemyPlayer(plr) then
                    local char, hum, root = Util.GetCharacter(plr)
                    if char and hum.Health > 0 and (root.Position - here).Magnitude <= R(14, 60)
                        and (char:GetAttribute("IceQueenStacks") or 0) >= 4 then
                        useAbility("ice_queen", nil, 0.5)
                        break
                    end
                end
            end
        end)
    end)

    kit("jellyfish", ATTACK, "Shocks enemies near your jellyfish. Legit: 14 studs, otherwise 18.", function(s)
        loop(s, 0.1, function()
            for _, jelly in ipairs(CollectionService:GetTagged("jellyfish")) do
                local part = partOf(jelly)
                if part and jelly:GetAttribute("PlacedByUserId") == LocalPlayer.UserId
                    and nearestEnemy(R(14, 18), part.Position) then
                    useAbility("electrify_jellyfish", nil, 1)
                    break
                end
            end
        end)
    end)

    kit("dragon_sword", ATTACK, "Fires at enemies. Legit: 14 studs, otherwise 18.", function(s)
        loop(s, 0.1, function()
            local enemy = nearestEnemy(R(14, 18))
            if enemy and send("DragonSwordFire", { target = enemy.Character }) ~= nil then
                task.wait(0.5)
            end
        end)
    end)

    kit("gun_blade", ATTACK, "Shoots enemies. Legit: 10 studs, otherwise 40.", function(s)
        loop(s, 0.1, function()
            local enemy = nearestEnemy(R(10, 40))
            if enemy then
                local direction = (enemy.Root.Position - myRoot().Position).Unit
                send("GunBladeFire", { lookVector = direction })
                useAbility("hand_gun", nil, 0.2)
            end
        end)
    end)

    kit("soul_broker", ATTACK, "Links souls with nearby enemies. Legit: 14 studs, otherwise 60.", function(s)
        local linked, count = {}, 0
        loop(s, 0.3, function()
            local enemy = nearestEnemy(R(14, 60))
            if enemy and count < 8 and not linked[enemy.Character] then
                useAbility("soul_link", nil, 0.2)
                task.wait(0.1)
                local result = send("SoulLink", enemy.Character)
                if type(result) == "table" and result.result then
                    linked[enemy.Character] = true
                    count = count + 1
                    s:Clean(enemy.Character.AncestryChanged:Connect(function()
                        if not enemy.Character.Parent and linked[enemy.Character] then
                            linked[enemy.Character] = nil
                            count = count - 1
                        end
                    end))
                end
            end
        end)
    end)

    kit("warlock", ATTACK, "Links the staff to an enemy while you hold it. Legit: 10 studs, otherwise 20.", function(s)
        local last
        loop(s, 0.3, function()
            if not holding("warlock_staff") then
                last = nil
                return
            end
            local reach = R(10, 20)
            if last then
                local hum = last:FindFirstChildOfClass("Humanoid")
                local root = last:FindFirstChild("HumanoidRootPart")
                if not last.Parent or not hum or hum.Health <= 0 or not root
                    or (root.Position - myRoot().Position).Magnitude > reach then
                    last = nil
                end
            end
            if not last then
                local enemy = nearestEnemy(reach)
                if enemy then
                    last = enemy.Character
                    useAbility("WARLOCK_LINK", nil, 0.2)
                    task.wait(0.1)
                    send("WarlockTarget", { target = last })
                end
            end
        end)
    end)

    kit("summoner", ATTACK, "Sends the claw at the nearest enemy within 31 studs.", function(s)
        loop(s, 0.1, function()
            local enemy = nearestEnemy(31)
            if enemy then
                local here = myRoot().Position
                local direction = (enemy.Root.Position - here).Unit
                here = here + direction * math.max((here - enemy.Root.Position).Magnitude - 16, 0)
                send("SummonerClawAttack", {
                    position = here,
                    direction = direction,
                    clientTime = Workspace:GetServerTimeNow(),
                })
            end
        end)
    end)

    kit("void_dragon", ATTACK, "Breathes on enemies while you are in dragon form. Legit: 14 studs, otherwise 60.", function(s)
        loop(s, 0.1, function()
            local dragon = controller("VoidDragonController")
            if dragon and dragon.inDragonForm then
                local enemy = nearestEnemy(R(14, 60))
                if enemy then
                    send("DragonBreath", { player = LocalPlayer, targetPoint = enemy.Root.Position })
                    task.wait(1)
                end
            end
        end)
    end)

    kit("mimic", ATTACK, "Pickpockets marked players. Legit: 14 studs, otherwise 18.", function(s)
        loop(s, 0.1, function()
            local here = myRoot().Position
            for _, plr in ipairs(Players:GetPlayers()) do
                if isEnemyPlayer(plr) then
                    local char, hum, root = Util.GetCharacter(plr)
                    if char and hum.Health > 0 and (root.Position - here).Magnitude <= R(14, 18)
                        and CollectionService:HasTag(char, "MimicBLockPickPocketPlayer") then
                        send("MimicPickPocket", plr)
                        task.wait(0.5)
                    end
                end
            end
        end)
    end)

    kit("trapper", ATTACK, "Sets off your explosive traps when an enemy walks into them.", function(s)
        local traps = setmetatable({}, { __mode = "k" })
        local nextBoom = 0
        local function isExplosive(trap)
            local kind = tostring(attr(trap, "trapType", "TrapType", "Type") or ""):lower()
            return kind:find("explosive", 1, true) or trap.Name:lower():find("explosive", 1, true)
                or trap:FindFirstChild("explosive_trap", true)
        end
        local function isMine(trap)
            local owner = tonumber(attr(trap, "PlacedByUserId", "OwnerUserId", "PlayerUserId", "ownerId"))
            if owner then
                return owner == LocalPlayer.UserId
            end
            local team = attr(trap, "TrapperTeamId", "TeamId")
            return team ~= nil and tostring(team) == tostring(LocalPlayer:GetAttribute("Team"))
        end
        local function radiusOf(trap)
            for _, name in ipairs({ "TriggerRadius", "DetonationRadius", "ExplosionRadius", "ActivationRadius", "Radius" }) do
                local value = tonumber(trap:GetAttribute(name))
                if value and value > 0 then
                    return value
                end
            end
            return 8
        end
        local function track(trap)
            task.wait()
            if trap.Parent and isExplosive(trap) and isMine(trap) then
                traps[trap] = true
            end
        end
        s:Clean(CollectionService:GetInstanceAddedSignal("trapper_trap"):Connect(track))
        s:Clean(CollectionService:GetInstanceRemovedSignal("trapper_trap"):Connect(function(trap)
            traps[trap] = nil
        end))
        for _, trap in ipairs(CollectionService:GetTagged("trapper_trap")) do
            task.spawn(track, trap)
        end
        loop(s, 0.05, function()
            if os.clock() < nextBoom then
                return
            end
            for trap in pairs(traps) do
                local part = trap.Parent and partOf(trap)
                if not part then
                    traps[trap] = nil
                elseif nearestEnemy(radiusOf(trap), part.Position) then
                    nextBoom = os.clock() + 0.25
                    useAbility("trapper_detonate", nil, 0.2)
                    break
                end
            end
        end)
    end)

    -- Support and utility
    kit("melody", SUPPORT, "Heals the hurt teammate nearest to you (within 30 studs) while the guitar is out.", function(s)
        loop(s, 0.1, function()
            if not holding("guitar") then
                return
            end
            local here = myRoot().Position
            local best, bestHealth, bestDistance = nil, math.huge, 30
            for _, plr in ipairs(Players:GetPlayers()) do
                if plr ~= LocalPlayer and not isEnemyPlayer(plr) then
                    local char, hum, root = Util.GetCharacter(plr)
                    if char and hum.Health > 0 and hum.Health < hum.MaxHealth then
                        local d = (root.Position - here).Magnitude
                        if d <= bestDistance and hum.Health < bestHealth then
                            best, bestHealth, bestDistance = char, hum.Health, d
                        end
                    end
                end
            end
            if best then
                send("GuitarHeal", { healTarget = best })
            end
        end)
    end)

    kit("rebellion_leader", SUPPORT, "Raises a shield (and switches to the healing aura) below half health.", function(s)
        loop(s, 0.1, function()
            local _, hum = Util.GetCharacter(LocalPlayer)
            if hum and hum.MaxHealth > 0 and hum.Health / hum.MaxHealth <= 0.5 then
                useAbility("rebellion_shield", nil, 1)
                if LocalPlayer:GetAttribute("LeaderAuraType") ~= "healing" then
                    useAbility("rebellion_aura_swap", nil, 1)
                end
            end
        end)
    end)

    kit("block_kicker", SUPPORT, "Stomps for more blocks whenever you run out.", function(s)
        loop(s, 0.1, function()
            local char = LocalPlayer.Character
            local blocks = (char and char:GetAttribute("BlockKickerKit_BlockCount"))
                or LocalPlayer:GetAttribute("BlockKickerKit_BlockCount") or 0
            if blocks <= 0 then
                useAbility("BLOCK_STOMP", nil, 0.8)
            end
        end)
    end)

    kit("spirit_gardener", SUPPORT, "Waters your flowers while you are close. Legit: 14 studs, otherwise 20.", function(s)
        loop(s, 0.5, function()
            local here = myRoot().Position
            for _, flower in ipairs(CollectionService:GetTagged("SpiritGardenerFlower")) do
                local part = partOf(flower)
                if part and flower:GetAttribute("PlacedByUserId") == LocalPlayer.UserId
                    and not flower:GetAttribute("HasFullyGrown")
                    and (part.Position - here).Magnitude <= R(14, 20) then
                    useAbility("spirit_gardener_water", nil, 0.6)
                    break
                end
            end
        end)
    end)

    kit("hatter", SUPPORT, "Teleports as soon as the game offers it.", function(s)
        local gui = LocalPlayer:FindFirstChild("PlayerGui")
        local app = gui and gui:WaitForChild("NotificationApp", 10)
        if not app or not s.Active then
            return
        end
        s:Clean(app.DescendantAdded:Connect(function(obj)
            if obj:IsA("TextLabel") and obj.Text:lower():find("teleport", 1, true) then
                task.delay(0.05, function()
                    if s.Active then
                        useAbility("HATTER_TELEPORT", nil, 0.2)
                    end
                end)
            end
        end))
        while s.Active do
            task.wait(1)
        end
    end)

    -- Module -------------------------------------------------------------------------------------
    local BY_ID = {}
    for _, entry in ipairs(KITS) do
        BY_ID[entry.Id] = entry
        BY_ID[string.lower(entry.Id)] = entry
    end

    local function prettyName(id)
        return (id:gsub("_", " "):gsub("(%a)([%w]*)", function(first, rest)
            return first:upper() .. rest
        end))
    end

    local function equippedKits()
        local list, seen = {}, {}
        local function add(id)
            if type(id) ~= "string" then
                return
            end
            id = id:lower():match("^[%w_]+") or id:lower()
            if id == "" or id == "none" or seen[id] then
                return
            end
            seen[id] = true
            list[#list + 1] = id
        end
        local function absorb(raw)
            if type(raw) == "string" then
                for id in string.gmatch(raw, "[%w_]+") do
                    add(id)
                end
            elseif type(raw) == "table" then
                for _, id in pairs(raw) do
                    add(tostring(id))
                end
            end
        end
        -- Player attributes (Bedwars uses PlayingAsKits; others show up on some seasons)
        for _, key in ipairs({ "PlayingAsKits", "Kit", "kit", "ActiveKit", "BedwarsKit", "SelectedKit" }) do
            absorb(LocalPlayer:GetAttribute(key))
        end
        local char = LocalPlayer.Character
        if char then
            for _, key in ipairs({ "PlayingAsKits", "Kit", "kit" }) do
                absorb(char:GetAttribute(key))
            end
        end
        -- Knit / store if ResolveExtras pulled them
        pcall(function()
            if Bedwars.Store then
                local state = Bedwars.Store:getState()
                if state then
                    absorb(state.Kit)
                    if state.Bedwars then
                        absorb(state.Bedwars.kit)
                    end
                end
            end
        end)
        return list
    end

    autokit = Tabs.Kits:CreateModule({
        Name = "AutoKit",
        Description = "Uses your kit's abilities for you, whichever kit you are playing.",
        OnEnable = function(mod)
            local sessions = {}
            local function stopAll()
                for id, session in pairs(sessions) do
                    sessions[id] = nil
                    session:Stop()
                end
            end
            mod.Maid:Give(stopAll)
            pcall(Bedwars.ResolveExtras)

            mod.Maid:Give(task.spawn(function()
                local lastStatus
                while mod.Enabled do
                    local ready = Bedwars.Resolve()
                    local active = {}
                    local wanted = {}
                    if ready then
                        pcall(Bedwars.ResolveExtras)
                        for _, id in ipairs(equippedKits()) do
                            local entry = BY_ID[id]
                            if entry then
                                -- Config keys use original kit id casing from KITS
                                local cfgKey = "Kit_" .. entry.Id
                                if mod.Config[cfgKey] ~= false then
                                    wanted[entry.Id] = entry
                                end
                            end
                        end
                    end
                    for id, session in pairs(sessions) do
                        if not wanted[id] then
                            sessions[id] = nil
                            session:Stop()
                        end
                    end
                    for id, entry in pairs(wanted) do
                        if not sessions[id] then
                            local session = newSession()
                            sessions[id] = session
                            session.Thread = task.spawn(function()
                                pcall(entry.Run, session)
                            end)
                        end
                        active[#active + 1] = prettyName(id)
                    end
                    table.sort(active)

                    local status
                    if not ready then
                        status = "Join a Bedwars match"
                    elseif #active > 0 then
                        status = "Running: " .. table.concat(active, ", ")
                    elseif #equippedKits() > 0 then
                        status = "Your kit isn't supported or is switched off"
                    else
                        status = "Waiting for you to pick a kit"
                    end
                    if status ~= lastStatus then
                        lastStatus = status
                        mod:SetStatus(status)
                    end
                    task.wait(0.5)
                end
            end))
        end,
    })

    autokit:AddToggle({
        Label = "Legit Range", Key = "Legit", Default = true,
        Tip = "On: every kit works at a normal distance. Off: longer reach and the extra tricks.",
    })

    for _, group in ipairs({ PICKUP, ATTACK, SUPPORT }) do
        autokit:AddSection(group)
        local names = {}
        for _, entry in ipairs(KITS) do
            if entry.Group == group then
                names[#names + 1] = entry
            end
        end
        table.sort(names, function(a, b)
            return prettyName(a.Id) < prettyName(b.Id)
        end)
        for _, entry in ipairs(names) do
            autokit:AddToggle({
                Label = prettyName(entry.Id), Key = "Kit_" .. entry.Id, Default = true, Tip = entry.Tip,
            })
        end
    end
    autokit:AddNote("Only the kit you are playing runs. Kits need a Bedwars match; switch any kit off here if it misbehaves.")
end

-- ====================== MODULE: AUTO FISHER ======================
-- Fisherman kit: finishes the fishing minigame for you, tells you what the catch is, and can cast
-- the rod by itself.
do
    local ReplicatedStorage = service("ReplicatedStorage")

    local fisher
    local FISH_NAMES = {
        fish_iron = "Iron Fish", fish_diamond = "Diamond Fish", fish_gold = "Gold Fish",
        fish_special = "Special Fish", fish_emerald = "Emerald Fish",
    }

    local function walk(root, ...)
        local node = root
        for _, name in ipairs({ ... }) do
            node = node and node:FindFirstChild(name)
        end
        return node
    end

    local animations
    local function getAnimations()
        if animations then
            return animations
        end
        local ok, util, kinds = pcall(function()
            return require(walk(ReplicatedStorage, "TS", "animation", "animation-util")).GameAnimationUtil,
                require(walk(ReplicatedStorage, "TS", "animation", "animation-type")).AnimationType
        end)
        if ok and util and kinds then
            animations = { Util = util, Type = kinds }
        end
        return animations
    end

    local function describeCatch(model, drops)
        local name = FISH_NAMES[model] or tostring(model)
        if type(drops) ~= "table" or #drops == 0 then
            return "You caught a " .. name .. (model == "fish_special" and " (special item incoming)" or "")
        end
        local totals, order = {}, {}
        for _, drop in ipairs(drops) do
            local item = tostring(drop.itemType or "unknown")
            if not totals[item] then
                totals[item] = 0
                order[#order + 1] = item
            end
            totals[item] = totals[item] + (tonumber(drop.amount) or 0)
        end
        if model == "fish_special" then
            return "You caught a " .. name .. ": " .. table.concat(order, ", ")
        end
        local parts = {}
        for _, item in ipairs(order) do
            parts[#parts + 1] = math.ceil(totals[item] * 1.4) .. "x " .. item
        end
        return "You caught a " .. name .. ": " .. table.concat(parts, ", ")
    end

    local function skipped(cfg, model)
        if type(model) ~= "string" or tostring(cfg.SkipFish or "") == "" then
            return false
        end
        for word in string.gmatch(tostring(cfg.SkipFish), "[^,%s]+") do
            if string.lower(word) == string.lower(model) then
                return true
            end
        end
        return false
    end

    local function bobber()
        for _, inst in ipairs(Workspace:GetChildren()) do
            if inst.Name == "fisherman_bobber" and inst:GetAttribute("ProjectileShooter") == LocalPlayer.UserId then
                return inst
            end
        end
        return nil
    end

    fisher = Tabs.Kits:CreateModule({
        Name = "Auto Fisher",
        Description = "Fisherman kit: wins the fishing minigame and casts for you.",
        OnEnable = function(mod)
            local loaded, why = Bedwars.Resolve()
            assert(loaded, why or "Bedwars isn't loaded yet - join a match first")
            pcall(Bedwars.ResolveExtras)

            local controller
            pcall(function()
                controller = Bedwars.Knit.Controllers.FishingMinigameController
            end)
            assert(controller and type(controller.startMinigame) == "function", "Fishing controller not found (Bedwars update?)")

            local cfg = mod.Config
            local original = controller.startMinigame
            local tracks = {}
            local function stopTracks()
                for index = #tracks, 1, -1 do
                    local track = table.remove(tracks, index)
                    pcall(function()
                        track:Stop()
                    end)
                end
            end
            local function play(kind)
                local anim = getAnimations()
                if not anim or not cfg.Animations or not anim.Type[kind] then
                    return
                end
                local ok, track = pcall(function()
                    return anim.Util:playAnimation(LocalPlayer, anim.Type[kind])
                end)
                if ok and track then
                    tracks[#tracks + 1] = track
                end
            end

            local hook
            hook = function(self, dropData, result)
                local model = dropData and dropData.fishModel
                if cfg.Notify and model then
                    Nova.Notify("Fisherman", describeCatch(model, dropData.drops), 6, "info")
                end
                if not cfg.AutoComplete then
                    return original(self, dropData, result)
                end
                if skipped(cfg, model) then
                    -- not worth it: let the game's own minigame run (and jump to fail it quickly)
                    local _, humanoid = Util.GetCharacter(LocalPlayer)
                    if humanoid and humanoid:GetState() ~= Enum.HumanoidStateType.Jumping then
                        pcall(function()
                            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                        end)
                    end
                    return original(self, dropData, result)
                end

                local wait
                if cfg.Randomize then
                    local low, high = cfg.MinDelay, math.max(cfg.MinDelay, cfg.MaxDelay)
                    wait = low + (high - low) * math.random()
                else
                    wait = cfg.Delay
                end
                task.spawn(function()
                    stopTracks()
                    if wait > 0 then
                        play("FISHING_ROD_PULLING")
                        task.wait(wait)
                        stopTracks()
                    end
                    if not mod.Enabled then
                        return
                    end
                    play("FISHING_ROD_CATCH_SUCCESS")
                    if type(result) == "function" then
                        pcall(result, { win = true })
                    end
                    task.wait(0.5)
                    stopTracks()
                end)
            end
            controller.startMinigame = hook
            mod.Maid:Give(function()
                if controller.startMinigame == hook then
                    controller.startMinigame = original
                end
                stopTracks()
            end)

            -- Auto cast
            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    task.wait(0.1)
                    if cfg.AutoCast and VirtualInputManager and Util.MatchesHeld("fishing_rod") then
                        local _, _, root = Util.GetCharacter(LocalPlayer)
                        local camera = Workspace.CurrentCamera
                        if root and camera and not bobber() then
                            local size = camera.ViewportSize
                            local ray = camera:ViewportPointToRay(size.X / 2, size.Y / 2)
                            local head = root.Position + Vector3.new(0, 1.5, 0)
                            -- only cast when the spot ahead has no ground under it (water)
                            local hit = Workspace:Raycast(head + ray.Direction * 6, Vector3.new(0, -20, 0))
                            if not hit then
                                local low, high = cfg.CastMin, math.max(cfg.CastMin, cfg.CastMax)
                                task.wait(low + (high - low) * math.random())
                                if mod.Enabled and not bobber() then
                                    for _, down in ipairs({ true, false }) do
                                        pcall(function()
                                            VirtualInputManager:SendMouseButtonEvent(size.X / 2, size.Y / 2, 0, down, game, 1)
                                        end)
                                        task.wait()
                                    end
                                    task.wait(0.5)
                                end
                            end
                        end
                    end
                end
            end))
            mod:SetStatus("Waiting for a bite")
        end,
    })

    fisher:AddSection("Minigame")
    fisher:AddToggle({
        Label = "Auto Complete", Key = "AutoComplete", Default = true,
        Tip = "Wins the fishing minigame for you.",
    })
    fisher:AddSlider({
        Label = "Delay", Key = "Delay", Min = 0, Max = 5, Default = 1, Step = 0.1, Suffix = "s",
        Tip = "How long to wait before the catch lands.",
        ShowIf = function(c) return c.AutoComplete and not c.Randomize end,
    })
    fisher:AddToggle({
        Label = "Randomize Delay", Key = "Randomize", Default = false,
        ShowIf = function(c) return c.AutoComplete end,
    })
    fisher:AddSlider({
        Label = "Shortest", Key = "MinDelay", Min = 0.1, Max = 5, Default = 0.5, Step = 0.1, Suffix = "s",
        ShowIf = function(c) return c.AutoComplete and c.Randomize end,
    })
    fisher:AddSlider({
        Label = "Longest", Key = "MaxDelay", Min = 0.1, Max = 5, Default = 2, Step = 0.1, Suffix = "s",
        ShowIf = function(c) return c.AutoComplete and c.Randomize end,
    })
    fisher:AddToggle({
        Label = "Animations", Key = "Animations", Default = true,
        Tip = "Plays the rod's pull and catch animations while it waits.",
        ShowIf = function(c) return c.AutoComplete end,
    })
    fisher:AddTextBox({
        Label = "Skip Fish", Key = "SkipFish", Default = "", Placeholder = "e.g. fish_iron",
        Tip = "Fish you don't want auto-completed (separate with commas). Those run the game's normal minigame.",
        ShowIf = function(c) return c.AutoComplete end,
    })
    fisher:AddSection("Extras")
    fisher:AddToggle({
        Label = "Catch Notify", Key = "Notify", Default = true,
        Tip = "Shows what the fish will drop as soon as it bites.",
    })
    fisher:AddToggle({
        Label = "Auto Cast", Key = "AutoCast", Default = false,
        Tip = "Casts the rod by itself while you hold it and aim at water.",
    })
    fisher:AddSlider({
        Label = "Cast Wait Min", Key = "CastMin", Min = 0, Max = 5, Default = 0.3, Step = 0.1, Suffix = "s",
        ShowIf = function(c) return c.AutoCast end,
    })
    fisher:AddSlider({
        Label = "Cast Wait Max", Key = "CastMax", Min = 0, Max = 5, Default = 1.2, Step = 0.1, Suffix = "s",
        ShowIf = function(c) return c.AutoCast end,
    })
    fisher:AddNote("Bedwars only. Hold your fishing rod to use Auto Cast.")
end

-- ====================== MODULES: VELOCITY, BED ALARM, ANTI AFK, CAMERA TOOLS ======================
-- Everything in this block only changes what happens on your own screen / your own client.

-- Velocity -----------------------------------------------------------------------------------
do
    local ReplicatedStorage = service("ReplicatedStorage")
    local rng = Random.new()
    local velocity

    local function knockbackUtil()
        if Bedwars.KnockbackUtil then
            return Bedwars.KnockbackUtil
        end
        local ok, util = pcall(function()
            return require(ReplicatedStorage.TS.damage["knockback-util"]).KnockbackUtil
        end)
        if ok and type(util) == "table" and type(util.applyKnockback) == "function" then
            Bedwars.KnockbackUtil = util
            return util
        end
        return nil
    end

    local function enemyNear(distance)
        local _, _, root = Util.GetCharacter(LocalPlayer)
        if not root then
            return false
        end
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and not Util.IsTeammate(plr) then
                local _, hum, theirRoot = Util.GetCharacter(plr)
                if hum and hum.Health > 0 and (theirRoot.Position - root.Position).Magnitude <= distance then
                    return true
                end
            end
        end
        return false
    end

    velocity = Tabs.Combat:CreateModule({
        Name = "Velocity",
        Description = "Take less knockback, or take it a moment late.",
        OnEnable = function(mod)
            local loaded, why = Bedwars.Resolve()
            assert(loaded, why or "Bedwars isn't loaded yet")
            local util = knockbackUtil()
            assert(util, "knockback code not found (Bedwars update?)")

            local original = util.applyKnockback
            local hooked
            hooked = function(root, mass, direction, knockback, ...)
                local cfg = mod.Config
                local _, _, myRoot = Util.GetCharacter(LocalPlayer)
                -- only your own character, and only when the roll and the "targeting" check allow it
                if not mod.Enabled or root ~= myRoot or rng:NextNumber(0, 100) >= cfg.Chance
                    or (cfg.OnlyTargeting and not enemyNear(50)) then
                    return original(root, mass, direction, knockback, ...)
                end
                if cfg.Mode == "Delay" then
                    local _, hum = Util.GetCharacter(LocalPlayer)
                    local inAir = hum and hum.FloorMaterial == Enum.Material.Air
                    local seconds = (inAir and cfg.DelayAir or cfg.DelayGround) / 1000
                    local args = table.pack(...)
                    task.delay(seconds, function()
                        if mod.Enabled and root.Parent then
                            pcall(original, root, mass, direction, knockback, table.unpack(args, 1, args.n))
                        end
                    end)
                    return
                end
                if cfg.Horizontal <= 0 and cfg.Vertical <= 0 then
                    return
                end
                local changed = table.clone(knockback or {})
                changed.horizontal = ((knockback and knockback.horizontal) or 1) * (cfg.Horizontal / 100)
                changed.vertical = ((knockback and knockback.vertical) or 1) * (cfg.Vertical / 100)
                return original(root, mass, direction, changed, ...)
            end
            util.applyKnockback = hooked
            mod.Maid:Give(function()
                if util.applyKnockback == hooked then
                    util.applyKnockback = original
                end
            end)
        end,
    })
    velocity:AddOption({
        Label = "Mode", Key = "Mode", Options = { "Reduce", "Delay" }, Default = "Reduce",
        Tip = "Reduce shrinks the knockback. Delay applies it a moment late instead.",
    })
    velocity:AddSlider({
        Label = "Horizontal", Key = "Horizontal", Min = 0, Max = 100, Default = 70, Step = 1, Suffix = "%",
        Tip = "How much sideways knockback you keep.",
        ShowIf = function(c) return c.Mode == "Reduce" end,
    })
    velocity:AddSlider({
        Label = "Vertical", Key = "Vertical", Min = 0, Max = 100, Default = 100, Step = 1, Suffix = "%",
        Tip = "How much upward knockback you keep.",
        ShowIf = function(c) return c.Mode == "Reduce" end,
    })
    velocity:AddSlider({
        Label = "Delay on Ground", Key = "DelayGround", Min = 0, Max = 3000, Default = 300, Step = 10, Suffix = " ms",
        ShowIf = function(c) return c.Mode == "Delay" end,
    })
    velocity:AddSlider({
        Label = "Delay in Air", Key = "DelayAir", Min = 0, Max = 3000, Default = 300, Step = 10, Suffix = " ms",
        ShowIf = function(c) return c.Mode == "Delay" end,
    })
    velocity:AddSlider({
        Label = "Chance", Key = "Chance", Min = 0, Max = 100, Default = 100, Step = 1, Suffix = "%",
        Tip = "How often it changes your knockback. 100 means every hit.",
    })
    velocity:AddToggle({
        Label = "Only When an Enemy Is Close", Key = "OnlyTargeting", Default = false,
        Tip = "Leaves knockback alone unless an enemy is within 50 studs.",
    })
end

-- Bed Alarm ----------------------------------------------------------------------------------
do
    local CollectionService = service("CollectionService")
    local alarm

    local function ownBed()
        local team = LocalPlayer:GetAttribute("Team")
        if team == nil then
            return nil
        end
        for _, bed in ipairs(CollectionService:GetTagged("bed")) do
            if bed.Parent and bed:GetAttribute("Team" .. tostring(team) .. "NoBreak") then
                return bed
            end
        end
        return nil
    end

    local function positionOf(inst)
        local ok, pivot = pcall(function()
            return inst:GetPivot().Position
        end)
        if ok then
            return pivot
        end
        return inst:IsA("BasePart") and inst.Position or nil
    end

    alarm = Tabs.Utility:CreateModule({
        Name = "Bed Alarm",
        Description = "Warns you when an enemy gets close to your bed.",
        OnEnable = function(mod)
            local highlights = {}
            local sound = Instance.new("Sound")
            sound.SoundId = "rbxasset://sounds/electronicpingshort.wav"
            mod.Maid:Give(sound)
            sound.Parent = Workspace.CurrentCamera or Workspace
            mod.Maid:Give(function()
                for _, highlight in pairs(highlights) do
                    pcall(function() highlight:Destroy() end)
                end
                highlights = {}
            end)

            local lastAlert, lastPing = 0, 0
            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    task.wait(0.2)
                    local cfg = mod.Config
                    local bed = ownBed()
                    local bedPosition = bed and positionOf(bed)
                    local nearest, nearestDistance
                    if bedPosition then
                        for _, plr in ipairs(Players:GetPlayers()) do
                            if plr ~= LocalPlayer and not Util.IsTeammate(plr)
                                and plr:GetAttribute("Team") ~= LocalPlayer:GetAttribute("Team") then
                                local char, hum, root = Util.GetCharacter(plr)
                                if char and hum.Health > 0 then
                                    local d = (root.Position - bedPosition).Magnitude
                                    if d <= cfg.Distance and (not nearestDistance or d < nearestDistance) then
                                        nearest, nearestDistance = plr, d
                                    end
                                end
                            end
                        end
                    end

                    -- outline whoever is close, remove it when they leave
                    local near = {}
                    if bedPosition and cfg.Highlight then
                        for _, plr in ipairs(Players:GetPlayers()) do
                            if plr ~= LocalPlayer and plr:GetAttribute("Team") ~= LocalPlayer:GetAttribute("Team") then
                                local char, hum, root = Util.GetCharacter(plr)
                                if char and hum.Health > 0 and (root.Position - bedPosition).Magnitude <= cfg.Distance then
                                    near[plr] = char
                                end
                            end
                        end
                    end
                    for plr, highlight in pairs(highlights) do
                        if not near[plr] or not highlight.Parent then
                            pcall(function() highlight:Destroy() end)
                            highlights[plr] = nil
                        end
                    end
                    for plr, char in pairs(near) do
                        if not highlights[plr] then
                            local highlight = Instance.new("Highlight")
                            highlight.Name = "NovaBedAlarm"
                            highlight.FillColor = Theme.Bad
                            highlight.OutlineColor = Theme.Bad
                            highlight.FillTransparency = 0.65
                            highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                            highlight.Adornee = char
                            highlight.Parent = char
                            highlights[plr] = highlight
                        end
                    end

                    if not bed then
                        mod:SetStatus(LocalPlayer:GetAttribute("Team") == nil and "Waiting for a match" or "Your bed is gone", "warn")
                    elseif nearest then
                        mod:SetStatus(string.format("%s is %d studs from your bed", nearest.DisplayName, nearestDistance), "error")
                        if os.clock() - lastAlert >= cfg.Interval then
                            lastAlert = os.clock()
                            Nova.Notify("Bed Alarm", string.format("%s is %d studs from your bed!", nearest.DisplayName, nearestDistance),
                                math.max(cfg.Interval, 2), "warn", true)
                        end
                        if cfg.Sound and os.clock() - lastPing >= 1.2 then
                            lastPing = os.clock()
                            sound.Volume = cfg.Volume
                            pcall(function() sound:Play() end)
                        end
                    else
                        mod:SetStatus("Watching your bed")
                    end
                end
            end))
        end,
    })
    alarm:AddSlider({ Label = "Distance", Key = "Distance", Min = 10, Max = 100, Default = 40, Step = 1, Suffix = " studs", Tip = "How close an enemy must get to your bed." })
    alarm:AddSlider({ Label = "Alert Every", Key = "Interval", Min = 1, Max = 10, Default = 3, Step = 0.5, Suffix = "s", Tip = "Time between pop-up warnings." })
    alarm:AddToggle({ Label = "Outline Enemies", Key = "Highlight", Default = true, Tip = "Shows enemies near your bed through walls." })
    alarm:AddToggle({ Label = "Play Sound", Key = "Sound", Default = true })
    alarm:AddSlider({ Label = "Volume", Key = "Volume", Min = 0.1, Max = 3, Default = 1.5, Step = 0.1, ShowIf = function(c) return c.Sound end })
end

-- Anti AFK -----------------------------------------------------------------------------------
do
    local afk
    afk = Tabs.Utility:CreateModule({
        Name = "Anti AFK",
        Description = "Stops Roblox from kicking you for being idle.",
        OnEnable = function(mod)
            local VirtualUser = service("VirtualUser")
            mod.Maid:Give(LocalPlayer.Idled:Connect(function()
                pcall(function()
                    VirtualUser:CaptureController()
                    VirtualUser:ClickButton2(Vector2.new(0, 0))
                end)
            end))
        end,
    })
end

-- Camera tools -------------------------------------------------------------------------------
do
    -- Field of View
    local fov

-- ====================== CLOSET MODULES (CatVape-inspired) ======================
-- Combat / utility helpers that stay low-profile. No fly, spider, speed-beyond-sprint, etc.
do



    -- No Slow: clamp movement speed multipliers >= 1
    local noSlow = Tabs.Combat:CreateModule({
        Name = "No Slow",
        Description = "Blocks client slow effects from eating/using items.",
        OnEnable = function(mod)
            local ready = Bedwars.Resolve()
            assert(ready, "Bedwars not loaded")
            pcall(Bedwars.ResolveExtras)
            local sprint = Bedwars.SprintController
            assert(sprint and sprint.getMovementStatusModifier, "SprintController missing")
            local modifier = sprint:getMovementStatusModifier()
            local oldAdd = modifier.addModifier
            modifier.addModifier = function(self, newModifier)
                if type(newModifier) == "table" and type(newModifier.moveSpeedMultiplier) == "number" then
                    if newModifier.moveSpeedMultiplier < 1 then
                        newModifier.moveSpeedMultiplier = 1
                    end
                end
                return oldAdd(self, newModifier)
            end
            pcall(function()
                for active in pairs(modifier.modifiers or {}) do
                    if type(active) == "table" and type(active.moveSpeedMultiplier) == "number" and active.moveSpeedMultiplier < 1 then
                        modifier:removeModifier(active)
                    end
                end
            end)
            mod.Maid:Give(function()
                modifier.addModifier = oldAdd
            end)
        end,
    })

    -- Auto Collect / Pickup Range
    local autoCollect = Tabs.Utility:CreateModule({
        Name = "Auto Collect",
        Description = "Picks up nearby item drops automatically.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Auto Collect", -140)
            local CollectionService = service("CollectionService")
            local last = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                if os.clock() - last < 0.15 then return end
                last = os.clock()
                local _, hum, root = Util.GetCharacter(LocalPlayer)
                if not root or not hum or hum.Health <= 0 then
                    setStatus(cfg.StatusLine, "waiting")
                    return
                end
                local range = cfg.Range or 10
                local count = 0
                local drops = {}
                pcall(function()
                    for _, inst in ipairs(CollectionService:GetTagged("ItemDrop")) do
                        drops[#drops + 1] = inst
                    end
                end)
                if #drops == 0 then
                    for _, inst in ipairs(Workspace:GetChildren()) do
                        if inst.Name == "ItemDrop" or CollectionService:HasTag(inst, "ItemDrop") then
                            drops[#drops + 1] = inst
                        end
                    end
                end
                for _, drop in ipairs(drops) do
                    local pos = drop:IsA("BasePart") and drop.Position
                        or (drop:IsA("Model") and drop.PrimaryPart and drop.PrimaryPart.Position)
                    if pos and (pos - root.Position).Magnitude <= range then
                        count = count + 1
                        pcall(function()
                            if Bedwars.Client then
                                local h = Bedwars.Client:Get("PickupItemDrop")
                                if h then
                                    local payload = { itemDrop = drop }
                                    if h.CallServerAsync then h:CallServerAsync(payload)
                                    elseif h.CallServer then h:CallServer(payload)
                                    elseif h.SendToServer then h:SendToServer(payload)
                                    end
                                end
                            end
                        end)
                    end
                end
                setStatus(cfg.StatusLine, count > 0 and ("picking " .. count) or "idle")
            end))
        end,
    })
    autoCollect:AddSlider({ Label = "Range", Key = "Range", Min = 4, Max = 20, Default = 10, Step = 0.5, Suffix = " studs" })
    autoCollect:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })

    -- Chest Steal: grab items from nearby openable chests
    local chestSteal = Tabs.Utility:CreateModule({
        Name = "Chest Steal",
        Description = "Loots nearby chests when you're close.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Chest Steal", -150)
            local CollectionService = service("CollectionService")
            local last = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                if os.clock() - last < 0.35 then return end
                last = os.clock()
                local _, hum, root = Util.GetCharacter(LocalPlayer)
                if not root or not hum or hum.Health <= 0 then
                    setStatus(cfg.StatusLine, "waiting")
                    return
                end
                local range = cfg.Range or 12
                local looted = 0
                local chests = {}
                for _, tag in ipairs({ "chest", "Chest", "personal-chest", "team-chest" }) do
                    pcall(function()
                        for _, inst in ipairs(CollectionService:GetTagged(tag)) do
                            chests[#chests + 1] = inst
                        end
                    end)
                end
                for _, chest in ipairs(chests) do
                    local pos = chest:IsA("BasePart") and chest.Position
                        or (chest.PrimaryPart and chest.PrimaryPart.Position)
                        or (chest:FindFirstChildWhichIsA("BasePart", true) and chest:FindFirstChildWhichIsA("BasePart", true).Position)
                    if pos and (pos - root.Position).Magnitude <= range then
                        looted = looted + 1
                        pcall(function()
                            if fireproximityprompt then
                                for _, p in ipairs(chest:GetDescendants()) do
                                    if p:IsA("ProximityPrompt") then
                                        fireproximityprompt(p)
                                    end
                                end
                            end
                            if Bedwars.Client then
                                for _, name in ipairs({ "ChestGetItem", "OpenChest", "BedwarsOpenChest" }) do
                                    pcall(function()
                                        local h = Bedwars.Client:Get(name)
                                        if h then
                                            local payload = { chest = chest, chestId = chest:GetAttribute("Id") or chest.Name }
                                            if h.CallServerAsync then h:CallServerAsync(payload)
                                            elseif h.CallServer then h:CallServer(payload)
                                            end
                                        end
                                    end)
                                end
                            end
                        end)
                    end
                end
                setStatus(cfg.StatusLine, looted > 0 and ("looting x" .. looted) or "idle")
            end))
        end,
    })
    chestSteal:AddSlider({ Label = "Range", Key = "Range", Min = 4, Max = 20, Default = 12, Step = 0.5, Suffix = " studs" })
    chestSteal:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })

    -- Auto Eat: consume food when HP low
    local autoEat = Tabs.Utility:CreateModule({
        Name = "Auto Eat",
        Description = "Eats food from hotbar when health is low.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Auto Eat", -160)
            local last = 0
            local FOOD = { apple = true, pie = true, gapple = true, golden_apple = true, banana = true,
                melon = true, carrot = true, potato = true, stew = true, soup = true, bread = true,
                orange = true, grape = true, berry = true, taco = true, turkey = true }
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                if os.clock() - last < 0.4 then return end
                local char, hum = Util.GetCharacter(LocalPlayer)
                if not hum or hum.Health <= 0 then
                    setStatus(cfg.StatusLine, "waiting")
                    return
                end
                local pct = (hum.Health / math.max(hum.MaxHealth, 1)) * 100
                if pct > (cfg.Health or 50) then
                    setStatus(cfg.StatusLine, string.format("hp %.0f%%", pct))
                    return
                end
                last = os.clock()
                local inv = Bedwars.GetInventory and Bedwars.GetInventory()
                local ate = false
                if inv and inv.hotbar and Bedwars.Store then
                    for index, slot in ipairs(inv.hotbar) do
                        local item = slot and slot.item
                        local typ = item and tostring(item.itemType or ""):lower()
                        if typ then
                            local isFood = FOOD[typ]
                            if not isFood then
                                for key in pairs(FOOD) do
                                    if typ:find(key, 1, true) then isFood = true break end
                                end
                            end
                            if isFood then
                                pcall(function()
                                    Bedwars.Store:dispatch({ type = "InventorySelectHotbarSlot", slot = index - 1 })
                                end)
                                task.wait(0.05)
                                pcall(function()
                                    if mouse1click then mouse1click()
                                    elseif VirtualInputManager then
                                        VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true, Workspace, 1)
                                        task.wait(0.05)
                                        VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, Workspace, 1)
                                    end
                                end)
                                ate = true
                                setStatus(cfg.StatusLine, "eating " .. typ)
                                break
                            end
                        end
                    end
                end
                if not ate then
                    setStatus(cfg.StatusLine, string.format("low hp %.0f%% no food", pct))
                end
            end))
        end,
    })
    autoEat:AddSlider({ Label = "Eat Below", Key = "Health", Min = 10, Max = 90, Default = 55, Step = 1, Suffix = "%" })
    autoEat:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })

    -- Auto Tool: swap to best break tool when mining
    local autoTool = Tabs.World:CreateModule({
        Name = "Auto Tool",
        Description = "Swaps to the best tool for the block you look at.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Auto Tool", -170)
            local last = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                if os.clock() - last < 0.2 then return end
                if cfg.RequireMouse and not Util.IsMouseDown(false) then
                    setStatus(cfg.StatusLine, "hold LMB")
                    return
                end
                local _, hum, root = Util.GetCharacter(LocalPlayer)
                if not root or not hum then
                    setStatus(cfg.StatusLine, "waiting")
                    return
                end
                local cam = Workspace.CurrentCamera
                if not cam then return end
                last = os.clock()
                local params = RaycastParams.new()
                params.FilterType = Enum.RaycastFilterType.Exclude
                params.FilterDescendantsInstances = { LocalPlayer.Character }
                local hit = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 20, params)
                if not hit or not hit.Instance then
                    setStatus(cfg.StatusLine, "no block")
                    return
                end
                local block = hit.Instance
                if not (service("CollectionService"):HasTag(block, "block") or service("CollectionService"):HasTag(block, "bed")) then
                    setStatus(cfg.StatusLine, "not a block")
                    return
                end
                local meta = Bedwars.ItemMeta and Bedwars.ItemMeta[block.Name]
                local breakType = meta and meta.block and meta.block.breakType
                if not breakType then
                    setStatus(cfg.StatusLine, block.Name)
                    return
                end
                local inv = Bedwars.GetInventory and Bedwars.GetInventory()
                local best, bestDmg, bestSlot = nil, 0, nil
                if inv and inv.hotbar then
                    for index, slot in ipairs(inv.hotbar) do
                        local item = slot and slot.item
                        if item then
                            local im = Bedwars.ItemMeta and Bedwars.ItemMeta[item.itemType]
                            local dmg = im and im.breakBlock and im.breakBlock[breakType] or 0
                            if dmg > bestDmg then
                                best, bestDmg, bestSlot = item.itemType, dmg, index - 1
                            end
                        end
                    end
                end
                if best and bestSlot and inv.hotbarSlot ~= bestSlot and Bedwars.Store then
                    pcall(function()
                        Bedwars.Store:dispatch({ type = "InventorySelectHotbarSlot", slot = bestSlot })
                    end)
                    setStatus(cfg.StatusLine, "equip " .. best)
                else
                    setStatus(cfg.StatusLine, best or "no tool")
                end
            end))
        end,
    })
    autoTool:AddToggle({ Label = "Require Mouse", Key = "RequireMouse", Default = true })
    autoTool:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })

    -- Clutch: place a block under you when falling
    local clutch = Tabs.Utility:CreateModule({
        Name = "Clutch",
        Description = "Places a block under you when you start falling.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Clutch", -180)
            local last = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                local _, hum, root = Util.GetCharacter(LocalPlayer)
                if not root or not hum or hum.Health <= 0 then
                    setStatus(cfg.StatusLine, "waiting")
                    return
                end
                local vy = root.AssemblyLinearVelocity.Y
                local falling = hum.FloorMaterial == Enum.Material.Air and vy < (cfg.FallSpeed or -20)
                if not falling then
                    setStatus(cfg.StatusLine, "ready")
                    return
                end
                if os.clock() - last < (cfg.Cooldown or 0.35) then
                    return
                end
                last = os.clock()
                -- equip wool/wood if possible
                local inv = Bedwars.GetInventory and Bedwars.GetInventory()
                if inv and inv.hotbar and Bedwars.Store then
                    for index, slot in ipairs(inv.hotbar) do
                        local item = slot and slot.item
                        local typ = item and tostring(item.itemType or ""):lower() or ""
                        if typ:find("wool", 1, true) or typ:find("wood", 1, true) or typ:find("plank", 1, true) then
                            pcall(function()
                                Bedwars.Store:dispatch({ type = "InventorySelectHotbarSlot", slot = index - 1 })
                            end)
                            break
                        end
                    end
                end
                -- look down and place
                pcall(function()
                    if mouse1click then
                        mouse1click()
                    end
                end)
                setStatus(cfg.StatusLine, "clutch!")
            end))
        end,
    })
    clutch:AddSlider({ Label = "Fall Speed", Key = "FallSpeed", Min = -80, Max = -5, Default = -25, Step = 1, Tip = "Y velocity threshold to clutch." })
    clutch:AddSlider({ Label = "Cooldown", Key = "Cooldown", Min = 0.15, Max = 1, Default = 0.35, Step = 0.05, Suffix = "s" })
    clutch:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })

    -- Fast Place: lower client place delay
    local fastPlace = Tabs.World:CreateModule({
        Name = "Fast Place",
        Description = "Reduces client block-place delay.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Fast Place", -190)
            local old
            pcall(function()
                local ready = Bedwars.Resolve()
                if not ready then return end
                pcall(Bedwars.ResolveExtras)
                local bc = Bedwars.BlockController
                if bc and type(bc.getPlaceBlockDelay) == "function" then
                    old = bc.getPlaceBlockDelay
                    bc.getPlaceBlockDelay = function()
                        return tonumber(cfg.Delay) or 0
                    end
                end
            end)
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                setStatus(cfg.StatusLine, "active")
            end))
            mod.Maid:Give(function()
                pcall(function()
                    if old and Bedwars.BlockController then
                        Bedwars.BlockController.getPlaceBlockDelay = old
                    end
                end)
            end)
        end,
    })
    fastPlace:AddSlider({ Label = "Delay", Key = "Delay", Min = 0, Max = 0.2, Default = 0, Step = 0.01, Suffix = "s" })
    fastPlace:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = false })

    -- Fast Drop: drop items quickly
    local fastDrop = Tabs.Utility:CreateModule({
        Name = "Fast Drop",
        Description = "Drops the held item repeatedly while Q is held.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local last = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                if not UserInputService:IsKeyDown(Enum.KeyCode.Q) then return end
                if UserInputService:GetFocusedTextBox() then return end
                if os.clock() - last < (cfg.Gap or 0.08) then return end
                last = os.clock()
                pcall(function()
                    if Bedwars.Client then
                        local h = Bedwars.Client:Get("DropItem")
                        if h then
                            if h.CallServerAsync then h:CallServerAsync({})
                            elseif h.CallServer then h:CallServer({})
                            elseif h.SendToServer then h:SendToServer({})
                            end
                        end
                    end
                end)
            end))
        end,
    })
    fastDrop:AddSlider({ Label = "Gap", Key = "Gap", Min = 0.05, Max = 0.3, Default = 0.08, Step = 0.01, Suffix = "s" })

    -- Auto Hotbar: keep preferred item types equipped by priority list
    local autoHotbar = Tabs.Utility:CreateModule({
        Name = "Auto Hotbar",
        Description = "Keeps a preferred item type selected (sword/blocks/etc).",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Auto Hotbar", -200)
            local last = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                if os.clock() - last < 0.35 then return end
                last = os.clock()
                local prefer = string.lower(tostring(cfg.Prefer or "sword"))
                local inv = Bedwars.GetInventory and Bedwars.GetInventory()
                if not (inv and inv.hotbar and Bedwars.Store) then
                    setStatus(cfg.StatusLine, "no inv")
                    return
                end
                for index, slot in ipairs(inv.hotbar) do
                    local item = slot and slot.item
                    local typ = item and tostring(item.itemType or ""):lower() or ""
                    local meta = item and Bedwars.ItemMeta and Bedwars.ItemMeta[item.itemType]
                    local match = typ:find(prefer, 1, true)
                        or (prefer == "sword" and meta and meta.sword)
                        or (prefer == "block" and meta and meta.block)
                        or (prefer == "bow" and meta and meta.projectileSource)
                    if match and inv.hotbarSlot ~= (index - 1) then
                        pcall(function()
                            Bedwars.Store:dispatch({ type = "InventorySelectHotbarSlot", slot = index - 1 })
                        end)
                        setStatus(cfg.StatusLine, "equip " .. typ)
                        return
                    end
                end
                setStatus(cfg.StatusLine, "ok")
            end))
        end,
    })
    autoHotbar:AddOption({
        Label = "Prefer", Key = "Prefer",
        Options = { "sword", "block", "bow", "pickaxe", "wool" },
        Default = "sword",
    })
    autoHotbar:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = false })

    -- Anti Effect: strip common negative status effects client-side where possible
    local antiEffect = Tabs.Utility:CreateModule({
        Name = "Anti Effect",
        Description = "Tries to clear slow/poison/fire-style effects on you.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Anti Effect", -210)
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                local char, hum = Util.GetCharacter(LocalPlayer)
                if not char or not hum then
                    setStatus(cfg.StatusLine, "waiting")
                    return
                end
                local cleared = 0
                for _, child in ipairs(char:GetChildren()) do
                    local n = string.lower(child.Name)
                    if child:IsA("NumberValue") or child:IsA("BoolValue") or child:IsA("Folder") or child:IsA("Configuration") then
                        if n:find("slow", 1, true) or n:find("poison", 1, true) or n:find("burn", 1, true)
                            or n:find("freeze", 1, true) or n:find("stun", 1, true) or n:find("plague", 1, true) then
                            pcall(function() child:Destroy() end)
                            cleared = cleared + 1
                        end
                    end
                end
                -- Restore walkspeed if crushed
                if hum.WalkSpeed > 0 and hum.WalkSpeed < 12 and cfg.FixSpeed then
                    hum.WalkSpeed = 16
                end
                setStatus(cfg.StatusLine, cleared > 0 and ("cleared " .. cleared) or "clean")
            end))
        end,
    })
    antiEffect:AddToggle({ Label = "Fix WalkSpeed", Key = "FixSpeed", Default = true })
    antiEffect:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = false })

    -- Reach: raises the client's own RAYCAST_SWORD_CHARACTER_DISTANCE constant, the way aero's
    -- "Attack Range" does - bedwars.CombatConstant.RAYCAST_SWORD_CHARACTER_DISTANCE = value.
    -- This is a DIFFERENT code path from Kill Aura: KA builds and sends its own SendHit payload
    -- with a spoofed position (see the Range slider on Kill Aura/SERVER_SLACK above) and never
    -- reads this constant at all, because it prefers the sword's own attackRange field whenever
    -- the game provides one. This module instead widens the distance the CLIENT lets a *manual*
    -- swing (click without Kill Aura) or a block-mine register at, by changing the one shared
    -- table the game's own SwordController/BlockBreaker read that distance from. The previous
    -- version here fell back silently whenever the write didn't stick, which looked identical to
    -- "doing nothing" - this one resolves the table once, reapplies every frame the way aero's
    -- does (the game can reset it), and reads the value back after writing so a rejected write
    -- (a frozen/read-only table) shows up on the status line instead of just failing quietly.
    local reach = Tabs.Combat:CreateModule({
        Name = "Reach",
        Description = "Extends the client's own sword/mine reach constant (closet — keep Extra low).",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Reach", -220)
            local cc, key, baseValue = nil, nil, nil
            local lastWritten = nil

            local function resolve()
                if cc and key then
                    return true
                end
                local ok = pcall(function()
                    local TS = ReplicatedStorage:FindFirstChild("TS")
                    local modu = TS and TS:FindFirstChild("combat") and TS.combat:FindFirstChild("combat-constant")
                    if not modu then
                        return
                    end
                    local pack = require(modu)
                    local pickedCc = (type(pack) == "table" and pack.CombatConstant) or pack
                    if type(pickedCc) ~= "table" then
                        return
                    end
                    local pickedKey = "RAYCAST_SWORD_CHARACTER_DISTANCE"
                    if type(pickedCc[pickedKey]) ~= "number" then
                        -- Field name can shift between game updates - fall back to scanning for it
                        for k, v in pairs(pickedCc) do
                            if type(v) == "number" and v > 10 and v < 30 and type(k) == "string"
                                and (k:lower():find("sword", 1, true) or k:lower():find("ray", 1, true)) then
                                pickedKey = k
                                break
                            end
                        end
                    end
                    if type(pickedCc[pickedKey]) == "number" then
                        cc, key, baseValue = pickedCc, pickedKey, pickedCc[pickedKey]
                    end
                end)
                return ok and cc ~= nil
            end

            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                if not Bedwars.Resolve() then
                    setStatus(cfg.StatusLine, "waiting for Bedwars")
                    return
                end
                if not resolve() then
                    setStatus(cfg.StatusLine, "combat-constant not found (Bedwars update?)")
                    return
                end
                local extra = tonumber(cfg.Extra) or 1.5
                local target = math.clamp(baseValue + extra, 12, 20)
                if cc[key] ~= target then
                    pcall(function()
                        cc[key] = target
                    end)
                end
                lastWritten = target
                Bedwars.ReachLimit = target
                if cc[key] == target then
                    setStatus(cfg.StatusLine, string.format("%.1f studs (base %.1f +%.1f)", target, baseValue, extra))
                else
                    -- Write didn't stick - most likely the table is read-only on this game version
                    setStatus(cfg.StatusLine, string.format("blocked by the game (still %.1f)", tonumber(cc[key]) or -1))
                end
            end))
            mod.Maid:Give(function()
                pcall(function()
                    if cc and key and baseValue and cc[key] == lastWritten then
                        cc[key] = baseValue
                    end
                end)
                Bedwars.ReachLimit = (type(baseValue) == "number") and baseValue or Bedwars.ReachLimit
            end)
        end,
    })
    reach:AddSlider({ Label = "Extra Reach", Key = "Extra", Min = 0, Max = 4, Default = 1.5, Step = 0.1, Suffix = " studs", Tip = "Added on top of the real value (reads it live, usually ~12-14.4). Only affects manual swings/mining, not Kill Aura. Keep ≤2 for closet." })
    reach:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })


    -- Anti Suffocate: unstuck when inside blocks
    local antiSuf = Tabs.Utility:CreateModule({
        Name = "Anti Suffocate",
        Description = "Nudge out when your head is inside a block.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local last = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                if os.clock() - last < 0.2 then return end
                local char, hum, root = Util.GetCharacter(LocalPlayer)
                if not root or not hum then return end
                local head = char:FindFirstChild("Head")
                if not head then return end
                local params = RaycastParams.new()
                params.FilterType = Enum.RaycastFilterType.Exclude
                params.FilterDescendantsInstances = { char }
                local parts = Workspace:GetPartBoundsInBox(head.CFrame, Vector3.new(1.2, 1.2, 1.2), OverlapParams.new())
                local stuck = false
                for _, p in ipairs(parts) do
                    if p.CanCollide and not p:IsDescendantOf(char) then
                        stuck = true
                        break
                    end
                end
                if stuck then
                    last = os.clock()
                    root.CFrame = root.CFrame + Vector3.new(0, cfg.Lift or 3, 0)
                end
            end))
        end,
    })
    antiSuf:AddSlider({ Label = "Lift", Key = "Lift", Min = 1, Max = 6, Default = 3, Step = 0.5, Suffix = " studs" })

    -- Trap Disabler: break/ignore nearby snap traps if tagged
    local trapDis = Tabs.Utility:CreateModule({
        Name = "Trap Disabler",
        Description = "Breaks nearby enemy traps when you walk close.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local CollectionService = service("CollectionService")
            local last = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                if os.clock() - last < 0.4 then return end
                local _, _, root = Util.GetCharacter(LocalPlayer)
                if not root then return end
                last = os.clock()
                for _, tag in ipairs({ "trap", "snap-trap", "damage-trap", "tesla-trap" }) do
                    pcall(function()
                        for _, inst in ipairs(CollectionService:GetTagged(tag)) do
                            local pos = inst:IsA("BasePart") and inst.Position or (inst.PrimaryPart and inst.PrimaryPart.Position)
                            if pos and (pos - root.Position).Magnitude <= (cfg.Range or 10) then
                                pcall(function()
                                    if Bedwars.DamageBlockRemotes then
                                        local cell
                                        if Bedwars.BlockController then
                                            cell = Bedwars.BlockController:getBlockPosition(pos)
                                        end
                                        if cell then
                                            local h = Bedwars.DamageBlockRemotes:Get("DamageBlock")
                                            if h and h.CallServerAsync then
                                                h:CallServerAsync({
                                                    blockRef = { blockPosition = cell },
                                                    hitPosition = pos,
                                                    hitNormal = Vector3.new(0, 1, 0),
                                                })
                                            end
                                        end
                                    end
                                end)
                            end
                        end
                    end)
                end
            end))
        end,
    })
    trapDis:AddSlider({ Label = "Range", Key = "Range", Min = 4, Max = 18, Default = 10, Step = 1, Suffix = " studs" })

    -- Auto Vote: vote on map/mode popups when they appear
    local autoVote = Tabs.Utility:CreateModule({
        Name = "Auto Vote",
        Description = "Auto-clicks vote buttons when the vote UI opens.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local last = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                if os.clock() - last < 1 then return end
                local pg = LocalPlayer:FindFirstChild("PlayerGui")
                if not pg then return end
                for _, gui in ipairs(pg:GetDescendants()) do
                    if gui:IsA("TextButton") or gui:IsA("ImageButton") then
                        local t = string.lower(tostring(gui.Text or gui.Name or ""))
                        if t:find("vote", 1, true) or t:find("yes", 1, true) or t == "1" or t == "2" or t == "3" then
                            if gui.Visible and gui.AbsoluteSize.Magnitude > 5 then
                                last = os.clock()
                                pcall(function()
                                    firesignal(gui.MouseButton1Click)
                                end)
                                pcall(function()
                                    gui.MouseButton1Click:Fire()
                                end)
                            end
                        end
                    end
                end
            end))
        end,
    })

    -- Fast Consume: speed up eating/charging use time client-side when possible
    local fastConsume = Tabs.Utility:CreateModule({
        Name = "Fast Consume",
        Description = "Uses food/potions faster while holding click.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Fast Consume", -240)
            local last = 0
            local function isConsumable(name)
                if not name then return false end
                local meta = Bedwars.ItemMeta and Bedwars.ItemMeta[name]
                if meta and (meta.consumable or meta.food or meta.potion) then
                    return true
                end
                local n = string.lower(tostring(name))
                for _, key in ipairs({ "apple", "pie", "gapple", "banana", "stew", "soup", "bread",
                    "potion", "juice", "taco", "turkey", "orange", "grape", "berry", "melon", "carrot" }) do
                    if n:find(key, 1, true) then return true end
                end
                return false
            end
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                local held = Util.GetHeldName and Util.GetHeldName()
                if not isConsumable(held) then
                    setStatus(cfg.StatusLine, "hold food/potion")
                    return
                end
                if not Util.IsMouseDown(false) and cfg.RequireMouse then
                    setStatus(cfg.StatusLine, "hold LMB")
                    return
                end
                local gap = tonumber(cfg.Gap) or 0.08
                if os.clock() - last < gap then return end
                last = os.clock()
                -- Activate tool + try consumable remotes
                pcall(function()
                    local tool = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Tool")
                    if tool then tool:Activate() end
                end)
                pcall(function()
                    if not Bedwars.Client then return end
                    for _, name in ipairs({ "ConsumeItem", "UseItem", "BedwarsUseItem", "ConsumeFood" }) do
                        local h = Bedwars.Client:Get(name)
                        if h then
                            local payload = { item = held, itemType = held }
                            if h.CallServerAsync then h:CallServerAsync(payload)
                            elseif h.CallServer then h:CallServer(payload)
                            elseif h.SendToServer then h:SendToServer(payload)
                            end
                        end
                    end
                end)
                pcall(function()
                    if mouse1click then mouse1click() end
                end)
                setStatus(cfg.StatusLine, "using " .. tostring(held))
            end))
        end,
    })
    fastConsume:AddSlider({ Label = "Gap", Key = "Gap", Min = 0.05, Max = 0.25, Default = 0.08, Step = 0.01, Suffix = "s" })
    fastConsume:AddToggle({ Label = "Require Mouse", Key = "RequireMouse", Default = true })
    fastConsume:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })

    -- Bow Assist: mild charge helper — holds full draw hint via status only + slight FOV aim sticky handled by PA
    local bowAssist = Tabs.Combat:CreateModule({
        Name = "Bow Assist",
        Description = "Notifies when bow is fully charged; pairs with Projectile Aimbot.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Bow Assist", -230)
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                local held = Util.GetHeldName and Util.GetHeldName()
                local meta = held and Bedwars.ItemMeta and Bedwars.ItemMeta[held]
                if not (meta and meta.projectileSource) then
                    setStatus(cfg.StatusLine, "equip bow")
                    return
                end
                if Util.IsMouseDown(false) then
                    setStatus(cfg.StatusLine, "drawing — release to fire")
                else
                    setStatus(cfg.StatusLine, "ready")
                end
            end))
        end,
    })
    bowAssist:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })

end

-- ====================== AUTOMATION TAB ======================
do
    local function flatUnit(v, fallback)
        local f = Vector3.new(v.X, 0, v.Z)
        if f.Magnitude < 0.05 then
            return fallback or Vector3.new(0, 0, -1)
        end
        return f.Unit
    end

    -- Equip best sword from hotbar if we aren't holding one
    local lastSwordSwap = 0
    local function ensureSword()
        local item, meta = Bedwars.GetHeldSword()
        if item then
            return item, meta
        end
        if os.clock() - lastSwordSwap < 0.35 then
            return nil, "swapping to sword..."
        end
        lastSwordSwap = os.clock()
        local inv = Bedwars.GetInventory and Bedwars.GetInventory()
        if not (inv and inv.hotbar and Bedwars.Store) then
            return nil, "hold a sword"
        end
        local bestSlot, bestRank = nil, -1
        local rank = {
            emerald_sword = 7, diamond_sword = 6, iron_sword = 5, stone_sword = 4,
            wood_sword = 3, wooden_sword = 3, sword = 2, dagger = 1,
        }
        for index, slot in ipairs(inv.hotbar) do
            local it = slot and slot.item
            if it then
                local typ = tostring(it.itemType or "")
                local m = Bedwars.ItemMeta and Bedwars.ItemMeta[typ]
                local r = 0
                if m and m.sword then
                    r = 3
                end
                local lower = string.lower(typ)
                for key, val in pairs(rank) do
                    if lower:find(key, 1, true) then
                        r = math.max(r, val)
                    end
                end
                if r > bestRank then
                    bestRank, bestSlot = r, index - 1
                end
            end
        end
        if bestSlot and bestRank > 0 then
            pcall(function()
                Bedwars.Store:dispatch({ type = "InventorySelectHotbarSlot", slot = bestSlot })
            end)
            return nil, "swapping to sword..."
        end
        return nil, "no sword in hotbar"
    end

    -- Shared navigation: wall slide, void detour, single ledge jump
    local function makeNavigator()
        local lastJump = 0
        local lastPos, stuckFor = nil, 0
        local avoidDir, avoidUntil = nil, 0

        local function groundAt(pos)
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            local char = LocalPlayer.Character
            if char then params.FilterDescendantsInstances = { char } end
            local hit = Workspace:Raycast(pos + Vector3.new(0, 4, 0), Vector3.new(0, -14, 0), params)
            return hit ~= nil, hit
        end

        local function blocked(origin, dir, dist)
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Exclude
            local char = LocalPlayer.Character
            if char then params.FilterDescendantsInstances = { char } end
            local hit = Workspace:Raycast(origin + Vector3.new(0, 1.5, 0), dir * dist, params)
            return hit and hit.Instance and hit.Instance.CanCollide or false
        end

        -- Score a candidate direction for progress toward goal + safety
        local function scoreDir(origin, dir, goalFlat)
            if blocked(origin, dir, 2.8) then
                return -1000
            end
            local score = 0
            -- ground samples along path
            local grounded = 0
            for s = 2, 10, 2 do
                local p = origin + dir * s
                if groundAt(p) then
                    grounded = grounded + 1
                else
                    score = score - 8
                end
                if not blocked(origin, dir, s) then
                    score = score + 2
                end
            end
            if grounded == 0 then
                return -500 -- pure void path
            end
            score = score + grounded * 3
            -- prefer directions that still head toward the goal
            if goalFlat.Magnitude > 0.1 then
                score = score + dir:Dot(goalFlat.Unit) * 12
            end
            return score
        end

        local function steer(root, desiredFlat, allowJump)
            if desiredFlat.Magnitude < 0.05 then
                return nil, "arrived"
            end
            local goal = desiredFlat.Unit
            local dir = goal
            local origin = root.Position
            local now = os.clock()

            if avoidDir and now < avoidUntil then
                dir = avoidDir
            end

            -- If straight path is void/blocked, search for best detour (don't just stop)
            local straightBad = blocked(origin, dir, 3.2) or not groundAt(origin + dir * 5)
            if straightBad then
                local bestDir, bestScore = nil, -1e9
                for _, deg in ipairs({ 0, 25, -25, 45, -45, 70, -70, 95, -95, 120, -120, 150, -150 }) do
                    local d = flatUnit(CFrame.Angles(0, math.rad(deg), 0) * goal)
                    local sc = scoreDir(origin, d, desiredFlat)
                    if sc > bestScore then
                        bestScore, bestDir = sc, d
                    end
                end
                if bestDir and bestScore > -100 then
                    dir = bestDir
                    avoidDir, avoidUntil = dir, now + 0.55
                else
                    -- Truly no safe path
                    return nil, "void ahead"
                end
            end

            -- Stuck → one ledge jump if ground exists ahead
            if lastPos then
                if (root.Position - lastPos).Magnitude < 0.55 then
                    stuckFor = stuckFor + 0.03
                else
                    stuckFor = 0
                end
            end
            lastPos = root.Position

            if allowJump and stuckFor > 0.5 and now - lastJump > 1.15 then
                local ahead = origin + dir * 4
                if groundAt(ahead + Vector3.new(0, 2, 0)) and groundAt(ahead) then
                    lastJump = now
                    stuckFor = 0
                    pcall(function()
                        local hum = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
                        if hum then hum.Jump = true end
                    end)
                end
            end

            return dir, nil
        end

        local function reset()
            lastPos, stuckFor = nil, 0
            avoidDir, avoidUntil = nil, 0
        end

        return { steer = steer, reset = reset, groundAt = groundAt }
    end

    -- Lightweight melee used by AutoFight + Auto Play (built-in)
    local function tryMelee(root, hum, range, angle, wallCheck, minInterval, state)
        state = state or {}
        local item, meta = ensureSword()
        if not item then
            return false, meta
        end
        local cam = Workspace.CurrentCamera
        local camLook = flatUnit(cam and cam.CFrame.LookVector or root.CFrame.LookVector)
        local halfCos = math.cos(math.rad(angle or 360) / 2)
        local useAngle = (angle or 360) < 359
        local best, bestScore, bestDist
        for _, entry in ipairs(Util.GetTargets("Players")) do
            if entry.Root and entry.Humanoid and entry.Humanoid.Health > 0
                and not (entry.Player and Util.IsTeammate(entry.Player)) then
                local offset = entry.Root.Position - root.Position
                local dist = offset.Magnitude
                if dist <= range then
                    local toward = flatUnit(offset, camLook)
                    local angOk = (not useAngle) or camLook:Dot(toward) >= halfCos
                    local wallOk = true
                    if wallCheck then
                        wallOk = Util.HasLineOfSight(root.Position + Vector3.new(0, 1.5, 0), entry.Root.Position)
                    end
                    if angOk and wallOk and (not bestScore or dist < bestScore) then
                        best, bestScore, bestDist = entry, dist, dist
                    end
                end
            end
        end
        if not best then
            return false, nil
        end
        -- Face
        local flatTo = Vector3.new(best.Root.Position.X - root.Position.X, 0, best.Root.Position.Z - root.Position.Z)
        if flatTo.Magnitude > 0.1 then
            local goal = CFrame.lookAt(root.Position, root.Position + flatTo)
            root.CFrame = root.CFrame:Lerp(goal, 0.35)
        end
        local swordFloor = (meta.sword and type(meta.sword.attackSpeed) == "number") and meta.sword.attackSpeed or 0
        local interval = math.max(tonumber(minInterval) or 0.05, swordFloor)
        local now = os.clock()
        if now - (state.lastSend or 0) < interval then
            return true, best, bestDist, false
        end
        local ok = Bedwars.SendHit(item, best.Model, root.Position, best.Root.Position)
        if ok then
            state.lastSend = now
            pcall(function()
                Bedwars.SwordController:playSwordEffect(meta, false)
            end)
        end
        return true, best, bestDist, ok and true or false
    end

    -- ===================== AutoFight =====================
    local autoFight = Tabs.Automation:CreateModule({
        Name = "AutoFight",
        Description = "Faces, chases, and swings. Auto-equips sword. No mouse needed.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "AutoFight", -110)
            local lastSend = 0
            local autoRotateOverridden = nil
            local nav = makeNavigator()
            local box = mod.Maid:Give(New("BoxHandleAdornment", {
                Size = Vector3.new(3.6, 5.2, 3.6),
                CFrame = CFrame.new(0, -0.55, 0),
                Transparency = 0.7,
                Color3 = Theme.Accent,
                AlwaysOnTop = true,
                ZIndex = 1,
                Adornee = nil,
                Parent = UI.Gui,
            }))

            local function releaseRotation(hum)
                if autoRotateOverridden ~= nil and hum then
                    pcall(function() hum.AutoRotate = autoRotateOverridden end)
                end
                autoRotateOverridden = nil
            end

            local function userWantsControl()
                if UserInputService:GetFocusedTextBox() then return true end
                local keys = 0
                for _, k in ipairs({ Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D }) do
                    if UserInputService:IsKeyDown(k) then keys = keys + 1 end
                end
                return keys >= 2
            end

            mod.Maid:Give(RunService.RenderStepped:Connect(function(dt)
                local char, hum, root = Util.GetCharacter(LocalPlayer)
                local function idle(text)
                    box.Adornee = nil
                    releaseRotation(hum)
                    setStatus(cfg.StatusLine, text)
                end

                local ready, why = Bedwars.Resolve()
                if not ready then
                    idle("unavailable - " .. tostring(why))
                    return
                end
                if not char or not hum or hum.Health <= 0 or not root then
                    idle("waiting for character")
                    return
                end

                local item, meta = ensureSword()
                if not item then
                    idle(tostring(meta))
                    return
                end

                local cam = Workspace.CurrentCamera
                local camLook = flatUnit(cam and cam.CFrame.LookVector or root.CFrame.LookVector)
                local attackRange = tonumber(cfg.Range) or 14
                local chaseRange = tonumber(cfg.ChaseRange) or 250
                if cfg.Chase == false then
                    chaseRange = attackRange
                end
                local halfCos = math.cos(math.rad(cfg.Angle or 360) / 2)
                local useAngle = (cfg.Angle or 360) < 359

                local closest, closestDist = nil, math.huge
                local attackTarget, attackDist, attackScore = nil, nil, nil
                for _, entry in ipairs(Util.GetTargets(cfg.Targets or "Players")) do
                    if entry.Root and entry.Humanoid and entry.Humanoid.Health > 0 then
                        if not (entry.Player and Util.IsTeammate(entry.Player)) then
                            local offset = entry.Root.Position - root.Position
                            local dist = offset.Magnitude
                            if dist < closestDist and dist <= chaseRange then
                                closest, closestDist = entry, dist
                            end
                            if dist <= attackRange then
                                local toward = flatUnit(offset, camLook)
                                local angOk = (not useAngle) or camLook:Dot(toward) >= halfCos
                                local wallOk = true
                                if cfg.WallCheck then
                                    wallOk = Util.HasLineOfSight(root.Position + Vector3.new(0, 1.5, 0), entry.Root.Position)
                                end
                                if angOk and wallOk then
                                    local score = dist
                                    if cfg.Sort == "Health" then
                                        score = entry.Humanoid.Health
                                    elseif cfg.Sort == "Angle" then
                                        score = -camLook:Dot(toward)
                                    end
                                    if not attackScore or score < attackScore then
                                        attackTarget, attackDist, attackScore = entry, dist, score
                                    end
                                end
                            end
                        end
                    end
                end

                local focus = attackTarget or closest
                if not focus then
                    idle(cfg.Chase ~= false and "no one in chase range" or "no target")
                    pcall(function() hum:Move(Vector3.zero, false) end)
                    return
                end

                if cfg.ShowTarget then
                    box.Adornee = focus.Root
                else
                    box.Adornee = nil
                end

                local flatTo = Vector3.new(focus.Root.Position.X - root.Position.X, 0, focus.Root.Position.Z - root.Position.Z)
                local dist = flatTo.Magnitude
                if dist > 0.1 then
                    if autoRotateOverridden == nil then
                        autoRotateOverridden = hum.AutoRotate
                    end
                    hum.AutoRotate = false
                    local goal = CFrame.lookAt(root.Position, root.Position + flatTo)
                    root.CFrame = root.CFrame:Lerp(goal, math.clamp(1 - math.exp(-18 * dt), 0, 1))
                end

                local stick = tonumber(cfg.WalkUntil) or 4.5
                if cfg.Chase ~= false and dist > stick and not userWantsControl() then
                    local dir, reason = nav.steer(root, flatTo, cfg.LedgeJump ~= false)
                    if dir then
                        pcall(function() hum:Move(dir, false) end)
                    else
                        pcall(function() hum:Move(Vector3.zero, false) end)
                        if reason == "void ahead" and not attackTarget then
                            setStatus(cfg.StatusLine, "no safe path — stopped")
                            return
                        end
                    end
                    if not attackTarget then
                        setStatus(cfg.StatusLine, string.format("chasing %s (%.0f)", focus.Name, closestDist))
                        return
                    end
                elseif dist <= stick and not userWantsControl() then
                    pcall(function() hum:Move(Vector3.zero, false) end)
                end

                if not attackTarget then
                    setStatus(cfg.StatusLine, string.format("near %s — out of attack range/FOV", focus.Name))
                    return
                end

                local swordFloor = (meta.sword and type(meta.sword.attackSpeed) == "number") and meta.sword.attackSpeed or 0
                local interval = math.max(tonumber(cfg.MinInterval) or 0.05, swordFloor)
                local now = os.clock()
                if now - lastSend < interval then
                    setStatus(cfg.StatusLine, string.format("%s (%.1f)", attackTarget.Name, attackDist))
                    return
                end

                local ok, err = Bedwars.SendHit(item, attackTarget.Model, root.Position, attackTarget.Root.Position)
                if ok then
                    lastSend = now
                    pcall(function()
                        Bedwars.SwordController:playSwordEffect(meta, false)
                    end)
                    setStatus(cfg.StatusLine, string.format("hit %s (%.1f)", attackTarget.Name, attackDist))
                else
                    setStatus(cfg.StatusLine, tostring(err))
                end
            end))

            mod.Maid:Give(function()
                local _, hum = Util.GetCharacter(LocalPlayer)
                releaseRotation(hum)
                nav.reset()
                pcall(function() if hum then hum:Move(Vector3.zero, false) end end)
            end)
        end,
    })
    autoFight:AddSection("Combat")
    autoFight:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players" })
    autoFight:AddSlider({ Label = "Attack Range", Key = "Range", Min = 5, Max = 22, Default = 14, Step = 0.5, Suffix = " studs" })
    autoFight:AddSlider({ Label = "Max Angle", Key = "Angle", Min = 30, Max = 360, Default = 360, Step = 5, Suffix = "°" })
    autoFight:AddOption({ Label = "Sort", Key = "Sort", Options = { "Distance", "Health", "Angle" }, Default = "Distance" })
    autoFight:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true })
    autoFight:AddSlider({ Label = "Min Interval", Key = "MinInterval", Min = 0.03, Max = 0.5, Default = 0.05, Step = 0.01, Suffix = "s" })
    autoFight:AddSection("Chase")
    autoFight:AddToggle({ Label = "Walk To Target", Key = "Chase", Default = true })
    autoFight:AddSlider({
        Label = "Chase Range", Key = "ChaseRange", Min = 20, Max = 1000, Default = 250, Step = 10, Suffix = " studs",
        ShowIf = function(c) return c.Chase end,
    })
    autoFight:AddSlider({
        Label = "Stop Distance", Key = "WalkUntil", Min = 2, Max = 12, Default = 4.5, Step = 0.5, Suffix = " studs",
        ShowIf = function(c) return c.Chase end,
    })
    autoFight:AddToggle({
        Label = "Ledge Jump", Key = "LedgeJump", Default = true,
        ShowIf = function(c) return c.Chase end,
    })
    autoFight:AddToggle({ Label = "Show Target", Key = "ShowTarget", Default = true })
    autoFight:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })
    autoFight:AddLabel("Auto-equips sword. Detours around void when a safe path exists.")

    -- ===================== Auto Play [BETA] =====================
    local autoPlay = Tabs.Automation:CreateModule({
        Name = "Auto Play [BETA]",
        Description = "Farm → push. Built-in AutoFight (30 studs). Auto sword.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local setStatus = makeStatusLabel(mod, "Auto Play", -200)
            local CollectionService = service("CollectionService")
            local phase = "farm"
            local farmStartedAt = 0
            local pushUntil = 0
            local homeGen = nil
            local nav = makeNavigator()
            local meleeState = { lastSend = 0 }
            local forceLeaveGen = false

            local function partPos(inst)
                if not inst then return nil end
                if inst:IsA("BasePart") then return inst.Position end
                if inst:IsA("Model") then
                    if inst.PrimaryPart then return inst.PrimaryPart.Position end
                    local p = inst:FindFirstChildWhichIsA("BasePart", true)
                    return p and p.Position or nil
                end
                return nil
            end

            local function manual()
                if UserInputService:GetFocusedTextBox() then return true end
                for _, k in ipairs({ Enum.KeyCode.W, Enum.KeyCode.A, Enum.KeyCode.S, Enum.KeyCode.D }) do
                    if UserInputService:IsKeyDown(k) then return true end
                end
                return false
            end

            local function nearestTagged(origin, tags, pred)
                local best, bestD
                for _, tag in ipairs(tags) do
                    pcall(function()
                        for _, inst in ipairs(CollectionService:GetTagged(tag)) do
                            if not pred or pred(inst) then
                                local p = partPos(inst)
                                if p then
                                    local d = (p - origin).Magnitude
                                    if not bestD or d < bestD then
                                        best, bestD = p, d
                                    end
                                end
                            end
                        end
                    end)
                end
                return best, bestD
            end

            local function isEnemyBed(inst, myTeam)
                local team = inst:GetAttribute("Team")
                if team == nil and inst.Parent then team = inst.Parent:GetAttribute("Team") end
                if myTeam == nil or team == nil then return false end
                return tostring(team) ~= tostring(myTeam)
            end

            local function isOwnBed(inst, myTeam)
                local team = inst:GetAttribute("Team")
                if team == nil and inst.Parent then team = inst.Parent:GetAttribute("Team") end
                return myTeam ~= nil and team ~= nil and tostring(team) == tostring(myTeam)
            end

            local function walkTo(hum, root, target, stop)
                if not target or not hum or not root then return true end
                if manual() then return false end
                local flat = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
                if flat.Magnitude <= (stop or 4) then
                    pcall(function() hum:Move(Vector3.zero, false) end)
                    return true
                end
                local dir = nav.steer(root, flat, cfg.LedgeJump ~= false)
                if dir then
                    pcall(function() hum:Move(dir, false) end)
                else
                    pcall(function() hum:Move(Vector3.zero, false) end)
                end
                return false
            end

            mod.Maid:Give(function()
                local _, hum = Util.GetCharacter(LocalPlayer)
                nav.reset()
                pcall(function() if hum then hum:Move(Vector3.zero, false) end end)
            end)

            -- Start farm timer immediately so we never soft-lock
            farmStartedAt = os.clock()

            mod.Maid:Give(RunService.RenderStepped:Connect(function()
                local char, hum, root = Util.GetCharacter(LocalPlayer)
                if not char or not hum or hum.Health <= 0 or not root then
                    setStatus(cfg.StatusLine, "waiting for character")
                    return
                end
                if manual() then
                    setStatus(cfg.StatusLine, "manual — bot paused")
                    return
                end

                local ready = Bedwars.Resolve()
                local now = os.clock()
                local farmTime = tonumber(cfg.FarmSeconds) or 6
                local pushTime = tonumber(cfg.PushSeconds) or 18
                local myTeam = LocalPlayer:GetAttribute("Team")
                local origin = root.Position

                -- Built-in AutoFight (30 studs) — priority when an enemy is close
                if ready then
                    local hasTarget, target, tdist, didHit = tryMelee(root, hum, 30, 360, true, 0.05, meleeState)
                    if hasTarget and target then
                        -- Chase into melee range
                        local flatTo = Vector3.new(target.Root.Position.X - root.Position.X, 0, target.Root.Position.Z - root.Position.Z)
                        if flatTo.Magnitude > 5 then
                            local dir = nav.steer(root, flatTo, true)
                            if dir then pcall(function() hum:Move(dir, false) end) end
                        else
                            pcall(function() hum:Move(Vector3.zero, false) end)
                        end
                        setStatus(cfg.StatusLine, string.format("fight %s (%.0f)%s", target.Name, tdist or 0, didHit and " · hit" or ""))
                        return
                    end
                end

                local ownBed = nearestTagged(origin, { "bed" }, function(inst)
                    return isOwnBed(inst, myTeam)
                end)
                local searchOrigin = ownBed or homeGen or origin

                local genPos, genDist = nearestTagged(searchOrigin, {
                    "Generator",
                    tostring(myTeam or "") .. "_TeamOreGenerator",
                })
                if not genPos then
                    genPos, genDist = nearestTagged(searchOrigin, { "Generator" })
                end
                if genPos and genDist and genDist > 90 then
                    genPos, genDist = nil, nil
                end
                if genPos and not homeGen then homeGen = genPos end

                local bedPos, bedDist = nearestTagged(origin, { "bed" }, function(inst)
                    return isEnemyBed(inst, myTeam)
                end)

                -- Hard time gate: always leave farm after FarmSeconds from phase start
                if phase == "farm" and farmStartedAt > 0 and (now - farmStartedAt) >= farmTime then
                    phase = "push"
                    pushUntil = now + pushTime
                    forceLeaveGen = true
                end

                if phase == "farm" then
                    if not genPos then
                        if ownBed then
                            walkTo(hum, root, ownBed, 6)
                            setStatus(cfg.StatusLine, string.format("no gen · base · push in %.0fs", math.max(0, farmTime - (now - farmStartedAt))))
                        else
                            pcall(function() hum:Move(Vector3.zero, false) end)
                            setStatus(cfg.StatusLine, "no generator found")
                        end
                        return
                    end
                    local arrived = walkTo(hum, root, genPos, 3.5)
                    if arrived or (genDist and genDist <= 5.5) then
                        pcall(function() hum:Move(Vector3.zero, false) end)
                        local left = math.max(0, farmTime - (now - farmStartedAt))
                        setStatus(cfg.StatusLine, string.format("farming gen · leave in %.0fs", left))
                    else
                        setStatus(cfg.StatusLine, string.format("to gen (%.0f) · leave in %.0fs", genDist or 0, math.max(0, farmTime - (now - farmStartedAt))))
                    end
                else -- push
                    if now >= pushUntil then
                        phase = "farm"
                        farmStartedAt = now
                        forceLeaveGen = false
                        setStatus(cfg.StatusLine, "back to farm")
                        return
                    end
                    local left = pushUntil - now
                    if bedPos then
                        walkTo(hum, root, bedPos, 5)
                        setStatus(cfg.StatusLine, string.format("enemy bed (%.0f) · %.0fs", bedDist or 0, left))
                    else
                        -- No bed yet: walk toward nearest enemy player (scout), not sit at gen
                        local scout, scoutDist
                        for _, entry in ipairs(Util.GetTargets("Players")) do
                            if entry.Root and entry.Humanoid and entry.Humanoid.Health > 0
                                and entry.Player and not Util.IsTeammate(entry.Player) then
                                local d = (entry.Root.Position - origin).Magnitude
                                if not scoutDist or d < scoutDist then
                                    scout, scoutDist = entry.Root.Position, d
                                end
                            end
                        end
                        if scout then
                            walkTo(hum, root, scout, 6)
                            setStatus(cfg.StatusLine, string.format("scout enemy (%.0f) · %.0fs", scoutDist or 0, left))
                        elseif ownBed then
                            -- walk out from bed a bit so we aren't stuck in gen
                            local out = ownBed + Vector3.new(18, 0, 18)
                            walkTo(hum, root, out, 4)
                            setStatus(cfg.StatusLine, string.format("scout · %.0fs", left))
                        else
                            setStatus(cfg.StatusLine, string.format("push · no targets · %.0fs", left))
                        end
                    end
                end
            end))
        end,
    })
    autoPlay:AddSlider({ Label = "Farm Time", Key = "FarmSeconds", Min = 2, Max = 20, Default = 6, Step = 0.5, Suffix = "s", Tip = "Hard timer — always leaves gen after this." })
    autoPlay:AddSlider({ Label = "Push Time", Key = "PushSeconds", Min = 5, Max = 40, Default = 18, Step = 1, Suffix = "s" })
    autoPlay:AddToggle({ Label = "Ledge Jump", Key = "LedgeJump", Default = true })
    autoPlay:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })
    autoPlay:AddLabel("BETA: hard farm timer, built-in 30-stud AutoFight, auto sword, void detours.")
end





    fov = Tabs.World:CreateModule({
        Name = "Field of View",
        Description = "Set how wide your camera sees.",
        OnEnable = function(mod)
            local camera = Workspace.CurrentCamera
            local original = camera and camera.FieldOfView
            mod.Maid:Give(RunService.RenderStepped:Connect(function()
                local cam = Workspace.CurrentCamera
                if cam then
                    cam.FieldOfView = mod.Config.FOV
                end
            end))
            mod.Maid:Give(function()
                local cam = Workspace.CurrentCamera
                if cam and original then
                    cam.FieldOfView = original
                end
            end)
        end,
    })
    fov:AddSlider({ Label = "Field of View", Key = "FOV", Min = 30, Max = 120, Default = 100, Step = 1, Suffix = "°" })

    -- Infinite Zoom
    local zoom
    zoom = Tabs.World:CreateModule({
        Name = "Infinite Zoom",
        Description = "Zoom the camera out much further than normal.",
        OnEnable = function(mod)
            local original = LocalPlayer.CameraMaxZoomDistance
            local function apply()
                LocalPlayer.CameraMaxZoomDistance = mod.Config.MaxZoom
            end
            apply()
            mod.Maid:Give(LocalPlayer:GetPropertyChangedSignal("CameraMaxZoomDistance"):Connect(function()
                if LocalPlayer.CameraMaxZoomDistance ~= mod.Config.MaxZoom then
                    apply()
                end
            end))
            mod.Maid:Give(function()
                LocalPlayer.CameraMaxZoomDistance = original
            end)
        end,
    })
    zoom:AddSlider({
        Label = "Max Distance", Key = "MaxZoom", Min = 40, Max = 1000, Default = 400, Step = 10, Suffix = " studs",
        Callback = function(value)
            if zoom.Enabled then
                LocalPlayer.CameraMaxZoomDistance = value
            end
        end,
    })

    -- Freecam
    local freecam
    freecam = Tabs.World:CreateModule({
        Name = "Freecam",
        Description = "Fly the camera around while your character stays put.",
        OnEnable = function(mod)
            local camera = Workspace.CurrentCamera
            assert(camera, "no camera")
            local start = camera.CFrame
            local yaw, pitch = 0, 0
            do
                local x, y = start:ToOrientation()
                pitch, yaw = x, y
            end
            local position = start.Position
            local looking = false

            -- stop the character from walking around while the camera moves
            local controls
            pcall(function()
                controls = require(LocalPlayer.PlayerScripts:WaitForChild("PlayerModule", 2)):GetControls()
                controls:Disable()
            end)

            mod.Maid:Give(UserInputService.InputBegan:Connect(function(input, processed)
                if input.UserInputType == Enum.UserInputType.MouseButton2 then
                    looking = true
                    UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
                end
            end))
            mod.Maid:Give(UserInputService.InputEnded:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton2 then
                    looking = false
                    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
                end
            end))
            mod.Maid:Give(UserInputService.InputChanged:Connect(function(input)
                if looking and input.UserInputType == Enum.UserInputType.MouseMovement then
                    yaw = yaw - input.Delta.X * 0.004
                    pitch = math.clamp(pitch - input.Delta.Y * 0.004, -1.5, 1.5)
                end
            end))

            mod.Maid:Give(RunService.RenderStepped:Connect(function(dt)
                local cam = Workspace.CurrentCamera
                if not cam then
                    return
                end
                cam.CameraType = Enum.CameraType.Scriptable
                local rotation = CFrame.fromOrientation(pitch, yaw, 0)
                local move = Vector3.new(0, 0, 0)
                if not UserInputService:GetFocusedTextBox() then
                    if UserInputService:IsKeyDown(Enum.KeyCode.W) then move = move + rotation.LookVector end
                    if UserInputService:IsKeyDown(Enum.KeyCode.S) then move = move - rotation.LookVector end
                    if UserInputService:IsKeyDown(Enum.KeyCode.D) then move = move + rotation.RightVector end
                    if UserInputService:IsKeyDown(Enum.KeyCode.A) then move = move - rotation.RightVector end
                    if UserInputService:IsKeyDown(Enum.KeyCode.E) or UserInputService:IsKeyDown(Enum.KeyCode.Space) then
                        move = move + Vector3.new(0, 1, 0)
                    end
                    if UserInputService:IsKeyDown(Enum.KeyCode.Q) or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
                        move = move - Vector3.new(0, 1, 0)
                    end
                end
                local speed = mod.Config.Speed
                if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
                    speed = speed * 3
                end
                if move.Magnitude > 0 then
                    position = position + move.Unit * speed * dt
                end
                cam.CFrame = CFrame.new(position) * rotation
            end))

            mod.Maid:Give(function()
                looking = false
                pcall(function()
                    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
                end)
                if controls then
                    pcall(function() controls:Enable() end)
                end
                local cam = Workspace.CurrentCamera
                if cam then
                    cam.CameraType = Enum.CameraType.Custom
                    local _, hum = Util.GetCharacter(LocalPlayer)
                    if hum then
                        cam.CameraSubject = hum
                    end
                end
            end)
        end,
    })
    freecam:AddSlider({ Label = "Speed", Key = "Speed", Min = 5, Max = 150, Default = 40, Step = 1, Suffix = " studs/s", Tip = "Hold Shift for three times this speed." })
    freecam:AddNote("W A S D to move, Space / E up, Ctrl / Q down. Hold the right mouse button to look around.")

    -- Xray
    local xray
    local touched = setmetatable({}, { __mode = "k" })
    xray = Tabs.World:CreateModule({
        Name = "Xray",
        Description = "See through walls and the map by making them see-through.",
        OnEnable = function(mod)
            local function eligible(inst)
                if not inst:IsA("BasePart") or inst.Transparency >= 0.95 or not inst.CanCollide then
                    return false
                end
                -- leave players and NPCs alone
                local model = inst:FindFirstAncestorOfClass("Model")
                if model and (Players:GetPlayerFromCharacter(model) or model:FindFirstChildOfClass("Humanoid")) then
                    return false
                end
                return true
            end
            local function apply(inst)
                if eligible(inst) then
                    touched[inst] = true
                    inst.LocalTransparencyModifier = mod.Config.Opacity
                end
            end
            mod.Maid:Give(task.spawn(function()
                local count = 0
                for _, inst in ipairs(Workspace:GetDescendants()) do
                    if not mod.Enabled then
                        return
                    end
                    apply(inst)
                    count = count + 1
                    if count % 1500 == 0 then
                        task.wait()
                    end
                end
            end))
            mod.Maid:Give(Workspace.DescendantAdded:Connect(function(inst)
                task.defer(apply, inst)
            end))
            mod.Maid:Give(function()
                for inst in pairs(touched) do
                    pcall(function()
                        inst.LocalTransparencyModifier = 0
                    end)
                end
                touched = setmetatable({}, { __mode = "k" })
            end)
        end,
    })
    xray:AddSlider({
        Label = "See-Through", Key = "Opacity", Min = 0.1, Max = 0.95, Default = 0.7, Step = 0.05,
        Tip = "Higher is more see-through.",
        Callback = function(value)
            if xray.Enabled then
                for inst in pairs(touched) do
                    pcall(function()
                        inst.LocalTransparencyModifier = value
                    end)
                end
            end
        end,
    })
    xray:AddNote("On big maps this can lower your frame rate.")
end

-- ====================== MODULE: INVENTORY ESP + NAMETAGS ======================
-- Inventory ESP: a side panel listing what every enemy is carrying (Bedwars keeps each player's
-- inventory readable in ReplicatedStorage.Inventories). NameTags: overhead tags with name, health,
-- distance, kit and the item in hand + armor. Both only read data the game already replicates.
do
    local ReplicatedStorage = service("ReplicatedStorage")

    local TEAM_COLORS = {
        [1] = Color3.fromRGB(80, 140, 255),   -- blue
        [2] = Color3.fromRGB(255, 150, 60),   -- orange
        [3] = Color3.fromRGB(255, 110, 180),  -- pink
        [4] = Color3.fromRGB(255, 225, 80),   -- yellow
        [5] = Color3.fromRGB(160, 110, 70),   -- brown
        [6] = Color3.fromRGB(235, 235, 245),  -- white
        [7] = Color3.fromRGB(70, 215, 230),   -- cyan
        [8] = Color3.fromRGB(170, 110, 255),  -- purple
    }
    local PLACEHOLDER_ICON = "rbxassetid://6031075931"

    local function teamColorOrNil(plr)
        local id = tonumber(plr:GetAttribute("Team"))
        if id and TEAM_COLORS[id] then
            return TEAM_COLORS[id]
        end
        local ok, color = pcall(function()
            return plr.Team and plr.TeamColor.Color
        end)
        if ok and color then
            return color
        end
        return nil
    end

    local function teamColor(plr)
        return teamColorOrNil(plr) or Theme.AccentLight
    end

    local function sameTeam(plr)
        local mine, theirs = LocalPlayer:GetAttribute("Team"), plr:GetAttribute("Team")
        if mine ~= nil and theirs ~= nil then
            return mine == theirs
        end
        return Util.IsTeammate(plr)
    end

    local function shortCount(n)
        n = tonumber(n) or 0
        if n >= 1000 then
            return string.format("%.1fk", n / 1000)
        end
        return tostring(math.floor(n))
    end

    local function distanceTo(plr)
        local _, _, mine = Util.GetCharacter(LocalPlayer)
        local _, _, theirs = Util.GetCharacter(plr)
        if mine and theirs then
            return (mine.Position - theirs.Position).Magnitude
        end
        return nil
    end

    local function kitOf(plr)
        local raw = plr:GetAttribute("PlayingAsKits")
        if type(raw) == "string" then
            local kit = string.match(raw, "[%w_]+")
            if kit and kit ~= "none" then
                return kit
            end
        end
        return nil
    end

    local function kitIcon(kit)
        if not kit then
            return ""
        end
        if Bedwars.KitImage then
            local ok, image = pcall(Bedwars.KitImage, kit)
            if ok and type(image) == "string" and image ~= "" then
                return image
            end
        end
        local meta = Bedwars.KitMeta and Bedwars.KitMeta[kit]
        return meta and meta.renderImage or ""
    end

    local function itemIcon(itemType)
        local image = Bedwars.GetItemImage and Bedwars.GetItemImage(itemType) or ""
        if image == "" then
            return PLACEHOLDER_ICON
        end
        return image
    end

    -- Sorts an item into a group so the panel can filter and order it
    local function classify(name)
        local n = string.lower(name)
        if n:find("chestplate") or n:find("helmet") or n:find("boots") or n:find("leggings") then
            return "Armor", 3
        end
        if n:find("sword") or n:find("bow") or n:find("dagger") or n:find("katana") or n:find("scythe") or n:find("spear") then
            return "Weapons", 1
        end
        if n:find("pickaxe") or n:find("axe") or n:find("shears") or n:find("rod") or n:find("drill") then
            return "Tools", 2
        end
        if n == "iron" or n == "diamond" or n == "emerald" or n == "gold" then
            return "Resources", 4
        end
        local meta = Bedwars.ItemMeta and Bedwars.ItemMeta[name]
        if (meta and meta.block) or n:find("wool") or n:find("clay") or n:find("plank") or n:find("glass")
            or n:find("obsidian") or n:find("ceramic") or n:find("stone") then
            return "Blocks", 5
        end
        return "Other", 6
    end

    local GROUP_KEYS = {
        Weapons = "ShowWeapons", Armor = "ShowArmor", Tools = "ShowTools",
        Resources = "ShowResources", Blocks = "ShowBlocks", Other = "ShowOther",
    }

    -- ====================== INVENTORY ESP ======================
    -- CatVape Inventory Overlay data path: InventoryUtil.getInventory(player)
    local invEsp
    local invGui          -- dedicated ScreenGui (not nested under main UI)
    local panel
    local statusLabel
    local rows = {}
    local COLUMNS = 6
    local placePanel      -- defined below ensureGui
    local cachedUtil

    local function cellSize()
        return (invEsp and invEsp.Config and invEsp.Config.Size) or 28
    end

    local function panelWidth()
        return COLUMNS * cellSize() + (COLUMNS - 1) * 3 + 20
    end

    local function resolveInventoryUtil()
        if cachedUtil then
            return cachedUtil
        end
        local util
        local function try(path)
            local ok, mod = pcall(function()
                if setthreadidentity then
                    pcall(setthreadidentity, 8)
                end
                return require(path)
            end)
            if ok and mod then
                return mod.InventoryUtil or mod
            end
            return nil
        end
        util = try(ReplicatedStorage.TS.inventory["inventory-util"])
        if not util then
            local ts = ReplicatedStorage:FindFirstChild("TS")
            local inv = ts and ts:FindFirstChild("inventory")
            local mod = inv and inv:FindFirstChild("inventory-util")
            if mod then
                util = try(mod)
            end
        end
        if util and type(util.getInventory) == "function" then
            cachedUtil = util
        end
        return util
    end

    -- Exact CatVape Collect → flat list of {name, amount}
    local function collectCatVape(plr)
        local list = {}
        local util = resolveInventoryUtil()
        if not util or type(util.getInventory) ~= "function" then
            return list
        end
        if setthreadidentity then
            pcall(setthreadidentity, 8)
        end
        local ok, inv = pcall(util.getInventory, plr)
        if not ok or type(inv) ~= "table" then
            return list
        end
        local worn = {}
        if type(inv.armor) == "table" then
            for _, v in pairs(inv.armor) do
                if type(v) == "table" and v.tool then
                    worn[v.tool] = true
                end
            end
        end
        if type(inv.backpack) == "table" and inv.backpack.tool then
            worn[inv.backpack.tool] = true
        end
        local items = {}
        if type(inv.items) == "table" then
            for _, v in pairs(inv.items) do
                if type(v) == "table" and (v.tool or v.itemType) and not (v.tool and worn[v.tool]) then
                    items[#items + 1] = v
                end
            end
        end
        table.sort(items, function(a, b)
            local at, bt = a.addedToBackpackTime or 0, b.addedToBackpackTime or 0
            if at ~= bt then return at < bt end
            return tostring(a.itemType or "") < tostring(b.itemType or "")
        end)
        local cfg = invEsp.Config
        local function add(name, amount)
            if not name or name == "" then return end
            amount = tonumber(amount) or 1
            if amount <= 0 then return end
            local group = select(1, classify(tostring(name)))
            local key = GROUP_KEYS[group]
            if key and cfg[key] == false then return end
            list[#list + 1] = { name = tostring(name), amount = amount }
        end
        -- armor first
        if type(inv.armor) == "table" then
            for _, v in pairs(inv.armor) do
                if type(v) == "table" then
                    add(v.itemType or (v.tool and v.tool.Name), v.amount or 1)
                end
            end
        end
        for _, v in ipairs(items) do
            add(v.itemType or (v.tool and v.tool.Name), v.amount or 1)
        end
        return list
    end

    local function collectFolder(plr)
        local list = {}
        local root = ReplicatedStorage:FindFirstChild("Inventories")
        if not root then return list end
        local folder = root:FindFirstChild(plr.Name) or root:FindFirstChild(tostring(plr.UserId))
        if not folder then return list end
        local cfg = invEsp.Config
        local function walk(node, depth)
            if not node or depth > 5 then return end
            for _, child in ipairs(node:GetChildren()) do
                local amount = child:GetAttribute("Amount") or child:GetAttribute("amount")
                if amount == nil and child:IsA("ValueBase") then amount = child.Value end
                if amount ~= nil or child:IsA("Tool") then
                    local group = select(1, classify(child.Name))
                    local key = GROUP_KEYS[group]
                    if not (key and cfg[key] == false) then
                        list[#list + 1] = { name = child.Name, amount = tonumber(amount) or 1 }
                    end
                end
                if #child:GetChildren() > 0 then
                    walk(child, depth + 1)
                end
            end
        end
        walk(folder, 0)
        if cfg.Personal then
            walk(root:FindFirstChild(plr.Name .. "_personal"), 0)
        end
        return list
    end

    local function collectCharacter(plr)
        local list = {}
        local char = plr.Character
        if not char then return list end
        local cfg = invEsp.Config
        local function add(name)
            if not name then return end
            local group = select(1, classify(name))
            local key = GROUP_KEYS[group]
            if key and cfg[key] == false then return end
            list[#list + 1] = { name = name, amount = 1 }
        end
        local hand = char:FindFirstChild("HandInvItem")
        if hand and hand.Value then add(hand.Value.Name) end
        for slot = 0, 3 do
            local a = char:FindFirstChild("ArmorInvItem_" .. slot)
            if a and a.Value then add(a.Value.Name) end
        end
        return list
    end

    local function collect(plr)
        -- Merge all sources (Util / folder / character) so something always shows
        local okA, list = pcall(collectCatVape, plr)
        local okB, folderList = pcall(collectFolder, plr)
        local okC, charList = pcall(collectCharacter, plr)
        list = okA and list or {}
        folderList = okB and folderList or {}
        charList = okC and charList or {}
        local seen = {}
        local merged = {}
        for _, src in ipairs({ list, folderList, charList }) do
            for _, it in ipairs(src) do
                local key = it.name
                if not seen[key] then
                    seen[key] = true
                    merged[#merged + 1] = it
                end
            end
        end
        local parts = {}
        for _, it in ipairs(merged) do
            parts[#parts + 1] = it.name .. ":" .. it.amount
        end
        return merged, table.concat(parts, ",")
    end

    local function destroyInvGui()
        for plr in pairs(rows) do
            local r = rows[plr]
            if r and r.frame then pcall(function() r.frame:Destroy() end) end
            rows[plr] = nil
        end
        if invGui then
            pcall(function() invGui:Destroy() end)
            invGui = nil
            panel = nil
            statusLabel = nil
        end
    end

    local function ensureGui()
        if Nova.Unloaded then
            return nil
        end
        if invGui and invGui.Parent then
            return panel
        end
        destroyInvGui()
        invGui = Instance.new("ScreenGui")
        invGui.Name = "NovaInventoryESP"
        invGui.ResetOnSpawn = false
        invGui.IgnoreGuiInset = true
        invGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        invGui.DisplayOrder = 99999
        pcall(function()
            invGui.Parent = getGuiParent()
        end)
        if not invGui.Parent then
            invGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
        end

        panel = Instance.new("Frame")
        panel.Name = "Panel"
        panel.BackgroundTransparency = 1
        panel.AutomaticSize = Enum.AutomaticSize.Y
        panel.Size = UDim2.fromOffset(panelWidth(), 0)
        panel.Parent = invGui
        local layout = Instance.new("UIListLayout")
        layout.Padding = UDim.new(0, 6)
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
        layout.Parent = panel

        statusLabel = Instance.new("TextLabel")
        statusLabel.Name = "Status"
        statusLabel.BackgroundColor3 = Theme.Panel
        statusLabel.BackgroundTransparency = 0.2
        statusLabel.Size = UDim2.new(1, 0, 0, 22)
        statusLabel.Font = Enum.Font.GothamBold
        statusLabel.TextSize = 12
        statusLabel.TextColor3 = Theme.Text
        statusLabel.Text = "Inventory ESP…"
        statusLabel.LayoutOrder = 0
        statusLabel.Parent = panel
        local sc = Instance.new("UICorner")
        sc.CornerRadius = UDim.new(0, 6)
        sc.Parent = statusLabel

        placePanel()
        return panel
    end

    placePanel = function()
        if not panel then return end
        local left = invEsp and invEsp.Config and invEsp.Config.Side == "Left"
        panel.AnchorPoint = Vector2.new(left and 0 or 1, 0)
        panel.Position = left and UDim2.new(0, 14, 0, 100) or UDim2.new(1, -14, 0, 100)
        panel.Size = UDim2.fromOffset(panelWidth(), 0)
    end

    local function removeRow(plr)
        local row = rows[plr]
        if row then
            pcall(function() row.frame:Destroy() end)
            rows[plr] = nil
        end
    end

    local function buildRow(plr)
        local size = cellSize()
        local frame = Instance.new("Frame")
        frame.Name = plr.Name
        frame.BackgroundColor3 = Theme.Panel
        frame.BackgroundTransparency = 0.12
        frame.BorderSizePixel = 0
        frame.Size = UDim2.new(1, 0, 0, 0)
        frame.AutomaticSize = Enum.AutomaticSize.Y
        frame.Parent = panel
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 8)
        corner.Parent = frame
        local pad = Instance.new("UIPadding")
        pad.PaddingLeft = UDim.new(0, 8)
        pad.PaddingRight = UDim.new(0, 8)
        pad.PaddingTop = UDim.new(0, 6)
        pad.PaddingBottom = UDim.new(0, 8)
        pad.Parent = frame
        local list = Instance.new("UIListLayout")
        list.Padding = UDim.new(0, 5)
        list.SortOrder = Enum.SortOrder.LayoutOrder
        list.Parent = frame

        local header = Instance.new("Frame")
        header.BackgroundTransparency = 1
        header.Size = UDim2.new(1, 0, 0, 22)
        header.LayoutOrder = 1
        header.Parent = frame

        local avatar = Instance.new("ImageLabel")
        avatar.Size = UDim2.fromOffset(22, 22)
        avatar.BackgroundColor3 = Theme.Card
        avatar.Image = "rbxthumb://type=AvatarHeadShot&id=" .. plr.UserId .. "&w=48&h=48"
        avatar.Parent = header
        local ac = Instance.new("UICorner")
        ac.CornerRadius = UDim.new(1, 0)
        ac.Parent = avatar

        local name = Instance.new("TextLabel")
        name.BackgroundTransparency = 1
        name.Position = UDim2.fromOffset(28, 0)
        name.Size = UDim2.new(1, -30, 1, 0)
        name.Font = Enum.Font.GothamBold
        name.TextSize = 13
        name.TextXAlignment = Enum.TextXAlignment.Left
        name.TextColor3 = Theme.Text
        name.TextTruncate = Enum.TextTruncate.AtEnd
        name.Text = plr.DisplayName
        name.Parent = header

        local items = Instance.new("Frame")
        items.Name = "Items"
        items.BackgroundTransparency = 1
        items.Size = UDim2.new(1, 0, 0, 0)
        items.AutomaticSize = Enum.AutomaticSize.Y
        items.LayoutOrder = 2
        items.Parent = frame
        local grid = Instance.new("UIGridLayout")
        grid.CellSize = UDim2.fromOffset(size, size)
        grid.CellPadding = UDim2.fromOffset(3, 3)
        grid.SortOrder = Enum.SortOrder.LayoutOrder
        grid.Parent = items

        return { frame = frame, name = name, items = items, grid = grid, signature = nil }
    end

    local function fillItems(row, list)
        for _, child in ipairs(row.items:GetChildren()) do
            if child:IsA("GuiObject") then
                child:Destroy()
            end
        end
        local size = cellSize()
        row.grid.CellSize = UDim2.fromOffset(size, size)
        for index, item in ipairs(list) do
            local cell = Instance.new("Frame")
            cell.LayoutOrder = index
            cell.BackgroundColor3 = Theme.Card
            cell.BackgroundTransparency = 0.1
            cell.BorderSizePixel = 0
            cell.Parent = row.items
            local cc = Instance.new("UICorner")
            cc.CornerRadius = UDim.new(0, 5)
            cc.Parent = cell
            local icon = Instance.new("ImageLabel")
            icon.BackgroundTransparency = 1
            icon.AnchorPoint = Vector2.new(0.5, 0.5)
            icon.Position = UDim2.fromScale(0.5, 0.5)
            icon.Size = UDim2.fromScale(0.82, 0.82)
            icon.ScaleType = Enum.ScaleType.Fit
            icon.Image = itemIcon(item.name)
            icon.Parent = cell
            if (item.amount or 1) > 1 then
                local amt = Instance.new("TextLabel")
                amt.BackgroundTransparency = 1
                amt.AnchorPoint = Vector2.new(1, 1)
                amt.Position = UDim2.new(1, -2, 1, -1)
                amt.Size = UDim2.new(1, -2, 0, 12)
                amt.Font = Enum.Font.GothamBold
                amt.TextSize = 11
                amt.TextColor3 = Color3.new(1, 1, 1)
                amt.TextStrokeTransparency = 0.5
                amt.TextXAlignment = Enum.TextXAlignment.Right
                amt.Text = shortCount(item.amount)
                amt.ZIndex = 2
                amt.Parent = cell
            end
        end
    end

    local function refreshPanel()
        ensureGui()
        local cfg = invEsp.Config
        local wanted = {}
        local candidates = {}
        local totalItems = 0
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and not (cfg.TeamCheck and sameTeam(plr)) then
                local d = distanceTo(plr) or 9e9
                local limit = cfg.MaxDistance or 0
                if limit <= 0 or d <= limit then
                    candidates[#candidates + 1] = { plr = plr, distance = d }
                end
            end
        end
        table.sort(candidates, function(a, b) return a.distance < b.distance end)

        for index, entry in ipairs(candidates) do
            if index > 12 then break end
            local plr = entry.plr
            local list, signature = collect(plr)
            totalItems = totalItems + #list
            wanted[plr] = true
            local row = rows[plr] or buildRow(plr)
            rows[plr] = row
            row.frame.LayoutOrder = index
            row.frame.Visible = true
            local color = teamColor(plr)
            row.name.TextColor3 = color
            local dist = entry.distance < 1e8 and string.format(" · %dm", math.floor(entry.distance)) or ""
            row.name.Text = string.format("%s%s · %d", plr.DisplayName, dist, #list)
            local key = (signature or "") .. "|" .. tostring(cellSize())
            if row.signature ~= key then
                row.signature = key
                fillItems(row, list)
            end
        end
        for plr in pairs(rows) do
            if not wanted[plr] then
                removeRow(plr)
            end
        end
        if statusLabel then
            local utilOk = resolveInventoryUtil() ~= nil
            statusLabel.Text = string.format(
                "Inv ESP · %d players · %d items · %s",
                #candidates,
                totalItems,
                utilOk and "Util OK" or "Util miss (folder/char)"
            )
        end
        placePanel()
    end

    invEsp = Tabs.Render:CreateModule({
        Name = "Inventory ESP",
        Description = "Side panel of enemy inventories (CatVape InventoryUtil path).",
        OnEnable = function(mod)
            pcall(Bedwars.ResolveExtras)
            pcall(Bedwars.Resolve)
            local alive = true
            ensureGui()
            -- Module disable + full Unload both must kill the ScreenGui (it is NOT under UI.Gui)
            local function shutdown()
                alive = false
                destroyInvGui()
            end
            mod.Maid:Give(shutdown)
            Nova.Maid:Give(shutdown)
            mod.Maid:Give(task.spawn(function()
                while alive and mod.Enabled and not Nova.Unloaded do
                    local ok, err = pcall(refreshPanel)
                    if not ok then
                        -- show the failure on the panel instead of silently drawing nothing
                        pcall(function()
                            ensureGui()
                            if statusLabel then
                                statusLabel.Text = "Inv ESP error: " .. string.sub(tostring(err), 1, 70)
                            end
                        end)
                    end
                    task.wait(0.3)
                end
                destroyInvGui()
            end))
        end,
    })

    invEsp:AddSection("Display")
    invEsp:AddOption({
        Label = "Side", Key = "Side", Options = { "Right", "Left" }, Default = "Right",
        Callback = function() pcall(placePanel) end,
    })
    invEsp:AddSlider({
        Label = "Icon Size", Key = "Size", Min = 20, Max = 44, Default = 28, Step = 2, Suffix = " px",
        Callback = function() pcall(placePanel) end,
    })
    invEsp:AddToggle({ Label = "Personal Chest", Key = "Personal", Default = false })
    invEsp:AddSection("Players")
    invEsp:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = false })
    invEsp:AddSlider({
        Label = "Max Distance", Key = "MaxDistance", Min = 0, Max = 1000, Default = 0, Step = 25, Suffix = " studs",
        Tip = "0 = unlimited",
    })
    invEsp:AddSection("Items")
    invEsp:AddToggle({ Label = "Weapons", Key = "ShowWeapons", Default = true })
    invEsp:AddToggle({ Label = "Armor", Key = "ShowArmor", Default = true })
    invEsp:AddToggle({ Label = "Tools", Key = "ShowTools", Default = true })
    invEsp:AddToggle({ Label = "Resources", Key = "ShowResources", Default = true })
    invEsp:AddToggle({ Label = "Blocks", Key = "ShowBlocks", Default = false })
    invEsp:AddToggle({ Label = "Other", Key = "ShowOther", Default = true })
    invEsp:AddLabel("Uses InventoryUtil.getInventory like CatVape. Status line shows Util OK/miss.")


    -- ====================== NAMETAGS ======================
    local CollectionService = service("CollectionService")

    local nameTags
    local tagFolder
    local tags = {}               -- entity key (Player or NPC model) -> tag
    local drawings = {}           -- entity key -> { Text, BG, head } (Stream Proof mode)
    local hiddenDefaults = {}     -- humanoid / billboard -> original value (game's own tags)
    local rankCache, rankRetry = {}, {}
    local enchantMap
    local ROMAN = { "I", "II", "III", "IV", "V" }

    local FONT_NAMES = {
        "Gotham", "GothamMedium", "GothamBold", "GothamBlack", "SourceSans", "SourceSansBold", "SourceSansSemibold",
        "Ubuntu", "Roboto", "RobotoMono", "Code", "Oswald", "Nunito", "Michroma", "Bangers", "FredokaOne",
        "Merriweather", "PatrickHand", "Highway", "SciFi", "Fantasy", "Arcade", "Cartoon",
    }
    local COLOR_NAMES = { "Purple", "Blue", "Cyan", "Green", "Lime", "Yellow", "Orange", "Red", "Pink", "White" }
    local COLORS = {
        Purple = Color3.fromRGB(152, 98, 255), Blue = Color3.fromRGB(86, 148, 255), Cyan = Color3.fromRGB(64, 208, 232),
        Green = Color3.fromRGB(84, 214, 120), Lime = Color3.fromRGB(170, 230, 70), Yellow = Color3.fromRGB(255, 225, 80),
        Orange = Color3.fromRGB(255, 156, 80), Red = Color3.fromRGB(255, 80, 96), Pink = Color3.fromRGB(255, 104, 176),
        White = Color3.fromRGB(240, 240, 250),
    }
    local POTIONS = {
        { name = "PotSerpent", attr = "StatusEffect_serpents_touch_potion", item = "serpents_touch_potion", timed = true },
        { name = "PotFury", attr = "StatusEffect_fury_potion", item = "fury_potion", timed = true },
        { name = "PotInvis", attr = "StatusEffect_invisibility", item = "invisibility_potion", timed = true },
        { name = "PotJump", attr = "JumpBoost", item = "jump_potion", timed = false },
        { name = "PotPie", attr = "SpeedPieBuff", item = "speed_pie", timed = false },
    }
    local DEVICE_ICONS = { Mobile = "📱", PC = "🖥", Controller = "🎮" }

    local function cfgOf()
        return nameTags.Config
    end

    local function textSize()
        return math.max(1, math.floor(14 * (cfgOf().Scale or 1) + 0.5))
    end

    local function iconSize()
        return math.max(6, math.floor(24 * (cfgOf().Scale or 1) + 0.5))
    end

    local function hex(color)
        return string.format("#%02x%02x%02x", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
    end

    local function escape(text)
        local safe = tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        return safe
    end

    -- Health ------------------------------------------------------------------------------------
    local function shieldOf(char)
        local total = char:GetAttribute("TotalShield")
        if type(total) == "number" then
            return math.max(total, 0)
        end
        local sum = 0
        pcall(function()
            for name, value in pairs(char:GetAttributes()) do
                if string.find(name, "Shield", 1, true) and type(value) == "number" and value > 0 then
                    sum = sum + value
                end
            end
        end)
        return sum
    end

    local function healthOf(char, hum)
        local value = char:GetAttribute("Health")
        if type(value) ~= "number" then
            value = hum and hum.Health or 100
        end
        local maxValue = char:GetAttribute("MaxHealth")
        if type(maxValue) ~= "number" or maxValue <= 0 then
            maxValue = hum and hum.MaxHealth or 100
        end
        return math.max(0, value), math.max(1, maxValue), shieldOf(char)
    end

    local function healthColor(ratio)
        local cfg = cfgOf()
        if cfg.CustomHealth then
            local full = COLORS[cfg.FullColor] or COLORS.Green
            local mid = COLORS[cfg.MidColor] or COLORS.Yellow
            local low = COLORS[cfg.LowColor] or COLORS.Red
            if ratio >= 0.5 then
                return full:Lerp(mid, (1 - ratio) / 0.5)
            end
            return mid:Lerp(low, (0.5 - ratio) / 0.5)
        end
        if ratio >= 0.7 then
            return Color3.fromRGB(0, 255, 0)
        elseif ratio >= 0.3 then
            return Color3.fromRGB(255, 255, 0)
        elseif ratio >= 0.1 then
            return Color3.fromRGB(255, 165, 0)
        end
        return Color3.fromRGB(255, 0, 0)
    end

    -- Entities --------------------------------------------------------------------------------
    local function bossName(model)
        if model:GetAttribute("BossType") == "Bhaa" or string.lower(model.Name) == "bhaa"
            or model:FindFirstChild("BhaaModel") or model:FindFirstChild("BhaaHead") then
            return "Bhaa"
        end
        if model.Name == "Titan" then
            return "Titan"
        end
        return nil
    end

    local function listEntities()
        local cfg = cfgOf()
        local list = {}
        if cfg.Players ~= false then
            local players = Players
            if not players then
                players = service("Players")
            end
            for _, plr in ipairs(players:GetPlayers()) do
                if plr ~= LocalPlayer then
                    list[#list + 1] = { key = plr, plr = plr }
                end
            end
        end
        if cfg.NPCs or cfg.Bosses then
            for _, model in ipairs(CollectionService:GetTagged("entity")) do
                if model.Parent and model:IsA("Model") and not Players:GetPlayerFromCharacter(model) then
                    local boss = bossName(model)
                    if (boss and cfg.Bosses) or (not boss and cfg.NPCs) then
                        list[#list + 1] = { key = model, model = model, boss = boss }
                    end
                end
            end
        end
        return list
    end

    local function parts(entry)
        if entry.plr then
            local char, hum, root = Util.GetCharacter(entry.plr)
            return char, hum, root, char and (char:FindFirstChild("Head") or root)
        end
        local model = entry.model
        local hum = model:FindFirstChildOfClass("Humanoid")
        local root = model.PrimaryPart or model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
        return model, hum, root, model:FindFirstChild("Head") or root
    end

    local function nameOf(entry)
        if entry.plr then
            return cfgOf().DisplayName == false and entry.plr.Name or entry.plr.DisplayName
        end
        return entry.boss or entry.model.Name
    end

    local function nameColor(entry)
        local cfg = cfgOf()
        if entry.plr and cfg.TeamColors ~= false then
            local color = teamColorOrNil(entry.plr)
            if color then
                return color
            end
        end
        return COLORS[cfg.PlayerColor] or COLORS.Purple
    end

    -- Inventory-derived data ---------------------------------------------------------------------
    local function inventoriesFolder()
        return ReplicatedStorage:FindFirstChild("Inventories")
    end

    -- itemType -> amount for a player. Reads the game's InventoryUtil first (same source as the
    -- Inventory ESP panel), falls back to ReplicatedStorage.Inventories. Cached for a moment.
    local countsCache = setmetatable({}, { __mode = "k" })
    local function countsOf(plr)
        local cached = countsCache[plr]
        if cached and os.clock() - cached.t < 0.25 then
            return cached.v
        end
        local counts = {}
        pcall(function()
            local util = resolveInventoryUtil()
            if util and type(util.getInventory) == "function" then
                if setthreadidentity then
                    pcall(setthreadidentity, 8)
                end
                local inv = util.getInventory(plr)
                if type(inv) == "table" and type(inv.items) == "table" then
                    for _, item in pairs(inv.items) do
                        if type(item) == "table" and item.itemType then
                            counts[item.itemType] = (counts[item.itemType] or 0) + (tonumber(item.amount) or 1)
                        end
                    end
                end
            end
        end)
        if next(counts) == nil then
            pcall(function()
                local folder = inventoriesFolder()
                local inventory = folder and (folder:FindFirstChild(plr.Name) or folder:FindFirstChild(tostring(plr.UserId)))
                if inventory then
                    for _, child in ipairs(inventory:GetChildren()) do
                        local amount = child:GetAttribute("Amount") or child:GetAttribute("amount")
                        if amount == nil and child:IsA("ValueBase") then
                            amount = child.Value
                        end
                        counts[child.Name] = tonumber(amount) or 1
                    end
                end
            end)
        end
        countsCache[plr] = { v = counts, t = os.clock() }
        return counts
    end

    local function tinkerImage(level)
        local ok, image = pcall(function()
            local ids = require(ReplicatedStorage.TS.image["image-id"]).BedwarsImageId
            return ({ ids.WOOD_TINKER_MECH, ids.IRON_TINKER_MECH, ids.DIAMOND_TINKER_MECH, ids.EMERALD_TINKER_MECH, ids.VOID_TINKER_MECH })[level]
        end)
        return ok and image or ""
    end

    -- Held item + armor from the character's ObjectValues. Armor is sorted by name so the
    -- helmet / chestplate / boots slots line up whatever order the game lists them in.
    local function gearOf(char)
        local gear = { hand = nil, Helmet = nil, Chestplate = nil, Boots = nil }
        local hand = char:FindFirstChild("HandInvItem")
        local held = hand and hand.Value
        if held and held.Name ~= "" then
            gear.hand = held.Name
        end
        local fallback = { "Helmet", "Chestplate", "Boots" }
        for slot = 0, 2 do
            local armor = char:FindFirstChild("ArmorInvItem_" .. slot)
            local piece = armor and armor.Value
            if piece and piece.Name ~= "" then
                local lowered = string.lower(piece.Name)
                local place = (string.find(lowered, "helmet", 1, true) and "Helmet")
                    or (string.find(lowered, "chestplate", 1, true) and "Chestplate")
                    or ((string.find(lowered, "boots", 1, true) or string.find(lowered, "leggings", 1, true)) and "Boots")
                    or fallback[slot + 1]
                gear[place] = piece.Name
            end
        end
        return gear
    end

    local function enchantImage(char)
        if not enchantMap then
            enchantMap = {}
            pcall(function()
                local meta = require(ReplicatedStorage.TS.enchant["enchant-meta"])
                for _, group in pairs({ meta.EnchantMeta, meta.ToolEnchantMeta, meta.ArmorEnchantMeta }) do
                    if type(group) == "table" then
                        for _, entry in pairs(group) do
                            if type(entry) == "table" and entry.statusEffect and entry.image then
                                enchantMap[entry.statusEffect] = entry.image
                            end
                        end
                    end
                end
            end)
        end
        local found = ""
        pcall(function()
            for attr, value in pairs(char:GetAttributes()) do
                if string.sub(attr, 1, 13) == "StatusEffect_" and type(value) == "number" and value < 0 then
                    local effect = string.sub(attr, 14)
                    if not string.find(effect, "stacks", 1, true) then
                        local image = enchantMap[effect]
                        if image and image ~= "" then
                            found = image
                            return
                        end
                    end
                end
            end
        end)
        return found
    end

    local function potionActive(char, def)
        local value = char:GetAttribute(def.attr)
        if value == nil then
            return false
        end
        if def.timed then
            return type(value) == "number" and value > Workspace:GetServerTimeNow()
        end
        return value ~= false and value ~= 0
    end

    local function stackTier(counts, word)
        for name in pairs(counts) do
            if string.find(string.lower(name), word, 1, true) then
                return tonumber(string.sub(name, -1)) or 1
            end
        end
        return nil
    end

    -- Short per-kit status that sits left of the name (only things the game exposes as attributes)
    local function kitTracker(plr, char, counts)
        local kit = kitOf(plr)
        if not kit then
            return ""
        end
        local function roman(n)
            return ROMAN[n] or tostring(n)
        end
        if kit == "void_knight" then
            local tier = plr:GetAttribute("VoidKnightTier") or 0
            if tier > 0 then return "【" .. roman(tier) .. "】", Color3.fromRGB(180, 80, 255) end
        elseif kit == "block_kicker" then
            local count = char:GetAttribute("BlockKickerKit_BlockCount") or plr:GetAttribute("BlockKickerKit_BlockCount") or 0
            if count > 0 then return "【" .. count .. "】", Color3.fromRGB(100, 210, 100) end
        elseif kit == "elk_master" then
            if char:FindFirstChild("elk") then return "【🦌】", Color3.fromRGB(160, 220, 80) end
        elseif kit == "summoner" then
            local tier = plr:GetAttribute("Summoner_ClawLevel") or 0
            if tier > 0 then return "【" .. roman(tier) .. "】", Color3.fromRGB(191, 0, 255) end
        elseif kit == "paladin" then
            return "【🪽】", Color3.fromRGB(255, 242, 150)
        elseif kit == "davey" then
            local stacks = char:GetAttribute("StatusEffect_powdered_stacks") or 0
            if stacks > 0 then return "【" .. stacks .. "】", Color3.fromRGB(255, 105, 130) end
        elseif kit == "wizard" then
            local tier = stackTier(counts, "wizard_staff")
            if tier then return "【" .. roman(tier) .. "】", Color3.fromRGB(130, 100, 240) end
        elseif kit == "winter_lady" then
            local tier = stackTier(counts, "frost_staff")
            if tier then return "【" .. roman(tier) .. "】", Color3.fromRGB(200, 225, 255) end
        elseif kit == "aery" then
            return "【" .. (plr:GetAttribute("AeryStacks") or 0) .. "】", Color3.fromRGB(130, 210, 255)
        elseif kit == "warrior" then
            return "【" .. (plr:GetAttribute("Grit") or 0) .. "/100】", Color3.fromRGB(220, 60, 60)
        elseif kit == "mimic" then
            if Workspace:FindFirstChild("DisguisedPlayerBlock_" .. tostring(plr.UserId)) then
                return "【👔】", Color3.fromRGB(180, 210, 60)
            end
        elseif kit == "disruptor" then
            local target = plr:GetAttribute("DisruptorTarget")
            return "【" .. (target and (tostring(target) .. " Team") or "Unknown Team") .. "】", Color3.fromRGB(40, 180, 140)
        end
        return ""
    end

    local function deviceOf(plr)
        local value = string.upper(tostring(plr:GetAttribute("UserInputType") or ""))
        if value == "MOBILE" then
            return "Mobile"
        elseif value == "GAMEPAD" or value == "CONTROLLER" then
            return "Controller"
        end
        return "PC"
    end

    -- Rank badge: asked for once per player, kept for the match
    local function rankImage(plr)
        local cached = rankCache[plr.UserId]
        if cached ~= nil then
            return cached or ""
        end
        if rankRetry[plr.UserId] and os.clock() < rankRetry[plr.UserId] then
            return ""
        end
        rankRetry[plr.UserId] = os.clock() + 20
        task.spawn(function()
            local ok, success, data = pcall(function()
                return Bedwars.Client:Get("FetchRanks"):CallServerAsync({ plr.UserId }):await()
            end)
            if ok and success and type(data) == "table" then
                local division = data[1] and data[1].rankDivision
                local meta = division and Bedwars.RankMeta and Bedwars.RankMeta[division]
                if meta and meta.image then
                    rankCache[plr.UserId] = meta.image
                end
            end
        end)
        return ""
    end

    -- Tag construction -------------------------------------------------------------------------------
    -- Billboards live in a plain Folder inside the hidden-gui container (no ScreenGui in between),
    -- so they keep rendering when the Nova window is hidden.
    local function ensureTagFolder()
        if tagFolder and tagFolder.Parent then
            return tagFolder
        end
        tagFolder = Instance.new("Folder")
        tagFolder.Name = "NovaNameTags"
        local parent
        pcall(function()
            parent = getGuiParent()
        end)
        tagFolder.Parent = parent or LocalPlayer:WaitForChild("PlayerGui")
        return tagFolder
    end

    local function buildTag(entry)
        local cfg = cfgOf()
        local size = iconSize()
        local fontOk, font = pcall(function()
            return Enum.Font[cfg.Font or "Gotham"]
        end)
        font = fontOk and font or FONT.Bold

        ensureTagFolder()
        local gui = New("BillboardGui", {
            Name = "NovaTag",
            Size = UDim2.fromOffset(520, 220),
            StudsOffsetWorldSpace = Vector3.new(0, 2.4, 0),
            AlwaysOnTop = true,
            LightInfluence = 0,
            ResetOnSpawn = false,
            MaxDistance = 1000,
            Parent = tagFolder,
        })
        local stack = New("Frame", {
            Name = "Stack",
            AnchorPoint = Vector2.new(0.5, 1),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(0, 0),
            AutomaticSize = Enum.AutomaticSize.XY,
            BackgroundTransparency = 1,
            Parent = gui,
        }, {
            New("UIListLayout", {
                Padding = UDim.new(0, 3),
                SortOrder = Enum.SortOrder.LayoutOrder,
                HorizontalAlignment = Enum.HorizontalAlignment.Center,
                VerticalAlignment = Enum.VerticalAlignment.Bottom,
            }),
        })

        local function makeRow(name, order)
            return New("Frame", {
                Name = name,
                LayoutOrder = order,
                Size = UDim2.fromOffset(0, 0),
                AutomaticSize = Enum.AutomaticSize.XY,
                BackgroundTransparency = 1,
                Visible = false,
                Parent = stack,
            }, {
                New("UIListLayout", {
                    FillDirection = Enum.FillDirection.Horizontal,
                    Padding = UDim.new(0, 2),
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    HorizontalAlignment = Enum.HorizontalAlignment.Center,
                    VerticalAlignment = Enum.VerticalAlignment.Center,
                }),
            })
        end
        local extras, gear = makeRow("Extras", 1), makeRow("Gear", 2)

        local slots, order = {}, 0
        local function slot(parent, name, counted)
            order = order + 1
            local icon = New("ImageLabel", {
                Name = name,
                BackgroundTransparency = 1,
                Size = UDim2.fromOffset(size, size),
                LayoutOrder = order,
                Image = "",
                Visible = false,
                Parent = parent,
            })
            local amount
            if counted then
                amount = New("TextLabel", {
                    Name = "Amt",
                    BackgroundTransparency = 1,
                    AnchorPoint = Vector2.new(0.5, 1),
                    Position = UDim2.new(0.5, 0, 1, 3),
                    Size = UDim2.fromOffset(size + 8, math.max(8, math.floor(size * 0.5))),
                    Font = FONT.Bold,
                    TextSize = math.max(6, math.floor(size * 0.5)),
                    TextColor3 = Color3.new(1, 1, 1),
                    TextStrokeTransparency = 0,
                    TextXAlignment = Enum.TextXAlignment.Center,
                    TextYAlignment = Enum.TextYAlignment.Bottom,
                    Text = "",
                    ZIndex = 2,
                    Parent = icon,
                })
            end
            slots[name] = { icon = icon, amount = amount }
        end
        if cfg.Enchant then slot(extras, "Enchant") end
        if cfg.Potions then
            for _, def in ipairs(POTIONS) do slot(extras, def.name) end
        end
        if cfg.Loot then
            slot(extras, "Iron", true)
            slot(extras, "Diamond", true)
            slot(extras, "Emerald", true)
        end
        if cfg.BedBreak then
            slot(extras, "Tnt", true)
            slot(extras, "Siege", true)
        end
        if cfg.Kits then slot(gear, "KitIcon") end
        if cfg.Equipment then
            slot(gear, "Hand", true)
            slot(gear, "Helmet")
            slot(gear, "Chestplate")
            slot(gear, "Boots")
        end

        local pill = New("Frame", {
            Name = "Pill",
            LayoutOrder = 3,
            Size = UDim2.fromOffset(0, 0),
            AutomaticSize = Enum.AutomaticSize.XY,
            BackgroundColor3 = Color3.new(0, 0, 0),
            BackgroundTransparency = cfg.Transparency or 0.5,
            BorderSizePixel = 0,
            Parent = stack,
        }, {
            Round(5),
            Pad(5, 2, 5, 2),
            New("UIListLayout", {
                FillDirection = Enum.FillDirection.Horizontal,
                Padding = UDim.new(0, 4),
                SortOrder = Enum.SortOrder.LayoutOrder,
                VerticalAlignment = Enum.VerticalAlignment.Center,
            }),
        })
        local function label(name, order, visible)
            return New("TextLabel", {
                Name = name,
                LayoutOrder = order,
                BackgroundTransparency = 1,
                AutomaticSize = Enum.AutomaticSize.XY,
                Size = UDim2.fromOffset(0, 0),
                Font = font,
                TextSize = textSize(),
                RichText = true,
                TextColor3 = Theme.Text,
                Text = "",
                Visible = visible,
                Parent = pill,
            })
        end
        local tag = {
            gui = gui, extras = extras, gear = gear, pill = pill, slots = slots,
            tracker = cfg.KitTracker and label("Tracker", 1, false) or nil,
            line = label("Line", 2, true),
            device = cfg.Device and label("Device", 3, true) or nil,
        }
        if cfg.Rank then
            tag.rank = New("ImageLabel", {
                Name = "Rank", LayoutOrder = 4, BackgroundTransparency = 1, Size = UDim2.fromOffset(size, size),
                Image = "", Visible = false, Parent = pill,
            })
        end
        if cfg.Gloop then
            tag.gloop = New("ImageLabel", {
                Name = "Gloop", LayoutOrder = 5, BackgroundTransparency = 1, Size = UDim2.fromOffset(size, size),
                Image = itemIcon("glue_projectile"), Visible = false, Parent = pill,
            })
        end
        return tag
    end

    local function removeTag(key)
        local tag = tags[key]
        if tag then
            tag.gui:Destroy()
            tags[key] = nil
        end
    end

    local function removeDrawing(key)
        local drawn = drawings[key]
        if drawn then
            pcall(function() drawn.Text.Visible = false end)
            pcall(function() drawn.BG.Visible = false end)
            pcall(function() drawn.Text:Remove() end)
            pcall(function() drawn.BG:Remove() end)
            drawings[key] = nil
        end
    end

    local function resetTags()
        for key in pairs(tags) do
            removeTag(key)
        end
        for key in pairs(drawings) do
            removeDrawing(key)
        end
    end

    local function setSlot(tag, name, image, label)
        local entry = tag.slots[name]
        if not entry then
            return
        end
        local show = image ~= nil and image ~= ""
        if entry.icon.Visible ~= show then
            entry.icon.Visible = show
        end
        if show then
            if entry.icon.Image ~= image then
                entry.icon.Image = image
            end
            if entry.amount then
                entry.amount.Text = label or ""
            end
        end
    end

    local function syncRow(row)
        local any = false
        for _, child in ipairs(row:GetChildren()) do
            if child:IsA("ImageLabel") and child.Visible then
                any = true
                break
            end
        end
        if row.Visible ~= any then
            row.Visible = any
        end
    end

    -- The game's own name tags are hidden while ours are on, and put back afterwards
    local function setDefaultTags(char, hidden)
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then
            if hidden then
                if hiddenDefaults[hum] == nil then
                    hiddenDefaults[hum] = hum.DisplayDistanceType
                end
                pcall(function()
                    hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
                end)
            elseif hiddenDefaults[hum] ~= nil then
                pcall(function()
                    hum.DisplayDistanceType = hiddenDefaults[hum]
                end)
                hiddenDefaults[hum] = nil
            end
        end
        local head = char:FindFirstChild("Head")
        if head then
            for _, child in ipairs(head:GetChildren()) do
                if child:IsA("BillboardGui") and child.Name == "Nametag" then
                    if hidden then
                        if hiddenDefaults[child] == nil then
                            hiddenDefaults[child] = child.Enabled
                        end
                        child.Enabled = false
                    elseif hiddenDefaults[child] ~= nil then
                        child.Enabled = hiddenDefaults[child]
                        hiddenDefaults[child] = nil
                    end
                end
            end
        end
    end

    local function restoreDefaults()
        for inst, original in pairs(hiddenDefaults) do
            pcall(function()
                if inst:IsA("Humanoid") then
                    inst.DisplayDistanceType = original
                else
                    inst.Enabled = original
                end
            end)
        end
        hiddenDefaults = {}
    end

    local function drawingSupported()
        local ok, fn = pcall(function()
            return Drawing and Drawing.new
        end)
        return ok and type(fn) == "function"
    end

    local function updateDrawing(entry, head, text, color)
        local drawn = drawings[entry.key]
        if not drawn then
            local bg = Drawing.new("Square")
            bg.Filled = true
            bg.Thickness = 0
            bg.Color = Color3.new(0, 0, 0)
            bg.ZIndex = 1
            bg.Visible = false
            local label = Drawing.new("Text")
            label.Center = false
            label.Outline = true
            label.OutlineColor = Color3.new(0, 0, 0)
            label.Font = 2
            label.ZIndex = 2
            label.Visible = false
            drawn = { Text = label, BG = bg }
            drawings[entry.key] = drawn
        end
        drawn.Text.Size = textSize()
        drawn.Text.Text = text
        drawn.Text.Color = color
        drawn.BG.Transparency = 1 - (cfgOf().Transparency or 0.5)
        drawn.head = head
    end

    local function positionDrawings()
        local camera = Workspace.CurrentCamera
        for _, drawn in pairs(drawings) do
            local head = drawn.head
            local shown = false
            if camera and head and head.Parent then
                local point, onScreen = camera:WorldToViewportPoint(head.Position + Vector3.new(0, 2, 0))
                if onScreen and point.Z > 0 then
                    local bounds = drawn.Text.TextBounds
                    drawn.Text.Position = Vector2.new(point.X - bounds.X / 2, point.Y - bounds.Y)
                    drawn.BG.Size = Vector2.new(bounds.X + 8, bounds.Y + 7)
                    drawn.BG.Position = Vector2.new(point.X - bounds.X / 2 - 4, point.Y - bounds.Y - 3)
                    shown = true
                end
            end
            drawn.Text.Visible = shown
            drawn.BG.Visible = shown
        end
    end

    -- One refresh of one entity ---------------------------------------------------------------------
    local function updateEntry(entry, useDrawing)
        local cfg = cfgOf()
        local plr = entry.plr
        local char, hum, root, head = parts(entry)
        if not char or not head or (hum and hum.Health <= 0) then
            return false
        end
        if plr and cfg.HideTeammates ~= false and sameTeam(plr) then
            return false
        end

        local distance
        local _, _, mine = Util.GetCharacter(LocalPlayer)
        if mine and root then
            distance = (mine.Position - root.Position).Magnitude
        end
        local inRange = true
        if cfg.DistanceCheck then
            inRange = distance ~= nil and distance >= (cfg.DistanceMin or 0) and distance <= (cfg.DistanceMax or 64)
        end

        local counts = plr and (cfg.Loot or cfg.BedBreak or cfg.KitTracker or cfg.Equipment) and countsOf(plr) or {}
        local color = nameColor(entry)

        -- text
        local name = nameOf(entry)
        local prefix = (cfg.Distance and distance) and string.format("[%d] ", math.floor(distance)) or ""
        local hp, maxHp, shield, ratio = 0, 1, 0, 1
        if cfg.Health then
            hp, maxHp, shield = healthOf(char, hum)
            ratio = math.clamp(hp / maxHp, 0, 1)
        end

        if useDrawing then
            local text = prefix .. name
            if cfg.Health then
                text = text .. " " .. (shield > 0 and (math.round(hp) .. " +" .. math.round(shield)) or tostring(math.round(hp)))
            end
            local kit = cfg.Kits and plr and kitOf(plr)
            if kit then
                local pretty = kit:gsub("_", " "):gsub("^%l", string.upper)
                text = text .. " (" .. pretty .. ")"
            end
            updateDrawing(entry, head, text, cfg.Health and healthColor(ratio) or color)
            local drawn = drawings[entry.key]
            if drawn then
                drawn.inRange = inRange
                if not inRange then
                    drawn.head = nil
                end
            end
            return true
        end

        local tag = tags[entry.key]
        if tag and not tag.gui.Parent then
            tags[entry.key] = nil
            tag = nil
        end
        tag = tag or buildTag(entry)
        tags[entry.key] = tag
        tag.gui.Adornee = head
        tag.gui.Enabled = inRange

        local text = prefix .. escape(name)
        if cfg.Health then
            text = text .. string.format(' <font color="%s">%d</font>', hex(healthColor(ratio)), math.round(hp))
            if shield > 0 then
                text = text .. string.format(' <font color="#ffffff">%d</font>', math.round(shield))
            end
        end
        tag.line.TextColor3 = color
        tag.line.Text = text

        if tag.tracker then
            local trackerText, trackerColor = "", nil
            if plr then
                trackerText, trackerColor = kitTracker(plr, char, counts)
            end
            tag.tracker.Visible = trackerText ~= nil and trackerText ~= ""
            tag.tracker.Text = trackerText or ""
            if trackerColor then
                tag.tracker.TextColor3 = trackerColor
            end
        end
        if tag.device and plr then
            tag.device.Text = DEVICE_ICONS[deviceOf(plr)] or ""
        end
        if tag.rank and plr then
            local image = rankImage(plr)
            tag.rank.Visible = image ~= ""
            tag.rank.Image = image
        end
        if tag.gloop then
            local glue = char:GetAttribute("GlueSlow")
            if glue ~= nil and glue ~= 0 and glue ~= tag.lastGlue then
                tag.gloopUntil = os.clock() + 10
            end
            tag.lastGlue = glue
            tag.gloop.Visible = tag.gloopUntil ~= nil and os.clock() < tag.gloopUntil
        end

        -- icon rows
        if tag.slots.Enchant then
            setSlot(tag, "Enchant", enchantImage(char))
        end
        if cfg.Potions then
            for _, def in ipairs(POTIONS) do
                setSlot(tag, def.name, potionActive(char, def) and itemIcon(def.item) or "")
            end
        end
        if plr then
            if cfg.Loot then
                for _, pair in ipairs({ { "Iron", "iron" }, { "Diamond", "diamond" }, { "Emerald", "emerald" } }) do
                    local amount = counts[pair[2]] or 0
                    setSlot(tag, pair[1], amount > 0 and itemIcon(pair[2]) or "", shortCount(amount))
                end
            end
            if cfg.BedBreak then
                local tnt, siege = counts.tnt or 0, counts.siege_tnt or 0
                setSlot(tag, "Tnt", tnt > 0 and itemIcon("tnt") or "", shortCount(tnt))
                setSlot(tag, "Siege", siege > 0 and itemIcon("siege_tnt") or "", shortCount(siege))
            end
            if cfg.Kits then
                local kit = kitOf(plr)
                setSlot(tag, "KitIcon", kit and kitIcon(kit) or "")
            end
            if cfg.Equipment then
                local gear = gearOf(char)
                setSlot(tag, "Hand", gear.hand and itemIcon(gear.hand) or "",
                    (gear.hand and (counts[gear.hand] or 0) > 1) and shortCount(counts[gear.hand]) or "")
                setSlot(tag, "Helmet", gear.Helmet and itemIcon(gear.Helmet) or "")
                local chest = gear.Chestplate and itemIcon(gear.Chestplate) or ""
                if kitOf(plr) == "tinker" then
                    local level = plr:GetAttribute("TinkerMachineLevel")
                    if level and level >= 1 and level <= 5 then
                        local mech = tinkerImage(level)
                        if mech ~= "" then
                            chest = mech
                        end
                    end
                end
                setSlot(tag, "Chestplate", chest)
                setSlot(tag, "Boots", gear.Boots and itemIcon(gear.Boots) or "")
            end
        end
        syncRow(tag.extras)
        syncRow(tag.gear)

        if plr and cfg.HideGameTags then
            setDefaultTags(char, true)
        end
        return true
    end

    local function refreshTags()
        local useDrawing = cfgOf().StreamProof and drawingSupported()
        local seen = {}
        for _, entry in ipairs(listEntities()) do
            local ok, shown = pcall(updateEntry, entry, useDrawing)
            if ok and shown then
                seen[entry.key] = true
            end
        end
        for key in pairs(tags) do
            if not seen[key] or useDrawing then
                removeTag(key)
            end
        end
        for key in pairs(drawings) do
            if not seen[key] or not useDrawing then
                removeDrawing(key)
            end
        end
    end

    nameTags = Tabs.Render:CreateModule({
        Name = "NameTags",
        Description = "Overhead tags with name, health, distance, gear, kit and more.",
        OnEnable = function(mod)
            pcall(Bedwars.ResolveExtras)
            pcall(Bedwars.Resolve)

            local function ensureFolder()
                return ensureTagFolder()
            end
            ensureFolder()

            mod.Maid:Give(function()
                resetTags()
                restoreDefaults()
                if tagFolder then
                    pcall(function() tagFolder:Destroy() end)
                    tagFolder = nil
                end
            end)
            mod.Maid:Give(RunService.RenderStepped:Connect(function()
                if next(drawings) then
                    pcall(positionDrawings)
                end
            end))
            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    ensureFolder()
                    local ok, err = pcall(refreshTags)
                    if not ok and type(err) == "string" then
                        -- Soft log once in a while for debugging
                        if not mod._lastTagErr or os.clock() - mod._lastTagErr > 5 then
                            mod._lastTagErr = os.clock()
                            pcall(function()
                                Nova.Notify("NameTags", "refresh error: " .. string.sub(tostring(err), 1, 60), 3, "warn")
                            end)
                        end
                    end
                    task.wait(0.12)
                end
            end))
        end,
    })

    -- Anything that changes how a tag is built starts the tags over
    local function rebuild()
        if nameTags.Enabled then
            resetTags()
        end
    end
    local function defaultsChanged()
        if nameTags.Enabled and not nameTags.Config.HideGameTags then
            restoreDefaults()
        end
    end
    local function whenCustomHealth(cfg)
        return cfg.Health and cfg.CustomHealth
    end

    nameTags:AddSection("Targets")
    nameTags:AddToggle({ Label = "Players", Key = "Players", Default = true, Callback = rebuild })
    nameTags:AddToggle({ Label = "NPCs", Key = "NPCs", Default = false, Tip = "Non-player entities like zombies and golems.", Callback = rebuild })
    nameTags:AddToggle({ Label = "Bosses", Key = "Bosses", Default = false, Tip = "Titan and Bhaa.", Callback = rebuild })
    nameTags:AddToggle({ Label = "Hide Teammates", Key = "HideTeammates", Default = true, Callback = rebuild })

    nameTags:AddSection("Look")
    nameTags:AddOption({ Label = "Font", Key = "Font", Options = FONT_NAMES, Default = "Gotham", Dropdown = true, Callback = rebuild })
    nameTags:AddToggle({ Label = "Team Colors", Key = "TeamColors", Default = true, Tip = "Colour names by team. Off = everyone uses Player Color." })
    nameTags:AddOption({
        Label = "Player Color", Key = "PlayerColor", Options = COLOR_NAMES, Swatches = COLORS, Default = "Purple",
        Tip = "Used for NPCs, and for players when Team Colors is off.",
    })
    nameTags:AddSlider({ Label = "Scale", Key = "Scale", Min = 0.1, Max = 1.5, Default = 1, Step = 0.1, Suffix = "x", Callback = rebuild })
    nameTags:AddSlider({ Label = "Transparency", Key = "Transparency", Min = 0, Max = 1, Default = 0.5, Step = 0.1, Callback = rebuild })

    nameTags:AddSection("Name")
    nameTags:AddToggle({ Label = "Use Displayname", Key = "DisplayName", Default = true })
    nameTags:AddToggle({ Label = "Health", Key = "Health", Default = true })
    nameTags:AddToggle({ Label = "Custom Health Colors", Key = "CustomHealth", Default = false, ShowIf = function(c) return c.Health end })
    nameTags:AddOption({ Label = "Full HP Color", Key = "FullColor", Options = COLOR_NAMES, Swatches = COLORS, Default = "Green", ShowIf = whenCustomHealth })
    nameTags:AddOption({ Label = "Mid HP Color", Key = "MidColor", Options = COLOR_NAMES, Swatches = COLORS, Default = "Yellow", ShowIf = whenCustomHealth })
    nameTags:AddOption({ Label = "Low HP Color", Key = "LowColor", Options = COLOR_NAMES, Swatches = COLORS, Default = "Red", ShowIf = whenCustomHealth })
    nameTags:AddToggle({ Label = "Distance", Key = "Distance", Default = true })

    nameTags:AddSection("Icons")
    nameTags:AddToggle({ Label = "Equipment", Key = "Equipment", Default = true, Tip = "Held item, helmet, chestplate and boots.", Callback = rebuild })
    nameTags:AddToggle({ Label = "Show Kits", Key = "Kits", Default = false, Callback = rebuild })
    nameTags:AddToggle({ Label = "Kit Tracker", Key = "KitTracker", Default = false, Tip = "Kit status next to the name (tiers, stacks, grit...).", Callback = rebuild })
    nameTags:AddToggle({ Label = "Loot", Key = "Loot", Default = false, Tip = "Iron, diamond and emerald they are carrying.", Callback = rebuild })
    nameTags:AddToggle({ Label = "Bed Break", Key = "BedBreak", Default = false, Tip = "TNT and siege TNT they are carrying.", Callback = rebuild })
    nameTags:AddToggle({ Label = "Potions", Key = "Potions", Default = false, Tip = "Active potion effects.", Callback = rebuild })
    nameTags:AddToggle({ Label = "Enchant", Key = "Enchant", Default = false, Tip = "Shows an active enchant effect.", Callback = rebuild })
    nameTags:AddToggle({ Label = "Rank", Key = "Rank", Default = false, Tip = "Their ranked badge (asked from the game once per player).", Callback = rebuild })
    nameTags:AddToggle({ Label = "Device Icon", Key = "Device", Default = false, Tip = "Phone, PC or controller.", Callback = rebuild })
    nameTags:AddToggle({ Label = "Gloop", Key = "Gloop", Default = false, Tip = "Shows for 10s after they get hit by a glue projectile.", Callback = rebuild })

    nameTags:AddSection("Range")
    nameTags:AddToggle({ Label = "Distance Check", Key = "DistanceCheck", Default = false, Tip = "Only show players inside the distance window below." })
    nameTags:AddSlider({
        Label = "Min Distance", Key = "DistanceMin", Min = 0, Max = 256, Default = 0, Step = 4, Suffix = " studs",
        ShowIf = function(c) return c.DistanceCheck end,
    })
    nameTags:AddSlider({
        Label = "Max Distance", Key = "DistanceMax", Min = 0, Max = 256, Default = 64, Step = 4, Suffix = " studs",
        ShowIf = function(c) return c.DistanceCheck end,
    })

    nameTags:AddSection("Other")
    nameTags:AddToggle({
        Label = "Stream Proof", Key = "StreamProof", Default = false,
        Tip = "Draws plain text tags with the Drawing library (no icons). Needs an executor that supports Drawing.",
    })
    nameTags:AddToggle({
        Label = "Hide Game Tags", Key = "HideGameTags", Default = false,
        Tip = "Hides the game's own name tags while this is on. Off by default so the game's normal tags stay visible.",
        Callback = defaultsChanged,
    })

    -- Belt-and-suspenders: guarantees our tags and any hidden default tags are cleaned up on a
    -- full Unload even if something above skipped the module's own Disable cleanup.
    Nova.Maid:Give(function()
        resetTags()
        restoreDefaults()
        if tagFolder then
            tagFolder:Destroy()
            tagFolder = nil
        end
    end)
end

-- ====================== MODULE: WORLD (SKY) ======================
do
    local DEFAULT_SKY = {
        SkyboxBk = "rbxasset://textures/sky/sky512_bk.tex",
        SkyboxDn = "rbxasset://textures/sky/sky512_dn.tex",
        SkyboxFt = "rbxasset://textures/sky/sky512_ft.tex",
        SkyboxLf = "rbxasset://textures/sky/sky512_lf.tex",
        SkyboxRt = "rbxasset://textures/sky/sky512_rt.tex",
        SkyboxUp = "rbxasset://textures/sky/sky512_up.tex",
    }
    local FACES = { "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp" }

    local function normalizeAsset(text)
        text = tostring(text or ""):gsub("%s+", "")
        if text == "" then
            return ""
        end
        if text:match("^%d+$") then
            return "rbxassetid://" .. text
        end
        return text
    end

    local sky = Tabs.World:CreateModule({
        Name = "Custom Sky",
        Description = "Client-side skybox replacement.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local hidden = {}

            for _, child in ipairs(Lighting:GetChildren()) do
                if child:IsA("Sky") then
                    hidden[#hidden + 1] = child
                    child.Parent = nil
                end
            end

            local novaSky = Instance.new("Sky")
            novaSky.Name = "NovaSky"

            local function apply()
                local mode = cfg.Mode
                novaSky.StarCount = cfg.StarCount
                if mode == "Default" then
                    for _, face in ipairs(FACES) do
                        novaSky[face] = DEFAULT_SKY[face]
                    end
                    novaSky.CelestialBodiesShown = true
                elseif mode == "Custom ID" then
                    local id = normalizeAsset(cfg.CustomId)
                    for _, face in ipairs(FACES) do
                        novaSky[face] = id
                    end
                    novaSky.CelestialBodiesShown = cfg.CelestialBodies
                else -- Space
                    for _, face in ipairs(FACES) do
                        novaSky[face] = ""
                    end
                    novaSky.CelestialBodiesShown = cfg.CelestialBodies
                end
            end

            mod.Apply = apply
            apply()
            novaSky.Parent = Lighting

            mod.Maid:Give(function()
                mod.Apply = nil
                pcall(function()
                    novaSky:Destroy()
                end)
                for _, original in ipairs(hidden) do
                    pcall(function()
                        original.Parent = Lighting
                    end)
                end
            end)
        end,
    })

    local function reapply()
        if sky.Apply then
            sky.Apply()
        end
    end

    sky:AddOption({ Label = "Mode", Key = "Mode", Options = { "Space", "Custom ID", "Default" }, Default = "Space", Callback = reapply })
    sky:AddTextBox({ Label = "Image Asset ID", Key = "CustomId", Default = "", Placeholder = "numeric id", Callback = reapply, ShowIf = function(c) return c.Mode == "Custom ID" end })
    sky:AddLabel("Custom ID applies one image to all six faces. Use an Image asset ID, not a Decal ID.", { ShowIf = function(c) return c.Mode == "Custom ID" end })
    sky:AddSlider({ Label = "Stars", Key = "StarCount", Min = 0, Max = 5000, Default = 3000, Step = 100, Callback = reapply, ShowIf = function(c) return c.Mode == "Space" end })
    sky:AddToggle({ Label = "Sun / Moon", Key = "CelestialBodies", Default = false, Callback = reapply })
end

-- ====================== MODULE: WORLD (NIGHTMARE EMOTE) ======================
do
    local nightmare = Tabs.World:CreateModule({
        Name = "Nightmare Emote",
        Description = "Plays the Nightmare emote effect (stand still).",
        OnEnable = function(mod)
            local char, hum, root = Util.GetCharacter(LocalPlayer)
            if not char or not hum or not root then
                error("Character not ready")
            end

            local asset
            local animTrack
            local lastPos = root.Position
            local alive = true

            pcall(function()
                local effects = game:GetService("ReplicatedStorage"):FindFirstChild("Assets")
                effects = effects and effects:FindFirstChild("Effects")
                local template = effects and effects:FindFirstChild("NightmareEmote")
                if not template then
                    error("NightmareEmote asset not found")
                end
                asset = template:Clone()
                asset.Parent = Workspace
                for _, part in ipairs(asset:GetDescendants()) do
                    if part:IsA("BasePart") then
                        part.CanCollide = false
                        part.Anchored = true
                        pcall(function()
                            part.CanQuery = false
                        end)
                    end
                end
                local outer = asset:FindFirstChild("Outer")
                if outer and outer:IsA("BasePart") then
                    TweenService:Create(outer, TweenInfo.new(1.5, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), {
                        Orientation = outer.Orientation + Vector3.new(0, 360, 0),
                    }):Play()
                end
                local middle = asset:FindFirstChild("Middle")
                if middle and middle:IsA("BasePart") then
                    TweenService:Create(middle, TweenInfo.new(12.5, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), {
                        Orientation = middle.Orientation + Vector3.new(0, -360, 0),
                    }):Play()
                end
            end)

            pcall(function()
                local anim = Instance.new("Animation")
                anim.AnimationId = "rbxassetid://9191822700"
                animTrack = hum:LoadAnimation(anim)
                animTrack:Play()
            end)

            mod.Maid:Give(RunService.RenderStepped:Connect(function()
                if not alive then return end
                local _, h, r = Util.GetCharacter(LocalPlayer)
                if not r or not h or h.Health <= 0 then
                    mod:SetEnabled(false)
                    return
                end
                if (r.Position - lastPos).Magnitude > 0.15 then
                    mod:SetEnabled(false)
                    return
                end
                lastPos = r.Position
                if asset and asset.Parent then
                    pcall(function()
                        if asset.PrimaryPart then
                            asset:SetPrimaryPartCFrame(r.CFrame * CFrame.new(0, -3, 0))
                        elseif asset:IsA("Model") then
                            asset:PivotTo(r.CFrame * CFrame.new(0, -3, 0))
                        end
                    end)
                end
            end))

            mod.Maid:Give(function()
                alive = false
                pcall(function()
                    if animTrack then animTrack:Stop() end
                end)
                pcall(function()
                    if asset then asset:Destroy() end
                end)
            end)
        end,
    })
end

-- ====================== MODULE: WORLD (LIGHTING) ======================
do
    local PROPS = { "ClockTime", "Brightness", "Ambient", "OutdoorAmbient", "FogEnd", "FogStart", "GlobalShadows" }

    local lighting = Tabs.World:CreateModule({
        Name = "Lighting Changes",
        Description = "Time of day, fullbright, fog and ambient tint.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local saved = {}
            for _, prop in ipairs(PROPS) do
                saved[prop] = Lighting[prop]
            end
            local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
            local savedAtmosphere = atmosphere and { Density = atmosphere.Density, Haze = atmosphere.Haze } or nil

            local function set(prop, value)
                if Lighting[prop] ~= value then
                    Lighting[prop] = value
                end
            end

            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                if cfg.LockTime then
                    set("ClockTime", cfg.ClockTime)
                end
                if cfg.Fullbright then
                    set("Brightness", 2)
                    set("Ambient", Color3.fromRGB(190, 190, 190))
                    set("OutdoorAmbient", Color3.fromRGB(190, 190, 190))
                    set("GlobalShadows", false)
                elseif cfg.TintAmbient then
                    local tint = Color3.fromHSV(cfg.TintHue, cfg.TintSaturation, 0.55)
                    set("Ambient", tint)
                    set("OutdoorAmbient", tint)
                end
                if cfg.NoFog then
                    set("FogEnd", 1000000)
                    set("FogStart", 0)
                    if atmosphere and atmosphere.Parent then
                        atmosphere.Density = 0
                        atmosphere.Haze = 0
                    end
                end
            end))

            mod.Maid:Give(function()
                for prop, value in pairs(saved) do
                    pcall(function()
                        Lighting[prop] = value
                    end)
                end
                if atmosphere and savedAtmosphere then
                    pcall(function()
                        atmosphere.Density = savedAtmosphere.Density
                        atmosphere.Haze = savedAtmosphere.Haze
                    end)
                end
            end)
        end,
    })

    lighting:AddSection("Time")
    lighting:AddToggle({ Label = "Lock Time of Day", Key = "LockTime", Default = true, Tip = "Keeps the clock fixed so the game can't change it." })
    lighting:AddSlider({ Label = "Time of Day", Key = "ClockTime", Min = 0, Max = 24, Default = 20, Step = 0.25, Tip = "0 and 24 are midnight, 12 is noon.", ShowIf = function(c) return c.LockTime end })
    lighting:AddSection("Atmosphere")
    lighting:AddToggle({ Label = "Fullbright", Key = "Fullbright", Default = false })
    lighting:AddToggle({ Label = "No Fog", Key = "NoFog", Default = false })
    lighting:AddToggle({ Label = "Ambient Tint", Key = "TintAmbient", Default = false })
    lighting:AddSlider({ Label = "Tint Hue", Key = "TintHue", Min = 0, Max = 1, Default = 0.75, Step = 0.01, ShowIf = function(c) return c.TintAmbient end })
    lighting:AddSlider({ Label = "Tint Saturation", Key = "TintSaturation", Min = 0, Max = 1, Default = 0.6, Step = 0.01, ShowIf = function(c) return c.TintAmbient end })
end

-- ====================== MODULE: FPS (POTATO MODE) ======================
do
    local potato
    potato = Tabs.FPS:CreateModule({
        Name = "Potato Mode",
        Description = "Strips textures, shadows and effects for FPS.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local saved = {}       -- instance -> { property = original value }
            local detached = {}    -- instance -> original parent
            local alive = true
            local savedQuality = nil

            local function set(inst, prop, value)
                local record = saved[inst]
                if not record then
                    record = {}
                    saved[inst] = record
                end
                if record[prop] == nil then
                    record[prop] = inst[prop]
                end
                inst[prop] = value
            end

            local function process(inst)
                pcall(function()
                    if inst:IsA("Terrain") then
                        return
                    end
                    if inst:IsA("BasePart") then
                        if cfg.SimplifyMaterials then
                            set(inst, "Material", Enum.Material.SmoothPlastic)
                            if inst.Reflectance ~= 0 then
                                set(inst, "Reflectance", 0)
                            end
                        end
                        if cfg.DisableShadows then
                            set(inst, "CastShadow", false)
                        end
                        if cfg.RemoveTextures and inst:IsA("MeshPart") and inst.TextureID ~= "" then
                            set(inst, "TextureID", "")
                        end
                    elseif cfg.RemoveTextures and (inst:IsA("Decal") or inst:IsA("Texture")) then
                        set(inst, "Transparency", 1)
                    elseif cfg.RemoveTextures and inst:IsA("SurfaceAppearance") then
                        detached[inst] = inst.Parent
                        inst.Parent = nil
                    elseif cfg.DisableParticles and (inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")
                        or inst:IsA("Smoke") or inst:IsA("Fire") or inst:IsA("Sparkles")) then
                        set(inst, "Enabled", false)
                    elseif cfg.DisablePostFX and inst:IsA("PostEffect") then
                        set(inst, "Enabled", false)
                    elseif cfg.DisablePostFX and inst:IsA("Atmosphere") then
                        set(inst, "Density", 0)
                        set(inst, "Haze", 0)
                    end
                end)
            end

            -- Global settings
            pcall(function()
                if cfg.DisableShadows then
                    set(Lighting, "GlobalShadows", false)
                end
                local terrain = Workspace:FindFirstChildOfClass("Terrain")
                if terrain then
                    set(terrain, "WaterWaveSize", 0)
                    set(terrain, "WaterReflectance", 0)
                    set(terrain, "Decoration", false)
                end
            end)
            if cfg.LowQuality then
                pcall(function()
                    local rendering = settings().Rendering
                    savedQuality = rendering.QualityLevel
                    rendering.QualityLevel = Enum.QualityLevel.Level01
                end)
            end

            -- Process the existing world in chunks so the game doesn't freeze
            task.spawn(function()
                local list = Workspace:GetDescendants()
                for index, inst in ipairs(list) do
                    if not alive then
                        return
                    end
                    process(inst)
                    if index % 300 == 0 then
                        task.wait()
                    end
                end
                for _, inst in ipairs(Lighting:GetDescendants()) do
                    process(inst)
                end
            end)

            mod.Maid:Give(Workspace.DescendantAdded:Connect(function(inst)
                task.defer(process, inst)
            end))

            mod.Maid:Give(function()
                alive = false
                for inst, record in pairs(saved) do
                    pcall(function()
                        for prop, value in pairs(record) do
                            inst[prop] = value
                        end
                    end)
                end
                for inst, parent in pairs(detached) do
                    pcall(function()
                        inst.Parent = parent
                    end)
                end
                if savedQuality ~= nil then
                    pcall(function()
                        settings().Rendering.QualityLevel = savedQuality
                    end)
                end
            end)
        end,
    })

    -- Changing an option while enabled re-applies the whole mode
    local function refresh()
        if potato.Enabled then
            potato:SetEnabled(false, true)
            potato:SetEnabled(true, true)
        end
    end

    potato:AddSection("World")
    potato:AddToggle({ Label = "Simplify Materials", Key = "SimplifyMaterials", Default = true, Callback = refresh })
    potato:AddToggle({ Label = "Remove Textures", Key = "RemoveTextures", Default = true, Callback = refresh })
    potato:AddSection("Effects")
    potato:AddToggle({ Label = "Disable Shadows", Key = "DisableShadows", Default = true, Callback = refresh })
    potato:AddToggle({ Label = "Disable Particles", Key = "DisableParticles", Default = true, Callback = refresh })
    potato:AddToggle({ Label = "Disable Post Effects", Key = "DisablePostFX", Default = true, Callback = refresh })
    potato:AddSection("Engine")
    potato:AddToggle({ Label = "Lowest Quality Level", Key = "LowQuality", Default = true, Callback = refresh })
end

-- ====================== MODULE: FPS (UNLOCKER / CAP) ======================
do
    local unlocker
    unlocker = Tabs.FPS:CreateModule({
        Name = "FPS Unlocker",
        Description = "Set a custom FPS cap or remove it.",
        OnEnable = function(mod)
            if not setfpscap then
                error("setfpscap is not supported by this executor")
            end
            local cfg = mod.Config
            mod.Apply = function()
                pcall(setfpscap, cfg.Unlimited and 0 or cfg.Cap)
            end
            mod.Apply()
            mod.Maid:Give(function()
                mod.Apply = nil
                pcall(setfpscap, 60)
            end)
        end,
    })

    local function reapply()
        if unlocker.Apply then
            unlocker.Apply()
        end
    end

    unlocker:AddToggle({ Label = "Unlimited", Key = "Unlimited", Default = false, Callback = reapply, Tip = "Removes the cap entirely." })
    unlocker:AddSlider({ Label = "FPS Cap", Key = "Cap", Min = 30, Max = 360, Default = 144, Step = 1, Callback = reapply, ShowIf = function(c) return not c.Unlimited end })
end

-- ====================== MODULE: FPS (COUNTER) ======================
do
    Tabs.FPS:CreateModule({
        Name = "FPS Counter",
        Description = "Small FPS readout in the corner.",
        OnEnable = function(mod)
            local label = mod.Maid:Give(New("TextLabel", {
                Position = UDim2.fromOffset(14, 14),
                Size = UDim2.fromOffset(86, 26),
                BackgroundColor3 = Theme.Card,
                BorderSizePixel = 0,
                Text = "-- FPS",
                Font = Enum.Font.GothamBold,
                TextSize = 13,
                TextColor3 = Theme.Accent,
                Parent = UI.Gui,
            }, { Round(8), Stroke(Theme.Stroke, 1) }))

            local frames, elapsed = 0, 0
            mod.Maid:Give(RunService.RenderStepped:Connect(function(dt)
                frames = frames + 1
                elapsed = elapsed + dt
                if elapsed >= 0.5 then
                    label.Text = tostring(math.floor(frames / elapsed + 0.5)) .. " FPS"
                    frames, elapsed = 0, 0
                end
            end))
        end,
    })
end

-- ====================== BOOT ======================
UI:SelectTab(UI.TabList[1])
Nova.Quiet = true
pcall(Nova.LoadConfig, nil, true)
Nova.Quiet = false
pcall(Nova.AutoInject.Refresh)
do
    local savedAccent = Nova.Config.UI.Accent
    if ACCENT_SWATCHES[savedAccent] then
        local alt = ACCENTS[1].Alt
        for _, accent in ipairs(ACCENTS) do
            if accent.Name == savedAccent then
                alt = accent.Alt
                break
            end
        end
        applyAccent(ACCENT_SWATCHES[savedAccent], alt)
    end
end
UI:FitScale()
UI:ApplySearch("")
UI:RefreshCounts()
UI:RefreshHud()
UI:SetVisible(true)
Nova.StartAutoSave()
Nova.Notify("Nova", "Loaded", 3, "success")


end -- NovaMain

NovaMain()

]====]
local __run, __err = loadstring(__nova, "=Nova")
if not __run then
    error("Nova could not be compiled by this executor: " .. tostring(__err))
end
return __run(__nova)
