--[[
  game_tooltip – Premium Item Hover Tooltip for OTCV8
  ====================================================
  Architecture:
    Theme           – centralised colour/style table (minimal, only for data-layer colors)
    PositionHelper  – cursor offset + screen clamping
    AnimController  – hover delay, fade in/out
    CategoryMapper  – item client-id → category string
    TooltipBuilder  – item → TooltipData (pure data, no widgets)
    TooltipRenderer – TooltipData → widget tree (generic, no item knowledge)
    ItemProvider    – hooks into UIItem hover, calls builder then renderer
    Main            – init/terminate, wires everything

  Visual Design (Diablo/PoE style):
    - Dark fantasy background (~RGB 15,13,10, 95% opacity)
    - 9-slice aged-gold engraved border (border.png)
    - Header: 32x32 UIItem + bold golden name + gray category
    - Decorative dividers with flourish ornament (flourish.png)
    - Dynamic rows: stat, attribute, locked, empty, socket, rarity, warning
    - Footer: gray labels + white values
    - Diamond bullets for stat rows (diamond.png)
    - All styling in styles.otui, Lua contains only data-layer colors
]]

-- ═══════════════════════════════════════════════════════════════
-- 1.  OTB/XML loading helper
-- ═══════════════════════════════════════════════════════════════
local otbLoaded = false
local xmlLoaded = false

local function loadThingsData()
  if otbLoaded and xmlLoaded then return true end

  if not otbLoaded then
    local ok, err = pcall(g_things.loadOtb, '/things/1098/items.otb')
    local isLoaded = g_things.isOtbLoaded()
    if ok and isLoaded then
      otbLoaded = true
      print("[game_tooltip] items.otb loaded")
    else
      print("[game_tooltip] items.otb load FAILED: pcall_ok=" .. tostring(ok) .. " isOtbLoaded=" .. tostring(isLoaded))
    end
  end

  if otbLoaded and not xmlLoaded then
    local ok, err = pcall(g_things.loadXml, '/things/1098/items.xml')
    local stillLoaded = g_things.isOtbLoaded()
    if ok and stillLoaded then
      xmlLoaded = true
      print("[game_tooltip] items.xml loaded")
    else
      print("[game_tooltip] items.xml load FAILED: pcall_ok=" .. tostring(ok) .. " isOtbLoaded=" .. tostring(stillLoaded))
    end
  end

  return otbLoaded and xmlLoaded
end

