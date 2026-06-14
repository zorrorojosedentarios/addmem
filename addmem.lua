local ADDON_NAME = "addmem"
local AddMem = CreateFrame("Frame", "AddMemFrame", UIParent)
AddMem:Hide()
tinsert(UISpecialFrames, "AddMemFrame")

local IsActive = true
local IsBackgroundActive = true

local alerts = {} 
local commandSpamCounts = {} 
local previousCPU = {}
local cpuDeltas = {}
local previousMem = {}
local uptimeTicks = 0
local dataList = {}
local dataListPool = {}
local tempAlertKeys = {}
local memStableTicks = {}
local altoConsumoAlerted = {}

local HISTORY_SIZE = 8
local MEM_LEAK_MIN_KB = 15
local MEM_LEAK_PERCENT = 0.01
local CPU_SPIKE_MIN_DELTA = 25
local CPU_SPIKE_FACTOR = 2.0
local HIGH_MEM_THRESHOLD_KB = 5000
local MEM_STABLE_DELTA = 50
local MEM_STABLE_TICKS = 5

local lastMemDrop = {}
local leakStrikes = {}
local cpuBaseline = {}
local isAbruptGrowth = {}
local MEM_ABRUPT_DELTA = 1000 -- 1MB jump in 1 second is abrupt

local errorDetails = {}
local errorRateLimits = {}
local gracePeriods = {}
local BASE_INTERVAL_IDLE = 5.0
local BASE_INTERVAL_BURST = 1.0
local currentInterval = BASE_INTERVAL_IDLE
local GRACE_PERIOD_DURATION = 5
local UI_FRAMES_TO_TRACK = {
    ["AuctionFrame"] = "Auctioneer/Blizzard_Auction",
    ["TradeFrame"] = "Comercio",
    ["CraftFrame"] = "Profesiones",
}

local bgTracker = CreateFrame("Frame")

local function ClearMemory()
    alerts = {}
    if AddMemDB then AddMemDB.alerts = {} end
    commandSpamCounts = {}
    previousCPU = {}
    previousMem = {}
    uptimeTicks = 0
    lastMemDrop = {}
    leakStrikes = {}
    cpuBaseline = {}
    errorDetails = {}
    errorRateLimits = {}
    memStableTicks = {}
    altoConsumoAlerted = {}
    wipe(dataList)
    wipe(dataListPool)
    wipe(tempAlertKeys)
    wipe(gracePeriods)
    currentInterval = BASE_INTERVAL_IDLE
    isReadyToEvaluate = false
    timeSinceEnteringWorld = 0
    isAbruptGrowth = {}
    collectgarbage("collect")
end

local function RingPush(tbl, value)
    if not tbl then tbl = {vals = {}, idx = 1, count = 0} end
    tbl.vals[tbl.idx] = value
    tbl.idx = tbl.idx % HISTORY_SIZE + 1
    tbl.count = math.min(tbl.count + 1, HISTORY_SIZE)
    return tbl
end

local function RingAvg(tbl)
    if not tbl or tbl.count == 0 then return 0 end
    local sum = 0
    for i = 1, tbl.count do
        sum = sum + (tbl.vals[i] or 0)
    end
    return sum / tbl.count
end

local function RingPositiveRatio(tbl)
    if not tbl or tbl.count == 0 then return 0 end
    local pos = 0
    for i = 1, tbl.count do
        if tbl.vals[i] and tbl.vals[i] > 0 then pos = pos + 1 end
    end
    return pos / tbl.count
end

local timeSinceLastUpdate = 0
local isReadyToEvaluate = false
local timeSinceEnteringWorld = 0
local STARTUP_WAIT_TIME = 30
local scrollFrame, lines = nil, {}
local MAX_LINES = 15
local ROW_HEIGHT = 20

local DEFAULTS = {
    cpuSpikeDelta = 100,
    memLeakDelta = 1000,
    spamThreshold = 15,
    highMemThreshold = 5000,
    isActive = true,
    isBackgroundActive = true,
    showErrors = true,
    currentSort = "CPU",
}

local ShowErrors = true
local currentSort = "CPU"

local IGNORED_ADDONS = {
    [ADDON_NAME] = true,
    ["Unknown"] = true,
    ["!Swatter"] = true,
}

local function GetAddonOrigin(level)
    local stack = debugstack(level or 3, 1, 0)
    local addon = string.match(stack, "Interface\\AddOns\\([^\\]+)\\")
    if addon and (IGNORED_ADDONS[addon] or addon:find("^Blizzard_")) then return nil end
    return addon
end

local function UpdateEngineState()
    if IsActive and (IsBackgroundActive or AddMem:IsVisible()) then
        bgTracker:Show()
    else
        bgTracker:Hide()
    end
end

local function ShouldTrack()
    if not IsActive then return false end
    if not IsBackgroundActive and not AddMem:IsVisible() then return false end
    return true
end

local function AddAlert(addon, alertType, extraDetails)
    if not ShouldTrack() then return end
    if addon then
        if not alerts[addon] then alerts[addon] = {} end
        alerts[addon][alertType] = true
        
        if AddMemDB then
            if not AddMemDB.alerts then AddMemDB.alerts = {} end
            if not AddMemDB.alerts[addon] then AddMemDB.alerts[addon] = {} end
            AddMemDB.alerts[addon][alertType] = date("%d/%m %H:%M")
        end

        if alertType:find("Error") or alertType:find("Pico") or alertType:find("Alto") then
            print("|cffff3333[addmem]|r ALERTA: |cffffff00" .. addon .. "|r (" .. alertType .. ")")
        end

        if not alertType:find("Error:") then
            if not errorDetails[addon] then errorDetails[addon] = {} end
            table.insert(errorDetails[addon], 1, {
                message = alertType,
                stack = extraDetails or "Alerta de comportamiento detectada por addmem.",
                time = date("%H:%M:%S")
            })
            if #errorDetails[addon] > 5 then
                table.remove(errorDetails[addon])
            end
        end
    end
end

