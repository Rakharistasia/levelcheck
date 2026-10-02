--[[
  LevelCheck - gear level-requirement scanner for EQ Might (or any EQEmu server)

  Scans worn gear, bags, bank and shared bank (plus augments inside items)
  for Required Level and Recommended Level, then flags anything you could
  not use after deleveling to a target level (default 51).

  Install:  <MacroQuest>/lua/levelcheck/init.lua

  Usage:
    /lua run levelcheck          scan this character and open the window
    /lua run levelcheck scan     scan this character, save, and exit (no UI)
    /levelcheck scan             rescan this character (window running)
    /levelcheck scanall          ask every DanNet box to scan (needs MQ2DanNet)
    /levelcheck scanzone         ask DanNet boxes in this zone to scan
    /levelcheck quit             close the window and stop the script

  Each character saves its own results file in your MQ config folder, so the
  window shows every character that has ever been scanned - online or not.
  From the window you can tell all DanNet-connected boxes to rescan.
]]

local mq    = require('mq')
local ImGui = require('ImGui')

local SCRIPT   = 'levelcheck'
local CFG_DIR  = mq.configDir
local INDEX    = CFG_DIR .. '/LevelCheck_index.lua'
local args     = { ... }

-- ---------------------------------------------------------------- slots ---
local WORN = {
  [0]='Charm','Left Ear','Head','Face','Right Ear','Neck','Shoulders','Arms',
  'Back','Left Wrist','Right Wrist','Range','Hands','Primary','Secondary',
  'Left Finger','Right Finger','Chest','Legs','Feet','Waist','Power Source','Ammo',
}
local PACK_FIRST = 23
local function packLast() return PACK_FIRST - 1 + (tonumber(mq.TLO.Me.NumBagSlots()) or 10) end
local BANK_SLOTS            = 24
local SHARED_SLOTS          = 2
local MAX_AUGS              = 6

-- -------------------------------------------------------------- helpers ---
local function safe(fn, ...)
  local ok, v = pcall(fn, ...)
  if ok then return v end
  return nil
end

local function num(v) return tonumber(v) or 0 end

local function fileFor(server, name)
  local s = (server or 'server'):gsub('[^%w]', '')
  return string.format('%s/LevelCheck_%s_%s.lua', CFG_DIR, s, name)
end

local function loadTable(path)
  local f = loadfile(path)
  if not f then return nil end
  local ok, t = pcall(f)
  if ok and type(t) == 'table' then return t end
  return nil
end

-- ----------------------------------------------------------------- scan ---
local function addItem(out, item, location, slot, parent)
  if not item or not safe(function() return item() end) then return end
  local req = num(safe(function() return item.RequiredLevel() end))
  local rec = num(safe(function() return item.RecommendedLevel() end))
  if req > 0 or rec > 0 then
    table.insert(out, {
      name     = safe(function() return item.Name() end) or '?',
      id       = num(safe(function() return item.ID() end)),
      req      = req,
      rec      = rec,
      location = location,
      slot     = slot,
      parent   = parent,   -- set when this is an augment inside another item
      link     = safe(function() return item.ItemLink('CLICKABLE')() end),
    })
  end
end

-- An item plus any augments socketed in it
local function scanItem(out, item, location, slot)
  if not item or not safe(function() return item() end) then return end
  addItem(out, item, location, slot)
  local isBag = num(safe(function() return item.Container() end)) > 0
  if not isBag then
    local pname = safe(function() return item.Name() end)
    for a = 1, MAX_AUGS do
      local aug = safe(function() return item.AugSlot(a).Item end)
      addItem(out, aug, location, slot .. ' (aug ' .. a .. ')', pname)
    end
  end
end

-- A slot that may hold a bag; scans the bag and everything in it
local function scanSlot(out, item, location, slotLabel)
  if not item or not safe(function() return item() end) then return end
  scanItem(out, item, location, slotLabel)
  local slots = num(safe(function() return item.Container() end))
  for i = 1, slots do
    local inner = safe(function() return item.Item(i) end)
    scanItem(out, inner, location, slotLabel .. ' / ' .. i)
  end
end

