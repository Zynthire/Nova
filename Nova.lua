--[[
    ███  Nova  ███
    Closet-style utility for Roblox  |  Single file  |  Built for Xeno

    Open / close UI : RightShift (or the x button). Drag the top bar to move, double-click it to re-centre.
    Modules         : click a card to open its settings, right-click it (or use the switch) to toggle it.
    Keybinds        : click the small key chip on any module, type a key name
                      (e.g. "E", "Q", "LeftAlt", "F4") and click away. Type "none" to clear.
    Search          : type in the search box (top right) to filter modules across every tab.
    Sliders         : drag, right-click to reset, or click the number and type an exact value.
    Settings        : gear icon (top right) -> notifications, accent colour, window scale,
                      module list, config save / load, Reinject, Uninject.

    Global table    : getgenv().Nova   (settings live in Nova.Config)
    Kill Aura hook  : getgenv().Nova.Hooks.KillAura = function(character, tool, rootPart) ... end
                      (set this for games that use remotes instead of Tool:Activate())
]]

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
                -- Drawing objects and misc userdata/tables
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

    for hum, entry in pairs(TargetRegistry.Entries) do
        local model = hum.Parent
        if model and model:IsA("Model") and model ~= myChar and hum.Health > 0
            and not (myChar and model:IsDescendantOf(myChar)) then
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

-- Skips hits right next to the origin (your own head / viewmodel in first person) and see-through parts
-- Strict version used by Kill Aura: five rays must all be clear, so grazing the corner of a block
-- (or peeking past it) doesn't count as seeing the target. Nothing near you is ignored either.
function Util.HasStrictSight(origin, targetPosition)
    RayFilter.Refresh()
    local toward = targetPosition - origin
    if toward.Magnitude < 1 then
        return true
    end
    local flat = Vector3.new(toward.X, 0, toward.Z)
    local side = flat.Magnitude > 0.01 and flat.Unit:Cross(Vector3.new(0, 1, 0)) or Vector3.new(1, 0, 0)
    local function clear(from, to)
        local current = from
        for _ = 1, 4 do
            local direction = to - current
            if direction.Magnitude < 0.3 then
                return true
            end
            local hit = Workspace:Raycast(current, direction, RayFilter.Params)
            if not hit then
                return true
            end
            if hit.Instance.Transparency >= 0.95 then
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
        and clear(origin + side * 0.5, targetPosition)
        and clear(origin - side * 0.5, targetPosition)
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
local CONFIG_VERSION = 7
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

local Theme = {
    Background  = Color3.fromRGB(12, 10, 19),
    Panel       = Color3.fromRGB(17, 15, 27),
    Card        = Color3.fromRGB(23, 20, 36),
    Accent      = Color3.fromRGB(152, 98, 255),
    AccentDark  = Color3.fromRGB(104, 62, 205),
    AccentLight = Color3.fromRGB(198, 164, 255),
    Text        = Color3.fromRGB(240, 235, 252),
    TextDim     = Color3.fromRGB(150, 142, 178),
    TextFaint   = Color3.fromRGB(102, 96, 130),
    Stroke      = Color3.fromRGB(44, 38, 68),
    StrokeHover = Color3.fromRGB(74, 66, 112),
    Track       = Color3.fromRGB(50, 44, 78),
    Good        = Color3.fromRGB(110, 224, 150),
    Bad         = Color3.fromRGB(255, 96, 118),
    Warn        = Color3.fromRGB(255, 198, 96),
}

local ACCENTS = {
    { Name = "Purple", Color = Color3.fromRGB(152, 98, 255) },
    { Name = "Blue",   Color = Color3.fromRGB(86, 148, 255) },
    { Name = "Cyan",   Color = Color3.fromRGB(64, 208, 232) },
    { Name = "Green",  Color = Color3.fromRGB(84, 214, 148) },
    { Name = "Pink",   Color = Color3.fromRGB(255, 104, 176) },
    { Name = "Orange", Color = Color3.fromRGB(255, 156, 80) },
}
local ACCENT_NAMES, ACCENT_SWATCHES = {}, {}
for _, accent in ipairs(ACCENTS) do
    ACCENT_NAMES[#ACCENT_NAMES + 1] = accent.Name
    ACCENT_SWATCHES[accent.Name] = accent.Color
end

-- Anything that shows the accent colour registers a repaint function here, so changing the
-- accent in settings recolours the whole interface live.
local ThemeHooks = {}
local function onTheme(fn)
    ThemeHooks[#ThemeHooks + 1] = fn
    fn()
    return fn
end

local function applyAccent(color)
    Theme.Accent = color
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

local WINDOW_W, WINDOW_H = 780, 520
local SIDEBAR_W, TOPBAR_H, FOOTER_H = 176, 60, 0
local PAGE_PAD, BODY_PAD, HEADER_H = 24, 18, 56
local CONTENT_W = WINDOW_W - SIDEBAR_W - 1 - PAGE_PAD * 2
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

local function Tween(inst, duration, props, style, direction)
    local tween = TweenService:Create(
        inst,
        TweenInfo.new(duration, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
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
        Animate(track, { BackgroundColor3 = state and Theme.Accent or Theme.Track }, instant, 0.18)
        Animate(knob, { Position = position, BackgroundColor3 = state and Color3.new(1, 1, 1) or Theme.TextDim }, instant, 0.18)
    end
    onTheme(function()
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
    }, { Round(8), stroke })

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
    }, { Round(7), valueStroke })
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
        fillGradient.Color = ColorSequence.new(Theme.AccentDark, Theme.AccentLight)
        knobRing.Color = Theme.Accent
        valueBox.TextColor3 = Theme.AccentLight
    end)

    local function apply(value)
        value = math.clamp(value, min, max)
        value = math.floor(value / step + 0.5) * step
        value = math.clamp(value, min, max)
        value = tonumber(string.format("%.4f", value))
        cfg[key] = value
        local alpha = (max > min) and ((value - min) / (max - min)) or 0
        fill.Size = UDim2.fromScale(alpha, 1)
        knob.Position = UDim2.fromScale(alpha, 0.5)
        valueBox.Text = tostring(value) .. (o.Suffix or "")
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
        valueBox.Text = tostring(cfg[key])
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
        }, { Round(8), Stroke(Theme.Stroke, 1) })
        local highlight = New("Frame", {
            Position = UDim2.fromOffset(2, 2),
            Size = UDim2.fromOffset(widths[1], 22),
            BackgroundColor3 = Theme.Accent,
            BorderSizePixel = 0,
            Parent = segment,
        }, { Round(6) })
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
    }, { Round(7), boxStroke, Pad(10, 0, 10, 0) })
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
                def.Callback()
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
}, { Round(16), mainStroke })

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
}, { Round(16) })
New("Frame", {
    Position = UDim2.new(1, -16, 0, 0),
    Size = UDim2.new(0, 16, 1, 0),
    BackgroundColor3 = Theme.Panel,
    BorderSizePixel = 0,
    Parent = Sidebar,
})

-- Brand
local BrandArea = New("Frame", {
    Name = "Brand",
    Size = UDim2.new(1, 0, 0, 70),
    BackgroundTransparency = 1,
    Parent = Sidebar,
})
local brandTile = New("Frame", {
    Position = UDim2.fromOffset(16, 17),
    Size = UDim2.fromOffset(34, 34),
    BackgroundColor3 = Color3.new(1, 1, 1),
    BorderSizePixel = 0,
    Parent = BrandArea,
}, { Round(10) })
local brandGradient = New("UIGradient", { Rotation = 45, Parent = brandTile })
New("TextLabel", {
    Size = UDim2.fromScale(1, 1),
    BackgroundTransparency = 1,
    Text = "N",
    Font = FONT.Bold,
    TextSize = 19,
    TextColor3 = Color3.new(1, 1, 1),
    Parent = brandTile,
})
New("TextLabel", {
    Position = UDim2.fromOffset(58, 17),
    Size = UDim2.fromOffset(100, 34),
    BackgroundTransparency = 1,
    Text = "Nova",
    Font = FONT.Bold,
    TextSize = 20,
    TextColor3 = Theme.Text,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = BrandArea,
})
onTheme(function()
    brandGradient.Color = ColorSequence.new(Theme.AccentLight, Theme.AccentDark)
end)

