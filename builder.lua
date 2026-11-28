-- Build and Conquer: AUTO BUILD tahap 1 (naik ke city level 5). INTERNAL (Delta). Script terpisah.
-- Mulai dari plot kosong (pakai Delete All dulu). Uang tidak dihemat. Urutan kerja tiap putaran:
--   1. Beli semua chunk lahan (LandChunkRemotes.PurchaseChunk, sama dengan tombol beli lahan).
--   2. Air & listrik DULU: Water Tower dan pembangkit (Wind -> Haunted Windmill -> Solar) di dekat area
--      yang akan dibangun. Gedung baru hanya dipasang kalau sudah dalam jangkauan air & listrik yang SELESAI
--      dibangun, dan kalau sisa listrik cukup.
--   3. Hunian: House sampai penghuni rumah 2.500 (syarat level 4), lalu apartemen terbaik yang sudah
--      ter-unlock (populasi per listrik) sampai populasi 20.000 / city level 5.
-- Tata letak: jalan mendatar tiap 14 stud + jalan tegak tiap 100 stud, gedung di sela jalan dengan jarak 1
-- stud (aman dari snap grid server), semua dalam 4 stud dari jalan.
-- Memakai remote yang sama dengan tombol Place di game (BuildPlacementRemotes.PlaceBatch).
-- Log: bc_build_log.txt. Jalankan ulang = versi lama berhenti.
if game.GameId ~= 10757247806 then return end
local G = (getgenv and getgenv()) or _G
if G.BC_BUILDER then pcall(G.BC_BUILDER.stop) G.BC_BUILDER = nil end
local GUI_PARENT = (gethui and gethui()) or game:GetService("CoreGui")
local RUN_ID = ("%04x"):format(math.random(0, 0xffff))
GUI_PARENT:SetAttribute("BCBuilderRun", RUN_ID)
G.BCBuilderRun = RUN_ID   -- dicek dari thread tombol: thread itu tidak boleh menyentuh gethui (capability)
for _, old in ipairs(GUI_PARENT:GetChildren()) do
  if old.Name == "BCBuilder" then old:Destroy() end
end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer
local Placed = workspace:WaitForChild("PlacedRoads")
local function req(name) return require(RS:WaitForChild(name, 10)) end
local Catalog, PlotUtil, Chunks, Avail = req("BuildCatalog"), req("PlotUtil"), req("LandChunks"), req("BuildAvailability")
local BuildRemotes = RS:WaitForChild("BuildPlacementRemotes")
local PlaceBatch = BuildRemotes:WaitForChild("PlaceBatch")

local K = {
  LOG_FILE = "bc_build_log.txt",
  TICK = 3,                 -- detik antar-putaran
  BATCH = 40,               -- gedung per putaran
  SEND_LIMIT = 64,          -- entri per PlaceBatch (sama dengan game)
  SEND_GAP = 0.4,
  ROAD_PITCH = 14,          -- jalan mendatar tiap 14 stud (blok 12 stud)
  ROAD_V_PITCH = 100,       -- jalan tegak tiap 100 stud
  ROAD_REACH = 4,           -- jarak maks tepi gedung ke tepi jalan (roadAccessRadius)
  GAP = 1,                  -- jarak antar-gedung (aman dari snap)
  HOUSE = "House",
  HOUSE_TARGET = 2600,      -- penghuni rumah (syarat level 4 = 2.500, +buffer)
  TARGET_LEVEL = 5,
  WIND_MAX = 20,
  ENERGY_MARGIN = 40,       -- sisa listrik minimal sebelum menambah gedung
  WATER = "Water Tower",
  GENERATORS = { "WindTurbine", "HauntedWindmill", "SolarPanel" },
  PENDING_TIME = 90,        -- detik: gedung baru dianggap masih memakan jatah listrik
}