local function scanMe()
  local me = mq.TLO.Me
  local out = {}

  for i = 0, 22 do
    scanItem(out, me.Inventory(i), 'Worn', WORN[i])
  end
  for i = PACK_FIRST, packLast() do
    scanSlot(out, me.Inventory(i), 'Bags', 'Pack ' .. (i - PACK_FIRST + 1))
  end
  for i = 1, BANK_SLOTS do
    scanSlot(out, me.Bank(i), 'Bank', 'Bank ' .. i)
  end
  for i = 1, SHARED_SLOTS do
    local sb = safe(function() return me.SharedBank(i) end)
    scanSlot(out, sb, 'Shared Bank', 'Shared ' .. i)
  end

  local data = {
    name    = me.CleanName(),
    server  = mq.TLO.MacroQuest.Server() or mq.TLO.EverQuest.Server(),
    class   = me.Class.ShortName(),
    level   = me.Level(),
    scanned = os.date('%Y-%m-%d %H:%M'),
    items   = out,
  }

  mq.pickle(fileFor(data.server, data.name), data)

  -- keep a list of every scanned character so the UI can find their files
  local index = loadTable(INDEX) or {}
  local key = data.server .. '|' .. data.name
  local found = false
  for _, v in ipairs(index) do if v == key then found = true end end
  if not found then table.insert(index, key); mq.pickle(INDEX, index) end

  printf('\ag[LevelCheck]\ax scanned %s: %d items with level requirements', data.name, #out)
  return data
end

if args[1] == 'scan' then
  scanMe()
  return
end

-- ------------------------------------------------------------------- UI ---
local state = {
  open       = true,
  threshold  = 51,
  onlyBad    = true,
  showRec    = true,
  search     = '',
  charFilter = 'All characters',
  locs       = { Worn = true, Bags = true, Bank = true, ['Shared Bank'] = true },
  chars      = {},     -- list of loaded character data
  rows       = {},     -- flattened, filtered rows
  sortCol    = 5,
  sortAsc    = false,
  dirty      = true,
  reloadAt   = nil,
}

local function loadAll()
  state.chars = {}
  for _, key in ipairs(loadTable(INDEX) or {}) do
    local server, name = key:match('^(.-)|(.+)$')
    local t = name and loadTable(fileFor(server, name))
    if t then table.insert(state.chars, t) end
  end
  table.sort(state.chars, function(a, b) return a.name < b.name end)
  state.dirty = true
end

local function status(it)
  if it.req > state.threshold then return 3 end           -- cannot equip
  if state.showRec and it.rec > state.threshold then return 2 end -- reduced stats
  return 1
end

local STATUS_TEXT  = { 'OK', 'Reduced stats', 'Unwearable' }
local STATUS_COLOR = {
  { 0.55, 0.80, 0.55, 1 },
  { 0.95, 0.75, 0.30, 1 },
  { 0.95, 0.40, 0.40, 1 },
}

local function rebuild()
  local q = state.search:lower()
  local rows = {}
  for _, c in ipairs(state.chars) do
    if state.charFilter == 'All characters' or state.charFilter == c.name then
      for _, it in ipairs(c.items or {}) do
        local st = status(it)
        if state.locs[it.location]
          and (not state.onlyBad or st > 1)
          and (q == '' or it.name:lower():find(q, 1, true)) then
          table.insert(rows, { char = c.name, it = it, st = st })
        end
      end
    end
  end
  local col, asc = state.sortCol, state.sortAsc
  local keyFns = {
    [0] = function(r) return r.char end,
    [1] = function(r) return r.it.location end,
    [2] = function(r) return r.it.slot end,
    [3] = function(r) return r.it.name end,
    [4] = function(r) return r.it.req end,
    [5] = function(r) return r.it.rec end,
    [6] = function(r) return r.st end,
  }
  local k = keyFns[col] or keyFns[4]
  table.sort(rows, function(a, b)
    local ka, kb = k(a), k(b)
    if ka == kb then
      if a.char ~= b.char then return a.char < b.char end
      return a.it.name < b.it.name
    end
    if asc then return ka < kb else return ka > kb end
  end)
  state.rows = rows
  state.dirty = false
end

local function countsFor(c)
  local bad, warn, wornBad = 0, 0, 0
  for _, it in ipairs(c.items or {}) do
    local st = status(it)
    if st == 3 then bad = bad + 1; if it.location == 'Worn' then wornBad = wornBad + 1 end
    elseif st == 2 then warn = warn + 1 end
  end
  return bad, warn, wornBad
end

local function drawSummary()
  if #state.chars == 0 then
    ImGui.TextDisabled('No characters scanned yet. Click "Rescan me" or "Rescan all boxes".')
    return
  end
  local flags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.SizingStretchProp)
  if ImGui.BeginTable('summary', 6, flags) then
    ImGui.TableSetupColumn('Character')
    ImGui.TableSetupColumn('Class / Lvl')
    ImGui.TableSetupColumn('Unwearable (worn)')
    ImGui.TableSetupColumn('Unwearable (total)')
    ImGui.TableSetupColumn('Reduced stats')
    ImGui.TableSetupColumn('Last scan')
    ImGui.TableHeadersRow()
    for _, c in ipairs(state.chars) do
      local bad, warn, wornBad = countsFor(c)
      ImGui.TableNextRow()
      ImGui.TableNextColumn()
      if ImGui.Selectable(c.name .. '##sum', state.charFilter == c.name, ImGuiSelectableFlags.SpanAllColumns) then
        state.charFilter = (state.charFilter == c.name) and 'All characters' or c.name
        state.dirty = true
      end
      ImGui.TableNextColumn(); ImGui.Text(string.format('%s %s', c.class or '', c.level or ''))
      ImGui.TableNextColumn()
      if wornBad > 0 then ImGui.TextColored(STATUS_COLOR[3][1], STATUS_COLOR[3][2], STATUS_COLOR[3][3], 1, tostring(wornBad))
      else ImGui.TextColored(STATUS_COLOR[1][1], STATUS_COLOR[1][2], STATUS_COLOR[1][3], 1, '0') end
      ImGui.TableNextColumn(); ImGui.Text(tostring(bad))
      ImGui.TableNextColumn(); ImGui.Text(tostring(warn))
      ImGui.TableNextColumn(); ImGui.TextDisabled(c.scanned or '')
    end
    ImGui.EndTable()
  end
