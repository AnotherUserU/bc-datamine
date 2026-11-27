-- Build and Conquer: TES "load" event rudal dengan memindah kamera. INTERNAL (Delta). Script terpisah dari hub.
-- Server hanya mengirim info peluncuran rudal (MissileFlight) ke pemain yang kameranya RELEVAN (dekat), dan
-- mengirim snapshot rudal yang sedang terbang saat kamera baru masuk ke suatu area (lihat PerformanceChecks
-- "lateViewer" di kode game). Event intercept diterima semua pemain, jadi dipakai sebagai pembanding.
-- Tes 3 fase (jangan sentuh game selama tes):
--   1. NORMAL      2 menit: kamera diam, hanya menghitung
--   2. BERPUTAR    2 menit: kamera (sungguhan) berpindah bergiliran ke 3 titik pertempuran terbesar, 8 dtk per titik
--   3. NORMAL LAGI 1 menit: kamera kembali, menghitung lagi
-- Cakupan = dari rudal yang dicegat pada fase itu, berapa % yang info peluncurannya kita terima.
-- Hasil di panel + file bc_loadtest.txt. Jalankan ulang = versi lama berhenti.
if game.GameId ~= 10757247806 then return end
local G = (getgenv and getgenv()) or _G
if G.BC_LOADTEST then pcall(G.BC_LOADTEST.stop) G.BC_LOADTEST = nil end
local GUI_PARENT = (gethui and gethui()) or game:GetService("CoreGui")
local RUN_ID = ("%04x"):format(math.random(0, 0xffff))
GUI_PARENT:SetAttribute("BCLoadTestRun", RUN_ID)
for _, old in ipairs(GUI_PARENT:GetChildren()) do
  if old.Name == "BCLoadTest" then old:Destroy() end
end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local lp = Players.LocalPlayer
local MissileRemotes = RS:WaitForChild("MissileRemotes")

local PHASES = {
  { name = "1. NORMAL", seconds = 120, rotate = false },
  { name = "2. BERPUTAR", seconds = 120, rotate = true },
  { name = "3. NORMAL LAGI", seconds = 60, rotate = false },
}
local DWELL = 8              -- detik kamera di tiap titik pertempuran
local HOTSPOTS = 3           -- jumlah titik yang digilir
local CELL = 1000            -- stud; kotak pengelompokan intercept
local WINDOW = 60            -- detik; intercept terakhir yang dipakai mencari titik pertempuran
local GRACE = 5              -- detik; tunggu snapshot terlambat sebelum cakupan fase dihitung
local CAM_HEIGHT, CAM_BACK = 900, 700
local LOG_FILE = "bc_loadtest.txt"

local alive, running = true, false
local conns = {}
local seen = {}              -- missile id -> true (info peluncuran diterima)
local recentHits = {}        -- { t, pos } intercept untuk mencari titik pertempuran
local results = {}           -- per fase: { flights = n, intercepts = { id... } }
local phaseIdx, phaseEnd, statusText = 0, 0, "Siap. Tekan MULAI lalu jangan sentuh game."
local savedCam

local function current() return alive and GUI_PARENT:GetAttribute("BCLoadTestRun") == RUN_ID end
local function log(msg)
  local line = os.date("%H:%M:%S") .. " " .. msg .. "\n"
  pcall(function()
    local ok = appendfile and pcall(appendfile, LOG_FILE, line)
    if not ok then writefile(LOG_FILE, line) end
  end)
end

