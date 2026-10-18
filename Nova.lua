--[[
    ███  Nova  ███
    Closet-style utility for Roblox  |  Single file  |  Built for Xeno

    Open / close UI : RightShift
    Settings        : gear icon (top right) -> Notifications, Reinject, Uninject
    Keybinds        : click the small box on any module, type a key name
                      (e.g. "E", "Q", "LeftAlt", "F4") and click away. Type "none" to clear.

    Global table    : getgenv().Nova   (settings live in Nova.Config)
    Kill Aura hook  : getgenv().Nova.Hooks.KillAura = function(character, tool, rootPart) ... end
                      (set this for games that use remotes instead of Tool:Activate())
]]

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

-- Shared "Require Mouse Down" + "Limit to Items" gate.
-- `gate` is a table the caller owns (stores the grace-window timestamp).
function Util.PassesGate(cfg, gate, grace)
    if cfg.RequireMouseDown then
        local button = (cfg.MouseButton == "Right") and Enum.UserInputType.MouseButton2 or Enum.UserInputType.MouseButton1
        if UserInputService:IsMouseButtonPressed(button) then
            gate.LastActive = os.clock()
        elseif os.clock() - (gate.LastActive or 0) > (grace or 0.15) then
            return false
        end
    end
    if cfg.LimitToItems and not Util.GetHeldTool(cfg.ItemNames) then
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

function Util.HasLineOfSight(origin, targetPosition)
    RayFilter.Refresh()
    local hit = Workspace:Raycast(origin, targetPosition - origin, RayFilter.Params)
    return hit == nil
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
local CONFIG_VERSION = 3
if Nova.Config.__v ~= CONFIG_VERSION then
    Nova.Config = { UI = Nova.Config.UI or {}, __v = CONFIG_VERSION }
end
Nova.Config.UI = Nova.Config.UI or {}
if Nova.Config.UI.Notifications == nil then
    Nova.Config.UI.Notifications = true
end
env.Nova = Nova

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
local Theme = {
    Background = Color3.fromRGB(14, 12, 22),
    Panel      = Color3.fromRGB(20, 17, 32),
    Card       = Color3.fromRGB(27, 23, 43),
    Accent     = Color3.fromRGB(152, 98, 255),
    AccentDark = Color3.fromRGB(104, 62, 205),
    Text       = Color3.fromRGB(238, 232, 252),
    TextDim    = Color3.fromRGB(150, 141, 178),
    Stroke     = Color3.fromRGB(52, 45, 78),
    Good       = Color3.fromRGB(110, 224, 150),
    Bad        = Color3.fromRGB(255, 96, 118),
}

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

