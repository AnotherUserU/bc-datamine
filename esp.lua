-- Build and Conquer ESP + auto-mark target rudal. INTERNAL (Delta).
-- Kategori bangunan dari template (atribut RoadTemplateName di workspace.PlacedRoads), kapal dari workspace.Ships
-- (ShipKind -> ShipKinds.ClassName). Kapal selam musuh yang menyelam hanya disembunyikan di client
-- (LocalTransparencyModifier), posisinya tetap terkirim, jadi tetap tampil di ESP.
-- Auto-mark memanggil fungsi game sendiri (MissileTargeting.assignTarget) lewat getgc: tidak ada klik mouse,
-- target tidak harus ada di layar, dan aturan game (limit, range, PVP, sekutu) tetap berlaku.
-- Cara pakai: buka targeting rudal + pilih munisi di game, lalu tekan MARK (atau "=").
-- Anti AFK (default ON) mencegah kick idle 20 menit bawaan Roblox.
-- Tombol: Insert = sembunyikan panel, "=" = MARK, "-" = scan ulang, Numpad1.. = on/off kategori.
if game.GameId ~= 10757247806 then return end
if _G.BC_ESP_INT then pcall(_G.BC_ESP_INT.stop) end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer

local M_PER_STUD = 0.28
local MAX_DIST_M = 1500        -- label lebih jauh dari ini tidak tampil (meter)
local UPDATE_EVERY = 0.3       -- dtk, teks/visibilitas label dihitung ulang
local RESCAN_DEBOUNCE = 1      -- dtk setelah bangunan/kapal bertambah/berkurang
local STREAM_EVERY = 90        -- dtk, minta server mengirim semua plot lagi
local LABEL_UP = 4             -- stud di atas bangunan
local SUB_DIVE_Z = 1.5         -- ShipMotion.Z di atas ini = menyelam (sama dengan game)

local TEMPLATE_KIND = {}
local function addKind(kind, list) for _, t in ipairs(list) do TEMPLATE_KIND[t] = kind end end
addKind("ad", { "Stinger MANPADS", "Mistral MANPADS", "Igla-S MANPADS", "AA Gun", "RapidFire", "M163 VADS", "CIWS",
  "Mistral Launcher", "VL MICA Launcher", "S-300 Launcher", "US PAC-2 Launcher", "PatriotPac2", "Pantsir", "Iron Dome",
  "Enduring Shield Launcher", "US PAC-3 MSE Launcher", "SAMP-TG", "S-400 Launcher", "PatriotPac3", "THAAD Launcher",
  "S-500Launcher", "Arrow3", "Aquilla Base Launcher" })
addKind("ew", { "Early Warning Radar" })
addKind("rudal", { "SRBMLauncher", "IskanderLauncher", "FP-5 Flamingo Launcher", "MRBMLauncher", "FP9 Pelican Launcher",
  "ClusterBMLauncher", "B-Strike1000Launcher", "M270Launcher", "MdCN Launcher", "ASBMLauncher", "Himars PrSM",
  "B-STRIKE 2500 Launcher", "Zircon Launcher", "Hypersonic BM Launcher", "ATACMS Cluster Launcher", "HeavyMRBMLauncher",
  "GLCM Launcher", "CoastalLauncher", "Dark Eagle Launcher", "B-STRIKE Hypersonic launcher", "Typhon Launcher",
  "Blackbeard Launcher", "Hades Launcher", "M51 Launcher" })
addKind("drone", { "LUCAS Launcher", "Switchblade Launcher", "Shahed Launcher", "Rodeur 330 Rail", "Veloce 330 Rail",
  "Shahed-236 Launcher", "Red Wolf Launcher", "Barracuda Launcher", "One Way Effector Rail", "Karrar Launcher",
  "Geran-5 Launcher" })
addKind("wh", { "Medium Military Warehouse" })
addKind("fac", { "LargeMilitaryFactory" })

