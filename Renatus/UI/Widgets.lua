-- UI/Widgets.lua: standalone UI components.
-- FrameXML templates are deliberately avoided (WoW Forever removed many of them):
-- everything is built from plain frames, textures and fonts.
local _, ns = ...

local UI = {}
ns.UI = UI

UI.FONT_TITLE = "Fonts\\MORPHEUS.TTF"
UI.FONT_BODY = "Fonts\\FRIZQT__.TTF"

UI.C = {
    gold = { 1, 0.82, 0 },
    text = { 0.92, 0.88, 0.78 },
    dim = { 0.62, 0.58, 0.5 },
    ink = { 0.24, 0.14, 0.06 },
    inkDim = { 0.42, 0.3, 0.18 },
    red = { 0.78, 0.16, 0.1 },
    green = { 0.4, 0.85, 0.4 },
    bg = { 0.07, 0.055, 0.04, 0.97 },
    panel = { 0.13, 0.1, 0.075, 0.95 },
    panelLight = { 0.19, 0.15, 0.11, 0.95 },
    parchment = { 0.86, 0.78, 0.6, 1 },
    border = { 0.55, 0.42, 0.22, 1 },
}

local CLASS_COORDS = {
    WARRIOR = { 0, 0.25, 0, 0.25 }, MAGE = { 0.25, 0.49609375, 0, 0.25 },
    ROGUE = { 0.49609375, 0.7421875, 0, 0.25 }, DRUID = { 0.7421875, 0.98828125, 0, 0.25 },
    HUNTER = { 0, 0.25, 0.25, 0.5 }, SHAMAN = { 0.25, 0.49609375, 0.25, 0.5 },
    PRIEST = { 0.49609375, 0.7421875, 0.25, 0.5 }, WARLOCK = { 0.7421875, 0.98828125, 0.25, 0.5 },
    PALADIN = { 0, 0.25, 0.5, 0.75 },
}
local CLASS_COLORS = {
    WARRIOR = { 0.78, 0.61, 0.43 }, MAGE = { 0.25, 0.78, 0.92 }, ROGUE = { 1, 0.96, 0.41 },
    DRUID = { 1, 0.49, 0.04 }, HUNTER = { 0.67, 0.83, 0.45 }, SHAMAN = { 0, 0.44, 0.87 },
    PRIEST = { 1, 1, 1 }, WARLOCK = { 0.53, 0.53, 0.93 }, PALADIN = { 0.96, 0.55, 0.73 },
}

function UI.ClassColor(class)
    local c = RAID_CLASS_COLORS and class and RAID_CLASS_COLORS[class]
    if c and c.r then return c.r, c.g, c.b end
    c = CLASS_COLORS[class or ""] or UI.C.text
    return c[1], c[2], c[3]
end