local alive, running = true, false
local conns = {}
local st = { status = "Siap. Plot harus kosong / sesuai rencana. Tekan MULAI.", log = {}, warn = "", stats = "" }
local function current() return alive and G.BCBuilderRun == RUN_ID end
local logLines = {}
local function note(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  s = os.date("%H:%M:%S ") .. (ok and s or tostring(fmt))
  table.insert(st.log, 1, s)
  while #st.log > 10 do table.remove(st.log) end
  logLines[#logLines + 1] = s
  pcall(writefile, K.LOG_FILE, table.concat(logLines, "\n") .. "\n")
end

-- ===== plot & koordinat lokal (u,v = 0..600 dari pojok plot) =====
local plot, half
local function toWorld(u, v)
  local p = plot.CFrame:PointToWorldSpace(Vector3.new(u - half.X, 0, v - half.Z))
  return Vector3.new(p.X, plot.Position.Y + plot.Size.Y * 0.5, p.Z)
end
local function toLocal(pos)
  local p = plot.CFrame:PointToObjectSpace(pos)
  return p.X + half.X, p.Z + half.Z
end
local function chunkOf(u, v)
  local size = plot.Size.X / Chunks.GridSize
  return math.floor(u / size) + 1, math.floor(v / size) + 1
end
local chunkMask = 0          -- di-cache tiap putaran (readCity) dan sesudah beli chunk
local function unlocked(u, v)
  local cx, cz = chunkOf(u, v)
  return cx >= 1 and cz >= 1 and cx <= Chunks.GridSize and cz <= Chunks.GridSize
    and Chunks.IsUnlocked(chunkMask, cx, cz)
end

-- ===== data gedung =====
local itemCache, footCache = {}, {}
local function item(t)
  if itemCache[t] == nil then itemCache[t] = Catalog.GetItemByTemplateName(t) or false end
  return itemCache[t] or nil
end
local function isUnlockedT(t)
  local it = item(t)
  if not it or it.devOnly then return false end
  local ok, res = pcall(Avail.IsUnlocked, lp, it)
  return ok and res == true
end
-- ukuran tapak (lebar u, dalam v) dari placementFootprint atau model template game
local function footprint(t)
  if footCache[t] then return footCache[t][1], footCache[t][2] end
  local it = item(t)
  local fp = it and it.placementFootprint
  if typeof(fp) == "Vector2" then
    footCache[t] = { math.ceil(fp.X), math.ceil(fp.Y) }
    return footCache[t][1], footCache[t][2]
  end
  local folder = RS:FindFirstChild("PlacedDetail")
  local model = folder and folder:FindFirstChild(t)
  if not model then
    local remote = RS:FindFirstChild("BuildTemplateInterestRemotes")
    remote = remote and remote:FindFirstChild("RequestTemplate")
    if remote then pcall(remote.FireServer, remote, t) end
    model = folder and folder:WaitForChild(t, 6)
  end
  if not model then return nil end
  local ok, size = pcall(model.GetExtentsSize, model)
  if not ok then return nil end
  footCache[t] = { math.max(1, math.floor(size.X + 0.7)), math.max(1, math.floor(size.Z + 0.7)) }
  return footCache[t][1], footCache[t][2]
end

-- ===== keadaan kota (dibaca ulang tiap putaran) =====
local occ, roadSet, own = {}, {}, {}
local pending = {}            -- { t, energy } gedung yang baru dikirim
local function cellKey(u, v) return u .. ":" .. v end
local function markRect(u0, v0, w, d)
  for u = math.floor(u0), math.ceil(u0 + w) - 1 do
    for v = math.floor(v0), math.ceil(v0 + d) - 1 do occ[cellKey(u, v)] = true end
  end
end
local function readCity()
  occ, roadSet, own = {}, {}, { count = {}, energy = {}, water = {}, globalWater = false }
  chunkMask = Chunks.GetPlayerMask(lp, plot)
  for _, m in ipairs(Placed:GetChildren()) do
    if m:IsA("Model") and m:GetAttribute("PlacementOwnerUserId") == lp.UserId then
      local t = m:GetAttribute("RoadTemplateName")
      local okP, cf = pcall(m.GetPivot, m)
      local okS, size = pcall(m.GetExtentsSize, m)
      if t and okP and okS then
        local u, v = toLocal(cf.Position)
        markRect(u - size.X / 2, v - size.Z / 2, size.X, size.Z)
        own.count[t] = (own.count[t] or 0) + 1
        local it = item(t)
        local ready = m:GetAttribute("UnderConstruction") ~= true
        if it and it.kind == "Road" then roadSet[cellKey(math.floor(u + 0.5), math.floor(v + 0.5))] = true end
        if it and (it.energySupply or 0) > 0 and it.energyRange then
          own.energy[#own.energy + 1] = { u = u, v = v, r = it.energyRange, ready = ready }
        end
        if it and it.waterGlobalSupply and ready then own.globalWater = true end
        if it and (it.waterSupplyRange or 0) > 0 then
          own.water[#own.water + 1] = { u = u, v = v, r = it.waterSupplyRange, ready = ready }
        end
      end
    end
  end
end
local function covered(list, u, v, needReady)
  for _, s in ipairs(list) do
    -- jangkauan berbentuk kotak (tooltip game: range 150 = area 300x300), sisakan 5% untuk aman
    if (s.ready or not needReady) and math.abs(s.u - u) <= s.r * 0.95 and math.abs(s.v - v) <= s.r * 0.95 then
      return true
    end
  end
  return false
end
local function stat(name)
  local ls = lp:FindFirstChild("leaderstats")
  local s = ls and ls:FindFirstChild(name)
  return s and tonumber(s.Value) or 0
end
local function pendingEnergy()
  local now, sum, keep = os.clock(), 0, {}
  for _, p in ipairs(pending) do
    if now - p.at < K.PENDING_TIME then keep[#keep + 1] = p sum = sum + p.energy end
  end
  pending = keep
  return sum
end

-- ===== jalan =====
-- jalan mendatar: pusat v = 14k+1 (pita v 14k..14k+2); jalan tegak: pusat u = 100m+1. Ubin 2x2, pusat ganjil.
local function isRoadCell(u, v)
  local rv = v % K.ROAD_PITCH
  local ru = u % K.ROAD_V_PITCH
  return rv < 2 or ru < 2
end
local queueRoads = {}
local function wantRoad(u, v)   -- u,v = pusat ubin (ganjil)
  local key = cellKey(u, v)
  if roadSet[key] or queueRoads[key] or not unlocked(u, v) then return end
  queueRoads[key] = { u = u, v = v }
end
-- pastikan jalan di sekitar blok (u0..u1) pada pita atas & bawah blok k, plus jalan tegak terdekat
local function ensureRoadsFor(u0, u1, k)
  for _, bandV in ipairs({ K.ROAD_PITCH * k + 1, K.ROAD_PITCH * (k + 1) + 1 }) do
    for u = math.floor((u0 - 4) / 2) * 2 + 1, u1 + 4, 2 do wantRoad(u, bandV) end
  end
  local vu = math.floor(u0 / K.ROAD_V_PITCH) * K.ROAD_V_PITCH + 1
  for v = K.ROAD_PITCH * k + 1, K.ROAD_PITCH * (k + 1) + 1, 2 do wantRoad(vu, v) end
end

-- ===== mencari tempat =====
local function freeRect(u0, v0, w, d)
  for u = u0, u0 + w - 1 do
    for v = v0, v0 + d - 1 do
      if occ[cellKey(u, v)] or isRoadCell(u, v) or not unlocked(u, v) then return false end
    end
  end
  return true
end
-- baris-baris yang dekat jalan untuk gedung sedalam d di blok k (v dari 14k+2 sampai 14k+14)
local function rowsInBlock(k, d)
  local top, bottom, rows, seen = K.ROAD_PITCH * k + 2, K.ROAD_PITCH * (k + 1), {}, {}
  if d > bottom - top then return rows end
  local v = top
  while v + d <= bottom and v - top <= K.ROAD_REACH do
    rows[#rows + 1] = v seen[v] = true
    v = v + d + K.GAP
  end
  v = bottom - d
  while v >= top and bottom - (v + d) <= K.ROAD_REACH do
    local clash = false
    for _, r in ipairs(rows) do if v < r + d + K.GAP and r < v + d + K.GAP then clash = true end end
    if not clash then rows[#rows + 1] = v end
    v = v - d - K.GAP
  end
  return rows
end
-- urutan chunk: chunk awal dulu, lalu yang terdekat
local function chunkOrder()
  local sx, sz = Chunks.GetStartChunk(plot)
  local list = {}
  for x = 1, Chunks.GridSize do
    for z = 1, Chunks.GridSize do list[#list + 1] = { x = x, z = z, d = math.abs(x - sx) + math.abs(z - sz) } end
  end
  table.sort(list, function(a, b) return a.d < b.d end)
  return list
end
-- semua slot kosong untuk tapak w x d, berurutan dari chunk awal. Kembalikan { u0, v0, k }.
local scanSteps = 0
local function yieldSometimes()   -- loop pencarian panjang: beri jeda supaya game tidak membeku
  scanSteps = scanSteps + 1
  if scanSteps % 3000 == 0 then task.wait() end
end
local function slots(w, d, maxCount)
  local out, size = {}, plot.Size.X / Chunks.GridSize
  for _, c in ipairs(chunkOrder()) do
    local cu0, cv0 = (c.x - 1) * size, (c.z - 1) * size
    if unlocked(cu0 + 1, cv0 + 1) then
      for k = math.floor(cv0 / K.ROAD_PITCH), math.floor((cv0 + size) / K.ROAD_PITCH) do
        for _, v0 in ipairs(rowsInBlock(k, d)) do
          if v0 >= cv0 and v0 + d <= cv0 + size then
            local u = cu0
            while u + w <= cu0 + size do
              yieldSometimes()
              if freeRect(u, v0, w, d) then
                out[#out + 1] = { u0 = u, v0 = v0, k = k }
                if #out >= maxCount then return out end
                u = u + w + K.GAP
              else
                u = u + 1
              end
            end
          end
        end
      end
    end
  end
  return out
end

-- ===== mengirim =====
local function send(entries)
  for i = 1, #entries, K.SEND_LIMIT do
    if not (current() and running) then return end
    local chunk = {}
    for j = i, math.min(i + K.SEND_LIMIT - 1, #entries) do chunk[#chunk + 1] = entries[j] end
    pcall(PlaceBatch.FireServer, PlaceBatch, chunk)
    task.wait(K.SEND_GAP)
  end
end
local function flushRoads()
  local list = {}
  for key, r in pairs(queueRoads) do
    list[#list + 1] = { t = "Road", p = toWorld(r.u, r.v), r = 0 }
    roadSet[key] = true
  end
  queueRoads = {}
  if #list > 0 then
    send(list)
    note("jalan: %d ubin", #list)
  end
end
local function place(t, slot, w, d, entries)
  markRect(slot.u0, slot.v0, w + K.GAP, d + K.GAP)
  ensureRoadsFor(slot.u0, slot.u0 + w, slot.k)
  entries[#entries + 1] = { t = t, p = toWorld(slot.u0 + w / 2, slot.v0 + d / 2), r = 0 }
  local it = item(t)
  pending[#pending + 1] = { at = os.clock(), energy = it and it.energyDemand or 0 }
end

-- ===== layanan: air & listrik =====
local function limitOf(t)
  local ok, lim = pcall(Catalog.GetPlacementLimit, item(t), lp)
  return ok and lim or nil
end
local function canBuild(t)
  if not isUnlockedT(t) then return false end
  local lim = limitOf(t)
  return not lim or (own.count[t] or 0) < lim
end
local function nextGenerator()
  for _, t in ipairs(K.GENERATORS) do
    if canBuild(t) and footprint(t) then return t end
  end
  return nil
end
-- pasang satu layanan sedekat mungkin ke titik (u,v) yang butuh jangkauan
local function placeServiceNear(t, u, v, entries)
  local w, d = footprint(t)
  if not w then return false end
  local best, bestD
  for _, s in ipairs(slots(w, d, 400)) do
    local dist = (s.u0 + w / 2 - u) ^ 2 + (s.v0 + d / 2 - v) ^ 2
    if not bestD or dist < bestD then best, bestD = s, dist end
  end
  if not best then return false end
  place(t, best, w, d, entries)
  own.count[t] = (own.count[t] or 0) + 1
  local it = item(t)
  local list = (it.waterSupplyRange or 0) > 0 and own.water or own.energy
  list[#list + 1] = { u = best.u0 + w / 2, v = best.v0 + d / 2, r = it.waterSupplyRange or it.energyRange or 0, ready = false }
  note("layanan: %s di (%.0f, %.0f)", t, best.u0, best.v0)
  return true
end

-- ===== pilih hunian =====
local function bestApartment()
  local level, best, bestScore = stat("CityLevel"), nil, -1
  for _, it in pairs(Catalog.Items) do
    if type(it) == "table" and it.category == "Housing" and it.subcategory == "Apartments" and not it.devOnly
      and (it.minimumCityLevel or 1) <= level and canBuild(it.templateName) then
      local pop = it.effects and it.effects.population or 0
      local w, d = footprint(it.templateName)
      if pop > 0 and w and d <= K.ROAD_PITCH - 2 and (it.energyDemand or 0) > 0 then
        local score = pop / it.energyDemand + pop / (w * d) * 0.01
        if score > bestScore then best, bestScore = it.templateName, score end
      end
    end
  end
  return best
end
-- rumah (Residential) terbaik yang SUDAH ter-unlock: populasi terbanyak
local function bestHouse()
  local best, bestPop = nil, -1
  for _, it in pairs(Catalog.Items) do
    if type(it) == "table" and it.category == "Housing" and it.subcategory == "Residential" and not it.devOnly
      and canBuild(it.templateName) then
      local pop = it.effects and it.effects.population or 0
      if pop > bestPop and footprint(it.templateName) then best, bestPop = it.templateName, pop end
    end
  end
  return best
end
-- kenapa gedung terkunci (teks syarat dari game), untuk panel
local function lockReason(t)
  local it = item(t)
  if not it then return t .. ": tidak ada di katalog" end
  local ok, text = pcall(Avail.RequirementText, lp, it)
  return t .. ": " .. (ok and text ~= "" and text or "terkunci")
end
local function targetHousing()
  local houseRes = tonumber(lp:GetAttribute("HouseResidents")) or 0
  local houseResPlanned = 0
  for t, n in pairs(own.count) do
    local it = item(t)
    if it and it.category == "Housing" and it.subcategory == "Residential" then
      houseResPlanned = houseResPlanned + n * (it.effects and it.effects.population or 0)
    end
  end
  local house = bestHouse()
  if math.max(houseRes, houseResPlanned) < K.HOUSE_TARGET and house then return house end
  return bestApartment() or house
end

-- ===== beli chunk =====
-- InvokeServer bisa menunggu selamanya kalau server tidak menjawab, jadi diberi batas waktu
local function invokeTimeout(remote, timeout, ...)
  local args, done, ok, res = { ... }, false, false, nil
  task.spawn(function()
    ok, res = pcall(remote.InvokeServer, remote, table.unpack(args))
    done = true
  end)
  local t0 = os.clock()
  while not done and os.clock() - t0 < timeout do task.wait(0.1) end
  if not done then return false, "tidak dijawab server" end
  return ok, res
end
local function brief(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(x) end
  return "{" .. table.concat(parts, ", ") .. "}"
end
local function buyChunks()
  local remotes = RS:FindFirstChild("LandChunkRemotes")
  local buy = remotes and remotes:FindFirstChild("PurchaseChunk")
  if not buy then return end
  local tried = {}
  for _ = 1, Chunks.ChunkCount do
    local mask, bought = Chunks.GetPlayerMask(lp, plot), false
    for x = 1, Chunks.GridSize do
      for z = 1, Chunks.GridSize do
        local key = x .. ":" .. z
        if not tried[key] and not Chunks.IsUnlocked(mask, x, z) and Chunks.HasUnlockedNeighbor(mask, x, z) then
          tried[key] = true
          st.status = ("Membeli chunk (%d,%d)..."):format(x, z)
          local ok, res = invokeTimeout(buy, 8, x, z)
          note("beli chunk (%d,%d): %s", x, z, ok and brief(res) or tostring(res))
          bought = true
          task.wait(1)
          mask = Chunks.GetPlayerMask(lp, plot)
          chunkMask = mask
        end
      end
    end
    if not bought then break end
  end
  note("chunk terbuka: %d/%d", Chunks.GetUnlockedCount(Chunks.GetPlayerMask(lp, plot)), Chunks.ChunkCount)
end

-- ===== satu putaran =====
local function tick()
  st.status, st.warn = "Membaca kota...", ""
  readCity()
  local level = stat("CityLevel")
  st.stats = ("Level %d | Populasi %d | Penghuni rumah %s | Listrik sisa %d | Gedung %d")
    :format(level, stat("Population"), tostring(lp:GetAttribute("HouseResidents") or 0), stat("EnergyAvailable"),
      (function() local n = 0 for _, c in pairs(own.count) do n = n + c end return n end)())
  if level >= K.TARGET_LEVEL then
    st.status = "City level 5 tercapai. Tahap 1 selesai."
    running = false
    return
  end
  local entries = {}
  local sx, sz = Chunks.GetStartChunk(plot)
  local csize = plot.Size.X / Chunks.GridSize
  local homeU, homeV = (sx - 0.5) * csize, (sz - 0.5) * csize   -- tengah chunk awal
  -- air: citizen support kurang -> tambah Water Tower
  local unsupported = tonumber(lp:GetAttribute("UnsupportedCitizens")) or 0
  if unsupported > 0 and canBuild(K.WATER) then
    placeServiceNear(K.WATER, homeU, homeV, entries)
  end
  local t = targetHousing()
  if not t then
    st.status = "Belum ada hunian yang terbuka. " .. lockReason(K.HOUSE)
    return
  end
  local it = item(t)
  st.status = "Membaca ukuran " .. tostring(t) .. "..."
  local w, d = footprint(t)
  if not (it and w) then
    st.status = "Tidak bisa membaca ukuran " .. tostring(t)
    return
  end
  local energyLeft = stat("EnergyAvailable") - pendingEnergy() - K.ENERGY_MARGIN
  local budget = it.energyDemand and it.energyDemand > 0 and math.floor(energyLeft / it.energyDemand) or K.BATCH
  local placedN, needService, genPlaced = 0, nil, false
  st.status = ("Mencari tempat %s (%dx%d)..."):format(t, w, d)
  for _, s in ipairs(slots(w, d, K.BATCH * 3)) do
    if placedN >= math.min(K.BATCH, budget) then break end
    local cu, cv = s.u0 + w / 2, s.v0 + d / 2
    local needWater = it.waterRequired and not own.globalWater and not covered(own.water, cu, cv, true)
    local needEnergy = (it.energyDemand or 0) > 0 and not covered(own.energy, cu, cv, true)
    if needWater or needEnergy then
      needService = needService or { water = needWater, energy = needEnergy, u = cu, v = cv }
    else
      place(t, s, w, d, entries)
      placedN = placedN + 1
    end
  end
  -- layanan untuk area yang belum terjangkau (hanya kalau belum ada yang sedang dibangun di sana)
  if needService then
    if needService.water and not covered(own.water, needService.u, needService.v, false) then
      if canBuild(K.WATER) then
        placeServiceNear(K.WATER, needService.u, needService.v, entries)
      else
        st.warn = "Air: " .. lockReason(K.WATER)
      end
    end
    if needService.energy and not covered(own.energy, needService.u, needService.v, false) then
      local gen = nextGenerator()
      if gen then
        genPlaced = placeServiceNear(gen, needService.u, needService.v, entries)
      else
        local reasons = {}
        for _, g in ipairs(K.GENERATORS) do reasons[#reasons + 1] = lockReason(g) end
        st.warn = "Listrik: tidak ada pembangkit yang bisa dibangun (" .. table.concat(reasons, "; ") .. ")"
      end
    end
  end
  -- kapasitas listrik kurang -> tambah pembangkit (dekat area yang sedang dibangun)
  if budget < K.BATCH / 4 and not genPlaced and #pending < K.BATCH then
    local gen = nextGenerator()
    if gen then
      placeServiceNear(gen, needService and needService.u or homeU, needService and needService.v or homeV, entries)
    else
      st.warn = "Pembangkit habis (Wind maks, Haunted/Solar tidak tersedia)."
    end
  end
  flushRoads()
  if #entries > 0 then
    send(entries)
    note("kirim %d (%s x%d), listrik sisa %d", #entries, t, placedN, stat("EnergyAvailable"))
  end
  st.status = ("Membangun %s. %s"):format(t, placedN == 0 and "Menunggu listrik/air selesai dibangun..." or "")
end

local function runLoop()
  plot = PlotUtil.GetOwnedPlot(lp.UserId)
  if not plot then st.status = "Plot tidak ditemukan." running = false return end
  half = plot.Size * 0.5
  note("mulai. plot %s, ukuran %.0f", tostring(plot.Position), plot.Size.X)
  buyChunks()
  note("putaran bangun dimulai")
  while current() and running do
    local ok, err = pcall(tick)
    if not ok then note("error: %s", tostring(err)) end
    task.wait(K.TICK)
  end
  if st.status:find("Membangun") then st.status = "Dihentikan." end
end

-- peringatan dari game (ruang terisi, di luar jangkauan, dll)
pcall(function()
  local pg = lp:WaitForChild("PlayerGui", 5)
  local w = pg and pg:FindFirstChild("BuildModeGui") and pg.BuildModeGui:FindFirstChild("PlacementWarning", true)
  if w and w:IsA("TextLabel") then
    table.insert(conns, w:GetPropertyChangedSignal("Text"):Connect(function()
      if w.Text ~= "" then st.warn = w.Text note("game: %s", w.Text) end
    end))
  end
end)

-- ===== panel =====
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "BCBuilder", false, 60
local frame = Instance.new("Frame")
frame.Size, frame.Position = UDim2.fromOffset(330, 300), UDim2.new(0, 12, 0, 120)
frame.BackgroundColor3, frame.BorderSizePixel, frame.Active, frame.Draggable = Color3.fromRGB(22, 24, 30), 0, true, true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local function label(y, h, size, font, color)
  local l = Instance.new("TextLabel")
  l.BackgroundTransparency, l.Position, l.Size = 1, UDim2.fromOffset(10, y), UDim2.new(1, -20, 0, h)
  l.Font, l.TextSize, l.TextColor3 = font or Enum.Font.GothamMedium, size or 12, color or Color3.fromRGB(225, 228, 235)
  l.TextXAlignment, l.TextYAlignment, l.TextWrapped, l.Text = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top, true, ""
  l.Parent = frame
  return l
end
label(8, 18, 14, Enum.Font.GothamBold).Text = "Auto build tahap 1: city level 5"
local hideBtn = Instance.new("TextButton")
hideBtn.Position, hideBtn.Size, hideBtn.Text = UDim2.fromOffset(296, 6), UDim2.fromOffset(26, 22), "-"
hideBtn.BackgroundColor3, hideBtn.TextColor3, hideBtn.BorderSizePixel = Color3.fromRGB(55, 60, 75), Color3.new(1, 1, 1), 0
hideBtn.Parent = frame
local btn = Instance.new("TextButton")
btn.Position, btn.Size = UDim2.fromOffset(10, 32), UDim2.new(1, -20, 0, 30)
btn.Font, btn.TextSize, btn.TextColor3, btn.BorderSizePixel = Enum.Font.GothamBold, 13, Color3.new(1, 1, 1), 0
btn.Parent = frame
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
local statsLbl = label(68, 30, 12)
local statusLbl = label(100, 44, 12)
local logLbl = label(146, 150, 11, Enum.Font.Code, Color3.fromRGB(150, 155, 165))
local tab = Instance.new("TextButton")
tab.Position, tab.Size, tab.Text, tab.Visible = UDim2.new(0, 12, 0, 120), UDim2.fromOffset(80, 26), "BUILD", false
tab.BackgroundColor3, tab.TextColor3, tab.BorderSizePixel = Color3.fromRGB(22, 24, 30), Color3.new(1, 1, 1), 0
tab.Parent = gui

local lastClick = 0
table.insert(conns, btn.MouseButton1Click:Connect(function()
  if not current() or os.clock() - lastClick < 0.5 then return end
  lastClick = os.clock()
  if running then
    running = false
    st.status = "Menghentikan..."
  else
    running = true
    task.spawn(runLoop)
  end
end))
table.insert(conns, hideBtn.MouseButton1Click:Connect(function() frame.Visible, tab.Visible = false, true end))
table.insert(conns, tab.MouseButton1Click:Connect(function() frame.Visible, tab.Visible = true, false end))
gui.Parent = GUI_PARENT

local function stop()
  alive, running = false, false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  pcall(function() gui:Destroy() end)
end
G.BC_BUILDER = { stop = stop }

task.spawn(function()
  while current() and gui.Parent do
    pcall(function()
      btn.Text = running and "BERHENTI" or "MULAI"
      btn.BackgroundColor3 = running and Color3.fromRGB(170, 60, 60) or Color3.fromRGB(40, 150, 80)
      statsLbl.Text = st.stats
      statusLbl.Text = st.status .. (st.warn ~= "" and ("\nGame: " .. st.warn) or "")
      logLbl.Text = table.concat(st.log, "\n")
    end)
    task.wait(0.5)
  end
  stop()
end)