local TabHolder = New("Frame", {
    Name = "Tabs",
    Position = UDim2.fromOffset(12, 84),
    Size = UDim2.new(1, -24, 1, -84 - 44),
    BackgroundTransparency = 1,
    Parent = Sidebar,
}, {
    New("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }),
})

-- Top bar --------------------------------------------------------------
local TopBar = New("Frame", {
    Name = "TopBar",
    Position = UDim2.fromOffset(RIGHT_X, 0),
    Size = UDim2.fromOffset(RIGHT_W, TOPBAR_H),
    BackgroundTransparency = 1,
    Parent = UI.Main,
})
UI.TitleLabel = New("TextLabel", {
    Position = UDim2.fromOffset(PAGE_PAD, 11),
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
    Position = UDim2.fromOffset(PAGE_PAD, 33),
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
local searchStroke = Stroke(Theme.Stroke, 1, 1)
local SearchFrame = New("Frame", {
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -(PAGE_PAD + 78), 0, TOPBAR_H / 2),
    Size = UDim2.fromOffset(176, 30),
    BackgroundColor3 = Theme.Card,
    BorderSizePixel = 0,
    Parent = TopBar,
}, { Round(9), searchStroke })
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

-- Enabled count (bottom of the sidebar) -------------------------------------
UI.ActiveLabel = New("TextLabel", {
    AnchorPoint = Vector2.new(0, 1),
    Position = UDim2.new(0, 20, 1, -16),
    Size = UDim2.fromOffset(SIDEBAR_W - 40, 16),
    BackgroundTransparency = 1,
    Text = "",
    Font = FONT.Medium,
    TextSize = 11,
    TextColor3 = Theme.TextDim,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = Sidebar,
})

-- Pages ----------------------------------------------------------------
local Pages = New("Frame", {
    Name = "Pages",
    Position = UDim2.fromOffset(RIGHT_X, TOPBAR_H),
    Size = UDim2.fromOffset(RIGHT_W, WINDOW_H - TOPBAR_H - FOOTER_H),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
    Parent = UI.Main,
})

-- ---------------------------------------------------------------------
-- Tabs
-- ---------------------------------------------------------------------
function UI:SelectTab(selected)
    if not selected then
        return
    end
    UI:CloseDropdown()
    for _, tab in ipairs(UI.TabList) do
        tab.Active = (tab == selected)
        tab.Page.Visible = tab.Active
        tab.Paint(false)
    end
    UI.CurrentTab = selected
    UI.TitleLabel.Text = selected.Name
    UI.SubtitleLabel.Text = selected.Subtitle or ""
end

function UI:CreateTab(name, subtitle)
    local tab = { Name = name, Subtitle = subtitle, Modules = {}, Active = false, Matches = 0 }

    tab.Button = New("TextButton", {
        Name = name,
        Size = UDim2.new(1, 0, 0, 36),
        BackgroundColor3 = Theme.Accent,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        LayoutOrder = #UI.TabList + 1,
        Parent = TabHolder,
    }, { Round(9) })

    tab.Label = New("TextLabel", {
        Position = UDim2.fromOffset(14, 0),
        Size = UDim2.new(1, -24, 1, 0),
        BackgroundTransparency = 1,
        Text = name,
        Font = FONT.Medium,
        TextSize = 13,
        TextColor3 = Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = tab.Button,
    })

    tab.Hovered = false
    tab.Paint = function(instant)
        local active = tab.Active
        local bgAlpha = 1
        local bgColor = Theme.Accent
        if active then
            bgAlpha = 0.86
        elseif tab.Hovered then
            bgAlpha, bgColor = 0.55, Theme.Card
        end
        Animate(tab.Button, { BackgroundTransparency = bgAlpha, BackgroundColor3 = bgColor }, instant, 0.15)
        Animate(tab.Label, { TextColor3 = active and Theme.AccentLight or (tab.Hovered and Theme.Text or Theme.TextDim) }, instant, 0.15)
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
        }, { Round(12), Stroke(Theme.Stroke, 1, 0.4) })
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

        local expanded, expandable, hovered = false, false, false
        local bodyHeight = 0

        local cardStroke = Stroke(Theme.Stroke, 1, 1)
        local card = New("Frame", {
            Name = def.Name,
            Size = UDim2.new(1, 0, 0, HEADER_H),
            BackgroundColor3 = Theme.Card,
            BorderSizePixel = 0,
            ClipsDescendants = true,
            LayoutOrder = #tab.Modules + 1,
            Parent = tab.Page,
        }, { Round(14), cardStroke })
        mod.Card = card

        local header = New("Frame", {
            Name = "Header",
            Size = UDim2.new(1, 0, 0, HEADER_H),
            BackgroundTransparency = 1,
            Parent = card,
        })
        local headerButton = New("TextButton", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            AutoButtonColor = false,
            Text = "",
            Parent = header,
        })
        local arrow = New("TextLabel", {
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromOffset(24, HEADER_H / 2),
            Size = UDim2.fromOffset(16, 16),
            BackgroundTransparency = 1,
            Text = "",
            Font = FONT.Bold,
            TextSize = 12,
            TextColor3 = Theme.TextDim,
            Parent = headerButton,
        })
        local textInset = 44
        local rightReserve = 14 + 42 + 10 + 66 + 14
        New("TextLabel", {
            Position = UDim2.fromOffset(textInset, 10),
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
            Position = UDim2.fromOffset(textInset, 30),
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

        -- Master switch
        local switchTrack, setSwitch, switchClick = createSwitch(header, 42, 22)
        switchTrack.AnchorPoint = Vector2.new(1, 0.5)
        switchTrack.Position = UDim2.new(1, -14, 0.5, 0)
        switchTrack.ZIndex = 2
        switchClick.ZIndex = 3

        -- Keybind chip (typed key name)
        local chipStroke = Stroke(Theme.Stroke, 1)
        local keyBox = New("TextBox", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -66, 0.5, 0),
            Size = UDim2.fromOffset(66, 24),
            BackgroundColor3 = Theme.Panel,
            BorderSizePixel = 0,
            Text = keyText(cfg.Key),
            PlaceholderText = "type key",
            PlaceholderColor3 = Theme.TextFaint,
            TextColor3 = Theme.TextFaint,
            Font = FONT.Medium,
            TextSize = 11,
            ClearTextOnFocus = true,
            ZIndex = 2,
            Parent = header,
        }, { Round(7), chipStroke })

        -- An unbound chip stays out of sight until the card is hovered or the chip is being edited
        local chipHover = false
        local function refreshChip()
            local unbound = (cfg.Key == nil or cfg.Key == "None")
            local show = (not unbound) or hovered or chipHover or keyBox:IsFocused()
            keyBox.BackgroundTransparency = show and 0 or 1
            chipStroke.Transparency = show and 0 or 1
            keyBox.PlaceholderText = show and "type key" or ""
        end
        local function paintChip()
            local unbound = (cfg.Key == nil or cfg.Key == "None")
            keyBox.Text = keyText(cfg.Key)
            keyBox.TextColor3 = unbound and Theme.TextFaint or Theme.AccentLight
            refreshChip()
        end
        paintChip()
        onTheme(paintChip)

        function mod.SetKey(name)
            cfg.Key = name or "None"
            paintChip()
        end

        keyBox.Focused:Connect(function()
            chipStroke.Color = Theme.Accent
            UI:HideTip()
            refreshChip()
        end)
        keyBox.MouseEnter:Connect(function()
            chipHover = true
            refreshChip()
            if not keyBox:IsFocused() then
                chipStroke.Color = Theme.StrokeHover
            end
        end)
        keyBox.MouseLeave:Connect(function()
            chipHover = false
            refreshChip()
            if not keyBox:IsFocused() then
                chipStroke.Color = Theme.Stroke
            end
        end)
        keyBox.FocusLost:Connect(function()
            chipStroke.Color = Theme.Stroke
            task.defer(refreshChip)
            local text = string.gsub(keyBox.Text, "%s+", "")
            local lowered = string.lower(text)
            if text ~= "" and text ~= keyText(cfg.Key) then
                if lowered == "none" or lowered == "clear" or lowered == "-" then
                    cfg.Key = "None"
                    Nova.Notify(def.Name, "Keybind cleared", 2)
                else
                    local keyCode = KeyLookup[lowered]
                    if not keyCode then
                        Nova.Notify(def.Name, "Unknown key: " .. text, 3, "error")
                    elseif keyCode == Enum.KeyCode.RightShift then
                        Nova.Notify(def.Name, "RightShift is reserved for the window", 3, "error")
                    else
                        cfg.Key = keyCode.Name
                        Nova.Notify(def.Name, "Bound to " .. keyText(keyCode.Name), 2)
                    end
                end
            end
            paintChip()
        end)
        UI:AttachTip(keyBox, "Keybind. Click, type a key (E, Q, LeftAlt, F4...) and click away. Type none to clear.")

        -- Body (rows live here)
        local divider = New("Frame", {
            Position = UDim2.fromOffset(BODY_PAD, HEADER_H),
            Size = UDim2.new(1, -BODY_PAD * 2, 0, 1),
            BackgroundColor3 = Theme.Stroke,
            BorderSizePixel = 0,
            Visible = false,
            Parent = card,
        })
        local body = New("Frame", {
            Name = "Body",
            Position = UDim2.fromOffset(0, HEADER_H + 1),
            Size = UDim2.new(1, 0, 0, 0),
            BackgroundTransparency = 1,
            Visible = false,
            Parent = card,
        })
        local content = New("Frame", {
            Name = "Content",
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Parent = body,
        }, {
            New("UIListLayout", { Padding = UDim.new(0, ROW_GAP), SortOrder = Enum.SortOrder.LayoutOrder }),
            Pad(BODY_PAD, BODY_TOP, BODY_PAD, BODY_BOTTOM),
        })

        local host = newHost(content, cfg, nil)
        mod.Host = host

        local function applyHeight(instant)
            bodyHeight = host:ContentHeight()
            body.Size = UDim2.new(1, 0, 0, bodyHeight)
            local target = HEADER_H + (expanded and (1 + bodyHeight) or 0)
            Animate(card, { Size = UDim2.new(1, 0, 0, target) }, instant, 0.24, Enum.EasingStyle.Quint)
        end
        host.OnLayout = function()
            applyHeight(not expanded)
        end

        local function paintCard(instant)
            local base = mod.Enabled and Theme.Card:Lerp(Theme.Accent, 0.1) or Theme.Card
            local bg = hovered and base:Lerp(Theme.Text, 0.04) or base
            Animate(card, { BackgroundColor3 = bg }, instant, 0.12)
            -- an outline only appears while the module is on
            Animate(cardStroke, { Color = Theme.Accent, Transparency = mod.Enabled and (hovered and 0.5 or 0.72) or 1 }, instant, 0.15)
        end
        onTheme(function()
            paintCard(true)
        end)

        local function setExpanded(state, instant)
            expanded = state and true or false
            if expanded then
                body.Visible = true
                divider.Visible = true
            end
            Animate(arrow, { Rotation = expanded and 90 or 0, TextColor3 = expanded and Theme.AccentLight or Theme.TextDim }, instant, 0.2)
            applyHeight(instant)
            if not expanded then
                task.delay(0.26, function()
                    if not expanded and body.Parent then
                        body.Visible = false
                        divider.Visible = false
                    end
                end)
            end
        end
        mod.SetExpanded = setExpanded
        mod.IsExpanded = function()
            return expanded
        end

        local function ensureExpandable()
            if not expandable then
                expandable = true
                arrow.Text = ">"
            end
        end

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

        -- One-line status shown under the module name (used to explain why a module failed to start)
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
        end
        onTheme(function()
            mod:SetStatus(mod.StatusText, mod.StatusKind)
        end)

        headerButton.MouseEnter:Connect(function()
            hovered = true
            paintCard(false)
            refreshChip()
        end)
        headerButton.MouseLeave:Connect(function()
            hovered = false
            paintCard(false)
            task.defer(refreshChip)
        end)
        headerButton.MouseButton1Click:Connect(function()
            if expandable then
                setExpanded(not expanded, false)
            else
                mod:Toggle()
            end
        end)
        headerButton.MouseButton2Click:Connect(function()
            mod:Toggle()
        end)
        UI:AttachTip(headerButton, function()
            if mod.StatusKind == "error" and mod.StatusText then
                return mod.StatusText .. "  (click to retry after fixing it)"
            end
            if expandable then
                return "Click to open settings. Right-click to toggle."
            end
            return "Click to toggle."
        end)

        -- Controls --------------------------------------------------
        local function register(label)
            if label then
                mod.SearchText = mod.SearchText .. " " .. string.lower(label)
            end
            ensureExpandable()
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
                    paintCard(false)
                    cardStroke.Color = Theme.Bad
                    cardStroke.Transparency = 0.2
                    task.delay(1.4, function()
                        if card.Parent then
                            paintCard(false)
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
            paintCard(silent)
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
            mod:Toggle()
        end)

        setSwitch(false, true)
        paintCard(true)
        tab.Modules[#tab.Modules + 1] = mod
        Nova.ModuleList[#Nova.ModuleList + 1] = mod
        UI:RefreshCounts()
        return mod
    end

    UI.Tabs[name] = tab
    UI.TabList[#UI.TabList + 1] = tab
    return tab
end

function UI:RefreshCounts()
    local totalOn = 0
    for _, tab in ipairs(UI.TabList) do
        for _, mod in ipairs(tab.Modules) do
            if mod.Enabled then
                totalOn = totalOn + 1
            end
        end
    end
    UI.ActiveLabel.Text = (totalOn == 0) and "" or (tostring(totalOn) .. " on")
    UI.ActiveLabel.TextColor3 = Theme.AccentLight
end
onTheme(function()
    if UI.RefreshCounts and #UI.TabList > 0 then
        UI:RefreshCounts()
    end
end)

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
}, { Round(8), Stroke(Theme.StrokeHover, 1) })
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
}, { Round(10), Stroke(Theme.StrokeHover, 1) })
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
        }, { Round(6) })
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
    }, { Round(10), Stroke(Theme.Stroke, 1) })

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
        }, { Round(6), Pad(10, 0, 0, 0) })
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

-- Remembers what is on screen right now (enabled modules, tab, open cards, window position)
function Nova.CaptureState()
    local state = { Enabled = {}, Open = {} }
    for _, mod in ipairs(Nova.ModuleList) do
        if mod.Enabled or (Nova.Wanted and Nova.Wanted[mod.Name]) then
            state.Enabled[mod.Name] = true
        end
        if mod.IsExpanded and mod.IsExpanded() then
            state.Open[mod.Name] = true
        end
    end
    if UI.CurrentTab then
        state.Tab = UI.CurrentTab.Name
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
        if type(state.Open) == "table" then
            for _, mod in ipairs(Nova.ModuleList) do
                if state.Open[mod.Name] and mod.SetExpanded then
                    pcall(mod.SetExpanded, true, true)
                end
            end
        end
        if type(state.Tab) == "string" then
            for _, tab in ipairs(UI.TabList) do
                if tab.Name == state.Tab then
                    UI:SelectTab(tab)
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
}, { Round(14), Stroke(Theme.StrokeHover, 1) })
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
            applyAccent(ACCENT_SWATCHES[value] or ACCENT_SWATCHES.Purple)
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
                Nova.AutoSave()
                Nova.Reinject()
            end,
        },
        {
            Label = "Uninject", Style = "danger",
            Tip = "Turn everything off and remove Nova completely.",
            Callback = function()
                Nova.AutoSave()
                Nova.Unload(false)
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

-- ====================== MODULE: LIFECYCLE ======================
function Nova.Unload(keepSaved)
    if Nova.Unloaded then
        return
    end
    Nova.Unloaded = true
    Nova.Unloading = keepSaved and "keep" or "remove"

    -- Disable every module first so each one restores what it touched
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
    Combat  = UI:CreateTab("Combat", "Aim, hitboxes and melee"),
    Render  = UI:CreateTab("Render", "See players and NPCs through walls"),
    Blatant = UI:CreateTab("Blatant", "Obvious movement changes"),
    Utility = UI:CreateTab("Utility", "Safety and quality-of-life tools"),
    Kits    = UI:CreateTab("Kits", "Bedwars kit helpers"),
    World   = UI:CreateTab("World", "Camera, sky and lighting"),
    FPS     = UI:CreateTab("FPS", "Performance and frame rate"),
}