-- Prioritas MARK: semua tingkat 1 dulu, sisa slot ke tingkat 2, dst; dalam satu tingkat urut jarak.
-- Dicocokkan ke nama huruf kecil tanpa simbol.
local PRIORITY_TIERS = {
  { "aquilla", "s500", "arrow3" },
  { "hypersonic", "zircon" },
  { "sampt", "s400", "pac3", "earlywarningradar" },
  { "fp9", "bstrike2500", "mrbm" },
}

local CATS = {
  { id = "wh",    label = "Medium Warehouse",   color = Color3.fromRGB(255, 170, 40),  on = false },
  { id = "ad",    label = "Air Defense",        color = Color3.fromRGB(255, 70, 70),   on = true },
  { id = "ew",    label = "Early Warning (EW)", color = Color3.fromRGB(255, 140, 200), on = true },
  { id = "rudal", label = "Missile Launcher",   color = Color3.fromRGB(220, 90, 255),  on = true },
  { id = "drone", label = "Drone Launcher",     color = Color3.fromRGB(60, 210, 255),  on = false },
  { id = "fac",   label = "Large Mil Factory",  color = Color3.fromRGB(255, 230, 60),  on = false },
  { id = "ship",  label = "Ship",               color = Color3.fromRGB(90, 160, 255),  on = true },
  { id = "sub",   label = "Submarine",          color = Color3.fromRGB(0, 255, 190),   on = true },
}
local CAT = {}
for i, c in ipairs(CATS) do CAT[c.id], c.idx = c, i end
local opt = { mine = false, hideDead = true, fill = false, stream = true, afk = true }
local MINE_COLOR, DEAD_COLOR = Color3.fromRGB(80, 220, 80), Color3.fromRGB(150, 150, 150)

local alive = true
local conns = {}
local entries = {}            -- model -> entry
local playerOn = {}           -- UserId -> false kalau dimatikan
local baseKey = nil
local markLimit = 0           -- diketik di panel; 0 / kosong = Auto (sampai game bilang penuh)
local statusText = "Siap"
local afkCount = 0            -- berapa kali kick idle Roblox (20 menit) dicegah
local renderPanel             -- didefinisikan di bagian panel

local function attr(i, k)
  local ok, v = pcall(i.GetAttribute, i, k)
  return ok and v or nil
end
local function norm(s) return (s:lower():gsub("[^%w]", "")) end
local function priorityOf(name)
  local n = norm(name)
  for i, tier in ipairs(PRIORITY_TIERS) do
    for _, w in ipairs(tier) do if n:find(w, 1, true) then return i end end
  end
  return #PRIORITY_TIERS + 1
end

local ShipKinds
pcall(function() ShipKinds = require(RS:WaitForChild("ShipKinds", 10)) end)

local function playerName(id)
  local p = id and Players:GetPlayerByUserId(id)
  return p and p.Name or tostring(id)
end

local holder = Instance.new("Folder")
holder.Name = "BCEspInt"
local guiParent = (gethui and gethui()) or game:GetService("CoreGui")
holder.Parent = guiParent

-- ===== entry + label =====
local function firstPart(m)
  if m:IsA("Model") and m.PrimaryPart then return m.PrimaryPart end
  local d = m:FindFirstChild("DetailBounds")
  if d and d:IsA("BasePart") then return d end
  return m:FindFirstChildWhichIsA("BasePart", true)
end

local function makeLabel(e)
  local bb = Instance.new("BillboardGui")
  bb.AlwaysOnTop, bb.LightInfluence, bb.ResetOnSpawn = true, 0, false
  bb.Size = UDim2.fromOffset(260, 16)
  bb.MaxDistance = MAX_DIST_M / M_PER_STUD
  local t = Instance.new("TextLabel")
  t.BackgroundTransparency, t.Size = 1, UDim2.fromScale(1, 1)
  t.Font, t.TextSize, t.TextStrokeTransparency = Enum.Font.GothamBold, 13, 0
  t.Parent = bb
  if e.ship then
    bb.Adornee = firstPart(e.model)
    bb.StudsOffsetWorldSpace = Vector3.new(0, 12, 0)
  else
    local a = Instance.new("Attachment")
    a.WorldPosition = e.point + Vector3.new(0, LABEL_UP, 0)
    a.Parent = workspace.Terrain
    e.att = a
    bb.Adornee = a
  end
  bb.Enabled = false
  bb.Parent = holder
  e.bb, e.txt = bb, t
