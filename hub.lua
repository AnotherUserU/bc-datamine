-- Build and Conquer HUB: ESP + rudal (auto-mark) + auto-capture + auto-shuffle dalam SATU script & SATU panel.
-- INTERNAL (Delta). Satu file karena executor menjalankan satu loadstring (pengecualian batas 800 baris).
-- Aturan thread (pelajaran dari "MACET render" / panel stuck "Label"): thread yang menggambar panel TIDAK pernah
-- memanggil fungsi game (remote, GameActions, modul game). Semua panggilan game ada di thread kerja; panel hanya
-- membaca variabel biasa. Error render ditampilkan di panel (tidak disembunyikan).
-- Jalankan ulang = versi lama (termasuk script ESP/capture/shuffle terpisah) berhenti sendiri.
-- Tombol: Insert/Delete = sembunyikan panel, "=" = MARK rudal, "-" = muat + scan ulang ESP.
if game.GameId ~= 10757247806 then return end
local G = (getgenv and getgenv()) or _G
for _, key in ipairs({ "BC_HUB", "BC_ESP_INT", "BC_CAPTURE", "BC_SHUFFLE" }) do
  for _, env in ipairs({ G, _G }) do
    if env[key] then pcall(env[key].stop) env[key] = nil end
  end
end
local GUI_PARENT = (gethui and gethui()) or game:GetService("CoreGui")
local RUN_ID = ("%04x"):format(math.random(0, 0xffff))
local K = {}                     -- konstanta (dikumpulkan: batas 200 local per fungsi di Luau)
GUI_PARENT:SetAttribute("BCHubRun", RUN_ID)
for _, a in ipairs({ "BCEspRun", "BCCaptureRun", "BCShuffleRun" }) do GUI_PARENT:SetAttribute(a, "hub") end
K.OLD_GUIS = { BCHub = true, BCEspInt = true, BCEspIntPanel = true, BCCapturePanel = true, BCShufflePanel = true }
for _, old in ipairs(GUI_PARENT:GetChildren()) do
  if K.OLD_GUIS[old.Name] then old:Destroy() end
end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local UIS = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")
local StarterGui = game:GetService("StarterGui")
local lp = Players.LocalPlayer

local GameActions = require(RS:WaitForChild("GameActions"))
local ZoneTypes = require(RS:WaitForChild("CaptureZoneTypes"))
local Politics = require(RS:WaitForChild("Politics"))
local ShipKinds
pcall(function() ShipKinds = require(RS:WaitForChild("ShipKinds", 10)) end)

