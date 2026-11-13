-- WGG_Logic.lua
-- Silent Aim + Wallbang + ESP logic
-- Di-load oleh GUI via loadstring / require

local Logic = {}

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local lp         = Players.LocalPlayer
local Camera     = workspace.CurrentCamera

Logic.SAConfig = {
    Enabled   = true,
    WBEnabled = true,
    HitPart   = "Head",
    FOV       = Camera.ViewportSize.X,
    MaxDist   = 500,
}

Logic.ESPConfig = {
    Enabled     = false,
    BorderColor = Color3.fromRGB(255, 140, 0),
    BgColor     = Color3.fromRGB(15, 15, 15),
    NameColor   = Color3.fromRGB(255, 255, 255),
    DistColor   = Color3.fromRGB(200, 200, 200),
    TextSize    = 13,
}

local Connections = {}
local function bind(signal, fn)
    local c = signal:Connect(fn)
    table.insert(Connections, c)
    return c
end

local function isAlive(char)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return hum and hum.Health > 0
end

local function getEnemies()
    local out = {}
    for _, p in Players:GetPlayers() do
        if p == lp then continue end
        if lp.Team and p.Team and p.Team == lp.Team then continue end
        local char = p.Character
        if not char or not isAlive(char) then continue end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hrp then continue end
        table.insert(out, { plr = p, char = char, hrp = hrp, hum = char:FindFirstChildOfClass("Humanoid") })
    end
    local botFolder = workspace:FindFirstChild("ServerBots")
    if botFolder then
        for _, model in botFolder:GetChildren() do
            if not model:IsA("Model") then continue end
            local hrp = model:FindFirstChild("HumanoidRootPart")
            local hum = model:FindFirstChildOfClass("Humanoid")
            if not hrp or not hum or hum.Health <= 0 then continue end
            table.insert(out, { plr = nil, char = model, hrp = hrp, hum = hum })
        end
    end
    return out
end

-- =====================================================================
-- SILENT AIM + WALLBANG
-- =====================================================================
local cachedTarget = nil

local function refreshTarget()
    local SA = Logic.SAConfig
    if not SA.Enabled and not SA.WBEnabled then
        cachedTarget = nil return
    end
    local cam = workspace.CurrentCamera
    if not cam then cachedTarget = nil return end

    local center   = cam.ViewportSize / 2
    local bestDist = SA.FOV
    local best     = nil

    for _, e in getEnemies() do
        local part = e.char:FindFirstChild(SA.HitPart) or e.hrp
        local dist3d = (part.Position - cam.CFrame.Position).Magnitude
        if dist3d > SA.MaxDist then continue end
        local screenPos, onScreen = cam:WorldToViewportPoint(part.Position)
        if not onScreen then continue end
        local sd = (Vector2.new(screenPos.X, screenPos.Y) - center).Magnitude
        if sd < bestDist then
            bestDist = sd
            best = { pos = part.Position, hum = e.hum }
        end
    end
    cachedTarget = best
end

bind(RunService.RenderStepped, function()
    local ok = pcall(refreshTarget)
    if not ok then cachedTarget = nil end
end)

local oldNamecall
local processing = false

local function hook(self, ...)
    local method = getnamecallmethod()
    if processing then return oldNamecall(self, ...) end
    if method ~= "FireServer" then return oldNamecall(self, ...) end

    processing = true
    local okN, className, name = pcall(function()
        return self.ClassName, self.Name
    end)
    processing = false

    if not okN or className ~= "RemoteEvent" or name ~= "Shoot" then
        return oldNamecall(self, ...)
    end

    if not cachedTarget then return oldNamecall(self, ...) end

    local SA   = Logic.SAConfig
    local args = { ... }
    local camCF = args[3]
    if typeof(camCF) ~= "CFrame" then return oldNamecall(self, ...) end

    if SA.Enabled then
        local origin = camCF.Position
        args[3] = CFrame.lookAt(origin, origin + (cachedTarget.pos - origin).Unit)
    end

    if SA.WBEnabled then
        args[5] = { ["1"] = { cachedTarget.hum, true, false, 0 } }
    end

    return oldNamecall(self, table.unpack(args))
end

if hookmetamethod then
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(hook))
else
    local mt = getrawmetatable(game)
    oldNamecall = mt.__namecall
    setreadonly(mt, false)
    mt.__namecall = newcclosure(hook)
    setreadonly(mt, true)
end

-- =====================================================================
-- ESP
-- =====================================================================
local espFolder = Instance.new("Folder")
espFolder.Name   = "WGG_ESPFolder"
espFolder.Parent = Camera

local esps = {}

local ESPWallParams = RaycastParams.new()
ESPWallParams.FilterType = Enum.RaycastFilterType.Exclude

local function isVisible(char)
    local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
    local head  = char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart")
    if not myHRP or not head then return false end
    ESPWallParams.FilterDescendantsInstances = { lp.Character, char }
    local dir = head.Position - myHRP.Position
    return workspace:Raycast(myHRP.Position, dir, ESPWallParams) == nil
end