-- HOOKS
hooksecurefunc("SendAddonMessage", function(...)
    if not ShouldTrack() then return end
    local addon = GetAddonOrigin(3)
    if addon then
        local now = GetTime()
        if not commandSpamCounts[addon] then commandSpamCounts[addon] = {msgs = 0, time = now} end
        local data = commandSpamCounts[addon]
        if now - data.time > 1 then
            data.msgs = 0
            data.time = now
        end
        data.msgs = data.msgs + 1
        local cfg = (AddMemDB and AddMemDB.config) and AddMemDB.config or DEFAULTS
        if data.msgs > cfg.spamThreshold then
            local extra = string.format("Frecuencia de red anormalmente alta.\nMensajes enviados: %d en 1.0s\nUmbral máximo permitido: %d mensajes/s.", data.msgs, cfg.spamThreshold)
            AddAlert(addon, "Spam Red", extra)
        end
    end
end)

local function HookFocusSteal(frame)
    if frame and frame.SetFocus then
        hooksecurefunc(frame, "SetFocus", function()
            if not ShouldTrack() then return end
            local addon = GetAddonOrigin(3)
            if addon then
                local extra = string.format("El addon llamó forzadamente a SetFocus()\nCaja de texto afectada: %s", frame:GetName() or "Anónimo")
                AddAlert(addon, "Robo Foco", extra)
            end
        end)
    end
end

for i=1, NUM_CHAT_WINDOWS do
    local editBox = _G["ChatFrame"..i.."EditBox"]
    if editBox then HookFocusSteal(editBox) end
end

local function CheckCommandInjection(arg1)
    if not ShouldTrack() then return end
    local addon = GetAddonOrigin(3)
    if addon then
        local extra = string.format("El addon ejecutó un comando, chat o script dinámico.\nTexto/Script ejecutado:\n%s", tostring(arg1 or "Desconocido"))
        AddAlert(addon, "Inyección", extra)
    end
end

hooksecurefunc("SendChatMessage", CheckCommandInjection)
hooksecurefunc("RunScript", CheckCommandInjection)
if RunMacroText then hooksecurefunc("RunMacroText", CheckCommandInjection) end
if ConsoleExec then hooksecurefunc("ConsoleExec", CheckCommandInjection) end

local function GetAddonFromStack(stack)
    if not stack then return nil end
    for addon in stack:gmatch("Interface\\AddOns\\([^\\]+)\\") do
        if not IGNORED_ADDONS[addon] and not addon:find("^Blizzard_") then
            return addon
        end
    end
    return nil
end

local function HandleError(err, stack, locals)
    if not ShouldTrack() then return end
    
    local addon = string.match(err, "Interface\\AddOns\\([^\\]+)\\")
    if not addon then
        addon = GetAddonFromStack(stack)
    end
    
    if addon then
        local now = GetTime()
        if not errorRateLimits[addon] then
            errorRateLimits[addon] = {time = now, count = 0}
        end
        local limit = errorRateLimits[addon]
        if now - limit.time > 10 then
            limit.count = 0
            limit.time = now
        end
        limit.count = limit.count + 1
        if limit.count > 10 then return end

        local line = string.match(err, "Interface\\AddOns\\[^\\]+\\([^\n:]+:[0-9]+)")
        if not line then
            line = string.match(stack, "Interface\\AddOns\\[^\\]+\\([^\n:]+:[0-9]+)")
        end
        if not line and err:find("%[string") then
            line = string.match(err, "%[string \"([^\"]+)\"%]:[0-9]+") or "Script Dinámico"
        end

        AddAlert(addon, "Error: " .. (line or "Línea desconocida"))
        
        if not errorDetails[addon] then errorDetails[addon] = {} end
        
        local found = false
        for _, errInfo in ipairs(errorDetails[addon]) do
            if errInfo.message == err then
                errInfo.count = (errInfo.count or 1) + 1
                errInfo.time = date("%H:%M:%S")
                found = true
                break
            end
        end
        
        if not found then
            table.insert(errorDetails[addon], 1, {
                message = err,
                stack = stack,
                locals = locals or "N/A",
                time = date("%H:%M:%S"),
                count = 1
            })
            if #errorDetails[addon] > 5 then
                table.remove(errorDetails[addon])
            end
        end
    end
end

local isHandlingError = false

local function MakeErrorHandler(nextHandler)
    return function(err)
        if isHandlingError then return end
        isHandlingError = true

        local stack = debugstack(1, 15, 15)
        local locals = debuglocals and debuglocals(4) or "Funcionalidad debuglocals no disponible."
        HandleError(err, stack, locals)

        local ok, msg = pcall(function()
            local isSwatter = (Swatter and type(Swatter) == "table" and type(nextHandler) == "function" and nextHandler == Swatter.OnError)
            if ShowErrors and type(nextHandler) == "function" and not isSwatter then
                nextHandler(err)
            end
        end)

        isHandlingError = false
        if not ok then
            print("|cffff3333[addmem]|r Error crítico en Handler: " .. tostring(msg))
            print("|cffff3333[addmem]|r Error original: " .. tostring(err))
        end
    end
end

local ourHandler = MakeErrorHandler(geterrorhandler())
seterrorhandler(ourHandler)

