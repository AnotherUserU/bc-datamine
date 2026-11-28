-- Build and Conquer: PROBE auto build (tahap 0). INTERNAL (Delta). Script terpisah.
-- 1. Saat jalan: catat data plot, chunk lahan, city level, dan aturan gedung kunci ke bc_build_probe.txt.
-- 2. Tombol TES BANGUN: pasang 1 jalan + 1 rumah di tengah chunk awal lewat remote game yang sama dengan
--    tombol Place (BuildPlacementRemotes.PlaceBatch), lalu catat jawaban server. Biaya: jalan $10 + rumah $50.
-- Kirim isi bc_build_probe.txt (folder workspace executor) supaya auto build bisa dibuat dengan format yang benar.
if game.GameId ~= 10757247806 then return end
local G = (getgenv and getgenv()) or _G
if G.BC_BUILDPROBE then pcall(G.BC_BUILDPROBE.stop) G.BC_BUILDPROBE = nil end
local GUI_PARENT = (gethui and gethui()) or game:GetService("CoreGui")
for _, old in ipairs(GUI_PARENT:GetChildren()) do
  if old.Name == "BCBuildProbe" then old:Destroy() end
end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer
local Placed = workspace:WaitForChild("PlacedRoads")
local LOG = "bc_build_probe.txt"
local KEY_TEMPLATES = { "Road", "PoorHouse", "House", "Terrace Apartment Block", "Water Tower", "WindTurbine",
  "SolarPanel", "CoalPowerPlant", "Mine", "SteelMill", "LargeSuburbanApartment", "Lowrise Apartment 1" }