-- ====================== MODULE: AIMBOT ======================
do
    local MOUSE_BUTTONS = { "Left", "Right" }
    local gate = {}
    local currentTarget = nil
    local acquireAt = 0

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

    local function evaluate(cfg, entry, cam, mousePos)
        if not isValid(entry) then
            return nil
        end
        if cfg.TeamCheck and entry.Player and Util.IsTeammate(entry.Player) then
            return nil
        end
        local part, distance = getAimPart(entry, cfg.AimPart, cam, mousePos)
        if not part or distance > cfg.FOV then
            return nil
        end
        if cfg.WallCheck and not Util.HasLineOfSight(cam.CFrame.Position, part.Position) then
            return nil
        end
        return part, distance
    end

    local aim = Tabs.Combat:CreateModule({
        Name = "Aim Assist",
        Description = "Smooth, human-like aim toward the closest target.",
        OnEnable = function(mod)
            local cfg = mod.Config
            currentTarget = nil
            acquireAt = 0

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

            local stepName = "Nova_Aim_" .. Util.RandomName(6)
            RunService:BindToRenderStep(stepName, Enum.RenderPriority.Camera.Value + 1, function(dt)
                local cam = Workspace.CurrentCamera
                if not cam then
                    return
                end
                local mousePos = UserInputService:GetMouseLocation()

                if circle then
                    circle.Visible = cfg.ShowFOV
                    circle.Position = mousePos
                    circle.Radius = cfg.FOV
                end

                local _, myHum = Util.GetCharacter(LocalPlayer)
                if not myHum or myHum.Health <= 0 then
                    currentTarget = nil
                    return
                end
                if not Util.PassesGate(cfg, gate, 0.1) then
                    currentTarget = nil
                    return
                end

                -- Keep the current target unless someone is clearly closer to the crosshair
                local part, distance
                if currentTarget then
                    part, distance = evaluate(cfg, currentTarget, cam, mousePos)
                    if not part then
                        currentTarget = nil
                    end
                end

                local bestEntry, bestPart, bestDistance = nil, nil, math.huge
                for _, entry in ipairs(Util.GetTargets(cfg.Targets)) do
                    local candidatePart, candidateDistance = evaluate(cfg, entry, cam, mousePos)
                    if candidatePart and candidateDistance < bestDistance then
                        bestEntry, bestPart, bestDistance = entry, candidatePart, candidateDistance
                    end
                end

                if bestEntry and (not currentTarget or (bestEntry ~= currentTarget and bestDistance + 30 < distance)) then
                    currentTarget, part, distance = bestEntry, bestPart, bestDistance
                    acquireAt = os.clock() + (cfg.LegitMode and (0.06 + math.random() * 0.1) or 0)
                end

                if not currentTarget or not part then
                    return
                end
                if os.clock() < acquireAt then
                    return
                end

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
                    local noiseX = math.noise(t * 1.3, 0, 0) * 0.45
                    local noiseY = math.noise(0, t * 1.1, 0) * 0.45
                    aimPos = aimPos + camCFrame.RightVector * noiseX + camCFrame.UpVector * noiseY

                    local toTarget = (aimPos - camCFrame.Position)
                    if toTarget.Magnitude > 0.01 then
                        local angle = math.acos(math.clamp(camCFrame.LookVector:Dot(toTarget.Unit), -1, 1))
                        if angle < math.rad(0.35) then
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
    aim:AddOption({ Label = "Aim Part", Key = "AimPart", Options = { "Head", "Torso", "Closest" }, Default = "Closest", Tip = "Closest picks whichever part is nearer to your cursor." })
    aim:AddSlider({ Label = "FOV", Key = "FOV", Min = 20, Max = 600, Default = 150, Step = 5, Suffix = " px", Tip = "Only targets inside this radius around your cursor are considered." })
    aim:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true, Tip = "Ignore targets you can't see." })
    aim:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true, Tip = "Ignore your teammates." })
    aim:AddSection("Feel")
    aim:AddSlider({ Label = "Smoothing", Key = "Smoothing", Min = 1, Max = 100, Default = 35, Step = 1, Tip = "Higher is slower and softer." })
    aim:AddToggle({ Label = "Legit Mode", Key = "LegitMode", Default = true, Tip = "Adds a small human-like delay before locking on." })
    aim:AddSlider({ Label = "Prediction X", Key = "PredictionX", Min = 0, Max = 0.5, Default = 0.1, Step = 0.01, Tip = "How far ahead to aim horizontally for moving targets." })
    aim:AddSlider({ Label = "Prediction Y", Key = "PredictionY", Min = 0, Max = 0.5, Default = 0.05, Step = 0.01, Tip = "How far ahead to aim vertically for moving targets." })
    aim:AddSection("Activation")
    aim:AddToggle({ Label = "Require Mouse Down", Key = "RequireMouseDown", Default = true, Tip = "Only aim while you hold a mouse button." })
    aim:AddOption({ Label = "Mouse Button", Key = "MouseButton", Options = MOUSE_BUTTONS, Default = "Right", ShowIf = function(c) return c.RequireMouseDown end })
    aim:AddToggle({ Label = "Limit to Items", Key = "LimitToItems", Default = false, Tip = "Only aim while holding a matching item." })
    aim:AddTextBox({ Label = "Item Names", Key = "ItemNames", Default = "", Placeholder = "blank = any tool", ShowIf = function(c) return c.LimitToItems end, Tip = "Comma separated, partial names work (bow, gun)." })
    aim:AddSection("Display")
    aim:AddToggle({ Label = "Show FOV Circle", Key = "ShowFOV", Default = false, Tip = "Draw the FOV radius on screen." })
end