local errorDetailFrame
local function CreateErrorDetailFrame()
    if errorDetailFrame then return end
    
    errorDetailFrame = CreateFrame("Frame", "AddMemErrorDetailFrame", UIParent)
    errorDetailFrame:SetSize(550, 400)
    errorDetailFrame:SetPoint("CENTER")
    errorDetailFrame:SetFrameStrata("DIALOG")
    errorDetailFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    errorDetailFrame:SetBackdropColor(0.08, 0.08, 0.15, 0.98)
    errorDetailFrame:SetBackdropBorderColor(0.4, 0.4, 0.7, 1)
    
    errorDetailFrame:SetMovable(true)
    errorDetailFrame:EnableMouse(true)
    errorDetailFrame:RegisterForDrag("LeftButton")
    errorDetailFrame:SetScript("OnDragStart", errorDetailFrame.StartMoving)
    errorDetailFrame:SetScript("OnDragStop", errorDetailFrame.StopMovingOrSizing)
    errorDetailFrame:SetClampedToScreen(true)
    
    local title = errorDetailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 15, -15)
    title:SetText("Detalles de Errores")
    errorDetailFrame.title = title
    
    local closeBtn = CreateFrame("Button", nil, errorDetailFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)
    
    local sf = CreateFrame("ScrollFrame", "AddMemErrorDetailScrollFrame", errorDetailFrame, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 15, -45)
    sf:SetPoint("BOTTOMRIGHT", -35, 15)
    
    local eb = CreateFrame("EditBox", nil, sf)
    eb:SetMultiLine(true)
    eb:SetMaxLetters(99999)
    eb:SetFontObject(GameFontHighlightSmall)
    eb:SetWidth(490)
    eb:SetHeight(340)
    eb:SetAutoFocus(false)
    eb:SetScript("OnEscapePressed", function() errorDetailFrame:Hide() end)
    
    sf:SetScrollChild(eb)
    errorDetailFrame.editBox = eb
    
    tinsert(UISpecialFrames, "AddMemErrorDetailFrame")
end

local configFrame, configScrollChild
local configRowFrames = {}
local function RefreshConfigList()
    if not configFrame or not configScrollChild then return end

    local items = {}
    for i = 1, GetNumAddOns() do
        local name = GetAddOnInfo(i)
        if IsAddOnLoaded(i) then
            local mem = GetAddOnMemoryUsage(i)
            local threshold = AddMemDB and AddMemDB.addonThresholds and AddMemDB.addonThresholds[name]
            table.insert(items, { name = name, mem = mem, threshold = threshold })
        end
    end
    table.sort(items, function(a, b) return a.name < b.name end)

    for idx, itemData in ipairs(items) do
        local item = itemData
        local row
        if configRowFrames[idx] then
            row = configRowFrames[idx]
            row:Hide()
        else
            row = CreateFrame("Frame", nil, configScrollChild)
            row:SetHeight(20)
            row:SetPoint("LEFT", configScrollChild, "LEFT", 5, 0)
            row:SetPoint("RIGHT", configScrollChild, "RIGHT", -5, 0)

            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture("Interface\\Buttons\\WHITE8X8")
            bg:SetVertexColor(0.15, 0.15, 0.25, 0.3)

            local tName = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            tName:SetPoint("LEFT", 5, 0)
            tName:SetWidth(170)

            local tMem = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            tMem:SetPoint("LEFT", 180, 0)
            tMem:SetWidth(65)

            local eb = CreateFrame("EditBox", nil, row)
            eb:SetSize(90, 18)
            eb:SetPoint("LEFT", 260, 0)
            eb:SetAutoFocus(false)
            eb:SetFontObject(GameFontHighlightSmall)
            eb:SetTextInsets(3, 3, 0, 0)
            eb:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 8, edgeSize = 8,
                insets = { left = 2, right = 2, top = 2, bottom = 2 }
            })
            eb:SetBackdropColor(0.06, 0.06, 0.12, 0.85)
            eb:SetBackdropBorderColor(0.35, 0.35, 0.55, 0.8)

            row.tName = tName
            row.tMem = tMem
            row.eb = eb
            configRowFrames[idx] = row
        end

        if idx == 1 then
            row:SetPoint("TOP", configScrollChild, "TOP", 0, -5)
        else
            row:SetPoint("TOP", configRowFrames[idx-1], "BOTTOM", 0, 0)
        end

        row.tName:SetText(item.name)
        local memStr = item.mem > 1024 and string.format("%.1fMB", item.mem / 1024) or string.format("%.0fKB", item.mem)
        row.tMem:SetText(memStr)

        row.eb:SetText(item.threshold and tostring(item.threshold) or "")
        row.eb:SetScript("OnEnterPressed", function(self)
            local val = self:GetText():match("^%s*(.-)%s*$")
            if val == "" or val == "0" then
                if AddMemDB then
                    if not AddMemDB.addonThresholds then AddMemDB.addonThresholds = {} end
                    AddMemDB.addonThresholds[item.name] = nil
                end
            else
                local num = tonumber(val)
                if num and num > 0 then
                    if AddMemDB then
                        if not AddMemDB.addonThresholds then AddMemDB.addonThresholds = {} end
                        AddMemDB.addonThresholds[item.name] = num
                    end
                end
            end
            RefreshConfigList()
        end)
        row.eb:SetScript("OnEscapePressed", function(self)
            self:SetText(item.threshold and tostring(item.threshold) or "")
        end)

        row:Show()
    end

    for i = #items + 1, #configRowFrames do
        configRowFrames[i]:Hide()
    end

    configScrollChild:SetHeight(#items * 20 + 10)
end

local function CreateConfigFrame()
    if configFrame then
        configFrame:Show()
        RefreshConfigList()
        return
    end

    configFrame = CreateFrame("Frame", "AddMemConfigFrame", UIParent)
    configFrame:SetSize(520, 420)
    configFrame:SetPoint("CENTER")
    configFrame:SetFrameStrata("DIALOG")
    configFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    configFrame:SetBackdropColor(0.08, 0.08, 0.15, 0.98)
    configFrame:SetBackdropBorderColor(0.4, 0.4, 0.7, 1)
    
    configFrame:SetMovable(true)
    configFrame:EnableMouse(true)
    configFrame:RegisterForDrag("LeftButton")
    configFrame:SetScript("OnDragStart", configFrame.StartMoving)
    configFrame:SetScript("OnDragStop", configFrame.StopMovingOrSizing)
    configFrame:SetClampedToScreen(true)
    
    local title = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -15)
    title:SetText("addmem - Umbrales por Addon")
    
    local closeBtn = CreateFrame("Button", nil, configFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)
    
    -- Column headers
    local hdrName = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrName:SetPoint("TOPLEFT", 25, -45)
    hdrName:SetText("Addon")
    
    local hdrMem = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrMem:SetPoint("TOPLEFT", 185, -45)
    hdrMem:SetText("Memoria")
    
    local hdrUmbral = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrUmbral:SetPoint("TOPLEFT", 265, -45)
    hdrUmbral:SetText("Umbral (KB) |cff888888(vacío = global)|r")
    
    -- Global threshold display + edit
    local globalLabel = configFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    globalLabel:SetPoint("BOTTOMLEFT", 20, 50)
    globalLabel:SetText("Umbral global:")
    
    local globalVal = configFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    globalVal:SetPoint("LEFT", globalLabel, "RIGHT", 8, 0)
    local currentGlobal = AddMemDB and AddMemDB.config and AddMemDB.config.highMemThreshold or 5000
    globalVal:SetText(currentGlobal > 1024 and string.format("%.1f MB", currentGlobal / 1024) or string.format("%d KB", currentGlobal))
    
    local globalEdit = CreateFrame("EditBox", nil, configFrame, "InputBoxTemplate")
    globalEdit:SetSize(100, 22)
    globalEdit:SetPoint("LEFT", globalVal, "RIGHT", 8, 0)
    globalEdit:SetAutoFocus(false)
    globalEdit:SetFontObject(GameFontHighlightSmall)
    globalEdit:SetScript("OnEnterPressed", function(self)
        local val = self:GetText():match("^%s*(.-)%s*$")
        local num = tonumber(val)
        if num and num > 0 then
            if AddMemDB and AddMemDB.config then
                AddMemDB.config.highMemThreshold = num
                local display = num > 1024 and string.format("%.1f MB", num / 1024) or string.format("%d KB", num)
                globalVal:SetText(display)
            end
        end
        self:SetText("")
        RefreshConfigList()
    end)
    globalEdit:SetScript("OnEscapePressed", function(self) self:SetText("") end)
    
    local globalHint = configFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    globalHint:SetPoint("LEFT", globalEdit, "RIGHT", 8, 0)
    globalHint:SetText("(escribe y Enter)")
    
    -- Scrollable list
    local sf = CreateFrame("ScrollFrame", "AddMemConfigScrollFrame", configFrame, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 20, -65)
    sf:SetPoint("BOTTOMRIGHT", -35, 80)
    
    local fs = CreateFrame("Frame", nil, sf)
    fs:SetWidth(440)
    fs:SetHeight(1)
    
    sf:SetScrollChild(fs)
    configScrollChild = fs
    configRowFrames = {}
    
    -- Close button
    local closeConfig = CreateFrame("Button", nil, configFrame, "UIPanelButtonTemplate")
    closeConfig:SetSize(100, 22)
    closeConfig:SetPoint("BOTTOMRIGHT", -20, 20)
    closeConfig:SetText("Cerrar")
    closeConfig:SetScript("OnClick", function() configFrame:Hide() end)
    
    tinsert(UISpecialFrames, "AddMemConfigFrame")
    RefreshConfigList()