function UI.ColorHex(r, g, b)
    return string.format("ff%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
end

function UI.ClassName(name, class)
    local r, g, b = UI.ClassColor(class)
    return "|c" .. UI.ColorHex(r, g, b) .. tostring(name) .. "|r"
end

function UI.SetClassIcon(tex, class)
    local coords = (CLASS_ICON_TCOORDS and class and CLASS_ICON_TCOORDS[class]) or CLASS_COORDS[class or ""]
    if coords then
        tex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        tex:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
    else
        tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end
end

-- CreateFrame with an optional template: if the template does not exist, do without.
function UI.Create(frameType, parent, template, name)
    if template then
        local ok, f = pcall(CreateFrame, frameType, name, parent, template)
        if ok and f then return f end
    end
    return CreateFrame(frameType, name, parent)
end

-- Background + border with plain textures (works with or without BackdropTemplate).
function UI.Box(frame, bg, border, thickness)
    thickness = thickness or 1
    if not frame.gcBg then
        frame.gcBg = frame:CreateTexture(nil, "BACKGROUND")
        frame.gcBg:SetAllPoints()
        frame.gcEdges = {}
        for i = 1, 4 do frame.gcEdges[i] = frame:CreateTexture(nil, "BORDER") end
        local e = frame.gcEdges
        e[1]:SetPoint("TOPLEFT"); e[1]:SetPoint("TOPRIGHT"); e[1]:SetHeight(thickness)
        e[2]:SetPoint("BOTTOMLEFT"); e[2]:SetPoint("BOTTOMRIGHT"); e[2]:SetHeight(thickness)
        e[3]:SetPoint("TOPLEFT"); e[3]:SetPoint("BOTTOMLEFT"); e[3]:SetWidth(thickness)
        e[4]:SetPoint("TOPRIGHT"); e[4]:SetPoint("BOTTOMRIGHT"); e[4]:SetWidth(thickness)
    end
    bg = bg or UI.C.panel
    frame.gcBg:SetColorTexture(bg[1], bg[2], bg[3], bg[4] or 1)
    border = border or UI.C.border
    for _, t in ipairs(frame.gcEdges) do t:SetColorTexture(border[1], border[2], border[3], border[4] or 1) end
    return frame
end

------------------------------------------------------------------------
-- Medieval skin: textures shipped with the game client (dialog borders, stone,
-- parchment, red panel buttons). Each one is checked before use; when a texture
-- or the backdrop API is missing, the flat UI.Box look above is used instead.
------------------------------------------------------------------------
UI.TEX = {
    white = "Interface\\Buttons\\WHITE8X8",
    rock = "Interface\\FrameGeneral\\UI-Background-Rock",
    dark = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    parchment = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal",
    goldBorder = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    thinBorder = "Interface\\Tooltips\\UI-Tooltip-Border",
    buttonUp = "Interface\\Buttons\\UI-Panel-Button-Up",
    buttonDown = "Interface\\Buttons\\UI-Panel-Button-Down",
    buttonHighlight = "Interface\\Buttons\\UI-Panel-Button-Highlight",
    closeUp = "Interface\\Buttons\\UI-Panel-MinimizeButton-Up",
    closeDown = "Interface\\Buttons\\UI-Panel-MinimizeButton-Down",
    closeHighlight = "Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight",
    glow = "Interface\\QuestFrame\\UI-QuestTitleHighlight",
}

-- True if the client has this texture file (unknown = assumed present).
function UI.HasFile(path)
    if not path then return false end
    if GetFileIDFromPath then
        local ok, id = pcall(GetFileIDFromPath, path)
        if ok then return id ~= nil end
    end
    return true
end

local STYLES = {
    -- Main window and dialogs: stone background, gold dialog border.
    window = { bg = UI.TEX.rock, bgColor = { 0.4, 0.34, 0.28, 1 }, tile = 256,
        edge = UI.TEX.goldBorder, edgeSize = 32, inset = 11,
        flatBg = UI.C.bg, flatBorder = { 0.75, 0.58, 0.25, 1 }, flatSize = 2 },
    -- Panels inside the window: dark leather, thin bronze border.
    panel = { bg = UI.TEX.dark, bgColor = { 1, 1, 1, 0.85 }, tile = 64,
        edge = UI.TEX.thinBorder, edgeSize = 16, inset = 4, edgeColor = { 0.72, 0.56, 0.3, 1 },
        flatBg = UI.C.panel, flatBorder = { 0.4, 0.3, 0.16, 1 } },
    -- Parchment: gazette pages, wanted posters.
    parchment = { bg = UI.TEX.parchment, bgColor = { 1, 0.96, 0.86, 1 },
        edge = UI.TEX.thinBorder, edgeSize = 16, inset = 3, edgeColor = { 0.36, 0.22, 0.1, 1 },
        flatBg = UI.C.parchment, flatBorder = { 0.3, 0.18, 0.08, 1 }, flatSize = 2 },
    -- Input fields and dropdowns: almost black, thin bronze border.
    field = { bg = UI.TEX.white, bgColor = { 0.03, 0.025, 0.02, 0.9 },
        edge = UI.TEX.thinBorder, edgeSize = 12, inset = 3, edgeColor = { 0.6, 0.47, 0.25, 1 },
        flatBg = { 0.03, 0.025, 0.02, 1 }, flatBorder = UI.C.border },
}
UI.STYLES = STYLES

local function backdrop(frame, st)
    if not (UI.HasFile(st.bg) and UI.HasFile(st.edge)) then return false end
    if not frame.SetBackdrop and BackdropTemplateMixin and Mixin then
        -- What the BackdropTemplate XML template does, without needing the template.
        Mixin(frame, BackdropTemplateMixin)
        if frame.OnBackdropSizeChanged then frame:HookScript("OnSizeChanged", frame.OnBackdropSizeChanged) end
    end
    if not frame.SetBackdrop then return false end
    local i = st.inset
    local ok = pcall(frame.SetBackdrop, frame, {
        bgFile = st.bg, edgeFile = st.edge, edgeSize = st.edgeSize,
        tile = st.tile ~= nil, tileSize = st.tile or 0, tileEdge = true,
        insets = { left = i, right = i, top = i, bottom = i },
    })
    if not ok then return false end
    local c = st.bgColor
    if frame.SetBackdropColor then frame:SetBackdropColor(c[1], c[2], c[3], c[4]) end
    local e = st.edgeColor
    if e and frame.SetBackdropBorderColor then frame:SetBackdropBorderColor(e[1], e[2], e[3], e[4]) end
    return true
end

-- Dresses a frame in one of the STYLES; falls back to the flat look.
function UI.Skin(frame, style)
    local st = STYLES[style] or STYLES.panel
    if backdrop(frame, st) then
        frame.gcSkin = style
    else
        frame.gcSkin = nil
        UI.Box(frame, st.flatBg, st.flatBorder, st.flatSize)
    end
    return frame
end

function UI.Text(parent, size, color, font, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(font or UI.FONT_BODY, size or 12, "")
    if not fs:GetFont() and GameFontHighlight then fs:SetFontObject(GameFontHighlight) end
    color = color or UI.C.text
    fs:SetTextColor(color[1], color[2], color[3])
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    return fs
end

function UI.Title(parent, size, color)
    local fs = UI.Text(parent, size or 18, color or UI.C.gold, UI.FONT_TITLE)
    fs:SetShadowOffset(1, -1)
    return fs
end

function UI.Icon(parent, size, path)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetSize(size, size)
    t:SetTexture(path or "Interface\\Icons\\INV_Misc_QuestionMark")
    t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    return t
end

function UI.Tooltip(owner, title, lines)
    if not GameTooltip then return end
    owner:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local t, l = title, lines
        if type(title) == "function" then t, l = title(self) end
        if not t then return end
        GameTooltip:AddLine(t, 1, 0.82, 0, true)
        for _, line in ipairs(l or {}) do
            if type(line) == "table" then GameTooltip:AddLine(line[1], line[2], line[3], line[4], true)
            else GameTooltip:AddLine(line, 0.9, 0.9, 0.9, true) end
        end
        GameTooltip:Show()
    end)
    owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function UI.Click()
    if PlaySound and SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON then
        pcall(PlaySound, SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end
end

------------------------------------------------------------------------
-- Button
------------------------------------------------------------------------
local BUTTON_COORDS = { 0, 0.625, 0, 0.6875 } -- useful part of UI-Panel-Button-*

local function textured(b)
    local T = UI.TEX
    if not (UI.HasFile(T.buttonUp) and UI.HasFile(T.buttonDown)) then return false end
    local c = BUTTON_COORDS
    b.face = b:CreateTexture(nil, "BACKGROUND")
    b.face:SetAllPoints()
    b.face:SetTexture(T.buttonUp)
    b.face:SetTexCoord(c[1], c[2], c[3], c[4])
    b:HookScript("OnMouseDown", function(self)
        if self.gcDisabled then return end
        self.face:SetTexture(T.buttonDown)
        self.label:SetPoint("CENTER", 1, -1)
    end)
    b:HookScript("OnMouseUp", function(self)
        self.face:SetTexture(T.buttonUp)
        self.label:SetPoint("CENTER", 0, 0)
    end)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(T.buttonHighlight)
    hl:SetTexCoord(c[1], c[2], c[3], c[4])
    hl:SetBlendMode("ADD")
    return true
end

-- flat = true: no red button texture (dropdowns, which get the "field" skin).
function UI.Button(parent, label, width, height, onClick, flat)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width or 110, height or 22)
    if flat or not textured(b) then
        UI.Box(b, { 0.32, 0.08, 0.05, 1 }, { 0.75, 0.58, 0.25, 1 })
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 0.85, 0.4, 0.15)
    end
    b.label = UI.Text(b, 12, UI.C.gold)
    b.label:SetPoint("CENTER")
    b.label:SetJustifyH("CENTER")
    b.label:SetJustifyV("MIDDLE")
    b.label:SetText(label)
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnClick", function(self, ...)
        if self.gcDisabled then return end
        UI.Click()
        if onClick then onClick(self, ...) end
    end)
    function b:SetLabel(text) self.label:SetText(text) end
    function b:SetDisabled(disabled)
        self.gcDisabled = disabled
        self:SetAlpha(disabled and 0.45 or 1)
    end
    return b
