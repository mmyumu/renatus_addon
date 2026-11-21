-- UI/TabAlbum.lua: guild card album (collection, sets, boosters).
-- A card: illustrated window (backdrop of its series, then a 3D model of the creature or of
-- the member, else a crisp icon in a medallion), name banner, text, number and date.
-- Opening a booster: the pack shakes and tears open, five cards are dealt face down and
-- turned one by one (click) or all at once.
local _, ns = ...
local UI = ns.UI
local Album = ns.Album

local CARD_W, CARD_H = 132, 184
local COLS, ROWS = 5, 2
local PER_PAGE = COLS * ROWS
local ART_W, ART_H = CARD_W - 20, 88
local ICON = 50

-- Profiles of the members (CARD_PROFILE), for their portraits; set by the tab and the booster.
UI.cardProfiles = {}

------------------------------------------------------------------------
-- Card art
------------------------------------------------------------------------
local ICONS = "Interface\\Icons\\"
local artCache = {}

-- True if the client has this file (unknown = assumed present).
function UI.HasFile(path)
    if not GetFileIDFromPath then return true end
    local ok, id = pcall(GetFileIDFromPath, path)
    if not ok then return true end
    return id ~= nil
end

-- Icon of a card: its own, else the first candidate present on this client.
function UI.CardArt(card)
    if card.icon then return card.icon end
    if not card.icons or #card.icons == 0 then return nil end
    local cached = artCache[card.id]
    if cached then return cached end
    local chosen = ICONS .. card.icons[#card.icons]
    for _, name in ipairs(card.icons) do
        if UI.HasFile(ICONS .. name) then chosen = ICONS .. name break end
    end
    artCache[card.id] = chosen
    return chosen
end

-- Backdrop of the illustration, by series.
local BACKDROP = {
    est = "lieu", kalimdor = "lieu", donjons = "donjon", expeditions = "donjon",
    personnages = "guilde", heros = "guilde", members = "guilde", founders = "guilde", legends = "guilde",
    bestiaire = "bestiaire", sworn = "ennemi", une = "presse", faits = "presse", tresors = "tresor",
}
function UI.CardBackdrop(card) return UI.MEDIA .. "cardbg_" .. (BACKDROP[card.series] or "guilde") end

-- Race portrait of a member (achievement icons), from their profile.
local RACE_ICON = { Scourge = "Undead", NightElf = "Nightelf", BloodElf = "Bloodelf" }
function UI.RacePortrait(profile)
    if not profile or type(profile.raceFile) ~= "string" then return nil end
    local race = RACE_ICON[profile.raceFile] or profile.raceFile
    local path = ICONS .. "Achievement_Character_" .. race .. "_" .. (profile.sex == 3 and "Female" or "Male")
    return UI.HasFile(path) and path or nil
end

function UI.CardNumber(card)
    if type(card.no) == "number" then return ("N° %03d"):format(card.no) end
    if card.no then return "N° " .. card.no end
    return ""
end

function UI.CardDate(card) return card.t and date("%d/%m/%Y", card.t) or "" end

------------------------------------------------------------------------
-- 3D portrait: the creature (card.npc) or the member (their CARD_PROFILE). Every call is
-- protected; a model that stays empty gives way to the icon.
------------------------------------------------------------------------
local function modelFrame(f, kind)
    f.models = f.models or {}
    if f.models[kind] == nil then
        local ok, m = pcall(CreateFrame, kind == "player" and "DressUpModel" or "PlayerModel", nil, f)
        if not ok or not m then
            f.models[kind] = false
        else
            m:SetPoint("TOPLEFT", f.art, "TOPLEFT", 1, -1)
            m:SetPoint("BOTTOMRIGHT", f.art, "BOTTOMRIGHT", -1, 1)
            m:SetFrameLevel((f:GetFrameLevel() or 1) + 1)
            m:SetScript("OnUpdate", function(self, elapsed)
                -- Slow turn while the card is hovered.
                if f.IsMouseOver and f:IsMouseOver() then
                    self.facing = (self.facing or 0) + elapsed * 0.9
                    pcall(self.SetFacing, self, self.facing)
                end
            end)
            m:Hide()
            f.models[kind] = m
        end
    end
    return f.models[kind] or nil
end

local function hideModels(f)
    for _, m in pairs(f.models or {}) do if m then m:Hide() end end
end

local function call(m, method, ...)
    local fn = m[method]
    if not fn then return false end
    return pcall(fn, m, ...)
end

local function showIcon(f, card)
    local profile = card.guid and UI.cardProfiles[card.guid]
    local art = UI.CardArt(card) or UI.RacePortrait(profile)
    if art then
        f.icon:SetTexture(art)
        f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    else
        UI.SetClassIcon(f.icon, card.class or (profile and profile.class))
    end
    f.icon:Show()
    f.ring:Show()
end

-- Returns true if a model is being shown (the icon waits for its check).
local function showModel(f, card)
    local profile = card.guid and UI.cardProfiles[card.guid]
    local m
    if card.npc then
        m = modelFrame(f, "creature")
        if not m or not call(m, "SetCreature", card.npc) then return false end
        call(m, "SetPortraitZoom", 0.55)
    elseif profile and profile.race then
        m = modelFrame(f, "player")
        if not m or not call(m, "SetUnit", "player") then return false end
        if not call(m, "SetCustomRace", profile.race, (profile.sex == 3) and 1 or 0) then return false end
        call(m, "Undress")
        for item in tostring(profile.items or ""):gmatch("%d+:(%d+)") do call(m, "TryOn", "item:" .. item) end
        call(m, "SetPortraitZoom", 0.75)
    else
        return false
    end
    m.facing = 0
    call(m, "SetFacing", 0)
    m:Show()
    -- An unknown creature (or an API missing on this client) leaves the model empty.
    local token = f.fillToken
    local function check()
        if f.fillToken ~= token then return end
        local ok, id = call(m, "GetModelFileID")
        if not ok or not id or id == 0 then m:Hide(); showIcon(f, card) end
    end
    if C_Timer then C_Timer.After(0.6, check) else check() end
    return true
end

------------------------------------------------------------------------
-- Card rendering (shared by the grid, the zoom and booster opening)
------------------------------------------------------------------------
function UI.CreateCard(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(CARD_W, CARD_H)
    -- glow behind epic and legendary cards
    f.glow = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    f.glow:SetPoint("TOPLEFT", -18, 18)
    f.glow:SetPoint("BOTTOMRIGHT", 18, -18)
    f.glow:SetTexture(UI.MEDIA .. "glow")
    f.glow:SetBlendMode("ADD")
    -- face
    f.base = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    f.base:SetPoint("TOPLEFT", 3, -3)
    f.base:SetPoint("BOTTOMRIGHT", -3, 3)
    f.base:SetColorTexture(0.1, 0.07, 0.05, 1)
    f.leather = f:CreateTexture(nil, "BACKGROUND", nil, -6)
    f.leather:SetPoint("TOPLEFT", 3, -3)
    f.leather:SetPoint("BOTTOMRIGHT", -3, 3)
    f.leather:SetTexture(UI.MEDIA .. "leather", "REPEAT", "REPEAT")
    f.leather:SetHorizTile(true)
    f.leather:SetVertTile(true)
    -- back (unknown card)
    f.back = f:CreateTexture(nil, "BACKGROUND", nil, -5)
    f.back:SetPoint("TOPLEFT", 3, -3)
    f.back:SetPoint("BOTTOMRIGHT", -3, 3)
    f.back:SetTexture(UI.MEDIA .. "cardback")
    -- illustration: backdrop of the series, then a model or a medallion
    f.art = f:CreateTexture(nil, "ARTWORK", nil, 0)
    f.art:SetSize(ART_W, ART_H)
    f.art:SetPoint("TOP", 0, -14)
    f.art:SetTexCoord(0.18, 0.82, 0, 1)
    f.icon = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.icon:SetSize(ICON, ICON)
    f.icon:SetPoint("CENTER", f.art, "CENTER", 0, 0)
    if f.icon.SetMask then pcall(f.icon.SetMask, f.icon, "Interface\\CharacterFrame\\TempPortraitAlphaMask") end
    f.ring = f:CreateTexture(nil, "ARTWORK", nil, 3)
    f.ring:SetSize(ICON + 14, ICON + 14)
    f.ring:SetPoint("CENTER", f.icon, "CENTER")
    f.ring:SetTexture(UI.MEDIA .. "ring")
    local artRim = CreateFrame("Frame", nil, f)
    artRim:SetPoint("TOPLEFT", f.art, "TOPLEFT", -1, 1)
    artRim:SetPoint("BOTTOMRIGHT", f.art, "BOTTOMRIGHT", 1, -1)
    artRim:SetFrameLevel((f:GetFrameLevel() or 1) + 3)
    f.artRim = UI.Edges(artRim, { 0.85, 0.66, 0.3, 1 })
    -- number over the illustration (top left), copies (top right)
    local top = CreateFrame("Frame", nil, f)
    top:SetAllPoints()
    top:SetFrameLevel((f:GetFrameLevel() or 1) + 4)
    f.no = UI.Text(top, 9, UI.C.gold)
    f.no:SetPoint("TOPLEFT", f.art, "TOPLEFT", 3, -3)
    f.no:SetShadowOffset(1, -1)
    f.count = UI.Text(top, 11, UI.C.gold)
    f.count:SetPoint("TOPRIGHT", f.art, "TOPRIGHT", -3, -3)
    f.count:SetJustifyH("RIGHT")
    f.count:SetShadowOffset(1, -1)
    f.new = UI.Text(top, 10, { 0.4, 1, 0.4 }, UI.FONT_TITLE)
    f.new:SetPoint("BOTTOM", f.art, "TOP", 0, 1)
    f.new:SetShadowOffset(1, -1)
    -- name banner
    f.banner = f:CreateTexture(nil, "ARTWORK")
    f.banner:SetPoint("TOPLEFT", f.art, "BOTTOMLEFT", -2, -3)
    f.banner:SetPoint("TOPRIGHT", f.art, "BOTTOMRIGHT", 2, -3)
    f.banner:SetHeight(19)
    f.banner:SetColorTexture(0.3, 0.06, 0.04, 0.9)
    f.name = UI.Text(f, 11, { 1, 1, 1 })
    f.name:SetPoint("LEFT", f.banner, "LEFT", 3, 0)
    f.name:SetPoint("RIGHT", f.banner, "RIGHT", -3, 0)
    f.name:SetJustifyH("CENTER")
    f.name:SetJustifyV("MIDDLE")
    f.name:SetWordWrap(false)
    f.flavor = UI.Text(f, 9, { 0.88, 0.82, 0.7 })
    f.flavor:SetPoint("TOP", f.banner, "BOTTOM", 0, -4)
    f.flavor:SetWidth(CARD_W - 18)
    f.flavor:SetJustifyH("CENTER")
    f.flavor:SetMaxLines(3)
    f.flavor:SetSpacing(1)
    -- footer: series, date, rarity gem
    f.series = UI.Text(f, 8, { 0.7, 0.6, 0.45 })
    f.series:SetPoint("BOTTOMLEFT", 9, 8)
    f.series:SetWidth(62)
    f.series:SetWordWrap(false)
    f.date = UI.Text(f, 8, { 0.7, 0.6, 0.45 })
    f.date:SetPoint("BOTTOMRIGHT", -24, 8)
    f.date:SetJustifyH("RIGHT")
    f.gem = f:CreateTexture(nil, "OVERLAY")
    f.gem:SetSize(13, 13)
    f.gem:SetPoint("BOTTOMRIGHT", -7, 6)
    f.gem:SetTexture(UI.MEDIA .. "gem")
    f.unknown = UI.Title(f, 34, { 0.95, 0.78, 0.4 })
    f.unknown:SetPoint("CENTER", 0, 4)
    f.unknown:SetText("?")
    -- frame tinted by rarity
    f.frame = UI.NineSlice(f, "cardframe", 0.25, 18, "OVERLAY")
    UI.Tooltip(f, function(self)
        local card = self.card
        if not card then return nil end
        local r = Album.Rarity(card.rarity)
        local rarity = { r.label, r.color[1], r.color[2], r.color[3] }
        local ident = UI.CardNumber(card) .. (card.t and ("  ·  publiée le " .. UI.CardDate(card)) or "")
        if not self.owned then return "Carte inconnue", { "Série : " .. UI.SeriesLabel(card.series), rarity, ident } end
        local lines = { rarity, "Série : " .. UI.SeriesLabel(card.series), ident, card.flavor or "" }
        if card.orphan then lines[#lines + 1] = { "Ancienne édition : n'est plus tirée dans les boosters.", 0.6, 0.6, 0.6 } end
        return card.name, lines
    end)
    return f
end

local function tintFrame(f, c, a)
    for _, t in ipairs(f.frame) do t:SetVertexColor(c[1], c[2], c[3], a or 1) end
end

function UI.FillCard(f, card, count, faceDown)
    f.card, f.owned = card, (count or 0) > 0 and not faceDown
    f.fillToken = (f.fillToken or 0) + 1
    local r = Album.Rarity(card.rarity)
    f.gem:SetVertexColor(r.color[1], r.color[2], r.color[3])
    local face = f.owned
    for _, t in ipairs({ f.leather, f.art, f.banner, f.name, f.flavor, f.no, f.date,
        f.artRim[1], f.artRim[2], f.artRim[3], f.artRim[4] }) do
        t:SetShown(face)
    end
    f.back:SetShown(not face)
    f.unknown:Hide()   -- the card back already says "unknown"
    f.new:SetText("")
    hideModels(f)
    f.icon:Hide()
    f.ring:Hide()
    if face then
        tintFrame(f, r.color)
        f.art:SetTexture(UI.CardBackdrop(card))
        f.art:SetTexCoord(0.18, 0.82, 0, 1)
        if not showModel(f, card) then showIcon(f, card) end
        f.name:SetText(card.name)
        if card.class then f.name:SetTextColor(UI.ClassColor(card.class)) else f.name:SetTextColor(1, 1, 1) end
        f.flavor:SetText(card.flavor or "")
        f.series:SetText(UI.SeriesLabel(card.series))
        f.no:SetText(UI.CardNumber(card))
        f.date:SetText(UI.CardDate(card))
        f.count:SetText((count or 0) > 1 and ("x" .. count) or "")
        local idx = Album.RARITY_INDEX[card.rarity] or 1
        f.glow:SetShown(idx >= 4)
        f.glow:SetVertexColor(r.color[1], r.color[2], r.color[3], idx >= 5 and 0.55 or 0.3)
        f:SetAlpha(card.orphan and 0.85 or 1)
    else
        tintFrame(f, { 0.45, 0.4, 0.35 })
        f.series:SetText(UI.SeriesLabel(card.series))
        f.count:SetText("")
        f.glow:Hide()
        f:SetAlpha(faceDown and 1 or 0.8)
    end
end

function UI.SeriesLabel(key)
    for _, s in ipairs(Album.SERIES) do if s.key == key then return s.label end end
    return key
end

------------------------------------------------------------------------
-- Tweens (OnUpdate, no AnimationGroup: simplest to trust on every client)
------------------------------------------------------------------------
local function tweens(owner)
    owner.tweens = {}
    owner:SetScript("OnUpdate", function(self, elapsed)
        local list = self.tweens
        if #list == 0 then return end
        self.tweens = {}
        local keep = {}
        for _, tw in ipairs(list) do
            tw.t = tw.t + elapsed
            if tw.t < 0 then
                keep[#keep + 1] = tw   -- still waiting for its delay
            else
                local p = tw.dur > 0 and math.min(1, tw.t / tw.dur) or 1
                if tw.step then tw.step(p) end
                if p >= 1 then
                    if tw.done then tw.done() end
                else
                    keep[#keep + 1] = tw
                end
            end
        end
        for _, tw in ipairs(self.tweens) do keep[#keep + 1] = tw end   -- added by a callback
        self.tweens = keep
    end)
end

-- dur seconds, after `delay`; step(progress 0..1), then done().
local function tween(owner, dur, step, done, delay)
    table.insert(owner.tweens, { t = -(delay or 0), dur = dur, step = step, done = done })
end

local function ease(p) return 1 - (1 - p) * (1 - p) end

------------------------------------------------------------------------
-- Booster opening: the pack shakes and tears, the five cards are dealt face down, then
-- turned one by one (click) or all at once.
------------------------------------------------------------------------
local reveal
local GAP = 12
local function slotX(i) return 26 + (i - 1) * (CARD_W + GAP) end
local SLOT_Y = -64
local PACK_W, PACK_H = 110, 220

local function buildReveal()
    local r = CreateFrame("Frame", nil, UI.GetWindow())
    r:SetFrameStrata("DIALOG")
    r:SetSize(5 * (CARD_W + GAP) + 40, CARD_H + 130)
    r:SetPoint("CENTER")
    r:EnableMouse(true)
    UI.Skin(r, "window")
    tweens(r)
    r.title = UI.Title(r, 22)
    r.title:SetPoint("TOP", 0, -24)
    r.title:SetJustifyH("CENTER")
    r.hint = UI.Text(r, 11, UI.C.dim)
    r.hint:SetPoint("TOP", r.title, "BOTTOM", 0, -2)
    r.hint:SetJustifyH("CENTER")

    -- the pack: top flap and body, torn apart
    local pack = CreateFrame("Button", nil, r)
    pack:SetSize(PACK_W, PACK_H)
    pack:SetPoint("CENTER", 0, -6)
    pack:SetFrameLevel((r:GetFrameLevel() or 1) + 6)
    local cut = 0.2
    pack.top = pack:CreateTexture(nil, "ARTWORK")
    pack.top:SetTexture(UI.MEDIA .. "booster")
    pack.top:SetTexCoord(0, 1, 0, cut)
    pack.top:SetSize(PACK_W, PACK_H * cut)
    pack.body = pack:CreateTexture(nil, "ARTWORK")
    pack.body:SetTexture(UI.MEDIA .. "booster")
    pack.body:SetTexCoord(0, 1, cut, 1)
    pack.body:SetSize(PACK_W, PACK_H * (1 - cut))
    pack.burst = pack:CreateTexture(nil, "OVERLAY")
    pack.burst:SetTexture(UI.MEDIA .. "glow")
    pack.burst:SetBlendMode("ADD")
    pack.burst:SetPoint("CENTER", 0, PACK_H * (0.5 - cut))
    pack.burst:SetVertexColor(1, 0.85, 0.45)
    function pack:Place(dx, topDy, bodyDy, alpha)
        self.top:ClearAllPoints()
        self.top:SetPoint("TOP", dx, topDy)
        self.body:ClearAllPoints()
        self.body:SetPoint("BOTTOM", dx, bodyDy)
        self.top:SetAlpha(alpha); self.body:SetAlpha(alpha)
    end
    pack:SetScript("OnClick", function() if r.stage == "pack" then UI.Click(); r:Tear() end end)
    r.pack = pack

    r.cards, r.flippers, r.bursts = {}, {}, {}
    for i = 1, Album.BOOSTER_SIZE do
        local f = UI.CreateCard(r)
        f:SetFrameLevel((r:GetFrameLevel() or 1) + 2)
        f:SetScript("OnClick", function() r:Flip(i) end)
        r.cards[i] = f
        -- burst of light when the card turns, coloured by its rarity
        local b = r:CreateTexture(nil, "BACKGROUND", nil, 2)
        b:SetTexture(UI.MEDIA .. "glow")
        b:SetBlendMode("ADD")
        b:Hide()
        r.bursts[i] = b
        -- the flipping card: a flat texture narrowing then widening
        local fl = r:CreateTexture(nil, "OVERLAY")
        fl:Hide()
        r.flippers[i] = fl
    end

    r.all = UI.Button(r, "Tout retourner", 150, 24, function() r:FlipAll() end)
    r.all:SetPoint("BOTTOM", -84, 20)
    r.ok = UI.Button(r, "Ranger dans l'album", 170, 24, function() r:Hide() end)
    r.ok:SetPoint("BOTTOM", 84, 20)
    return r
end

local function place(f, x, y)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", x, y)
end

local function showReveal(cards, collection, opts)
    opts = opts or {}
    reveal = reveal or buildReveal()
    local r = reveal
    r.tweens = {}
    r.got, r.collection, r.revealed = cards, collection or {}, 0
    r.title:SetText(opts.title or "Nouveau booster !")
    r.hint:SetText(opts.preview and "Aperçu : rien n'est encore publié." or "Clique le paquet pour l'ouvrir.")
    local centerX = (r:GetWidth() - CARD_W) / 2

    function r:Done()
        self.stage = "done"
        self.all:Hide()
        self.ok:Show()
        self.hint:SetText(opts.preview and "Aperçu : rien n'est encore publié." or "Cartes rangées dans ton album.")
    end

    function r:Flip(i, instant)
        local f, card = self.cards[i], self.got[i]
        if self.stage ~= "deal" or not card or f.turned then return end
        f.turned = true
        local fl, burst = self.flippers[i], self.bursts[i]
        local rar = Album.Rarity(card.rarity)
        local idx = Album.RARITY_INDEX[card.rarity] or 1
        local function face()
            UI.FillCard(f, card, 1)
            f:Show()
            f.new:SetText(not opts.preview and self.collection[card.id] == 1 and "NOUVEAU" or "")
            fl:Hide()
            self.revealed = self.revealed + 1
            UI.Click()
            if self.revealed >= #self.got then self:Done() end
            -- burst: bigger and longer for the rarest cards
            local size, dur = CARD_W * (idx >= 4 and 2.6 or 1.8), idx >= 5 and 1.2 or (idx >= 4 and 0.9 or 0.5)
            burst:SetVertexColor(rar.color[1], rar.color[2], rar.color[3])
            burst:ClearAllPoints()
            burst:SetPoint("CENTER", f, "CENTER")
            burst:Show()
            tween(self, dur, function(p)
                local s = size * (0.6 + 0.6 * ease(p))
                burst:SetSize(s, s * 1.3)
                burst:SetAlpha((1 - p) * (idx >= 4 and 1 or 0.7))
            end, function() burst:Hide() end)
        end
        if instant then face() return end
        f:Hide()
        fl:ClearAllPoints()
        fl:SetPoint("CENTER", f, "CENTER")
        fl:SetTexture(UI.MEDIA .. "cardback")
        fl:SetVertexColor(1, 1, 1)
        fl:SetSize(CARD_W, CARD_H)
        fl:Show()
        tween(self, 0.14, function(p) fl:SetSize(math.max(1, CARD_W * (1 - p)), CARD_H) end, function()
            fl:SetColorTexture(rar.color[1] * 0.5, rar.color[2] * 0.5, rar.color[3] * 0.5, 1)
            tween(self, 0.14, function(p) fl:SetSize(math.max(1, CARD_W * p), CARD_H) end, face)
        end)
    end

    function r:FlipAll()
        if self.stage == "pack" then self:Tear() end
        if self.stage == "opening" then self.flipAll = true return end
        local n = 0
        for i = 1, #self.got do
            if not self.cards[i].turned then
                tween(self, 0, nil, function() self:Flip(i) end, n * 0.15)
                n = n + 1
            end
        end
    end

    -- Tearing: the flap flies off, the body sinks, the cards slide out face down.
    function r:Tear()
        if self.stage ~= "pack" then return end
        self.stage = "opening"
        self.hint:SetText("")
        local pack = self.pack
        pack.burst:Show()
        tween(self, 0.45, function(p)
            local e = ease(p)
            pack:Place(e * 14, 70 * e, -50 * e, 1 - p)
            local s = PACK_W * (1 + 2 * e)
            pack.burst:SetSize(s, s)
            pack.burst:SetAlpha(1 - p)
        end, function() pack:Hide() end)
        for i, f in ipairs(self.cards) do
            local card = self.got[i]
            if card then
                tween(self, 0.4, function(p)
                    local e = ease(p)
                    place(f, centerX + (slotX(i) - centerX) * e, SLOT_Y - 20 * (1 - e))
                    f:SetAlpha(e)
                end, function()
                    if i == #self.got then
                        self.stage = "deal"
                        self.hint:SetText("Clique une carte pour la retourner.")
                        self.all:Show()
                        if self.flipAll then self.flipAll = nil; self:FlipAll() end
                    end
                end, 0.25 + (i - 1) * 0.07)
            end
        end
    end

    -- Start: the pack, shaking, then torn open by itself (or by a click).
    for i, f in ipairs(r.cards) do
        f.turned = false
        r.flippers[i]:Hide()
        r.bursts[i]:Hide()
        local card = cards[i]
        if card then
            UI.FillCard(f, card, 1, true)
            place(f, centerX, SLOT_Y)
            f:SetAlpha(0)
            f:Show()
        else
            f:Hide()
        end
    end
    r.flipAll = nil
    r.all:Show()
    r.ok:Hide()
    r:Show()
    if opts.preview then
        r.pack:Hide()
        r.stage = "deal"
        for i, f in ipairs(r.cards) do
            if cards[i] then place(f, slotX(i), SLOT_Y); f:SetAlpha(1); r:Flip(i, true) end
        end
        return r
    end
    r.stage = "pack"
    r.pack:Show()
    r.pack:Place(0, 0, 0, 1)
    tween(r, 0.7, function(p)
        local amp = 4 * (1 - p * 0.4)
        r.pack:Place(math.sin(p * 46) * amp, 0, 0, 1)
    end, function() r:Tear() end)
    return r
end
UI.ShowBoosterReveal = showReveal

-- Preview of cards not published yet (Renatus_Admin): face up, nothing recorded.
function UI.CardsPreview(cards, title)
    UI.Open("album")
    local list = {}
    for i = 1, math.min(#cards, Album.BOOSTER_SIZE) do list[i] = cards[i] end
    return showReveal(list, {}, { preview = true, title = title or "Aperçu des cartes" })
end

------------------------------------------------------------------------
-- Zoom: one card, large.
------------------------------------------------------------------------
local zoom
local function showZoom(card, count)
    if not zoom then
        zoom = CreateFrame("Button", nil, UI.GetWindow())
        zoom:SetFrameStrata("DIALOG")
        zoom:SetAllPoints(UI.GetWindow())
        local shade = zoom:CreateTexture(nil, "BACKGROUND")
        shade:SetAllPoints()
        shade:SetColorTexture(0, 0, 0, 0.7)
        zoom.card = UI.CreateCard(zoom)
        zoom.card:SetScale(1.9)
        zoom.card:SetPoint("CENTER", 0, 8)
        zoom.card:SetScript("OnClick", function() zoom:Hide() end)
        zoom.hint = UI.Text(zoom, 11, UI.C.dim)
        zoom.hint:SetPoint("BOTTOM", 0, 30)
        zoom.hint:SetText("Clique pour refermer.")
        zoom:SetScript("OnClick", function() zoom:Hide() end)
    end
    UI.FillCard(zoom.card, card, count)
    zoom:Show()
    return zoom
end
UI.ShowCardZoom = showZoom

------------------------------------------------------------------------
-- Tab
------------------------------------------------------------------------
local function build(c)
    c.series = "all"
    c.page = 1
    local title = UI.Title(c, 20)
    title:SetPoint("TOPLEFT", 4, -2)
    title:SetText("Album de la Guilde")
    c.progress = UI.Text(c, 11, UI.C.dim)
    c.progress:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)

    c.booster = UI.Button(c, "Ouvrir un booster", 170, 26, function()
        local ds = ns.Store.Dataset()
        if (ds.boosters or 0) <= 0 then return end
        UI.cardProfiles = ds.profiles or {}
        local cards = Album.Catalogue(ds)
        local n = (ds.boostersOpened or 0) + 1
        local got = Album.BoosterContents(cards, ds.me .. ":booster:" .. n)
        if ds.isDemo then
            ds.boostersOpened, ds.boosters = n, ds.boosters - 1
            for _, card in ipairs(got) do ds.collection[card.id] = (ds.collection[card.id] or 0) + 1 end
        else
            local ids = {}
            for i, card in ipairs(got) do ids[i] = card.id end
            ns.Store.Add("BOOSTER_OPEN", { n = n, cards = ids, cv = cards.version }, { keep = true, noExp = true, loc = {} })
            ds = ns.Store.Dataset()
        end
        c.reveal = showReveal(got, ds.collection)
        c:Refresh()
        UI.Notifier:Refresh(ds)
    end)
    c.booster:SetPoint("TOPRIGHT", -4, -6)
    UI.Tooltip(c.booster, function()
        return "Booster", { "5 cartes. Le contenu est déterminé par l'identifiant du booster : impossible de relancer le tirage.",
            "On en gagne 1 par jour joué, +1 par niveau, boss vaincu ou sortie avec un membre de la guilde (5 par jour au plus)." }
    end)

    local seriesOpts = { { value = "all", label = "Toutes les séries" },
        { value = "family:guild", label = "— Guilde (toutes)" }, { value = "family:azeroth", label = "— Azeroth (toutes)" } }
    for _, s in ipairs(Album.SERIES) do table.insert(seriesOpts, { value = s.key, label = s.label }) end
    c.seriesDropdown = UI.Dropdown(c, 170, seriesOpts, function(v) c.series = v; c.page = 1; c:Refresh() end)
    c.seriesDropdown:SetPoint("TOPLEFT", 4, -48)
    c.seriesDropdown:SetValue("all")
    c.ownedOnly = UI.Checkbox(c, "Seulement mes cartes", function(v) c.onlyOwned = v; c.page = 1; c:Refresh() end)
    c.ownedOnly:SetPoint("LEFT", c.seriesDropdown, "RIGHT", 14, 0)

    c.prev = UI.Button(c, "<", 28, 22, function() c.page = c.page - 1; c:Refresh() end)
    c.prev:SetPoint("TOPRIGHT", -80, -48)
    c.pageText = UI.Text(c, 11, UI.C.dim)
    c.pageText:SetPoint("LEFT", c.prev, "RIGHT", 4, 0)
    c.pageText:SetWidth(40)
    c.pageText:SetJustifyH("CENTER")
    c.pageText:SetJustifyV("MIDDLE")
    c.next = UI.Button(c, ">", 28, 22, function() c.page = c.page + 1; c:Refresh() end)
    c.next:SetPoint("LEFT", c.pageText, "RIGHT", 4, 0)

    c.cards = {}
    local gapX = math.floor((UI.CONTENT_W - COLS * CARD_W) / (COLS + 1))
    for i = 1, PER_PAGE do
        local f = UI.CreateCard(c)
        local col, line = (i - 1) % COLS, math.floor((i - 1) / COLS)
        f:SetPoint("TOPLEFT", gapX + col * (CARD_W + gapX), -82 - line * (CARD_H + 10))
        f:SetScript("OnClick", function(self)
            if self.owned and self.card then UI.Click(); c.zoom = showZoom(self.card, self.copies) end
        end)
        c.cards[i] = f
    end
    c.empty = UI.Text(c, 13, UI.C.dim)
    c.empty:SetPoint("TOP", 0, -160)
    c.empty:SetWidth(520)
    c.empty:SetJustifyH("CENTER")
    c.note = UI.Text(c, 10, UI.C.dim)
    c.note:SetPoint("BOTTOMLEFT", 4, 0)

    function c:Refresh()
        local ds = ns.Store.Dataset()
        UI.cardProfiles = ds.profiles or {}
        local cards = Album.Catalogue(ds)
        local all = {}
        for _, card in ipairs(cards) do all[#all + 1] = card end
        for _, card in ipairs(Album.Orphans(ds, cards, ds.collection)) do all[#all + 1] = card end
        local family = self.series:match("^family:(.+)$")
        local function inFilter(card)
            if self.series == "all" then return true end
            if family then return (card.azeroth and "azeroth" or "guild") == family end
            return card.series == self.series
        end
        local owned, total, doubles = 0, 0, 0
        for _, card in ipairs(cards) do
            if inFilter(card) then
                total = total + 1
                local n = ds.collection[card.id] or 0
                if n > 0 then owned = owned + 1 end
                if n > 1 then doubles = doubles + n - 1 end
            end
        end
        self.progress:SetText(("%d / %d cartes  ·  %d doublon(s)"):format(owned, total, doubles))
        local nb = ds.boosters or 0
        self.booster:SetLabel("Ouvrir un booster (" .. nb .. ")")
        self.booster:SetDisabled(nb <= 0)
        self.note:SetText(cards.published and "Catalogue publié par les officiers avec la gazette. Clique une carte pour l'agrandir."
            or "Cartes de guilde calculées en attendant le premier catalogue publié. Clique une carte pour l'agrandir.")

        local visible = {}
        for _, card in ipairs(all) do
            local n = ds.collection[card.id] or 0
            if inFilter(card) and (not self.onlyOwned or n > 0) then
                table.insert(visible, card)
            end
        end
        local order = {}
        for i, sr in ipairs(Album.SERIES) do order[sr.key] = i end
        table.sort(visible, function(a, b)
            if a.series ~= b.series then return (order[a.series] or 99) < (order[b.series] or 99) end
            local na, nb2 = type(a.no) == "number" and a.no or nil, type(b.no) == "number" and b.no or nil
            if na and nb2 and na ~= nb2 then return na < nb2 end
            local ra, rb = Album.RARITY_INDEX[a.rarity], Album.RARITY_INDEX[b.rarity]
            if ra ~= rb then return ra < rb end
            return a.name < b.name
        end)
        local pages = math.max(1, math.ceil(#visible / PER_PAGE))
        self.page = math.max(1, math.min(self.page, pages))
        for i, f in ipairs(self.cards) do
            local card = visible[(self.page - 1) * PER_PAGE + i]
            if card then
                f.copies = ds.collection[card.id] or 0
                UI.FillCard(f, card, f.copies)
                f:Show()
            else
                f:Hide()
            end
        end
        self.pageText:SetText(self.page .. "/" .. pages)
        self.prev:SetDisabled(self.page <= 1)
        self.next:SetDisabled(self.page >= pages)
        self.empty:SetText(#visible == 0 and "Aucune carte à afficher.\nLe catalogue se construit à partir de l'histoire de la guilde : membres, ennemis jurés, exploits, faits divers." or "")
    end
end

UI.RegisterTab({ key = "album", group = "main", label = "Album", icon = "Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01", order = 2,
    build = build, refresh = function(c) c:Refresh() end })