local lines, alive, conns = {}, true, {}
local function out(fmt, ...)
  local ok, s = pcall(string.format, fmt, ...)
  lines[#lines + 1] = ok and s or tostring(fmt)
  pcall(writefile, LOG, table.concat(lines, "\n") .. "\n")
end
local function req(name)
  local ok, m = pcall(function() return require(RS:WaitForChild(name, 5)) end)
  return ok and m or nil
end
local function v3(v) return typeof(v) == "Vector3" and ("(%.1f, %.1f, %.1f)"):format(v.X, v.Y, v.Z) or tostring(v) end
local function flat(t, depth)
  if type(t) ~= "table" then return typeof(t) == "Vector3" and v3(t) or tostring(t) end
  if (depth or 0) > 1 then return "{...}" end
  local parts = {}
  for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. flat(v, (depth or 0) + 1) end
  table.sort(parts)
  return "{" .. table.concat(parts, ", ") .. "}"
end

local Catalog, PlotUtil, Chunks = req("BuildCatalog"), req("PlotUtil"), req("LandChunks")

-- ===== 1. data =====
local plot
local function dump()
  out("=== BC build probe %s ===", os.date("%Y-%m-%d %H:%M:%S"))
  local ls = lp:FindFirstChild("leaderstats")
  for _, s in ipairs(ls and ls:GetChildren() or {}) do out("leaderstats.%s = %s", s.Name, tostring(s.Value)) end
  for _, a in ipairs({ "HouseResidents", "ApartmentResidents", "HighestCityLevel", "UnlockedLandChunks" }) do
    out("player attr %s = %s", a, tostring(lp:GetAttribute(a)))
  end
  plot = PlotUtil and PlotUtil.GetOwnedPlot(lp.UserId)
  if not plot then out("PLOT TIDAK DITEMUKAN") return end
  out("plot %s pos=%s size=%s look=%s up=%s", plot:GetFullName(), v3(plot.Position), v3(plot.Size),
    v3(plot.CFrame.LookVector), v3(plot.CFrame.UpVector))
  for k, v in pairs(plot:GetAttributes()) do out("plot attr %s = %s", k, flat(v)) end
  if Chunks then
    local mask = Chunks.GetPlayerMask(lp, plot)
    out("chunk mask=%s (unlocked %d/%d), harga chunk berikut=%s", tostring(mask), Chunks.GetUnlockedCount(mask),
      Chunks.ChunkCount, tostring(Chunks.GetPurchasePrice(mask)))
    for z = 1, Chunks.GridSize do
      local row = {}
      for x = 1, Chunks.GridSize do row[#row + 1] = Chunks.IsUnlocked(mask, x, z) and "#" or "." end
      out("chunk baris z=%d: %s", z, table.concat(row, " "))
    end
  end
  local mine = 0
  for _, b in ipairs(Placed:GetChildren()) do
    if b:GetAttribute("PlacementOwnerUserId") == lp.UserId then mine = mine + 1 end
  end
  out("bangunan milikku sekarang: %d", mine)
  for _, t in ipairs(KEY_TEMPLATES) do
    local item = Catalog and Catalog.GetItemByTemplateName(t)
    if item then
      out("[%s] grid=%s snap=%s offset=%s road=%s rotStep=%s item=%s", t,
        tostring(Catalog.GetGridSize and select(2, pcall(Catalog.GetGridSize, t))),
        tostring(Catalog.GetSnapSize and select(2, pcall(Catalog.GetSnapSize, t))),
        flat(Catalog.GetGridOffset and select(2, pcall(Catalog.GetGridOffset, t))),
        tostring(Catalog.GetRoadAccessRadius and select(2, pcall(Catalog.GetRoadAccessRadius, t))),
        tostring(Catalog.GetRotationStep and select(2, pcall(Catalog.GetRotationStep, t))), flat(item))
    else
      out("[%s] tidak ada di katalog", t)
    end
  end
  -- model template (untuk ukuran tapak)
  for _, t in ipairs({ "Road", "PoorHouse", "Water Tower", "WindTurbine" }) do
    local found
    for _, d in ipairs(RS:GetDescendants()) do
      if d.Name == t and d:IsA("Model") then found = d break end
    end
    if found then
      local ok, size = pcall(found.GetExtentsSize, found)
      out("template model %s di %s ukuran=%s", t, found:GetFullName(), ok and v3(size) or "?")
    else
      out("template model %s tidak ada di ReplicatedStorage (mungkin diminta via RequestTemplate)", t)
    end
  end
  local remotes = RS:FindFirstChild("BuildPlacementRemotes")
  local names = {}
  for _, r in ipairs(remotes and remotes:GetChildren() or {}) do names[#names + 1] = r.Name .. ":" .. r.ClassName end
  out("BuildPlacementRemotes: %s", table.concat(names, ", "))
end

-- ===== 2. tes bangun =====
local function listen()
  local remotes = RS:FindFirstChild("BuildPlacementRemotes")
  local placed = remotes and remotes:FindFirstChild("RoadPlaced")
  if placed then
    table.insert(conns, placed.OnClientEvent:Connect(function(...)
      local args = { ... }
      for i, a in ipairs(args) do args[i] = flat(a) end
      out("RoadPlaced <- %s", table.concat(args, " | "))
    end))
  end
  table.insert(conns, Placed.ChildAdded:Connect(function(m)
    task.wait(0.5)
    if m:GetAttribute("PlacementOwnerUserId") == lp.UserId then
      local ok, cf = pcall(m.GetPivot, m)
      local okS, size = pcall(m.GetExtentsSize, m)
      out("BANGUNAN BARU %s template=%s pivot=%s ukuran=%s rot=%s", m.Name, tostring(m:GetAttribute("RoadTemplateName")),
        ok and v3(cf.Position) or "?", okS and v3(size) or "?",
        ok and ("%.0f"):format(math.deg(math.atan2(-cf.LookVector.X, -cf.LookVector.Z))) or "?")
    end
  end))
  local pg = lp:FindFirstChild("PlayerGui")
  local warnLbl = pg and pg:FindFirstChild("BuildModeGui") and pg.BuildModeGui:FindFirstChild("PlacementWarning", true)
  if warnLbl and warnLbl:IsA("TextLabel") then
    table.insert(conns, warnLbl:GetPropertyChangedSignal("Text"):Connect(function()
      out("PlacementWarning: %s", warnLbl.Text)
    end))
  end
end

local function testBuild()
  if not plot then out("tes batal: plot tidak ada") return end
  local batch = RS:WaitForChild("BuildPlacementRemotes"):WaitForChild("PlaceBatch")
  local sx, sz = Chunks.GetStartChunk(plot)
  local center = Chunks.GetChunkCenterWorld(plot, sx, sz, plot.Position.Y + plot.Size.Y * 0.5)
  -- jalan di grid 2 stud, rumah 6 stud di sebelahnya (dalam jarak akses jalan 4)
  local road = Vector3.new(math.floor(center.X / 2) * 2 + 1, center.Y, math.floor(center.Z / 2) * 2 + 1)
  local house = road + Vector3.new(6, 0, 0)
  out("TES: chunk awal (%d,%d) tengah=%s jalan=%s rumah=%s", sx, sz, v3(center), v3(road), v3(house))
  local ok1, e1 = pcall(batch.FireServer, batch, { { t = "Road", p = road, r = 0 } })
  out("kirim jalan: %s %s", tostring(ok1), tostring(e1 or ""))
  task.wait(2)
  local ok2, e2 = pcall(batch.FireServer, batch, { { t = "PoorHouse", p = house, r = 90 } })
  out("kirim rumah: %s %s", tostring(ok2), tostring(e2 or ""))
  task.wait(4)
  out("tes selesai. Kirim isi %s.", LOG)
end

-- ===== panel kecil =====
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "BCBuildProbe", false, 60
local frame = Instance.new("Frame")
frame.Size, frame.Position = UDim2.fromOffset(260, 96), UDim2.new(0, 12, 0, 120)
frame.BackgroundColor3, frame.BorderSizePixel, frame.Active, frame.Draggable = Color3.fromRGB(22, 24, 30), 0, true, true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local info = Instance.new("TextLabel")
info.BackgroundTransparency, info.Position, info.Size = 1, UDim2.fromOffset(10, 6), UDim2.new(1, -20, 0, 40)
info.Font, info.TextSize, info.TextColor3, info.TextWrapped = Enum.Font.GothamMedium, 12, Color3.fromRGB(225, 228, 235), true
info.TextXAlignment, info.TextYAlignment = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top
info.Text = "Probe auto build: data dicatat ke " .. LOG
info.Parent = frame
local btn = Instance.new("TextButton")
btn.Position, btn.Size = UDim2.fromOffset(10, 54), UDim2.new(1, -20, 0, 32)
btn.BackgroundColor3, btn.BorderSizePixel, btn.TextColor3 = Color3.fromRGB(40, 150, 80), 0, Color3.new(1, 1, 1)
btn.Font, btn.TextSize, btn.Text = Enum.Font.GothamBold, 13, "TES BANGUN (1 jalan + 1 rumah)"
btn.Parent = frame
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
local busy = false
table.insert(conns, btn.MouseButton1Click:Connect(function()
  if busy or not alive then return end
  busy = true
  btn.Text = "Mengetes..."
  task.spawn(function()
    pcall(testBuild)
    busy = false
  end)
end))
gui.Parent = GUI_PARENT

G.BC_BUILDPROBE = { stop = function()
  alive = false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  pcall(function() gui:Destroy() end)
end }

local ok, err = pcall(dump)
if not ok then out("dump error: %s", tostring(err)) end
pcall(listen)
task.spawn(function()
  while alive and gui.Parent do
    pcall(function()
      btn.Text = busy and "Mengetes..." or "TES BANGUN (1 jalan + 1 rumah)"
      info.Text = ("Probe auto build: %d baris dicatat ke %s"):format(#lines, LOG)
    end)
    task.wait(0.5)
  end
end)