end

-- Tab button (selectable)
function UI.ToggleButton(parent, label, width, height, onClick)
    local b = UI.Button(parent, label, width, height, onClick)
    function b:SetSelected(selected)
        self.selected = selected
        if self.face then
            -- Textured: the selected button stays lit, the others are dimmed.
            local v = selected and 1 or 0.55
            self.face:SetVertexColor(v, v, v)
            if selected then self.label:SetTextColor(1, 1, 1)
            else self.label:SetTextColor(UI.C.gold[1], UI.C.gold[2], UI.C.gold[3]) end
            return
        end
        if selected then
            UI.Box(self, { 0.55, 0.38, 0.12, 1 }, { 1, 0.82, 0.3, 1 })
            self.label:SetTextColor(1, 1, 1)
        else
            UI.Box(self, { 0.18, 0.12, 0.08, 1 }, { 0.5, 0.38, 0.2, 1 })
            self.label:SetTextColor(UI.C.gold[1], UI.C.gold[2], UI.C.gold[3])
        end
    end
    b:SetSelected(false)
    return b
end

------------------------------------------------------------------------
-- Checkbox
------------------------------------------------------------------------
function UI.Checkbox(parent, label, onChange)
    local cb = CreateFrame("CheckButton", nil, parent)
    cb:SetSize(22, 22)
    cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
    cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
    cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
    cb.label = UI.Text(cb, 12)
    cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    cb.label:SetJustifyV("MIDDLE")
    cb.label:SetText(label or "")
    cb:SetScript("OnClick", function(self)
        UI.Click()
        if onChange then onChange(self:GetChecked() and true or false) end
    end)
    return cb