local function Stroke(color, thickness)
    return New("UIStroke", {
        Color = color or Theme.Stroke,
        Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
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

local UI = { Tabs = {}, TabList = {}, Visible = false }

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

local WINDOW_W, WINDOW_H = 680, 440
local SIDEBAR_W, TOPBAR_H = 150, 46

UI.Main = New("Frame", {
    Name = "Main",
    Size = UDim2.fromOffset(WINDOW_W, WINDOW_H),
    Position = UDim2.fromScale(0.5, 0.5),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = Theme.Background,
    BorderSizePixel = 0,
    Visible = false,
    Parent = UI.Gui,
}, { Round(14), Stroke(Theme.Stroke, 1) })

UI.Scale = New("UIScale", { Scale = 1, Parent = UI.Main })

-- Modal button lets the cursor free itself in shift-lock / first person games
UI.ModalButton = New("TextButton", {
    Size = UDim2.fromOffset(0, 0),
    BackgroundTransparency = 1,
    Text = "",
    Modal = false,
    Parent = UI.Main,
})

-- Top bar ------------------------------------------------------------
local TopBar = New("Frame", {
    Name = "TopBar",
    Size = UDim2.new(1, 0, 0, TOPBAR_H),
    BackgroundTransparency = 1,
    Parent = UI.Main,
})

New("TextLabel", {
    Position = UDim2.fromOffset(18, 0),
    Size = UDim2.fromOffset(70, TOPBAR_H),
    BackgroundTransparency = 1,
    Text = "Nova",
    Font = Enum.Font.GothamBold,
    TextSize = 23,
    TextColor3 = Color3.new(1, 1, 1),
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = TopBar,
}, {
    New("UIGradient", {
        Color = ColorSequence.new(Theme.Accent, Color3.fromRGB(214, 180, 255)),
    }),
})

New("TextLabel", {
    Position = UDim2.fromOffset(80, 4),
    Size = UDim2.fromOffset(80, TOPBAR_H),
    BackgroundTransparency = 1,
    Text = "v" .. Nova.Version,
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextColor3 = Theme.TextDim,
    TextXAlignment = Enum.TextXAlignment.Left,
    Parent = TopBar,
})

New("Frame", {
    Position = UDim2.fromOffset(0, TOPBAR_H),
    Size = UDim2.new(1, 0, 0, 1),
    BackgroundColor3 = Theme.Stroke,
    BorderSizePixel = 0,
    Parent = UI.Main,
})

New("Frame", {
    Position = UDim2.fromOffset(SIDEBAR_W, TOPBAR_H + 1),
    Size = UDim2.new(0, 1, 1, -(TOPBAR_H + 1)),
    BackgroundColor3 = Theme.Stroke,
    BorderSizePixel = 0,
    Parent = UI.Main,
})

-- Sidebar & pages ----------------------------------------------------
local Sidebar = New("Frame", {
    Name = "Sidebar",
    Position = UDim2.fromOffset(0, TOPBAR_H + 1),
    Size = UDim2.new(0, SIDEBAR_W, 1, -(TOPBAR_H + 1)),
    BackgroundTransparency = 1,
    Parent = UI.Main,
}, {
    New("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
    New("UIPadding", {
        PaddingTop = UDim.new(0, 12), PaddingLeft = UDim.new(0, 10),
        PaddingRight = UDim.new(0, 10),
    }),
})

local Pages = New("Frame", {
    Name = "Pages",
    Position = UDim2.fromOffset(SIDEBAR_W + 1, TOPBAR_H + 1),
    Size = UDim2.new(1, -(SIDEBAR_W + 1), 1, -(TOPBAR_H + 1)),
    BackgroundTransparency = 1,
    ClipsDescendants = true,
    Parent = UI.Main,
})

-- Shared small switch widget ----------------------------------------
local function createSwitch(parent, width, height)
    local knobSize = height - 6
    local track = New("Frame", {
        Size = UDim2.fromOffset(width, height),
        BackgroundColor3 = Theme.Stroke,
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

    local function set(state, instant)
        local pos = UDim2.fromOffset(state and (width - knobSize - 3) or 3, 3)
        local trackColor = state and Theme.Accent or Theme.Stroke
        local knobColor = state and Color3.new(1, 1, 1) or Theme.TextDim
        if instant then
            track.BackgroundColor3 = trackColor
            knob.Position = pos
            knob.BackgroundColor3 = knobColor
        else
            Tween(track, 0.18, { BackgroundColor3 = trackColor })
            Tween(knob, 0.18, { Position = pos, BackgroundColor3 = knobColor })
        end
    end

    return track, set, click
end

-- Tabs ---------------------------------------------------------------
function UI:SelectTab(selected)
    for _, tab in ipairs(UI.TabList) do
        local active = (tab == selected)
        tab.Page.Visible = active
        Tween(tab.Button, 0.2, { BackgroundTransparency = active and 0.8 or 1 })
        Tween(tab.Indicator, 0.2, { BackgroundTransparency = active and 0 or 1 })
        Tween(tab.Label, 0.2, { TextColor3 = active and Theme.Text or Theme.TextDim })
    end
    UI.CurrentTab = selected
end

function UI:CreateTab(name)
    local tab = { Name = name, Modules = {} }

    tab.Button = New("TextButton", {
        Name = name,
        Size = UDim2.new(1, 0, 0, 38),
        BackgroundColor3 = Theme.Accent,
        BackgroundTransparency = 1,
        AutoButtonColor = false,
        Text = "",
        LayoutOrder = #UI.TabList + 1,
        Parent = Sidebar,
    }, { Round(8) })

    tab.Indicator = New("Frame", {
        Size = UDim2.fromOffset(3, 18),
        Position = UDim2.new(0, 0, 0.5, -9),
        BackgroundColor3 = Theme.Accent,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Parent = tab.Button,
    }, { Round(2) })

    tab.Label = New("TextLabel", {
        Position = UDim2.fromOffset(16, 0),
        Size = UDim2.new(1, -16, 1, 0),
        BackgroundTransparency = 1,
        Text = name,
        Font = Enum.Font.GothamMedium,
        TextSize = 14,
        TextColor3 = Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = tab.Button,
    })

    tab.Page = New("ScrollingFrame", {
        Name = name .. "Page",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = Theme.Accent,
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Visible = false,
        Parent = Pages,
    }, {
        New("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
        New("UIPadding", {
            PaddingTop = UDim.new(0, 12), PaddingBottom = UDim.new(0, 12),
            PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14),
        }),
    })

    tab.Button.MouseButton1Click:Connect(function()
        UI:SelectTab(tab)
    end)

    -- Dim info card (used for "more coming soon" placeholders)
    function tab:CreatePlaceholder(text)
        New("TextLabel", {
            Size = UDim2.new(1, 0, 0, 40),
            BackgroundColor3 = Theme.Card,
            BackgroundTransparency = 0.4,
            Text = text,
            Font = Enum.Font.Gotham,
            TextSize = 12,
            TextColor3 = Theme.TextDim,
            LayoutOrder = 9999,
            Parent = tab.Page,
        }, { Round(10), Stroke(Theme.Stroke, 1) })
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
        }

        Nova.Config[def.Name] = Nova.Config[def.Name] or {}
        local cfg = Nova.Config[def.Name]
        mod.Config = cfg
        if cfg.Key == nil then
            cfg.Key = def.Key or "None"
        end

        local card = New("Frame", {
            Name = def.Name,
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = Theme.Card,
            BorderSizePixel = 0,
            LayoutOrder = #tab.Modules + 1,
            Parent = tab.Page,
        }, {
            Round(10),
            Stroke(Theme.Stroke, 1),
            New("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }),
        })

        local header = New("Frame", {
            Name = "Header",
            Size = UDim2.new(1, 0, 0, 48),
            BackgroundTransparency = 1,
            LayoutOrder = 1,
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
            Position = UDim2.fromOffset(14, 0),
            Size = UDim2.fromOffset(14, 48),
            BackgroundTransparency = 1,
            Text = "",
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            TextColor3 = Theme.TextDim,
            Parent = headerButton,
        })

        local nameLabel = New("TextLabel", {
            Position = UDim2.fromOffset(34, 7),
            Size = UDim2.new(1, -190, 0, 18),
            BackgroundTransparency = 1,
            Text = def.Name,
            Font = Enum.Font.GothamMedium,
            TextSize = 14,
            TextColor3 = Theme.Text,
            TextXAlignment = Enum.TextXAlignment.Left,
            Parent = headerButton,
        })

        New("TextLabel", {
            Position = UDim2.fromOffset(34, 25),
            Size = UDim2.new(1, -190, 0, 16),
            BackgroundTransparency = 1,
            Text = def.Description or "",
            Font = Enum.Font.Gotham,
            TextSize = 11,
            TextColor3 = Theme.TextDim,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextTruncate = Enum.TextTruncate.AtEnd,
            Parent = headerButton,
        })

        -- Master toggle switch
        local switchTrack, setSwitch, switchClick = createSwitch(header, 42, 22)
        switchTrack.AnchorPoint = Vector2.new(1, 0.5)
        switchTrack.Position = UDim2.new(1, -14, 0.5, 0)

        -- Keybind TextBox (typed key name method)
        local keyBox = New("TextBox", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -66, 0.5, 0),
            Size = UDim2.fromOffset(76, 24),
            BackgroundColor3 = Theme.Panel,
            BorderSizePixel = 0,
            Text = cfg.Key,
            PlaceholderText = "Bind",
            PlaceholderColor3 = Theme.TextDim,
            TextColor3 = (cfg.Key == "None") and Theme.TextDim or Theme.Accent,
            Font = Enum.Font.GothamMedium,
            TextSize = 12,
            ClearTextOnFocus = true,
            Parent = header,
        }, { Round(6), Stroke(Theme.Stroke, 1) })

        keyBox.Focused:Connect(function()
            keyBox.PlaceholderText = "key / none"
        end)

        keyBox.FocusLost:Connect(function()
            keyBox.PlaceholderText = "Bind"
            local text = keyBox.Text:gsub("%s+", "")
            local lowered = text:lower()
            if text ~= "" then
                if lowered == "none" or lowered == "clear" then
                    cfg.Key = "None"
                    Nova.Notify(def.Name, "Keybind cleared", 2)
                else
                    local keyCode = KeyLookup[lowered]
                    if not keyCode then
                        Nova.Notify(def.Name, "Unknown key: " .. text, 3, "error")
                    elseif keyCode == Enum.KeyCode.RightShift then
                        Nova.Notify(def.Name, "RightShift is reserved for the UI", 3, "error")
                    else
                        cfg.Key = keyCode.Name
                        Nova.Notify(def.Name, "Bound to " .. keyCode.Name, 2)
                    end
                end
            end
            keyBox.Text = cfg.Key
            keyBox.TextColor3 = (cfg.Key == "None") and Theme.TextDim or Theme.Accent
        end)

        -- Settings body (hidden until expanded)
        local body = New("Frame", {
            Name = "Body",
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Visible = false,
            LayoutOrder = 2,
            Parent = card,
        }, {
            New("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
            New("UIPadding", {
                PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14),
                PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 14),
            }),
        })

        New("Frame", {
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = Theme.Stroke,
            BorderSizePixel = 0,
            LayoutOrder = 0,
            Parent = body,
        })

        local order = 0
        local expanded = false
        local expandable = false

        local function setExpanded(state)
            expanded = state
            body.Visible = state
            arrow.Text = state and "v" or ">"
        end

        local function ensureExpandable()
            if not expandable then
                expandable = true
                arrow.Text = ">"
            end
        end

        headerButton.MouseButton1Click:Connect(function()
            if expandable then
                setExpanded(not expanded)
            end
        end)

        local function newRow(height)
            order = order + 1
            return New("Frame", {
                Size = UDim2.new(1, 0, 0, height),
                BackgroundTransparency = 1,
                LayoutOrder = order,
                Parent = body,
            })
        end

        local function rowLabel(parent, text, widthOffset)
            return New("TextLabel", {
                Size = UDim2.new(1, widthOffset or -60, 0, 18),
                BackgroundTransparency = 1,
                Text = text,
                Font = Enum.Font.Gotham,
                TextSize = 13,
                TextColor3 = Theme.Text,
                TextXAlignment = Enum.TextXAlignment.Left,
                Parent = parent,
            })
        end

        -- Controls --------------------------------------------------
        function mod:AddToggle(o)
            ensureExpandable()
            local key = o.Key
            if cfg[key] == nil then
                cfg[key] = o.Default and true or false
            end
            local r = newRow(24)
            local label = rowLabel(r, o.Label, -60)
            label.Size = UDim2.new(1, -60, 1, 0)
            local track, set, click = createSwitch(r, 36, 20)
            track.AnchorPoint = Vector2.new(1, 0.5)
            track.Position = UDim2.new(1, 0, 0.5, 0)
            set(cfg[key], true)
            click.MouseButton1Click:Connect(function()
                cfg[key] = not cfg[key]
                set(cfg[key], false)
                if o.Callback then
                    pcall(o.Callback, cfg[key])
                end
            end)
        end

        function mod:AddSlider(o)
            ensureExpandable()
            local key, min, max, step = o.Key, o.Min, o.Max, o.Step or 1
            if cfg[key] == nil then
                cfg[key] = o.Default or min
            end
            local r = newRow(42)
            rowLabel(r, o.Label, -80)
            local valueLabel = New("TextLabel", {
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, 0, 0, 0),
                Size = UDim2.fromOffset(80, 18),
                BackgroundTransparency = 1,
                Text = "",
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.Accent,
                TextXAlignment = Enum.TextXAlignment.Right,
                Parent = r,
            })
            local track = New("Frame", {
                Position = UDim2.new(0, 0, 0, 29),
                Size = UDim2.new(1, 0, 0, 6),
                BackgroundColor3 = Theme.Stroke,
                BorderSizePixel = 0,
                Parent = r,
            }, { Round(3) })
            local fill = New("Frame", {
                Size = UDim2.fromScale(0, 1),
                BackgroundColor3 = Theme.Accent,
                BorderSizePixel = 0,
                Parent = track,
            }, { Round(3) })
            local knob = New("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.fromScale(0, 0.5),
                Size = UDim2.fromOffset(12, 12),
                BackgroundColor3 = Color3.new(1, 1, 1),
                BorderSizePixel = 0,
                Parent = track,
            }, { Round(6) })
            local hit = New("TextButton", {
                Position = UDim2.new(0, 0, 0, 20),
                Size = UDim2.new(1, 0, 0, 22),
                BackgroundTransparency = 1,
                Text = "",
                Parent = r,
            })

            local function apply(value, fire)
                value = math.clamp(value, min, max)
                value = math.floor(value / step + 0.5) * step
                value = math.clamp(value, min, max)
                value = tonumber(string.format("%.4f", value))
                cfg[key] = value
                local alpha = (max > min) and ((value - min) / (max - min)) or 0
                fill.Size = UDim2.fromScale(alpha, 1)
                knob.Position = UDim2.fromScale(alpha, 0.5)
                valueLabel.Text = tostring(value) .. (o.Suffix or "")
                if fire and o.Callback then
                    pcall(o.Callback, value)
                end
            end

            local function fromInput(input)
                local alpha = math.clamp((input.Position.X - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
                apply(min + (max - min) * alpha, true)
            end

            hit.InputBegan:Connect(function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1
                    or input.UserInputType == Enum.UserInputType.Touch then
                    UI.ActiveDrag = fromInput
                    fromInput(input)
                end
            end)

            apply(cfg[key], false)
        end

        function mod:AddOption(o)
            ensureExpandable()
            local key, list = o.Key, o.Options
            if cfg[key] == nil then
                cfg[key] = o.Default or list[1]
            end
            local r = newRow(28)
            local label = rowLabel(r, o.Label, -130)
            label.Size = UDim2.new(1, -130, 1, 0)
            local button = New("TextButton", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, 0, 0.5, 0),
                Size = UDim2.fromOffset(120, 24),
                BackgroundColor3 = Theme.Panel,
                BorderSizePixel = 0,
                AutoButtonColor = false,
                Text = "",
                Parent = r,
            }, { Round(6), Stroke(Theme.Stroke, 1) })
            local text = New("TextLabel", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "",
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.Accent,
                Parent = button,
            })
            local function set(value, fire)
                cfg[key] = value
                text.Text = tostring(value)
                if fire and o.Callback then
                    pcall(o.Callback, value)
                end
            end
            button.MouseButton1Click:Connect(function()
                local index = table.find(list, cfg[key]) or 0
                set(list[(index % #list) + 1], true)
            end)
            set(cfg[key], false)
        end

        function mod:AddTextBox(o)
            ensureExpandable()
            local key = o.Key
            if cfg[key] == nil then
                cfg[key] = o.Default or ""
            end
            local r = newRow(28)
            local label = rowLabel(r, o.Label, -150)
            label.Size = UDim2.new(1, -150, 1, 0)
            local box = New("TextBox", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, 0, 0.5, 0),
                Size = UDim2.fromOffset(140, 24),
                BackgroundColor3 = Theme.Panel,
                BorderSizePixel = 0,
                Text = tostring(cfg[key]),
                PlaceholderText = o.Placeholder or "",
                PlaceholderColor3 = Theme.TextDim,
                TextColor3 = Theme.Accent,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                ClearTextOnFocus = false,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Parent = r,
            }, { Round(6), Stroke(Theme.Stroke, 1) })
            box.FocusLost:Connect(function()
                cfg[key] = box.Text
                if o.Callback then
                    pcall(o.Callback, box.Text)
                end
            end)
        end

        function mod:AddLabel(text)
            ensureExpandable()
            local r = newRow(30)
            local label = rowLabel(r, text, 0)
            label.Size = UDim2.new(1, 0, 1, 0)
            label.TextColor3 = Theme.TextDim
            label.TextSize = 11
            label.TextWrapped = true
            label.TextYAlignment = Enum.TextYAlignment.Top
        end

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
                    warn("[Nova] " .. def.Name .. " failed to enable: " .. tostring(err))
                    Nova.Notify(def.Name, string.sub(tostring(err), 1, 70), 4, "error", true)
                    setSwitch(false, true)
                    return
                end
            else
                self.Enabled = false
                if def.OnDisable then
                    pcall(def.OnDisable, self)
                end
                self.Maid:Clean()
            end

            setSwitch(self.Enabled, silent)
            if not silent then
                Nova.Notify(def.Name, self.Enabled and "Enabled" or "Disabled", 2, self.Enabled and "success" or "info")
            end
        end

        function mod:Toggle()
            self:SetEnabled(not self.Enabled)
        end

        switchClick.MouseButton1Click:Connect(function()
            mod:Toggle()
        end)

        setSwitch(false, true)
        tab.Modules[#tab.Modules + 1] = mod
        Nova.ModuleList[#Nova.ModuleList + 1] = mod
        return mod
    end

    UI.Tabs[name] = tab
    UI.TabList[#UI.TabList + 1] = tab
    return tab
end

-- ====================== MODULE: NOTIFICATIONS ======================
local NotifHolder = New("Frame", {
    Name = "Notifications",
    AnchorPoint = Vector2.new(1, 1),
    Position = UDim2.new(1, -20, 1, -20),
    Size = UDim2.fromOffset(280, 500),
    BackgroundTransparency = 1,
    Parent = UI.Gui,
}, {
    New("UIListLayout", {
        FillDirection = Enum.FillDirection.Vertical,
        HorizontalAlignment = Enum.HorizontalAlignment.Right,
        VerticalAlignment = Enum.VerticalAlignment.Bottom,
        SortOrder = Enum.SortOrder.LayoutOrder,
        Padding = UDim.new(0, 8),
    }),
})

local notifCounter = 0

-- kind: "info" (default) | "success" | "error".  `force` ignores the Notifications toggle.
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
    end

    local wrap = New("Frame", {
        Size = UDim2.fromOffset(270, 60),
        BackgroundTransparency = 1,
        LayoutOrder = notifCounter,
        Parent = NotifHolder,
    })

    local card = New("Frame", {
        Size = UDim2.fromScale(1, 1),
        Position = UDim2.new(1, 330, 0, 0),
        BackgroundColor3 = Theme.Card,
        BorderSizePixel = 0,
        Parent = wrap,
    }, { Round(10), Stroke(Theme.Stroke, 1) })

    New("Frame", {
        Position = UDim2.fromOffset(8, 10),
        Size = UDim2.new(0, 3, 1, -20),
        BackgroundColor3 = accent,
        BorderSizePixel = 0,
        Parent = card,
    }, { Round(2) })

    New("TextLabel", {
        Position = UDim2.fromOffset(20, 8),
        Size = UDim2.new(1, -30, 0, 18),
        BackgroundTransparency = 1,
        Text = tostring(title),
        Font = Enum.Font.GothamBold,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = card,
    })

    New("TextLabel", {
        Position = UDim2.fromOffset(20, 26),
        Size = UDim2.new(1, -30, 0, 18),
        BackgroundTransparency = 1,
        Text = tostring(text),
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextColor3 = Theme.TextDim,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
        Parent = card,
    })

    local bar = New("Frame", {
        Position = UDim2.new(0, 20, 1, -8),
        Size = UDim2.new(1, -40, 0, 2),
        BackgroundColor3 = accent,
        BackgroundTransparency = 0.3,
        BorderSizePixel = 0,
        Parent = card,
    }, { Round(1) })

    task.spawn(function()
        pcall(function()
            Tween(card, 0.45, { Position = UDim2.new(0, 0, 0, 0) }, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
            Tween(bar, duration, { Size = UDim2.new(0, 0, 0, 2) }, Enum.EasingStyle.Linear)
            task.wait(duration)
            Tween(card, 0.35, { Position = UDim2.new(1, 330, 0, 0) }, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
            task.wait(0.35)
            Tween(wrap, 0.2, { Size = UDim2.fromOffset(270, 0) })
            task.wait(0.2)
            wrap:Destroy()
        end)
    end)
end

-- ====================== MODULE: SETTINGS MENU (GEAR) ======================
local gearButton = New("TextButton", {
    Name = "Gear",
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -14, 0, TOPBAR_H / 2),
    Size = UDim2.fromOffset(30, 30),
    BackgroundColor3 = Theme.Card,
    AutoButtonColor = false,
    Text = "⚙",
    Font = Enum.Font.GothamBold,
    TextSize = 18,
    TextColor3 = Theme.TextDim,
    Parent = TopBar,
}, { Round(8), Stroke(Theme.Stroke, 1) })

gearButton.MouseEnter:Connect(function()
    Tween(gearButton, 0.15, { TextColor3 = Theme.Accent })
end)
gearButton.MouseLeave:Connect(function()
    Tween(gearButton, 0.15, { TextColor3 = Theme.TextDim })
end)

local SettingsMenu = New("Frame", {
    Name = "SettingsMenu",
    AnchorPoint = Vector2.new(1, 0),
    Position = UDim2.new(1, -14, 0, TOPBAR_H + 6),
    Size = UDim2.fromOffset(210, 150),
    BackgroundColor3 = Theme.Card,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 20,
    Parent = UI.Main,
}, {
    Round(10),
    Stroke(Theme.Stroke, 1),
    New("UIPadding", {
        PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10),
        PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12),
    }),
    New("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
})
local SettingsScale = New("UIScale", { Scale = 1, Parent = SettingsMenu })

do
    local row = New("Frame", {
        Size = UDim2.new(1, 0, 0, 26),
        BackgroundTransparency = 1,
        LayoutOrder = 1,
        Parent = SettingsMenu,
    })
    New("TextLabel", {
        Size = UDim2.new(1, -50, 1, 0),
        BackgroundTransparency = 1,
        Text = "Notifications",
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Parent = row,
    })
    local track, set, click = createSwitch(row, 38, 20)
    track.AnchorPoint = Vector2.new(1, 0.5)
    track.Position = UDim2.new(1, 0, 0.5, 0)
    set(Nova.Config.UI.Notifications, true)
    click.MouseButton1Click:Connect(function()
        Nova.Config.UI.Notifications = not Nova.Config.UI.Notifications
        set(Nova.Config.UI.Notifications, false)
        Nova.Notify("Nova", Nova.Config.UI.Notifications and "Notifications on" or "Notifications off", 2, "info", true)
    end)

    local function menuButton(text, color, order, callback)
        local button = New("TextButton", {
            Size = UDim2.new(1, 0, 0, 34),
            BackgroundColor3 = Theme.Panel,
            BorderSizePixel = 0,
            AutoButtonColor = false,
            Text = text,
            Font = Enum.Font.GothamMedium,
            TextSize = 13,
            TextColor3 = color,
            LayoutOrder = order,
            Parent = SettingsMenu,
        }, { Round(8), Stroke(Theme.Stroke, 1) })
        button.MouseEnter:Connect(function()
            Tween(button, 0.15, { BackgroundColor3 = Theme.Background })
        end)
        button.MouseLeave:Connect(function()
            Tween(button, 0.15, { BackgroundColor3 = Theme.Panel })
        end)
        button.MouseButton1Click:Connect(callback)
    end

    menuButton("Reinject", Theme.Accent, 2, function()
        Nova.Reinject()
    end)
    menuButton("Uninject", Theme.Bad, 3, function()
        Nova.Unload(false)
    end)
end

local function setSettingsMenu(state)
    if state then
        SettingsMenu.Visible = true
        SettingsScale.Scale = 0.9
        Tween(SettingsScale, 0.18, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    else
        SettingsMenu.Visible = false
    end
end

gearButton.MouseButton1Click:Connect(function()
    setSettingsMenu(not SettingsMenu.Visible)
end)

-- ====================== MODULE: WINDOW BEHAVIOUR ======================
function UI:SetVisible(state)
    UI.Visible = state
    UI.ModalButton.Modal = state
    if state then
        UI.Main.Visible = true
        UI.Scale.Scale = 0.92
        Tween(UI.Scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
    else
        setSettingsMenu(false)
        Tween(UI.Scale, 0.15, { Scale = 0.92 })
        task.delay(0.15, function()
            if not UI.Visible and UI.Main then
                UI.Main.Visible = false
            end
        end)
    end
end

TopBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        UI.WindowDrag = { StartMouse = input.Position, StartPos = UI.Main.Position }
    end
end)

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
        UI.Main.Position = UDim2.new(
            drag.StartPos.X.Scale, drag.StartPos.X.Offset + delta.X,
            drag.StartPos.Y.Scale, drag.StartPos.Y.Offset + delta.Y
        )
    end
end))

Nova.Maid:Give(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        UI.ActiveDrag = nil
        UI.WindowDrag = nil
    end
end))

-- Global hotkeys: RightShift toggles UI, module keybinds toggle modules
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

-- ====================== TABS ======================
local Tabs = {
    Combat  = UI:CreateTab("Combat"),
    Render  = UI:CreateTab("Render"),
    Blatant = UI:CreateTab("Blatant"),
    World   = UI:CreateTab("World"),
    FPS     = UI:CreateTab("FPS"),
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

    aim:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players" })
    aim:AddSlider({ Label = "Smoothing", Key = "Smoothing", Min = 1, Max = 100, Default = 35, Step = 1 })
    aim:AddSlider({ Label = "FOV", Key = "FOV", Min = 20, Max = 600, Default = 150, Step = 5, Suffix = " px" })
    aim:AddSlider({ Label = "Prediction X", Key = "PredictionX", Min = 0, Max = 0.5, Default = 0.1, Step = 0.01 })
    aim:AddSlider({ Label = "Prediction Y", Key = "PredictionY", Min = 0, Max = 0.5, Default = 0.05, Step = 0.01 })
    aim:AddToggle({ Label = "Legit Mode", Key = "LegitMode", Default = true })
    aim:AddToggle({ Label = "Require Mouse Down", Key = "RequireMouseDown", Default = true })
    aim:AddOption({ Label = "Mouse Button", Key = "MouseButton", Options = MOUSE_BUTTONS, Default = "Right" })
    aim:AddToggle({ Label = "Limit to Items", Key = "LimitToItems", Default = false })
    aim:AddTextBox({ Label = "Item Names", Key = "ItemNames", Default = "", Placeholder = "blank = any tool" })
    aim:AddOption({ Label = "Aim Part", Key = "AimPart", Options = { "Head", "Torso", "Closest" }, Default = "Closest" })
    aim:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true })
    aim:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true })
    aim:AddToggle({ Label = "Show FOV Circle", Key = "ShowFOV", Default = true })
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

    hitbox:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players" })
    hitbox:AddSlider({ Label = "Size", Key = "Size", Min = 1, Max = 14, Default = 6, Step = 0.5, Suffix = " studs" })
    hitbox:AddLabel("Sizes above 10.5 have no extra effect.")
    hitbox:AddSlider({ Label = "Transparency", Key = "Transparency", Min = 0, Max = 1, Default = 0.85, Step = 0.05 })
    hitbox:AddToggle({ Label = "Inside Fix", Key = "InsideFix", Default = true })
    hitbox:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true })
    hitbox:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true })