-- ═══════════════════════════════════════════════════════════════
-- 2.  Theme – minimal data-layer colours + layout constants
--     All visual styling (fonts, backgrounds, borders) is in styles.otui
--     Colors use hex ARGB strings (#RRGGBBAA) for OTCV8 compat.
-- ═══════════════════════════════════════════════════════════════
local Theme = {
  -- Layout constants (must match styles.otui)
  Padding  = { left = 8, right = 8, top = 8, bottom = 8 },
  Spacing  = 2,
  MinWidth = 220,
  MaxWidth = 260,

  -- Row text colours (matching styles.otui)
  RowColor = {
    stat      = '#DCDCDCFF',  -- white
    attribute = '#DCDCDCFF',  -- white
    locked    = '#7EC8E3FF',  -- cyan/blue
    empty     = '#888888FF',  -- grey
    socket    = '#DCDCDCFF',  -- white
    rarity    = '#DCDCDCFF',  -- white
    warning   = '#DCDCDCFF',  -- white
    footer    = '#E6B92DFF',  -- gold
    separator = nil,
  },

  SuffixColor = {
    locked    = '#7EC8E3FF',
    empty     = '#888888FF',
    warning   = '#B48C3CFF',
  },
}

-- Toggle debug logging — single flag controls ALL tooltip diagnostics
-- Set to true to enable [DES], [RX], and classification debug output.
local TOOLTIP_DEBUG = false

-- ═══════════════════════════════════════════════════════════════
-- Item classification constants
-- Used by ItemClassifier and all providers.  These are the only
-- item-type identifiers the tooltip system should reference.
-- ═══════════════════════════════════════════════════════════════
local ITEM_GENERIC    = 0
local ITEM_WEAPON     = 1
local ITEM_ARMOR      = 2
local ITEM_SHIELD     = 3
local ITEM_CONTAINER  = 4
local ITEM_RUNE       = 5
local ITEM_AMMO       = 6
local ITEM_FLUID      = 7
local ITEM_FOOD       = 8
local ITEM_KEY        = 9
local ITEM_TOOL       = 10
local ITEM_DECORATION = 11
local ITEM_MISC       = 12

-- ═══════════════════════════════════════════════════════════════
-- ItemClassifier – determines item class using multi-priority
-- classification.  Returns one of the ITEM_* constants.
-- ═══════════════════════════════════════════════════════════════
local ItemClassifier = {}

-- ═══════════════════════════════════════════════════════════════
-- Name-heuristic tables (LAST resort, confidence=10)
-- ═══════════════════════════════════════════════════════════════
local CLASSIFIER_WEAPON_NAMES = { "sword", "axe", "club", "bow", "wand", "staff",
  "rod", "spear", "knife", "dagger", "blade", "hammer", "mace", "scythe",
  "cleaver", "halberd", "lance", "javelin", "throwing", "naginata", "glaive",
  "pike", "trident", "whip", "claw", "sickle", "kama", "rapier", "scimitar",
  "crusher", "maul", "flail", "crossbow" }
local CLASSIFIER_ARMOR_NAMES  = { "armor", "helmet", "legs", "boots", "coat", "robe",
  "tunic", "vest", "plate", "greaves", "gauntlets", "bracers", "mask",
  "hat", "cap", "crown", "hauberk", "cuirass", "brassard", "skirt",
  "pants", "shoes", "slippers", "sandals", "wristband" }

local function classifyByName(name)
  if not name then return nil end
  local lower = name:lower()
  for _, s in ipairs(CLASSIFIER_WEAPON_NAMES) do
    if lower:match(s .. "$") then return ITEM_WEAPON end
  end
  if lower:match("shield$") or lower:match("buckler$") then return ITEM_SHIELD end
  for _, s in ipairs(CLASSIFIER_ARMOR_NAMES) do
    if lower:match(s .. "$") then return ITEM_ARMOR end
  end
  if lower:match("key$") then return ITEM_KEY end
  if lower:match("food$") or lower:match("bread$") or lower:match("meat$") or lower:match("ham$")
    or lower:match("fish$") or lower:match("cheese$") or lower:match("cookie$") or lower:match("cake$")
    or lower:match("pizza$") then return ITEM_FOOD end
  return nil
end

-- ── Mapping tables ──

-- MarketData category → ITEM_* mapping (confidence=80)
local MD_TO_CLASS = {
  [1]  = nil,           -- Ground
  [2]  = ITEM_CONTAINER,
  [3]  = ITEM_WEAPON,
  [4]  = ITEM_AMMO,
  [5]  = ITEM_ARMOR,
  [6]  = ITEM_RUNE,
  [7]  = nil,           -- Teleport
  [8]  = nil,           -- Magic Field
  [9]  = nil,           -- Writable
  [10] = ITEM_KEY,
  [11] = ITEM_FLUID,
  [12] = ITEM_FLUID,
  [13] = nil,           -- Door
  [14] = nil,           -- Deprecated
}

-- Human-readable names for MarketData categories (debugging)
local MD_CATEGORY_NAMES = {
  [1]  = "Ground",        [2]  = "Container",
  [3]  = "Weapon",        [4]  = "Ammunition",
  [5]  = "Armor",         [6]  = "Charges",
  [7]  = "Teleport",      [8]  = "Magic Field",
  [9]  = "Writable",      [10] = "Key",
  [11] = "Splash",        [12] = "Fluid",
  [13] = "Door",          [14] = "Deprecated",
}

-- ThingType getCategory() → ITEM_* mapping (confidence=100 when >0)
local TTCAT_TO_CLASS = {
  [1]  = ITEM_ARMOR,     -- Armor
  [2]  = ITEM_ARMOR,     -- Boots
  [3]  = ITEM_CONTAINER, -- Container
  [4]  = ITEM_DECORATION,-- Decoration
  [5]  = ITEM_FOOD,      -- Food
  [6]  = ITEM_ARMOR,     -- Helmet (map to Armor)
  [7]  = ITEM_KEY,
  [8]  = ITEM_GENERIC,   -- Magic Field
  [9]  = ITEM_GENERIC,   -- Necklace
  [10] = ITEM_FLUID,     -- Flask
  [11] = ITEM_ARMOR,     -- Armor (body equipment)
  [12] = ITEM_GENERIC,   -- Reward
  [13] = ITEM_GENERIC,   -- Ring
  [14] = ITEM_RUNE,
  [15] = ITEM_GENERIC,   -- Energy
  [16] = ITEM_GENERIC,   -- Training
  [17] = ITEM_GENERIC,   -- Material
  [18] = ITEM_TOOL,      -- Tool
  [19] = ITEM_GENERIC,   -- Potion? handled by flags
  [20] = ITEM_GENERIC,   -- Special
  [21] = ITEM_GENERIC,   -- Spellbook
  [22] = ITEM_WEAPON,    -- Sword
  [23] = ITEM_WEAPON,    -- Axe
  [24] = ITEM_WEAPON,    -- Club
  [25] = ITEM_WEAPON,    -- Distance
  [26] = ITEM_WEAPON,    -- Wand
  [27] = ITEM_AMMO,
  [28] = ITEM_CONTAINER, -- Quiver (container-like)
}

-- Human-readable OTB category names (debugging)
local TTCAT_NAMES = {
  [1]="Armor", [2]="Boots", [3]="Container", [4]="Decoration",
  [5]="Food", [6]="Helmet", [7]="Key", [8]="Magic Field",
  [9]="Necklace", [10]="Flask", [11]="Body Equipment", [12]="Reward",
  [13]="Ring", [14]="Rune", [15]="Energy", [16]="Training",
  [17]="Material", [18]="Tool", [19]="Potion", [20]="Special",
  [21]="Spellbook", [22]="Sword", [23]="Axe", [24]="Club",
  [25]="Distance", [26]="Wand", [27]="Ammunition", [28]="Quiver",
}

-- Clothing slot → ITEM_* mapping (confidence=95)
-- Slot 1=head, 2=body, 3=legs, 4=feet, 5=ring, 6=necklace,
-- 7=backpack, 8=armor/clothing, 9=ring(alt)
local SLOT_TO_CLASS = {
  [1] = ITEM_ARMOR,     -- head → Helmet (Armor category)
  [2] = ITEM_ARMOR,     -- body → Armor
  [3] = ITEM_ARMOR,     -- legs → Legs
  [4] = ITEM_ARMOR,     -- feet → Boots
  [5] = ITEM_GENERIC,   -- ring → Ring (NOT Fluid!)
  [6] = ITEM_GENERIC,   -- necklace → Amulet
  [7] = ITEM_CONTAINER, -- backpack → Container
  [8] = ITEM_ARMOR,     -- cloth slot (generic armor)
  [9] = ITEM_GENERIC,   -- ring (alt) → Ring
}

local SLOT_NAMES = {
  [1] = "Head", [2] = "Body", [3] = "Legs", [4] = "Feet",
  [5] = "Ring", [6] = "Necklace", [7] = "Backpack",
  [8] = "Cloth", [9] = "Ring(alt)",
}

-- Human-readable ITEM_* constant names
local CLASS_NAMES = {
  [ITEM_GENERIC]    = "Generic",
  [ITEM_WEAPON]     = "Weapon",
  [ITEM_ARMOR]      = "Armor",
  [ITEM_SHIELD]     = "Shield",
  [ITEM_CONTAINER]  = "Container",
  [ITEM_RUNE]       = "Rune",
  [ITEM_AMMO]       = "Ammo",
  [ITEM_FLUID]      = "Fluid",
  [ITEM_FOOD]       = "Food",
  [ITEM_KEY]        = "Key",
  [ITEM_TOOL]       = "Tool",
  [ITEM_DECORATION] = "Decoration",
  [ITEM_MISC]       = "Misc",
}

-- ═══════════════════════════════════════════════════════════════
-- ItemClassifier.classify(item, thingType, ctx) → itemClass
--
-- Confidence-based classification pipeline:
--  Each source has a confidence level (100=highest, 10=lowest).
--  Sources are evaluated in descending confidence order.
--  The highest-confidence source that produces a valid result wins.
--  A low-confidence source (e.g. name heuristic=10) NEVER overrides
--  a high-confidence source (e.g. cloth slot=95).
-- ═══════════════════════════════════════════════════════════════
function ItemClassifier.classify(item, thingType, ctx)
  local name = ctx.displayName or ctx.itemName or ""
  local logLines = {}
  local function log(msg) table.insert(logLines, "[game_tooltip]   " .. msg) end
  local finalClass = ITEM_GENERIC
  local finalReason = "Fallback (no sources matched)"

  -- ═══════════════════════════════════════════════════════════════
  -- Source 1: ThingType OTB category (confidence=100)
  -- This is the official item category from items.otb.
  -- When set (>0), it is always authoritative.
  -- ═══════════════════════════════════════════════════════════════
  local ttCat = nil
  local ttCatName = "nil"
  local ttCatOK = false
  if thingType then
    local ok, cat = pcall(thingType.getCategory, thingType)
    if ok and cat then
      ttCat = cat
      ttCatOK = true
      local nameStr = TTCAT_NAMES[cat] or ("Unknown(" .. tostring(cat) .. ")")
      ttCatName = nameStr
      if cat > 0 and cat < 29 then
        local mapped = TTCAT_TO_CLASS[cat]
        if mapped then
          finalClass = mapped
          finalReason = "ThingType category=" .. nameStr .. " (confidence=100)"
          log("ACCEPT: ThingType category=" .. tostring(cat) .. " (" .. nameStr .. ") → " .. (CLASS_NAMES[mapped] or "?") .. " (confidence=100)")
        else
          log("REJECT: ThingType category=" .. tostring(cat) .. " (" .. nameStr .. ") → no mapping (mapped=nil)")
        end
      else
        log("REJECT: ThingType category=" .. tostring(cat) .. " → zero or out of range (cat=" .. tostring(cat) .. ")")
      end
    else
      log("REJECT: ThingType.getCategory() threw error or returned nil")
    end
  else
    log("SKIP: no ThingType available")
  end
  if finalReason:sub(1,6) == "ThingT" then
    if TOOLTIP_DEBUG then
      print("[game_tooltip]╔══ Classification Debug ══╗")
      for _, l in ipairs(logLines) do print(l) end
      print("[game_tooltip]  FINAL=" .. (CLASS_NAMES[finalClass] or "?") .. " (" .. tostring(finalClass) .. ")")
      print("[game_tooltip]  REASON=" .. finalReason)
      print("[game_tooltip]╚════════════════════════════╝")
    end
    return finalClass
  end

  -- ═══════════════════════════════════════════════════════════════
  -- Source 2: isContainer ThingType flag (confidence=100)
  -- Containers are unmistakable in the OTB data.
  -- ═══════════════════════════════════════════════════════════════
  if thingType then
    local ok, isC = pcall(thingType.isContainer, thingType)
    if ok and isC then
      finalClass = ITEM_CONTAINER
      finalReason = "ThingType flag isContainer=true (confidence=100)"
      log("ACCEPT: isContainer=true → Container (confidence=100)")
    else
      local status = ok and (isC and "true" or "false") or "ERROR"
      log("REJECT: isContainer=" .. tostring(status) .. " → " .. (ok and (isC and "container" or "not container") or "pcall failed"))
    end
  else
    log("SKIP: no ThingType for container check")
  end
  if finalClass ~= ITEM_GENERIC then
    if TOOLTIP_DEBUG then
      print("[game_tooltip]╔══ Classification Debug ══╗")
      for _, l in ipairs(logLines) do print(l) end
      print("[game_tooltip]  FINAL=" .. (CLASS_NAMES[finalClass] or "?") .. " (" .. tostring(finalClass) .. ")")
      print("[game_tooltip]  REASON=" .. finalReason)
      print("[game_tooltip]╚════════════════════════════╝")
    end
    return finalClass
  end

  -- ═══════════════════════════════════════════════════════════════
  -- Source 3: isFluidContainer ThingType flag (confidence=90)
  -- Actual fluid containers (vials, potions, flasks).
  -- More reliable than isSplash because it specifically means
  -- this item holds fluid.  Rings may have isSplash but NOT
  -- isFluidContainer.
  -- ═══════════════════════════════════════════════════════════════
  if thingType then
    local ok, isF = pcall(thingType.isFluidContainer, thingType)
    if ok and isF then
      finalClass = ITEM_FLUID
      finalReason = "ThingType flag isFluidContainer=true (confidence=90)"
      log("ACCEPT: isFluidContainer=true → Fluid (confidence=90)")
    else
      local status = ok and (isF and "true" or "false") or "ERROR"
      log("REJECT: isFluidContainer=" .. tostring(status))
    end
  else
    log("SKIP: no ThingType for fluid container check")
  end
  if finalClass ~= ITEM_GENERIC then
    if TOOLTIP_DEBUG then
      print("[game_tooltip]╔══ Classification Debug ══╗")
      for _, l in ipairs(logLines) do print(l) end
      print("[game_tooltip]  FINAL=" .. (CLASS_NAMES[finalClass] or "?") .. " (" .. tostring(finalClass) .. ")")
      print("[game_tooltip]  REASON=" .. finalReason)
      print("[game_tooltip]╚════════════════════════════╝")
    end
    return finalClass
  end

  -- ═══════════════════════════════════════════════════════════════
  -- Source 4: Equipment slot (cloth slot) — confidence=95
  -- This is the single most reliable classifier for wearable items.
  -- It correctly identifies rings (slot 5/9 → Generic, NOT Fluid),
  -- boots (slot 4 → Armor), headwear (slot 1 → Armor), etc.
  -- Evaluated BEFORE MarketData because the cloth slot is part of
  -- the item's fundamental OTB definition, not a trade-system hint.
  --
  -- CRITICAL: ANY valid cloth slot mapping is accepted, even if it
  -- maps to ITEM_GENERIC (e.g. rings, amulets).  The presence of a
  -- cloth slot means the item IS wearable equipment, and we must
  -- NOT allow a lower-confidence source (like MarketData's Splash
  -- category for rings) to override this.
  -- ═══════════════════════════════════════════════════════════════
  if thingType then
    local ok, slot = pcall(thingType.getClothSlot, thingType)
    if ok and slot and slot > 0 then
      local slotName = SLOT_NAMES[slot] or ("Slot" .. tostring(slot))
      local mapped = SLOT_TO_CLASS[slot]
      if mapped then
        local clsName = CLASS_NAMES[mapped] or "?"
        finalClass = mapped
        finalReason = "Equipment slot=" .. slotName .. " (confidence=95)"
        log("ACCEPT: getClothSlot=" .. tostring(slot) .. " (" .. slotName .. ") → " .. clsName .. " (confidence=95)")
        -- Return immediately for ANY valid cloth slot, even Generic.
        -- Rings (slot 5) map to ITEM_GENERIC — this is the CORRECT
        -- classification (a ring is not Fluid), and must not be
        -- overridden by MarketData's misleading Splash category.
        if TOOLTIP_DEBUG then
          print("[game_tooltip]╔══ Classification Debug ══╗")
          for _, l in ipairs(logLines) do print(l) end
          print("[game_tooltip]  FINAL=" .. (CLASS_NAMES[finalClass] or "?") .. " (" .. tostring(finalClass) .. ")")
          print("[game_tooltip]  REASON=" .. finalReason)
          print("[game_tooltip]╚════════════════════════════╝")
        end
        return finalClass
      else
        log("REJECT: getClothSlot=" .. tostring(slot) .. " (" .. slotName .. ") → no mapping (should not happen)")
      end
    elseif ok and slot then
      log("REJECT: getClothSlot=" .. tostring(slot) .. " → zero (not wearable)")
    else
      log("REJECT: getClothSlot() threw error or returned nil")
    end
  else
    log("SKIP: no ThingType for cloth slot check")
  end

  -- ═══════════════════════════════════════════════════════════════
  -- Source 5: Description-based stats (confidence=85)
  -- Server-sent description text is parsed for known patterns.
  -- Atk/Hit/Range → Weapon; Def only → Shield; Armor/Protection → Armor.
  -- These are trustworthy when present because they come from
  -- the game server's item definitions.
  -- ═══════════════════════════════════════════════════════════════
  local hasDescStats = ctx.statsRows and #ctx.statsRows > 0
  if hasDescStats then
    local hasWeaponStat = false
    local hasAttack = false
    local hasDefenseOnly = false
    local hasArmorStat = false
    for _, r in ipairs(ctx.statsRows) do
      if r.text:match("^Atk") then hasAttack = true; hasWeaponStat = true end
      if r.text:match("^Hit Chance") or r.text:match("^Range") then hasWeaponStat = true end
      if r.text:match("^Def") then hasDefenseOnly = true end
      if r.text:match("Armor$") or r.text:match("^Protection") then hasArmorStat = true end
    end

    if hasWeaponStat then
      finalClass = ITEM_WEAPON
      finalReason = "Description stats contain weapon stats (Atk/Hit/Range) (confidence=85)"
      log("ACCEPT: description has weapon stats → Weapon (confidence=85)")
    elseif hasDefenseOnly and not hasAttack then
      finalClass = ITEM_SHIELD
      finalReason = "Description stats contain Def without Atk (confidence=85)"
      log("ACCEPT: description has Def-only → Shield (confidence=85)")
    elseif hasArmorStat then
      finalClass = ITEM_ARMOR
      finalReason = "Description stats contain Armor/Protection (confidence=85)"
      log("ACCEPT: description has Armor/Protection → Armor (confidence=85)")
    else
      local details = {}
      for _, r in ipairs(ctx.statsRows) do table.insert(details, r.text) end
      log("REJECT: description rows=[" .. table.concat(details, ", ") .. "] → no recognized pattern")
    end
  else
    log("SKIP: no description stats (empty or missing)")
  end
  if finalClass ~= ITEM_GENERIC then
    if TOOLTIP_DEBUG then
      print("[game_tooltip]╔══ Classification Debug ══╗")
      for _, l in ipairs(logLines) do print(l) end
      print("[game_tooltip]  FINAL=" .. (CLASS_NAMES[finalClass] or "?") .. " (" .. tostring(finalClass) .. ")")
      print("[game_tooltip]  REASON=" .. finalReason)
      print("[game_tooltip]╚════════════════════════════╝")
    end
    return finalClass
  end

  -- ═══════════════════════════════════════════════════════════════
  -- Source 6: MarketData category (confidence=80)
  -- From the in-game Market system.  Useful for tradeable items
  -- that also appear in the Market.  However, MarketData can be
  -- misleading (e.g. rings may be category 11 "Splash" or
  -- boots may be category 3 "Weapon" in poorly configured data).
  -- Always evaluated AFTER cloth slot to prevent rings/boots
  -- from being misclassified by a misleading MarketData category.
  -- ═══════════════════════════════════════════════════════════════
  if ctx.marketData and ctx.marketData.category then
    local mdCat = ctx.marketData.category
    local mdName = MD_CATEGORY_NAMES[mdCat] or ("Unknown(" .. tostring(mdCat) .. ")")
    local mapped = MD_TO_CLASS[mdCat]
    if mapped then
      local clsName = CLASS_NAMES[mapped] or "?"
      -- Extra guard: if MarketData says Fluid but we already ruled
      -- out isFluidContainer, isSplash, and ring slot, still trust it.
      -- If it says Weapon but we have no weapon name clue, trust it.
      finalClass = mapped
      finalReason = "MarketData category=" .. mdName .. " (confidence=80)"
      log("ACCEPT: MarketData category=" .. tostring(mdCat) .. " (" .. mdName .. ") → " .. clsName .. " (confidence=80)")
    else
      log("REJECT: MarketData category=" .. tostring(mdCat) .. " (" .. mdName .. ") → no mapping")
    end
  else
    log("SKIP: no MarketData or no category")
  end
  if finalClass ~= ITEM_GENERIC then
    if TOOLTIP_DEBUG then
      print("[game_tooltip]╔══ Classification Debug ══╗")
      for _, l in ipairs(logLines) do print(l) end
      print("[game_tooltip]  FINAL=" .. (CLASS_NAMES[finalClass] or "?") .. " (" .. tostring(finalClass) .. ")")
      print("[game_tooltip]  REASON=" .. finalReason)
      print("[game_tooltip]╚════════════════════════════╝")
    end
    return finalClass
  end

  -- ═══════════════════════════════════════════════════════════════
  -- Source 7: isSplash flag (confidence=50)
  -- Low confidence because rings and usable items often have
  -- isSplash=true in OTB data even though they are not fluids.
  -- By this point, cloth slot has already ruled out ring/necklace
  -- slots, so this is safer.  Only triggers for genuine splashes.
  -- ═══════════════════════════════════════════════════════════════
  if thingType then
    local ok, isS = pcall(thingType.isSplash, thingType)
    if ok and isS then
      finalClass = ITEM_FLUID
      finalReason = "ThingType flag isSplash=true (confidence=50)"
      log("ACCEPT: isSplash=true → Fluid (confidence=50)")
    else
      local status = ok and (isS and "true" or "false") or "ERROR"
      log("REJECT: isSplash=" .. tostring(status))
    end
  else
    log("SKIP: no ThingType for splash check")
  end
  if finalClass ~= ITEM_GENERIC then
    if TOOLTIP_DEBUG then
      print("[game_tooltip]╔══ Classification Debug ══╗")
      for _, l in ipairs(logLines) do print(l) end
      print("[game_tooltip]  FINAL=" .. (CLASS_NAMES[finalClass] or "?") .. " (" .. tostring(finalClass) .. ")")
      print("[game_tooltip]  REASON=" .. finalReason)
      print("[game_tooltip]╚════════════════════════════╝")
    end
    return finalClass
  end

  -- ═══════════════════════════════════════════════════════════════
  -- Source 8: Remaining ThingType flags (confidence=40)
  -- isStackable+isUsable → Rune.  isStackable → consider Ammo.
  -- ═══════════════════════════════════════════════════════════════
  if thingType then
    local okSt, isSt = pcall(thingType.isStackable, thingType)
    local okUs, isUs = pcall(thingType.isUsable, thingType)
    if okSt and isSt and okUs and isUs then
      finalClass = ITEM_RUNE
      finalReason = "ThingType flags isStackable+isUsable → Rune (confidence=40)"
      log("ACCEPT: isStackable=true + isUsable=true → Rune (confidence=40)")
    elseif okSt and isSt then
      log("HINT: isStackable=true, isUsable=" .. tostring(isUs) .. " — not a rune")
    end

    if finalClass == ITEM_GENERIC and okSt and isSt then
      -- Check MarketData for ammo hint
      if ctx.marketData and ctx.marketData.category == 4 then
        finalClass = ITEM_AMMO
        finalReason = "ThingType flag isStackable + MarketData category=Ammunition (confidence=40)"
        log("ACCEPT: isStackable + MarketData category=4 (Ammunition) → Ammo (confidence=40)")
      end
    end
  else
    log("SKIP: no ThingType for stackable/usable check")
  end

  if finalClass == ITEM_GENERIC then
    -- ═══════════════════════════════════════════════════════════════
    -- Source 9: Name heuristics (confidence=10)
    -- Absolute LAST resort.  Only used when every other source
    -- has been exhausted.  Matches common English item suffixes.
    -- ═══════════════════════════════════════════════════════════════
    local byName = classifyByName(name)
    if byName then
      finalClass = byName
      finalReason = "Name heuristic matched \"" .. name .. "\" (confidence=10)"
      log("ACCEPT: name=\"" .. name .. "\" matched → " .. (CLASS_NAMES[byName] or "?") .. " (confidence=10)")
    else
      log("REJECT: name=\"" .. name .. "\" → no suffix match")
    end
  end

  -- ═══════════════════════════════════════════════════════════════
  -- Final fallback
  -- ═══════════════════════════════════════════════════════════════
  if finalClass == ITEM_GENERIC then
    log("FALLBACK: no source matched → Generic (0)")
  end

  -- ═══════════════════════════════════════════════════════════════
  -- Print debug output
  -- ═══════════════════════════════════════════════════════════════
  if TOOLTIP_DEBUG then
    print("[game_tooltip]╔══ Classification Debug ══╗")
    for _, l in ipairs(logLines) do print(l) end
    print("[game_tooltip]  FINAL=" .. (CLASS_NAMES[finalClass] or "?") .. " (" .. tostring(finalClass) .. ")")
    print("[game_tooltip]  REASON=" .. finalReason)
    print("[game_tooltip]╚════════════════════════════╝")
  end

  return finalClass
end

-- ═══════════════════════════════════════════════════════════════
-- 3.  CategoryMapper – item client-id → human-readable category
-- ═══════════════════════════════════════════════════════════════
local CategoryNames = {
  [1]  = "Armor",
  [2]  = "Boots",
  [3]  = "Container",
  [4]  = "Decoration",
  [5]  = "Food",
  [6]  = "Helmet",
  [7]  = "Legs",
  [8]  = "Other",
  [9]  = "Potion",
  [10] = "Ring",
  [11]  = "Rune",
  [12] = "Shield",
  [13] = "Tool",
  [14] = "Valuables",
  [15] = "Ammunition",
  [16] = "Axe",
  [17] = "Club",
  [18] = "Distance Weapon",
  [19] = "Sword",
  [20] = "Wand",
  [21] = "Body Equipment",
  [22] = "Finger Equipment",
  [23] = "Necklace Equipment",
  [24] = "Head Equipment",
  [25] = "Legs Equipment",
  [26] = "Feet Equipment",
  [27] = "Shield Equipment",
  [28] = "Quiver",
}

local function getCategory(item)
  local itemId = item:getId()
  if itemId == 0 then return nil end

  local thingType = g_things.getThingType(itemId, ThingCategoryItem)
  if not thingType then return nil end

  local cat = thingType:getCategory()
  if cat and cat > 0 and cat < 29 then
    return CategoryNames[cat]
  end

  -- Fallback 1: ThingType boolean flags → known categories
  if thingType:isContainer()    then return "Container" end
  if thingType:isSplash()       then return "Splash" end
  if thingType:isFluidContainer() then return "Potion" end

  -- Fallback 2: MarketData category (if available)
  local okMD, md = pcall(thingType.getMarketData, thingType)
  if okMD and md and md.category and md.category > 0 then
    -- MarketData.category uses the same ItemCategory enum (1-15)
    local marketCatNames = {
      [1] = "Ground", [2] = "Container", [3] = "Weapon",
      [4] = "Ammunition", [5] = "Armor", [6] = "Charges",
      [7] = "Teleport", [8] = "Magic Field", [9] = "Writable",
      [10] = "Key", [11] = "Splash", [12] = "Fluid",
      [13] = "Door", [14] = "Deprecated",
    }
    return marketCatNames[md.category]
  end

  -- Fallback 3: try g_things.findItemTypeByClientId for server-ID ranges
  local ok, itemType = pcall(g_things.findItemTypeByClientId, itemId)
  if ok and itemType then
    local ok2, sid = pcall(itemType.getServerId, itemType)
    if ok2 and sid and sid > 0 then
      if sid > 2400 and sid < 2800 then
        if sid < 2500 then return "Sword" end
        if sid < 2600 then return "Axe" end
        if sid < 2700 then return "Club" end
        return "Distance Weapon"
      end
      if sid > 2800 and sid < 3200 then return "Armor" end
      if sid > 3200 and sid < 3400 then return "Helmet" end
      if sid > 3400 and sid < 3600 then return "Legs" end
      if sid > 3600 and sid < 3800 then return "Boots" end
      if sid > 3800 and sid < 4000 then return "Shield" end
      if sid > 4000 and sid < 4200 then return "Ring" end
      if sid > 4200 and sid < 4400 then return "Necklace" end
    end
  end

  return nil
end

-- ═══════════════════════════════════════════════════════════════
-- 4.  PositionHelper – cursor offset + screen clamping
-- ═══════════════════════════════════════════════════════════════
local PositionHelper = {}

function PositionHelper.new()
  local self = {
    _offsetX = 18,
    _offsetY = 18,
  }
  setmetatable(self, { __index = PositionHelper })
  return self
end

function PositionHelper:getPosition(panelSize, mousePos)
  local winSize = g_window.getSize()
  local x = mousePos.x + self._offsetX
  local y = mousePos.y + self._offsetY

  if x + panelSize.width > winSize.width then
    x = mousePos.x - panelSize.width - 4
  end
  if y + panelSize.height > winSize.height then
    y = mousePos.y - panelSize.height - 4
  end
  if x < 2 then x = 2 end
  if y < 2 then y = 2 end

  return { x = x, y = y }
end

-- ═══════════════════════════════════════════════════════════════
-- 5.  AnimController – hover delay, fade in/out
-- ═══════════════════════════════════════════════════════════════
local AnimController = {}

function AnimController.new()
  local self = {
    _delayMs      = 150,
    _fadeInMs     = 120,
    _fadeOutMs    = 80,
    _timerEvent   = nil,
    _visible      = false,
    _currentPanel = nil,
    _currentItem  = nil,
    _onShow       = nil,
    _onHide       = nil,
  }
  setmetatable(self, { __index = AnimController })
  return self
end

function AnimController:configure(opts)
  if opts.delayMs   then self._delayMs   = opts.delayMs   end
  if opts.fadeInMs  then self._fadeInMs  = opts.fadeInMs  end
  if opts.fadeOutMs then self._fadeOutMs = opts.fadeOutMs end
  if opts.onShow    then self._onShow    = opts.onShow    end
  if opts.onHide    then self._onHide    = opts.onHide    end
end

function AnimController:requestShow(item, pos)
  self:cancel()

  local selfRef = self
  local itemRef = item
  local posRef  = pos

  self._timerEvent = addEvent(function()
    selfRef._timerEvent = nil
    selfRef._visible = true
    selfRef._currentItem = itemRef
    if selfRef._onShow then
      selfRef._onShow(itemRef, posRef)
    end
  end, self._delayMs)
end

function AnimController:requestHide()
  self:cancel()
  if self._visible then
    self._visible = false
    self._currentItem = nil
    if self._onHide then
      self._onHide()
    end
  end
end

function AnimController:cancel()
  if self._timerEvent then
    removeEvent(self._timerEvent)
    self._timerEvent = nil
  end
end

function AnimController:isVisible()
  return self._visible
end

function AnimController:getCurrentItem()
  return self._currentItem
end

-- ═══════════════════════════════════════════════════════════════
-- 6.  TooltipRenderer – TooltipData → widget tree
--     Uses OTUI layout containers (VerticalLayout / HorizontalLayout)
-- ═══════════════════════════════════════════════════════════════

local ROW_STYLES = {
  stat      = { textStyle = "TooltipStatText" },
  attribute = { textStyle = "TooltipStatText" },
  locked    = { textStyle = "TooltipLockedText" },
  empty     = { textStyle = "TooltipEmptyText" },
  socket    = { textStyle = "TooltipStatText" },
  rarity    = { textStyle = "TooltipStatText" },
  warning   = { textStyle = "TooltipStatText" },
  footer    = { textStyle = "TooltipFooterLabel" },
  value     = { textStyle = "TooltipFooterValue" },
}

local MIN_W = 180
local MAX_W = 320
local PAD = 10      -- matches styles.otui padding: 10
local BULLET_W = 8  -- TooltipDiamondBullet width
local BULLET_GAP = 4 -- spacing between bullet and label

-- Approximate pixel width per character for the fonts used.
-- Used to estimate panel width before widget creation.
local FONT_WIDTHS = {
  ["TooltipHeaderName"] = 6.8,   -- verdana-11px-monochrome
  ["TooltipCategory"]   = 5.5,   -- verdana-9px
  ["TooltipStatText"]   = 5.5,   -- verdana-9px
  ["TooltipLockedText"] = 5.5,
  ["TooltipEmptyText"]  = 5.5,
  ["TooltipFooterLabel"]= 5.5,
  ["TooltipFooterValue"]= 5.5,
}

local TooltipRenderer = {}

function TooltipRenderer.new()
  local self = {
    _panel     = nil,
    _all       = {},  -- all dynamic widgets for cleanup
    _curW      = MIN_W,
    _built     = false,
    _dividers  = {},  -- divider widgets created in this build
    -- Tracking for row-level verification (reset each rebuild)
    _stats     = nil, -- table: { expected = N, rendered = N, rows = { {sec, row, widget}, ... } }
  }
  setmetatable(self, { __index = TooltipRenderer })
  return self
end

function TooltipRenderer:_buildPanel()
  if self._panel and not self._panel:isDestroyed() then return end
  -- Panel was destroyed or nil, create a fresh one
  if self._panel and self._panel:isDestroyed() then
    self._panel = nil
  end
  self._panel = g_ui.createWidget('TooltipPanel', rootWidget)
  self._panel:setId('gameTooltip')
  self._panel:setPhantom(true)
  self._panel:hide()
  self._panel:setFocusable(false)
end

-- Destroy all dynamically created widgets
function TooltipRenderer:_clearAll()
  for _, w in ipairs(self._all) do
    if w and w:isDestroyed() == false then w:destroy() end
  end
  self._all = {}
  self._dividers = {}
end

-- Estimate the pixel width of a piece of text for a given style name.
-- Uses the approximate FONT_WIDTHS table; falls back to 5.5px/char.
local function estimateTextWidth(styleName, text)
  if not text or text == "" then return 0 end
  local cw = FONT_WIDTHS[styleName] or 5.5
  return #text * cw
end

-- Scan all rows in data and compute the narrowest panel width that fits all text
-- without wrapping (if ≤ MAX_W) or MAX_W if text must wrap.
local function computeOptimalWidth(data)
  local maxTextW = 0

  -- Header width: icon (32px) + hLayout spacing (6px) + widest text line
  if data.header then
    local hdrW = 0
    if data.header.name then
      hdrW = math.max(hdrW, estimateTextWidth("TooltipHeaderName", data.header.name))
    end
    if data.header.category then
      hdrW = math.max(hdrW, estimateTextWidth("TooltipCategory", data.header.category))
    end
    if hdrW > 0 then
      hdrW = hdrW + 32 + 6  -- icon width + UIHorizontalLayout spacing
    end
    if hdrW > maxTextW then maxTextW = hdrW end
  end

  -- Section rows
  for _, sec in ipairs(data.sections or {}) do
    for _, row in ipairs(sec.rows or {}) do
      local styleName = ROW_STYLES[row.type] and ROW_STYLES[row.type].textStyle or "TooltipStatText"
      local text = row.text or ""
      if row.suffix then text = text .. " [" .. row.suffix .. "]" end
      local w = estimateTextWidth(styleName, text)
      -- Add room for diamond bullet + gap if present
      if row.icon == "diamond" then w = w + BULLET_W + BULLET_GAP end
      if w > maxTextW then maxTextW = w end
    end
  end

  -- Footer rows
  for _, row in ipairs(data.footer or {}) do
    local labelW = row.label and estimateTextWidth("TooltipFooterLabel", row.label .. ":") or 0
    local valW = row.value and estimateTextWidth("TooltipFooterValue", row.value) or 0
    local w = labelW + 20 + valW  -- 20px for spacing
    if w > maxTextW then maxTextW = w end
  end

  -- Convert text width to panel width (text area = panel width - 2*padding)
  local panelW = maxTextW + PAD * 2 + 4
  if panelW < MIN_W then panelW = MIN_W end
  if panelW > MAX_W then panelW = MAX_W end
  return panelW
end

-- Helper: compute the maximum child height for a row widget and set the row's height.
-- UIHorizontalLayout does NOT resize the parent widget, so all rows would have height=0
-- without this explicit computation.
local function setRowHeightFromChildren(widget)
  local maxH = 0
  local children = widget:getChildren()
  if children then
    for _, child in ipairs(children) do
      if child and not child:isDestroyed() then
        local sz = child:getSize()
        if sz and sz.height and sz.height > maxH then
          maxH = sz.height
        end
      end
    end
  end
  -- Minimum row height to avoid zero-height rows even if no children have height
  if maxH < 8 then maxH = 8 end
  local curSize = widget:getSize() or { width = 0, height = 0 }
  widget:setSize({ width = curSize.width, height = maxH })
end

-- Helper: compute the total height of a container's children, including spacing.
-- Used instead of getChildrenRect() because layouts haven't been applied yet
-- at rebuild time. Returns the sum of child heights + spacing between them.
local function computeContainerHeight(widget, spacing)
  local total = 0
  local count = 0
  local children = widget:getChildren()
  if children then
    for _, child in ipairs(children) do
      if child and not child:isDestroyed() then
        local sz = child:getSize()
        if sz and sz.height then
          -- Include the child's actual rendered height
          local h = sz.height
          -- Add child's vertical margins (margins contribute to visual spacing
          -- but are not reflected in the widget's own size)
          local mt = child:getMarginTop() or 0
          local mb = child:getMarginBottom() or 0
          h = h + mt + mb
          total = total + h
          count = count + 1
        end
      end
    end
  end
  -- Add spacing between pairs of children
  if count > 1 then
    total = total + (count - 1) * (spacing or 3)
  end
  return total
end

-- Create a decorative divider: [gold line] [ornament] [gold line]
-- The line widths are set after the panel width is known (in _finalizeDividers).
function TooltipRenderer:_createDivider(parent)
  local row = g_ui.createWidget('UIWidget', parent)
  row:setMargin(6, 0, 6, 0)
  table.insert(self._all, row)
  table.insert(self._dividers, row)

  local hLayout = UIHorizontalLayout.create(row)
  row:setLayout(hLayout)

  local leftLine = g_ui.createWidget('UIWidget', row)
  leftLine:setBackgroundColor('#A57D23FF')
  leftLine:setSize({width = 1, height = 1})
  leftLine:setMargin(0, 0, 4, 0)
  leftLine:setFocusable(false)
  table.insert(self._all, leftLine)

  local ornament = g_ui.createWidget('UIWidget', row)
  ornament:setSize({width = 24, height = 8})
  ornament:setImageSource('/modules/game_tooltip/images/flourish.png')
  ornament:setFocusable(false)
  table.insert(self._all, ornament)

  local rightLine = g_ui.createWidget('UIWidget', row)
  rightLine:setBackgroundColor('#A57D23FF')
  rightLine:setSize({width = 1, height = 1})
  rightLine:setMargin(4, 0, 0, 0)
  rightLine:setFocusable(false)
  table.insert(self._all, rightLine)

  setRowHeightFromChildren(row)

  return row
end

-- After the panel width is known, stretch divider lines to fill the available space.
function TooltipRenderer:_finalizeDividers()
  local lineW = math.floor((self._curW - PAD * 2 - 24 - 8) / 2)
  if lineW < 10 then lineW = 10 end
  for _, div in ipairs(self._dividers) do
    if div and not div:isDestroyed() then
      local ch = div:getChildren()
      if ch and ch[1] and not ch[1]:isDestroyed() then ch[1]:setSize({width = lineW, height = 1}) end
      if ch and ch[3] and not ch[3]:isDestroyed() then ch[3]:setSize({width = lineW, height = 1}) end
    end
  end
end

-- Build a single stat/attribute/description row with a diamond bullet.
-- Returns the created row widget (already added to self._all).
function TooltipRenderer:_buildStatRow(parent, rowData)
  local styleName = ROW_STYLES[rowData.type] and ROW_STYLES[rowData.type].textStyle or "TooltipStatText"
  local text = rowData.text or ""
  if rowData.suffix then
    text = text .. " [" .. rowData.suffix .. "]"
  end
  -- [STAGE BUILDROW] confirm row reaches widget creation
  print("[STAGE BUILDROW] type='" .. tostring(rowData.type) .. "' icon='" .. tostring(rowData.icon)
        .. "' label='" .. tostring(rowData.label) .. "' value='" .. tostring(rowData.value)
        .. "' text='" .. tostring(text) .. "' color=" .. tostring(rowData.color))

  local statRow = g_ui.createWidget('UIWidget', parent)
  table.insert(self._all, statRow)
  local rLayout = UIHorizontalLayout.create(statRow)
  statRow:setLayout(rLayout)
  rLayout:setSpacing(BULLET_GAP)

  if rowData.icon == "diamond" then
    local bullet = g_ui.createWidget('TooltipDiamondBullet', statRow)
    bullet:setFocusable(false)
    bullet:setMargin(0, 3, 0, 0)  -- slight vertical offset to align with text
    table.insert(self._all, bullet)
  end
  local label = g_ui.createWidget(styleName, statRow)
  label:setText(text)
  label:setFocusable(false)
  table.insert(self._all, label)

  setRowHeightFromChildren(statRow)

  return statRow
end

-- Build a footer row with label + value.
function TooltipRenderer:_buildFooterRow(parent, rowData)
  local footerRow = g_ui.createWidget('UIWidget', parent)
  table.insert(self._all, footerRow)
  local frLayout = UIHorizontalLayout.create(footerRow)
  footerRow:setLayout(frLayout)
  frLayout:setSpacing(8)

  if rowData.label then
    local lbl = g_ui.createWidget("TooltipFooterLabel", footerRow)
    lbl:setText(rowData.label .. ":")
    lbl:setFocusable(false)
    table.insert(self._all, lbl)
  end
  if rowData.value then
    local val = g_ui.createWidget("TooltipFooterValue", footerRow)
    val:setText(rowData.value)
    val:setFocusable(false)
    table.insert(self._all, val)
  end

  setRowHeightFromChildren(footerRow)

  return footerRow
end

function TooltipRenderer:rebuild(data)
  -- Throttle: prevent more than one rebuild per 50ms to avoid rapid cascade
  local now = g_clock.millis()
  if self._lastRebuild and (now - self._lastRebuild) < 50 then
    return
  end
  self._lastRebuild = now

  -- Auto-detect and flatten new-format TooltipData (header/body/footer/style)
  -- for backward compatibility with the old format (header/sections/footer).
  if data and data.body and not data.sections then
    data = flattenTooltipData(data)
  end

  self:_buildPanel()
  self:_clearAll()

  -- Reset tracking stats for this rebuild (DEBUG only)
  if TOOLTIP_DEBUG then
    self._stats = {
      expected   = 0,   -- total rows in data sections + footer
      rendered   = 0,   -- rows for which a widget was created
      visible    = 0,   -- rows whose widget is visible (shown, positive size)
      skipped    = 0,   -- rows deliberately skipped
      sectionLog = {},  -- per-section log: { name, rows, rendered, skipped }
      rowLog     = {},  -- per-row log: { secIdx, rowIdx, type, text, widget, ok }
      issues     = {},  -- any problems discovered
    }
  end

  -- Count expected rows from TooltipData (all sections + footer)
  if TOOLTIP_DEBUG then
    local allSectionRows = 0
    for _, sec in ipairs(data.sections or {}) do
      allSectionRows = allSectionRows + #(sec.rows or {})
    end
    self._stats.expected = allSectionRows + #(data.footer or {})
  end

  if TOOLTIP_DEBUG then
    print("[game_tooltip]╔══ RENDERER: rebuild() ══╗")
    print("[game_tooltip]║  sections in data: " .. tostring(#(data.sections or {})))
    print("[game_tooltip]║  expected rows: " .. tostring(self._stats.expected))
  end

  -- ═══════════════════════════════════════════════════════════════
  -- 1. Compute optimal panel width from text content
  -- ═══════════════════════════════════════════════════════════════
  self._curW = computeOptimalWidth(data)

  -- Set up fresh root layout at computed width
  -- _clearAll() already destroyed all child widgets, no need for destroyChildren()
  self._panel:setSize({width = self._curW, height = 1})

  local rootLayout = UIVerticalLayout.create(self._panel)
  self._panel:setLayout(rootLayout)
  rootLayout:setSpacing(3)

  -- ═══════════════════════════════════════════════════════════════
  -- 2. Header Row: [UIItem 32x32] + [Name + Category]
  --    Icon is top-aligned via margin
  -- ═══════════════════════════════════════════════════════════════
  if data.header then
    local headerRow = g_ui.createWidget('UIWidget', self._panel)
    table.insert(self._all, headerRow)
    local hLayout = UIHorizontalLayout.create(headerRow)
    headerRow:setLayout(hLayout)
    hLayout:setSpacing(6)

    local icon = g_ui.createWidget('TooltipHeaderIcon', headerRow)
    icon:setFocusable(false)
    table.insert(self._all, icon)

    local headerText = g_ui.createWidget('UIWidget', headerRow)
    table.insert(self._all, headerText)
    -- Give the text container explicit remaining width so children aren't clipped
    local textW = self._curW - PAD * 2 - 32 - 6
    if textW < 50 then textW = 50 end
    headerText:setSize({width = textW, height = 1})
    local vLayout = UIVerticalLayout.create(headerText)
    headerText:setLayout(vLayout)
    vLayout:setSpacing(1)

    if data.header.icon then
      icon:setItem(data.header.icon)
      icon:setSize({width = 32, height = 32})
      icon:setShowTimer(false)  -- prevent inventory timer overlay from leaking into tooltip
    end
    if data.header.name then
      local name = g_ui.createWidget('TooltipHeaderName', headerText)
      name:setText(data.header.name)
      name:setFocusable(false)
      table.insert(self._all, name)
    end
    if data.header.category then
      local cat = g_ui.createWidget('TooltipCategory', headerText)
      cat:setText(data.header.category)
      cat:setFocusable(false)
      table.insert(self._all, cat)
    end

    setRowHeightFromChildren(headerRow)
  end

  -- ═══════════════════════════════════════════════════════════════
  -- 3. Populated sections with dividers between them
  --    Only render dividers between non-empty sections.
  --    No consecutive dividers, no divider after footer.
  -- ═══════════════════════════════════════════════════════════════

  local populatedSections = {}
  for _psi, sec in ipairs(data.sections or {}) do
    local _rows = sec.rows or {}
    local _kept = #_rows > 0
    if _kept then
      table.insert(populatedSections, sec)
    end
  end

  local needsDivider = false
  local sectionIndex = 0  -- index among populated sections only

  for _, sec in ipairs(populatedSections) do
    sectionIndex = sectionIndex + 1

    -- Insert divider before this section if needed
    if needsDivider then
      self:_createDivider(self._panel)
    end
    needsDivider = true

    -- Create the section container
    local secContainer = g_ui.createWidget('UIWidget', self._panel)
    table.insert(self._all, secContainer)
    local secLayout = UIVerticalLayout.create(secContainer)
    secContainer:setLayout(secLayout)
    secLayout:setSpacing(3)

    -- Section header using the server-provided section name
    if sec.name and sec.name ~= "" then
      local secHeader = g_ui.createWidget('TooltipSectionHeader', secContainer)
      secHeader:setText(sec.name)
      secHeader:setFocusable(false)
      table.insert(self._all, secHeader)
      -- Section header debug logging disabled for performance.
    end

    -- Per-section tracking
    local secRowCount  = #sec.rows
    local secRendered  = 0

    -- Render each row in the section
    for ri, rowData in ipairs(sec.rows) do
      local rowWidget = self:_buildStatRow(secContainer, rowData)
      secRendered = secRendered + 1
      if TOOLTIP_DEBUG then
        self._stats.rendered = self._stats.rendered + 1

        -- Log the row for post-verification
        local text = rowData.text or ""
        if rowData.suffix then text = text .. " [" .. rowData.suffix .. "]" end

        table.insert(self._stats.rowLog, {
          secIdx = sectionIndex,
          rowIdx = ri,
          rowType = rowData.type,
          text    = text,
          widget  = rowWidget,
        })
      end
    end

    -- Set explicit section container height so computeContainerHeight works
    local secH = computeContainerHeight(secContainer, 3)
    local secW = secContainer:getSize() and secContainer:getSize().width or 0
    secContainer:setSize({ width = secW, height = secH })
    if TOOLTIP_DEBUG then
      table.insert(self._stats.sectionLog, {
        name     = sec.name or ("Section " .. sectionIndex),
        rows     = secRowCount,
        rendered = secRendered,
      })
    end
  end

  -- ═══════════════════════════════════════════════════════════════
  -- 4. Footer (only if rows exist)
  -- ═══════════════════════════════════════════════════════════════
  local hasFooter = data.footer and #data.footer > 0

  if hasFooter then
    -- Only add divider if there were populated sections above
    if sectionIndex > 0 then
      self:_createDivider(self._panel)
    end

    local footerContainer = g_ui.createWidget('UIWidget', self._panel)
    table.insert(self._all, footerContainer)
    local fLayout = UIVerticalLayout.create(footerContainer)
    footerContainer:setLayout(fLayout)
    fLayout:setSpacing(3)

    for ri, rowData in ipairs(data.footer) do
      local rowWidget = self:_buildFooterRow(footerContainer, rowData)
      if TOOLTIP_DEBUG then
        self._stats.rendered = self._stats.rendered + 1

        local label = rowData.label or ""
        local value = rowData.value or ""
        table.insert(self._stats.rowLog, {
          secIdx   = "footer",
          rowIdx   = ri,
          rowType  = "footer",
          text     = label .. ": " .. value,
          widget   = rowWidget,
        })
      end
    end

    -- Set explicit footer container height
    local footerH = computeContainerHeight(footerContainer, 3)
    local fW = footerContainer:getSize() and footerContainer:getSize().width or 0
    footerContainer:setSize({ width = fW, height = footerH })
  end

  -- ═══════════════════════════════════════════════════════════════
  -- 5. Finalize: stretch dividers, compute height
  -- ═══════════════════════════════════════════════════════════════
  self:_finalizeDividers()

  -- Compute panel height: sum of all direct children + spacing + padding.
  -- We cannot use getChildrenRect() here because layouts haven't been applied
  -- yet (OTUI applies them during the render frame).  Instead we sum the
  -- explicit heights we've set on every child.
  local contentH = computeContainerHeight(self._panel, 3)

  local finalH = contentH + PAD * 2
  if finalH < 50 then finalH = 50 end
  self._panel:setSize({width = self._curW, height = finalH})

  self._built = true

  -- ═══════════════════════════════════════════════════════════════
  -- 6. Post-render verification (DEBUG only)
  -- ═══════════════════════════════════════════════════════════════
  if TOOLTIP_DEBUG then
    self:_verifyRendering(data, finalH)
  end
end

-- ═══════════════════════════════════════════════════════════════════
-- Detailed rendering verification (DEBUG only)
-- Checks every row from TooltipData against the created widget tree.
-- Logs per-section, per-row, and final tally.
-- ═══════════════════════════════════════════════════════════════════
function TooltipRenderer:_verifyRendering(data, panelH)
  local st = self._stats
  print("[game_tooltip] ═══ Render Verification ═══")
  print("[game_tooltip] Panel: " .. tostring(self._curW) .. "x" .. tostring(panelH))
  print("[game_tooltip] Total widgets tracked: " .. tostring(#self._all))

  -- ── Header verification ──
  if data.header then
    print("[game_tooltip] ── Header ──")
    if data.header.icon then
      print("[game_tooltip]   Icon: provided")
    else
      print("[game_tooltip]   Icon: MISSING")
      table.insert(st.issues, "Header icon is nil")
    end
    if data.header.name and data.header.name ~= "" then
      print("[game_tooltip]   Name: " .. data.header.name)
    else
      print("[game_tooltip]   Name: MISSING")
      table.insert(st.issues, "Header name is empty")
    end
    if data.header.category and data.header.category ~= "" then
      print("[game_tooltip]   Category: " .. data.header.category)
    else
      print("[game_tooltip]   Category: none")
    end
  else
    print("[game_tooltip]   Header: NONE (data.header is nil)")
    table.insert(st.issues, "data.header is nil")
  end

  -- ── Section-by-section log ──
  local sectionNames = { "Base Stats", "Special Attributes", "Requirements", "Description" }
  print("[game_tooltip] ── Sections ──")
  print("[game_tooltip]   All sections in data: " .. tostring(#(data.sections or {})))
  for si, secData in ipairs(data.sections or {}) do
    local nRows = #(secData.rows or {})
    local secName = sectionNames[si] or ("Section " .. si)
    -- Find matching populated section log
    local rendered = 0
    for _, sl in ipairs(st.sectionLog) do
      -- Compare by row count to match (no stable name in data)
      if sl.rows == nRows or sl.name == secName then
        rendered = sl.rendered
      end
    end
    local skipped = nRows - rendered
    if skipped < 0 then skipped = 0 end
    print("[game_tooltip]   [" .. si .. "] " .. secName
          .. ": rows=" .. tostring(nRows)
          .. " rendered=" .. tostring(rendered)
          .. " skipped=" .. tostring(skipped)
          .. (skipped > 0 and (" REASON=" .. self:_skipReason(data, si)) or ""))
    if skipped > 0 then
      table.insert(st.issues, secName .. ": " .. tostring(skipped) .. " rows not rendered")
    end
  end

  -- ── Footer verification ──
  local footerRows = #(data.footer or {})
  local footerRendered = 0
  for _, rl in ipairs(st.rowLog) do
    if rl.secIdx == "footer" then footerRendered = footerRendered + 1 end
  end
  print("[game_tooltip] ── Footer ──")
  print("[game_tooltip]   rows=" .. tostring(footerRows)
        .. " rendered=" .. tostring(footerRendered)
        .. (footerRows ~= footerRendered and " MISMATCH!" or ""))
  if footerRows ~= footerRendered then
    table.insert(st.issues, "Footer: " .. tostring(footerRows - footerRendered) .. " rows missing")
  end

  -- ── Per-row widget verification ──
  print("[game_tooltip] ── Row Widgets ──")
  local visibleCount = 0
  for ri, rl in ipairs(st.rowLog) do
    local w = rl.widget
    local ok = true
    local problems = {}

    if not w or w:isDestroyed() then
      table.insert(problems, "DESTROYED")
      ok = false
    else
      -- Check visibility (note: widget may not have isVisible=true until panel is shown)
      local hidden = false
      if w:isVisible() == false then
        hidden = true
      end
      -- Check size
      local ws = w:getSize()
      if not ws or ws.width <= 0 or ws.height <= 0 then
        table.insert(problems, "ZERO_SIZE(" .. tostring(ws and ws.width) .. "x" .. tostring(ws and ws.height) .. ")")
        ok = false
      end
      -- Check position
      local wr = w:getRect()
      if wr then
        if wr.x < 0 then
          table.insert(problems, "NEG_X(" .. tostring(wr.x) .. ")")
          ok = false
        end
        if wr.y < 0 then
          table.insert(problems, "NEG_Y(" .. tostring(wr.y) .. ")")
          ok = false
        end
        if wr.width <= 0 or wr.height <= 0 then
          table.insert(problems, "ZERO_RECT(" .. tostring(wr.width) .. "x" .. tostring(wr.height) .. ")")
          ok = false
        end
      end
      if hidden and ok then
        problems = { "HIDDEN(ok)" }
      elseif hidden then
        table.insert(problems, "HIDDEN")
      end
    end

    if ok then
      visibleCount = visibleCount + 1
    end
    local status = ok and "OK" or ("ISSUE: " .. table.concat(problems, ", "))
    print("[game_tooltip]   row " .. tostring(ri)
          .. "  type=" .. tostring(rl.rowType)
          .. "  text=\"" .. tostring(rl.text) .. "\""
          .. "  " .. status)
  end
  st.visible = visibleCount

  -- ── Final tally ──
  print("[game_tooltip] ═══ Tally ═══")
  print("[game_tooltip]   TooltipData rows: " .. tostring(st.expected))
  print("[game_tooltip]   Row widgets created: " .. tostring(st.rendered))
  print("[game_tooltip]   Row widgets visible: " .. tostring(st.visible))
  if st.expected == st.rendered and st.rendered == st.visible then
    print("[game_tooltip]   VERDICT: ALL ROWS ACCOUNTED FOR ✓")
  else
    if st.expected ~= st.rendered then
      local diff = st.expected - st.rendered
      print("[game_tooltip]   VERDICT: " .. tostring(diff) .. " rows were NOT created from TooltipData!")
      if diff > 0 then
        print("[game_tooltip]   Possible cause: section excluded by populatedSections filter?")
      end
    end
    if st.rendered ~= st.visible then
      local diff = st.rendered - st.visible
      print("[game_tooltip]   VERDICT: " .. tostring(diff) .. " created rows are NOT VISIBLE!")
      print("[game_tooltip]   Review per-row log above for ISSUE entries.")
    end
  end

  -- ── Layout validation ──
  -- Note: Layout validation skipped at rebuild time because OTUI applies
  -- layouts during the render frame.  Widget positions/sizes will be correct
  -- when the panel is shown.  The "HIDDEN" warnings above are expected since
  -- the panel hasn't been shown yet.  Check the render output visually
  -- or add a runtime verification hook after panel:show().

  if #st.issues > 0 then
    print("[game_tooltip] ═══ Issues Summary ═══")
    for ii, issue in ipairs(st.issues) do
      print("[game_tooltip]   " .. tostring(ii) .. ". " .. issue)
    end
  end
  print("[game_tooltip] ═══ End Verification ═══")
end

-- Determine why rows in a section might not render (helper for verification)
function TooltipRenderer:_skipReason(data, secIdx)
  local sec = data.sections and data.sections[secIdx]
  if not sec then return "section index out of range" end
  if not sec.rows or #sec.rows == 0 then return "empty section" end

  -- Check each row for common problems
  for _, row in ipairs(sec.rows) do
    if row.text == nil then return "row has nil text" end
    if row.text == "" then return "row has empty text" end
  end
  return "unknown"
end

function TooltipRenderer:show()
  if self._panel then
    self._panel:show()
    self._panel:raise()
  end
end

function TooltipRenderer:hide()
  if self._panel then
    self._panel:hide()
  end
end

function TooltipRenderer:setPosition(x, y)
  if self._panel then
    if type(x) == "table" then
      self._panel:setPosition(x)
    else
      self._panel:setPosition({x = x, y = y})
    end
  end
end

function TooltipRenderer:getSize()
  if self._panel then
    return self._panel:getSize()
  end
  return { width = 0, height = 0 }
end

function TooltipRenderer:destroy()
  self:_clearAll()
  if self._panel and self._panel:isDestroyed() == false then
    self._panel:destroy()
  end
  self._panel = nil
  self._built = false
end

function TooltipRenderer:fadeIn(duration)
  if self._panel then
    g_effects.fadeIn(self._panel, duration or 120)
  end
end

function TooltipRenderer:fadeOut(duration)
  if self._panel then
    g_effects.fadeOut(self._panel, duration or 80)
  end
end

-- ═══════════════════════════════════════════════════════════════
-- 7.  TooltipBuilder – item → TooltipData (pure data)
--
-- ARCHITECTURE:
--   TooltipBuilder is the orchestration layer.  It:
--     1. Classifies the item (ItemClassifier)
--     2. Collects data from each enabled provider
--     3. Assembles the NEW TooltipData format (header/body/footer/style)
--     4. Flattens to the OLD format (header/sections/footer) for
--        backward compatibility with TooltipRenderer
--
--   Each provider is a self-contained module that:
--     - Receives: itemClass, item, thingType, ctx
--     - Returns: data for one section of the tooltip, or nil if N/A
--     - Can be enabled/disabled independently
--     - Knows nothing about other providers or the renderer
--
--   The NEW TooltipData format (used internally):
--     TooltipData = {
--       header = { icon, name, category, rarity, quality },
--       body   = {
--         equipment    = { rows = { {type,text,suffix,icon}, ... } },
--         attributes   = { rows = { ... } },
--         requirements = { rows = { ... } },
--         sockets      = { rows = { ... } },
--         enchantments = { rows = { ... } },
--         description  = { rows = { ... } },
--       },
--       footer = { { label, value }, ... },
--       style  = { borderColor, titleColor, rarityColor, dividerStyle },
--     }
--
--   The flattened OLD format (used by TooltipRenderer):
--     TooltipData = {
--       header   = { icon, name, category },
--       sections = { { name?, rows = { ... } }, ... },
--       footer   = { { label, value }, ... },
--     }
--
--   SEPARATION OF CONCERNS:
--     TooltipRenderer:rebuild(data) — consumes flattened TooltipData
--     TooltipBuilder.build(item)    — classifier + providers + flatten
--     Providers                     — domain-specific data producers
-- ═══════════════════════════════════════════════════════════════
local TooltipBuilder = {}

local VOCATION_MAP = {
  [1]  = "Knights",
  [2]  = "Paladins",
  [3]  = "Sorcerers",
  [4]  = "Druids",
  [5]  = "Knights & Paladins",
  [6]  = "Knights & Sorcerers",
  [7]  = "Paladins & Sorcerers",
  [8]  = "Knights & Druids",
  [9]  = "Paladins & Druids",
  [10] = "Sorcerers & Druids",
  [11] = "Knights & Paladins & Sorcerers",
  [12] = "Knights & Paladins & Druids",
  [13] = "Knights & Sorcerers & Druids",
  [14] = "Paladins & Sorcerers & Druids",
  [15] = "All Vocations",
}

-- Parse an item description string and return:
--   statsRows   – stat lines (armor, attack, defence, protection, …)
--   reqRows     – requirement lines (level, vocation)
--   weightOz    – parsed weight as number, or nil
--   otherLines  – description text that didn't match known patterns
local function parseDescription(desc)
  local statsRows  = {}
  local reqRows    = {}
  local weightOz   = nil
  local otherLines = {}

  if not desc or desc == "" then return statsRows, reqRows, weightOz, otherLines end

  for line in desc:gmatch("[^\n]+") do
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then
      -- skip blank lines
    elseif line:match("^It weighs ([%d%.]+) oz%.?$") then
      weightOz = tonumber(line:match("^It weighs ([%d%.]+) oz%.?$"))
    elseif line:match("^Armor:%s*(%d+)") then
      local armor = line:match("^Armor:%s*(%d+)")
      table.insert(statsRows, { type = "stat", icon = "diamond", text = tostring(armor) .. " Armor" })
    elseif line:match("^Atk:%s*(%d+),%s*Def:%s*(%d+)") then
      local atk, def = line:match("^Atk:%s*(%d+),%s*Def:%s*(%d+)")
      table.insert(statsRows, { type = "stat", icon = "diamond", text = "Atk: " .. atk .. "  Def: " .. def })
    elseif line:match("^Attack:%s*(%d+),%s*Defense:%s*(%d+)") then
      local atk, def = line:match("^Attack:%s*(%d+),%s*Defense:%s*(%d+)")
      table.insert(statsRows, { type = "stat", icon = "diamond", text = "Atk: " .. atk .. "  Def: " .. def })
    elseif line:match("^Atk:%s*(%d+)") then
      local atk = line:match("^Atk:%s*(%d+)")
      table.insert(statsRows, { type = "stat", icon = "diamond", text = "Atk: " .. atk })
    elseif line:match("^Attack:%s*(%d+)") then
      local atk = line:match("^Attack:%s*(%d+)")
      table.insert(statsRows, { type = "stat", icon = "diamond", text = "Atk: " .. atk })
    elseif line:match("^Def:%s*(%d+)") then
      local def = line:match("^Def:%s*(%d+)")
      table.insert(statsRows, { type = "stat", icon = "diamond", text = "Def: " .. def })
    elseif line:match("^Defense:%s*(%d+)") then
      local def = line:match("^Defense:%s*(%d+)")
      table.insert(statsRows, { type = "stat", icon = "diamond", text = "Def: " .. def })
    elseif line:match("^Protection (.+)") then
      local protTxt = line:match("^Protection (.+)")
      table.insert(statsRows, { type = "stat", icon = "diamond", text = "Protection " .. protTxt })
    elseif line:match("^Charges:%s*(%d+)") then
      local charges = line:match("^Charges:%s*(%d+)")
      table.insert(statsRows, { type = "stat", icon = "diamond", text = "Charges: " .. charges })
    elseif line:match("^Hit Chance%s*(%+?%-?%d+)%%") then
      local hc = line:match("^Hit Chance%s*(%+?%-?%d+)%%")
      table.insert(statsRows, { type = "stat", icon = "diamond", text = "Hit Chance " .. hc .. "%" })
    elseif line:match("^Range:%s*(%d+)") then
      local range = line:match("^Range:%s*(%d+)")
      table.insert(statsRows, { type = "stat", icon = "diamond", text = "Range: " .. range })
    elseif line:match("^It can only be wielded properly by (.+) of level (%d+) or higher%.?$") then
      local vocStr, lvlStr = line:match("^It can only be wielded properly by (.+) of level (%d+) or higher%.?$")
      table.insert(reqRows, { type = "stat", icon = "diamond", text = "Level " .. lvlStr .. " (" .. vocStr .. ")" })
    elseif line:match("^It can only be wielded properly by (.+)%.?$") then
      local vocOnly = line:match("^It can only be wielded properly by (.+)%.?$")
      table.insert(reqRows, { type = "stat", icon = "diamond", text = vocOnly })
    elseif line:match("^It says: (.+)") then
      local says = line:match("^It says: (.+)")
      table.insert(otherLines, '"' .. says .. '"')
    else
      table.insert(otherLines, line)
    end
  end

  return statsRows, reqRows, weightOz, otherLines
end

-- ═════════════════════════════════════════════════════════════════════
-- Shared helpers used by multiple providers
-- ═════════════════════════════════════════════════════════════════════

local function tryLightRow(thingType)
  if not thingType then return nil end
  local ok, has = pcall(thingType.hasLight, thingType)
  if not ok or not has then return nil end
  local ok2, light = pcall(thingType.getLight, thingType)
  if not ok2 or not light or not light.intensity or light.intensity <= 0 then return nil end
  local txt = "Light: " .. tostring(light.intensity)
  return { type = "stat", icon = "diamond", text = txt }
end

local function tryChargesRow(item, thingType)
  if not thingType then return nil end
  local ok, isChargeable = pcall(thingType.isChargeable, thingType)
  if not ok or not isChargeable then return nil end
  local charges = item:getSubType()
  if not charges or charges <= 0 then return nil end
  return { type = "stat", icon = "diamond", text = "Charges: " .. tostring(charges) }
end

-- ═════════════════════════════════════════════════════════════════════
-- Provider registry
--   Each provider is registered with a name and a getData() function.
--   getData(itemClass, item, thingType, ctx) → rows array or nil
-- ═════════════════════════════════════════════════════════════════════
local ProviderRegistry = {
  _order   = {},  -- ordered list of provider names
  _modules = {},  -- name → { getData = fn, enabled = bool }
}

function ProviderRegistry.register(name, getData, enabled)
  ProviderRegistry._modules[name] = {
    getData = getData,
    enabled = enabled ~= false,  -- default enabled
  }
  table.insert(ProviderRegistry._order, name)
end

function ProviderRegistry.setEnabled(name, enabled)
  local mod = ProviderRegistry._modules[name]
  if mod then mod.enabled = enabled end
end

function ProviderRegistry.isEnabled(name)
  local mod = ProviderRegistry._modules[name]
  return mod and mod.enabled
end

-- ═════════════════════════════════════════════════════════════════════
-- EquipmentProvider – combat/defense stats (Atk, Def, Armor, Protection,
--   Hit Chance, Range).  Primary section for weapons, armor, shields.
-- ═════════════════════════════════════════════════════════════════════
local function equipmentProvider_getData(itemClass, item, thingType, ctx)
  -- Containers: show capacity info from OTB/ItemType if available
  if itemClass == ITEM_CONTAINER then
    local rows = {}
    -- Try to get container capacity from the item's parent Container object
    local parentContainer = item:getParentContainer()
    if parentContainer then
      local cap = parentContainer:getCapacity()
      if cap and cap > 0 then
        table.insert(rows, { type = "stat", icon = "diamond", text = "Capacity: " .. tostring(cap) .. " slots" })
        return rows
      end
    end
    -- Fallback: read from g_things ItemType (OTB data)
    local ok, itemType = pcall(g_things.getItemType, item:getServerId())
    if ok and itemType then
      -- No getMaxItems exposed, just note it's a container
      table.insert(rows, { type = "stat", icon = "diamond", text = "Container" })
      return rows
    end
    return nil
  end

  -- Fluids: handled by other providers
  if itemClass == ITEM_FLUID then
    return nil
  end

  -- Weapons, armor, shields, runes, ammo, and generic items with combat stats.
  -- Only gameplay-relevant stats from server description are shown.
  -- Engine flags (isMarketable, isStackable, etc.) are NEVER exposed here.
  local rows = {}
  for _, r in ipairs(ctx.statsRows) do table.insert(rows, r) end
  return (#rows > 0) and rows or nil
end

ProviderRegistry.register("equipment", equipmentProvider_getData, true)

-- ═════════════════════════════════════════════════════════════════════
-- AttributeProvider – gameplay-relevant item attributes (light, charges,
--   ground speed, written text content).
--   NEVER emits raw engine flags (Tradeable, Stackable, Usable, etc.).
--   Engine flags may still be used INTERNALLY for logic but are never
--   displayed as visible rows.
-- ═════════════════════════════════════════════════════════════════════
local function attributeProvider_getData(itemClass, item, thingType, ctx)
  if not thingType then return nil end

  local rows = {}
  local hasStats = ctx.statsRows and #ctx.statsRows > 0

  -- Charges (always check – gameplay relevant)
  local cr = tryChargesRow(item, thingType)
  if cr then table.insert(rows, cr) end

  -- For items WITH equipment stats, only emit supplementary attributes
  if hasStats then
    if ctx.itemText and ctx.itemText ~= "" then
      table.insert(rows, { type = "stat", icon = "diamond", text = ctx.itemText })
    end
    return (#rows > 0) and rows or nil
  end

  -- For items WITHOUT equipment stats, emit only gameplay-relevant attributes.
  -- Engine flags (Tradeable, Stackable, Usable, Writable, etc.) are NOT shown.

  if itemClass == ITEM_CONTAINER then
    -- Container attributes handled by EquipmentProvider
  elseif itemClass == ITEM_FLUID then
    -- Fluid attributes handled by EquipmentProvider
  else
    -- Equipment slot (gameplay info: where does this item go?)
    local clothSlot = thingType:getClothSlot()
    if clothSlot and clothSlot > 0 then
      local slotNames = { [1]="Head", [2]="Body", [3]="Legs", [4]="Feet", [5]="Ring", [6]="Necklace", [7]="Backpack", [8]="Cloth", [9]="Ring" }
      local slotName = slotNames[clothSlot] or ("Slot " .. tostring(clothSlot))
      table.insert(rows, { type = "stat", icon = "diamond", text = "Equip: " .. slotName })
    end

    -- Market data category (gameplay classification)
    if thingType:isMarketable() then
      local md = thingType:getMarketData()
      if md and md.category and md.category > 0 then
        local catNames = { [2]="Container", [3]="Weapon", [4]="Ammunition", [5]="Armor", [6]="Rune", [10]="Key", [11]="Fluid", [12]="Fluid" }
        local catName = catNames[md.category]
        if catName then
          table.insert(rows, { type = "stat", icon = "diamond", text = catName })
        end
      end
    end

    -- Ground speed (ground tiles – gameplay relevant for movement)
    local ok, gs = pcall(thingType.getGroundSpeed, thingType)
    if ok and gs and gs > 0 then
      table.insert(rows, { type = "stat", icon = "diamond", text = "Speed: " .. tostring(gs) })
    end

    -- Written text content (books, letters, parchments – the actual content)
    if ctx.itemText and ctx.itemText ~= "" then
      table.insert(rows, { type = "stat", icon = "diamond", text = ctx.itemText })
    end
  end

  return (#rows > 0) and rows or nil
end

ProviderRegistry.register("attributes", attributeProvider_getData, true)

-- ═════════════════════════════════════════════════════════════════════
-- RequirementProvider – level and vocation requirements
-- ═════════════════════════════════════════════════════════════════════
local function requirementProvider_getData(itemClass, item, thingType, ctx)
  local rows = {}
  for _, r in ipairs(ctx.marketRows) do table.insert(rows, r) end
  for _, r in ipairs(ctx.reqRows) do table.insert(rows, r) end
  return (#rows > 0) and rows or nil
end

ProviderRegistry.register("requirements", requirementProvider_getData, true)

-- ═════════════════════════════════════════════════════════════════════
-- DescriptionProvider – item description text lines (e.g. "It says: ...")
-- ═════════════════════════════════════════════════════════════════════
local function descriptionProvider_getData(itemClass, item, thingType, ctx)
  local rows = {}
  for _, txt in ipairs(ctx.otherLines) do
    if txt ~= ctx.displayName and txt ~= ctx.itemName then
      table.insert(rows, { type = "stat", icon = "diamond", text = txt })
    end
  end
  return (#rows > 0) and rows or nil
end

ProviderRegistry.register("description", descriptionProvider_getData, true)

-- ═════════════════════════════════════════════════════════════════════
-- FooterProvider – weight, value, and source info.
--   Only shows information the player cares about.
--   Never displays placeholders.
-- ═════════════════════════════════════════════════════════════════════
local function footerProvider_getData(itemClass, item, thingType, ctx)
  local rows = {}

  -- Weight
  if ctx.weightOz then
    local totalWeight = ctx.weightOz
    if ctx.itemCount and ctx.itemCount > 1 then
      totalWeight = ctx.weightOz * ctx.itemCount
    end
    table.insert(rows, { label = "Weight", value = string.format("%.2f oz", totalWeight) })
  end

  -- Market value (buy/sell from MarketData if available)
  if ctx.marketData and type(ctx.marketData) == "table" then
    if ctx.marketData.buyPrice and ctx.marketData.buyPrice > 0 then
      table.insert(rows, { label = "NPC Buy", value = tostring(ctx.marketData.buyPrice) .. " gp" })
    end
    if ctx.marketData.sellPrice and ctx.marketData.sellPrice > 0 then
      table.insert(rows, { label = "NPC Sell", value = tostring(ctx.marketData.sellPrice) .. " gp" })
    end
  end

  return (#rows > 0) and rows or nil
end

ProviderRegistry.register("footer", footerProvider_getData, true)

-- ═════════════════════════════════════════════════════════════════════
-- SocketProvider – sockets / imbuing (future)
-- ═════════════════════════════════════════════════════════════════════
local function socketProvider_getData(itemClass, item, thingType, ctx)
  return nil  -- Not yet implemented
end

ProviderRegistry.register("sockets", socketProvider_getData, true)

-- ═════════════════════════════════════════════════════════════════════
-- EnchantmentProvider – enchantments / upgrade info (future)
-- ═════════════════════════════════════════════════════════════════════
local function enchantmentProvider_getData(itemClass, item, thingType, ctx)
  return nil  -- Not yet implemented
end

ProviderRegistry.register("enchantments", enchantmentProvider_getData, true)

-- ═════════════════════════════════════════════════════════════════════
-- New TooltipData flattener – converts new format → old sections/footer
-- ═════════════════════════════════════════════════════════════════════
local function flattenTooltipData(newData)
  local flat = {
    header = newData.header and {
      icon     = newData.header.icon,
      name     = newData.header.name,
      category = newData.header.category,
    } or nil,
    sections = {},
    footer   = {},
  }

  -- Ordered body sections
  local bodyOrder = { "equipment", "attributes", "requirements", "sockets", "enchantments", "description" }
  for _, key in ipairs(bodyOrder) do
    local section = newData.body and newData.body[key]
    if section and section.rows and #section.rows > 0 then
      local sectionName = nil
      if key == "requirements" then sectionName = "Requirements" end
      table.insert(flat.sections, { name = sectionName, rows = section.rows })
    end
  end

  -- Footer
  if newData.footer and #newData.footer > 0 then
    for _, f in ipairs(newData.footer) do
      table.insert(flat.footer, f)
    end
  end

  return flat
end

-- Gather MarketData rows (level requirement, vocation restriction)
-- MarketData struct always returns a table with defaults (0 for ints, "" for strings).
-- Only show rows when values are genuinely > 0.
local function buildMarketDataRows(itemId)
  local rows = {}

  local ok, marketData = pcall(function()
    local tt = g_things.getThingType(itemId, ThingCategoryItem)
    if tt then return tt:getMarketData() end
    return nil
  end)
  if ok and marketData and type(marketData) == "table" then
    -- Market data is valid only if it has a non-empty name or category > 0
    local hasData = (marketData.name and marketData.name ~= "") or (marketData.category and marketData.category > 0)
    if hasData then
      local reqLevel = marketData.requiredLevel
      if reqLevel and reqLevel > 0 then
        table.insert(rows, { type = "stat", icon = "diamond", text = "Level Required: " .. tostring(reqLevel) })
      end
      local restrictVoc = marketData.restrictVocation
      if restrictVoc and restrictVoc > 0 then
        local vocName = VOCATION_MAP[restrictVoc]
        if vocName then
          table.insert(rows, { type = "stat", icon = "diamond", text = "Vocation: " .. vocName })
        end
      end
    end
  end

  return rows
end

-- Helper: try calling a function and return (ok, value_as_string)
local function try(fn)
  local ok, val = pcall(fn)
  return ok, tostring(val)
end

-- Verify an Item by probing every available Lua-bound method and logging results.
local function verifyItemAPI(item, label)
  if not TOOLTIP_DEBUG then return end
  print("[game_tooltip] === Item API Probe [" .. label .. "] ===")

  local checks = {
    {"getName",            function() return item:getName() end},
    {"getDescription",     function() return item:getDescription() end},
    {"getTooltip",         function() return item:getTooltip() end},
    {"getId",              function() return item:getId() end},
    {"getServerId",        function() return item:getServerId() end},
    {"getCount",           function() return item:getCount() end},
    {"getSubType",         function() return item:getSubType() end},
    {"getCountOrSubType",  function() return item:getCountOrSubType() end},
    {"getText",            function() return item:getText() end},
    {"getActionId",        function() return item:getActionId() end},
    {"getUniqueId",        function() return item:getUniqueId() end},
    {"getClothSlot",       function() return item:getClothSlot() end},
    {"getQuickLootFlags",  function() return item:getQuickLootFlags() end},
    {"isStackable",        function() return item:isStackable() end},
    {"isMarketable",       function() return item:isMarketable() end},
    {"isFluidContainer",   function() return item:isFluidContainer() end},
    {"isGround",           function() return item:isGround() end},
    {"isContainer",        function() return item:isContainer() end},
    {"isPickupable",       function() return item:isPickupable() end},
    {"isRotateable",       function() return item:isRotateable() end},
    {"isNotMoveable",      function() return item:isNotMoveable() end},
    {"isUsable",           function() return item:isUsable() end},
    {"isWrapable",         function() return item:isWrapable() end},
    {"isTopEffect",        function() return item:isTopEffect() end},
    {"isLyingCorpse",      function() return item:isLyingCorpse() end},
    {"isFullGround",       function() return item:isFullGround() end},
    {"isTranslucent",      function() return item:isTranslucent() end},
    {"isHookSouth",        function() return item:isHookSouth() end},
    {"isForceUse",         function() return item:isForceUse() end},
    {"isMultiUse",         function() return item:isMultiUse() end},
    {"getMarketData",      function() local md = item:getMarketData(); return md and md.name or "empty" end},
    {"getCustomAttribute(1)", function() return item:getCustomAttribute(1) end},
  }

  for _, c in ipairs(checks) do
    local ok, val = try(c[2])
    print("  " .. c[1] .. " = " .. val .. (ok and "" or " (ERROR)"))
  end
  print("[game_tooltip] === End Item API Probe ===")
end

-- Verify a ThingType by probing every available property.
local function verifyThingType(itemId)
  if not TOOLTIP_DEBUG then return end
  local ok, tt = pcall(g_things.getThingType, itemId, ThingCategoryItem)
  if not ok or not tt then
    print("[game_tooltip] verifyThingType: cannot get ThingType for " .. tostring(itemId))
    return
  end

  print("[game_tooltip] === ThingType Probe (id=" .. tostring(itemId) .. ") ===")

  local probes = {
    {"getCategory",     function() return tt:getCategory() end},
    {"getClothSlot",    function() return tt:getClothSlot() end},
    {"getGroundSpeed",  function() return tt:getGroundSpeed() end},
    {"getMaxTextLength",function() return tt:getMaxTextLength() end},
    {"getMinimapColor", function() return tt:getMinimapColor() end},
    {"getLensHelp",     function() return tt:getLensHelp() end},
    {"getElevation",    function() return tt:getElevation() end},
    {"getLight",        function() local l = tt:getLight(); return "{intensity=" .. tostring(l.intensity) .. ",color=" .. tostring(l.color) .. "}" end},
    {"getMarketData",   function() local md = tt:getMarketData(); return md and md.name or "empty" end},
    {"isGround",        function() return tt:isGround() end},
    {"isGroundBorder",  function() return tt:isGroundBorder() end},
    {"isOnBottom",      function() return tt:isOnBottom() end},
    {"isOnTop",         function() return tt:isOnTop() end},
    {"isContainer",     function() return tt:isContainer() end},
    {"isStackable",     function() return tt:isStackable() end},
    {"isForceUse",      function() return tt:isForceUse() end},
    {"isMultiUse",      function() return tt:isMultiUse() end},
    {"isWritable",      function() return tt:isWritable() end},
    {"isChargeable",    function() return tt:isChargeable() end},
    {"isWritableOnce",  function() return tt:isWritableOnce() end},
    {"isFluidContainer",function() return tt:isFluidContainer() end},
    {"isSplash",        function() return tt:isSplash() end},
    {"isNotWalkable",   function() return tt:isNotWalkable() end},
    {"isNotMoveable",   function() return tt:isNotMoveable() end},
    {"blockProjectile", function() return tt:blockProjectile() end},
    {"isNotPathable",   function() return tt:isNotPathable() end},
    {"isPickupable",    function() return tt:isPickupable() end},
    {"isHangable",      function() return tt:isHangable() end},
    {"isHookSouth",     function() return tt:isHookSouth() end},
    {"isHookEast",      function() return tt:isHookEast() end},
    {"isRotateable",    function() return tt:isRotateable() end},
    {"hasLight",        function() return tt:hasLight() end},
    {"isDontHide",      function() return tt:isDontHide() end},
    {"isTranslucent",   function() return tt:isTranslucent() end},
    {"hasDisplacement", function() return tt:hasDisplacement() end},
    {"hasElevation",    function() return tt:hasElevation() end},
    {"isLyingCorpse",   function() return tt:isLyingCorpse() end},
    {"isAnimateAlways", function() return tt:isAnimateAlways() end},
    {"hasMiniMapColor", function() return tt:hasMiniMapColor() end},
    {"hasLensHelp",     function() return tt:hasLensHelp() end},
    {"isFullGround",    function() return tt:isFullGround() end},
    {"isIgnoreLook",    function() return tt:isIgnoreLook() end},
    {"isCloth",         function() return tt:isCloth() end},
    {"isMarketable",    function() return tt:isMarketable() end},
    {"isUsable",        function() return tt:isUsable() end},
    {"isWrapable",      function() return tt:isWrapable() end},
    {"isUnwrapable",    function() return tt:isUnwrapable() end},
    {"isTopEffect",     function() return tt:isTopEffect() end},
  }

  for _, p in ipairs(probes) do
    local ok, val = try(p[2])
    print("  " .. p[1] .. " = " .. val .. (ok and "" or " (ERROR)"))
  end
  print("[game_tooltip] === End ThingType Probe ===")
end

-- ═══════════════════════════════════════════════════════════════════════
-- TooltipBuilder.build(item) → TooltipData (flat, for renderer)
--
-- PRODUCER-CONSUMER CONTRACT:
--   TooltipBuilder is the ONLY component that knows about Items,
--   ThingTypes, and MarketData.  It produces TooltipData in the flat
--   (header/sections/footer) format that TooltipRenderer consumes.
--
--   ARCHITECTURE:
--     1. Classify item via ItemClassifier.classify()
--     2. Iterate provider registry, collect body section data
--     3. Assemble NEW TooltipData (header/body/footer/style)
--     4. Flatten to old format (header/sections/footer) for renderer
--
--   INTEGRATION PATH FOR SERVER-SENT DATA:
--     A future data-source module can:
--       1. Listen for server structured data
--       2. Build a NEW-format TooltipData table
--       3. Call flattenTooltipData() to produce the old format
--       4. Call renderer:rebuild(flattened) directly
--     No changes needed in TooltipRenderer or TooltipBuilder.
-- ═══════════════════════════════════════════════════════════════════════

-- Forward declaration — ServerData implementation is below, but build()
-- and hover handlers need access to it before the implementation.
local ServerData = {}

-- OPC 205 V3 state tables
ServerData._requestSeq        = 0                           -- monotonic request counter
ServerData._pending           = {}                          -- seq → { item, source, key, timer, callbacks }
ServerData._pendingByKey      = {}                          -- cacheKey → seq (O(1) dedup)
ServerData._cache             = {}                          -- cacheKey → parsed TooltipData (no wrapper)
ServerData._orphanedCallbacks = {}                          -- cacheKey → callbacks rescued from invalidated requests

-- Cache for item:getTooltipData() parsed results (feat-93 / item-packet path)
local parsedTooltipCache = {}

-- Determine the exact source location of a hovered item.
-- Returns { type=0..2, ... } or nil.
-- type=0: ground tile → { x, y, z, stackpos }
-- type=1: inventory   → { slot }
-- type=2: container   → { containerId, slot }
local function getItemSource(item, widget)
  if not widget then return nil end
  local widgetId = widget:getId() or ""

  -- Inventory: widget ID = "slot" .. slotNumber
  local invSlot = widgetId:match("^slot(%d+)$")
  if invSlot then
    return { type = 1, slot = tonumber(invSlot) }
  end

  -- Container: widget ID = "item" .. slotIndex
  local contSlot = widgetId:match("^item(%d+)$")
  if contSlot then
    contSlot = tonumber(contSlot)
    local parent = widget:getParent()          -- contentsPanel
    local grandparent = parent and parent:getParent()  -- containerWindow
    local contId = 0
    if grandparent then
      local gpId = grandparent:getId() or ""
      local idStr = gpId:match("^container(%d+)$")
      if idStr then contId = tonumber(idStr) end
    end
    return { type = 2, containerId = contId, slot = contSlot }
  end

  -- Ground: position-based
  local pos = item:getPosition()
  if pos and pos.x > 0 and pos.y > 0 then
    return {
      type     = 0,
      x        = pos.x,
      y        = pos.y,
      z        = pos.z,
      stackpos = item:getStackPos(),
    }
  end

  return nil
end

-- Stable cache key derived from item source location.
-- Used instead of userdata pointers which are not stable across item recreations.
-- Includes itemId to prevent stale cache when a different item occupies the same slot/position.
local function makeTooltipKey(source, itemId)
  if not source then return nil end
  if source.type == 0 then
    -- Ground: GROUND:<x>:<y>:<z>:<stackpos>:<itemId>
    return "GROUND:" .. source.x .. ":" .. source.y .. ":" .. source.z .. ":" .. (source.stackpos or 0) .. ":" .. (itemId or 0)
  elseif source.type == 1 then
    -- Inventory: INV:<slot>:<itemId>
    return "INV:" .. (source.slot or 0) .. ":" .. (itemId or 0)
  elseif source.type == 2 then
    -- Container: CONT:<containerId>:<slot>:<itemId>
    return "CONT:" .. (source.containerId or 0) .. ":" .. (source.slot or 0) .. ":" .. (itemId or 0)
  end
  return nil
end

-- Binary serializer helpers (for building opcode 205 request buffer)
local function _writeU8(v)
  return string.char(v % 256)
end
local function _writeU16LE(v)
  return string.char(v % 256, math.floor(v / 256) % 256)
end

-- ═══════════════════════════════════════════════════════════════
--  Internal: build and send opcode 205 request, create pending entry
-- ═══════════════════════════════════════════════════════════════
-- Pending entry stores NO UI references — only item, source, key, timer, callbacks.
function ServerData._sendRequest(item, source, key)
  ServerData._requestSeq = (ServerData._requestSeq + 1) % 65536
  local seq = ServerData._requestSeq

  -- Build request buffer: [seq(u16)][clientId(u16)][serverId(u16)][srcType(u8)][payload...]
  local buf = _writeU16LE(seq) .. _writeU16LE(item:getId()) .. _writeU16LE(item:getServerId()) .. _writeU8(source.type)

  if source.type == 0 then
    buf = buf .. _writeU16LE(source.x) .. _writeU16LE(source.y) .. _writeU8(source.z) .. _writeU8(source.stackpos)
  elseif source.type == 1 then
    buf = buf .. _writeU8(source.slot)
  elseif source.type == 2 then
    buf = buf .. _writeU8(source.containerId) .. _writeU8(source.slot)
  end

  -- Timeout: 5 seconds
  local timerId = scheduleEvent(function()
    local p = ServerData._pending[seq]
    if p then
      if p.key then
        ServerData._pendingByKey[p.key]      = nil
        ServerData._orphanedCallbacks[p.key] = nil
      end
      ServerData._pending[seq] = nil
    end
  end, 5000)

  -- Store pending entry (no widget/renderer/posHelper)
  ServerData._pending[seq] = {
    item      = item,
    source    = source,
    key       = key,
    timer     = timerId,
    callbacks = {},
  }
  if key then
    ServerData._pendingByKey[key] = seq
  end

  -- Send via extended opcode 205
  local pg = g_game.getProtocolGame()
  if pg then
    pg:sendExtendedOpcode(205, buf)
  end

  return seq
end

-- ═══════════════════════════════════════════════════════════════
--  fetch() — single synchronization authority
-- ═══════════════════════════════════════════════════════════════
--   pending?        → attach callback, return
--   cache exists?   → return nil (caller must invalidate first)
--   cache missing?  → send request, store callback for response
-- Returns seq (request sent) or nil (cache fresh / no request needed).
function ServerData.fetch(item, source, callback)
  if not item or not item:isItem() or item:getId() == 0 then return nil end
  if not source then return nil end

  local key = makeTooltipKey(source, item:getId())
  if not key then return nil end

  -- Already in-flight?
  local existingSeq = ServerData._pendingByKey[key]
  if existingSeq then
    local pending = ServerData._pending[existingSeq]
    if pending and callback then
      pending.callbacks[#pending.callbacks + 1] = callback
    end
    return existingSeq
  end

  -- Cache already exists?  No request needed.
  -- Caller (TooltipSync) MUST invalidate before fetch to force a refresh.
  if ServerData._cache[key] then
    return nil
  end

  -- Cache missing: send request
  local seq = ServerData._sendRequest(item, source, key)
  if not seq then return nil end

  -- Re-attach any callbacks rescued from the prior invalidated request for this key
  local pending = ServerData._pending[seq]
  if pending then
    local orphaned = ServerData._orphanedCallbacks[key]
    if orphaned then
      for _, cb in ipairs(orphaned) do
        pending.callbacks[#pending.callbacks + 1] = cb
      end
      ServerData._orphanedCallbacks[key] = nil
    end
    if callback then
      pending.callbacks[#pending.callbacks + 1] = callback
    end
  end

  return seq
end

-- Backward-compatible wrapper: derives source from widget, then calls fetch().
function ServerData.request(item, widget, renderer, posHelper)
  local source = getItemSource(item, widget)
  if not source then return nil end
  -- Wrap the UI-rebuild logic into a callback so transport stays UI-free
  local callback
  if widget and renderer and posHelper then
    local w, r, ph = widget, renderer, posHelper
    callback = function(parsed)
      if w:isHovered() and w:getItem() == item then
        pcall(function()
          r:rebuild(parsed)
          local mpos = g_window.getMousePosition()
          local sz = r:getSize()
          local fp = ph:getPosition(sz, mpos)
          r:setPosition(fp.x, fp.y)
          r:show()
          r:fadeIn(120)
        end)
      end
    end
  end
  return ServerData.fetch(item, source, callback)
end

-- ═══════════════════════════════════════════════════════════════
--  invalidateKey() — remove cache entry and cancel pending
-- ═══════════════════════════════════════════════════════════════
function ServerData.invalidateKey(key)
  if not key then return end
  -- Cancel pending request for this key, but rescue its callbacks
  local seq = ServerData._pendingByKey[key]
  if seq then
    local pending = ServerData._pending[seq]
    if pending then
      if pending.timer then
        removeEvent(pending.timer)
      end
      if pending.callbacks and #pending.callbacks > 0 then
        ServerData._orphanedCallbacks[key] = pending.callbacks
      end
    end
    ServerData._pending[seq] = nil
    ServerData._pendingByKey[key] = nil
  end
  -- Remove cache entry
  ServerData._cache[key] = nil
end

-- ═══════════════════════════════════════════════════════════════
--  _onResponse — handle opcode 205 response
-- ═══════════════════════════════════════════════════════════════
--  1. Consume pending entry
--  2. Deserialize data
--  3. Atomically replace cache entry
--  4. Invoke all callbacks
function ServerData._onResponse(seq, dataBuf)
  local pending = ServerData._pending[seq]
  if not pending then return end  -- stale response

  -- Cancel timeout
  if pending.timer then removeEvent(pending.timer) end

  -- Consume pending entry
  local key = pending.key
  ServerData._pending[seq] = nil
  if key then
    ServerData._pendingByKey[key] = nil
  end

  -- Verify item is still valid
  local item = pending.item
  if not item or item:getId() == 0 then return end

  -- Deserialize
  local parsed = ServerData._deserialize(dataBuf)
  if not parsed then return end  -- corrupt data

  -- Atomically replace cache entry (wrapped struct for future metadata), then invoke callbacks
  if key then
    parsed.header.icon = item
    ServerData._cache[key] = {
      data      = parsed,
      timestamp = g_clock.millis(),
      source    = pending.source and pending.source.type,
    }
  end

  local callbacks = pending.callbacks or {}
  for _, cb in ipairs(callbacks) do
    pcall(cb, parsed)
  end
end

-- ═══════════════════════════════════════════════════════════════
--  terminate — clear all state on logout/disconnect
-- ═══════════════════════════════════════════════════════════════
function ServerData.terminate()
  for _, p in pairs(ServerData._pending) do
    if p.timer then removeEvent(p.timer) end
  end
  ServerData._pending            = {}
  ServerData._pendingByKey       = {}
  ServerData._cache              = {}
  ServerData._orphanedCallbacks  = {}
  ServerData._requestSeq         = 0
  parsedTooltipCache             = {}
end

-- ═══════════════════════════════════════════════════════════════
--  TooltipSync — gameplay event observer
-- ═══════════════════════════════════════════════════════════════
--   Only responsibility: translate gameplay events into
--   TooltipCache.fetch() / invalidateKey() calls.
--   Never evaluates cache state, never owns callbacks.
-- ═══════════════════════════════════════════════════════════════
local TooltipSync = {}

function TooltipSync.init()
  TooltipSync._handlers = {
    onInventoryChange = function(player, slot, item, oldItem)
      if oldItem and oldItem:isItem() then
        -- Invalidate old cache entry on any change/removal
        ServerData.invalidateKey("INV:" .. slot .. ":" .. oldItem:getId())
      end
      if item and item:isItem() then
        -- Invalidate current key first so fetch() sees cache miss
        ServerData.invalidateKey("INV:" .. slot .. ":" .. item:getId())
        ServerData.fetch(item, { type = 1, slot = slot })
      end
    end,

    onContainerOpen = function(container, previousContainer)
      local cid = container:getId()
      for slot = 0, container:getItemsCount() - 1 do
        local item = container:getItem(slot)
        if item and item:isItem() then
          local key = "CONT:" .. cid .. ":" .. slot .. ":" .. item:getId()
          ServerData.invalidateKey(key)
          ServerData.fetch(item, { type = 2, containerId = cid, slot = slot })
        end
      end
    end,

    onContainerAddItem = function(container, slot, item, oldItem)
      if item and item:isItem() then
        local key = "CONT:" .. container:getId() .. ":" .. slot .. ":" .. item:getId()
        ServerData.invalidateKey(key)
        ServerData.fetch(item, { type = 2, containerId = container:getId(), slot = slot })
      end
    end,

    onContainerUpdateItem = function(container, slot, item, oldItem)
      if oldItem and oldItem:isItem() then
        ServerData.invalidateKey("CONT:" .. container:getId() .. ":" .. slot .. ":" .. oldItem:getId())
      end
      if item and item:isItem() then
        local key = "CONT:" .. container:getId() .. ":" .. slot .. ":" .. item:getId()
        ServerData.invalidateKey(key)
        ServerData.fetch(item, { type = 2, containerId = container:getId(), slot = slot })
      end
    end,

    onContainerRemoveItem = function(container, slot, item)
      if item and item:isItem() then
        ServerData.invalidateKey("CONT:" .. container:getId() .. ":" .. slot .. ":" .. item:getId())
      end
    end,
  }

  connect(LocalPlayer, {
    onInventoryChange = TooltipSync._handlers.onInventoryChange,
  })
  connect(Container, {
    onOpen          = TooltipSync._handlers.onContainerOpen,
    onAddItem       = TooltipSync._handlers.onContainerAddItem,
    onUpdateItem    = TooltipSync._handlers.onContainerUpdateItem,
    onRemoveItem    = TooltipSync._handlers.onContainerRemoveItem,
  })
end

function TooltipSync.terminate()
  disconnect(LocalPlayer, {
    onInventoryChange = TooltipSync._handlers.onInventoryChange,
  })
  disconnect(Container, {
    onOpen          = TooltipSync._handlers.onContainerOpen,
    onAddItem       = TooltipSync._handlers.onContainerAddItem,
    onUpdateItem    = TooltipSync._handlers.onContainerUpdateItem,
    onRemoveItem    = TooltipSync._handlers.onContainerRemoveItem,
  })
  TooltipSync._handlers = nil
end

-- Called by hover path: delegates to fetch() without any cache-state knowledge.
function TooltipSync.ensureSync(item, source, callback)
  return ServerData.fetch(item, source, callback)
end

-- ── Fallback tooltip builder (used when server doesn't send tooltip data) ──
local function buildFallbackTooltip(item)
  local name = item:getName()
  if not name or name == "" then
    name = "Item #" .. item:getId()
  end
  local desc = item:getDescription() or ""

  -- Parse description for stat rows, requirements, weight
  local statsRows, reqRows, weightOz, otherLines = parseDescription(desc)

  -- Build sections
  local sections = {}

  -- Stats section (from parsed description)
  if #statsRows > 0 then
    table.insert(sections, { name = nil, rows = statsRows })
  end

  -- Requirements section
  if #reqRows > 0 then
    table.insert(sections, { name = "Requirements", rows = reqRows })
  end

  -- Raw description lines that didn't match known patterns
  if #otherLines > 0 then
    local descRows = {}
    for _, line in ipairs(otherLines) do
      table.insert(descRows, { type = "stat", icon = nil, text = line })
    end
    table.insert(sections, { name = "Description", rows = descRows })
  end

  -- If nothing was parsed, don't show any extra sections
  -- (just header + footer is fine for simple items)

  -- Footer
  local footer = {}
  if weightOz then
    table.insert(footer, { label = "Weight", value = weightOz .. " oz" })
  end

  -- Count for stackable items
  local count = item:getCount()
  if count and count > 1 then
    table.insert(footer, { label = "Quantity", value = tostring(count) })
  end

  return {
    header = { icon = item, name = name, category = nil },
    sections = sections,
    footer = footer,
  }
end

function TooltipBuilder.build(item, cacheKey)
  if not item or not item:isItem() then return nil end
  if item:getId() == 0 then return nil end

  -- PRIORITY 1: OPC 205 response cache (keyed by stable source key)
  local entry = nil
  if cacheKey then
    entry = ServerData._cache[cacheKey]
  end
  if entry and entry.data then
    entry.data.header.icon = item
    return entry.data
  end

  -- PRIORITY 2: Item-packet tooltip data (getTooltipData — feat 93 path)
  local raw = item:getTooltipData()
  if raw and #raw > 0 then
    local p2key = cacheKey or ("RAW:" .. item:getId())
    local parsed = parsedTooltipCache[p2key]
    if parsed then
      parsed.header.icon = item
      return parsed
    end

    parsed = ServerData._deserialize(raw)
    if parsed then
      parsed.header.icon = item
      parsedTooltipCache[p2key] = parsed
      return parsed
    end
  end

  -- PRIORITY 3: Fallback (client-side, from item description)
  local result = buildFallbackTooltip(item)
  return result
end

-- ── Helper: Build position string for tooltip request ──
-- Returns "x,y,z,stackpos" for items on ground, in containers,
-- or in the player's inventory.
-- ═══════════════════════════════════════════════════════════════
-- 8.  ItemProvider – bridges hover events into the pipeline
-- ═══════════════════════════════════════════════════════════════
local ItemProvider = {}

function ItemProvider.new(renderer, animCtrl, posHelper)
  local self = {
    _renderer  = renderer,
    _animCtrl  = animCtrl,
    _posHelper = posHelper,
    _hoveredWidget    = nil,
    _mouseMoveHandler = nil,
  }
  setmetatable(self, { __index = ItemProvider })
  return self
end

function ItemProvider:onHoverChange(widget, hovered)
  if hovered then
    -- Cancel any pending hide from a previous unhover
    if self._hideEvent then
      removeEvent(self._hideEvent)
      self._hideEvent = nil
    end

    local item = widget:getItem()
    if item and item:isItem() and not item:isCreature() then
      self._hoveredWidget = widget

      -- Build tooltip with stable cache key (checks cache first, then fallback)
      local source = getItemSource(item, widget)
      local cacheKey = source and makeTooltipKey(source, item and item:getId()) or nil
      local data = TooltipBuilder.build(item, cacheKey)
      if data then
        pcall(function()
          self._renderer:rebuild(data)
          local mpos = g_window.getMousePosition()
          local sz = self._renderer:getSize()
          local fp = self._posHelper:getPosition(sz, mpos)
          self._renderer:setPosition(fp.x, fp.y)
          self._renderer:show()
          self._renderer:fadeIn(120)
        end)
      else
        self._renderer:hide()
      end

      -- Fetch on cache miss for ALL source types.
      -- Ground items have no TooltipSync events, so they must fetch here.
      -- Inventory/container items are prefetched by TooltipSync, but if the
      -- server response hasn't arrived yet, this attaches a callback so the
      -- tooltip updates when the data arrives (fixes race condition).
      if source and not ServerData._cache[cacheKey] then
        local widgetRef = widget
        local rendererRef = self._renderer
        local posHelperRef = self._posHelper
        ServerData.fetch(item, source, function(parsed)
          -- [STAGE CALLBACK] OPC-205 async callback fired
          local _cbName = parsed and parsed.header and parsed.header.name or "?"
          local _cbSecs = parsed and #(parsed.sections or {}) or 0
          local _cbFoot = parsed and #(parsed.footer or {}) or 0
          print("[STAGE CALLBACK] fired name='" .. _cbName .. "' sections=" .. _cbSecs .. " footer=" .. _cbFoot)
          for _ci, _cs in ipairs(parsed and parsed.sections or {}) do
            print("[STAGE CALLBACK]   section[" .. _ci .. "] name='" .. tostring(_cs.name) .. "' rows=" .. #(_cs.rows or {}))
          end
          local _cbHovered = widgetRef:isHovered()
          local _cbSameItem = widgetRef:getItem() == item
          print("[STAGE CALLBACK] hovered=" .. tostring(_cbHovered) .. " sameItem=" .. tostring(_cbSameItem))
          if _cbHovered and _cbSameItem then
            pcall(function()
              rendererRef:rebuild(parsed)
              local mpos = g_window.getMousePosition()
              local sz = rendererRef:getSize()
              local fp = posHelperRef:getPosition(sz, mpos)
              rendererRef:setPosition(fp.x, fp.y)
              rendererRef:show()
              rendererRef:fadeIn(120)
            end)
          end
        end)
      end

      -- Attach mouse-follow handler once
      if not self._mouseMoveHandler then
        self._mouseMoveHandler = function()
          pcall(function()
            if not self._renderer then return end
            local pnl = self._renderer._panel
            if not pnl then return end
            if pnl:isDestroyed() then return end
            if pnl:isHidden() then return end
            local mpos = g_window.getMousePosition()
            local psz = self._renderer:getSize()
            local fp = self._posHelper:getPosition(psz, mpos)
            self._renderer:setPosition(fp.x, fp.y)
          end)
        end
        connect(rootWidget, { onMouseMove = self._mouseMoveHandler })
      end
      return
    end
  end

  -- Hide on unhover (with short delay to prevent flickering during drag/move)
  if self._hoveredWidget == widget then
    if self._hideEvent then
      removeEvent(self._hideEvent)
      self._hideEvent = nil
    end
    self._hideEvent = addEvent(function()
      self._hideEvent = nil
      -- Double-check the widget is still not hovered (in case of re-hover)
      if self._hoveredWidget ~= nil then return end
      self._renderer:fadeOut(80)
      addEvent(function()
        pcall(function() self._renderer:hide() end)
      end, 100)
    end, 50)  -- 50ms delay before starting hide
    self._hoveredWidget = nil
  end
end

-- ═══════════════════════════════════════════════════════════════
-- 9.  Validation test – classification correctness checker
-- ═══════════════════════════════════════════════════════════════

-- Expected classifications for known items (itemId → { expectedClass, expectedName })
-- These are the authoritative ground truth for verification.
local TEST_ITEMS = {
  -- Weapons
  ["Sword"]          = { id = nil, expect = ITEM_WEAPON },
  ["Axe"]            = { id = nil, expect = ITEM_WEAPON },
  ["Club"]           = { id = nil, expect = ITEM_WEAPON },
  ["Bow"]            = { id = nil, expect = ITEM_WEAPON },
  ["Crossbow"]       = { id = nil, expect = ITEM_WEAPON },
  -- Shields
  ["Shield"]         = { id = nil, expect = ITEM_SHIELD },
  -- Armor
  ["Helmet"]         = { id = nil, expect = ITEM_ARMOR },
  ["Armor"]          = { id = nil, expect = ITEM_ARMOR },
  ["Legs"]           = { id = nil, expect = ITEM_ARMOR },
  ["Boots"]          = { id = nil, expect = ITEM_ARMOR },
  -- Jewelry
  ["Ring"]           = { id = nil, expect = ITEM_GENERIC },
  ["Amulet"]         = { id = nil, expect = ITEM_GENERIC },
  -- Containers
  ["Backpack"]       = { id = nil, expect = ITEM_CONTAINER },
  ["Bag"]            = { id = nil, expect = ITEM_CONTAINER },
  -- Consumables
  ["Rune"]           = { id = nil, expect = ITEM_RUNE },
  ["Potion"]         = { id = nil, expect = ITEM_FLUID },
  ["Food"]           = { id = nil, expect = ITEM_FOOD },
  -- Currency
  ["Gold Coin"]      = { id = nil, expect = ITEM_GENERIC },
  ["Crystal Coin"]   = { id = nil, expect = ITEM_GENERIC },
  -- Utility
  ["Key"]            = { id = nil, expect = ITEM_KEY },
}

local function validateClassifications()
  if not TOOLTIP_DEBUG then return end

  print("[game_tooltip] ╔══ Classification Validation ══╗")
  print("[game_tooltip] ║  Testing items via ThingType    ║")
  print("[game_tooltip] ╚══════════════════════════════════╝")

  -- We can only test items/things that exist in the loaded OTB/XML.
  -- This function checks whatever items the player can hover,
  -- plus a broader scan of OTB categories.
  -- For each OTB category (1-28), print the classification mapping.
  print("[game_tooltip] --- OTB Category Mappings ---")
  for cat = 1, 28 do
    local catName = TTCAT_NAMES[cat] or ("Unknown(" .. cat .. ")")
    local mapped = TTCAT_TO_CLASS[cat]
    local clsName = CLASS_NAMES[mapped] or "nil"
    print("[game_tooltip]   Cat " .. tostring(cat) .. " (" .. catName .. ") → " .. clsName)
  end

  print("[game_tooltip] --- Equipment Slot Mappings ---")
  for slot = 1, 9 do
    local slotName = SLOT_NAMES[slot] or ("Slot" .. tostring(slot))
    local mapped = SLOT_TO_CLASS[slot]
    local clsName = CLASS_NAMES[mapped] or "nil"
    print("[game_tooltip]   Slot " .. tostring(slot) .. " (" .. slotName .. ") → " .. clsName)
  end

  print("[game_tooltip] --- MarketData Category Mappings ---")
  for cat = 1, 14 do
    local catName = MD_CATEGORY_NAMES[cat] or ("Unknown(" .. cat .. ")")
    local mapped = MD_TO_CLASS[cat]
    local clsName = CLASS_NAMES[mapped] or "nil"
    print("[game_tooltip]   MD Cat " .. tostring(cat) .. " (" .. catName .. ") → " .. clsName)
  end

  print("[game_tooltip] ═══ End Classification Validation ═══")
end

-- ═══════════════════════════════════════════════════════════════
-- 10.  Module entry point
-- ═══════════════════════════════════════════════════════════════
-- ═══════════════════════════════════════════════════════════════
-- ServerData – manages server-authoritative tooltip data
-- ═══════════════════════════════════════════════════════════════════════
-- 10.  ServerData – server-authoritative tooltip data
-- ──────────────────────────────────────────────────────────────────────
-- Receives structured binary tooltip data from the server
-- (via extended opcode 205) and caches it for TooltipBuilder.
--
-- Priority: Server Data > Client Providers (fallback)
-- ═══════════════════════════════════════════════════════════════════════

-- Binary deserializer helpers
local function _readU8(data, pos)
  local v = string.byte(data, pos)
  if not v then return nil, pos end
  return v, pos + 1
end
local function _readU16LE(data, pos)
  local lo = string.byte(data, pos)
  local hi = string.byte(data, pos + 1)
  if not lo or not hi then return nil, pos end
  return lo + hi * 256, pos + 2
end
local function _readU32LE(data, pos)
  local b1 = string.byte(data, pos)
  local b2 = string.byte(data, pos + 1)
  local b3 = string.byte(data, pos + 2)
  local b4 = string.byte(data, pos + 3)
  if not b1 or not b2 or not b3 or not b4 then return nil, pos end
  return b1 + b2*256 + b3*65536 + b4*16777216, pos + 4
end
local function _readS32LE(data, pos)
  local u, p = _readU32LE(data, pos)
  if not u then return nil, pos end
  if u >= 0x80000000 then return u - 0x100000000, p end
  return u, p
end
local function _readS16LE(data, pos)
  local u, p = _readU16LE(data, pos)
  if not u then return nil, pos end
  if u >= 0x8000 then return u - 0x10000, p end
  return u, p
end
local function _readS8(data, pos)
  local u, p = _readU8(data, pos)
  if not u then return nil, pos end
  if u >= 0x80 then return u - 0x100, p end
  return u, p
end
local function _readStr16(data, pos)
  local len, p = _readU16LE(data, pos)
  if not len then return nil, pos end
  if len == 0 then return "", p end
  return string.sub(data, p, p + len - 1), p + len
end

-- Tags (must match tooltipbuilder.h on server)
local ST = {
  END=0, NAME=1, ARTICLE=2, CATEGORY=4, RARITY=5,
  ATTACK=6, DEFENSE=7, EXTRADEFENSE=8, ARMOR=9,
  ELEMENT_DAMAGE=10, ELEMENT_TYPE=11, HITCHANCE=12, SHOOTRANGE=13,
  ATTACK_SPEED=14, SLOT_POSITION=15, WEAPON_TYPE=16,
  LEVEL_REQ=17, MAGLEVEL_REQ=18, VOCATION_STRING=19,
  CHARGES=20, FLUID_TYPE=21, DURATION=22, DECAYING=23,
  CONTAINER_CAP=24, WEIGHT=25, LIGHT_LEVEL=26, LIGHT_COLOR=27,
  SPEED=28, MANASHIELD=29, INVISIBLE=30,
  HEALTH_GAIN=31, HEALTH_TICKS=32, MANA_GAIN=33, MANA_TICKS=34,
  SPECIAL_DESC=35, WRITTEN_TEXT=36, WRITTEN_BY=37, WRITTEN_DATE=38, DESCRIPTION=39,
  MAGIC_POINTS=60, MAGIC_POINTS_PCT=61,
  ABSORB_PHYSICAL=62, ABSORB_ENERGY=63, ABSORB_FIRE=64,
  ABSORB_POISON=65, ABSORB_ICE=66, ABSORB_HOLY=67, ABSORB_DEATH=68,
  ABSORB_LIFEDRAIN=69, ABSORB_MANADRAIN=70, ABSORB_DROWN=71,
  ABSORB_HEALING=72, ABSORB_ELEMENTS=73, ABSORB_MAGIC=74,
  CRIT_HIT_CHANCE=76, CRIT_HIT_AMOUNT=77,
  LIFE_LEECH_CHANCE=78, LIFE_LEECH_AMOUNT=79,
  MANA_LEECH_CHANCE=80, MANA_LEECH_AMOUNT=81,
  RUNE_SPELL_NAME=82, NPC_BUY_PRICE=83, NPC_SELL_PRICE=84,
  SECTIONS=86, FOOTER=87,
}

-- Note: ServerData is already initialized at the module top.
-- Do NOT reassign it here — that would wipe _cache, _pending, request, _onResponse, etc.
-- ServerData = {} -- REMOVED: was destroying the state table

-- Safety limits for deserialization (prevent DoS via crafted server responses)
local MAX_SECTIONS = 20
local MAX_ROWS_PER_SECTION = 30
local MAX_FOOTER_ITEMS = 10
local MAX_STRING_LENGTH = 65535

-- Tag name lookup for [RX] logging
local _RX_NAMES = {
  [0]="END",[1]="NAME",[2]="ARTICLE",[4]="CATEGORY",[5]="RARITY",
  [6]="ATTACK",[7]="DEFENSE",[8]="EXTRADEFENSE",[9]="ARMOR",
  [10]="ELEMENT_DAMAGE",[11]="ELEMENT_TYPE",[12]="HITCHANCE",[13]="SHOOTRANGE",
  [14]="ATTACK_SPEED",[15]="SLOT_POSITION",[16]="WEAPON_TYPE",
  [17]="LEVEL_REQ",[18]="MAGLEVEL_REQ",[19]="VOCATION_STRING",
  [20]="CHARGES",[21]="FLUID_TYPE",[22]="DURATION",[23]="DECAYING",
  [24]="CONTAINER_CAP",[25]="WEIGHT",
  [26]="LIGHT_LEVEL",[27]="LIGHT_COLOR",[28]="SPEED",
  [29]="MANASHIELD",[30]="INVISIBLE",
  [31]="HEALTH_GAIN",[32]="HEALTH_TICKS",[33]="MANA_GAIN",[34]="MANA_TICKS",
  [35]="SPECIAL_DESC",[36]="WRITTEN_TEXT",[37]="WRITTEN_BY",[38]="WRITTEN_DATE",
  [39]="DESCRIPTION",
  [40]="FIST",[41]="CLUB",[42]="SWORD",[43]="AXE",[44]="DISTANCE",
  [45]="SHIELDING",[46]="FISHING",
  [60]="MAGIC_POINTS",[61]="MAGIC_POINTS_PCT",
  [62]="ABSORB_PHYSICAL",[63]="ABSORB_ENERGY",[64]="ABSORB_FIRE",
  [65]="ABSORB_POISON",[66]="ABSORB_ICE",[67]="ABSORB_HOLY",[68]="ABSORB_DEATH",
  [69]="ABSORB_LIFEDRAIN",[70]="ABSORB_MANADRAIN",[71]="ABSORB_DROWN",
  [72]="ABSORB_HEALING",[73]="ABSORB_ELEMENTS",[74]="ABSORB_MAGIC",
  [76]="CRIT_HIT_CHANCE",[77]="CRIT_HIT_AMOUNT",
  [78]="LIFE_LEECH_CHANCE",[79]="LIFE_LEECH_AMOUNT",
  [80]="MANA_LEECH_CHANCE",[81]="MANA_LEECH_AMOUNT",
  [82]="RUNE_SPELL_NAME",[83]="NPC_BUY_PRICE",[84]="NPC_SELL_PRICE",
  [86]="SECTIONS",[87]="FOOTER",
}
local function _rxLog(before, tag, ptype, pbytes, after, val)
  if not TOOLTIP_DEBUG then return end
  local name = _RX_NAMES[tag] or ("UNKNOWN("..tostring(tag)..")")
  local vs = ""
  if val ~= nil then vs = " value=" .. tostring(val) end
  print("[RX] offset=" .. tostring(before) .. " tag=" .. tostring(tag) .. " name=" .. name .. " type=" .. ptype .. " bytes=" .. tostring(pbytes) .. " offsetAfter=" .. tostring(after) .. vs)
end

function ServerData._deserialize(data)
  if TOOLTIP_DEBUG then print("[DES] ENTER dataLen=" .. tostring(#data)) end
  if not data or #data < 4 then
    if TOOLTIP_DEBUG then print("[DES] EARLY RETURN: data too short, len=" .. tostring(#data)) end
    return nil
  end
  local pos = 1
  local v, p = _readU8(data, pos); if not v then if TOOLTIP_DEBUG then print("[DES] truncated version") end; return nil end; pos = p
  if TOOLTIP_DEBUG then print("[DES] version=" .. tostring(v)) end
  if v ~= 1 then
    if TOOLTIP_DEBUG then print("[DES] EARLY RETURN: bad version " .. tostring(v)) end
    return nil
  end
  local itemId, p = _readU16LE(data, pos); if not itemId then if TOOLTIP_DEBUG then print("[DES] truncated itemId") end; return nil end; pos = p
  if TOOLTIP_DEBUG then print("[DES] itemId=" .. tostring(itemId)) end
  local displayName, p = _readStr16(data, pos); if not displayName then if TOOLTIP_DEBUG then print("[DES] truncated name") end; return nil end; pos = p
  if TOOLTIP_DEBUG then print("[DES] displayName='" .. tostring(displayName) .. "' pos=" .. tostring(pos)) end
  local categoryIdx, p = _readU8(data, pos); if not categoryIdx then if TOOLTIP_DEBUG then print("[DES] truncated category") end; return nil end; pos = p
  if TOOLTIP_DEBUG then print("[DES] categoryIdx=" .. tostring(categoryIdx) .. " pos=" .. tostring(pos)) end

  local scalars = {}
  local tlvIterations = 0
  while pos <= #data do
    tlvIterations = tlvIterations + 1
    if tlvIterations > 200 then if TOOLTIP_DEBUG then print("[DES] TLV iteration limit reached") end; break end
    local rx_before = pos
    local tag, p = _readU8(data, pos); if not tag then if TOOLTIP_DEBUG then print("[DES] truncated tag, aborting") end; break end; pos = p
    if tag == ST.END then
      _rxLog(rx_before, tag, "end", 1, pos)
      break
    end
    if tag == ST.NAME or tag == ST.ARTICLE or tag == ST.VOCATION_STRING
        or tag == ST.SPECIAL_DESC or tag == ST.WRITTEN_TEXT
        or tag == ST.WRITTEN_BY or tag == ST.RUNE_SPELL_NAME
        or tag == ST.DESCRIPTION then
      local s, np = _readStr16(data, pos); if not s then if TOOLTIP_DEBUG then print("[DES] truncated string, aborting") end; return nil end; scalars[tag] = s; pos = np
      _rxLog(rx_before, tag, "string", #s + 2, pos, s)
    elseif tag == ST.SECTIONS then
      local rx_before_sc = pos
      local sc, np = _readU16LE(data, pos); if not sc then if TOOLTIP_DEBUG then print("[DES] truncated section count") end; return nil end; pos = np
      if sc > MAX_SECTIONS then if TOOLTIP_DEBUG then print("[DES] section count " .. tostring(sc) .. " exceeds max " .. tostring(MAX_SECTIONS)) end; sc = MAX_SECTIONS end
      local sections = {}
      for _ = 1, sc do
        local sn, sp = _readStr16(data, pos); if not sn then if TOOLTIP_DEBUG then print("[DES] truncated section name") end; return nil end; pos = sp
        local rc, rp = _readU16LE(data, pos); if not rc then if TOOLTIP_DEBUG then print("[DES] truncated row count") end; return nil end; pos = rp
        if rc > MAX_ROWS_PER_SECTION then if TOOLTIP_DEBUG then print("[DES] row count " .. tostring(rc) .. " exceeds max " .. tostring(MAX_ROWS_PER_SECTION)) end; rc = MAX_ROWS_PER_SECTION end
        local rows = {}
        for _ = 1, rc do
          local rt, rr = _readU8(data, pos); if not rt then if TOOLTIP_DEBUG then print("[DES] truncated row type") end; return nil end; pos = rr
          local ic, ir = _readU8(data, pos); if not ic then if TOOLTIP_DEBUG then print("[DES] truncated icon") end; return nil end; pos = ir
          local lb, lr = _readStr16(data, pos); if not lb then if TOOLTIP_DEBUG then print("[DES] truncated label") end; return nil end; pos = lr
          local vl, vr = _readStr16(data, pos); if not vl then if TOOLTIP_DEBUG then print("[DES] truncated value") end; return nil end; pos = vr
          local cl, cr = _readU32LE(data, pos); if not cl then if TOOLTIP_DEBUG then print("[DES] truncated color") end; return nil end; pos = cr
          local colorStr = nil
          if cl ~= 0 and cl <= 0xFFFFFF then colorStr = string.format("#%06x", cl)
          elseif cl ~= 0 then colorStr = string.format("#%06x", cl % 0x1000000) end
          table.insert(rows, { type = (rt == 1) and "label-value" or "stat",
            icon = (ic == 1) and "diamond" or (ic == 2) and "dot" or (ic == 3) and "star" or nil,
            text = (vl ~= "") and vl or lb, label = lb, value = vl, color = colorStr })
        end
        table.insert(sections, { name = sn, rows = rows })
      end
      scalars[tag] = sections
      _rxLog(rx_before, tag, "section", pos - rx_before - 1, pos)
    elseif tag == ST.FOOTER then
      local fc, np = _readU16LE(data, pos); if not fc then if TOOLTIP_DEBUG then print("[DES] truncated footer count") end; return nil end; pos = np
      if fc > MAX_FOOTER_ITEMS then if TOOLTIP_DEBUG then print("[DES] footer count " .. tostring(fc) .. " exceeds max " .. tostring(MAX_FOOTER_ITEMS)) end; fc = MAX_FOOTER_ITEMS end
      local footer = {}
      for _ = 1, fc do
        local lb, lp = _readStr16(data, pos); if not lb then if TOOLTIP_DEBUG then print("[DES] truncated footer label") end; return nil end; pos = lp
        local vl, vp = _readStr16(data, pos); if not vl then if TOOLTIP_DEBUG then print("[DES] truncated footer value") end; return nil end; pos = vp
        table.insert(footer, { label = lb, value = vl })
      end
      scalars[tag] = footer
      _rxLog(rx_before, tag, "footer", pos - rx_before - 1, pos)
    elseif tag == ST.ATTACK or tag == ST.DEFENSE or tag == ST.EXTRADEFENSE
        or tag == ST.ARMOR or tag == ST.ATTACK_SPEED
        or tag == ST.LEVEL_REQ or tag == ST.MAGLEVEL_REQ
        or tag == ST.SLOT_POSITION or tag == ST.SPEED
        or tag == ST.HEALTH_GAIN or tag == ST.HEALTH_TICKS
        or tag == ST.MANA_GAIN or tag == ST.MANA_TICKS
        or tag == ST.MAGIC_POINTS or tag == ST.MAGIC_POINTS_PCT
        or tag == ST.CRIT_HIT_CHANCE or tag == ST.CRIT_HIT_AMOUNT
        or tag == ST.LIFE_LEECH_CHANCE or tag == ST.LIFE_LEECH_AMOUNT
        or tag == ST.MANA_LEECH_CHANCE or tag == ST.MANA_LEECH_AMOUNT
        or tag == ST.WRITTEN_DATE then
      local val, np = _readS32LE(data, pos); if not val then if TOOLTIP_DEBUG then print("[DES] truncated s32") end; return nil end; scalars[tag] = val; pos = np
      _rxLog(rx_before, tag, "s32", 4, pos, val)
    elseif tag == ST.DURATION then
      local val, np = _readU32LE(data, pos); if not val then if TOOLTIP_DEBUG then print("[DES] truncated u32") end; return nil end; scalars[tag] = val; pos = np
      _rxLog(rx_before, tag, "u32", 4, pos, val)
    elseif tag == ST.CHARGES or tag == ST.CONTAINER_CAP then
      local val, np = _readU16LE(data, pos); if not val then if TOOLTIP_DEBUG then print("[DES] truncated u16") end; return nil end; scalars[tag] = val; pos = np
      _rxLog(rx_before, tag, "u16", 2, pos, val)
    elseif tag == ST.WEIGHT then
      local val, np = _readU32LE(data, pos); if not val then if TOOLTIP_DEBUG then print("[DES] truncated u32") end; return nil end; scalars[tag] = val; pos = np
      _rxLog(rx_before, tag, "u32", 4, pos, val)
    elseif (tag >= ST.ABSORB_PHYSICAL and tag <= ST.ABSORB_MAGIC) or tag == ST.ELEMENT_DAMAGE then
      local val, np = _readS16LE(data, pos); if not val then if TOOLTIP_DEBUG then print("[DES] truncated s16") end; return nil end; scalars[tag] = val; pos = np
      _rxLog(rx_before, tag, "s16", 2, pos, val)
    elseif tag == ST.CATEGORY or tag == ST.RARITY
        or tag == ST.FLUID_TYPE or tag == ST.WEAPON_TYPE
        or tag == ST.SHOOTRANGE or tag == ST.LIGHT_LEVEL or tag == ST.LIGHT_COLOR then
      local val, np = _readU8(data, pos); if not val then if TOOLTIP_DEBUG then print("[DES] truncated u8") end; return nil end; scalars[tag] = val; pos = np
      _rxLog(rx_before, tag, "u8", 1, pos, val)
    elseif tag == ST.ELEMENT_TYPE then
      local val, np = _readU16LE(data, pos); if not val then if TOOLTIP_DEBUG then print("[DES] truncated u16") end; return nil end; scalars[tag] = val; pos = np
      _rxLog(rx_before, tag, "u16", 2, pos, val)
    elseif tag == ST.HITCHANCE then
      local val, np = _readS8(data, pos); if not val then if TOOLTIP_DEBUG then print("[DES] truncated s8") end; return nil end; scalars[tag] = val; pos = np
      _rxLog(rx_before, tag, "s8", 1, pos, val)
    elseif tag == ST.DECAYING or tag == ST.MANASHIELD or tag == ST.INVISIBLE then
      local val, np = _readU8(data, pos); if not val then if TOOLTIP_DEBUG then print("[DES] truncated bool") end; return nil end; scalars[tag] = (val ~= 0); pos = np
      _rxLog(rx_before, tag, "bool", 1, pos, val ~= 0)
    elseif tag >= 39 and tag <= 49 then
      local val, np = _readS32LE(data, pos); if not val then if TOOLTIP_DEBUG then print("[DES] truncated skill") end; return nil end; scalars[tag] = val; pos = np
      _rxLog(rx_before, tag, "skill(s32)", 4, pos, val)
    else
      _rxLog(rx_before, tag, "UNKNOWN", 0, pos)
      pos = pos + 1
      break
    end
  end

  if TOOLTIP_DEBUG then
    print("[game_tooltip] ║  --- All decoded scalar fields ---")
    for k, v in pairs(scalars) do
      local kname = "?"
      for tagname, tagval in pairs(ST) do
        if tagval == k then kname = tagname; break end
      end
      if type(v) == "table" then
        print("[game_tooltip] ║    " .. kname .. " (" .. tostring(k) .. ") = table[" .. tostring(#v) .. "]")
      else
        print("[game_tooltip] ║    " .. kname .. " (" .. tostring(k) .. ") = " .. tostring(v))
      end
    end
    print("[game_tooltip] ╚═══════════════════════════════════════╝")
  end

  -- Build TooltipData (flat format for renderer)
  -- Map server category index to display name
  local catNames = { [1]="Weapon", [2]="Armor", [3]="Shield", [4]="Ring", [5]="Amulet", [6]="Rune", [7]="Container", [8]="Fluid", [9]="Ammo", [10]="Generic" }
  local result = { header = { icon = nil, name = displayName, category = catNames[categoryIdx] }, sections = {}, footer = {}, _meta = { itemId = itemId, server = true } }

  -- Use server sections if available
  local sectionsFromServer = false
  if scalars[ST.SECTIONS] then
    sectionsFromServer = true
    for _, sec in ipairs(scalars[ST.SECTIONS]) do table.insert(result.sections, sec) end
  end
  if scalars[ST.FOOTER] then
    result.footer = scalars[ST.FOOTER]
  end

  -- Build minimal sections from scalar fields if no sections received
  if #result.sections == 0 then
    local sr = {}
    local function as(t)
      table.insert(sr, { type="stat", icon="diamond", text=t })
    end
    if scalars[ST.ATTACK] and scalars[ST.ATTACK] ~= 0 then as(tostring(scalars[ST.ATTACK]) .. " Atk") end
    if scalars[ST.DEFENSE] and scalars[ST.DEFENSE] ~= 0 then
      local d = tostring(scalars[ST.DEFENSE])
      if scalars[ST.EXTRADEFENSE] and scalars[ST.EXTRADEFENSE] ~= 0 then d = d .. " (" .. tostring(scalars[ST.EXTRADEFENSE]) .. ")" end
      as(d .. " Def")
    end
    if scalars[ST.ARMOR] and scalars[ST.ARMOR] ~= 0 then as(tostring(scalars[ST.ARMOR]) .. " Armor") end
    if scalars[ST.ELEMENT_DAMAGE] and scalars[ST.ELEMENT_DAMAGE] ~= 0 then
      local _combatToElem = {[1]="Physical",[2]="Energy",[4]="Earth",[8]="Fire",[16]="Undefined",[32]="Life Drain",[64]="Mana Drain",[128]="Healing",[256]="Drown",[512]="Ice",[1024]="Holy",[2048]="Death"}
      local en = _combatToElem[scalars[ST.ELEMENT_TYPE] or 0] or "Unknown"
      as(tostring(scalars[ST.ELEMENT_DAMAGE]) .. " " .. en)
    end
    if scalars[ST.HITCHANCE] and scalars[ST.HITCHANCE] ~= 0 then as("Hit Chance " .. tostring(scalars[ST.HITCHANCE]) .. "%") end
    if scalars[ST.SHOOTRANGE] and scalars[ST.SHOOTRANGE] > 0 then as("Range: " .. tostring(scalars[ST.SHOOTRANGE])) end
    if scalars[ST.CHARGES] and scalars[ST.CHARGES] > 0 then as("Charges: " .. tostring(scalars[ST.CHARGES])) end
    -- Light rows intentionally omitted from tooltip display
    if #sr > 0 then
      table.insert(result.sections, { name = "Base Stats", rows = sr })
    end

    -- Build scalar-derived sections (always runs, regardless of SECTIONS presence)
    local ar = {}
    if scalars[ST.SPEED] and scalars[ST.SPEED] ~= 0 then table.insert(ar, { type="stat", icon="diamond", text="Speed " .. ((scalars[ST.SPEED] > 0) and "+" or "") .. tostring(scalars[ST.SPEED]) }) end
    if scalars[ST.MAGIC_POINTS] and scalars[ST.MAGIC_POINTS] ~= 0 then table.insert(ar, { type="stat", icon="diamond", text="Magic Level " .. ((scalars[ST.MAGIC_POINTS] > 0) and "+" or "") .. tostring(scalars[ST.MAGIC_POINTS]) }) end
    if scalars[ST.MANASHIELD] then table.insert(ar, { type="stat", icon="diamond", text="Mana Shield" }) end
    if scalars[ST.INVISIBLE] then table.insert(ar, { type="stat", icon="diamond", text="Invisible" }) end
    if scalars[ST.HEALTH_GAIN] and scalars[ST.HEALTH_GAIN] > 0 and scalars[ST.HEALTH_TICKS] and scalars[ST.HEALTH_TICKS] > 0 then table.insert(ar, { type="stat", icon="diamond", text="Regen " .. tostring(scalars[ST.HEALTH_GAIN]) .. " HP / " .. tostring(math.floor(scalars[ST.HEALTH_TICKS]/1000)) .. "s" }) end
    if scalars[ST.MANA_GAIN] and scalars[ST.MANA_GAIN] > 0 and scalars[ST.MANA_TICKS] and scalars[ST.MANA_TICKS] > 0 then table.insert(ar, { type="stat", icon="diamond", text="Regen " .. tostring(scalars[ST.MANA_GAIN]) .. " MP / " .. tostring(math.floor(scalars[ST.MANA_TICKS]/1000)) .. "s" }) end
    for tag = 39, 49 do
      if scalars[tag] and scalars[tag] ~= 0 then
        local sn = ({ [39]="Fist",[40]="Club",[41]="Sword",[42]="Axe",[43]="Distance",[44]="Shielding",[45]="Fishing" })[tag] or ("Skill" .. tostring(tag-38))
        table.insert(ar, { type="stat", icon="diamond", text=sn .. " " .. ((scalars[tag] > 0) and "+" or "") .. tostring(scalars[tag]) })
      end
    end
    if scalars[ST.CRIT_HIT_CHANCE] and scalars[ST.CRIT_HIT_CHANCE] ~= 0 then
      table.insert(ar, { type="stat", icon="diamond", text="Critical " .. tostring(scalars[ST.CRIT_HIT_CHANCE]) .. "% chance (" .. tostring(scalars[ST.CRIT_HIT_AMOUNT] or 0) .. "% dmg)" })
    end
    if scalars[ST.LIFE_LEECH_CHANCE] and scalars[ST.LIFE_LEECH_CHANCE] ~= 0 then
      table.insert(ar, { type="stat", icon="diamond", text="Life Leech " .. tostring(scalars[ST.LIFE_LEECH_CHANCE]) .. "% (" .. tostring(scalars[ST.LIFE_LEECH_AMOUNT] or 0) .. ")" })
    end
    if scalars[ST.MANA_LEECH_CHANCE] and scalars[ST.MANA_LEECH_CHANCE] ~= 0 then
      table.insert(ar, { type="stat", icon="diamond", text="Mana Leech " .. tostring(scalars[ST.MANA_LEECH_CHANCE]) .. "% (" .. tostring(scalars[ST.MANA_LEECH_AMOUNT] or 0) .. ")" })
    end
    local absorbTexts, absorbMap = {}, { [ST.ABSORB_PHYSICAL]="Physical", [ST.ABSORB_ENERGY]="Energy", [ST.ABSORB_FIRE]="Fire", [ST.ABSORB_POISON]="Poison", [ST.ABSORB_ICE]="Ice", [ST.ABSORB_HOLY]="Holy", [ST.ABSORB_DEATH]="Death" }
    for atag, aname in pairs(absorbMap) do if scalars[atag] and scalars[atag] ~= 0 then table.insert(absorbTexts, tostring(scalars[atag]) .. "% " .. aname) end end
    if #absorbTexts > 0 then table.insert(ar, { type="stat", icon="diamond", text="Protection " .. table.concat(absorbTexts, ", ") }) end
    if #ar > 0 then
      table.insert(result.sections, { name = "Abilities", rows = ar })
    end

    local rr = {}
    if scalars[ST.LEVEL_REQ] and scalars[ST.LEVEL_REQ] > 0 then table.insert(rr, { type="stat", icon="diamond", text="Level Required: " .. tostring(scalars[ST.LEVEL_REQ]) }) end
    if scalars[ST.MAGLEVEL_REQ] and scalars[ST.MAGLEVEL_REQ] > 0 then table.insert(rr, { type="stat", icon="diamond", text="Magic Level Required: " .. tostring(scalars[ST.MAGLEVEL_REQ]) }) end
    if scalars[ST.VOCATION_STRING] and scalars[ST.VOCATION_STRING] ~= "" then table.insert(rr, { type="stat", icon="diamond", text="Vocation: " .. scalars[ST.VOCATION_STRING] }) end
    if #rr > 0 then
      table.insert(result.sections, { name = "Requirements", rows = rr })
    end

    local dr = {}
    if scalars[ST.DESCRIPTION] and scalars[ST.DESCRIPTION] ~= "" then table.insert(dr, { type="stat", icon="diamond", text=scalars[ST.DESCRIPTION] }) end
    if scalars[ST.WRITTEN_TEXT] and scalars[ST.WRITTEN_TEXT] ~= "" then table.insert(dr, { type="stat", icon="diamond", text=scalars[ST.WRITTEN_TEXT] }) end
    if scalars[ST.SPECIAL_DESC] and scalars[ST.SPECIAL_DESC] ~= "" then table.insert(dr, { type="stat", icon="diamond", text=scalars[ST.SPECIAL_DESC] }) end
    if #dr > 0 then
      table.insert(result.sections, { name = "Description", rows = dr })
    end

    if scalars[ST.RUNE_SPELL_NAME] and scalars[ST.RUNE_SPELL_NAME] ~= "" then
      local rur = {}
      table.insert(rur, { type="stat", icon="diamond", text="Spell: " .. scalars[ST.RUNE_SPELL_NAME] })
      if scalars[ST.LEVEL_REQ] and scalars[ST.LEVEL_REQ] > 0 then table.insert(rur, { type="stat", icon="diamond", text="Level Required: " .. tostring(scalars[ST.LEVEL_REQ]) }) end
      if scalars[ST.MAGLEVEL_REQ] and scalars[ST.MAGLEVEL_REQ] > 0 then table.insert(rur, { type="stat", icon="diamond", text="Magic Level Required: " .. tostring(scalars[ST.MAGLEVEL_REQ]) }) end
      if scalars[ST.CHARGES] and scalars[ST.CHARGES] > 0 then table.insert(rur, { type="stat", icon="diamond", text="Charges: " .. tostring(scalars[ST.CHARGES]) }) end
      table.insert(result.sections, { name = "Rune", rows = rur })
    end
    if scalars[ST.CONTAINER_CAP] and scalars[ST.CONTAINER_CAP] > 0 then
      table.insert(result.sections, { name = "Container", rows = { { type="stat", icon="diamond", text="Capacity: " .. tostring(scalars[ST.CONTAINER_CAP]) .. " slots" } } })
    end
  end

  -- Only add scalar Weight/Duration to footer if server did NOT send TAG_FOOTER
  if not scalars[ST.FOOTER] then
    if scalars[ST.WEIGHT] and scalars[ST.WEIGHT] > 0 then
      table.insert(result.footer, 1, { label="Weight", value=string.format("%.2f oz", scalars[ST.WEIGHT]/100.0) })
    end
    if scalars[ST.DURATION] and scalars[ST.DURATION] > 0 then
    local d = scalars[ST.DURATION]  -- seconds
    local ds
    if d < 60 then
      ds = tostring(d) .. "s"
    elseif d < 3600 then
      local m = math.floor(d / 60)
      local s = d % 60
      if s > 0 then
        ds = tostring(m) .. "m " .. tostring(s) .. "s"
      else
        ds = tostring(m) .. "m"
      end
    elseif d < 86400 then
      local h = math.floor(d / 3600)
      local m = math.floor((d % 3600) / 60)
      if m > 0 then
        ds = tostring(h) .. "h " .. tostring(m) .. "m"
      else
        ds = tostring(h) .. "h"
      end
    else
      local days = math.floor(d / 86400)
      local h = math.floor((d % 86400) / 3600)
      if h > 0 then
        ds = tostring(days) .. "d " .. tostring(h) .. "h"
      else
        ds = tostring(days) .. "d"
      end
    end
    table.insert(result.footer, { label="Duration", value=ds })
  end
  end  -- end: not scalars[ST.FOOTER]
  return result
end

-- ═══════════════════════════════════════════════════════════════
-- 11.  Module entry point
-- ═══════════════════════════════════════════════════════════════
local renderer
local posHelper
local provider

function init()
  g_ui.importStyle('/modules/game_tooltip/styles')

  if not loadThingsData() then
    local origOnLoadOtb = g_things.onLoadOtb
    g_things.onLoadOtb = function(file)
      if origOnLoadOtb then origOnLoadOtb(file) end
      loadThingsData()
    end
    local origOnLoadDat = g_things.onLoadDat
    g_things.onLoadDat = function(file)
      if origOnLoadDat then origOnLoadDat(file) end
      loadThingsData()
    end
  end

  renderer  = TooltipRenderer.new()
  posHelper = PositionHelper.new()
  provider  = ItemProvider.new(renderer, nil, posHelper)

  UIItem.onHoverChange = function(self, hovered)
    provider:onHoverChange(self, hovered)
  end

  -- Register OPC 205 handler for tooltip responses
  local ok, err = pcall(ProtocolGame.registerExtendedOpcode, 205,
    function(protocol, opcode, buffer)
      if #buffer < 2 then return end
      local seq, nextPos = _readU16LE(buffer, 1)
      local _rxPayload = buffer:sub(nextPos)
      ServerData._onResponse(seq, _rxPayload)
    end
  )
  if not ok then
    print("[game_tooltip] Failed to register opcode 205: " .. tostring(err))
  end

  -- Hook gameplay events for proactive synchronization
  TooltipSync.init()

  -- Cleanup on game end (logout, disconnect, reconnect)
  connect(g_game, {
    onGameEnd = ServerData.terminate,
  })

  print("game_tooltip: loaded")
end

function terminate()
  TooltipSync.terminate()
  ServerData.terminate()
  if provider and provider._mouseMoveHandler then
    pcall(disconnect, rootWidget, { onMouseMove = provider._mouseMoveHandler })
    provider._mouseMoveHandler = nil
  end
  if renderer then renderer:destroy(); renderer = nil end
  provider = nil
  posHelper = nil
  UIItem.onHoverChange = nil
  if g_things.onLoadOtb then g_things.onLoadOtb = nil end
  if g_things.onLoadDat then g_things.onLoadDat = nil end
  otbLoaded = false
  xmlLoaded = false
  disconnect(g_game, {
    onGameEnd = ServerData.terminate,
  })
  print("game_tooltip: unloaded")
end