end

------------------------------------------------------------------------
-- Slider
------------------------------------------------------------------------
function UI.Slider(parent, label, minV, maxV, step, width, format, onChange)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(width or 220, 40)
    holder.label = UI.Text(holder, 12)
    holder.label:SetPoint("TOPLEFT")
    local s = CreateFrame("Slider", nil, holder)
    s:SetOrientation("HORIZONTAL")
    s:SetPoint("TOPLEFT", 0, -18)
    s:SetSize(width or 220, 14)
    UI.Box(s, { 0.05, 0.04, 0.03, 1 }, UI.C.border)
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    if s.SetObeyStepMode then s:SetObeyStepMode(true) end
    local function refresh(value)
        holder.label:SetText(label .. " : |cffffffff" .. string.format(format or "%s", value) .. "|r")
    end
    s:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value / step + 0.5) * step
        refresh(value)
        if holder.ready and onChange then onChange(value) end
    end)
    function holder:SetValue(v)
        self.ready = false
        s:SetValue(v)
        refresh(v)
        self.ready = true
    end
    holder.slider = s
    return holder
end

------------------------------------------------------------------------
-- Edit box
------------------------------------------------------------------------
function UI.EditBox(parent, width, height, multiline, maxLetters)
    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(width, height or 24)
    UI.Skin(box, "field")
    local e = CreateFrame("EditBox", nil, box)
    e:SetPoint("TOPLEFT", 6, -4)
    e:SetPoint("BOTTOMRIGHT", -6, 4)
    e:SetFont(UI.FONT_BODY, 12, "")
    e:SetTextColor(1, 1, 1)
    e:SetAutoFocus(false)
    e:SetMaxLetters(maxLetters or 200)
    if multiline then e:SetMultiLine(true) end
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    if not multiline then e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end) end
    box:SetScript("OnMouseDown", function() e:SetFocus() end)
    box.edit = e
    function box:GetText() return e:GetText() or "" end
    function box:SetText(t) e:SetText(t or "") end
    return box
