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
-- The illustration fills the card inside its frame band (ART_INSET), down to the name banner.
local ART_INSET = 4
local ART_W, ART_H = CARD_W - 2 * ART_INSET, 98
local ICON = 50
-- The card back is drawn in the card's proportions in the top of a 256 x 512 texture.
local BACK_V = 362 / 512

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
    -- an item's card: the item's own icon (Collectors/Loot.lua)
    if card.itemId then
        local api = (C_Item and C_Item.GetItemIconByID) or GetItemIcon
        local ok, icon = pcall(api, card.itemId)
        if ok and icon then return icon end
    end
    if card.icon then return card.icon end
    if not card.icons or #card.icons == 0 then return nil end
    -- keyed by the first candidate too: a correction may change the icon (Album.BaseSet)
    local key = card.id .. "|" .. card.icons[1]
    local cached = artCache[key]
    if cached then return cached end
    local chosen = ICONS .. card.icons[#card.icons]
    for _, name in ipairs(card.icons) do
        if UI.HasFile(ICONS .. name) then chosen = ICONS .. name break end
    end
    artCache[key] = chosen
    return chosen
end

-- Backdrop of the illustration, by series.
local BACKDROP = {
    est = "lieu", kalimdor = "lieu", donjons = "donjon", expeditions = "donjon",
    personnages = "guilde", heros = "guilde", members = "guilde", founders = "guilde", legends = "guilde",
    bestiaire = "bestiaire", sworn = "ennemi", une = "presse", faits = "presse", tresors = "tresor", butin = "tresor",
    mobs = "bestiaire", terreurs = "ennemi",
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
    local race = not UI.CardArt(card) and UI.RacePortrait(profile)
    local art = UI.CardArt(card) or race
    local class = card.class or (profile and profile.class)
    if race and class then
        -- a member: their race, with their class emblem in the corner
        UI.SetClassIcon(f.classBadge, class)
        f.classBadge:Show()
        f.classBadgeRing:Show()
    end
    if art then
        -- Square, in a gold frame: icons have a black background baked in, a circle shows it.
        f.icon:SetTexture(art)
        f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        f.icon:Show()
        f.iconFrame:Show()
    else
        -- class emblems are round already: a ring fitted to them
        UI.SetClassIcon(f.classIcon, card.class or (profile and profile.class))
        f.classIcon:Show()
        f.ring:Show()
    end
end

-- Zone cards: the world map of the zone fills the illustration. The map is 1002 x 668 in
-- 4 x 3 tiles of 256; scaled to the height of the art and centred (the sides are cropped).
local MAP_W, MAP_H = 1002, 668

-- Parts of the zone the player has explored, over the parchment: drawn like the world map
-- does (MapExplorationPinMixin), each overlay cut in tiles of 256 px, in map pixels.
local function showExplored(f, mapID, scale, left)
    local pool = f.map.overlays
    local used = 0
    local api = C_MapExplorationInfo and C_MapExplorationInfo.GetExploredMapTextures
    local ok, list = false, nil
    if api and mapID then ok, list = pcall(api, mapID) end
    for _, info in ipairs(ok and type(list) == "table" and list or {}) do
        local w, h, ids = info.textureWidth or 0, info.textureHeight or 0, info.fileDataIDs or {}
        local wide, tall = math.ceil(w / 256), math.ceil(h / 256)
        if not info.isShownByMouseOver and wide > 0 and tall > 0 then
            for j = 1, tall do
                local ph, fh = 256, 256
                if j == tall then
                    ph = h % 256; if ph == 0 then ph = 256 end
                    fh = 16; while fh < ph do fh = fh * 2 end
                end
                for k = 1, wide do
                    local pw, fw = 256, 256
                    if k == wide then
                        pw = w % 256; if pw == 0 then pw = 256 end
                        fw = 16; while fw < pw do fw = fw * 2 end
                    end
                    local id = ids[(j - 1) * wide + k]
                    if id then
                        used = used + 1
                        local tex = pool[used]
                        if not tex then
                            tex = f.map:CreateTexture(nil, "ARTWORK", nil, 1)
                            pool[used] = tex
                        end
                        tex:SetTexture(id)
                        tex:SetTexCoord(0, pw / fw, 0, ph / fh)
                        tex:SetSize(pw * scale, ph * scale)
                        tex:ClearAllPoints()
                        tex:SetPoint("TOPLEFT", f.map, "TOPLEFT",
                            left + ((info.offsetX or 0) + 256 * (k - 1)) * scale,
                            -((info.offsetY or 0) + 256 * (j - 1)) * scale)
                        tex:Show()
                    end
                end
            end
        end
    end
    for i = used + 1, #pool do pool[i]:Hide() end
end
local function showMap(f, card)
    local name, mapID = ns.Cards.MapOf(card)
    if not name or not f.map.clips then return false end
    local base = "Interface\\WorldMap\\" .. name .. "\\" .. name
    if not UI.HasFile(base .. "1") then return false end
    local scale = ART_H / MAP_H
    local tile = 256 * scale
    local left = (ART_W - MAP_W * scale) / 2
    for i, tex in ipairs(f.map.tiles) do
        local col, row = (i - 1) % 4, math.floor((i - 1) / 4)
        tex:SetTexture(base .. i)
        tex:SetSize(tile, tile)
        tex:ClearAllPoints()
        tex:SetPoint("TOPLEFT", f.map, "TOPLEFT", left + col * tile, -row * tile)
    end
    showExplored(f, mapID, scale, left)
    f.map:Show()
    return true
end

-- Unit token of a member the client can show as they really are (face, hair, gear): the
-- viewer, their group or raid, their target, what they hover. Nil for anyone else.
local function unitOf(guid)
    -- UI.noLiveModels: test switch, shows everyone as others see them when they are away
    if not guid or not UnitGUID or UI.noLiveModels then return nil end
    local tokens = { "player", "target", "mouseover", "focus" }
    for i = 1, 4 do tokens[#tokens + 1] = "party" .. i end
    for i = 1, 40 do tokens[#tokens + 1] = "raid" .. i end
    for _, unit in ipairs(tokens) do
        local ok, g = pcall(UnitGUID, unit)
        if ok and g == guid then return unit end
    end
    return nil
end

-- Returns true if a model is being shown (the icon waits for its check).
local function showModel(f, card)
    local profile = card.guid and UI.cardProfiles[card.guid]
    local unit = unitOf(card.guid)
    local m
    if card.npc then
        m = modelFrame(f, "creature")
        if not m or not call(m, "SetCreature", card.npc) then return false end
        call(m, "SetPortraitZoom", 0.55)
    elseif unit then
        -- the member in person: as they look right now
        m = modelFrame(f, "player")
        if not m or not call(m, "SetUnit", unit) then return false end
        call(m, "SetPortraitZoom", 0.75)
    else
        return false
    end
    m.facing = 0
    call(m, "SetFacing", 0)
    m:Show()
    -- A creature missing from the client cache leaves the model empty until the server
    -- answers: the icon stands in meanwhile, and the model is asked again a few times
    -- (an unknown creature, or an API missing on this client, keeps the icon).
    local token = f.fillToken
    local tries = 0
    local function check()
        if f.fillToken ~= token then return end
        local ok, id = call(m, "GetModelFileID")
        if ok and id and id ~= 0 then
            f.icon:Hide(); f.iconFrame:Hide(); f.classIcon:Hide(); f.ring:Hide()
            m:Show()
            return
        end
        m:Hide()
        if tries == 0 then showIcon(f, card) end
        tries = tries + 1
        if C_Timer and card.npc and tries <= 4 then
            call(m, "SetCreature", card.npc)
            C_Timer.After(1, check)
        end
    end
    if C_Timer then C_Timer.After(0.6, check) else check() end
    return true
end

------------------------------------------------------------------------
-- Force / endurance: two tabs filling the top corners of the card, flush inside its frame
-- (textures from tools/make_stat_corner.py, drawn for the left corner)
------------------------------------------------------------------------
local STAT_W, STAT_H = 32, 34
local STAT_INSET = 4   -- width of the card frame's metal band
local FORCE_COLOR = { 0.78, 0.2, 0.1 }
local ENDURANCE_COLOR = { 0.16, 0.56, 0.26 }

-- side: "LEFT" (corner top left) or "RIGHT" (corner top right, textures mirrored).
local function statBadge(parent, color, side)
    local left = side == "LEFT"
    local corner = left and "TOPLEFT" or "TOPRIGHT"
    local b = CreateFrame("Frame", nil, parent)
    b:SetSize(STAT_W, STAT_H)
    b:SetPoint(corner, parent, corner, left and STAT_INSET or -STAT_INSET, -STAT_INSET)
    local function layer(name, drawLayer)
        local t = b:CreateTexture(nil, drawLayer)
        t:SetTexture(UI.MEDIA .. name)
        if left then t:SetTexCoord(0, 1, 0, 1) else t:SetTexCoord(1, 0, 0, 1) end
        t:SetAllPoints()
        return t
    end
    layer("statfill", "ARTWORK"):SetVertexColor(color[1], color[2], color[3])
    layer("statrim", "OVERLAY")
    b.value = b:CreateFontString(nil, "OVERLAY", nil, 2)
    b.value:SetFont(UI.FONT_TITLE, 13, "OUTLINE")
    b.value:SetTextColor(1, 0.95, 0.8)
    b.value:SetShadowOffset(1, -1)
    -- centred on the straight part of the tab, inside its gold rim (EDGE and KNEE in the
    -- generator: the rim starts at 62 % of the width, less ~7 % for the gold band)
    -- (+3 px lower: the frame band covers the top of the plate)
    local dx, dy = STAT_W * 0.55 / 2, STAT_H * 0.48 / 2 + 3
    b.value:SetPoint("CENTER", b, corner, left and dx or -dx, -dy)
    b.value:SetJustifyH("CENTER")
    return b
end

local function statText(v, item) return item and ("+" .. v) or tostring(v) end

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
    f.back:SetTexCoord(0, 1, 0, BACK_V)
    -- illustration: backdrop of the series, then a model or a medallion
    f.art = f:CreateTexture(nil, "ARTWORK", nil, 0)
    f.art:SetSize(ART_W, ART_H)
    f.art:SetPoint("TOP", 0, -ART_INSET)
    f.art:SetTexCoord(0.18, 0.82, 0, 1)
    -- item icons: square, on a dark shadow, under a 2 px gold border (all in one frame)
    f.iconFrame = CreateFrame("Frame", nil, f)
    f.iconFrame:SetSize(ICON + 2, ICON + 2)
    f.iconFrame:SetPoint("CENTER", f.art, "CENTER", 0, 0)
    f.iconFrame:SetFrameLevel((f:GetFrameLevel() or 1) + 2)
    local shadow = f.iconFrame:CreateTexture(nil, "BACKGROUND")
    shadow:SetPoint("TOPLEFT", -3, 3)
    shadow:SetPoint("BOTTOMRIGHT", 3, -3)
    shadow:SetColorTexture(0, 0, 0, 0.6)
    f.icon = f.iconFrame:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(ICON, ICON)
    f.icon:SetPoint("CENTER")
    local gold = {}
    for i = 1, 4 do
        gold[i] = f.iconFrame:CreateTexture(nil, "OVERLAY")
        gold[i]:SetColorTexture(0.85, 0.66, 0.3, 1)
    end
    gold[1]:SetPoint("TOPLEFT"); gold[1]:SetPoint("TOPRIGHT"); gold[1]:SetHeight(2)
    gold[2]:SetPoint("BOTTOMLEFT"); gold[2]:SetPoint("BOTTOMRIGHT"); gold[2]:SetHeight(2)
    gold[3]:SetPoint("TOPLEFT"); gold[3]:SetPoint("BOTTOMLEFT"); gold[3]:SetWidth(2)
    gold[4]:SetPoint("TOPRIGHT"); gold[4]:SetPoint("BOTTOMRIGHT"); gold[4]:SetWidth(2)
    -- class emblem in the corner of a member's race portrait
    f.classBadge = f.iconFrame:CreateTexture(nil, "OVERLAY", nil, 2)
    f.classBadge:SetSize(24, 24)
    f.classBadge:SetPoint("CENTER", f.iconFrame, "BOTTOMRIGHT", -2, 2)
    f.classBadge:Hide()
    f.classBadgeRing = f.iconFrame:CreateTexture(nil, "OVERLAY", nil, 3)
    f.classBadgeRing:SetSize(30, 30)
    f.classBadgeRing:SetPoint("CENTER", f.classBadge, "CENTER")
    f.classBadgeRing:SetTexture(UI.MEDIA .. "ring")
    f.classBadgeRing:Hide()
    f.iconFrame:Hide()
    -- class emblems come from an atlas (tex coords per class) and are already round: no mask
    f.classIcon = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.classIcon:SetSize(ICON, ICON)
    f.classIcon:SetPoint("CENTER", f.art, "CENTER", 0, 0)
    -- zones: their world map as full art (12 tiles, clipped to the illustration)
    f.map = CreateFrame("Frame", nil, f)
    f.map:SetPoint("TOPLEFT", f.art, "TOPLEFT")
    f.map:SetPoint("BOTTOMRIGHT", f.art, "BOTTOMRIGHT")
    f.map:SetFrameLevel((f:GetFrameLevel() or 1) + 1)
    f.map.clips = f.map.SetClipsChildren and pcall(f.map.SetClipsChildren, f.map, true) or false
    f.map.tiles = {}
    for i = 1, 12 do f.map.tiles[i] = f.map:CreateTexture(nil, "ARTWORK", nil, 0) end
    f.map.overlays = {}   -- explored parts, over the tiles (showExplored)
    f.map:Hide()
    f.ring = f:CreateTexture(nil, "ARTWORK", nil, 3)
    f.ring:SetSize(ICON + 10, ICON + 10)
    f.ring:SetPoint("CENTER", f.icon, "CENTER")
    f.ring:SetTexture(UI.MEDIA .. "ring")
    local artRim = CreateFrame("Frame", nil, f)
    artRim:SetPoint("TOPLEFT", f.art, "TOPLEFT", -1, 1)
    artRim:SetPoint("BOTTOMRIGHT", f.art, "BOTTOMRIGHT", 1, -1)
    artRim:SetFrameLevel((f:GetFrameLevel() or 1) + 3)
    f.artRim = UI.Edges(artRim, { 0.85, 0.66, 0.3, 1 })
    -- number over the illustration (bottom left), copies (bottom right): the top corners
    -- hold force and endurance
    local top = CreateFrame("Frame", nil, f)
    top:SetAllPoints()
    top:SetFrameLevel((f:GetFrameLevel() or 1) + 4)
    f.no = UI.Text(top, 9, UI.C.gold)
    f.no:SetPoint("BOTTOMLEFT", f.art, "BOTTOMLEFT", 3, 3)
    f.no:SetShadowOffset(1, -1)
    f.count = UI.Text(top, 11, UI.C.gold)
    f.count:SetPoint("BOTTOMRIGHT", f.art, "BOTTOMRIGHT", -3, 3)
    f.count:SetJustifyH("RIGHT")
    f.count:SetShadowOffset(1, -1)
    f.new = UI.Text(top, 10, { 0.4, 1, 0.4 }, UI.FONT_TITLE)
    f.new:SetPoint("TOP", f.art, "TOP", 0, -4)
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
    f.date = UI.Text(f, 8, { 0.7, 0.6, 0.45 })
    f.date:SetPoint("BOTTOMRIGHT", -24, 8)
    f.date:SetJustifyH("RIGHT")
    f.series = UI.Text(f, 8, { 0.7, 0.6, 0.45 })
    f.series:SetPoint("BOTTOMLEFT", 9, 8)
    f.series:SetPoint("RIGHT", f.date, "LEFT", -4, 0)
    f.series:SetWordWrap(false)
    f.gem = f:CreateTexture(nil, "OVERLAY")
    f.gem:SetSize(13, 13)
    f.gem:SetPoint("BOTTOMRIGHT", -7, 6)
    f.gem:SetTexture(UI.MEDIA .. "gem")
    f.unknown = UI.Title(f, 34, { 0.95, 0.78, 0.4 })
    f.unknown:SetPoint("CENTER", 0, 4)
    f.unknown:SetText("?")
    -- frame tinted by rarity
    f.frame = UI.NineSlice(f, "cardframe", 0.25, 18, "OVERLAY")
    -- force (left) and endurance (right), over the frame
    f.stats = CreateFrame("Frame", nil, f)
    f.stats:SetAllPoints()
    f.stats:SetFrameLevel((f:GetFrameLevel() or 1) + 6)
    f.force = statBadge(f.stats, FORCE_COLOR, "LEFT")
    f.endurance = statBadge(f.stats, ENDURANCE_COLOR, "RIGHT")
    f.stats:Hide()
    UI.Tooltip(f, function(self)
        local card = self.card
        if not card then return nil end
        local r = Album.Rarity(card.rarity)
        local rarity = { r.label, r.color[1], r.color[2], r.color[3] }
        local ident = UI.CardNumber(card) .. (card.t and ("  ·  publiée le " .. UI.CardDate(card)) or "")
        if not self.owned then return "Carte inconnue", { "Série : " .. UI.SeriesLabel(card.series), rarity, ident } end
        local lines = { rarity, "Série : " .. UI.SeriesLabel(card.series), ident }
        local fo, en, item = Album.Stats(card)
        if fo then
            lines[#lines + 1] = item and { ("Objet : +%d force, +%d endurance à qui le porte"):format(fo, en), 1, 0.82, 0.3 }
                or { ("Force %d  ·  Endurance %d"):format(fo, en), 1, 0.82, 0.3 }
        end
        lines[#lines + 1] = card.flavor or ""
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
    f.iconFrame:Hide()
    f.classBadge:Hide()
    f.classBadgeRing:Hide()
    f.classIcon:Hide()
    f.map:Hide()
    f.ring:Hide()
    f.stats:Hide()
    if face then
        local fo, en, item = Album.Stats(card)
        if fo then
            f.force.value:SetText(statText(fo, item))
            f.endurance.value:SetText(statText(en, item))
            f.stats:Show()
        end
        tintFrame(f, r.color)
        f.art:SetTexture(UI.CardBackdrop(card))
        f.art:SetTexCoord(0.18, 0.82, 0, 1)
        if not showMap(f, card) and not showModel(f, card) then showIcon(f, card) end
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
-- A failing callback is reported but never takes the other tweens down with it: the list is
-- swapped out while it runs, so an uncaught error would freeze every animation mid-way.
local function safely(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local handler = geterrorhandler and geterrorhandler()
        if handler then pcall(handler, err) end
    end
end

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
                if tw.step then safely(tw.step, p) end
                if p >= 1 then
                    if tw.done then safely(tw.done) end
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
local SLOT_Y = -78
local PACK_W, PACK_H = 110, 220

local function buildReveal()
    local r = CreateFrame("Frame", nil, UI.GetWindow())
    r:SetFrameStrata("DIALOG")
    r:SetSize(5 * (CARD_W + GAP) + 40, CARD_H + 170)
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
    pack:SetPoint("CENTER", 0, -8)
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
    r.all:SetPoint("BOTTOM", 0, 20)
    r.ok = UI.Button(r, "Ranger dans l'album", 170, 24, function() r:Hide() end)
    r.ok:SetPoint("BOTTOM", 0, 20)   -- takes the place of "Tout retourner" once all are turned
    -- preview of more than five cards: the next ones (opts.onNext)
    r.more = UI.Button(r, "Cartes suivantes", 150, 24, function()
        r:Hide()
        if r.onNext then r.onNext() end
    end)
    r.more:SetPoint("BOTTOMRIGHT", -20, 20)
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
    r.ok:SetLabel(opts.preview and "Fermer" or "Ranger dans l'album")
    r.onNext = opts.onNext
    r.more:SetShown(opts.onNext ~= nil)
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
            -- The card must land face up and be counted even if its rendering fails.
            fl:Hide()
            self.revealed = self.revealed + 1
            f:SetAlpha(1)
            safely(UI.FillCard, f, card, 1)
            f:Show()
            f.new:SetText(not opts.preview and self.collection[card.id] == 1 and "NOUVEAU" or "")
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
        fl:SetTexCoord(0, 1, 0, BACK_V)
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

    -- Start: the pack shakes now and then until it is clicked.
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
    local function shake(delay)
        tween(r, 0.5, function(p)
            if r.stage ~= "pack" then return end
            r.pack:Place(math.sin(p * 34) * 4 * (1 - p), 0, 0, 1)
        end, function() if r.stage == "pack" then shake(1.2) end end, delay)
    end
    shake(0)
    return r
end
UI.ShowBoosterReveal = showReveal

-- Preview of cards not published yet (Renatus_Admin): face up, nothing recorded.
-- onNext: shows the "Cartes suivantes" button, called when it is clicked.
function UI.CardsPreview(cards, title, onNext)
    UI.Open("album")
    UI.cardProfiles = ns.Store.Dataset().profiles or {}   -- the members' portraits
    local list = {}
    for i = 1, math.min(#cards, Album.BOOSTER_SIZE) do list[i] = cards[i] end
    return showReveal(list, {}, { preview = true, title = title or "Aperçu des cartes", onNext = onNext })
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