end

local function buildingEntry(m)
  local tmpl = attr(m, "RoadTemplateName") or (m.Name:sub(1, 6) == "Placed" and m.Name:sub(7)) or m.Name
  local kind = TEMPLATE_KIND[tmpl]
  if not kind then return nil end
  local p = firstPart(m)
  if not p then return nil end
  local gx, gz = tonumber(attr(m, "RoadGridX")), tonumber(attr(m, "RoadGridZ"))
  local owner = tonumber(attr(m, "PlacementOwnerUserId"))
  local name = m.Name:sub(1, 6) == "Placed" and m.Name:sub(7) or tmpl
  return { model = m, kind = kind, owner = owner, name = name, prio = priorityOf(name),
           point = (gx and gz) and Vector3.new(gx, p.Position.Y, gz) or p.Position }
end

local function shipEntry(m)
  if not m:IsA("Model") then return nil end
  local sub = attr(m, "Submarine") == true
  local name = "Ship"
  if ShipKinds then
    local ok, n = pcall(ShipKinds.ClassName, m)
    if ok and n then name = n end
  end
  return { model = m, kind = sub and "sub" or "ship", ship = true, owner = tonumber(attr(m, "OwnerUserId")),
           name = name, prio = sub and #PRIORITY_TIERS + 2 or #PRIORITY_TIERS + 1 }
end

local function dropEntry(m)
  local e = entries[m]
  if not e then return end
  pcall(function() e.bb:Destroy() end)
  if e.att then pcall(function() e.att:Destroy() end) end
  entries[m] = nil
end

local function scan()
  local seen = {}
  local placed = workspace:FindFirstChild("PlacedRoads")
  for _, m in ipairs(placed and placed:GetChildren() or {}) do
    seen[m] = true
    if not entries[m] then
      local e = buildingEntry(m)
      if e then makeLabel(e) entries[m] = e end
    end
  end
  local ships = workspace:FindFirstChild("Ships")
  for _, m in ipairs(ships and ships:GetChildren() or {}) do
    seen[m] = true
    if not entries[m] then
      local e = shipEntry(m)
      if e and firstPart(m) then makeLabel(e) entries[m] = e end
    end
  end
  for m in pairs(entries) do if not seen[m] or not m.Parent then dropEntry(m) end end
end

-- ===== status per frame =====
local function isMine(e) return e.owner == lp.UserId end
local function isDead(e)
  if attr(e.model, "Destroyed") == true then return true end
  return not e.ship and attr(e.model, "Operational") == false
end
local function submerged(e)
  local mo = attr(e.model, "ShipMotion")
  return typeof(mo) == "Vector3" and mo.Z > SUB_DIVE_Z
end
local function posOf(e)
  if e.ship then
    local ok, cf = pcall(e.model.GetPivot, e.model)
    return ok and cf.Position or nil
  end
  return e.point
end

local function bases()
  local list = {}
  local f = workspace:FindFirstChild("Plots")
  for _, p in ipairs(f and f:GetChildren() or {}) do
    local owner = tonumber(attr(p, "OwnerUserId"))
    if owner and owner ~= lp.UserId and p:IsA("BasePart") then
      list[#list + 1] = { key = ("%d,%d"):format(math.floor(p.Position.X), math.floor(p.Position.Z)),
        name = ("%s (%s)"):format(tostring(attr(p, "CountryName") or "?"), playerName(owner)),
        cx = p.Position.X, cz = p.Position.Z, hx = p.Size.X / 2, hz = p.Size.Z / 2 }
    end
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end
local function selectedBase()
  for _, b in ipairs(bases()) do if b.key == baseKey then return b end end
  return nil
end

local function wanted(e, dead)
  if not CAT[e.kind].on then return false end
  if dead and opt.hideDead then return false end
  if isMine(e) then return opt.mine end
  return playerOn[e.owner] ~= false
end

local function extraInfo(e)
  if e.ship then
    local hp, mx = attr(e.model, "ShipHealth"), attr(e.model, "ShipHealthMax")
    local s = (type(hp) == "number" and type(mx) == "number" and mx > 0) and (" %d%%"):format(hp / mx * 100) or ""
    if e.kind == "sub" and submerged(e) then s = s .. " SELAM" end
    return s
  end
  if e.kind == "ad" then
    local ammo, mag = attr(e.model, "PatriotAmmo"), attr(e.model, "PatriotMagazine")
    local s = (ammo and mag) and (" %s/%s"):format(tostring(ammo), tostring(mag)) or ""
    if attr(e.model, "PatriotResupplying") == true then s = s .. " RELOAD" end
    if attr(e.model, "PatriotEnabled") == false then s = s .. " OFF" end
    return s
  end
  return ""
end

local function updateLabels()
  local cam = workspace.CurrentCamera.CFrame.Position
  for m, e in pairs(entries) do
    if not m.Parent then dropEntry(m) continue end
    local dead = isDead(e)
    local show = wanted(e, dead)
    if show then
      local p = posOf(e)
      local dist = p and math.floor((p - cam).Magnitude * M_PER_STUD + 0.5) or 0
      e.txt.Text = ("%s%s [%s]%s %dm"):format(dead and "[DEAD] " or "", e.name, playerName(e.owner), extraInfo(e), dist)
      e.txt.TextColor3 = dead and DEAD_COLOR or (isMine(e) and MINE_COLOR or CAT[e.kind].color)
    end
    if e.bb.Enabled ~= show then e.bb.Enabled = show end
  end
end

-- ===== auto-mark lewat fungsi game =====
local assignFn
local function findAssign()
  if assignFn then return assignFn end
  if not getgc then return nil end
  for _, f in ipairs(getgc()) do
    if type(f) == "function" then
      local ok, n, s = pcall(debug.info, f, "ns")
      if ok and n == "assignTarget" and type(s) == "string" and s:find("MissileTargeting", 1, true) then
        assignFn = f
        return f
      end
    end
  end
  return nil
end

local STOP_WORDS = { "limit reached", "No more", "Select a munition" }
local function isStop(msg)
  for _, w in ipairs(STOP_WORDS) do if tostring(msg):find(w, 1, true) then return true end end
  return false
end

local function candidates()
  local cam = workspace.CurrentCamera.CFrame.Position
  local base = selectedBase()
  local list = {}
  for _, e in pairs(entries) do
    local dead = isDead(e)
    local p = posOf(e)
    if p and not isMine(e) and not dead and wanted(e, dead)
      and not (e.kind == "sub" and submerged(e))
      and (base == nil or (math.abs(p.X - base.cx) <= base.hx and math.abs(p.Z - base.cz) <= base.hz)) then
      list[#list + 1] = { e = e, p = p, d = (p - cam).Magnitude }
    end
  end
  table.sort(list, function(a, b)
    if a.e.prio ~= b.e.prio then return a.e.prio < b.e.prio end
    return a.d < b.d
  end)
  return list
end

local function mark()
  local fn = findAssign()
  if not fn then statusText = "assignTarget tidak ketemu (buka targeting rudal dulu)" return end
  local limit = markLimit > 0 and markLimit or math.huge
  local list = candidates()
  local n, skipped, stopMsg = 0, 0, nil
  repeat
    local passN = 0
    for _, c in ipairs(list) do
      if n >= limit then break end
      local ok, res, msg = pcall(fn, c.p, true)
      if ok and res then
        n, passN = n + 1, passN + 1
      else
        msg = ok and msg or res
        if isStop(msg) then stopMsg = msg break end
        skipped = skipped + 1
      end
    end
  until stopMsg or not opt.fill or passN == 0 or n >= limit
  statusText = ("Marked %d dari %d target%s%s"):format(n, #list,
    skipped > 0 and (", %d ditolak"):format(skipped) or "",
    (n == 0 and stopMsg) and (" | " .. tostring(stopMsg)) or "")
end

-- ===== muat semua plot (StreamingEnabled) =====
local function streamAll()
  if not workspace.StreamingEnabled then return end
  local f = workspace:FindFirstChild("Plots")
  for _, plot in ipairs(f and f:GetChildren() or {}) do
    if not alive then return end
    local ok, c = pcall(function() return plot:IsA("BasePart") and plot.Position or plot:GetPivot().Position end)
    if ok then
      for _, dx in ipairs({ -200, 0, 200 }) do
        for _, dz in ipairs({ -200, 0, 200 }) do
          pcall(lp.RequestStreamAroundAsync, lp, c + Vector3.new(dx, 0, dz), 10)
        end
      end
    end
  end
end

-- ===== panel =====
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "BCEspIntPanel", false, 50
gui.Parent = guiParent
local W, ROW = 250, 22
local panel = Instance.new("Frame")
panel.Position, panel.BackgroundColor3, panel.BorderSizePixel = UDim2.fromOffset(20, 160), Color3.fromRGB(16, 15, 22), 0
panel.BackgroundTransparency = 0.1
panel.Parent = gui
local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = panel

local rows = {}
local function row(text, onClick, color)
  local b = Instance.new(onClick and "TextButton" or "TextLabel")
  b.Size, b.BackgroundTransparency, b.BorderSizePixel = UDim2.fromOffset(W, ROW), 1, 0
  b.Font, b.TextSize, b.TextXAlignment = Enum.Font.GothamBold, 13, Enum.TextXAlignment.Left
  b.TextColor3, b.TextStrokeTransparency, b.Text = Color3.fromRGB(215, 212, 228), 0.5, text
  b.LayoutOrder = #rows + 1
  local pad = Instance.new("UIPadding")
  pad.PaddingLeft = UDim.new(0, color and 24 or 8)
  pad.Parent = b
  local box
  if color then
    box = Instance.new("Frame")
    box.Size, box.Position, box.BorderSizePixel = UDim2.fromOffset(11, 11), UDim2.fromOffset(-17, 5), 0
    box.BackgroundColor3 = color
    box.Parent = b
  end
  if onClick then
    b.AutoButtonColor = false
    b.MouseButton1Click:Connect(function() onClick() renderPanel() end)
  end
  b.Parent = panel
  local r = { b = b, box = box }
  rows[#rows + 1] = r
  return r
end

local title = row("BC ESP internal  [Insert]  (seret)")
title.b.TextColor3 = Color3.new(1, 1, 1)
local catRows = {}
for _, c in ipairs(CATS) do catRows[c.id] = row("", function() c.on = not c.on end, c.color) end
local optRows = {
  mine = row("", function() opt.mine = not opt.mine end, MINE_COLOR),
  hideDead = row("", function() opt.hideDead = not opt.hideDead end, DEAD_COLOR),
}
local PLAYER_ROWS = 6
local playerRows, playerIds = {}, {}
for i = 1, PLAYER_ROWS do
  playerRows[i] = row("", function()
    local id = playerIds[i]
    if id then playerOn[id] = playerOn[id] == false end
  end, Color3.new(1, 1, 1))
end
local baseRow = row("", function()
  local list, idx = bases(), 0
  for i, b in ipairs(list) do if b.key == baseKey then idx = i end end
  local nxt = list[idx + 1]
  baseKey = nxt and nxt.key or nil
end)
-- Limit diketik bebas (angka berapa saja); kosong / 0 = Auto
local limitRow = row("Limit MARK:")
local limitBox = Instance.new("TextBox")
limitBox.Size, limitBox.Position = UDim2.fromOffset(110, ROW - 4), UDim2.fromOffset(W - 126, 2)
limitBox.BackgroundColor3, limitBox.BorderSizePixel = Color3.fromRGB(40, 38, 52), 0
limitBox.Font, limitBox.TextSize, limitBox.TextColor3 = Enum.Font.GothamBold, 13, Color3.new(1, 1, 1)
limitBox.PlaceholderText, limitBox.PlaceholderColor3 = "Auto", Color3.fromRGB(140, 140, 140)
limitBox.ClearTextOnFocus, limitBox.Text = false, ""
limitBox.Parent = limitRow.b
table.insert(conns, limitBox.FocusLost:Connect(function()
  local n = tonumber((limitBox.Text:gsub("%D", "")))
  markLimit = (n and n > 0) and math.floor(n) or 0
  limitBox.Text = markLimit > 0 and tostring(markLimit) or ""
  statusText = "Limit MARK: " .. (markLimit > 0 and tostring(markLimit) or "Auto")
  renderPanel()
end))
local fillRow = row("", function() opt.fill = not opt.fill end)
local streamRow = row("", function() opt.stream = not opt.stream end)
local afkRow = row("", function() opt.afk = not opt.afk end)
local markRow = row(">> MARK  [=]", function() mark() end)
markRow.b.TextColor3 = Color3.fromRGB(255, 220, 80)
local fullRescan               -- didefinisikan di bagian scan
local scanRow = row(">> Muat semua + scan ulang  [-]", function() fullRescan() end)
local statusRow = row("")
statusRow.b.TextColor3 = Color3.fromRGB(150, 150, 150)
statusRow.b.TextWrapped = true
statusRow.b.Size = UDim2.fromOffset(W, ROW * 2)
panel.Size = UDim2.fromOffset(W, ROW * (#rows + 1))

renderPanel = function()
  local cnt = {}
  for _, e in pairs(entries) do
    if not isMine(e) and not isDead(e) then cnt[e.kind] = (cnt[e.kind] or 0) + 1 end
  end
  for _, c in ipairs(CATS) do
    local r = catRows[c.id]
    r.box.BackgroundTransparency = c.on and 0 or 0.75
    r.b.Text = ("[%d] %s (%d)"):format(c.idx, c.label, cnt[c.id] or 0)
  end
  optRows.mine.box.BackgroundTransparency = opt.mine and 0 or 0.75
  optRows.mine.b.Text = "Show Mine"
  optRows.hideDead.box.BackgroundTransparency = opt.hideDead and 0 or 0.75
  optRows.hideDead.b.Text = "Hide Destroyed"
  local per = {}
  for _, e in pairs(entries) do
    if e.owner and not isMine(e) then per[e.owner] = (per[e.owner] or 0) + 1 end
  end
  local ids = {}
  for id in pairs(per) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return playerName(a) < playerName(b) end)
  playerIds = ids
  for i, r in ipairs(playerRows) do
    local id = ids[i]
    r.b.Visible = id ~= nil
    if id then
      r.box.BackgroundTransparency = playerOn[id] == false and 0.75 or 0
      r.b.Text = ("%s (%d)"):format(playerName(id), per[id])
    end
  end
  local b = selectedBase()
  baseRow.b.Text = "Base: " .. (b and b.name or "All")
  fillRow.b.Text = "Fill Slots: " .. (opt.fill and "ON" or "OFF")
  streamRow.b.Text = ("Muat semua plot tiap %ds: %s"):format(STREAM_EVERY, opt.stream and "ON" or "OFF")
  afkRow.b.Text = ("Anti AFK: %s%s"):format(opt.afk and "ON" or "OFF",
    afkCount > 0 and (" (dicegah %dx)"):format(afkCount) or "")
  statusRow.b.Text = statusText
  local shown = 0
  for _, r in ipairs(rows) do if r.b.Visible then shown = shown + 1 end end
  panel.Size = UDim2.fromOffset(W, ROW * (shown + 1))
end

-- seret panel dari judul (mouse atau sentuh)
do
  local dragging, start, origin
  table.insert(conns, title.b.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
      dragging, start, origin = true, i.Position, panel.Position
    end
  end))
  table.insert(conns, UIS.InputChanged:Connect(function(i)
    if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
      local d = i.Position - start
      panel.Position = UDim2.fromOffset(origin.X.Offset + d.X, origin.Y.Offset + d.Y)
    end
  end))
  table.insert(conns, UIS.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
      dragging = false
    end
  end))
end

-- ===== scan + loop =====
local dirty, scanning = true, false
fullRescan = function()
  if scanning then return end
  scanning = true
  statusText = "Memuat semua plot..."
  renderPanel()
  task.spawn(function()
    streamAll()
    task.wait(2)
    local ok, err = pcall(scan)
    local n = 0
    for _ in pairs(entries) do n = n + 1 end
    statusText = ok and ("Scan: %d objek"):format(n) or ("Scan ERR: " .. tostring(err))
    scanning = false
    if alive then renderPanel() end
  end)
end

local function watch(name)
  task.spawn(function()
    local f = workspace:WaitForChild(name, 30)
    if not f or not alive then return end
    table.insert(conns, f.ChildAdded:Connect(function() dirty = true end))
    table.insert(conns, f.ChildRemoved:Connect(function(m) dropEntry(m) end))
    dirty = true
  end)
end
watch("PlacedRoads")
watch("Ships")

-- Anti AFK: Roblox menembak Players.LocalPlayer.Idled sebelum kick idle 20 menit; klik kanan virtual
-- (VirtualUser) dihitung sebagai input sehingga timer idle mulai dari nol. Game ini tidak punya AFK kick sendiri.
local VirtualUser = game:GetService("VirtualUser")
table.insert(conns, lp.Idled:Connect(function()
  if not opt.afk then return end
  pcall(function()
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
  end)
  afkCount = afkCount + 1
end))

local NUMPAD = { Enum.KeyCode.KeypadOne, Enum.KeyCode.KeypadTwo, Enum.KeyCode.KeypadThree, Enum.KeyCode.KeypadFour,
  Enum.KeyCode.KeypadFive, Enum.KeyCode.KeypadSix, Enum.KeyCode.KeypadSeven, Enum.KeyCode.KeypadEight }
table.insert(conns, UIS.InputBegan:Connect(function(i, processed)
  if processed then return end
  local k = i.KeyCode
  if k == Enum.KeyCode.Insert then
    gui.Enabled = not gui.Enabled
  elseif k == Enum.KeyCode.Equals then
    mark() renderPanel()
  elseif k == Enum.KeyCode.Minus then
    fullRescan()
  else
    for idx, kc in ipairs(NUMPAD) do
      if k == kc and CATS[idx] then CATS[idx].on = not CATS[idx].on renderPanel() end
    end
  end
end))

task.spawn(function()
  local lastScan, lastStream, lastPanel = 0, os.clock(), 0
  while alive do
    local now = os.clock()
    if dirty and now - lastScan >= RESCAN_DEBOUNCE then
      dirty, lastScan = false, now
      pcall(scan)
    end
    if opt.stream and now - lastStream >= STREAM_EVERY and not scanning then
      lastStream = now
      task.spawn(function() streamAll() dirty = true end)
    end
    pcall(updateLabels)
    if now - lastPanel >= 1 then lastPanel = now pcall(renderPanel) end
    task.wait(UPDATE_EVERY)
  end
end)

renderPanel()
fullRescan()

_G.BC_ESP_INT = {
  stop = function()
    alive = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    for m in pairs(entries) do dropEntry(m) end
    pcall(function() holder:Destroy() end)
    pcall(function() gui:Destroy() end)
  end,
}