end

------------------------------------------------------------------------
-- Dropdown (custom menu, only one menu open at a time)
------------------------------------------------------------------------
local menu
local function getMenu()
    if menu then return menu end
    menu = CreateFrame("Frame", nil, UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    UI.Skin(menu, "field")
    menu.buttons = {}
    menu:Hide()
    menu:SetScript("OnUpdate", function(self)
        if IsMouseButtonDown and IsMouseButtonDown("LeftButton") and not self:IsMouseOver()
            and not (self.owner and self.owner:IsMouseOver()) then
            self:Hide()
        end
    end)
    return menu
end

function UI.CloseMenus() if menu then menu:Hide() end end

-- options: list of { value=, label= } or a function returning it
function UI.Dropdown(parent, width, options, onSelect)
    local d = UI.Button(parent, "", width or 140, 22, nil, true)
    UI.Skin(d, "field")
    d.label:ClearAllPoints()
    d.label:SetPoint("LEFT", 8, 0)
    d.label:SetPoint("RIGHT", -18, 0)
    d.label:SetJustifyH("LEFT")
    local arrow = UI.Text(d, 10, UI.C.gold)
    arrow:SetPoint("RIGHT", -6, 0)
    arrow:SetText("v")
    function d:GetOptions() return type(options) == "function" and options() or options end
    function d:SetValue(value)
        self.value = value
        for _, o in ipairs(self:GetOptions()) do
            if o.value == value then self.label:SetText(o.label) return end
        end
        self.label:SetText(tostring(value))
    end
    d:SetScript("OnClick", function(self)
        local m = getMenu()
        if m:IsShown() and m.owner == self then m:Hide() return end
        UI.Click()
        local opts = self:GetOptions()
        m.owner = self
        m:ClearAllPoints()
        m:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
        m:SetSize(self:GetWidth(), #opts * 20 + 6)
        for i, o in ipairs(opts) do
            local b = m.buttons[i]
            if not b then
                b = CreateFrame("Button", nil, m)
                b:SetHeight(20)
                local hl = b:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints()
                hl:SetColorTexture(1, 0.85, 0.4, 0.2)
                b.text = UI.Text(b, 12)
                b.text:SetPoint("LEFT", 8, 0)
                b.text:SetJustifyV("MIDDLE")
                m.buttons[i] = b
            end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", 4, -3 - (i - 1) * 20)
            b:SetPoint("RIGHT", -4, 0)
            b.text:SetText(o.label)
            if o.value == self.value then b.text:SetTextColor(1, 0.82, 0) else b.text:SetTextColor(0.92, 0.88, 0.78) end
            b:SetScript("OnClick", function()
                m:Hide()
                self:SetValue(o.value)
                if onSelect then onSelect(o.value) end
            end)
            b:Show()
        end
        for i = #opts + 1, #m.buttons do m.buttons[i]:Hide() end
        m:Show()
    end)
    return d
end

------------------------------------------------------------------------
-- Virtual list (recycled rows, mouse wheel + scrollbar)
------------------------------------------------------------------------
function UI.List(parent, width, height, rowHeight, createRow, updateRow)
    local list = CreateFrame("Frame", nil, parent)
    list:SetSize(width, height)
    list.items, list.offset, list.rows = {}, 0, {}
    local visible = math.floor(height / rowHeight)
    for i = 1, visible do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(width - 14, rowHeight - 2)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * rowHeight)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 0.85, 0.4, 0.08)
        createRow(row)
        list.rows[i] = row
    end
    local bar = CreateFrame("Slider", nil, list)
    bar:SetOrientation("VERTICAL")
    bar:SetPoint("TOPRIGHT", 0, 0)
    bar:SetSize(10, height)
    UI.Box(bar, { 0.05, 0.04, 0.03, 0.8 }, { 0.3, 0.22, 0.12, 1 })
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.75, 0.58, 0.25, 1)
    thumb:SetSize(10, 30)
    bar:SetThumbTexture(thumb)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value + 0.5)
        if value ~= list.offset then list.offset = value; list:Refresh() end
    end)
    list.bar = bar
    list.empty = UI.Text(list, 13, UI.C.dim)
    list.empty:SetPoint("TOP", 0, -40)
    list.empty:SetWidth(width - 60)
    list.empty:SetJustifyH("CENTER")

    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #list.items - visible)
        list.offset = math.max(0, math.min(maxOffset, list.offset - delta * 3))
        bar:SetValue(list.offset)
        list:Refresh()
    end)

    function list:Refresh()
        for i, row in ipairs(self.rows) do
            local item = self.items[self.offset + i]
            if item then
                row.item = item
                updateRow(row, item)
                row:Show()
            else
                row.item = nil
                row:Hide()
            end
        end
    end
    function list:SetItems(items, emptyText)
        self.items = items or {}
        local maxOffset = math.max(0, #self.items - visible)
        if self.offset > maxOffset then self.offset = maxOffset end
        bar:SetMinMaxValues(0, maxOffset)
        bar:SetValue(self.offset)
        if maxOffset > 0 then bar:Show() else bar:Hide() end
        self.empty:SetText(#self.items == 0 and (emptyText or "Rien à afficher.") or "")
        self:Refresh()
    end
    return list
end

------------------------------------------------------------------------
-- Scrolling text area (reading articles, records)
------------------------------------------------------------------------
function UI.ScrollText(parent, width, height, size, color)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    sf:SetSize(width, height)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(width - 12, 10)
    sf:SetScrollChild(child)
    local fs = UI.Text(child, size or 13, color)
    fs:SetPoint("TOPLEFT")
    fs:SetWidth(width - 12)
    fs:SetSpacing(3)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, (fs:GetStringHeight() or 0) - height + 10)
        local v = math.max(0, math.min(maxScroll, self:GetVerticalScroll() - delta * 30))
        self:SetVerticalScroll(v)
    end)
    function sf:SetText(text)
        fs:SetText(text or "")
        child:SetHeight(math.max(10, (fs:GetStringHeight() or 0) + 10))
        self:SetVerticalScroll(0)
    end
    sf.fontString = fs
    return sf