local function createESP(key)
    if esps[key] then return end
    local cardBB = Instance.new("BillboardGui")
    cardBB.AlwaysOnTop = true
    cardBB.Size        = UDim2.new(0, 130, 0, 52)
    cardBB.StudsOffset = Vector3.new(0, 1, 0)
    cardBB.Enabled     = false
    cardBB.Parent      = espFolder

    local bg = Instance.new("Frame")
    bg.Size                   = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3       = Logic.ESPConfig.BgColor
    bg.BackgroundTransparency = 0.25
    bg.BorderSizePixel        = 0
    bg.Parent                 = cardBB

    local stroke = Instance.new("UIStroke")
    stroke.Color     = Logic.ESPConfig.BorderColor
    stroke.Thickness = 1.5
    stroke.Parent    = bg
    Instance.new("UICorner", bg).CornerRadius = UDim.new(0, 4)

    local hpBG = Instance.new("Frame")
    hpBG.Size             = UDim2.new(1, -8, 0, 5)
    hpBG.Position         = UDim2.new(0, 4, 0, 4)
    hpBG.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    hpBG.BorderSizePixel  = 0
    hpBG.Parent           = bg
    Instance.new("UICorner", hpBG).CornerRadius = UDim.new(0, 2)

    local hpFG = Instance.new("Frame")
    hpFG.Size             = UDim2.new(1, 0, 1, 0)
    hpFG.BackgroundColor3 = Color3.fromRGB(80, 220, 80)
    hpFG.BorderSizePixel  = 0
    hpFG.Parent           = hpBG
    Instance.new("UICorner", hpFG).CornerRadius = UDim.new(0, 2)

    local cardName = Instance.new("TextLabel")
    cardName.Size                   = UDim2.new(1, -8, 0, 18)
    cardName.Position               = UDim2.new(0, 4, 0, 11)
    cardName.BackgroundTransparency = 1
    cardName.TextColor3             = Logic.ESPConfig.NameColor
    cardName.TextStrokeTransparency = 0.4
    cardName.TextSize               = Logic.ESPConfig.TextSize
    cardName.Font                   = Enum.Font.GothamBold
    cardName.TextXAlignment         = Enum.TextXAlignment.Left
    cardName.Parent                 = bg

    local infoLabel = Instance.new("TextLabel")
    infoLabel.Size                   = UDim2.new(1, -8, 0, 16)
    infoLabel.Position               = UDim2.new(0, 4, 0, 31)
    infoLabel.BackgroundTransparency = 1
    infoLabel.TextColor3             = Logic.ESPConfig.DistColor
    infoLabel.TextStrokeTransparency = 0.5
    infoLabel.TextSize               = Logic.ESPConfig.TextSize - 1
    infoLabel.Font                   = Enum.Font.Gotham
    infoLabel.TextXAlignment         = Enum.TextXAlignment.Left
    infoLabel.Parent                 = bg

    esps[key] = { cardBB = cardBB, bg = bg, stroke = stroke, hpFG = hpFG, cardName = cardName, infoLabel = infoLabel }
end

local function removeESP(key)
    if esps[key] then
        esps[key].cardBB:Destroy()
        esps[key] = nil
    end
end

local function setupPlayer(p)
    if p == lp then return end
    createESP(p)
    bind(p.CharacterAdded, function()
        task.wait(0.5)
        if not esps[p] then createESP(p) end
    end)
end

for _, p in Players:GetPlayers() do setupPlayer(p) end
bind(Players.PlayerAdded, setupPlayer)
bind(Players.PlayerRemoving, removeESP)

bind(RunService.RenderStepped, function()
    local ESP = Logic.ESPConfig
    if not ESP.Enabled then
        for _, esp in pairs(esps) do esp.cardBB.Enabled = false end
        return
    end
    for key, esp in pairs(esps) do
        local plr, char
        if typeof(key) == "Instance" and key:IsA("Model") then
            char = key
        else
            plr = key
            char = plr.Character
        end
        if plr and lp.Team and plr.Team and plr.Team == lp.Team then
            esp.cardBB.Enabled = false
            continue
        end
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        if not char or not hrp or not isAlive(char) then
            esp.cardBB.Enabled = false
            continue
        end
        local visible = isVisible(char)
        esp.stroke.Color = visible and ESP.BorderColor or Color3.fromRGB(255, 255, 255)

        local myHRP = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
        local dist  = myHRP and math.floor((hrp.Position - myHRP.Position).Magnitude) or 0
        local hum   = char:FindFirstChildOfClass("Humanoid")
        local hp    = hum and hum.Health or 0
        local maxHp = hum and hum.MaxHealth or 100
        local hpPct = math.clamp(hp / maxHp, 0, 1)
        local hpColor = Color3.fromRGB(
            math.floor(255 * math.min(1, 2 * (1 - hpPct))),
            math.floor(255 * math.min(1, 2 * hpPct)), 0
        )
        esp.cardBB.Enabled        = true
        esp.cardBB.Adornee        = char:FindFirstChild("Head") or hrp
        esp.hpFG.Size             = UDim2.new(hpPct, 0, 1, 0)
        esp.hpFG.BackgroundColor3 = hpColor
        esp.cardName.Text         = plr and plr.Name or char.Name
        esp.infoLabel.Text        = string.format("HP: %d%%  |  %dm", math.floor(hpPct * 100), dist)
    end
end)

-- =====================================================================
-- UNLOAD
-- =====================================================================
Logic.Connections = Connections
Logic.espFolder   = espFolder
Logic.oldNamecall = oldNamecall

Logic.Unload = function()
    Logic.SAConfig.Enabled   = false
    Logic.SAConfig.WBEnabled = false
    Logic.ESPConfig.Enabled  = false
    for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
    pcall(function() espFolder:Destroy() end)
    pcall(function()
        if not hookmetamethod then
            local mt2 = getrawmetatable(game)
            setreadonly(mt2, false)
            mt2.__namecall = oldNamecall
            setreadonly(mt2, true)
        end
    end)
end

return Logic