end

local function drawFilters()
  ImGui.SetNextItemWidth(110)
  local v, changed = ImGui.InputInt('Delevel to', state.threshold)
  if changed then state.threshold = math.max(1, math.min(v, 125)); state.dirty = true end
  ImGui.SameLine()
  local b
  b, changed = ImGui.Checkbox('Problems only', state.onlyBad)
  if changed then state.onlyBad = b; state.dirty = true end
  ImGui.SameLine()
  b, changed = ImGui.Checkbox('Flag recommended level', state.showRec)
  if changed then state.showRec = b; state.dirty = true end

  for _, loc in ipairs({ 'Worn', 'Bags', 'Bank', 'Shared Bank' }) do
    b, changed = ImGui.Checkbox(loc, state.locs[loc])
    if changed then state.locs[loc] = b; state.dirty = true end
    ImGui.SameLine()
  end
  ImGui.SetNextItemWidth(160)
  if ImGui.BeginCombo('##char', state.charFilter) then
    local opts = { 'All characters' }
    for _, c in ipairs(state.chars) do table.insert(opts, c.name) end
    for _, o in ipairs(opts) do
      if ImGui.Selectable(o, state.charFilter == o) then state.charFilter = o; state.dirty = true end
    end
    ImGui.EndCombo()
  end
  ImGui.SameLine()
  ImGui.SetNextItemWidth(-1)
  local s, sch = ImGui.InputTextWithHint('##search', 'Search item name...', state.search)
  if sch then state.search = s or ''; state.dirty = true end
end