-- ====================== MODULE: HITBOX EXPANDER ======================
do
    -- The slider goes higher, but anything above this has no extra effect (bigger boxes glitch)
    local HITBOX_EFFECTIVE_MAX = 10.5

    local hitbox = Tabs.Combat:CreateModule({
        Name = "Hitbox Expander",
        Description = "Expands hitboxes of players / NPCs (client side).",
        OnEnable = function(mod)
            local cfg = mod.Config
            local originals = setmetatable({}, { __mode = "k" })
            local wallCache = setmetatable({}, { __mode = "k" })

            local function restore(root)
                local saved = originals[root]
                if not saved then
                    return
                end
                originals[root] = nil
                pcall(function()
                    root.Size = saved.Size
                    root.Transparency = saved.Transparency
                    root.CanCollide = saved.CanCollide
                    root.Massless = saved.Massless
                end)
            end

            -- Runs on disable / unload / reinject: puts every hitbox back
            mod.Maid:Give(function()
                for root in pairs(originals) do
                    restore(root)
                end
            end)

            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                local cam = Workspace.CurrentCamera
                local now = os.clock()
                local _, _, myRoot = Util.GetCharacter(LocalPlayer)

                -- Points that must never end up inside an expanded box (Inside Fix)
                local points = {}
                if myRoot then
                    points[#points + 1] = myRoot.Position
                end
                if cam then
                    points[#points + 1] = cam.CFrame.Position
                end

                local seen = {}
                for _, entry in ipairs(Util.GetTargets(cfg.Targets)) do
                    local root = entry.Root
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
                        seen[root] = true
                        local saved = originals[root]
                        if not saved then
                            saved = {
                                Size = root.Size,
                                Transparency = root.Transparency,
                                CanCollide = root.CanCollide,
                                Massless = root.Massless,
                            }
                            originals[root] = saved
                        end

                        local size = math.min(cfg.Size, HITBOX_EFFECTIVE_MAX)

                        -- Inside Fix: if you're standing inside the expanded box (touch events never
                        -- fire, rays start inside the part and pass through it), shrink the box just
                        -- enough that you and your camera stay outside it. It grows back as you move away.
                        if cfg.InsideFix and #points > 0 then
                            local nearest = math.huge
                            local cf = root.CFrame
                            for _, point in ipairs(points) do
                                local rel = cf:PointToObjectSpace(point)
                                local d = math.max(math.abs(rel.X), math.abs(rel.Y), math.abs(rel.Z))
                                if d < nearest then
                                    nearest = d
                                end
                            end
                            if nearest < size / 2 + 0.5 then
                                local base = math.max(saved.Size.X, saved.Size.Y, saved.Size.Z)
                                size = math.clamp((nearest - 0.5) * 2, math.min(base, size), size)
                            end
                        end

                        local sizeVector = Vector3.new(size, size, size)
                        if root.Size ~= sizeVector then
                            root.Size = sizeVector
                        end
                        if root.Transparency ~= cfg.Transparency then
                            root.Transparency = cfg.Transparency
                        end
                        if root.CanCollide then
                            root.CanCollide = false
                        end
                        if not root.Massless then
                            root.Massless = true
                        end
                    end
                end

                -- Anything we expanded earlier that is no longer a valid target gets restored
                for root in pairs(originals) do
                    if not seen[root] then
                        restore(root)
                    end
                end
            end))
        end,
    })

    hitbox:AddSection("Targeting")
    hitbox:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players", Tip = "Whose hitboxes get expanded." })
    hitbox:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true })
    hitbox:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true, Tip = "Leave your teammates alone." })
    hitbox:AddSection("Size")
    hitbox:AddSlider({ Label = "Size", Key = "Size", Min = 1, Max = 14, Default = 6, Step = 0.5, Suffix = " studs" })
    hitbox:AddLabel("Sizes above 10.5 have no extra effect.")
    hitbox:AddSlider({ Label = "Transparency", Key = "Transparency", Min = 0, Max = 1, Default = 0.85, Step = 0.05, Tip = "How visible the expanded box is." })
    hitbox:AddToggle({ Label = "Inside Fix", Key = "InsideFix", Default = true })
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

    -- Held item if it's a sword: returns (item, meta) or (nil, reason)
    function Bedwars.GetHeldSword()
        local char = LocalPlayer.Character
        local hand = char and char:FindFirstChild("HandInvItem")
        local item = hand and hand.Value
        if not item then
            return nil, "hold a sword"
        end
        local meta = Bedwars.ItemMeta[item.Name]
        if not meta or not meta.sword then
            return nil, "hold a sword (holding " .. tostring(item.Name) .. ")"
        end
        return item, meta
    end

    local hitRemote
    -- Sends one SwordHit with TRUE positions (your real position, the target's real position).
    function Bedwars.SendHit(item, targetChar, selfPos, targetPos)
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

        local offset = targetPos - selfPos
        if offset.Magnitude < 0.01 then
            return false, "target is on top of you"
        end

        local payload = {
            weapon = weapon,
            chargedAttack = { chargeRatio = 0 },
            entityInstance = targetChar,
            validate = {
                raycast = {
                    cameraPosition = { value = selfPos },
                    cursorDirection = { value = offset.Unit },
                },
                targetPosition = { value = targetPos },
                selfPosition = { value = selfPos },
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
    return function(show, text)
        if not show then
            if label.Visible then
                label.Visible = false
            end
            return
        end
        label.Visible = true
        if text ~= lastText and os.clock() - lastAt > 0.1 then
            lastText = text
            lastAt = os.clock()
            label.Text = render(tostring(text))
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
            return require(remotes.shared.remotes).BlockEngineRemotes.Client
        end)
        attempt("Store", function()
            return require(walk(LocalPlayer, "PlayerScripts", "TS", "ui", "store")).ClientStore
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

            local setStatus = makeStatusLabel(mod, "Kill Aura", -100)

            local box = mod.Maid:Give(New("BoxHandleAdornment", {
                Size = Vector3.new(3.6, 5.8, 3.6),
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

                -- Split by what the server will actually accept from your real position
                local reachable = {}
                for _, candidate in ipairs(targets) do
                    if candidate.Distance <= Bedwars.ReachLimit then
                        reachable[#reachable + 1] = candidate
                    end
                end
                local lead = reachable[1] or targets[1]
                local leadEntry = lead.Entry
                local leadText = string.format("%s (%.1f studs)", tostring(leadEntry.Name), lead.Distance)
                local now = os.clock()

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

                -- Timing: same as the original version. The sword's own attack speed is the floor.
                local swordFloor = (type(meta.sword.attackSpeed) == "number") and meta.sword.attackSpeed or 0
                local interval = math.max(cfg.MinInterval, swordFloor)
                if nextInterval == 0 then
                    nextInterval = interval
                end
                local serverNow = Workspace:GetServerTimeNow()
                local lastGameSwing = tonumber(Bedwars.SwordController.lastAttack) or 0
                local tooSoon = now - lastSend < nextInterval
                -- Don't double up with the game's own swing (Swing Only is built on that swing, so it skips this)
                if not cfg.SwingOnly and serverNow - lastGameSwing < nextInterval * 0.9 then
                    tooSoon = true
                end
                if tooSoon then
                    if now - lastHitAt < 0.5 and lastHitText ~= "" then
                        setStatus(cfg.StatusLine, lastHitText)
                    else
                        setStatus(cfg.StatusLine, "target " .. leadText)
                    end
                    return
                end

                -- Everyone in Range is past the server's reach: swing animation only, no hit packet
                if #reachable == 0 then
                    if cfg.SwingAnimation and not cfg.SwingOnly then
                        playSwing(meta)
                    end
                    lastSend = now
                    nextInterval = interval
                    setStatus(cfg.StatusLine, string.format("%s is past the server's %.1f stud reach - swinging only", leadText, Bedwars.ReachLimit))
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
                    if cfg.SwingOnly then
                        usedSwing = swung
                    else
                        pcall(function()
                            Bedwars.SwordController.lastAttack = Workspace:GetServerTimeNow()
                        end)
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
            end)
        end,
    })

    aura:AddSection("Targeting")
    aura:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players" })
    aura:AddSlider({ Label = "Range", Key = "Range", Min = 3, Max = 22, Default = 12, Step = 0.5, Suffix = " studs", Tip = "Hits only register up to the server's reach (about 14.4 studs)." })
    aura:AddSlider({ Label = "Max Angle", Key = "Angle", Min = 30, Max = 360, Default = 180, Step = 5, Suffix = "°", Tip = "Field of view in front of you. 360 hits all around." })
    aura:AddSlider({ Label = "Max Targets", Key = "MaxTargets", Min = 1, Max = 5, Default = 1, Step = 1 })
    aura:AddOption({ Label = "Sort", Key = "Sort", Options = { "Distance", "Health", "Angle" }, Default = "Distance" })
    aura:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true })
    aura:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true })
    aura:AddSection("Timing")
    aura:AddSlider({ Label = "Min Interval", Key = "MinInterval", Min = 0.05, Max = 0.6, Default = 0.12, Step = 0.01, Suffix = "s", Tip = "The sword's own attack speed is the real minimum." })
    aura:AddToggle({ Label = "Randomize Interval", Key = "RandomizeInterval", Default = true, Tip = "Varies the delay between hits slightly." })
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
do
    local DEFAULT_GRAVITY = 196.2
    local CollectionService = service("CollectionService")
    local StatsService = service("Stats")
    local JUMP_SPEED = 42.6          -- upward speed of a Bedwars jump
    local FLOATY_MARKER = "rbxassetid://8200754399"
    local BODY_PARTS = { "Head", "UpperTorso", "LowerTorso", "HumanoidRootPart", "Torso" }

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

    -- Finds the lowest flight time t at which a projectile launched at `speed` can meet
    -- the target. targetAt(t) gives the predicted target position after t seconds.
    -- Returns velocity, time or nil.
    local function solveLaunch(from, speed, gravity, targetAt, maxTime)
        local function need(t)
            local point = targetAt(t)
            return (point - from + Vector3.new(0, 0.5 * gravity * t * t, 0)) / t
        end

        local step = 0.02
        local t = 0.04
        local previous = nil
        local low, high = nil, nil
        while t <= maxTime do
            if need(t).Magnitude - speed <= 0 then
                high = t
                low = previous or math.max(t - step, 0.01)
                break
            end
            previous = t
            t = t + step
        end
        if not high then
            return nil
        end
        for _ = 1, 24 do
            local mid = (low + high) / 2
            if need(mid).Magnitude - speed > 0 then
                low = mid
            else
                high = mid
            end
        end
        local velocity = need(high)
        if velocity.Magnitude < 0.001 then
            return nil
        end
        return velocity.Unit * speed, high
    end

    -- Samples the arc and checks nothing solid is in the way (characters are ignored)
    local function arcIsClear(from, velocity, gravity, flightTime)
        RayFilter.Refresh()
        local samples = 14
        local previous = from
        for i = 1, samples do
            local t = flightTime * (i / samples) * 0.97
            local point = from + velocity * t - Vector3.new(0, 0.5 * gravity * t * t, 0)
            local hit = Workspace:Raycast(previous, point - previous, RayFilter.Params)
            if hit then
                return false
            end
            previous = point
        end
        return true
    end

    -- Half the round trip to the server (seconds): what the target has already done by the time a
    -- shot lands, on top of the flight time.
    local function pingLead()
        local ok, ping = pcall(function()
            return StatsService.Network.ServerStatsItem["Data Ping"]:GetValue()
        end)
        if ok and type(ping) == "number" then
            return math.clamp(ping / 1000 * 0.5, 0, 0.15)
        end
        return 0
    end

    -- Target movement history. The replicated velocity can read zero for players that move by
    -- teleporting their position (speed hacks), so movement is also measured from position samples.
    local History = setmetatable({}, { __mode = "k" })
    local HISTORY_SPAN = 0.4

    local function sample(entry, now)
        local root = entry.Root
        if not root or not root.Parent then
            return
        end
        local list = History[entry.Model]
        if not list then
            list = {}
            History[entry.Model] = list
        end
        local last = list[#list]
        if last and now - last.t < 0.03 then
            return
        end
        list[#list + 1] = { t = now, p = root.Position }
        while #list > 2 and now - list[1].t > HISTORY_SPAN do
            table.remove(list, 1)
        end
    end

    local function measuredVelocity(entry, now)
        local list = History[entry.Model]
        if not list or #list < 2 then
            return nil
        end
        local newest = list[#list]
        local oldest
        for _, point in ipairs(list) do
            if newest.t - point.t >= 0.08 then
                oldest = point
            end
        end
        if not oldest then
            return nil
        end
        local dt = newest.t - oldest.t
        if dt <= 0 or now - newest.t > 0.25 then
            return nil
        end
        local velocity = (newest.p - oldest.p) / dt
        if velocity.Magnitude > 130 then
            return nil -- a teleport, not movement
        end
        return velocity
    end

    -- Where "the crosshair" is: screen centre in first person / locked mouse, otherwise the cursor
    local function aimReference(cam)
        if Util.IsFirstPerson() or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
            return cam.ViewportSize / 2
        end
        return UserInputService:GetMouseLocation()
    end

    local aim = Tabs.Combat:CreateModule({
        Name = "Bedwars Projectile Aim",
        Description = "Leads moving targets with bows and projectiles (Bedwars).",
        OnEnable = function(mod)
            local cfg = mod.Config
            local active = true
            local controller, original, hadOwn
            local installed = false
            local lastTryAt = 0
            local lastTarget, lastTargetAt = nil, 0
            local blacklist, blacklistText = parseList(cfg.Ignore), cfg.Ignore
            local randomPick = setmetatable({}, { __mode = "k" })   -- model -> { part, at }

            local setStatus = makeStatusLabel(mod, "Projectile Aim", -130)

            local box = mod.Maid:Give(New("BoxHandleAdornment", {
                Size = Vector3.new(3.6, 5.8, 3.6),
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

            local function bodyPart(entry, name)
                local part = entry.Model:FindFirstChild(name)
                if part and part:IsA("BasePart") then
                    return part
                end
                return nil
            end

            -- Which body part to aim at for this target
            local function partFor(entry, cam, mouse, projmeta, origin)
                local mode = cfg.AimPart
                local head = bodyPart(entry, "Head")
                if mode == "Head" then
                    return head or entry.Root
                elseif mode == "Dynamic" then
                    local text = string.lower(tostring(origin and origin.Name or "") .. " " .. tostring(projmeta and projmeta.projectile or ""))
                    if string.find(text, "headhunter", 1, true) then
                        return head or entry.Root
                    end
                    return entry.Root
                elseif mode == "Closest" and cam and mouse then
                    local best, bestDistance = entry.Root, math.huge
                    for _, name in ipairs(BODY_PARTS) do
                        local part = bodyPart(entry, name)
                        if part then
                            local point, onScreen = cam:WorldToViewportPoint(part.Position)
                            if onScreen and point.Z > 0 then
                                local distance = (Vector2.new(point.X, point.Y) - mouse).Magnitude
                                if distance < bestDistance then
                                    best, bestDistance = part, distance
                                end
                            end
                        end
                    end
                    return best
                elseif mode == "Randomize" then
                    local memory = randomPick[entry.Model]
                    if not memory or os.clock() - memory.at > 3 or not memory.part.Parent then
                        local pick = (math.random() * 100 < (cfg.HeadChance or 50)) and head or nil
                        memory = { part = pick or bodyPart(entry, "UpperTorso") or entry.Root, at = os.clock() }
                        randomPick[entry.Model] = memory
                    end
                    return memory.part
                end
                return entry.Root
            end

            -- Best target near the crosshair; returns entry, aimPart
            local function pickTarget(origin, cam, projmeta, tool)
                local mouse = aimReference(cam)
                local best, bestPart, bestScore = nil, nil, math.huge
                for _, entry in ipairs(Util.GetTargets(cfg.Targets)) do
                    local ok = true
                    if entry.Player then
                        if cfg.TeamCheck and Util.IsTeammate(entry.Player) then
                            ok = false
                        elseif entry.Player:GetAttribute("Spectator") then
                            ok = false
                        end
                    end
                    if ok then
                        local part = partFor(entry, cam, mouse, projmeta, tool)
                        local distance = (part.Position - origin).Magnitude
                        if distance <= cfg.Range then
                            local point, onScreen = cam:WorldToViewportPoint(part.Position)
                            local screen = (Vector2.new(point.X, point.Y) - mouse).Magnitude
                            -- the target you were just aiming at gets a small head start, so two players
                            -- close together don't make the aim flip back and forth
                            local sticky = (entry == lastTarget and os.clock() - lastTargetAt < 0.8) and 1.3 or 1
                            if onScreen and point.Z > 0 and screen <= cfg.FOV * sticky
                                and (not cfg.WallCheck or Util.HasLineOfSight(cam.CFrame.Position, part.Position)) then
                                local score
                                if cfg.Sort == "Distance" then
                                    score = distance
                                elseif cfg.Sort == "Health" then
                                    score = entry.Humanoid and entry.Humanoid.Health or 100
                                else
                                    score = screen
                                end
                                if sticky > 1 then
                                    score = score * 0.65
                                end
                                if score < bestScore then
                                    best, bestPart, bestScore = entry, part, score
                                end
                            end
                        end
                    end
                end
                return best, bestPart
            end

            -- Returns a modified copy of the game's launch values, or nil to leave the shot alone
            local function aimShot(native, projmeta, worldmeta, tool)
                local cam = Workspace.CurrentCamera
                if not cam or typeof(native.initialVelocity) ~= "Vector3" or typeof(native.positionFrom) ~= "Vector3" then
                    return nil
                end
                local firstPerson = Util.IsFirstPerson()
                if (cfg.WorkMode == "First Person" and not firstPerson) or (cfg.WorkMode == "Third Person" and firstPerson) then
                    return nil
                end
                if cfg.Ignore ~= blacklistText then
                    blacklist, blacklistText = parseList(cfg.Ignore), cfg.Ignore
                end
                local projectileName = tostring(projmeta and projmeta.projectile or ""):lower()
                if blacklist[projectileName] then
                    return nil
                end

                local from = native.positionFrom
                local speed = native.initialVelocity.Magnitude
                if speed < 1 then
                    return nil
                end
                local gravity = tonumber(native.gravitationalAcceleration)
                    or (DEFAULT_GRAVITY * (tonumber(projmeta and projmeta.gravityMultiplier) or 1))

                local entry, part = pickTarget(from, cam, projmeta, tool)
                if not entry then
                    return nil
                end

                -- Per-projectile numbers (some weapons override them)
                local meta, overrides = nil, {}
                pcall(function()
                    meta = projmeta:getProjectileMeta()
                    if type(meta.getProjectileOverridesFunction) == "function" then
                        overrides = meta.getProjectileOverridesFunction(LocalPlayer)
                    end
                end)
                if type(overrides) ~= "table" then
                    overrides = {}
                end
                meta = type(meta) == "table" and meta or {}
                local normalLife = tonumber(overrides.lifetimeOverride) or tonumber(meta.lifetimeSec) or 3
                local predictedLife = tonumber(overrides.predictionLifetimeOverride) or tonumber(meta.predictionLifetimeSec)
                local lifetime = math.min((worldmeta and predictedLife) or normalLife, 4)
                local returnDistance = tonumber(overrides.returnDistanceOverride) or tonumber(meta.returnDistance)

                local root, hum = entry.Root, entry.Humanoid
                local now = os.clock()
                local velocity = root.AssemblyLinearVelocity
                if cfg.MeasuredVelocity then
                    sample(entry, now)
                    local measured = measuredVelocity(entry, now)
                    if measured then
                        local replicated = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
                        local moved = Vector3.new(measured.X, 0, measured.Z).Magnitude
                        -- trust the measured movement when the replicated velocity clearly under-reports it
                        if moved > replicated * 1.3 + 2 then
                            velocity = Vector3.new(measured.X, velocity.Y, measured.Z)
                        end
                    end
                end
                if projectileName == "telepearl" then
                    velocity = Vector3.zero
                end

                local horizontalLead = cfg.HorizontalLead / 100
                local verticalLead = cfg.VerticalLead / 100
                local vx, vz = velocity.X * horizontalLead, velocity.Z * horizontalLead
                local airborne = hum.FloorMaterial == Enum.Material.Air
                local vy = airborne and velocity.Y * verticalLead or 0
                if cfg.JumpPrediction and not airborne and velocity.Y < 20 then
                    local okState, state = pcall(function()
                        return hum:GetState()
                    end)
                    if okState and state == Enum.HumanoidStateType.Jumping then
                        airborne = true
                        vy = JUMP_SPEED * verticalLead
                    end
                end

                local targetGravity = Workspace.Gravity
                local balloons = entry.Model:GetAttribute("InflatedBalloons")
                if type(balloons) == "number" and balloons > 0 then
                    targetGravity = targetGravity * (1 - (balloons >= 4 and 1.2 or balloons >= 3 and 1 or 0.975))
                end
                local primary = entry.Model.PrimaryPart
                if primary and primary:FindFirstChild(FLOATY_MARKER) then
                    targetGravity = 6
                end
                if entry.Player and entry.Player:GetAttribute("IsOwlTarget") then
                    for _, owl in ipairs(CollectionService:GetTagged("Owl")) do
                        if owl:GetAttribute("Target") == entry.Player.UserId and owl:GetAttribute("Status") == 2 then
                            targetGravity = 0
                            break
                        end
                    end
                end

                local lead = cfg.PingCompensation and pingLead() or 0
                local base = part.Position

                -- Don't predict a falling target through the floor
                local floorY = nil
                if airborne then
                    RayFilter.Refresh()
                    local down = Workspace:Raycast(root.Position, Vector3.new(0, -300, 0), RayFilter.Params)
                    if down then
                        floorY = down.Position.Y + hum.HipHeight + root.Size.Y / 2 + (base.Y - root.Position.Y)
                        floorY = math.min(floorY, base.Y)
                    end
                end

                -- Don't predict a runner through a wall: movement stops where the path is blocked
                local runSpeed = Vector3.new(vx, 0, vz).Magnitude
                local runDirection = runSpeed > 0.5 and Vector3.new(vx, 0, vz).Unit or nil
                local runLimit = math.huge
                if cfg.WallAwareLead and runDirection then
                    RayFilter.Refresh()
                    local reach = runSpeed * (lifetime + lead) + 2
                    local hit = Workspace:Raycast(root.Position, runDirection * reach, RayFilter.Params)
                    if hit then
                        runLimit = math.max(hit.Distance - 1.8, 0)
                    end
                end

                local yOffsetNow = 0
                local function targetAt(t)
                    local tt = t + lead
                    local y = base.Y + yOffsetNow
                    if airborne then
                        y = y + vy * tt - 0.5 * targetGravity * tt * tt
                        if floorY and y < floorY + yOffsetNow then
                            y = floorY + yOffsetNow
                        end
                    end
                    local x, z = base.X + vx * tt, base.Z + vz * tt
                    if runDirection and runSpeed * tt > runLimit then
                        x, z = base.X + runDirection.X * runLimit, base.Z + runDirection.Z * runLimit
                    end
                    return Vector3.new(x, y, z)
                end

                local bow = Bedwars.BowConstants
                -- Where the arrow spawns relative to the camera. A weapon can define its own offset.
                local relX, relY, relZ
                local toolMeta = tool and Bedwars.ItemMeta and Bedwars.ItemMeta[tool.Name]
                local relative = toolMeta and toolMeta.projectileSource and toolMeta.projectileSource.relativeOverride
                if type(relative) == "table" then
                    relX, relY, relZ = relative.relX or 0, relative.relY or 0, relative.relZ or 0
                elseif bow and tonumber(bow.RelX) ~= nil then
                    relX, relY, relZ = bow.RelX, bow.RelY or 0, bow.RelZ or 0
                end
                -- The offset only applies to the third person arrow spawn; first person fires from the camera
                local useOffset = cfg.OffsetFix and relX ~= nil and not firstPerson

                local chosen, chosenTime
                for _, dy in ipairs({ 0, 0.8, -0.8, 1.6, -1.6 }) do
                    yOffsetNow = dy
                    local v, flight = solveLaunch(from, speed, gravity, targetAt, lifetime)
                    if v then
                        if useOffset then
                            local spawn = (CFrame.lookAt(from, from + v) * CFrame.new(-relX, -relY, -relZ)).Position
                            local v2, flight2 = solveLaunch(spawn, speed, gravity, targetAt, lifetime)
                            if v2 then
                                v, flight = v2, flight2
                            end
                        end
                        if worldmeta or not cfg.WallCheck or arcIsClear(from, v, gravity, flight) then
                            chosen, chosenTime = v, flight
                            break
                        end
                    elseif dy == 0 then
                        break -- out of range for this projectile speed; extra offsets won't help
                    end
                end
                if not chosen then
                    return nil
                end
                -- boomerang-style projectiles turn around at a fixed distance
                if returnDistance and speed * chosenTime > returnDistance - 2 then
                    return nil
                end

                local result = {}
                for key, value in pairs(native) do
                    result[key] = value
                end
                result.initialVelocity = chosen
                lastTarget, lastTargetAt = entry, os.clock()
                return result, chosenTime
            end

            local function wrapper(...)
                local nativeResult = original(...)
                if not active or type(nativeResult) ~= "table" then
                    return nativeResult
                end
                local _, projmeta, worldmeta, tool = ...
                if typeof(tool) ~= "Instance" then
                    tool = nil
                end
                local ok, modified = pcall(aimShot, nativeResult, projmeta, worldmeta, tool)
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

            -- The hook goes in as soon as the game's controllers exist (retries until then)
            local lastSampleAt = 0
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                local cam = Workspace.CurrentCamera
                -- keep a short movement history of nearby targets (used by Measured Velocity)
                local now = os.clock()
                if cfg.MeasuredVelocity and installed and now - lastSampleAt >= 0.05 then
                    lastSampleAt = now
                    local _, _, myRoot = Util.GetCharacter(LocalPlayer)
                    if myRoot then
                        for _, entry in ipairs(Util.GetTargets(cfg.Targets)) do
                            if (entry.Root.Position - myRoot.Position).Magnitude <= cfg.Range * 1.5 then
                                sample(entry, now)
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

                if cfg.ShowTarget and lastTarget and os.clock() - lastTargetAt < 1.2
                    and lastTarget.Root and lastTarget.Root.Parent then
                    box.Adornee = lastTarget.Root
                else
                    box.Adornee = nil
                end

                if not installed then
                    if os.clock() - lastTryAt >= 1.5 then
                        lastTryAt = os.clock()
                        local ok, why = install()
                        if ok then
                            installed = true
                            Nova.Notify("Projectile Aim", "Hooked. Shoot a bow near a target.", 3, "success")
                        else
                            setStatus(cfg.StatusLine, "unavailable - " .. tostring(why))
                        end
                    end
                    return
                end

                if os.clock() - lastTargetAt < 1.2 and lastTarget then
                    setStatus(cfg.StatusLine, "aimed at " .. tostring(lastTarget.Name))
                elseif cam then
                    setStatus(cfg.StatusLine, "ready (" .. (Util.IsFirstPerson() and "first" or "third") .. " person)")
                end
            end))

            mod.Maid:Give(function()
                active = false
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
    aim:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players" })
    aim:AddOption({
        Label = "Aim Part", Key = "AimPart", Options = { "Body", "Head", "Dynamic", "Closest", "Randomize" }, Default = "Body",
        Tip = "Dynamic aims at the head only for head-hunter style weapons. Closest picks the part nearest your crosshair. Randomize rolls head or body for each target.",
    })
    aim:AddSlider({
        Label = "Head Chance", Key = "HeadChance", Min = 0, Max = 100, Default = 50, Step = 5, Suffix = "%",
        ShowIf = function(c) return c.AimPart == "Randomize" end,
    })
    aim:AddOption({ Label = "Sort", Key = "Sort", Options = { "Cursor", "Distance", "Health" }, Default = "Cursor", Tip = "Cursor picks whoever is closest to your crosshair. Health picks the weakest." })
    aim:AddOption({ Label = "Work Mode", Key = "WorkMode", Options = { "Both", "First Person", "Third Person" }, Default = "Both", Tip = "Only redirect shots in this camera view." })
    aim:AddSlider({ Label = "FOV", Key = "FOV", Min = 40, Max = 800, Default = 300, Step = 5, Suffix = " px" })
    aim:AddSlider({ Label = "Range", Key = "Range", Min = 20, Max = 250, Default = 120, Step = 5, Suffix = " studs" })
    aim:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true })
    aim:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true })
    aim:AddTextBox({ Label = "Ignore Projectiles", Key = "Ignore", Default = "telepearl", Placeholder = "comma separated names", Tip = "Projectile names that should never be redirected." })
    aim:AddSection("Lead")
    aim:AddSlider({ Label = "Horizontal Lead", Key = "HorizontalLead", Min = 0, Max = 150, Default = 100, Step = 5, Suffix = "%", Tip = "100% = full prediction of sideways movement." })
    aim:AddSlider({ Label = "Vertical Lead", Key = "VerticalLead", Min = 0, Max = 150, Default = 100, Step = 5, Suffix = "%", Tip = "100% = full prediction of vertical movement." })
    aim:AddToggle({ Label = "Bow Offset Fix", Key = "OffsetFix", Default = true })
    aim:AddSection("Prediction")
    aim:AddToggle({ Label = "Measured Velocity", Key = "MeasuredVelocity", Default = true, Tip = "Also measures how far a target actually moves, so speed hackers and laggy players are led correctly." })
    aim:AddToggle({ Label = "Wall Aware Lead", Key = "WallAwareLead", Default = true, Tip = "Stops the predicted path at walls instead of leading through them." })
    aim:AddToggle({ Label = "Jump Prediction", Key = "JumpPrediction", Default = true, Tip = "Leads targets that are just leaving the ground." })
    aim:AddToggle({ Label = "Ping Compensation", Key = "PingCompensation", Default = true, Tip = "Adds half your ping to the lead." })
    aim:AddSection("Visuals")
    aim:AddToggle({ Label = "Show FOV Circle", Key = "ShowFOV", Default = false })
    aim:AddToggle({ Label = "Show Target", Key = "ShowTarget", Default = true })
    aim:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })
    aim:AddLabel("Bedwars only. Doesn't move your camera: it redirects the arrow you release. Keeps the game's own draw strength and timing.")
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

    Tabs.Render:CreatePlaceholder("More render features coming soon...")
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
                    if #kits >= 3 then
                        break
                    end
                elseif #loose < 3 then
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
                ImageTransparency = 0.4,
                ScaleType = Enum.ScaleType.Crop,
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
        local image = kitImage(plr:GetAttribute("PlayingAsKits") or "none")
        if icon.Image ~= image then
            icon.Image = image
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

    local function createLastBadge(host, plr, slot)
        local badge = New("Frame", {
            Name = "NovaLastKit",
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.new(0.41, (slot - 1) * 58, 0.5, 0),
            Size = UDim2.fromOffset(54, 56),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ClipsDescendants = false,
            ZIndex = 10000,
            Visible = false,
            Parent = host,
        })
        badge:SetAttribute("Slot", slot)
        New("TextLabel", {
            Name = "Tag",
            AnchorPoint = Vector2.new(0.5, 0),
            Position = UDim2.new(0.5, 0, 0, -1),
            Size = UDim2.new(1.1, 0, 0, 14),
            BackgroundTransparency = 1,
            Text = (slot == 1) and "last game" or (tostring(slot) .. " games ago"),
            TextColor3 = Color3.fromRGB(255, 64, 64),
            TextSize = 10,
            Font = Enum.Font.FredokaOne,
            TextStrokeTransparency = 0.35,
            TextStrokeColor3 = Color3.new(0, 0, 0),
            ZIndex = 10002,
            Parent = badge,
        })
        New("ImageLabel", {
            Name = "Render",
            AnchorPoint = Vector2.new(0.5, 1),
            Position = UDim2.new(0.5, 0, 1, 1),
            Size = UDim2.fromOffset(44, 41),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            ImageTransparency = 0.05,
            ScaleType = Enum.ScaleType.Fit,
            ZIndex = 10001,
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
        local count = cfg.LastMatchCount or 1
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
        Label = "Matches Back", Key = "LastMatchCount", Min = 1, Max = 3, Default = 1, Step = 1,
        Tip = "1 = their last game, 3 = their last three games.",
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
-- Digs through a bed's defence: finds the cheapest path of blocks from the outside to the target
-- and breaks the block at the outer end of that path, over and over.
do
    local CollectionService = service("CollectionService")
    local ReplicatedStorage = service("ReplicatedStorage")

    local SIDES = {
        Vector3.new(3, 0, 0), Vector3.new(-3, 0, 0),
        Vector3.new(0, 3, 0), Vector3.new(0, -3, 0),
        Vector3.new(0, 0, 3), Vector3.new(0, 0, -3),
    }
    local FLAT = Vector3.new(1, 0, 1)
    local BREAK_CACHE_TTL = 0.5

    local nuker
    local pathCache = {}
    local breakableCache = setmetatable({}, { __mode = "k" })
    local toolDamage = {}           -- breakType -> { damage, item } (rebuilt every loop)
    local highlight = nil
    local lastEquip = 0
    local stats = { Tracked = 0, InRange = 0, Rejected = 0, Nearest = nil, Sent = 0, Reply = "none yet", Beds = {},
        Replies = {}, Cells = {}, Distinct = 0 }
    local activeLock = nil          -- { target, anchor, exit, exitTime } while a target is being dug
    local MIN_BED_GAP = 0.3         -- the game's own hit cooldown; faster hits on a bed get dropped
    local MAX_STICK = 6             -- seconds one entry block is kept before the path is re-checked

    -- Blocks ---------------------------------------------------------------------------
    -- The game's block engine is used when it can be found. If it can't, blocks are looked up
    -- straight from the map (placed blocks carry the "block" tag), so digging still works.
    local function cellOf(position)
        local controller = Bedwars.BlockController
        if controller then
            local ok, cell = pcall(controller.getBlockPosition, controller, position)
            if ok and cell then
                return cell
            end
        end
        return Vector3.new(math.floor(position.X / 3 + 0.5), math.floor(position.Y / 3 + 0.5), math.floor(position.Z / 3 + 0.5))
    end

    local overlap
    local function mapBlockAt(cell)
        if not overlap then
            overlap = OverlapParams.new()
        end
        local ok, parts = pcall(function()
            return Workspace:GetPartBoundsInBox(CFrame.new(cell * 3), Vector3.new(2.2, 2.2, 2.2), overlap)
        end)
        if ok and type(parts) == "table" then
            for _, part in ipairs(parts) do
                if CollectionService:HasTag(part, "block") or CollectionService:HasTag(part, "bed") then
                    return part
                end
            end
        end
        return nil
    end

    local function blockAt(worldPosition)
        local cell = cellOf(worldPosition)
        local controller = Bedwars.BlockController
        if controller then
            local ok, block = pcall(function()
                return controller:getStore():getBlockAt(cell)
            end)
            if ok then
                return block, cell
            end
        end
        return mapBlockAt(cell), cell
    end

    local function breakTypeOf(block)
        if block.Name == "gumdrop_bounce_pad" then
            return "stone"
        end
        local meta = Bedwars.ItemMeta and Bedwars.ItemMeta[block.Name]
        return meta and meta.block and meta.block.breakType
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

    local function bestToolFor(breakType)
        local cached = toolDamage[breakType]
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
        toolDamage[breakType] = { Item = bestItem, Damage = bestDamage }
        return bestItem, bestDamage
    end

    local function hitsToBreak(block, worldPosition)
        local breakType = breakTypeOf(block)
        local _, damage = nil, 2
        if breakType then
            local _, best = bestToolFor(breakType)
            if best and best > 0 then
                damage = best
            end
        end
        local cell = cellOf(worldPosition)
        return healthOf(block, cell) / damage
    end

    -- Path search ------------------------------------------------------------------------
    -- Starts at the target and spreads through solid blocks (cost = hits needed to break each).
    -- The best "exit" is a block that touches open air; `anchor` biases the search toward the
    -- side you are standing on.
    local function findPath(target, startPosition, angle, anchor)
        local cached = pathCache[startPosition]
        if cached then
            local age = os.clock() - cached.Time
            local sameAnchor = (not anchor and not cached.Anchor)
                or (anchor and cached.Anchor and (anchor - cached.Anchor).Magnitude < 1.5)
            if sameAnchor and age < (anchor and 0.5 or 1) then
                return cached.Exit, cached.Cost
            elseif age >= 1 then
                pathCache[startPosition] = nil
            end
        end

        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if not root then
            return nil
        end
        local origin = root.Position
        local camera = Workspace.CurrentCamera
        local camFlat = camera and (camera.CFrame.LookVector * FLAT) or Vector3.new(0, 0, 0)
        local useAngle = angle < 360 and camFlat.Magnitude > 0.01
        local halfAngle = math.rad(angle) / 2

        local visited, distances, open = {}, { [startPosition] = 0 }, { startPosition }
        local exit, cost = nil, math.huge

        for _ = 1, 4000 do
            local bestIndex, bestDistance = nil, math.huge
            for index = 1, #open do
                local distance = distances[open[index]]
                if distance < bestDistance then
                    bestIndex, bestDistance = index, distance
                end
            end
            if not bestIndex then
                break
            end
            local node = open[bestIndex]
            open[bestIndex] = open[#open]
            open[#open] = nil

            if not visited[node] then
                visited[node] = true
                if bestDistance >= cost then
                    break
                end
                for _, side in ipairs(SIDES) do
                    local neighbor = node + side
                    if not visited[neighbor] then
                        local block = blockAt(neighbor)
                        if not block then
                            -- `node` touches open air: it is a candidate block to break
                            local score = bestDistance
                            if anchor then
                                local delta = node - anchor
                                local near = (delta * FLAT).Magnitude + math.abs(delta.Y) * 2
                                score = bestDistance + near * 1.5
                            end
                            if score < cost then
                                exit, cost = node, score
                            end
                        elseif block ~= target and not block:GetAttribute("NoBreak")
                            and (neighbor - origin).Magnitude <= 30 then
                            local allowed = true
                            if useAngle then
                                local flat = (neighbor - origin) * FLAT
                                if flat.Magnitude > 0.01
                                    and math.acos(math.clamp(camFlat.Unit:Dot(flat.Unit), -1, 1)) > halfAngle then
                                    allowed = false
                                end
                            end
                            if allowed then
                                local total = hitsToBreak(block, neighbor) + bestDistance
                                if total < (distances[neighbor] or math.huge) then
                                    distances[neighbor] = total
                                    open[#open + 1] = neighbor
                                end
                            end
                        end
                    end
                end
            end
        end

        if exit then
            pathCache[startPosition] = { Exit = exit, Cost = cost, Time = os.clock(), Anchor = anchor }
            return exit, cost
        end
        return nil
    end

    -- Hand / tools ---------------------------------------------------------------------------
    local function heldItemName()
        local char = LocalPlayer.Character
        local hand = char and char:FindFirstChild("HandInvItem")
        local item = hand and hand.Value
        return item and item.Name or nil
    end

    -- Switches your hotbar to the best tool for this block (not while you are swinging a sword)
    local function equipFor(block)
        local cfg = nuker.Config
        local breakType = breakTypeOf(block)
        if not breakType then
            return true
        end
        local tool = bestToolFor(breakType)
        if not tool then
            return true
        end
        if not cfg.AutoTool then
            return heldItemName() == tool.itemType
        end
        if heldItemName() == tool.itemType then
            return true
        end
        local sword = Bedwars.SwordController
        local lastAttack = sword and tonumber(sword.lastAttack) or 0
        if Workspace:GetServerTimeNow() - lastAttack <= 0.4 or os.clock() - lastEquip < 0.25 then
            return true
        end
        local inventory = Bedwars.GetInventory()
        if inventory and Bedwars.Store then
            for index, slot in ipairs(inventory.hotbar or {}) do
                if slot.item and slot.item.itemType == tool.itemType then
                    if inventory.hotbarSlot ~= index - 1 then
                        lastEquip = os.clock()
                        pcall(function()
                            Bedwars.Store:dispatch({ type = "InventorySelectHotbarSlot", slot = index - 1 })
                        end)
                        task.wait(0.05)
                    end
                    break
                end
            end
        end
        return true
    end

    -- Target filtering --------------------------------------------------------------------
    local function teamKey(value)
        if value == nil then
            return nil
        end
        if typeof(value) == "Instance" then
            return tostring(value.Name)
        end
        return tostring(value)
    end

    local function myTeam()
        return teamKey(LocalPlayer:GetAttribute("Team") or LocalPlayer:GetAttribute("TeamId")
            or LocalPlayer:GetAttribute("TeamID") or LocalPlayer.Team)
    end

    local function isOwnTeamBlock(block)
        local mine = myTeam()
        local blockTeam = teamKey(block:GetAttribute("Team") or block:GetAttribute("TeamId") or block:GetAttribute("TeamID"))
        if mine and blockTeam and mine == blockTeam then
            return true
        end
        local placedBy = tonumber(block:GetAttribute("PlacedByUserId"))
        if placedBy == LocalPlayer.UserId then
            return true
        end
        if placedBy then
            local owner = Players:GetPlayerByUserId(placedBy)
            local theirs = owner and teamKey(owner:GetAttribute("Team") or owner:GetAttribute("TeamId") or owner.Team)
            if mine and theirs and mine == theirs then
                return true
            end
        end
        return false
    end

    local function isBreakable(block)
        local now = os.clock()
        local cached = breakableCache[block]
        if cached and now - cached.Time < BREAK_CACHE_TTL then
            return cached.Value
        end
        local value
        if Bedwars.BlockController then
            local ok, result = pcall(function()
                return Bedwars.BlockController:isBlockBreakable({ blockPosition = cellOf(block.Position) }, LocalPlayer)
            end)
            value = ok and result or false
        else
            value = not block:GetAttribute("NoBreak")
        end
        breakableCache[block] = { Value = value, Time = now }
        return value
    end

    local function passesChecks(block)
        local cfg = nuker.Config
        if block:GetAttribute("NoBreak") then
            return false
        end
        if (block:GetAttribute("BedShieldEndTime") or 0) > Workspace:GetServerTimeNow() then
            return false
        end
        local mine = myTeam()
        if mine and block:GetAttribute("Team" .. mine .. "NoBreak") then
            return false
        end
        if not cfg.SelfBreak and isOwnTeamBlock(block) then
            return false
        end
        if cfg.LimitToItems then
            local name = heldItemName()
            local meta = name and Bedwars.ItemMeta[name]
            if not (meta and meta.breakBlock) then
                return false
            end
        end
        return true
    end

    -- Highlight -----------------------------------------------------------------------------
    local function setHighlight(block)
        if not highlight then
            return
        end
        if block and nuker.Config.Highlight and block:IsA("BasePart") then
            highlight.Adornee = block
            highlight.Size = block.Size
            highlight.Color3 = Theme.Accent
        else
            highlight.Adornee = nil
        end
    end

    -- The game's own raw DamageBlock remote (used when the bed itself is exposed, and as a fallback)
    local rawRemote
    local function getRawRemote()
        if rawRemote ~= nil then
            return rawRemote or nil
        end
        rawRemote = false
        pcall(function()
            local node = ReplicatedStorage
            for _, name in ipairs({ "rbxts_include", "node_modules", "@easy-games", "block-engine", "node_modules",
                "@rbxts", "net", "out", "_NetManaged", "DamageBlock" }) do
                node = node and node:FindFirstChild(name)
            end
            if node then
                rawRemote = node
            end
        end)
        return rawRemote or nil
    end

    local function sendRaw(block, cell)
        local remote = getRawRemote()
        if not remote or not block or not block.Parent then
            return false
        end
        task.spawn(function()
            pcall(function()
                local payload = {
                    blockRef = { blockPosition = cell },
                    hitPosition = block.Position + Vector3.new(0, block.Size.Y / 2, 0),
                    hitNormal = Vector3.new(0, 1, 0),
                }
                if remote:IsA("RemoteFunction") then
                    remote:InvokeServer(payload)
                else
                    remote:FireServer(payload)
                end
            end)
        end)
        return true
    end

    -- Breaking ----------------------------------------------------------------------------------
    -- Returns (true, description) when it sent a hit, (false, reason) otherwise
    local function breakTarget(target, anchor, lock)
        local cfg = nuker.Config
        local handler
        pcall(function()
            handler = Bedwars.BlockController:getHandlerRegistry():getHandler(target.Name)
        end)
        local positions = {}
        local ok, contained = pcall(function()
            return handler and handler:getContainedPositions(target)
        end)
        if ok and type(contained) == "table" and next(contained) ~= nil then
            for _, cell in pairs(contained) do
                positions[#positions + 1] = cell * 3
            end
        else
            positions[1] = cellOf(target.Position) * 3
        end

        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if not root then
            return false, "no character"
        end

        -- Keep hitting the same entry block until it is gone. Re-planning every tick made the
        -- chosen block flip between neighbours as you moved, so each one only got a single hit.
        local bestExit, block, cell
        if lock and lock.exit and os.clock() - (lock.exitTime or 0) < MAX_STICK
            and (root.Position - lock.exit).Magnitude <= 30 then
            local held, heldCell = blockAt(lock.exit)
            if held and held.Parent and not held:GetAttribute("NoBreak") and heldCell then
                bestExit, block, cell = lock.exit, held, heldCell
            else
                lock.exit = nil
            end
        end

        if not bestExit then
            local bestCost = math.huge
            for _, worldPosition in ipairs(positions) do
                local exit, cost = findPath(target, worldPosition, cfg.Angle, anchor)
                if exit and cost < bestCost then
                    bestExit, bestCost = exit, cost
                end
            end
            if not bestExit then
                return false, "no way in (everything around it is unbreakable or out of range)"
            end
            if (root.Position - bestExit).Magnitude > 30 then
                return false, "too far from the entry block"
            end
            block, cell = blockAt(bestExit)
            if not block then
                block, cell = target, cellOf(target.Position)
            end
            if lock then
                lock.exit, lock.exitTime = bestExit, os.clock()
            end
        end
        if not cell or block:GetAttribute("NoBreak") then
            if lock then
                lock.exit = nil
            end
            return false, "entry block can't be broken"
        end
        if not cfg.SelfBreak and block ~= target and isOwnTeamBlock(block) then
            if lock then
                lock.exit = nil
            end
            return false, "entry block is your team's"
        end
        if not equipFor(block) then
            return false, "hold the right tool (Auto Tool is off)"
        end

        setHighlight(block)
        local sent, sendError = pcall(function()
            local remote = Bedwars.DamageBlockRemotes:Get("DamageBlock")
            local promise = remote:CallServerAsync({
                blockRef = { blockPosition = cell },
                hitPosition = bestExit,
                hitNormal = Vector3.new(0, 1, 0),
            })
            stats.Sent = stats.Sent + 1
            local key = tostring(cell)
            if not stats.Cells[key] then
                stats.Cells[key] = true
                stats.Distinct = stats.Distinct + 1
            end
            if type(promise) == "table" and type(promise.andThen) == "function" then
                promise:andThen(function(result)
                    stats.Reply = tostring(result)
                    stats.Replies[stats.Reply] = (stats.Replies[stats.Reply] or 0) + 1
                    if result == "cancelled" or result == "destroyed" then
                        pathCache = {}
                        if activeLock then
                            activeLock.exit = nil
                        end
                    end
                end)
            end
        end)
        -- the bed is directly exposed (or the normal remote errored): also use the raw remote
        if (block == target) or not sent then
            sent = sendRaw(block, cell) or sent
        end
        if not sent then
            return false, "couldn't send the hit: " .. string.sub(tostring(sendError), 1, 60)
        end
        local label = (block == target) and "breaking it" or ("digging " .. tostring(block.Name))
        return sent, label .. " (" .. stats.Reply .. ")"
    end

    -- Candidates -----------------------------------------------------------------------------
    -- A tagged object can be the block itself or a model that contains it; we always want a part.
    local function asPart(inst)
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

    -- Keeps a live list of everything carrying one of the tags
    local function trackTags(mod, tags)
        local list = {}
        local function add(inst)
            local part = asPart(inst)
            if part and not table.find(list, part) then
                list[#list + 1] = part
            end
        end
        local function remove(inst)
            local part = asPart(inst) or inst
            local index = table.find(list, part)
            if index then
                table.remove(list, index)
            end
        end
        for _, tag in ipairs(tags) do
            mod.Maid:Give(CollectionService:GetInstanceAddedSignal(tag):Connect(add))
            mod.Maid:Give(CollectionService:GetInstanceRemovedSignal(tag):Connect(remove))
            for _, inst in ipairs(CollectionService:GetTagged(tag)) do
                add(inst)
            end
        end
        return list, add, remove
    end

    -- One-click self check: shows what Nova can and can't see, and copies the report to the clipboard
    local function runDiagnostics()
        local lines = {}
        local function add(label, ok, detail)
            lines[#lines + 1] = (ok and "OK    " or "FAIL  ") .. label .. (detail ~= nil and (" - " .. tostring(detail)) or "")
        end
        local ready, reason = Bedwars.ResolveExtras()
        add("Bedwars found", Bedwars.Ready == true, reason)
        add("Block engine", Bedwars.BlockController ~= nil, Bedwars.BlockController and nil or "using map lookup instead")
        add("Hit remote (game)", Bedwars.DamageBlockRemotes ~= nil)
        add("Hit remote (direct)", getRawRemote() ~= nil)
        add("Item data", Bedwars.ItemMeta ~= nil)
        add("Inventory", Bedwars.GetInventory() ~= nil, Bedwars.Store and nil or "store not found")
        local tagged = #CollectionService:GetTagged("bed")
        local named = 0
        pcall(function()
            for _, inst in ipairs(Workspace:GetDescendants()) do
                if inst.Name == "bed" then
                    named = named + 1
                end
            end
        end)
        add("Beds named 'bed' in map", named > 0, named)
        add("Beds tagged in game", tagged > 0, tagged)
        add("Blocks tagged in game", #CollectionService:GetTagged("block") > 0, #CollectionService:GetTagged("block"))
        local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        add("Your character", root ~= nil)
        if root then
            local nearest, nearestDistance
            for _, inst in ipairs(CollectionService:GetTagged("bed")) do
                local part = asPart(inst)
                if part then
                    local distance = (part.Position - root.Position).Magnitude
                    if not nearestDistance or distance < nearestDistance then
                        nearest, nearestDistance = part, distance
                    end
                end
            end
            if nearest then
                add("Nearest bed", true, string.format("%.0f studs, team %s", nearestDistance, tostring(nearest:GetAttribute("Team"))))
                local atBed, bedCell = blockAt(nearest.Position)
                add("Bed found as a block", atBed ~= nil, bedCell and tostring(bedCell) or nil)
                add("Not blocked (shield / own team)", passesChecks(nearest))
                add("Game says it is breakable", isBreakable(nearest))
                local ok2, exit = pcall(function()
                    return findPath(nearest, cellOf(nearest.Position) * 3, 360, nil)
                end)
                add("Way in found", ok2 and exit ~= nil, ok2 and (exit == nil and "blocked or too far" or nil) or exit)
            end
        end
        add("Hits sent", stats.Sent > 0, tostring(stats.Sent) .. ", last reply: " .. stats.Reply)
        local counts = {}
        for reply, amount in pairs(stats.Replies) do
            counts[#counts + 1] = reply .. " x" .. amount
        end
        table.sort(counts)
        add("Server replies", #counts > 0, #counts > 0 and table.concat(counts, ", ") or "none yet")
        add("Different blocks hit", true, tostring(stats.Distinct) .. " (a high number next to few 'destroyed' means hits are spread out)")
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
            Bedwars.WaitExtras(4)
            local loaded, why = Bedwars.Resolve()
            assert(loaded, why or "Bedwars isn't loaded yet - join a match first")
            assert(Bedwars.DamageBlockRemotes or getRawRemote(), "DamageBlock remote not found (Bedwars update?)")

            local cfg = mod.Config
            pathCache, toolDamage = {}, {}
            activeLock = nil
            stats.Replies, stats.Cells, stats.Distinct, stats.Sent = {}, {}, 0, 0
            local setStatus = makeStatusLabel(mod, "Nuker", -160)

            highlight = New("BoxHandleAdornment", {
                Name = "NovaNuker",
                AlwaysOnTop = true,
                ZIndex = 2,
                Transparency = 0.55,
                Color3 = Theme.Accent,
                Size = Vector3.new(3, 3, 3),
                Parent = Workspace.CurrentCamera or Workspace,
            })
            mod.Maid:Give(highlight)
            mod.Maid:Give(function()
                highlight = nil
                pathCache = {}
                activeLock = nil
            end)

            -- Beds: the game tags them "bed". As a backup also look for anything named "bed" in the map.
            local beds, addBed, removeBed = trackTags(mod, { "bed" })
            local function addNamedBed(inst)
                if inst.Name == "bed" then
                    addBed(inst)
                end
            end
            pcall(function()
                for _, inst in ipairs(Workspace:GetDescendants()) do
                    addNamedBed(inst)
                end
            end)
            mod.Maid:Give(Workspace.DescendantAdded:Connect(addNamedBed))
            mod.Maid:Give(Workspace.DescendantRemoving:Connect(removeBed))
            -- Backup finder: looks at what is physically around you, so a bed is found even when the
            -- game's tag or its model name isn't what we expect.
            local scanParams
            local lastScan = -10
            local function looksLikeBed(inst)
                return inst and (inst.Name == "bed" or CollectionService:HasTag(inst, "bed"))
            end
            local function scanForBeds(position, force)
                if not force and os.clock() - lastScan < 1.5 then
                    return
                end
                lastScan = os.clock()
                scanParams = scanParams or OverlapParams.new()
                local ok, parts = pcall(function()
                    return Workspace:GetPartBoundsInRadius(position, math.max(cfg.Range, 20) + 10, scanParams)
                end)
                if not ok or type(parts) ~= "table" then
                    return
                end
                for _, part in ipairs(parts) do
                    local owner
                    if looksLikeBed(part) then
                        owner = part
                    else
                        local parent = part.Parent
                        if parent and parent ~= Workspace and looksLikeBed(parent) then
                            owner = parent
                        elseif parent and parent.Parent and parent.Parent ~= Workspace and looksLikeBed(parent.Parent) then
                            owner = parent.Parent
                        end
                    end
                    if owner then
                        addBed(owner)
                    end
                end
            end
            local luckyBlocks = trackTags(mod, { "LuckyBlock" })
            local ironOre = trackTags(mod, { "iron-ore", "iron_ore_mesh_block" })
            stats.Beds = beds

            local function pickTarget(position)
                -- keep digging the same target until it is gone / out of reach
                local held = activeLock and activeLock.target
                if held and held.Parent and (held.Position - position).Magnitude < cfg.Range
                    and passesChecks(held) and isBreakable(held) then
                    return held
                end
                local lists = {}
                if cfg.Beds then lists[#lists + 1] = beds end
                if cfg.LuckyBlocks then lists[#lists + 1] = luckyBlocks end
                if cfg.IronOre then lists[#lists + 1] = ironOre end

                local best, bestValue = nil, math.huge
                stats.Tracked, stats.InRange, stats.Rejected, stats.Nearest = 0, 0, 0, nil
                stats.NearestBed, stats.NearestBedOwn = nil, false
                for _, list in ipairs(lists) do
                    for _, block in ipairs(list) do
                        local distance = block.Parent and (block.Position - position).Magnitude
                        if distance and list == beds and (not stats.NearestBed or distance < stats.NearestBed) then
                            stats.NearestBed = distance
                            stats.NearestBedOwn = isOwnTeamBlock(block)
                        end
                        if distance then
                            stats.Tracked = stats.Tracked + 1
                            if not stats.Nearest or distance < stats.Nearest then
                                stats.Nearest = distance
                            end
                            if distance < cfg.Range then
                                stats.InRange = stats.InRange + 1
                            end
                        end
                        if distance and distance < cfg.Range
                            and passesChecks(block) and isBreakable(block) then
                            local value
                            if cfg.TargetMode == "Health" then
                                local cell = cellOf(block.Position)
                                value = healthOf(block, cell)
                            else
                                value = (block.Position - position).Magnitude
                            end
                            if value < bestValue then
                                best, bestValue = block, value
                            end
                        elseif distance and distance < cfg.Range then
                            stats.Rejected = stats.Rejected + 1
                        end
                    end
                end
                return best
            end

            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    task.wait(1 / 30)
                    if not mod.Enabled then
                        break
                    end
                    toolDamage = {}
                    local _, _, root = Util.GetCharacter(LocalPlayer)
                    local acted = false
                    if not root then
                        setStatus(false)
                    elseif LocalPlayer:GetAttribute("DenyBlockBreak") then
                        setStatus(true, "can't break blocks right now")
                    elseif cfg.RequireMouseDown and not Util.IsMouseDown(false) then
                        setStatus(true, "hold left click")
                    else
                        local ok, result, info = pcall(function()
                            if cfg.Beds then
                                scanForBeds(root.Position)
                            end
                            local target = pickTarget(root.Position)
                            if not target then
                                activeLock = nil
                                if stats.Tracked == 0 then
                                    return false, "no beds/blocks found in this match yet"
                                elseif stats.InRange == 0 then
                                    if stats.NearestBed then
                                        return false, string.format("no bed in range - nearest is %.0f studs away%s (range %d)",
                                            stats.NearestBed, stats.NearestBedOwn and ", your team's" or "", cfg.Range)
                                    end
                                    return false, string.format("no bed found yet, nearest block %.0f studs (range %d)",
                                        stats.Nearest or 0, cfg.Range)
                                end
                                return false, string.format("%d in range but not breakable (team/shield/protected)", stats.Rejected)
                            end

                            -- Stay on one target (and one side of it) until it is gone, so the entry
                            -- block doesn't change while you move.
                            local lock = activeLock
                            if lock and lock.target ~= target then
                                lock = nil
                            end
                            if lock and lock.anchor and (lock.anchor - root.Position).Magnitude > 12 then
                                lock.anchor = root.Position
                                lock.exit = nil
                            end
                            if not lock then
                                lock = { target = target, anchor = root.Position }
                            end
                            activeLock = lock

                            local anchor = (cfg.TargetMode == "Distance") and lock.anchor or nil
                            local sent, text = breakTarget(target, anchor, lock)
                            if sent then
                                setStatus(true, string.format("%s %.0f studs away, %s", target.Name,
                                    (target.Position - root.Position).Magnitude, text))
                                local pause = cfg.BreakSpeed
                                -- hits on or right next to a bed need the game's own 0.3s spacing
                                if lock.exit and (lock.exit - target.Position).Magnitude < 4 then
                                    pause = math.max(pause, MIN_BED_GAP)
                                end
                                task.wait(pause)
                                return true
                            end
                            return false, text
                        end)
                        if ok then
                            acted = result and true or false
                            if not acted then
                                setStatus(true, tostring(info or "idle"))
                            end
                        else
                            pathCache = {}
                            local message = tostring(result)
                            setStatus(true, "error: " .. string.sub(message, 1, 80))
                        end
                    end
                    if not acted then
                        setHighlight(nil)
                    end
                end
            end))
        end,
    })

    nuker:AddSection("Targets")
    nuker:AddToggle({ Label = "Break Beds", Key = "Beds", Default = true })
    nuker:AddToggle({ Label = "Break Lucky Blocks", Key = "LuckyBlocks", Default = true })
    nuker:AddToggle({ Label = "Break Iron Ore", Key = "IronOre", Default = true })
    nuker:AddToggle({ Label = "Self Break", Key = "SelfBreak", Default = false, Tip = "Also break your own bed and blocks you or your team placed." })
    nuker:AddOption({
        Label = "Target Mode", Key = "TargetMode", Options = { "Distance", "Health" }, Default = "Distance",
        Tip = "Distance digs in from the side closest to you. Health goes through the weakest blocks.",
    })
    nuker:AddSection("Range")
    nuker:AddSlider({ Label = "Range", Key = "Range", Min = 1, Max = 30, Default = 30, Step = 1, Suffix = " studs", Tip = "How far away a target can be." })
    nuker:AddSlider({ Label = "Break Angle", Key = "Angle", Min = 0, Max = 360, Default = 360, Step = 5, Suffix = "°", Tip = "Only dig through blocks inside this cone in front of your camera." })
    nuker:AddSlider({ Label = "Break Speed", Key = "BreakSpeed", Min = 0, Max = 0.3, Default = 0.25, Step = 0.01, Suffix = "s", Tip = "Wait between hits. Lower is faster." })
    nuker:AddSection("Behaviour")
    nuker:AddToggle({ Label = "Auto Tool", Key = "AutoTool", Default = true, Tip = "Swaps to the right tool by itself. Off = it waits until you hold it." })
    nuker:AddToggle({ Label = "Require Mouse Down", Key = "RequireMouseDown", Default = false, Tip = "Only dig while you hold left click." })
    nuker:AddToggle({ Label = "Limit to Items", Key = "LimitToItems", Default = false, Tip = "Only dig while you hold something that can break blocks." })
    nuker:AddToggle({ Label = "Block Highlight", Key = "Highlight", Default = true, Tip = "Box the block being hit." })
    nuker:AddButton({ Label = "Run Self Check", Tip = "Tests every step Nuker needs and reports which one fails.", Callback = runDiagnostics })
    nuker:AddNote("Bedwars only. It never touches your own team's blocks unless Self Break is on.")
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
        "GloriousConfigB2", "heywasupsir", "c6chisa",
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
    end

    local function prettyName(id)
        return (id:gsub("_", " "):gsub("(%a)([%w]*)", function(first, rest)
            return first:upper() .. rest
        end))
    end

    local function equippedKits()
        local raw = LocalPlayer:GetAttribute("PlayingAsKits")
        local list = {}
        if type(raw) == "string" then
            for id in string.gmatch(raw, "[%w_]+") do
                if id ~= "none" then
                    list[#list + 1] = id
                end
            end
        end
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
                            if BY_ID[id] and mod.Config["Kit_" .. id] ~= false then
                                wanted[id] = true
                            end
                        end
                    end
                    for id, session in pairs(sessions) do
                        if not wanted[id] then
                            sessions[id] = nil
                            session:Stop()
                        end
                    end
                    for id in pairs(wanted) do
                        if not sessions[id] then
                            local session = newSession()
                            sessions[id] = session
                            session.Thread = task.spawn(function()
                                pcall(BY_ID[id].Run, session)
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
    local invEsp
    local panel
    local rows = {}
    local COLUMNS = 6

    local function inventoriesFolder()
        return ReplicatedStorage:FindFirstChild("Inventories")
    end

    -- Reads one replicated inventory folder into a flat list of { name, amount, group, order }
    local function readItems(folder, list)
        if not folder then
            return
        end
        local cfg = invEsp.Config
        for _, child in ipairs(folder:GetChildren()) do
            local amount = child:GetAttribute("Amount")
            if amount == nil and child:IsA("ValueBase") then
                amount = child.Value
            end
            amount = tonumber(amount) or 1
            if amount > 0 then
                local group, order = classify(child.Name)
                if cfg[GROUP_KEYS[group]] ~= false then
                    list[#list + 1] = { name = child.Name, amount = amount, group = group, order = order }
                end
            end
        end
    end

    local function collect(plr)
        local list = {}
        local folder = inventoriesFolder()
        if not folder then
            return list, ""
        end
        readItems(folder:FindFirstChild(plr.Name), list)
        if invEsp.Config.Personal then
            readItems(folder:FindFirstChild(plr.Name .. "_personal"), list)
        end
        table.sort(list, function(a, b)
            if a.order ~= b.order then
                return a.order < b.order
            end
            return a.name < b.name
        end)
        local parts = {}
        for _, item in ipairs(list) do
            parts[#parts + 1] = item.name .. ":" .. item.amount
        end
        return list, table.concat(parts, ",")
    end

    local function cellSize()
        return invEsp.Config.Size or 28
    end

    local function panelWidth()
        return COLUMNS * cellSize() + (COLUMNS - 1) * 3 + 16
    end

    local function placePanel()
        if not panel then
            return
        end
        local left = invEsp.Config.Side == "Left"
        panel.AnchorPoint = Vector2.new(left and 0 or 1, 0)
        panel.Position = left and UDim2.new(0, 12, 0, 90) or UDim2.new(1, -12, 0, 90)
        panel.Size = UDim2.fromOffset(panelWidth(), 0)
        for _, row in pairs(rows) do
            row.frame.Parent = panel
            row.grid.CellSize = UDim2.fromOffset(cellSize(), cellSize())
            row.signature = nil
        end
    end

    local function buildRow(plr)
        local frame = New("Frame", {
            Name = plr.Name,
            BackgroundColor3 = Theme.Panel,
            BackgroundTransparency = 0.1,
            BorderSizePixel = 0,
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            Parent = panel,
        }, {
            Round(8),
            Stroke(Theme.Stroke, 1, 0),
            Pad(8, 6, 8, 8),
            New("UIListLayout", { Padding = UDim.new(0, 5), SortOrder = Enum.SortOrder.LayoutOrder }),
        })

        local header = New("Frame", {
            Name = "Header",
            BackgroundTransparency = 1,
            Size = UDim2.new(1, 0, 0, 22),
            LayoutOrder = 1,
            Parent = frame,
        })
        local avatar = New("ImageLabel", {
            Name = "Avatar",
            BackgroundColor3 = Theme.Card,
            BorderSizePixel = 0,
            Size = UDim2.fromOffset(22, 22),
            Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(plr.UserId) .. "&w=48&h=48",
            Parent = header,
        }, { Round(11) })
        local avatarStroke = Stroke(Theme.AccentLight, 2, 0)
        avatarStroke.Parent = avatar
        local name = New("TextLabel", {
            Name = "Name",
            BackgroundTransparency = 1,
            Position = UDim2.fromOffset(28, 0),
            Size = UDim2.new(1, -52, 1, 0),
            Font = FONT.Bold,
            TextSize = 13,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            TextColor3 = Theme.Text,
            Text = plr.DisplayName,
            Parent = header,
        })
        local kit = New("ImageLabel", {
            Name = "Kit",
            BackgroundTransparency = 1,
            AnchorPoint = Vector2.new(1, 0),
            Position = UDim2.new(1, 0, 0, 0),
            Size = UDim2.fromOffset(22, 22),
            Image = "",
            Visible = false,
            Parent = header,
        })
        local grid = New("UIGridLayout", {
            CellSize = UDim2.fromOffset(cellSize(), cellSize()),
            CellPadding = UDim2.fromOffset(3, 3),
            SortOrder = Enum.SortOrder.LayoutOrder,
        })
        New("Frame", {
            Name = "Items",
            BackgroundTransparency = 1,
            Size = UDim2.fromScale(1, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            LayoutOrder = 2,
            Parent = frame,
        }, { grid })

        return {
            frame = frame, name = name, avatarStroke = avatarStroke, kit = kit, grid = grid,
            items = frame.Items, signature = nil,
        }
    end

    local function fillItems(row, list)
        for _, child in ipairs(row.items:GetChildren()) do
            if child:IsA("GuiObject") then
                child:Destroy()
            end
        end
        for index, item in ipairs(list) do
            local cell = New("Frame", {
                Name = item.name,
                BackgroundColor3 = Theme.Card,
                BackgroundTransparency = 0.15,
                BorderSizePixel = 0,
                LayoutOrder = index,
                Parent = row.items,
            }, { Round(5) })
            New("ImageLabel", {
                BackgroundTransparency = 1,
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0.5, 0.5),
                Size = UDim2.fromScale(0.82, 0.82),
                Image = itemIcon(item.name),
                Parent = cell,
            })
            if item.amount > 1 then
                New("TextLabel", {
                    BackgroundTransparency = 1,
                    AnchorPoint = Vector2.new(1, 1),
                    Position = UDim2.new(1, -2, 1, -1),
                    Size = UDim2.fromOffset(cellSize(), 12),
                    Font = FONT.Bold,
                    TextSize = 11,
                    TextXAlignment = Enum.TextXAlignment.Right,
                    TextColor3 = Theme.Text,
                    TextStrokeTransparency = 0.3,
                    Text = shortCount(item.amount),
                    ZIndex = 2,
                    Parent = cell,
                })
            end
        end
    end

    local function removeRow(plr)
        local row = rows[plr]
        if row then
            row.frame:Destroy()
            rows[plr] = nil
        end
    end

    local function refreshPanel()
        local cfg = invEsp.Config
        local wanted = {}
        local candidates = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer and Util.GetCharacter(plr) and not (cfg.TeamCheck and sameTeam(plr)) then
                local distance = distanceTo(plr) or 0
                local limit = cfg.MaxDistance or 0
                if limit <= 0 or distance <= limit then
                    candidates[#candidates + 1] = { plr = plr, distance = distance }
                end
            end
        end
        table.sort(candidates, function(a, b)
            return a.distance < b.distance
        end)

        for index, entry in ipairs(candidates) do
            if index > 10 then
                break
            end
            local plr = entry.plr
            local list, signature = collect(plr)
            if #list > 0 then
                wanted[plr] = true
                local row = rows[plr] or buildRow(plr)
                rows[plr] = row
                row.frame.LayoutOrder = index
                row.frame.Parent = panel
                local color = teamColor(plr)
                row.name.TextColor3 = color
                row.avatarStroke.Color = color
                row.name.Text = plr.DisplayName

                local kit = cfg.Kits and kitOf(plr)
                local kitKey = kit or ""
                if kit then
                    row.kit.Image = kitIcon(kit)
                end
                row.kit.Visible = kit ~= nil and kit ~= false and row.kit.Image ~= ""

                local key = signature .. "|" .. kitKey .. "|" .. tostring(cellSize())
                if row.signature ~= key then
                    row.signature = key
                    fillItems(row, list)
                end
            end
        end

        for plr in pairs(rows) do
            if not wanted[plr] then
                removeRow(plr)
            end
        end
    end

    local function clearPanel()
        for plr in pairs(rows) do
            removeRow(plr)
        end
        if panel then
            panel:Destroy()
            panel = nil
        end
    end

    invEsp = Tabs.Render:CreateModule({
        Name = "Inventory ESP",
        Description = "Side panel showing what every enemy is carrying.",
        OnEnable = function(mod)
            pcall(Bedwars.ResolveExtras)
            assert(inventoriesFolder(), "Inventories not found - join a Bedwars match first")

            panel = New("Frame", {
                Name = "NovaInventoryEsp",
                BackgroundTransparency = 1,
                Size = UDim2.fromOffset(panelWidth(), 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                ZIndex = 0,
                Parent = UI.Gui,
            }, {
                New("UIListLayout", {
                    Padding = UDim.new(0, 6),
                    SortOrder = Enum.SortOrder.LayoutOrder,
                    HorizontalAlignment = Enum.HorizontalAlignment.Center,
                }),
            })
            placePanel()
            mod.Maid:Give(clearPanel)

            mod.Maid:Give(task.spawn(function()
                while mod.Enabled do
                    pcall(refreshPanel)
                    task.wait(0.5)
                end
            end))
        end,
    })

    invEsp:AddSection("Display")
    invEsp:AddOption({
        Label = "Side", Key = "Side", Options = { "Right", "Left" }, Default = "Right",
        Callback = placePanel,
    })
    invEsp:AddSlider({
        Label = "Icon Size", Key = "Size", Min = 20, Max = 44, Default = 28, Step = 2, Suffix = " px",
        Callback = placePanel,
    })
    invEsp:AddToggle({ Label = "Show Kits", Key = "Kits", Default = false, Tip = "Adds the player's kit icon to their row." })
    invEsp:AddToggle({ Label = "Personal Chest", Key = "Personal", Default = false, Tip = "Also lists what they keep in their personal chest." })
    invEsp:AddSection("Players")
    invEsp:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true, Tip = "Hide your teammates." })
    invEsp:AddSlider({
        Label = "Max Distance", Key = "MaxDistance", Min = 0, Max = 1000, Default = 0, Step = 25, Suffix = " studs",
        Tip = "0 = show everyone, no matter how far.",
    })
    invEsp:AddSection("Items")
    invEsp:AddToggle({ Label = "Weapons", Key = "ShowWeapons", Default = true })
    invEsp:AddToggle({ Label = "Armor", Key = "ShowArmor", Default = true })
    invEsp:AddToggle({ Label = "Tools", Key = "ShowTools", Default = true })
    invEsp:AddToggle({ Label = "Resources", Key = "ShowResources", Default = true })
    invEsp:AddToggle({ Label = "Blocks", Key = "ShowBlocks", Default = false })
    invEsp:AddToggle({ Label = "Other", Key = "ShowOther", Default = true })
    invEsp:AddNote("Shows at most the 10 nearest players. Needs to be in a Bedwars match.")

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
            for _, plr in ipairs(Players:GetPlayers()) do
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
    local function countsOf(plr)
        local counts = {}
        local folder = inventoriesFolder()
        local inventory = folder and folder:FindFirstChild(plr.Name)
        if inventory then
            for _, child in ipairs(inventory:GetChildren()) do
                local amount = child:GetAttribute("Amount")
                if amount == nil and child:IsA("ValueBase") then
                    amount = child.Value
                end
                counts[child.Name] = tonumber(amount) or 1
            end
        end
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
    local function buildTag(entry)
        local cfg = cfgOf()
        local size = iconSize()
        local fontOk, font = pcall(function()
            return Enum.Font[cfg.Font or "Gotham"]
        end)
        font = fontOk and font or FONT.Bold

        local gui = New("BillboardGui", {
            Name = "NovaTag",
            Size = UDim2.fromOffset(520, 220),
            StudsOffsetWorldSpace = Vector3.new(0, 2.4, 0),
            AlwaysOnTop = true,
            LightInfluence = 0,
            ResetOnSpawn = false,
            Parent = tagFolder,
        })
        local stack = New("Frame", {
            Name = "Stack",
            AnchorPoint = Vector2.new(0.5, 1),
            Position = UDim2.fromScale(0.5, 1),
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
            pcall(function()
                drawn.Text.Visible = false
                drawn.BG.Visible = false
                drawn.Text:Remove()
                drawn.BG:Remove()
            end)
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

        local tag = tags[entry.key] or buildTag(entry)
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
            tagFolder = New("Folder", { Name = "NovaNameTags", Parent = UI.Gui })
            mod.Maid:Give(function()
                resetTags()
                restoreDefaults()
                if tagFolder then
                    tagFolder:Destroy()
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
                    pcall(refreshTags)
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
        Label = "Hide Game Tags", Key = "HideGameTags", Default = true,
        Tip = "Hides the game's own name tags while this is on.", Callback = defaultsChanged,
    })
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
        applyAccent(ACCENT_SWATCHES[savedAccent])
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
local __run = loadstring(__nova, "=Nova")
if not __run then
    error("Nova could not be compiled by this executor")
end
return __run(__nova)