end

------------------------------------------------------------------------
-- Dates
------------------------------------------------------------------------
local MONTHS = { "janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc." }
function UI.Date(t, withTime)
    if not t then return "?" end
    local d = date("*t", t)
    local s = d.day .. " " .. MONTHS[d.month] .. " " .. d.year
    if withTime then s = s .. string.format(" à %02d:%02d", d.hour, d.min) end
    return s
end

function UI.Ago(t)
    if not t then return "jamais" end
    local diff = ns.Views.Now() - t
    if diff < 3600 then return "il y a " .. math.max(1, math.floor(diff / 60)) .. " min" end
    if diff < 86400 then return "il y a " .. math.floor(diff / 3600) .. " h" end
    local days = math.floor(diff / 86400)
    return days == 1 and "hier" or ("il y a " .. days .. " jours")
end

-- Titled section (gold subtitle + rule)
function UI.Section(parent, text, width)
    local fs = UI.Title(parent, 15)
    fs:SetText(text)
    -- Gold rule in three segments, fading out to the right.
    width = width or 300
    local alphas = { 0.75, 0.45, 0.2 }
    local prev
    for i, a in ipairs(alphas) do
        local seg = parent:CreateTexture(nil, "ARTWORK")
        seg:SetColorTexture(0.85, 0.66, 0.28, a)
        seg:SetHeight(1)
        seg:SetWidth(width / #alphas)
        if prev then seg:SetPoint("LEFT", prev, "RIGHT") else seg:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -3) end
        prev = seg
        if i == 1 then fs.line = seg end
    end
    return fs
end