local alive = true
local conns = {}
local function current() return alive and GUI_PARENT:GetAttribute("BCHubRun") == RUN_ID end
local function connect(signal, fn) conns[#conns + 1] = signal:Connect(fn) end
local function attr(i, k)
  local ok, v = pcall(i.GetAttribute, i, k)
  return ok and v or nil
end
local function playerName(id)
  local p = id and Players:GetPlayerByUserId(id)
  return p and p.Name or tostring(id)
end

-- ===== log aktivitas: satu file per KATEGORI per SESI (rejoin = sesi baru, file lama tidak tertimpa) =====
-- bchub/<tanggal_jam>_<server>_<kategori>.txt  + 6 baris terakhir per kategori untuk panel.
local HUB_DIR = "bchub"
local SESSION = os.date("%Y%m%d_%H%M%S") .. "_" .. tostring(game.JobId):sub(1, 8)
K.CATEGORY_FILE = { HUB = "hub", ESP = "esp", MIS = "rudal", CAP = "capture", SHUF = "shuffle" }
pcall(makefolder, HUB_DIR)
local recent = { ESP = {}, MIS = {}, CAP = {}, SHUF = {}, HUB = {} }
local logStarted = {}
-- Sensor data rahasia sebelum ditulis ke file / dikirim: URL webhook dan cookie Roblox (.ROBLOSECURITY).
-- Dipakai di setiap jalur tulis log dan di setiap data yang dikirim ke Discord.
local function redact(s)
  s = tostring(s)
  s = s:gsub("https?://[%w%.]*discord[%w]*%.com/api/webhooks/[%w_%-/]+", "[webhook disensor]")
  s = s:gsub("_|WARNING:%-DO%-NOT%-SHARE%-THIS[^%s\"']*", "[cookie disensor]")
  s = s:gsub("%.ROBLOSECURITY=[^%s;\"']+", ".ROBLOSECURITY=[cookie disensor]")
  return s
end
local function log(tag, msg)
  msg = redact(msg)
  local stamp = os.date("%H:%M:%S")
  local list = recent[tag]
  list[#list + 1] = stamp .. " " .. msg
  if #list > 6 then table.remove(list, 1) end
  local file = ("%s/%s_%s.txt"):format(HUB_DIR, SESSION, K.CATEGORY_FILE[tag] or "hub")
  local line = stamp .. " " .. msg .. "\n"
  pcall(function()
    if logStarted[file] and appendfile then appendfile(file, line) return end
    writefile(file, line)
    logStarted[file] = true
  end)
end
log("HUB", "=== BC Hub mulai ===")
local sendLog                  -- kirim log ke webhook Discord (didefinisikan di bagian WEBHOOK)

-- =====================================================================================================
-- ESP
-- =====================================================================================================
K.M_PER_STUD = 0.28
K.MAX_DIST_M = 1500
K.ESP_EVERY = 0.3
K.RESCAN_DEBOUNCE = 1
K.STREAM_EVERY = 90
K.LABEL_UP = 4
K.SUB_DIVE_Z = 1.5

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
for _, c in ipairs(CATS) do CAT[c.id] = c end
K.MINE_COLOR, K.DEAD_COLOR = Color3.fromRGB(80, 220, 80), Color3.fromRGB(150, 150, 150)
local esp = { mine = false, hideDead = true, stream = true, status = "Siap", scanning = false, dirty = true }
local entries = {}            -- model -> entry
local playerOn = {}           -- UserId -> false kalau dimatikan

local holder = Instance.new("Folder")
holder.Name = "BCEspInt"
holder.Parent = GUI_PARENT

local function norm(s) return (s:lower():gsub("[^%w]", "")) end
local function priorityOf(name)
  local n = norm(name)
  for i, tier in ipairs(PRIORITY_TIERS) do
    for _, w in ipairs(tier) do if n:find(w, 1, true) then return i end end
  end
  return #PRIORITY_TIERS + 1
end

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
  bb.MaxDistance = K.MAX_DIST_M / K.M_PER_STUD
  local t = Instance.new("TextLabel")
  t.BackgroundTransparency, t.Size = 1, UDim2.fromScale(1, 1)
  t.Font, t.TextSize, t.TextStrokeTransparency = Enum.Font.GothamBold, 13, 0
  t.Parent = bb
  if e.ship then
    bb.Adornee = firstPart(e.model)
    bb.StudsOffsetWorldSpace = Vector3.new(0, 12, 0)
  else
    local a = Instance.new("Attachment")
    a.WorldPosition = e.point + Vector3.new(0, K.LABEL_UP, 0)
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
  local name = m.Name:sub(1, 6) == "Placed" and m.Name:sub(7) or tmpl
  return { model = m, kind = kind, owner = tonumber(attr(m, "PlacementOwnerUserId")), name = name,
           prio = priorityOf(name), point = (gx and gz) and Vector3.new(gx, p.Position.Y, gz) or p.Position }
end

local function shipEntry(m)
  if not m:IsA("Model") then return nil end
  local sub = attr(m, "Submarine") == true
  local e = { model = m, kind = sub and "sub" or "ship", ship = true, owner = tonumber(attr(m, "OwnerUserId")),
              name = "Ship", prio = sub and #PRIORITY_TIERS + 2 or #PRIORITY_TIERS + 1 }
  if ShipKinds then
    -- nama kelas lewat fungsi game: di thread sendiri, hasilnya hanya ditulis ke tabel
    task.spawn(function()
      local ok, n = pcall(ShipKinds.ClassName, m)
      if ok and n then e.name = n end
    end)
  end
  return e
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
    if not entries[m] and firstPart(m) then
      local e = shipEntry(m)
      if e then makeLabel(e) entries[m] = e end
    end
  end
  for m in pairs(entries) do if not seen[m] or not m.Parent then dropEntry(m) end end
end

local function isMine(e) return e.owner == lp.UserId end
local function isDead(e)
  if attr(e.model, "Destroyed") == true then return true end
  return not e.ship and attr(e.model, "Operational") == false
end
local function submerged(e)
  local mo = attr(e.model, "ShipMotion")
  return typeof(mo) == "Vector3" and mo.Z > K.SUB_DIVE_Z
end
local function posOf(e)
  if e.ship then
    local ok, cf = pcall(e.model.GetPivot, e.model)
    return ok and cf.Position or nil
  end
  return e.point
end

local function wanted(e, dead)
  if not CAT[e.kind].on then return false end
  if dead and esp.hideDead then return false end
  if isMine(e) then return esp.mine end
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
      local dist = p and math.floor((p - cam).Magnitude * K.M_PER_STUD + 0.5) or 0
      e.txt.Text = ("%s%s [%s]%s %dm"):format(dead and "[DEAD] " or "", e.name, playerName(e.owner), extraInfo(e), dist)
      e.txt.TextColor3 = dead and K.DEAD_COLOR or (isMine(e) and K.MINE_COLOR or CAT[e.kind].color)
    end
    if e.bb.Enabled ~= show then e.bb.Enabled = show end
  end
end

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

local function fullRescan()
  if esp.scanning then return end
  esp.scanning, esp.status = true, "Memuat semua plot..."
  task.spawn(function()
    streamAll()
    task.wait(2)
    local ok, err = pcall(scan)
    local n = 0
    for _ in pairs(entries) do n = n + 1 end
    esp.status = ok and ("Scan: %d objek"):format(n) or ("Scan ERR: " .. tostring(err))
    if not ok then log("ESP", esp.status) end
    esp.scanning = false
  end)
end

local function watchFolder(name)
  task.spawn(function()
    local f = workspace:WaitForChild(name, 30)
    if not f or not alive then return end
    connect(f.ChildAdded, function() esp.dirty = true end)
    connect(f.ChildRemoved, function(m) dropEntry(m) end)
    esp.dirty = true
  end)
end
watchFolder("PlacedRoads")
watchFolder("Ships")

-- ===== Sembunyikan gedung (HANYA di layar sendiri) selain air defense & peluncur rudal, supaya lebih ringan =====
-- Part/decal dibuat transparan lewat LocalTransparencyModifier (tidak digambar), partikel/lampu/GUI gedung dimatikan.
-- Tidak mengubah apa pun di server. Dimatikan / script berhenti = semua dikembalikan seperti semula.
K.KEEP_KIND = { ad = true, rudal = true }
K.HIDE_BATCH = 25            -- model per frame saat menyembunyikan (supaya tidak patah-patah)
local hideOpt = { on = false, count = 0, busy = false }
local hiddenModels = {}          -- model -> { conn, saved = { [instance] = Enabled lama } }
K.TOGGLE_CLASSES = { "ParticleEmitter", "Beam", "Trail", "Light", "Fire", "Smoke", "Sparkles", "SurfaceGui", "BillboardGui" }

local function keepVisible(m)
  local tmpl = attr(m, "RoadTemplateName") or (m.Name:sub(1, 6) == "Placed" and m.Name:sub(7)) or m.Name
  return K.KEEP_KIND[TEMPLATE_KIND[tmpl]] == true
end
local function hideInstance(rec, d)
  if d:IsA("BasePart") or d:IsA("Decal") then d.LocalTransparencyModifier = 1 return end
  for _, cls in ipairs(K.TOGGLE_CLASSES) do
    if d:IsA(cls) then
      if rec.saved[d] == nil then rec.saved[d] = d.Enabled end
      d.Enabled = false
      return
    end
  end
end
local function hideModel(m)
  if hiddenModels[m] or keepVisible(m) then return end
  local rec = { saved = {} }
  hiddenModels[m] = rec
  hideOpt.count = hideOpt.count + 1
  for _, d in ipairs(m:GetDescendants()) do pcall(hideInstance, rec, d) end
  rec.conn = m.DescendantAdded:Connect(function(d) pcall(hideInstance, rec, d) end)
end
local function showModel(m)
  local rec = hiddenModels[m]
  if not rec then return end
  hiddenModels[m] = nil
  hideOpt.count = hideOpt.count - 1
  pcall(function() rec.conn:Disconnect() end)
  if not m.Parent then return end
  for _, d in ipairs(m:GetDescendants()) do
    if d:IsA("BasePart") or d:IsA("Decal") then pcall(function() d.LocalTransparencyModifier = 0 end) end
  end
  for d, was in pairs(rec.saved) do pcall(function() d.Enabled = was end) end
end
local function showAllBuildings()
  for m in pairs(hiddenModels) do showModel(m) end
end
local function applyHide()
  if hideOpt.busy then return end
  hideOpt.busy = true
  task.spawn(function()
    local placed = workspace:FindFirstChild("PlacedRoads")
    for i, m in ipairs(placed and placed:GetChildren() or {}) do
      if not hideOpt.on or not alive then break end
      pcall(hideModel, m)
      if i % K.HIDE_BATCH == 0 then task.wait() end
    end
    if not hideOpt.on then showAllBuildings() end
    hideOpt.busy = false
  end)
end
local function setHide(on)
  hideOpt.on = on
  log("ESP", "sembunyikan gedung: " .. (on and "ON" or "OFF"))
  if on then applyHide() else task.spawn(showAllBuildings) end
end
task.spawn(function()
  local placed = workspace:WaitForChild("PlacedRoads", 30)
  if not placed or not alive then return end
  connect(placed.ChildAdded, function(m)
    task.wait(1)               -- tunggu atribut template terisi
    if hideOpt.on and alive then pcall(hideModel, m) end
  end)
  connect(placed.ChildRemoved, function(m)
    local rec = hiddenModels[m]
    if rec then pcall(function() rec.conn:Disconnect() end) hiddenModels[m] = nil hideOpt.count = hideOpt.count - 1 end
  end)
end)

-- =====================================================================================================
-- RUDAL: auto-mark lewat fungsi game MissileTargeting.assignTarget (getgc)
-- =====================================================================================================
local mis = { limit = 0, fill = false, baseKey = nil, status = "Buka targeting rudal + pilih munisi, lalu MARK", busy = false }

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
  for _, b in ipairs(bases()) do if b.key == mis.baseKey then return b end end
  return nil
end

local assignFn
local function findAssign()
  if assignFn or not getgc then return assignFn end
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

K.STOP_WORDS = { "limit reached", "No more", "Select a munition" }
local function isStop(msg)
  for _, w in ipairs(K.STOP_WORDS) do if tostring(msg):find(w, 1, true) then return true end end
  return false
end

local function markCandidates()
  local cam = workspace.CurrentCamera.CFrame.Position
  local base = selectedBase()
  local list = {}
  for _, e in pairs(entries) do
    local dead = isDead(e)
    local p = posOf(e)
    if p and not isMine(e) and not dead and wanted(e, dead) and not (e.kind == "sub" and submerged(e))
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

-- dijalankan di thread sendiri (memanggil fungsi game); hanya menulis mis.status
local function markWork()
  local fn = findAssign()
  if not fn then mis.status = "assignTarget tidak ketemu (buka targeting rudal dulu)" return end
  local limit = mis.limit > 0 and mis.limit or math.huge
  local list = markCandidates()
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
  until stopMsg or not mis.fill or passN == 0 or n >= limit
  mis.status = ("Marked %d dari %d target%s%s"):format(n, #list,
    skipped > 0 and (", %d ditolak"):format(skipped) or "",
    (n == 0 and stopMsg) and (" | " .. tostring(stopMsg)) or "")
  log("MIS", mis.status)
end
local function mark()
  if mis.busy then return end
  mis.busy, mis.status = true, "Marking..."
  task.spawn(function()
    local ok, err = pcall(markWork)
    if not ok then mis.status = "MARK ERR: " .. tostring(err) log("MIS", mis.status) end
    mis.busy = false
  end)
end

-- =====================================================================================================
-- AUTO CAPTURE (unit darat ke zona tengah, jalan bertahap + memutar kalau blocked)
-- =====================================================================================================
K.TICK = 3
K.LEG, K.LEG_MIN = 400, 40
K.STILL_STUD = 3
K.REORDER_MIN = 3
K.DETOURS = { 0, 45, -45, 90, -90 }
K.STUCK_ORDERS, K.STUCK_GAIN = 2, 10
K.MAX_FAILS = 6
K.BAN_SECONDS = 300
K.EDGE_INSET = 0.75
K.RETRY_TURN = 0.9
K.TICK_TIMEOUT = 20
K.DEBUG_UNITS = 8
K.PRIORITY = { "URANIUM MINE", "CITY", "INDUSTRIAL ZONE", "NUCLEAR POWER PLANT", "OIL FIELD", "MINING SITE", "AIRPORT" }

local cap = { on = false, garrison = true, perZone = 3, status = "OFF", lastResult = "", tickN = 0,
              lastTickAt = os.clock(), phase = "-", unitDebug = "", debug = true }
local zoneOn = {}
local assign = {}
local banned = {}

-- Judul zona dari modul game (CaptureZoneTypes) dihitung di thread kerja lalu disimpan; panel hanya membaca cache.
local titleCache = {}
local function cacheTitle(z)
  if titleCache[z.Name] then return end
  local ok, t = pcall(ZoneTypes.Get, z.Name)
  titleCache[z.Name] = { title = ok and t and t.title or z.Name, rig = ok and t and t.oilRig == true or false }
end
local function zoneTitle(z)
  local c = titleCache[z.Name]
  if c then return c.title, c.rig end
  return z.Name, false
end
local function zoneMine(z) return attr(z, "CaptureState") == "Captured" and attr(z, "CaptureOwnerUserId") == lp.UserId end
local function zoneStatus(z)
  local s, owner = attr(z, "CaptureState"), attr(z, "CaptureOwnerUserId")
  if s == "Contested" then return "CONTESTED" end
  if s ~= "Captured" or type(owner) ~= "number" or owner == 0 then return "kosong" end
  if owner == lp.UserId then return "MILIKMU" end
  return tostring(attr(z, "CaptureOwnerName") or owner)
end
local function inside(z, p)
  local o = z.CFrame:PointToObjectSpace(p)
  return math.abs(o.X) <= z.Size.X / 2 and math.abs(o.Z) <= z.Size.Z / 2
end
local function rank(z)
  local title = zoneTitle(z)
  for i, t in ipairs(K.PRIORITY) do if t == title then return i end end
  return #K.PRIORITY + 1
end
local function zones()
  local list = {}
  for _, z in ipairs(CS:GetTagged("CaptureZone")) do
    local _, rig = zoneTitle(z)
    if z:IsA("BasePart") and z.Parent and not rig then list[#list + 1] = z end
  end
  table.sort(list, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    return a.Name < b.Name
  end)
  return list
end
local function unitName(u) return tostring(attr(u, "UnitName") or u.Name) end

local function myUnits()
  local list = {}
  for _, folder in ipairs({ "MilitaryTrucks", "Squads" }) do
    local f = workspace:FindFirstChild(folder)
    for _, u in ipairs(f and f:GetChildren() or {}) do
      if u:IsA("Model") and attr(u, "OwnerUserId") == lp.UserId and attr(u, "Destroyed") ~= true then
        local ok, cf = pcall(u.GetPivot, u)
        if ok then list[#list + 1] = { unit = u, pos = cf.Position } end
      end
    end
  end
  return list
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local terrainRay = RaycastParams.new()
terrainRay.FilterType = Enum.RaycastFilterType.Include
terrainRay.FilterDescendantsInstances = { workspace.Terrain }
local function ground(p, z)
  local hit = workspace:Raycast(Vector3.new(p.X, p.Y + 500, p.Z), Vector3.new(0, -2000, 0), terrainRay)
  if hit then return hit.Position end
  rayParams.FilterDescendantsInstances = { z, lp.Character, workspace:FindFirstChild("MilitaryTrucks"),
    workspace:FindFirstChild("Squads") }
  hit = workspace:Raycast(Vector3.new(p.X, p.Y + 500, p.Z), Vector3.new(0, -2000, 0), rayParams)
  return hit and hit.Position or p
end
local function angleFrom(z, p)
  local o = z.CFrame:PointToObjectSpace(p)
  return math.atan2(o.Z, o.X)
end
local function edgePoint(a)
  local z = a.zone
  return z.CFrame:PointToWorldSpace(Vector3.new(math.cos(a.angle) * z.Size.X / 2 * K.EDGE_INSET, 0,
    math.sin(a.angle) * z.Size.Z / 2 * K.EDGE_INSET))
end
local function nextStep(a, pos)
  local goal = edgePoint(a)
  local flat = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
  local d = flat.Magnitude
  local turn = K.DETOURS[a.detour or 1]
  if turn == 0 then return ground(d > a.leg and (pos + flat.Unit * a.leg) or goal, a.zone) end
  local dir = CFrame.Angles(0, math.rad(turn), 0) * flat.Unit
  return ground(pos + dir * math.min(a.leg, d), a.zone)
end
local function nextDetour(a)
  a.detour = (a.detour or 1) % #K.DETOURS + 1
  if a.detour == 1 then
    a.angle = a.angle + K.RETRY_TURN
    return "semua arah dicoba, pindah ke sisi lain zona"
  end
  return ("belok %+d derajat"):format(K.DETOURS[a.detour])
end

K.FAIL_WORDS = { "block", "fail", "reject", "invalid", "cancel", "unreach" }
local function isFail(st)
  st = st:lower()
  for _, w in ipairs(K.FAIL_WORDS) do if st:find(w, 1, true) then return true end end
  return false
end

local function onOrderStatus(p)
  if not current() or type(p) ~= "table" or p.state == "Planning" then return end
  local reasons = {}
  if p.reason then reasons[#reasons + 1] = tostring(p.reason) end
  for _, r in ipairs(p.results or {}) do
    local a = type(r) == "table" and r.unit and assign[r.unit]
    if a then
      local st = tostring(r.state)
      local why = r.reason or r.message or r.error
      if why then reasons[#reasons + 1] = tostring(why) end
      a.result = st .. (why and (" (" .. tostring(why) .. ")") or "")
      if isFail(st) then
        a.fails = (a.fails or 0) + 1
        local how = nextDetour(a)
        a.leg = math.max(K.LEG_MIN, math.floor(a.leg / 2))
        a.orderedAt = 0
        log("CAP", ("SERVER %s: %s -> gagal %d/%d, %s, langkah %d"):format(unitName(r.unit), a.result, a.fails, K.MAX_FAILS, how, a.leg))
      else
        a.leg = math.min(K.LEG, a.leg * 2)
        if (a.detour or 1) ~= 1 then a.detourDone = true end
        if st:lower():find("arriv", 1, true) then a.orderedAt = 0 end
      end
    end
  end
  cap.lastResult = ("%s: %s moving, %s blocked%s"):format(tostring(p.state), tostring(p.moving or 0),
    tostring(p.blocked or 0), #reasons > 0 and (" (" .. table.concat(reasons, "; ") .. ")") or "")
end
pcall(function() connect(GameActions.UnitOrderStatusChanged, onOrderStatus) end)

local function release(u, why)
  log("CAP", ("LEPAS %s: %s"):format(unitName(u), why))
  assign[u] = nil
end
local function isBanned(u, z)
  local b = banned[u]
  return b ~= nil and b[z] ~= nil and b[z] > os.clock()
end

local function releaseStale(byUnit)
  for u, a in pairs(assign) do
    if not byUnit[u] then release(u, "unit hilang / hancur")
    elseif not a.zone.Parent then release(u, "zona hilang (tidak ter-stream)")
    elseif zoneOn[a.zone] == false then release(u, "zona dimatikan")
    elseif not cap.garrison and zoneMine(a.zone) then release(u, "zona sudah direbut")
    elseif (a.fails or 0) >= K.MAX_FAILS then
      banned[u] = banned[u] or {}
      banned[u][a.zone] = os.clock() + K.BAN_SECONDS
      release(u, ("gagal %dx ke %s, diganti unit lain"):format(a.fails, (zoneTitle(a.zone))))
    end
  end
end

local function assignUnits(units)
  local count = {}
  for _, a in pairs(assign) do count[a.zone] = (count[a.zone] or 0) + 1 end
  local pool = {}
  for _, e in ipairs(units) do if not assign[e.unit] then pool[#pool + 1] = e end end
  for _, z in ipairs(zones()) do
    if zoneOn[z] ~= false and not zoneMine(z) then
      local need = cap.perZone - (count[z] or 0)
      while need > 0 do
        local best, bd = nil, math.huge
        for i, e in ipairs(pool) do
          local d = (e.pos - z.Position).Magnitude
          if d < bd and not isBanned(e.unit, z) then best, bd = i, d end
        end
        if not best then break end
        local e = table.remove(pool, best)
        count[z] = (count[z] or 0) + 1
        assign[e.unit] = { zone = z, orderedAt = 0, leg = K.LEG, state = "baru", result = "-", fails = 0, detour = 1,
          angle = angleFrom(z, e.pos) + (count[z] - 1) * 0.5 }
        log("CAP", ("TUGAS %s -> %s (%d stud)"):format(unitName(e.unit), (zoneTitle(z)), math.floor(bd)))
        need = need - 1
      end
    end
  end
end

local function planOrders(byUnit)
  local now, orders = os.clock(), {}
  for u, a in pairs(assign) do
    local e = byUnit[u]
    local moving = a.lastPos and (e.pos - a.lastPos).Magnitude > K.STILL_STUD
    a.lastPos = e.pos
    a.dist = math.floor(Vector3.new(a.zone.Position.X - e.pos.X, 0, a.zone.Position.Z - e.pos.Z).Magnitude)
    if inside(a.zone, e.pos) then
      if a.state ~= "SAMPAI" then log("CAP", ("SAMPAI %s di %s"):format(unitName(u), (zoneTitle(a.zone)))) end
      a.state = "SAMPAI"
    elseif moving then
      a.state = "jalan"
    elseif now - a.orderedAt >= K.REORDER_MIN then
      if a.bestDist and a.dist >= a.bestDist - K.STUCK_GAIN then a.stuck = (a.stuck or 0) + 1
      else a.stuck, a.bestDist = 0, a.dist end
      if a.stuck >= K.STUCK_ORDERS then
        a.stuck, a.bestDist, a.detourDone = 0, nil, false
        a.fails = (a.fails or 0) + 1
        log("CAP", ("MACET %s sisa %d, gagal %d/%d, %s"):format(unitName(u), a.dist, a.fails, K.MAX_FAILS, nextDetour(a)))
      elseif a.detourDone then
        a.detour, a.detourDone = 1, false
      end
      orders[#orders + 1] = { unit = u, position = nextStep(a, e.pos) }
      a.orderedAt, a.state = now, "diperintah"
    else
      a.state = ("diam, tunggu %ds"):format(math.ceil(K.REORDER_MIN - (now - a.orderedAt)))
    end
  end
  return orders
end

local function evaluate()
  cap.tickN, cap.lastTickAt = cap.tickN + 1, os.clock()
  cap.phase = "zona"
  for _, z in ipairs(CS:GetTagged("CaptureZone")) do cacheTitle(z) end
  cap.phase = "cari unit"
  local units = myUnits()
  local byUnit = {}
  for _, e in ipairs(units) do byUnit[e.unit] = e end
  releaseStale(byUnit)
  cap.phase = "bagi unit"
  assignUnits(units)
  cap.phase = "hitung langkah"
  local orders = planOrders(byUnit)
  if #orders > 0 then
    task.spawn(function()
      local ok, res = pcall(GameActions.OrderUnits, orders, "Move")
      if not ok then log("CAP", "ERROR OrderUnits: " .. tostring(res))
      elseif res == false then log("CAP", "OrderUnits menolak (return false)") end
    end)
  end
  cap.phase = "debug"
  local lines, n = {}, 0
  for u, a in pairs(assign) do
    n = n + 1
    if #lines < K.DEBUG_UNITS then
      lines[#lines + 1] = unitName(u):sub(1, 14) .. " > " .. tostring((zoneTitle(a.zone))):sub(1, 10) .. " | "
        .. tostring(a.state) .. " | sisa " .. tostring(a.dist) .. " | step " .. tostring(a.leg)
        .. ((a.detour or 1) ~= 1 and (" belok " .. K.DETOURS[a.detour]) or "") .. " | gagal " .. tostring(a.fails or 0)
    end
  end
  cap.unitDebug = table.concat(lines, "\n")
  cap.status = ("Unit darat %d, ditugaskan %d%s\nServer: %s"):format(#units, n,
    #orders > 0 and (", perintah %d"):format(#orders) or "", cap.lastResult ~= "" and cap.lastResult or "-")
  cap.phase = "selesai"
end

-- =====================================================================================================
-- AUTO SHUFFLE sampai Augustus Vale (Politics.Rare, penanda r = true di pool)
-- State dibaca sendiri dari atribut JSON (tanpa fungsi game). Statistik + riwayat disimpan per akun di workspace.
-- =====================================================================================================
local SHUFFLE_COST = tonumber(Politics.ShuffleCost) or 25
local STATE_ATTR = Politics.StateAttribute or "PoliticsState"
local READY_ATTR = Politics.ReadyAttribute or "CityHallReady"
K.SHUFFLE_GAP = 1.5
K.STATE_WAIT = 5
K.HISTORY_MAX = 30
local ShuffleRemote = RS:WaitForChild(Politics.RemoteFolderName or "PoliticsRemotes"):WaitForChild("Shuffle")
local STATS_FILE = "bc_shuffle_stats_" .. lp.UserId .. ".json"

local shuf = { on = false, found = false, count = 0, spent = 0, fails = 0, pp = 0, ready = false,
               status = "OFF", pool = "-", err = "", history = {} }
pcall(function()
  if not (isfile and isfile(STATS_FILE)) then return end
  local saved = HttpService:JSONDecode(readfile(STATS_FILE))
  shuf.count = tonumber(saved.count) or 0
  shuf.spent = tonumber(saved.spent) or 0
  shuf.fails = tonumber(saved.fails) or 0
  if type(saved.history) == "table" then shuf.history = saved.history end
  log("SHUF", ("lanjut dari simpanan: %d shuffle, %d PP"):format(shuf.count, shuf.spent))
end)
local function saveShuffle()
  pcall(writefile, STATS_FILE, HttpService:JSONEncode({ count = shuf.count, spent = shuf.spent, fails = shuf.fails,
    history = shuf.history }))
end

local function readPolitics()
  local raw = lp:GetAttribute(STATE_ATTR)
  local empty = { pp = 0, pool = {} }
  if type(raw) ~= "string" or raw == "" then return empty end
  local ok, t = pcall(HttpService.JSONDecode, HttpService, raw)
  if not ok or type(t) ~= "table" then return empty end
  return { pp = math.floor(tonumber(t.pp) or 0), pool = type(t.pool) == "table" and t.pool or {} }
end
local function poolText(pool)
  local parts = {}
  for _, c in ipairs(pool) do
    if type(c) == "table" then
      parts[#parts + 1] = c.r == true and "AUGUSTUS VALE 5*" or ("%s %s*"):format(tostring(c.n or "?"), tostring(c.s or "?"))
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or "(kosong)"
end
local function rareIndex(pool)
  for i, c in ipairs(pool) do if type(c) == "table" and c.r == true then return i end end
  return nil
end
local function addHistory(text)
  table.insert(shuf.history, 1, os.date("%d/%m %H:%M") .. " " .. text)
  while #shuf.history > K.HISTORY_MAX do table.remove(shuf.history) end
end

local function onFound(pool, i)
  shuf.found, shuf.on = true, false
  shuf.status = ("AUGUSTUS DITEMUKAN (kandidat #%d)! Buka City Hall dan appoint."):format(i)
  addHistory(("#%d DITEMUKAN AUGUSTUS VALE"):format(shuf.count))
  saveShuffle()
  log("SHUF", ("DITEMUKAN Augustus slot %d setelah %d shuffle (%d PP). Pool: %s"):format(i, shuf.count, shuf.spent, poolText(pool)))
  pcall(StarterGui.SetCore, StarterGui, "SendNotification",
    { Title = "Auto Shuffle", Text = "Augustus Vale muncul! Buka City Hall dan appoint.", Duration = 30 })
  if sendLog then sendLog("AUGUSTUS VALE DITEMUKAN! Buka City Hall dan appoint.") end
end

local function shuffleOnce()
  local before = lp:GetAttribute(STATE_ATTR)
  local ok, res, msg = pcall(ShuffleRemote.InvokeServer, ShuffleRemote)
  if not ok or res ~= true then
    shuf.fails = shuf.fails + 1
    shuf.err = (ok and "ditolak: " or "error: ") .. tostring(ok and (msg or res) or res)
    addHistory("GAGAL " .. shuf.err)
    saveShuffle()
    log("SHUF", shuf.err)
    return
  end
  shuf.count, shuf.spent, shuf.err = shuf.count + 1, shuf.spent + SHUFFLE_COST, ""
  local t0 = os.clock()
  while lp:GetAttribute(STATE_ATTR) == before and os.clock() - t0 < K.STATE_WAIT do task.wait(0.1) end
  local s = readPolitics()
  shuf.pp, shuf.pool = s.pp, poolText(s.pool)
  addHistory(("#%d %s"):format(shuf.count, shuf.pool))
  saveShuffle()
  log("SHUF", ("#%d PP %d | %s"):format(shuf.count, s.pp, shuf.pool))
  local i = rareIndex(s.pool)
  if i then onFound(s.pool, i) end
end

local function shuffleStep()
  shuf.ready = lp:GetAttribute(READY_ATTR) == true
  local s = readPolitics()
  shuf.pp = s.pp
  if shuf.pool == "-" then shuf.pool = poolText(s.pool) end
  if not shuf.on then return 1 end
  if not shuf.ready then shuf.status = "City Hall belum jadi / belum ada" return 2 end
  local i = rareIndex(s.pool)
  if i then onFound(s.pool, i) return 1 end
  if s.pp < SHUFFLE_COST then
    shuf.status = ("Menunggu PP %d/%d"):format(s.pp, SHUFFLE_COST)
    return 2
  end
  shuf.status = "Shuffle..."
  shuffleOnce()
  return K.SHUFFLE_GAP
end

-- =====================================================================================================
-- ANTI-AFK (bersama)
-- =====================================================================================================
local afk = { on = true, count = 0 }
pcall(function()
  local VirtualUser = game:GetService("VirtualUser")
  connect(lp.Idled, function()
    if not current() or not afk.on then return end
    pcall(function()
      VirtualUser:CaptureController()
      VirtualUser:ClickButton2(Vector2.new())
    end)
    afk.count = afk.count + 1
  end)
end)

-- =====================================================================================================
-- LOG PERANG (dulu combatlog.lua): hanya MENDENGAR event server soal rudal/interceptor + atribut air defense.
-- Satu file per sesi: bccombat/<waktu>_<server>.txt, ditambah tiap 5 dtk. Event handler tidak menyentuh GUI.
-- =====================================================================================================
local COMBAT_DIR = "bccombat"
K.COMBAT_FLUSH, K.COMBAT_DEPTH = 5, 4
K.COMBAT_WORDS = { "patriot", "missile", "radar", "intercept", "combat", "ciws", "defen", "launch", "naval", "ship", "torpedo" }
K.COMBAT_ATTRS = { "PatriotAmmo", "PatriotMagazine", "PatriotReadyAt", "PatriotResupplying", "PatriotEnabled", "Operational" }
local combat = { on = true, file = nil, events = 0, watched = 0, remotes = 0, lines = {}, written = false }
local combatWatched = {}

local function cfmt(v, depth)
  depth = depth or 0
  local t = typeof(v)
  if t == "table" then
    if depth >= K.COMBAT_DEPTH then return "{...}" end
    local parts = {}
    for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. cfmt(x, depth + 1) end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
  elseif t == "Instance" then
    local tmpl, owner = attr(v, "RoadTemplateName"), attr(v, "PlacementOwnerUserId")
    return "<" .. v:GetFullName() .. (tmpl and (" tmpl=" .. tostring(tmpl)) or "") .. (owner and (" owner=" .. tostring(owner)) or "") .. ">"
  elseif t == "Vector3" then
    return ("v3(%.1f,%.1f,%.1f)"):format(v.X, v.Y, v.Z)
  elseif t == "CFrame" then
    return ("cf(%.0f,%.0f,%.0f)"):format(v.X, v.Y, v.Z)
  elseif t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then return ("%d"):format(v) end
    if math.abs(v) >= 1e6 then return ("%.3f"):format(v) end
    return ("%.5g"):format(v)
  end
  return tostring(v)
end
local function cline(text)
  if combat.on then combat.lines[#combat.lines + 1] = ("%.3f %s"):format(workspace:GetServerTimeNow(), redact(text)) end
end

local function combatWatchBuilding(m)
  if combatWatched[m] or not m:IsA("Model") or attr(m, "PatriotMagazine") == nil then return end
  combatWatched[m] = true
  combat.watched = combat.watched + 1
  local p = m:GetPivot().Position
  local tag = ("%s owner=%s at=(%.0f,%.0f)"):format(tostring(attr(m, "RoadTemplateName")),
    tostring(attr(m, "PlacementOwnerUserId")), p.X, p.Z)
  local snap = {}
  for _, a in ipairs(K.COMBAT_ATTRS) do snap[#snap + 1] = a .. "=" .. cfmt(attr(m, a)) end
  cline("ADSNAP " .. tag .. " | " .. table.concat(snap, ", "))
  for _, a in ipairs(K.COMBAT_ATTRS) do
    connect(m:GetAttributeChangedSignal(a), function() cline(("ADATTR %s | %s=%s"):format(tag, a, cfmt(attr(m, a)))) end)
  end
end

local function combatFlush()
  if not combat.file or #combat.lines == 0 then return end
  local chunk = table.concat(combat.lines, "\n") .. "\n"
  combat.lines = {}
  if combat.written and appendfile then pcall(appendfile, combat.file, chunk)
  else pcall(writefile, combat.file, chunk) combat.written = true end
end

local function combatStart()
  if getgenv and getgenv().BC_COMBATLOG_STOP then pcall(getgenv().BC_COMBATLOG_STOP) end   -- combatlog.lua lama
  pcall(makefolder, COMBAT_DIR)
  combat.file = ("%s/%s.txt"):format(COMBAT_DIR, SESSION)
  combat.lines[#combat.lines + 1] = "-- mulai serverTime=" .. tostring(workspace:GetServerTimeNow())
  local found = {}
  for _, f in ipairs(RS:GetChildren()) do
    local low = f.Name:lower()
    for _, w in ipairs(K.COMBAT_WORDS) do
      if low:find(w, 1, true) then
        for _, r in ipairs(f:GetDescendants()) do
          if r:IsA("RemoteEvent") then
            found[#found + 1] = r:GetFullName()
            connect(r.OnClientEvent, function(...)
              if not combat.on then return end
              combat.events = combat.events + 1
              local args, parts = table.pack(...), {}
              for i = 1, args.n do parts[#parts + 1] = cfmt(args[i]) end
              cline(r.Name .. " " .. table.concat(parts, " | "))
            end)
          end
        end
        break
      end
    end
  end
  combat.remotes = #found
  combat.lines[#combat.lines + 1] = "-- mendengar: " .. table.concat(found, ", ")
  local placed = workspace:FindFirstChild("PlacedRoads")
  if placed then
    for _, m in ipairs(placed:GetChildren()) do pcall(combatWatchBuilding, m) end
    connect(placed.ChildAdded, function(m) task.wait(1) pcall(combatWatchBuilding, m) end)
  end
  log("HUB", ("log perang: %d remote, %d air defense -> %s"):format(#found, combat.watched, combat.file))
end

-- =====================================================================================================
-- WEBHOOK: kirim bc_hub_log.txt (+ ringkasan) ke webhook Discord milikmu. URL disimpan lokal di workspace.
-- =====================================================================================================
K.WEBHOOK_FILE = "bc_hub_webhook.txt"
local httpRequest = (syn and syn.request) or http_request or request or (http and http.request)
local hook = { url = "", every = 0, lastSent = os.clock(), status = "Belum diatur", busy = false }
K.AUTOSEND_FILE = "bc_hub_autosend.txt"   -- menit kirim otomatis, disimpan supaya autoexec tidak reset
pcall(function()
  if isfile and isfile(K.WEBHOOK_FILE) then hook.url = readfile(K.WEBHOOK_FILE):gsub("%s", "") end
  if isfile and isfile(K.AUTOSEND_FILE) then
    local n = tonumber((readfile(K.AUTOSEND_FILE):gsub("%s", "")))
    hook.every = (n and n > 0) and math.floor(n) * 60 or 0
  end
end)
local function validWebhook(url)
  return url:match("^https://discord%.com/api/webhooks/%d+/[%w_%-]+$") ~= nil
    or url:match("^https://discordapp%.com/api/webhooks/%d+/[%w_%-]+$") ~= nil
    or url:match("^https://%a+%.discord%.com/api/webhooks/%d+/[%w_%-]+$") ~= nil
end
-- Kunci: hub hanya jalan dengan URL webhook pemilik. Yang disimpan di script hanya hash-nya (FNV-1a 32 bit, dua arah),
-- jadi repo publik tidak membocorkan URL. Ini kunci ringan: source tetap bisa dibaca/diubah orang.
K.KEY_HASH = "fbf0ad5c9bbc9cb0"
local function mul32(a, b)
  return (a * (b % 65536) + ((a * math.floor(b / 65536)) % 65536) * 65536) % 4294967296
end
local function fnv(s)
  local h = 2166136261
  for i = 1, #s do h = mul32(bit32.bxor(h, s:byte(i)), 16777619) end
  return h
end
local function isKey(url)
  return validWebhook(url) and ("%08x%08x"):format(fnv(url), fnv(url:reverse())) == K.KEY_HASH
end
local unlocked = isKey(hook.url)
if hook.url ~= "" then hook.status = unlocked and "Siap" or "URL tersimpan bukan kunci yang benar" end

local function summary(note)
  return ("**BC Hub** (%s) %s\nShuffle: %d | PP terpakai: %d | PP: %d | Gagal: %d\nCapture: %s | Anti-AFK dicegah %dx"
    .. "\nLog perang: %d event, %d air defense dilacak")
    :format(lp.Name, note or "", shuf.count, shuf.spent, shuf.pp, shuf.fails, cap.on and "ON" or "OFF", afk.count,
      combat.events, combat.watched)
end

-- Yang sudah terkirim dicatat per file (berapa byte) di K.SENT_FILE, jadi yang dikirim hanya file baru atau bagian
-- baru dari file yang masih bertambah. Catatan baru disimpan SETELAH Discord menerima pesannya.
K.SENT_FILE = "bc_hub_sent.json"
local SEND_DIRS = { HUB_DIR, COMBAT_DIR }
K.MSG_MAX_BYTES = 8000000   -- batas lampiran webhook Discord ~10 MB per pesan
K.MSG_MAX_FILES = 9         -- batas Discord 10 lampiran per pesan
local sentBytes = {}            -- [file] = byte terkirim; sentBytes._done[file] = true -> file sesi lama, selesai
pcall(function()
  if isfile(K.SENT_FILE) then
    local t = HttpService:JSONDecode(readfile(K.SENT_FILE))
    if type(t) == "table" then sentBytes = t end
  end
end)
if type(sentBytes._done) ~= "table" then sentBytes._done = {} end
local function saveSent() pcall(writefile, K.SENT_FILE, HttpService:JSONEncode(sentBytes)) end
-- file dari sesi lain tidak akan bertambah lagi: setelah terkirim penuh, tidak perlu dibaca ulang
local function isOldSession(key) return not key:find(SESSION, 1, true) end

-- potongan yang belum terkirim: { key, from, to, size, data }, file terlama dulu
local function pendingChunks()
  combatFlush()
  local out, changed = {}, false
  for _, dir in ipairs(SEND_DIRS) do
    local ok, files = pcall(listfiles, dir)
    if ok and type(files) == "table" then
      table.sort(files)
      for _, path in ipairs(files) do
        local key = tostring(path):gsub("\\", "/")
        if key:sub(-4) == ".txt" and not sentBytes._done[key] then
          local okR, data = pcall(readfile, path)
          if okR and type(data) == "string" then
            local from = math.min(tonumber(sentBytes[key]) or 0, #data)
            if from >= #data and isOldSession(key) then
              sentBytes._done[key], changed = true, true
            end
            while from < #data do
              local to = math.min(#data, from + K.MSG_MAX_BYTES)
              out[#out + 1] = { key = key, from = from, to = to, size = #data, data = data:sub(from + 1, to) }
              from = to
            end
          end
        end
      end
    end
  end
  if changed then saveSent() end
  return out
end

local function attachName(c)
  local base = c.key:match("[^/]+$") or "log.txt"
  if c.key:find(COMBAT_DIR .. "/", 1, true) then base = "perang_" .. base end
  if c.from > 0 then base = base:gsub("%.txt$", "_lanjutan.txt") end
  return (base:gsub("[^%w_%.%-]", "_"))
end

local function post(content, files)
  local boundary = "----BCHub" .. RUN_ID .. math.random(100000, 999999)
  -- jaring pengaman: semua teks yang keluar disensor lagi (juga file lama yang ditulis sebelum ada sensor)
  local parts = { "--" .. boundary, 'Content-Disposition: form-data; name="payload_json"',
    "Content-Type: application/json", "", HttpService:JSONEncode({ content = redact(content):sub(1, 1900) }) }
  for i, f in ipairs(files) do
    for _, p in ipairs({ "--" .. boundary,
      ('Content-Disposition: form-data; name="files[%d]"; filename="%s"'):format(i - 1, f.name),
      "Content-Type: text/plain", "", redact(f.data) }) do parts[#parts + 1] = p end
  end
  parts[#parts + 1] = "--" .. boundary .. "--"
  parts[#parts + 1] = ""
  local res = httpRequest({ Url = hook.url, Method = "POST", Body = table.concat(parts, "\r\n"),
    Headers = { ["Content-Type"] = "multipart/form-data; boundary=" .. boundary } })
  local code = tonumber(res and (res.StatusCode or res.Status))
  if not code or code >= 300 then
    error(("Discord menolak (%s): %s"):format(tostring(code), tostring(res and res.Body or "")):sub(1, 200))
  end
end

-- return: jumlah potongan file yang terkirim
local function postLog(note)
  if not httpRequest then error("executor tidak punya fungsi request") end
  if not validWebhook(hook.url) then error("URL webhook belum diisi / tidak valid") end
  local chunks = pendingChunks()
  if #chunks == 0 then
    post(summary(note) .. "\n(tidak ada log baru)", {})
    return 0
  end
  local batch, bytes, sentN, msgN = {}, 0, 0, 0
  local function flushBatch()
    if #batch == 0 then return end
    msgN = msgN + 1
    local files, names = {}, {}
    for _, c in ipairs(batch) do
      files[#files + 1] = { name = attachName(c), data = c.data }
      names[#names + 1] = files[#files].name
    end
    post((msgN == 1 and summary(note) or "(lanjutan)") .. "\nFile: " .. table.concat(names, ", "), files)
    for _, c in ipairs(batch) do
      sentBytes[c.key] = c.to
      if c.to >= c.size and isOldSession(c.key) then sentBytes._done[c.key] = true end
    end
    saveSent()
    sentN = sentN + #batch
    batch, bytes = {}, 0
    task.wait(1.5)   -- jeda antar pesan (rate limit webhook)
  end
  for _, c in ipairs(chunks) do
    if #batch >= K.MSG_MAX_FILES or (#batch > 0 and bytes + #c.data > K.MSG_MAX_BYTES) then flushBatch() end
    batch[#batch + 1] = c
    bytes = bytes + #c.data
  end
  flushBatch()
  return sentN
end

sendLog = function(note)
  if hook.busy then return end
  hook.busy, hook.status = true, "Mengirim..."
  task.spawn(function()
    local ok, res = pcall(postLog, note)
    local err = res
    hook.status = ok and (res > 0 and ("Terkirim %d file baru, %s"):format(res, os.date("%H:%M:%S"))
      or ("Tidak ada log baru, " .. os.date("%H:%M:%S"))) or ("Gagal: " .. redact(err))
    if not ok then log("HUB", "webhook " .. hook.status) end
    hook.lastSent, hook.busy = os.clock(), false
  end)
end

-- =====================================================================================================
-- PANEL (satu jendela, 5 tab). Hanya membaca variabel; tidak memanggil fungsi game.
-- =====================================================================================================
local C = {
  bg = Color3.fromRGB(22, 24, 30), card = Color3.fromRGB(36, 39, 48), text = Color3.fromRGB(225, 228, 235),
  muted = Color3.fromRGB(150, 154, 165), on = Color3.fromRGB(40, 150, 80), off = Color3.fromRGB(80, 82, 92),
  gold = Color3.fromRGB(200, 150, 30), red = Color3.fromRGB(255, 110, 110), blue = Color3.fromRGB(130, 200, 255),
  green = Color3.fromRGB(120, 255, 120),
}
local function new(class, props, parent)
  local o = Instance.new(class)
  for k, v in pairs(props) do o[k] = v end
  if parent then o.Parent = parent end
  return o
end
local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 6) }, o) end

local W, H = 330, 460
local gui = new("ScreenGui", { Name = "BCHub", ResetOnSpawn = false, DisplayOrder = 50 })
local frame = new("Frame", { Size = UDim2.fromOffset(W, H), Position = UDim2.new(0, 12, 0.5, -H / 2),
  BackgroundColor3 = C.bg, BorderSizePixel = 0 }, gui)
corner(frame, 8)
local titleLbl = new("TextLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 6),
  Size = UDim2.new(1, -20, 0, 20), Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = C.text,
  TextXAlignment = Enum.TextXAlignment.Left, Text = "BC Hub  [Insert/Delete]  (seret di sini)" }, frame)
local hubErr = new("TextLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(10, H - 18),
  Size = UDim2.new(1, -20, 0, 16), Font = Enum.Font.Code, TextSize = 11, TextColor3 = C.red,
  TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Text = "" }, frame)

local function clickable(b, onClick)
  local last = 0
  connect(b.MouseButton1Click, function()
    if not current() or os.clock() - last < 0.35 then return end   -- emulator: klik ganda mouse+sentuh
    last = os.clock()
    onClick()
  end)
end

local TABS = { "ESP", "RUDAL", "CAPTURE", "SHUFFLE", "LOG" }
local pages, tabBtns, activeTab = {}, {}, "ESP"
local tabW = (W - 20) / #TABS
for i, name in ipairs(TABS) do
  local tb = new("TextButton", { Position = UDim2.fromOffset(10 + (i - 1) * tabW, 30), Size = UDim2.fromOffset(tabW - 4, 26),
    BackgroundColor3 = C.card, BorderSizePixel = 0, AutoButtonColor = false, Font = Enum.Font.GothamBold, TextSize = 11,
    TextColor3 = C.text, Text = name }, frame)
  corner(tb)
  clickable(tb, function() activeTab = name end)
  tabBtns[name] = tb
  local pg = new("ScrollingFrame", { BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(8, 90),
    Size = UDim2.new(1, -16, 1, -112), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarThickness = 4, Visible = false }, frame)
  new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, pg)
  new("UIPadding", { PaddingRight = UDim.new(0, 6) }, pg)
  pages[name] = pg
end
-- Baris atas: 3 tombol umum (Anti-AFK | Mode ringan | Sembunyikan gedung)
-- Mode ringan: dunia 3D tidak digambar + FPS dibatasi. Logika script tetap jalan; label ESP baru terlihat lagi
-- setelah mode ringan dimatikan.
K.LIGHT_FPS, K.NORMAL_FPS = 10, 60
local light = { on = false }
local RunService = game:GetService("RunService")
local function setLight(on)
  light.on = on
  pcall(function() RunService:Set3dRenderingEnabled(not on) end)
  if setfpscap then pcall(setfpscap, on and K.LIGHT_FPS or K.NORMAL_FPS) end
  log("HUB", "mode ringan: " .. (on and "ON" or "OFF"))
end
local topW = (W - 20) / 3
local function topButton(i, onClick)
  local b = new("TextButton", { Position = UDim2.fromOffset(10 + (i - 1) * topW, 60), Size = UDim2.fromOffset(topW - 4, 24),
    BackgroundColor3 = C.card, BorderSizePixel = 0, AutoButtonColor = false, Font = Enum.Font.GothamMedium, TextSize = 11,
    TextColor3 = C.text, Text = "" }, frame)
  corner(b)
  clickable(b, onClick)
  return b
end
local afkBtn = topButton(1, function() afk.on = not afk.on end)
local lightBtn = topButton(2, function() setLight(not light.on) end)
local hideBtn = topButton(3, function() setHide(not hideOpt.on) end)

local order = 0
local function nextOrder() order = order + 1 return order end
local function textLine(pg, color, font)
  return new("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
    Font = font or Enum.Font.GothamMedium, TextSize = 12, TextColor3 = color or C.text, TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = "",
    LayoutOrder = nextOrder() }, pg)
end
local function button(pg, onClick, swatch)
  local b = new("TextButton", { Size = UDim2.new(1, 0, 0, 26), BackgroundColor3 = C.card, BorderSizePixel = 0,
    AutoButtonColor = false, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.text, Text = "",
    TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = nextOrder() }, pg)
  corner(b)
  new("UIPadding", { PaddingLeft = UDim.new(0, swatch and 26 or 8) }, b)
  local sw
  if swatch then
    sw = new("Frame", { Size = UDim2.fromOffset(11, 11), Position = UDim2.new(0, -18, 0.5, -5), BorderSizePixel = 0,
      BackgroundColor3 = swatch }, b)
    corner(sw, 3)
  end
  clickable(b, onClick)
  return b, sw
end
local function input(pg, caption, placeholder, onCommit)
  local row = new("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = nextOrder() }, pg)
  new("TextLabel", { BackgroundTransparency = 1, Size = UDim2.new(0.5, -6, 1, 0), Font = Enum.Font.GothamMedium,
    TextSize = 12, TextColor3 = C.text, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true,
    Text = caption }, row)
  local box = new("TextBox", { Position = UDim2.new(0.5, 0, 0, 2), Size = UDim2.new(0.5, 0, 1, -4),
    BackgroundColor3 = C.card, BorderSizePixel = 0, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.text,
    PlaceholderText = placeholder, PlaceholderColor3 = C.muted, ClearTextOnFocus = false, Text = "" }, row)
  corner(box)
  connect(box.FocusLost, function() if current() then onCommit(box) end end)
  return box
end
local function numberOf(box) return tonumber((box.Text:gsub("%D", ""))) end

-- ----- tab ESP -----
local ui = {}
do
  local pg = pages.ESP
  ui.espCats = {}
  for _, c in ipairs(CATS) do
    local b, sw = button(pg, function() c.on = not c.on end, c.color)
    ui.espCats[c.id] = { b = b, sw = sw }
  end
  ui.espMine = button(pg, function() esp.mine = not esp.mine end)
  ui.espDead = button(pg, function() esp.hideDead = not esp.hideDead end)
  textLine(pg, C.muted).Text = "Pemain (klik untuk sembunyikan):"
  ui.espPlayers, ui.espPlayerIds = {}, {}
  for i = 1, 6 do
    ui.espPlayers[i] = button(pg, function()
      local id = ui.espPlayerIds[i]
      if id then playerOn[id] = playerOn[id] == false end
    end)
  end
  ui.espStream = button(pg, function() esp.stream = not esp.stream end)
  ui.espScan = button(pg, function() fullRescan() end)
  ui.espStatus = textLine(pg, C.muted)
end

-- ----- tab RUDAL -----
do
  local pg = pages.RUDAL
  textLine(pg, C.muted).Text = "Buka targeting rudal + pilih munisi di game, lalu MARK (atau tombol =). Target ikut "
    .. "kategori ESP yang ON; prioritas: Aquilla/S-500/Arrow3 > hypersonic > SAMP/S-400/PAC-3/EW > FP9/B-Strike/MRBM."
  ui.misBase = button(pg, function()
    local list, idx = bases(), 0
    for i, b in ipairs(list) do if b.key == mis.baseKey then idx = i end end
    local nxt = list[idx + 1]
    mis.baseKey = nxt and nxt.key or nil
  end)
  input(pg, "Limit MARK", "Auto (kosong)", function(box)
    local n = numberOf(box)
    mis.limit = (n and n > 0) and math.floor(n) or 0
    box.Text = mis.limit > 0 and tostring(mis.limit) or ""
  end)
  ui.misFill = button(pg, function() mis.fill = not mis.fill end)
  ui.misMark = button(pg, function() mark() end)
  ui.misStatus = textLine(pg)
end

-- ----- tab CAPTURE -----
do
  local pg = pages.CAPTURE
  ui.capOn = button(pg, function()
    cap.on = not cap.on
    assign, cap.unitDebug, cap.lastTickAt = {}, "", os.clock()
    log("CAP", "Auto Capture " .. (cap.on and "ON" or "OFF"))
  end)
  ui.capGar = button(pg, function() cap.garrison = not cap.garrison end)
  local perBox = input(pg, "Unit per zona", "3", function(box)
    local n = numberOf(box)
    cap.perZone = (n and n > 0) and math.floor(n) or cap.perZone
    box.Text = tostring(cap.perZone)
    assign = {}
    log("CAP", "Unit per zona = " .. cap.perZone)
  end)
  perBox.Text = tostring(cap.perZone)
  ui.capReward = textLine(pg, C.red)
  ui.capReward.Text = "Private server: zona TIDAK memberi hadiah"
  ui.capZones, ui.capZoneAt = {}, {}
  for i = 1, 10 do
    ui.capZones[i] = button(pg, function()
      local z = ui.capZoneAt[i]
      if z then zoneOn[z] = zoneOn[z] == false end
      assign = {}
    end)
  end
  ui.capStatus = textLine(pg, C.muted)
  ui.capBeat = textLine(pg)
  ui.capDbgBtn = button(pg, function() cap.debug = not cap.debug end)
  ui.capDbg = textLine(pg, Color3.fromRGB(190, 230, 190), Enum.Font.Code)
end

-- ----- tab SHUFFLE -----
do
  local pg = pages.SHUFFLE
  ui.shufOn = button(pg, function()
    shuf.found = false
    shuf.on = not shuf.on
    shuf.status = shuf.on and "ON" or "OFF"
    log("SHUF", shuf.on and "ON" or "OFF")
  end)
  ui.shufStatus = textLine(pg)
  ui.shufStats = textLine(pg, C.muted)
  ui.shufErr = textLine(pg, C.red)
  textLine(pg, C.muted).Text = "Pool sekarang:"
  ui.shufPool = textLine(pg)
  textLine(pg, C.muted).Text = ("Riwayat (terbaru di atas, %d terakhir, tersimpan di %s):"):format(K.HISTORY_MAX, STATS_FILE)
  ui.shufHist = textLine(pg, nil, Enum.Font.Code)
  button(pg, function()
    shuf.count, shuf.spent, shuf.fails, shuf.history = 0, 0, 0, {}
    saveShuffle()
    log("SHUF", "statistik direset")
  end).Text = "Reset statistik & riwayat"
end

-- ----- tab LOG -----
do
  local pg = pages.LOG
  textLine(pg, C.muted).Text = "Log aktivitas: folder " .. HUB_DIR .. "/ (1 file per kategori per sesi). Log perang: folder "
    .. COMBAT_DIR .. "/ (1 file per sesi). Rejoin = file baru. Kirim hanya mengirim file / bagian yang belum terkirim."
  local urlBox = input(pg, "URL webhook", "https://discord.com/api/webhooks/...", function(box)
    local url = box.Text:gsub("%s", "")
    if url == "" then return end
    if not isKey(url) then hook.status = "Bukan URL webhook kunci yang benar" return end
    hook.url, hook.status = url, "Tersimpan"
    pcall(writefile, K.WEBHOOK_FILE, url)
    box.Text = ""
  end)
  urlBox.TextTruncate = Enum.TextTruncate.AtEnd
  local everyBox = input(pg, "Auto kirim (menit)", "0 = mati", function(box)
    local n = numberOf(box)
    hook.every = (n and n > 0) and n * 60 or 0
    box.Text = hook.every > 0 and tostring(hook.every / 60) or ""
    pcall(writefile, K.AUTOSEND_FILE, tostring(hook.every / 60))
  end)
  everyBox.Text = hook.every > 0 and tostring(hook.every / 60) or ""
  ui.combatOn = button(pg, function() combat.on = not combat.on end)
  ui.combatInfo = textLine(pg, C.muted)
  ui.hookSend = button(pg, function() sendLog("(kirim manual)") end)
  ui.hookStatus = textLine(pg)
  textLine(pg, C.muted).Text = "Augustus ditemukan = log otomatis terkirim (kalau webhook sudah diisi)."
  ui.hookTail = textLine(pg, Color3.fromRGB(190, 230, 190), Enum.Font.Code)
end

-- ----- render -----
local function renderESP()
  local cnt, per = {}, {}
  for _, e in pairs(entries) do
    if not isMine(e) then
      if not isDead(e) then cnt[e.kind] = (cnt[e.kind] or 0) + 1 end
      if e.owner then per[e.owner] = (per[e.owner] or 0) + 1 end
    end
  end
  for i, c in ipairs(CATS) do
    local r = ui.espCats[c.id]
    r.sw.BackgroundTransparency = c.on and 0 or 0.75
    r.b.Text = ("[%d] %s (%d)"):format(i, c.label, cnt[c.id] or 0)
    r.b.TextColor3 = c.on and C.text or C.muted
  end
  ui.espMine.Text = "Tampilkan milik sendiri: " .. (esp.mine and "ON" or "OFF")
  ui.espDead.Text = "Sembunyikan yang hancur: " .. (esp.hideDead and "ON" or "OFF")
  local ids = {}
  for id in pairs(per) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return playerName(a) < playerName(b) end)
  ui.espPlayerIds = ids
  for i, b in ipairs(ui.espPlayers) do
    local id = ids[i]
    b.Visible = id ~= nil
    if id then
      b.Text = ("%s %s (%d)"):format(playerOn[id] == false and "[ ]" or "[x]", playerName(id), per[id])
      b.TextColor3 = playerOn[id] == false and C.muted or C.text
    end
  end
  ui.espStream.Text = ("Muat semua plot tiap %ds: %s"):format(K.STREAM_EVERY, esp.stream and "ON" or "OFF")
  ui.espScan.Text = ">> Muat semua + scan ulang  [-]"
  ui.espStatus.Text = esp.status
end

local function renderRudal()
  local b = selectedBase()
  ui.misBase.Text = "Base target: " .. (b and b.name or "Semua") .. "  (klik = ganti)"
  ui.misFill.Text = "Isi semua slot (ulang daftar): " .. (mis.fill and "ON" or "OFF")
  ui.misMark.Text = mis.busy and ">> Marking..." or ">> MARK  [=]"
  ui.misMark.BackgroundColor3 = mis.busy and C.off or C.gold
  ui.misStatus.Text = mis.status
end

local function renderCapture()
  ui.capOn.Text = "Auto Capture: " .. (cap.on and "ON (klik untuk berhenti)" or "OFF (klik untuk mulai)")
  ui.capOn.BackgroundColor3 = cap.on and C.on or C.off
  ui.capGar.Text = "Jaga zona yang sudah direbut: " .. (cap.garrison and "ON" or "OFF")
  ui.capReward.Visible = workspace:GetAttribute("CaptureRewardsOff") == true
  local per = {}
  for _, a in pairs(assign) do per[a.zone] = (per[a.zone] or 0) + 1 end
  local list = zones()
  for i, r in ipairs(ui.capZones) do
    local z = list[i]
    ui.capZoneAt[i] = z
    r.Visible = z ~= nil
    if z then
      local on = zoneOn[z] ~= false
      r.Text = ("[%s] %s - %s%s"):format(on and "x" or " ", (zoneTitle(z)), zoneStatus(z),
        per[z] and ("  (%d unit)"):format(per[z]) or "")
      r.TextColor3 = not on and C.muted or (zoneMine(z) and C.blue or C.text)
    end
  end
  ui.capStatus.Text = cap.on and cap.status
    or ("OFF. %d zona darat%s"):format(#list, #list == 0 and " (arahkan kamera ke tengah map)" or "")
  local ago = os.clock() - cap.lastTickAt
  if not cap.on then
    ui.capBeat.Text, ui.capBeat.TextColor3 = "Loop: hidup (OFF)", C.muted
  elseif ago <= K.TICK * 3 then
    ui.capBeat.Text, ui.capBeat.TextColor3 = ("Loop: JALAN tick #%d (%.0fs lalu)"):format(cap.tickN, ago), C.green
  else
    ui.capBeat.Text = ("Loop: MACET %.0fs, fase '%s'"):format(ago, cap.phase)
    ui.capBeat.TextColor3 = C.red
  end
  ui.capDbgBtn.Text = "Debug: " .. (cap.debug and "ON" or "OFF") .. "  (log: " .. HUB_DIR .. "/..._capture.txt)"
  ui.capDbg.Visible = cap.debug
  if cap.debug then
    local lines = { cap.unitDebug ~= "" and cap.unitDebug or "(belum ada unit ditugaskan)", "-- log --" }
    for _, l in ipairs(recent.CAP) do lines[#lines + 1] = l end
    ui.capDbg.Text = table.concat(lines, "\n")
  end
end

local function renderShuffle()
  ui.shufOn.Text = shuf.on and "Auto Shuffle: ON (klik untuk berhenti)"
    or (shuf.found and "DITEMUKAN - klik untuk lanjut" or "Auto Shuffle: OFF (klik untuk mulai)")
  ui.shufOn.BackgroundColor3 = shuf.found and C.gold or (shuf.on and C.on or C.off)
  ui.shufStatus.Text = shuf.status
  ui.shufStatus.TextColor3 = shuf.found and C.gold or C.text
  ui.shufStats.Text = ("Shuffle: %d | PP terpakai: %d | PP sekarang: %d | Gagal: %d\nCity Hall: %s | "
    .. "Peluang Augustus ~0,05%%/shuffle (rata-rata ~2000 shuffle)")
    :format(shuf.count, shuf.spent, shuf.pp, shuf.fails, shuf.ready and "siap" or "belum siap")
  ui.shufErr.Text = shuf.err
  ui.shufErr.Visible = shuf.err ~= ""
  ui.shufPool.Text = shuf.pool
  ui.shufHist.Text = #shuf.history > 0 and table.concat(shuf.history, "\n") or "(belum ada)"
end

local function renderLog()
  ui.combatOn.Text = "Log perang (rudal & intercept): " .. (combat.on and "ON" or "OFF")
  ui.combatOn.BackgroundColor3 = combat.on and C.on or C.off
  ui.combatInfo.Text = ("%d event, %d air defense dilacak, %d remote\nFile: %s"):format(
    combat.events, combat.watched, combat.remotes, combat.file or "(belum mulai)")
  ui.hookSend.Text = hook.busy and ">> Mengirim..." or ">> Kirim log sekarang"
  ui.hookSend.BackgroundColor3 = hook.busy and C.off or C.on
  ui.hookStatus.Text = ("Webhook: %s | otomatis: %s\nStatus: %s"):format(
    validWebhook(hook.url) and ("..." .. hook.url:sub(-6)) or "belum diisi",
    hook.every > 0 and ("tiap %d menit"):format(hook.every / 60) or "mati", hook.status)
  local lines = {}
  for _, tag in ipairs({ "HUB", "SHUF", "CAP", "MIS" }) do
    for _, l in ipairs(recent[tag]) do lines[#lines + 1] = tag .. " " .. l end
  end
  ui.hookTail.Text = #lines > 0 and table.concat(lines, "\n") or "(log kosong)"
end

local RENDER = { ESP = renderESP, RUDAL = renderRudal, CAPTURE = renderCapture, SHUFFLE = renderShuffle, LOG = renderLog }
local function render()
  for name, tb in pairs(tabBtns) do
    local on = name == activeTab
    tb.BackgroundColor3 = on and C.on or C.card
    pages[name].Visible = on
  end
  afkBtn.Text = ("Anti-AFK: %s%s"):format(afk.on and "ON" or "OFF", afk.count > 0 and (" (%d)"):format(afk.count) or "")
  afkBtn.BackgroundColor3 = afk.on and C.on or C.card
  lightBtn.Text = "Mode ringan: " .. (light.on and "ON" or "OFF")
  lightBtn.BackgroundColor3 = light.on and C.on or C.card
  hideBtn.Text = "Gedung: " .. (hideOpt.on and ("sembunyi (%d)"):format(hideOpt.count) or "tampil")
  hideBtn.BackgroundColor3 = hideOpt.on and C.on or C.card
  RENDER[activeTab]()
end

-- seret panel dari judul (mouse atau sentuh)
do
  local dragging, start, origin
  connect(titleLbl.InputBegan, function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
      dragging, start, origin = true, i.Position, frame.Position
    end
  end)
  connect(UIS.InputChanged, function(i)
    if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
      local d = i.Position - start
      frame.Position = UDim2.new(origin.X.Scale, origin.X.Offset + d.X, origin.Y.Scale, origin.Y.Offset + d.Y)
    end
  end)
  connect(UIS.InputEnded, function(i)
    if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
      dragging = false
    end
  end)
end

connect(UIS.InputBegan, function(i, processed)
  if processed or not current() or not unlocked then return end
  local k = i.KeyCode
  if k == Enum.KeyCode.Insert or k == Enum.KeyCode.Delete then
    gui.Enabled = not gui.Enabled
  elseif k == Enum.KeyCode.Equals then
    mark()
  elseif k == Enum.KeyCode.Minus then
    fullRescan()
  end
end)

-- Layar awal: minta URL webhook sebelum panel utama muncul (dilewati kalau sudah tersimpan & valid).
local function showWebhookPrompt()
  frame.Visible = false
  local box = new("Frame", { Size = UDim2.fromOffset(360, 170), Position = UDim2.new(0.5, -180, 0.5, -85),
    BackgroundColor3 = C.bg, BorderSizePixel = 0 }, gui)
  corner(box, 8)
  new("TextLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -24, 0, 54),
    Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = C.text, TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    Text = "BC Hub terkunci. Tempel URL webhook (kunci) dari pemilik script. Log kamu (.txt) akan dikirim ke "
      .. "channel Discord pemilik kunci. Disimpan lokal di Delta, cukup sekali." }, box)
  local field = new("TextBox", { Position = UDim2.fromOffset(12, 66), Size = UDim2.new(1, -24, 0, 30),
    BackgroundColor3 = C.card, BorderSizePixel = 0, Font = Enum.Font.Code, TextSize = 12, TextColor3 = C.text,
    PlaceholderText = "https://discord.com/api/webhooks/...", PlaceholderColor3 = C.muted, ClearTextOnFocus = false,
    TextTruncate = Enum.TextTruncate.AtEnd, Text = "" }, box)
  corner(field)
  local msg = new("TextLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 100), Size = UDim2.new(1, -24, 0, 18),
    Font = Enum.Font.GothamMedium, TextSize = 11, TextColor3 = C.red, TextXAlignment = Enum.TextXAlignment.Left, Text = "" }, box)
  local save = new("TextButton", { Position = UDim2.fromOffset(12, 126), Size = UDim2.new(1, -24, 0, 32),
    BackgroundColor3 = C.on, BorderSizePixel = 0, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = C.text,
    Text = "Buka kunci & mulai" }, box)
  corner(save)
  clickable(save, function()
    local url = field.Text:gsub("%s", "")
    if not isKey(url) then msg.Text = "Kunci salah. Minta URL webhook yang benar ke pemilik script." return end
    hook.url, hook.status = url, "Tersimpan"
    pcall(writefile, K.WEBHOOK_FILE, url)
    log("HUB", "kunci benar, hub dibuka")
    unlocked = true
    box:Destroy()
    frame.Visible = true
  end)
end
if not unlocked then showWebhookPrompt() end

gui.Parent = GUI_PARENT

local function stop()
  alive = false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  for m in pairs(entries) do dropEntry(m) end
  hideOpt.on = false
  pcall(showAllBuildings)      -- gedung yang disembunyikan dikembalikan
  if light.on then pcall(setLight, false) end   -- rendering 3D + FPS normal lagi
  pcall(function() holder:Destroy() end)
  pcall(function() gui:Destroy() end)
end
G.BC_HUB = { stop = stop }

local function running() return current() and gui.Parent ~= nil end
local function waitUnlock() while running() and not unlocked do task.wait(0.5) end end

-- ===== loop kerja ESP (label 3D) =====
task.spawn(function()
  waitUnlock()
  local lastScan, lastStream = 0, os.clock()
  while running() do
    local now = os.clock()
    if esp.dirty and now - lastScan >= K.RESCAN_DEBOUNCE then
      esp.dirty, lastScan = false, now
      local ok, err = pcall(scan)
      if not ok then esp.status = "Scan ERR: " .. tostring(err) end
    end
    if esp.stream and now - lastStream >= K.STREAM_EVERY and not esp.scanning then
      lastStream = now
      task.spawn(function() streamAll() esp.dirty = true end)
    end
    pcall(updateLabels)
    task.wait(K.ESP_EVERY)
  end
  stop()
end)

-- ===== loop kerja capture (watchdog: tick yang macet > K.TICK_TIMEOUT dilewati) =====
task.spawn(function()
  waitUnlock()
  while running() do
    pcall(function() for _, z in ipairs(CS:GetTagged("CaptureZone")) do cacheTitle(z) end end)
    if cap.on then
      local done = false
      task.spawn(function()
        local ok, err = pcall(evaluate)
        if not ok then cap.status = "ERR: " .. tostring(err) log("CAP", "ERROR evaluate: " .. tostring(err)) end
        done = true
      end)
      local t0 = os.clock()
      while not done and os.clock() - t0 < K.TICK_TIMEOUT do task.wait(0.25) end
      if not done then log("CAP", ("MACET di fase '%s' > %ds"):format(cap.phase, K.TICK_TIMEOUT)) end
    end
    task.wait(K.TICK)
  end
end)

-- ===== loop kerja shuffle =====
task.spawn(function()
  waitUnlock()
  while running() do
    local ok, res = pcall(shuffleStep)
    local delay = 1
    if ok then delay = res else
      shuf.err = "STEP error: " .. tostring(res)
      log("SHUF", shuf.err)
      delay = 3
    end
    task.wait(delay)
  end
end)

-- ===== log perang: mulai setelah kunci dibuka, tulis ke file tiap K.COMBAT_FLUSH dtk =====
task.spawn(function()
  waitUnlock()
  if not running() then return end
  local ok, err = pcall(combatStart)
  if not ok then log("HUB", "log perang gagal mulai: " .. tostring(err)) end
  while running() do
    task.wait(K.COMBAT_FLUSH)
    combatFlush()
  end
  combatFlush()
end)

-- ===== kirim log otomatis ke webhook =====
task.spawn(function()
  waitUnlock()
  while running() do
    if hook.every > 0 and validWebhook(hook.url) and os.clock() - hook.lastSent >= hook.every then
      sendLog("(otomatis)")
    end
    task.wait(10)
  end
end)

-- ===== loop panel (hanya menggambar) =====
task.spawn(function()
  local lastErr = ""
  while running() do
    local ok, err = pcall(render)
    local msg = ok and "" or ("Panel ERR: " .. tostring(err))
    hubErr.Text = msg
    if msg ~= "" and msg ~= lastErr then log("HUB", msg) end
    lastErr = msg
    task.wait(0.4)
  end
end)

task.spawn(function() waitUnlock() if running() then fullRescan() end end)