end

-- ====================== MODULE: KILL AURA ======================
do
    local gate = {}

    -- "Click" attack method: a real left-click, so the game's own combat code does the hit.
    -- Only used while the Nova window is closed and the cursor isn't over a game button.
    local function canClick()
        if UI.Visible then
            return false, "close the Nova window"
        end
        if not mouse1click and not VirtualInputManager then
            return false, "no mouse input on this executor"
        end
        local position = UserInputService:GetMouseLocation()
        local inset = GuiService:GetGuiInset()
        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        if playerGui then
            local ok, objects = pcall(function()
                return playerGui:GetGuiObjectsAtPosition(position.X - inset.X, position.Y - inset.Y)
            end)
            if ok and objects then
                for _, object in ipairs(objects) do
                    if object:IsA("GuiButton") and object.Visible then
                        return false, "cursor is over a button"
                    end
                end
            end
        end
        return true
    end

    local function sendClick()
        if mouse1click and pcall(mouse1click) then
            return true
        end
        if VirtualInputManager then
            local position = UserInputService:GetMouseLocation()
            return (pcall(function()
                VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, 0, true, game, 1)
                VirtualInputManager:SendMouseButtonEvent(position.X, position.Y, 0, false, game, 1)
            end))
        end
        return false
    end

    local killAura = Tabs.Combat:CreateModule({
        Name = "Kill Aura",
        Description = "Attacks nearby players / NPCs with your held tool.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local lastAttack = 0
            local nextDelay = 0
            local lastManualSwing = 0
            local lastSelfActivate = 0
            local autoRotateOverridden = nil
            local flashUntil = 0
            local engagedSince = nil
            local lastAttackText, lastAttackAt = "", 0
            local lastStatus, lastStatusAt = "", 0

            -- Target adornment ("Show Target")
            local box = mod.Maid:Give(New("BoxHandleAdornment", {
                Size = Vector3.new(3.6, 5.8, 3.6),
                Transparency = 0.7,
                Color3 = Theme.Accent,
                AlwaysOnTop = true,
                ZIndex = 1,
                Adornee = nil,
                Parent = UI.Gui,
            }))

            -- Status line: always says what the aura is doing (or why it isn't attacking)
            local statusLabel = mod.Maid:Give(New("TextLabel", {
                AnchorPoint = Vector2.new(0.5, 1),
                Position = UDim2.new(0.5, 0, 1, -70),
                Size = UDim2.fromOffset(0, 26),
                AutomaticSize = Enum.AutomaticSize.X,
                BackgroundColor3 = Theme.Card,
                BackgroundTransparency = 0.1,
                BorderSizePixel = 0,
                Text = "Kill Aura: starting...",
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.Text,
                Visible = false,
                Parent = UI.Gui,
            }, {
                Round(8),
                Stroke(Theme.Stroke, 1),
                New("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }),
            }))

            local function setStatus(text)
                if not cfg.StatusLine then
                    if statusLabel.Visible then
                        statusLabel.Visible = false
                    end
                    return
                end
                statusLabel.Visible = true
                if text ~= lastStatus and os.clock() - lastStatusAt > 0.1 then
                    lastStatus = text
                    lastStatusAt = os.clock()
                    statusLabel.Text = "Kill Aura: " .. text
                end
            end

            -- Track manual swings so "Swing Only" works
            local function hookTool(tool)
                if tool:IsA("Tool") then
                    mod.Maid:Give(tool.Activated:Connect(function()
                        if os.clock() - lastSelfActivate > 0.25 then
                            lastManualSwing = os.clock()
                        end
                    end))
                end
            end
            local function hookCharacter(char)
                for _, child in ipairs(char:GetChildren()) do
                    hookTool(child)
                end
                mod.Maid:Give(char.ChildAdded:Connect(hookTool))
            end
            if LocalPlayer.Character then
                hookCharacter(LocalPlayer.Character)
            end
            mod.Maid:Give(LocalPlayer.CharacterAdded:Connect(hookCharacter))

            local function releaseRotation(hum)
                if autoRotateOverridden ~= nil and hum then
                    pcall(function()
                        hum.AutoRotate = autoRotateOverridden
                    end)
                end
                autoRotateOverridden = nil
            end

            local function getHandle(tool)
                local handle = tool:FindFirstChild("Handle")
                if handle and handle:IsA("BasePart") then
                    return handle
                end
                for _, descendant in ipairs(tool:GetDescendants()) do
                    if descendant:IsA("BasePart") then
                        return descendant
                    end
                end
                return nil
            end

            -- Returns (sent, description). When nothing was sent, description says why.
            local function attack(entry, tool)
                lastSelfActivate = os.clock()

                local hook = Nova.Hooks.KillAura
                if hook then
                    pcall(hook, entry.Model, tool, entry.Root)
                    return true, "custom hook"
                end

                if not tool then
                    return false, "no tool equipped"
                end

                local method = cfg.AttackMethod
                local hasTouch = firetouchinterest ~= nil
                local doActivate = method == "Auto" or method == "Activate" or (method == "Touch" and not hasTouch)
                local doClick = method == "Auto" or method == "Click"
                local doTouch = (method == "Auto" or method == "Touch") and hasTouch

                local used, notes = {}, {}

                -- Activate = the normal swing
                if doActivate then
                    pcall(function()
                        tool:Activate()
                    end)
                    used[#used + 1] = "Activate"
                end

                -- Click = real left-click through the game's own input code
                if doClick then
                    local allowed, reason = canClick()
                    if allowed and sendClick() then
                        used[#used + 1] = "Click"
                    else
                        notes[#notes + 1] = "click skipped: " .. tostring(reason or "failed")
                    end
                end

                -- Touch = fires the tool's Touched hit detection directly (works even when overlapping)
                if doTouch then
                    local handle = getHandle(tool)
                    if handle then
                        used[#used + 1] = "Touch"
                        task.delay(doActivate and 0.07 or 0, function()
                            if not handle.Parent or not entry.Root or not entry.Root.Parent then
                                return
                            end
                            local head = entry.Model:FindFirstChild("Head")
                            for _, part in ipairs({ entry.Root, head }) do
                                if part and part:IsA("BasePart") then
                                    pcall(firetouchinterest, handle, part, 0)
                                    pcall(firetouchinterest, handle, part, 1)
                                end
                            end
                        end)
                    else
                        notes[#notes + 1] = "touch skipped: tool has no parts"
                    end
                end

                local noteText = (#notes > 0) and (" (" .. table.concat(notes, "; ") .. ")") or ""
                if #used == 0 then
                    return false, (#notes > 0) and table.concat(notes, "; ") or "nothing to send"
                end
                return true, table.concat(used, "+") .. noteText
            end

            -- Returns nil when `entry` is a valid target, otherwise a short reason why not
            local function whyNot(entry, root, head, flatLook, halfCos)
                local isNpc = entry.Player == nil
                if cfg.Targets == "Players" and isNpc then
                    return "is an NPC (set Targets to Players + NPCs)"
                end
                if cfg.Targets == "NPCs Only" and not isNpc then
                    return "is a player (Targets = NPCs Only)"
                end
                if cfg.TeamCheck and entry.Player and Util.IsTeammate(entry.Player) then
                    return "is on your team (Team Check)"
                end
                local offset = entry.Root.Position - root.Position
                local distance = offset.Magnitude
                if distance > cfg.Range then
                    return string.format("is %.1f studs away (Range %.1f)", distance, cfg.Range)
                end
                local flat = Vector3.new(offset.X, 0, offset.Z)
                if cfg.Angle < 360 and flat.Magnitude >= 0.01 and flatLook:Dot(flat.Unit) < halfCos then
                    return "is outside Max Angle"
                end
                if cfg.WallCheck and not Util.HasLineOfSight(head.Position, entry.Root.Position) then
                    return "is behind a wall (Wall Check)"
                end
                return nil
            end

            -- Returns (entry) or (nil, reason)
            local function findTarget(char, root, cam)
                local head = char:FindFirstChild("Head") or root
                local look = cam and cam.CFrame.LookVector or root.CFrame.LookVector
                local flatLook = Vector3.new(look.X, 0, look.Z)
                if flatLook.Magnitude < 0.001 then
                    flatLook = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
                end
                flatLook = flatLook.Unit
                local halfCos = math.cos(math.rad(cfg.Angle) / 2)

                local best, bestScore = nil, math.huge
                local nearestEntry, nearestDistance, nearestReason = nil, math.huge, nil

                for _, entry in ipairs(Util.GetTargets("Players + NPCs")) do
                    local reason = whyNot(entry, root, head, flatLook, halfCos)
                    if not reason then
                        local score = (entry.Root.Position - root.Position).Magnitude
                        if cfg.TargetMode == "Health" then
                            score = entry.Humanoid.Health + score * 0.001
                        end
                        if score < bestScore then
                            best, bestScore = entry, score
                        end
                    else
                        local distance = (entry.Root.Position - root.Position).Magnitude
                        if distance < nearestDistance then
                            nearestEntry, nearestDistance, nearestReason = entry, distance, reason
                        end
                    end
                end

                if best then
                    return best
                end
                if nearestEntry then
                    return nil, tostring(nearestEntry.Name) .. " " .. nearestReason
                end
                return nil, "no other players or NPCs found"
            end

            local stepName = "Nova_KA_" .. Util.RandomName(6)
            RunService:BindToRenderStep(stepName, Enum.RenderPriority.Camera.Value + 2, function(dt)
                local char, hum, root = Util.GetCharacter(LocalPlayer)
                if not char or hum.Health <= 0 then
                    box.Adornee = nil
                    engagedSince = nil
                    setStatus("waiting for your character")
                    return
                end

                local cam = Workspace.CurrentCamera
                local function idle(reason)
                    box.Adornee = nil
                    engagedSince = nil
                    releaseRotation(hum)
                    setStatus(reason)
                end

                if not Util.PassesGate(cfg, gate, 0.2) then
                    if cfg.LimitToItems and not Util.GetHeldTool(cfg.ItemNames) then
                        idle("hold an item matching '" .. tostring(cfg.ItemNames) .. "' (Limit to Items)")
                    else
                        idle("hold the " .. string.lower(tostring(cfg.MouseButton)) .. " mouse button (Require Mouse Down)")
                    end
                    return
                end
                if cfg.SwingOnly and os.clock() - lastManualSwing > 0.45 then
                    idle("swing your tool to attack (Swing Only)")
                    return
                end

                local entry, reason = findTarget(char, root, cam)
                if not entry then
                    idle("no target - " .. tostring(reason))
                    return
                end

                local now = os.clock()
                engagedSince = engagedSince or now
                local targetRoot = entry.Root
                local targetText = string.format("%s (%.1f studs)", tostring(entry.Name), (targetRoot.Position - root.Position).Magnitude)

                -- Visual: target box (flashes on attack)
                if cfg.ShowTarget then
                    box.Adornee = targetRoot
                    box.Color3 = (now < flashUntil) and Color3.fromRGB(235, 215, 255) or Theme.Accent
                else
                    box.Adornee = nil
                end

                -- Facing
                local facingOk = true
                local flatTo = Vector3.new(targetRoot.Position.X - root.Position.X, 0, targetRoot.Position.Z - root.Position.Z)
                local needAngle = math.cos(math.rad(45))
                if cfg.Facing == "Visible" and cam then
                    local goal = CFrame.lookAt(cam.CFrame.Position, targetRoot.Position)
                    cam.CFrame = cam.CFrame:Lerp(goal, 1 - math.exp(-cfg.AimSpeed * dt))
                    local flatCam = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
                    if flatCam.Magnitude > 0.01 and flatTo.Magnitude > 0.01 then
                        facingOk = flatCam.Unit:Dot(flatTo.Unit) > needAngle
                    end
                elseif cfg.Facing == "Silent" then
                    if flatTo.Magnitude > 0.1 then
                        if autoRotateOverridden == nil then
                            autoRotateOverridden = hum.AutoRotate
                        end
                        hum.AutoRotate = false
                        local goal = CFrame.lookAt(root.Position, root.Position + flatTo)
                        root.CFrame = root.CFrame:Lerp(goal, math.clamp(1 - math.exp(-cfg.AimSpeed * dt), 0, 1))
                        local flatLook = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
                        if flatLook.Magnitude > 0.01 then
                            facingOk = flatLook.Unit:Dot(flatTo.Unit) > needAngle
                        end
                    end
                else
                    releaseRotation(hum)
                end

                -- If the game keeps overriding our rotation, don't let that block attacks forever
                if not facingOk and now - engagedSince > 0.3 then
                    facingOk = true
                end

                -- Attack timing
                local blockedText = nil
                if facingOk and now - lastAttack >= nextDelay then
                    local tool = Util.GetHeldTool(cfg.LimitToItems and cfg.ItemNames or "")
                    local sent, info = attack(entry, tool)
                    if sent then
                        lastAttack = now
                        flashUntil = now + 0.12
                        lastAttackAt = now
                        lastAttackText = "attacking " .. targetText .. " via " .. info
                        local delay = cfg.AttackDelay
                        if cfg.DynamicDelay then
                            local distance = (targetRoot.Position - root.Position).Magnitude
                            delay = math.max(0.08, delay * math.clamp(distance / math.max(cfg.Range, 1), 0.35, 1))
                        end
                        if cfg.RandomizeDelay then
                            delay = delay * (0.9 + math.random() * 0.3)
                        end
                        nextDelay = delay
                    else
                        blockedText = info
                    end
                end

                if blockedText then
                    setStatus(targetText .. " - " .. blockedText)
                elseif now - lastAttackAt < 0.5 and lastAttackText ~= "" then
                    setStatus(lastAttackText)
                elseif not facingOk then
                    setStatus("turning to face " .. targetText)
                else
                    setStatus("target " .. targetText)
                end
            end)

            mod.Maid:Give(function()
                pcall(function()
                    RunService:UnbindFromRenderStep(stepName)
                end)
                local _, hum = Util.GetCharacter(LocalPlayer)
                releaseRotation(hum)
            end)
        end,
    })

    killAura:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players" })
    killAura:AddOption({ Label = "Attack Method", Key = "AttackMethod", Options = { "Auto", "Click", "Activate", "Touch" }, Default = "Auto" })
    killAura:AddSlider({ Label = "Range", Key = "Range", Min = 4, Max = 20, Default = 8, Step = 0.5, Suffix = " studs" })
    killAura:AddSlider({ Label = "Max Angle", Key = "Angle", Min = 30, Max = 360, Default = 140, Step = 5, Suffix = "°" })
    killAura:AddSlider({ Label = "Attack Delay", Key = "AttackDelay", Min = 0.1, Max = 1, Default = 0.35, Step = 0.01, Suffix = "s" })
    killAura:AddToggle({ Label = "Randomize Delay", Key = "RandomizeDelay", Default = true })
    killAura:AddToggle({ Label = "Dynamic Delay", Key = "DynamicDelay", Default = false })
    killAura:AddOption({ Label = "Facing", Key = "Facing", Options = { "Off", "Silent", "Visible" }, Default = "Silent" })
    killAura:AddSlider({ Label = "Turn Speed", Key = "AimSpeed", Min = 1, Max = 20, Default = 8, Step = 1 })
    killAura:AddOption({ Label = "Target Mode", Key = "TargetMode", Options = { "Distance", "Health" }, Default = "Distance" })
    killAura:AddToggle({ Label = "Require Mouse Down", Key = "RequireMouseDown", Default = false })
    killAura:AddOption({ Label = "Mouse Button", Key = "MouseButton", Options = { "Left", "Right" }, Default = "Left" })
    killAura:AddToggle({ Label = "Limit to Items", Key = "LimitToItems", Default = false })
    killAura:AddTextBox({ Label = "Item Names", Key = "ItemNames", Default = "", Placeholder = "blank = any tool" })
    killAura:AddToggle({ Label = "Swing Only", Key = "SwingOnly", Default = false })
    killAura:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true })
    killAura:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true })
    killAura:AddToggle({ Label = "Show Target", Key = "ShowTarget", Default = true })
    killAura:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })
    killAura:AddLabel("Auto = swing + touch + click. Click is a real left-click (window closed, cursor off buttons). Remote-based games: set Nova.Hooks.KillAura.")
end

-- ====================== MODULE: BEDWARS BRIDGE ======================
-- Shared plumbing for the two Bedwars modules below. Everything is resolved lazily and inside
-- pcall, so on any other game (or an executor missing require / debug.getupvalue) the modules
-- just report why they can't run instead of erroring.
local Bedwars = { Ready = false, Reason = "not checked yet", RetryAt = 0 }

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
    local label = mod.Maid:Give(New("TextLabel", {
        AnchorPoint = Vector2.new(0.5, 1),
        Position = UDim2.new(0.5, 0, 1, yOffset),
        Size = UDim2.fromOffset(0, 26),
        AutomaticSize = Enum.AutomaticSize.X,
        BackgroundColor3 = Theme.Card,
        BackgroundTransparency = 0.1,
        BorderSizePixel = 0,
        Text = prefix .. ": starting...",
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = Theme.Text,
        Visible = false,
        Parent = UI.Gui,
    }, {
        Round(8),
        Stroke(Theme.Stroke, 1),
        New("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }),
    }))
    local lastText, lastAt = "", 0
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
            label.Text = prefix .. ": " .. text
        end
    end
end

-- ====================== MODULE: BEDWARS AURA ======================
do
    local gate = {}

    local aura = Tabs.Combat:CreateModule({
        Name = "Bedwars Aura",
        Description = "Sword aura for Bedwars. Real positions, no reach spoofing.",
        OnEnable = function(mod)
            local cfg = mod.Config
            local lastSend = 0
            local nextInterval = 0
            local flashUntil = 0
            local lastHitText, lastHitAt = "", 0
            local autoRotateOverridden = nil
            local warnedUnavailable = false

            local setStatus = makeStatusLabel(mod, "Bedwars Aura", -100)

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

            -- Returns nil when the entry is a valid target, otherwise a short reason
            local function whyNot(entry, root, head, flatLook, halfCos)
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
                local flat = Vector3.new(offset.X, 0, offset.Z)
                if cfg.Angle < 360 and flat.Magnitude >= 0.01 and flatLook:Dot(flat.Unit) < halfCos then
                    return "is outside Max Angle"
                end
                if cfg.WallCheck and not Util.HasLineOfSight(head.Position, entry.Root.Position) then
                    return "is behind a wall"
                end
                return nil
            end

            local function collectTargets(char, root, cam)
                local head = char:FindFirstChild("Head") or root
                local look = cam and cam.CFrame.LookVector or root.CFrame.LookVector
                local flatLook = Vector3.new(look.X, 0, look.Z)
                if flatLook.Magnitude < 0.001 then
                    flatLook = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
                end
                flatLook = flatLook.Unit
                local halfCos = math.cos(math.rad(cfg.Angle) / 2)

                local valid = {}
                local nearest, nearestDistance, nearestReason = nil, math.huge, nil
                for _, entry in ipairs(Util.GetTargets(cfg.Targets)) do
                    local reason = whyNot(entry, root, head, flatLook, halfCos)
                    local offset = entry.Root.Position - root.Position
                    if not reason then
                        local score = offset.Magnitude
                        if cfg.Sort == "Health" then
                            score = entry.Humanoid.Health + offset.Magnitude * 0.001
                        elseif cfg.Sort == "Angle" then
                            local flat = Vector3.new(offset.X, 0, offset.Z)
                            score = (flat.Magnitude > 0.01) and -flatLook:Dot(flat.Unit) or -1
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
                        Nova.Notify("Bedwars Aura", tostring(why), 5, "error", true)
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

                if not Util.PassesGate(cfg, gate, 0.2) then
                    idle("hold the " .. string.lower(tostring(cfg.MouseButton)) .. " mouse button (Require Mouse Down)")
                    return
                end

                local item, meta = Bedwars.GetHeldSword()
                if not item then
                    idle(tostring(meta))
                    return
                end

                local cam = Workspace.CurrentCamera
                local targets, reason = collectTargets(char, root, cam)
                if #targets == 0 then
                    idle("no target - " .. tostring(reason))
                    return
                end

                local now = os.clock()
                local first = targets[1].Entry
                local firstText = string.format("%s (%.1f studs)", tostring(first.Name), targets[1].Distance)

                if cfg.ShowTarget then
                    box.Adornee = first.Root
                    box.Color3 = (now < flashUntil) and Color3.fromRGB(235, 215, 255) or Theme.Accent
                else
                    box.Adornee = nil
                end

                -- Optional: turn the character toward the target
                if cfg.FaceTarget then
                    local flatTo = Vector3.new(first.Root.Position.X - root.Position.X, 0, first.Root.Position.Z - root.Position.Z)
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

                -- Swing timing: sword attackSpeed is the floor, the slider can only slow it down
                local swordSpeed = (type(meta.sword.attackSpeed) == "number") and meta.sword.attackSpeed or 0
                local interval = math.max(cfg.MinInterval, swordSpeed)
                if nextInterval == 0 then
                    nextInterval = interval
                end
                local serverNow = Workspace:GetServerTimeNow()
                local lastGameSwing = tonumber(Bedwars.SwordController.lastAttack) or 0
                if now - lastSend < nextInterval or serverNow - lastGameSwing < nextInterval * 0.9 then
                    if now - lastHitAt < 0.5 and lastHitText ~= "" then
                        setStatus(cfg.StatusLine, lastHitText)
                    else
                        setStatus(cfg.StatusLine, "target " .. firstText)
                    end
                    return
                end

                local sent, failure = 0, nil
                for index = 1, math.min(cfg.MaxTargets, #targets) do
                    local entry = targets[index].Entry
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
                    pcall(function()
                        Bedwars.SwordController.lastAttack = Workspace:GetServerTimeNow()
                    end)
                    if cfg.SwingAnimation then
                        pcall(function()
                            Bedwars.SwordController:playSwordEffect(meta, false)
                        end)
                    end
                    lastHitAt = now
                    lastHitText = "hit " .. firstText .. ((sent > 1) and (" +" .. (sent - 1)) or "")
                    setStatus(cfg.StatusLine, lastHitText)
                else
                    setStatus(cfg.StatusLine, firstText .. " - " .. tostring(failure))
                end
            end))

            mod.Maid:Give(function()
                local _, hum = Util.GetCharacter(LocalPlayer)
                releaseRotation(hum)
            end)
        end,
    })

    aura:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players" })
    aura:AddSlider({ Label = "Range", Key = "Range", Min = 3, Max = 14, Default = 10, Step = 0.5, Suffix = " studs" })
    aura:AddSlider({ Label = "Max Angle", Key = "Angle", Min = 30, Max = 360, Default = 180, Step = 5, Suffix = "°" })
    aura:AddSlider({ Label = "Max Targets", Key = "MaxTargets", Min = 1, Max = 3, Default = 1, Step = 1 })
    aura:AddOption({ Label = "Sort", Key = "Sort", Options = { "Distance", "Health", "Angle" }, Default = "Distance" })
    aura:AddSlider({ Label = "Min Interval", Key = "MinInterval", Min = 0.05, Max = 0.6, Default = 0.12, Step = 0.01, Suffix = "s" })
    aura:AddToggle({ Label = "Randomize Interval", Key = "RandomizeInterval", Default = true })
    aura:AddToggle({ Label = "Swing Animation", Key = "SwingAnimation", Default = true })
    aura:AddToggle({ Label = "Face Target", Key = "FaceTarget", Default = false })
    aura:AddToggle({ Label = "Require Mouse Down", Key = "RequireMouseDown", Default = false })
    aura:AddOption({ Label = "Mouse Button", Key = "MouseButton", Options = { "Left", "Right" }, Default = "Left" })
    aura:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true })
    aura:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true })
    aura:AddToggle({ Label = "Show Target", Key = "ShowTarget", Default = true })
    aura:AddToggle({ Label = "Status Line", Key = "StatusLine", Default = true })
    aura:AddLabel("Bedwars only. Hold a sword. Hits use your real position; the sword's own attack speed is the minimum interval.")