-- ===== dengar event rudal (tidak menyentuh GUI) =====
table.insert(conns, MissileRemotes:WaitForChild("MissileFlight").OnClientEvent:Connect(function(kind, batch)
  if kind ~= "VisualBatch" or type(batch) ~= "table" then return end
  for _, item in ipairs(batch) do
    local d = type(item) == "table" and item[1]
    if type(d) == "table" and d.id then
      if not seen[d.id] and results[phaseIdx] then results[phaseIdx].flights = results[phaseIdx].flights + 1 end
      seen[d.id] = true
    end
  end
end))
table.insert(conns, MissileRemotes:WaitForChild("MissileIntercepted").OnClientEvent:Connect(function(id, pos)
  if typeof(pos) == "Vector3" then recentHits[#recentHits + 1] = { t = os.clock(), pos = pos } end
  if results[phaseIdx] then table.insert(results[phaseIdx].intercepts, id) end
end))

-- ===== titik pertempuran terbesar dari intercept terakhir =====
local function hotspots()
  local now, cells, keep = os.clock(), {}, {}
  for _, h in ipairs(recentHits) do
    if now - h.t <= WINDOW then
      keep[#keep + 1] = h
      local key = math.floor(h.pos.X / CELL) .. "," .. math.floor(h.pos.Z / CELL)
      local c = cells[key] or { n = 0, sum = Vector3.zero }
      c.n, c.sum = c.n + 1, c.sum + h.pos
      cells[key] = c
    end
  end
  recentHits = keep
  local list = {}
  for _, c in pairs(cells) do list[#list + 1] = { n = c.n, center = c.sum / c.n } end
  table.sort(list, function(a, b) return a.n > b.n end)
  local out = {}
  for i = 1, math.min(HOTSPOTS, #list) do out[i] = list[i].center end
  return out
end

-- ===== kamera =====
local function cameraTo(center)
  local cam = workspace.CurrentCamera
  if not savedCam then savedCam = { type = cam.CameraType, subject = cam.CameraSubject, cframe = cam.CFrame } end
  cam.CameraType = Enum.CameraType.Scriptable
  cam.CFrame = CFrame.lookAt(center + Vector3.new(0, CAM_HEIGHT, CAM_BACK), center)
end
local function cameraBack()
  if not savedCam then return end
  local cam, s = workspace.CurrentCamera, savedCam
  savedCam = nil
  pcall(function()
    cam.CameraType = s.type
    cam.CameraSubject = s.subject
    cam.CFrame = s.cframe
  end)
end

-- ===== hasil =====
local function coverage(r)
  local hit, total = 0, 0
  for _, id in ipairs(r.intercepts) do
    total = total + 1
    if seen[id] then hit = hit + 1 end
  end
  return hit, total
end
local function resultText()
  local lines = {}
  for i, p in ipairs(PHASES) do
    local r = results[i]
    if r then
      local hit, total = coverage(r)
      lines[#lines + 1] = ("%s: rudal diterima %d (%.1f/mnt) | cakupan %s"):format(p.name, r.flights,
        r.flights / (p.seconds / 60), total > 0 and ("%d/%d intercept = %.0f%%"):format(hit, total, 100 * hit / total)
        or "belum ada intercept")
    end
  end
  return table.concat(lines, "\n")
end

local function runTest()
  running, seen, results = true, {}, {}
  log("=== tes mulai ===")
  for i, p in ipairs(PHASES) do
    if not current() or not running then break end
    phaseIdx = i
    results[i] = { flights = 0, intercepts = {} }
    phaseEnd = os.clock() + p.seconds
    log("fase " .. p.name)
    local spot = 1
    while os.clock() < phaseEnd and current() and running do
      if p.rotate then
        local spots = hotspots()
        if #spots > 0 then
          spot = (spot % #spots) + 1
          pcall(cameraTo, spots[spot])
          statusText = ("%s: kamera di titik %d/%d (%.0f, %.0f)"):format(p.name, spot, #spots, spots[spot].X, spots[spot].Z)
        else
          statusText = p.name .. ": belum ada intercept, menunggu pertempuran..."
        end
        task.wait(DWELL)
      else
        cameraBack()
        hotspots()
        statusText = p.name .. ": kamera diam, menghitung"
        task.wait(1)
      end
    end
    cameraBack()
  end
  phaseIdx = 0
  statusText = "Menunggu snapshot terlambat..."
  task.wait(GRACE)
  statusText = "Selesai. Kirim screenshot hasil / bc_loadtest.txt."
  log(resultText())
  running = false
end

-- ===== panel =====
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "BCLoadTest", false, 60
local frame = Instance.new("Frame")
frame.Size, frame.Position = UDim2.fromOffset(340, 210), UDim2.new(1, -352, 0, 80)
frame.BackgroundColor3, frame.BorderSizePixel, frame.Active, frame.Draggable = Color3.fromRGB(22, 24, 30), 0, true, true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)
local function label(y, h, size, font)
  local l = Instance.new("TextLabel")
  l.BackgroundTransparency, l.Position, l.Size = 1, UDim2.fromOffset(10, y), UDim2.new(1, -20, 0, h)
  l.Font, l.TextSize, l.TextColor3 = font or Enum.Font.GothamMedium, size or 12, Color3.fromRGB(225, 228, 235)
  l.TextXAlignment, l.TextYAlignment, l.TextWrapped, l.Text = Enum.TextXAlignment.Left, Enum.TextYAlignment.Top, true, ""
  l.Parent = frame
  return l
end
label(8, 18, 14, Enum.Font.GothamBold).Text = "Tes load event rudal (geser di sini)"
local btn = Instance.new("TextButton")
btn.Position, btn.Size = UDim2.fromOffset(10, 32), UDim2.new(1, -20, 0, 28)
btn.Font, btn.TextSize, btn.TextColor3, btn.BorderSizePixel = Enum.Font.GothamBold, 13, Color3.new(1, 1, 1), 0
btn.Parent = frame
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
local statusLbl = label(66, 34, 12)
local resultLbl = label(102, 100, 12, Enum.Font.Code)

local lastClick = 0
btn.MouseButton1Click:Connect(function()
  if not current() or os.clock() - lastClick < 0.5 then return end
  lastClick = os.clock()
  if running then
    running = false
    cameraBack()
    statusText = "Dihentikan."
    log("tes dihentikan")
  else
    task.spawn(runTest)
  end
end)
gui.Parent = GUI_PARENT

local function stop()
  alive, running = false, false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  cameraBack()
  pcall(function() gui:Destroy() end)
end
G.BC_LOADTEST = { stop = stop }

task.spawn(function()
  while current() and gui.Parent do
    pcall(function()
      btn.Text = running and "BERHENTI" or "MULAI TES (5 menit)"
      btn.BackgroundColor3 = running and Color3.fromRGB(170, 60, 60) or Color3.fromRGB(40, 150, 80)
      local left = running and phaseIdx > 0 and math.max(0, math.ceil(phaseEnd - os.clock())) or 0
      statusLbl.Text = statusText .. (left > 0 and ("  (sisa %d dtk)"):format(left) or "")
      resultLbl.Text = resultText()
    end)
    task.wait(0.5)
  end
  stop()
end)