end

local function CreateUI()
    if AddMem.isCreated then return end
    AddMem.isCreated = true

    AddMem:SetWidth(650)
    AddMem:SetHeight(450)
    AddMem:SetPoint("CENTER")
    AddMem:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 }
    })
    AddMem:SetBackdropColor(0.05, 0.05, 0.1, 0.95)
    AddMem:SetBackdropBorderColor(0.3, 0.3, 0.5, 1)

    AddMem:SetMovable(true)
    AddMem:EnableMouse(true)
    AddMem:RegisterForDrag("LeftButton")
    AddMem:SetScript("OnDragStart", AddMem.StartMoving)
    AddMem:SetScript("OnDragStop", AddMem.StopMovingOrSizing)
    AddMem:SetClampedToScreen(true)
    
    local title = AddMem:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -15)
    title:SetText("addmem - Monitor de Rendimiento y Comportamiento")

    local closeBtn = CreateFrame("Button", nil, AddMem, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", -5, -5)
    
    if GetCVar("scriptProfile") ~= "1" then
        local btnCPU = CreateFrame("Button", nil, AddMem, "UIPanelButtonTemplate")
        btnCPU:SetSize(140, 22)
        btnCPU:SetPoint("BOTTOMRIGHT", -15, 15)
        btnCPU:SetText("Activar Medidor Lag")
        btnCPU:SetScript("OnClick", function()
            SetCVar("scriptProfile", "1")
            ReloadUI()
        end)
    end

    local btnToggleActive = CreateFrame("CheckButton", "AddMemToggleActive", AddMem, "UICheckButtonTemplate")
    btnToggleActive:SetPoint("BOTTOMLEFT", 15, 10)
    btnToggleActive:SetChecked(IsActive)
    _G[btnToggleActive:GetName().."Text"]:SetText("Activar Monitor")
    btnToggleActive:SetScript("OnClick", function(self)
        IsActive = self:GetChecked()
        if AddMemDB and AddMemDB.config then
            AddMemDB.config.isActive = IsActive
        end
        UpdateEngineState()
        if not IsActive then
            ClearMemory()
            AddMem.UpdateUI()
        end
    end)

    local btnToggleBG = CreateFrame("CheckButton", "AddMemToggleBG", AddMem, "UICheckButtonTemplate")
    btnToggleBG:SetPoint("BOTTOMLEFT", 150, 10)
    btnToggleBG:SetChecked(IsBackgroundActive)
    _G[btnToggleBG:GetName().."Text"]:SetText("Segundo Plano")
    btnToggleBG:SetScript("OnClick", function(self)
        IsBackgroundActive = self:GetChecked()
        if AddMemDB and AddMemDB.config then
            AddMemDB.config.isBackgroundActive = IsBackgroundActive
        end
        UpdateEngineState()
        if not IsBackgroundActive and not AddMem:IsVisible() then
            ClearMemory()
        end
    end)

    local btnReset = CreateFrame("Button", nil, AddMem, "UIPanelButtonTemplate")
    btnReset:SetSize(100, 22)
    btnReset:SetPoint("BOTTOMLEFT", 280, 15)
    btnReset:SetText("Reiniciar")
    btnReset:SetScript("OnClick", function()
        if GetCVar("scriptProfile") == "1" then
            ResetCPUUsage()
        end
        ClearMemory()
        AddMem.UpdateUI()
    end)

    local btnShowErrors = CreateFrame("CheckButton", "AddMemShowErrors", AddMem, "UICheckButtonTemplate")
    btnShowErrors:SetPoint("BOTTOMLEFT", 400, 10)
    btnShowErrors:SetChecked(ShowErrors)
    _G[btnShowErrors:GetName().."Text"]:SetText("Mostrar Errores")
    btnShowErrors:SetScript("OnClick", function(self)
        ShowErrors = self:GetChecked()
        if AddMemDB and AddMemDB.config then
            AddMemDB.config.showErrors = ShowErrors
        end
        print("|cffff3333[addmem]|r Mostrar errores de otros addons: " .. (ShowErrors and "|cff00ff00activado|r" or "|cffff0000desactivado|r"))
    end)


    local function UpdateHeaderColors()
        if not AddMem.headers then return end
        for key, btn in pairs(AddMem.headers) do
            if currentSort == key then
                btn.fs:SetTextColor(1, 0.82, 0) -- Gold for selected
            else
                btn.fs:SetTextColor(0.6, 0.6, 0.6) -- Gray for unselected
            end
        end
    end

    local function CreateHeader(text, width, xOffset, sortKey)
        local btn = CreateFrame("Button", nil, AddMem)
        btn:SetSize(width, ROW_HEIGHT)
        btn:SetPoint("TOPLEFT", xOffset, -40)
        
        local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        fs:SetPoint("LEFT", btn, "LEFT")
        fs:SetText(text)
        btn:SetFontString(fs)
        btn.fs = fs
        
        btn:SetScript("OnClick", function()
            currentSort = sortKey
            if AddMemDB and AddMemDB.config then
                AddMemDB.config.currentSort = currentSort
            end
            UpdateHeaderColors()
            AddMem.UpdateUI()
        end)
        
        btn:SetScript("OnEnter", function()
            fs:SetTextColor(1, 1, 1) -- White on hover
        end)
        btn:SetScript("OnLeave", function()
            if currentSort == sortKey then
                fs:SetTextColor(1, 0.82, 0)
            else
                fs:SetTextColor(0.6, 0.6, 0.6)
            end
        end)
        
        return btn
    end

    AddMem.headers = {
        NAME = CreateHeader("Addon", 190, 20, "NAME"),
        MEM = CreateHeader("Memoria", 75, 220, "MEM"),
        CPU = CreateHeader("CPU (%)", 90, 300, "CPU"),
        ALERTS = CreateHeader("Alertas", 230, 400, "ALERTS"),
    }
    UpdateHeaderColors()

    scrollFrame = CreateFrame("ScrollFrame", "AddMemScrollFrame", AddMem, "FauxScrollFrameTemplate")
    scrollFrame:SetWidth(570)
    scrollFrame:SetHeight(300)
    scrollFrame:SetPoint("TOPLEFT", 10, -65)
    scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, AddMem.UpdateUI)
    end)

    for i = 1, MAX_LINES do
        local row = CreateFrame("Frame", nil, AddMem)
        row:SetHeight(ROW_HEIGHT)
        row:SetPoint("LEFT", scrollFrame, "LEFT", 10, 0)
        row:SetPoint("RIGHT", scrollFrame, "RIGHT", -10, 0)
        if i == 1 then
            row:SetPoint("TOP", scrollFrame, "TOP", 0, 0)
        else
            row:SetPoint("TOP", lines[i-1], "BOTTOM", 0, 0)
        end

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        if i % 2 == 0 then
            bg:SetVertexColor(0.1, 0.1, 0.2, 0.3)
        else
            bg:SetVertexColor(0, 0, 0, 0)
        end
        row.bg = bg

        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            self.bg:SetVertexColor(0.2, 0.2, 0.4, 0.6)
            if self.addonName and errorDetails[self.addonName] and #errorDetails[self.addonName] > 0 then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(self.addonName, 1, 1, 1)
                GameTooltip:AddLine("Click para ver detalles del error.", 0.2, 1, 0.2)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(self) 
            if i % 2 == 0 then
                self.bg:SetVertexColor(0.1, 0.1, 0.2, 0.3)
            else
                self.bg:SetVertexColor(0, 0, 0, 0)
            end
            GameTooltip:Hide()
        end)

        row:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and self.addonName then
                local addon = self.addonName
                local details = errorDetails[addon]
                if details and #details > 0 then
                    CreateErrorDetailFrame()
                    errorDetailFrame.title:SetText("Detalles de Errores - |cff00ff00" .. addon .. "|r")
                    
                    local text = ""
                    for j, errInfo in ipairs(details) do
                        text = text .. "|cff33ff33[" .. j .. "] Hora: " .. errInfo.time .. " (Ocurrió " .. (errInfo.count or 1) .. " veces)|r\n"
                        text = text .. "|cffff3333Mensaje:|r " .. errInfo.message .. "\n"
                        text = text .. "|cffffaa00Stack Trace:|r\n" .. errInfo.stack .. "\n"
                        text = text .. "|cff00ffffVariables Locales:|r\n" .. (errInfo.locals or "N/A") .. "\n"
                        text = text .. "--------------------------------------------------\n\n"
                    end
                    
                    errorDetailFrame.editBox:SetText(text)
                    errorDetailFrame:Show()
                else
                    print("|cffff3333[addmem]|r No hay detalles de errores para " .. addon)
                end
            end
        end)

        local tName = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tName:SetPoint("LEFT", 5, 0)
        tName:SetWidth(190)
        tName:SetJustifyH("LEFT")

        local tMem = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tMem:SetPoint("LEFT", 200, 0)
        tMem:SetWidth(75)
        tMem:SetJustifyH("LEFT")

        local tCPU = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tCPU:SetPoint("LEFT", 285, 0)
        tCPU:SetWidth(90)
        tCPU:SetJustifyH("LEFT")

        local tAlert = row:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
        tAlert:SetPoint("LEFT", 385, 0)
        tAlert:SetWidth(230)
        tAlert:SetJustifyH("LEFT")

        row.tName = tName
        row.tMem = tMem
        row.tCPU = tCPU
        row.tAlert = tAlert
        lines[i] = row
    end