end

-- ====================== MODULE: BEDWARS PROJECTILE AIM ======================
do
    local DEFAULT_GRAVITY = 196.2

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

            -- Best target near the crosshair; returns entry, aimPart
            local function pickTarget(origin, cam)
                local mouse = UserInputService:GetMouseLocation()
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
                        local part = entry.Root
                        if cfg.AimPart == "Head" then
                            local head = entry.Model:FindFirstChild("Head")
                            if head and head:IsA("BasePart") then
                                part = head
                            end
                        end
                        local distance = (part.Position - origin).Magnitude
                        if distance <= cfg.Range then
                            local point, onScreen = cam:WorldToViewportPoint(part.Position)
                            local screen = (Vector2.new(point.X, point.Y) - mouse).Magnitude
                            if onScreen and point.Z > 0 and screen <= cfg.FOV
                                and (not cfg.WallCheck or Util.HasLineOfSight(cam.CFrame.Position, part.Position)) then
                                local score = (cfg.Sort == "Distance") and distance or screen
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
            local function aimShot(native, projmeta, worldmeta)
                local cam = Workspace.CurrentCamera
                if not cam or typeof(native.initialVelocity) ~= "Vector3" or typeof(native.positionFrom) ~= "Vector3" then
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

                local entry, part = pickTarget(from, cam)
                if not entry then
                    return nil
                end

                local lifetime = 3
                pcall(function()
                    local meta = projmeta:getProjectileMeta()
                    lifetime = tonumber(meta.predictionLifetimeSec) or tonumber(meta.lifetimeSec) or 3
                end)
                lifetime = math.min(lifetime, 4)

                local root, hum = entry.Root, entry.Humanoid
                local velocity = root.AssemblyLinearVelocity
                local horizontalLead = cfg.HorizontalLead / 100
                local verticalLead = cfg.VerticalLead / 100
                local vx, vz = velocity.X * horizontalLead, velocity.Z * horizontalLead
                local airborne = hum.FloorMaterial == Enum.Material.Air
                local vy = airborne and velocity.Y * verticalLead or 0

                local targetGravity = Workspace.Gravity
                local balloons = entry.Model:GetAttribute("InflatedBalloons")
                if type(balloons) == "number" and balloons > 0 then
                    targetGravity = targetGravity * (1 - (balloons >= 4 and 1.2 or balloons >= 3 and 1 or 0.975))
                end

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

                local yOffsetNow = 0
                local function targetAt(t)
                    local y = base.Y + yOffsetNow
                    if airborne then
                        y = y + vy * t - 0.5 * targetGravity * t * t
                        if floorY and y < floorY + yOffsetNow then
                            y = floorY + yOffsetNow
                        end
                    end
                    return Vector3.new(base.X + vx * t, y, base.Z + vz * t)
                end

                local bow = Bedwars.BowConstants
                local useOffset = cfg.OffsetFix and bow and tonumber(bow.RelX) ~= nil

                local chosen, chosenTime
                for _, dy in ipairs({ 0, 0.8, -0.8, 1.6, -1.6 }) do
                    yOffsetNow = dy
                    local v, flight = solveLaunch(from, speed, gravity, targetAt, lifetime)
                    if v then
                        if useOffset then
                            local spawn = (CFrame.lookAt(from, from + v) * CFrame.new(-bow.RelX, -(bow.RelY or 0), -(bow.RelZ or 0))).Position
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
                local _, projmeta, worldmeta = ...
                local ok, modified = pcall(aimShot, nativeResult, projmeta, worldmeta)
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
            mod.Maid:Give(RunService.Heartbeat:Connect(function()
                local cam = Workspace.CurrentCamera
                if circle then
                    local mouse = UserInputService:GetMouseLocation()
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
                    setStatus(cfg.StatusLine, "ready")
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

    aim:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players" })
    aim:AddOption({ Label = "Aim Part", Key = "AimPart", Options = { "Body", "Head" }, Default = "Body" })
    aim:AddOption({ Label = "Sort", Key = "Sort", Options = { "Cursor", "Distance" }, Default = "Cursor" })
    aim:AddSlider({ Label = "FOV", Key = "FOV", Min = 40, Max = 800, Default = 300, Step = 5, Suffix = " px" })
    aim:AddSlider({ Label = "Range", Key = "Range", Min = 20, Max = 250, Default = 120, Step = 5, Suffix = " studs" })
    aim:AddSlider({ Label = "Horizontal Lead", Key = "HorizontalLead", Min = 0, Max = 150, Default = 100, Step = 5, Suffix = "%" })
    aim:AddSlider({ Label = "Vertical Lead", Key = "VerticalLead", Min = 0, Max = 150, Default = 100, Step = 5, Suffix = "%" })
    aim:AddToggle({ Label = "Bow Offset Fix", Key = "OffsetFix", Default = true })
    aim:AddToggle({ Label = "Wall Check", Key = "WallCheck", Default = true })
    aim:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true })
    aim:AddTextBox({ Label = "Ignore Projectiles", Key = "Ignore", Default = "telepearl", Placeholder = "comma separated names" })
    aim:AddToggle({ Label = "Show FOV Circle", Key = "ShowFOV", Default = true })
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

    local esp = Tabs.Render:CreateModule({
        Name = "ESP",
        Description = "Boxes for players / NPCs that scale with height.",
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

    esp:AddOption({ Label = "Targets", Key = "Targets", Options = TARGET_MODES, Default = "Players" })
    esp:AddToggle({ Label = "Boxes", Key = "Boxes", Default = true })
    esp:AddToggle({ Label = "Names", Key = "Names", Default = true })
    esp:AddToggle({ Label = "Distance", Key = "Distances", Default = false })
    esp:AddToggle({ Label = "Health Bar", Key = "HealthBar", Default = true })
    esp:AddToggle({ Label = "Team Check", Key = "TeamCheck", Default = true })
    esp:AddSlider({ Label = "Max Distance", Key = "MaxDistance", Min = 50, Max = 5000, Default = 1500, Step = 50, Suffix = " studs" })
    esp:AddOption({ Label = "Color", Key = "Color", Options = { "Purple", "White", "Red", "Cyan", "Green" }, Default = "Purple" })

    Tabs.Render:CreatePlaceholder("More render features coming soon...")
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

    speed:AddSlider({ Label = "WalkSpeed", Key = "WalkSpeed", Min = 16, Max = MAX_SPEED, Default = 20, Step = 0.5 })
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
    sky:AddTextBox({ Label = "Image Asset ID", Key = "CustomId", Default = "", Placeholder = "numeric id", Callback = reapply })
    sky:AddSlider({ Label = "Stars", Key = "StarCount", Min = 0, Max = 5000, Default = 3000, Step = 100, Callback = reapply })
    sky:AddToggle({ Label = "Sun / Moon", Key = "CelestialBodies", Default = false, Callback = reapply })
    sky:AddLabel("Custom ID applies one image to all six faces. Use an Image asset ID, not a Decal ID.")
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

    lighting:AddToggle({ Label = "Lock Time of Day", Key = "LockTime", Default = true })
    lighting:AddSlider({ Label = "Time of Day", Key = "ClockTime", Min = 0, Max = 24, Default = 20, Step = 0.25 })
    lighting:AddToggle({ Label = "Fullbright", Key = "Fullbright", Default = false })
    lighting:AddToggle({ Label = "No Fog", Key = "NoFog", Default = false })
    lighting:AddToggle({ Label = "Ambient Tint", Key = "TintAmbient", Default = false })
    lighting:AddSlider({ Label = "Tint Hue", Key = "TintHue", Min = 0, Max = 1, Default = 0.75, Step = 0.01 })
    lighting:AddSlider({ Label = "Tint Saturation", Key = "TintSaturation", Min = 0, Max = 1, Default = 0.6, Step = 0.01 })
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

    potato:AddToggle({ Label = "Simplify Materials", Key = "SimplifyMaterials", Default = true, Callback = refresh })
    potato:AddToggle({ Label = "Remove Textures", Key = "RemoveTextures", Default = true, Callback = refresh })
    potato:AddToggle({ Label = "Disable Shadows", Key = "DisableShadows", Default = true, Callback = refresh })
    potato:AddToggle({ Label = "Disable Particles", Key = "DisableParticles", Default = true, Callback = refresh })
    potato:AddToggle({ Label = "Disable Post Effects", Key = "DisablePostFX", Default = true, Callback = refresh })
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

    unlocker:AddSlider({ Label = "FPS Cap", Key = "Cap", Min = 30, Max = 360, Default = 144, Step = 1, Callback = reapply })
    unlocker:AddToggle({ Label = "Unlimited", Key = "Unlimited", Default = false, Callback = reapply })
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
UI:SetVisible(true)
Nova.Notify("Nova", "Loaded. Press RightShift to toggle the UI.", 4, "success")

end -- NovaMain

NovaMain()