local function drawResults()
  local flags = bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.Sortable,
    ImGuiTableFlags.ScrollY, ImGuiTableFlags.Resizable, ImGuiTableFlags.SizingStretchProp)
  if ImGui.BeginTable("results", 7, flags, ImVec2(0, 0)) then
    ImGui.TableSetupScrollFreeze(0, 1)
    ImGui.TableSetupColumn('Character', 0, 1.0, 0)
    ImGui.TableSetupColumn('Where',     0, 0.8, 1)
    ImGui.TableSetupColumn('Slot',      0, 1.2, 2)
    ImGui.TableSetupColumn('Item',      0, 2.4, 3)
    ImGui.TableSetupColumn('Req',       ImGuiTableColumnFlags.PreferSortDescending, 0.4, 4)
    ImGui.TableSetupColumn('Rec',       bit32.bor(ImGuiTableColumnFlags.PreferSortDescending, ImGuiTableColumnFlags.DefaultSort), 0.4, 5)
    ImGui.TableSetupColumn('Status',    0, 0.9, 6)
    ImGui.TableHeadersRow()

    local specs = ImGui.TableGetSortSpecs()
    if specs and specs.SpecsDirty and specs.SpecsCount > 0 then
      local s = specs:Specs(1)
      state.sortCol = s.ColumnUserID
      state.sortAsc = (s.SortDirection == ImGuiSortDirection.Ascending)
      specs.SpecsDirty = false
      state.dirty = true
    end
    if state.dirty then rebuild() end

    for i, r in ipairs(state.rows) do
      local it, c = r.it, STATUS_COLOR[r.st]
      ImGui.TableNextRow()
      ImGui.TableNextColumn(); ImGui.Text(r.char)
      ImGui.TableNextColumn(); ImGui.Text(it.location)
      ImGui.TableNextColumn(); ImGui.Text(it.slot)
      ImGui.TableNextColumn()
      ImGui.Text(it.name)
      if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.Text(it.name)
        if it.parent then ImGui.TextDisabled('Augment in: ' .. it.parent) end
        ImGui.TextDisabled('Item ID ' .. it.id .. '  -  click to inspect')
        ImGui.EndTooltip()
      end
      if ImGui.IsItemClicked() and it.link then mq.cmdf('/executelink %s', it.link) end
      ImGui.TableNextColumn()
      if it.req > state.threshold then ImGui.TextColored(c[1], c[2], c[3], 1, tostring(it.req))
      else ImGui.Text(it.req > 0 and tostring(it.req) or '-') end
      ImGui.TableNextColumn(); ImGui.Text(it.rec > 0 and tostring(it.rec) or '-')
      ImGui.TableNextColumn(); ImGui.TextColored(c[1], c[2], c[3], c[4], STATUS_TEXT[r.st])
    end
    ImGui.EndTable()
  end
end

local function draw()
  if not state.open then return end
  ImGui.SetNextWindowSize(ImVec2(900, 600), ImGuiCond.FirstUseEver)
  local show
  state.open, show = ImGui.Begin('Gear Level Check', state.open)
  if show then
    if ImGui.Button('Rescan me') then state.rescanMe = true end
    ImGui.SameLine()
    if ImGui.Button('Rescan all boxes (DanNet)') then
      mq.cmdf('/dge /lua run %s scan', SCRIPT)
      state.rescanMe = true
      state.reloadAt = mq.gettime() + 4000
    end
    ImGui.SameLine()
    if ImGui.Button('Rescan this zone') then
      mq.cmdf('/dgze /lua run %s scan', SCRIPT)
      state.rescanMe = true
      state.reloadAt = mq.gettime() + 4000
    end
    if ImGui.IsItemHovered() then ImGui.SetTooltip('Scan every DanNet character in your current zone') end
    ImGui.SameLine()
    if ImGui.Button('Reload results') then loadAll() end
    ImGui.SameLine()
    ImGui.TextDisabled(string.format('  %d character(s), %d row(s)', #state.chars, #state.rows))

    ImGui.Separator()
    drawSummary()
    ImGui.Separator()
    drawFilters()
    drawResults()
  end
  ImGui.End()
end

scanMe()
loadAll()
mq.imgui.init('LevelCheckUI', draw)

-- one command, named after the script
mq.bind('/levelcheck', function(cmd)
  cmd = (cmd or ''):lower()
  if cmd == 'scan' then state.rescanMe = true
  elseif cmd == 'scanall' then mq.cmdf('/dge /lua run %s scan', SCRIPT); state.rescanMe = true; state.reloadAt = mq.gettime() + 4000
  elseif cmd == 'scanzone' then mq.cmdf('/dgze /lua run %s scan', SCRIPT); state.rescanMe = true; state.reloadAt = mq.gettime() + 4000
  elseif cmd == 'quit' then state.open = false
  else printf('\ag[LevelCheck]\ax /levelcheck scan | scanall | scanzone | quit') end
end)

while state.open do
  if state.rescanMe then state.rescanMe = false; scanMe(); loadAll() end
  if state.reloadAt and mq.gettime() >= state.reloadAt then state.reloadAt = nil; loadAll() end
  mq.delay(200)
end