end

local minimapBtn
local minimapBtnMoving = false

local function CreateMinimapButton()
    if minimapBtn then return end
    minimapBtn = CreateFrame("Button", "AddMemMinimapButton", Minimap)
    minimapBtn:SetWidth(32)
    minimapBtn:SetHeight(32)
    minimapBtn:SetFrameStrata("MEDIUM")
    minimapBtn:SetMovable(true)
    minimapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapBtn:RegisterForDrag("LeftButton")

    local icon = minimapBtn:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("TOPLEFT", 7, -5)
    icon:SetTexture("Interface\\AddOns\\addmem\\admem.tga")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    minimapBtn.icon = icon

    local border = minimapBtn:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    minimapBtn.border = border

    local radius = 80
    local angle = AddMemDB and AddMemDB.minimapAngle or 225
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(math.rad(angle)), radius * math.sin(math.rad(angle)))

    minimapBtn:SetScript("OnDragStart", function()
        minimapBtnMoving = true
        minimapBtn:SetScript("OnUpdate", function()
            local cx, cy = Minimap:GetCenter()
            local mx, my = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            mx, my = mx / scale, my / scale
            local currentAngle = math.deg(math.atan2(my - cy, mx - cx))
            if AddMemDB then AddMemDB.minimapAngle = currentAngle end
            minimapBtn:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(math.rad(currentAngle)), radius * math.sin(math.rad(currentAngle)))
        end)
    end)

    minimapBtn:SetScript("OnDragStop", function()
        minimapBtnMoving = false
        minimapBtn:SetScript("OnUpdate", nil)
    end)

    minimapBtn:SetScript("OnClick", function(_, button)
        if minimapBtnMoving then
            minimapBtnMoving = false
            return
        end
        if button == "LeftButton" then
            if AddMem:IsVisible() then AddMem:Hide() else AddMem:Show() end
        elseif button == "RightButton" then
            IsActive = not IsActive
            if AddMemDB and AddMemDB.config then
                AddMemDB.config.isActive = IsActive
            end
            if AddMemToggleActive then
                AddMemToggleActive:SetChecked(IsActive)
            end
            UpdateEngineState()
            if not IsActive then ClearMemory() end
            print("|cffff3333[addmem]|r Monitor " .. (IsActive and "|cff00ff00activado|r" or "|cffff0000desactivado|r"))
        end
    end)

    minimapBtn:SetScript("OnEnter", function()
        GameTooltip:SetOwner(minimapBtn, "ANCHOR_LEFT")
        GameTooltip:AddLine("addmem", 1, 0.3, 0.3)
        GameTooltip:AddLine("Click izquierdo: Abrir/Cerrar ventana", 1, 1, 1)
        GameTooltip:AddLine("Click derecho: Activar/Desactivar monitor", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Arrastrar: Mover el botón", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    minimapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local Sorters = {
    MEM = function(a, b)
        if a.mem ~= b.mem then
            return a.mem > b.mem
        end
        return a.name < b.name
    end,
    CPU = function(a, b)
        if a.cpu ~= b.cpu then
            return a.cpu > b.cpu
        end
        return a.mem > b.mem
    end,
    ALERTS = function(a, b)
        local aHas = (a.alertStr and a.alertStr ~= "") and 1 or 0
        local bHas = (b.alertStr and b.alertStr ~= "") and 1 or 0
        if aHas ~= bHas then
            return aHas > bHas
        end
        return a.mem > b.mem
    end,
    NAME = function(a, b)
        return a.name < b.name
    end,
}

function AddMem.UpdateUI()
    if not AddMem:IsVisible() then return end

    local numAddons = GetNumAddOns()
    
    -- Recycle existing tables into dataListPool
    for i = 1, #dataList do
        table.insert(dataListPool, dataList[i])
        dataList[i] = nil
    end

    local idx = 1
    for i = 1, numAddons do
        local name = GetAddOnInfo(i)
        if IsAddOnLoaded(i) then
            local mem = previousMem[name] or 0
            local cpu = cpuDeltas[name] or 0
            
            local memStr = mem > 1024 and string.format("%.2f MB", mem / 1024) or string.format("%.0f KB", mem)
            local cpuStr = cpu > 0 and string.format("%.1f%%", cpu) or "-"
            
            local alertStr = ""
            if alerts[name] then
                wipe(tempAlertKeys)
                for k, _ in pairs(alerts[name]) do
                    table.insert(tempAlertKeys, k)
                end
                table.sort(tempAlertKeys)
                local shown = 0
                for _, k in ipairs(tempAlertKeys) do
                    alertStr = alertStr .. k .. ", "
                    shown = shown + 1
                    if shown >= 3 then break end
                end
                alertStr = string.sub(alertStr, 1, -3)
                if #tempAlertKeys > 3 then alertStr = alertStr .. "..." end
            end

            local rowData = table.remove(dataListPool) or {}
            rowData.name = name
            rowData.mem = mem
            rowData.memStr = memStr
            rowData.cpu = cpu
            rowData.cpuStr = cpuStr
            rowData.alertStr = alertStr
            dataList[idx] = rowData
            idx = idx + 1
        end
    end

    local sorter = Sorters[currentSort] or Sorters.NAME
    table.sort(dataList, sorter)

    FauxScrollFrame_Update(scrollFrame, #dataList, MAX_LINES, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scrollFrame)

    for i = 1, MAX_LINES do
        local idx = offset + i
        local row = lines[i]
        if idx <= #dataList then
            local d = dataList[idx]
            row.tName:SetText(d.name)
            row.tMem:SetText(d.memStr)
            row.tCPU:SetText(d.cpuStr)
            row.tAlert:SetText(d.alertStr)
            row.addonName = d.name
            row:Show()
        else
            row.addonName = nil
            row:Hide()
        end
    end
end

for frameName, _ in pairs(UI_FRAMES_TO_TRACK) do
    if _G[frameName] then
        _G[frameName]:HookScript("OnShow", function()
            local now = GetTime()
            for i = 1, GetNumAddOns() do
                local name = GetAddOnInfo(i)
                gracePeriods[name] = now + GRACE_PERIOD_DURATION
            end
            if IsActive then
                currentInterval = BASE_INTERVAL_BURST
                timeSinceLastUpdate = BASE_INTERVAL_BURST
            end
        end)
    end
end

bgTracker:SetScript("OnUpdate", function(self, elapsed)
    if not ShouldTrack() then
        self:Hide()
        return
    end

    timeSinceLastUpdate = timeSinceLastUpdate + elapsed
    if timeSinceLastUpdate < currentInterval then return end
    timeSinceLastUpdate = 0

    if not isReadyToEvaluate then
        timeSinceEnteringWorld = timeSinceEnteringWorld + currentInterval
        if timeSinceEnteringWorld >= STARTUP_WAIT_TIME then
            isReadyToEvaluate = true
        end
    end
        
        UpdateAddOnMemoryUsage()
        if GetCVar("scriptProfile") == "1" then
            UpdateAddOnCPUUsage()
        end

        local numAddons = GetNumAddOns()
        uptimeTicks = uptimeTicks + 1
        local systemIsStable = true
        local currentTime = GetTime()

        for i = 1, numAddons do
            local name = GetAddOnInfo(i)
            if IsAddOnLoaded(i) then
                if gracePeriods[name] and currentTime < gracePeriods[name] then
                    -- En periodo de gracia
                else
                    local mem = GetAddOnMemoryUsage(i)
                    local cpu = GetCVar("scriptProfile") == "1" and GetAddOnCPUUsage(i) or 0
                    
                    local cfg = (AddMemDB and AddMemDB.config) and AddMemDB.config or DEFAULTS
                if isReadyToEvaluate and uptimeTicks > 3 and not IGNORED_ADDONS[name] then
                    if previousCPU[name] then
                        local cpuDelta = cpu - previousCPU[name]
                        if cpuDelta < 0 then cpuDelta = 0 end
                        cpuDeltas[name] = cpuDelta / 10

                        cpuBaseline[name] = RingPush(cpuBaseline[name], cpuDelta)
                        local avgCPU = RingAvg(cpuBaseline[name])
                        local dynThreshold = math.max(cfg.cpuSpikeDelta or 100, avgCPU * CPU_SPIKE_FACTOR)
                        if cpuDelta > dynThreshold then
                            systemIsStable = false
                            local extra = string.format("Consumo de CPU en este segundo: %.1f ms\nMedia de los últimos 8 segundos: %.1f ms\nUmbral dinámico de alerta: %.1f ms", cpuDelta, avgCPU, dynThreshold)
                            AddAlert(name, "Pico de Lag", extra)
                        end
                    end

                    if previousMem[name] then
                        if mem < previousMem[name] - 50 then
                            if lastMemDrop[name] then
                                local leakDynThreshold = math.max(MEM_LEAK_MIN_KB * 10, mem * MEM_LEAK_PERCENT)
                                
                                if mem > lastMemDrop[name] + leakDynThreshold then
                                    leakStrikes[name] = (leakStrikes[name] or 0) + 1
                                    
                                    if leakStrikes[name] >= 3 then
                                        systemIsStable = false
                                        local memStr = mem > 1024 and string.format("%.2fMB", mem / 1024) or string.format("%.0fKB", mem)
                                        local deltaStr = (mem - lastMemDrop[name]) > 1024 and string.format("%.2fMB", (mem - lastMemDrop[name]) / 1024) or string.format("%.0fKB", mem - lastMemDrop[name])
                                        local extra = string.format("Fuga de Memoria GC-Aware Detectada.\nEl consumo mínimo base subió 3 veces tras limpiezas consecutivas.\nConsumo actual: %s\nIncremento de base: +%s por ciclo", memStr, deltaStr)
                                        AddAlert(name, "Fuga Memoria", extra)
                                        print("|cffff3333[addmem]|r ALERTA GC: |cffffff00" .. name .. "|r no libera " .. deltaStr .. " (Fuga Confirmada)")
                                        leakStrikes[name] = 0
                                    end
                                else
                                    leakStrikes[name] = 0
                                end
                            end
                            lastMemDrop[name] = mem
                        end
                    end

                    local addonThreshold = AddMemDB and AddMemDB.addonThresholds and AddMemDB.addonThresholds[name]
                    local effectiveThreshold = addonThreshold or (cfg.highMemThreshold or HIGH_MEM_THRESHOLD_KB)
                    if mem > effectiveThreshold then
                        local delta = previousMem[name] and (mem - previousMem[name]) or 0
                        if delta > MEM_ABRUPT_DELTA then
                            isAbruptGrowth[name] = true
                        end
                        if delta < MEM_STABLE_DELTA then
                            memStableTicks[name] = (memStableTicks[name] or 0) + 1
                            if memStableTicks[name] >= MEM_STABLE_TICKS and not altoConsumoAlerted[name] then
                                if isAbruptGrowth[name] then
                                    local memStr = mem > 1024 and string.format("%.2fMB", mem / 1024) or string.format("%.0fKB", mem)
                                    altoConsumoAlerted[name] = true
                                    local extra = string.format("El addon se ha estabilizado por encima de su umbral tras una carga abrupta (>1MB/s).\nConsumo total estable: %s\nUmbral configurado: %s", memStr, effectiveThreshold > 1024 and string.format("%.2fMB", effectiveThreshold / 1024) or string.format("%.0fKB", effectiveThreshold))
                                    AddAlert(name, "Alto Consumo", extra)
                                end
                            end
                        else
                            memStableTicks[name] = 0
                        end
                    else
                        memStableTicks[name] = nil
                        altoConsumoAlerted[name] = nil
                        isAbruptGrowth[name] = nil
                    end
                end
                
                    previousCPU[name] = cpu
                    previousMem[name] = mem
                end
            end
        end
        
        if systemIsStable then
            currentInterval = math.min(BASE_INTERVAL_IDLE, currentInterval + 1.0)
        else
            currentInterval = BASE_INTERVAL_BURST
        end

        AddMem.UpdateUI()
end)

local ehCheck = CreateFrame("Frame")
ehCheck:SetScript("OnUpdate", function(self, elapsed)
    self.elapsed = (self.elapsed or 0) + elapsed
    if self.elapsed < 10 then return end
    self.elapsed = 0
    local current = geterrorhandler()
    if current ~= ourHandler then
        ourHandler = MakeErrorHandler(current)
        seterrorhandler(ourHandler)
    end
end)

AddMem:RegisterEvent("ADDON_LOADED")
AddMem:RegisterEvent("CHAT_MSG_ADDON")
AddMem:RegisterEvent("PLAYER_ENTERING_WORLD")
AddMem:SetScript("OnEvent", function(self, event, arg1, arg2, arg3, arg4)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        AddMemDB = AddMemDB or {}
        AddMemDB.alerts = AddMemDB.alerts or {}
        AddMemDB.config = AddMemDB.config or {}
        AddMemDB.addonThresholds = AddMemDB.addonThresholds or {}
        for k, v in pairs(DEFAULTS) do
            if AddMemDB.config[k] == nil then
                AddMemDB.config[k] = v
            end
        end
        IsActive = AddMemDB.config.isActive
        IsBackgroundActive = AddMemDB.config.isBackgroundActive
        ShowErrors = AddMemDB.config.showErrors
        currentSort = AddMemDB.config.currentSort
        for addon, data in pairs(AddMemDB.alerts) do
            if not alerts[addon] then alerts[addon] = {} end
            for alertType, _ in pairs(data) do
                alerts[addon][alertType] = true
            end
        end
        CreateMinimapButton()
    elseif event == "PLAYER_ENTERING_WORLD" then
        isReadyToEvaluate = false
        timeSinceEnteringWorld = 0
        local now = GetTime()
        for i = 1, GetNumAddOns() do
            gracePeriods[GetAddOnInfo(i)] = now + 30
        end
    elseif event == "CHAT_MSG_ADDON" and arg1 == "AddMemVer" then
        local msg = arg2
        local sender = arg4
        if msg == "req" then
            local version = GetAddOnMetadata(ADDON_NAME, "Version") or "Desconocida"
            SendAddonMessage("AddMemVer", version, "WHISPER", sender)
        else
            print("|cffff3333[addmem]|r " .. sender .. ": Versión " .. msg)
        end
    end
end)

AddMem:SetScript("OnHide", function()
    UpdateEngineState()
    if not IsBackgroundActive or not IsActive then
        ClearMemory()
    end
end)

AddMem:SetScript("OnShow", function()
    UpdateEngineState()
    CreateUI()
    AddMem.UpdateUI()
end)

local function ResetAll()
    if GetCVar("scriptProfile") == "1" then
        ResetCPUUsage()
    end
    ClearMemory()
    if AddMem:IsVisible() then AddMem.UpdateUI() end
    print("|cffff3333[addmem]|r Datos reiniciados.")
end

SLASH_ADDMEM1 = "/addmem"
SLASH_ADDMEM2 = "/admem"
SlashCmdList["ADDMEM"] = function(cmd)
    cmd = (cmd or ""):match("^%s*(.-)%s*$") or ""
    if cmd == "reset" then
        ResetAll()
    elseif cmd == "bg" or cmd == "background" then
        IsBackgroundActive = not IsBackgroundActive
        if AddMemDB and AddMemDB.config then
            AddMemDB.config.isBackgroundActive = IsBackgroundActive
        end
        if AddMemToggleBG then
            AddMemToggleBG:SetChecked(IsBackgroundActive)
        end
        UpdateEngineState()
        if not IsBackgroundActive and not AddMem:IsVisible() then ClearMemory() end
        print("|cffff3333[addmem]|r Segundo plano " .. (IsBackgroundActive and "|cff00ff00activado|r" or "|cffff0000desactivado|r"))
    elseif cmd == "ver" then
        local version = GetAddOnMetadata(ADDON_NAME, "Version") or "Desconocida"
        print("|cffff3333[addmem]|r Mi versión: " .. version)
        
        local channel = nil
        if GetNumRaidMembers() > 0 then
            channel = "RAID"
        elseif GetNumPartyMembers() > 0 then
            channel = "PARTY"
        end
        
        if channel then
            print("|cffff3333[addmem]|r Consultando versiones en " .. channel .. "...")
            SendAddonMessage("AddMemVer", "req", channel)
        end
    elseif cmd == "config" or cmd == "cfg" or cmd == "settings" then
        CreateConfigFrame()
    elseif cmd == "errors" then
        ShowErrors = not ShowErrors
        if AddMemDB and AddMemDB.config then
            AddMemDB.config.showErrors = ShowErrors
        end
        if AddMemShowErrors then
            AddMemShowErrors:SetChecked(ShowErrors)
        end
        print("|cffff3333[addmem]|r Mostrar errores de otros addons: " .. (ShowErrors and "|cff00ff00activado|r" or "|cffff0000desactivado|r"))
    else
        if AddMem:IsVisible() then AddMem:Hide() else
            CreateUI()
            AddMem:Show()
        end
    end
end

SLASH_ADDMEMVER1 = "/ver"
SlashCmdList["ADDMEMVER"] = function()
    local version = GetAddOnMetadata(ADDON_NAME, "Version") or "Desconocida"
    print("|cffff3333[addmem]|r Versión: " .. version)
end
