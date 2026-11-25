-- Build and Conquer: auto-capture zona tengah. INTERNAL (Delta). Hanya unit darat.
-- Zona = part dengan tag CollectionService "CaptureZone" (nama CaptureZone..CaptureZone10, lihat CaptureZoneTypes).
-- Status: atribut CaptureState ("Captured"/"Contested") + CaptureOwnerUserId. Cara capture (dari game):
-- "Have the only units inside the border to take it." Oil rig (hanya kapal) dilewati.
-- Unit = model milik sendiri di workspace.MilitaryTrucks dan workspace.Squads, digerakkan lewat fungsi game
-- GameActions.OrderUnits (sama seperti perintah gerak biasa; server yang menentukan jalur).
-- Perjalanan jauh dipecah per langkah (LEG stud). Kalau server menjawab "blocked", langkah unit itu
-- diperpendek (setengahnya, min LEG_MIN). Alasan dari server ditampilkan di baris status.
-- Private server: zona tidak memberi hadiah (atribut workspace.CaptureRewardsOff), ditampilkan di panel.
-- Jalankan ulang = versi lama berhenti sendiri (tidak perlu rejoin): stop() lama dipanggil, panel lama
-- dihapus, dan tiap loop/handler mengecek token RUN; token berganti = berhenti.
if game.GameId ~= 10757247806 then return end
local G = (getgenv and getgenv()) or _G
for _, env in ipairs({ G, _G }) do
  if env.BC_CAPTURE then pcall(env.BC_CAPTURE.stop) env.BC_CAPTURE = nil end
end
local RUN = {}
G.BC_CAPTURE_RUN = RUN
if not game:IsLoaded() then game.Loaded:Wait() end
local GUI_PARENT = (gethui and gethui()) or game:GetService("CoreGui")
for _, old in ipairs(GUI_PARENT:GetChildren()) do
  if old.Name == "BCCapturePanel" then old:Destroy() end
end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local UIS = game:GetService("UserInputService")
local lp = Players.LocalPlayer

local TICK = 3                 -- dtk antar evaluasi
local LEG = 400                -- stud per langkah perjalanan
local LEG_MIN = 40             -- langkah terpendek setelah berkali-kali blocked
local STILL_STUD = 3           -- gerak kurang dari ini dalam 1 tick = diam
local REORDER_MIN = 6          -- dtk minimal antar perintah ke unit yang sama
local SPREAD = 0.3             -- unit disebar di lingkaran = SPREAD x setengah ukuran zona terkecil
local PRIORITY = { "URANIUM MINE", "CITY", "INDUSTRIAL ZONE", "NUCLEAR POWER PLANT", "OIL FIELD",
  "MINING SITE", "AIRPORT" }

local GameActions = require(RS:WaitForChild("GameActions"))
local ZoneTypes = require(RS:WaitForChild("CaptureZoneTypes"))

local alive, enabled, garrison = true, false, true
local perZone = 3
local zoneOn = {}              -- zona -> false kalau dimatikan di panel
local assign = {}              -- unit -> { zone, slot, orderedAt, lastPos, leg }
local conns = {}
local statusText = "OFF"
local lastResult = ""          -- jawaban server terakhir (state + alasan)
local debugOn = true
local DEBUG_UNITS = 8          -- maks unit yang tampil di panel debug

-- ===== debug: log ke panel (6 baris terakhir) + file bc_capture_log.txt di workspace executor =====
local LOG_FILE = "bc_capture_log.txt"
local logLines = {}
local tickN, lastTickAt = 0, os.clock()
local function log(msg)
  local line = os.date("%H:%M:%S") .. " " .. msg
  logLines[#logLines + 1] = line
  if #logLines > 6 then table.remove(logLines, 1) end
  pcall(function()
    if isfile and isfile(LOG_FILE) then appendfile(LOG_FILE, line .. "\n") else writefile(LOG_FILE, line .. "\n") end
  end)
end
log("=== script mulai ===")

local function attr(i, k)
  local ok, v = pcall(i.GetAttribute, i, k)
  return ok and v or nil
end

local function unitName(u) return tostring(attr(u, "UnitName") or u.Name) end

local function zoneTitle(z)
  local t = ZoneTypes.Get(z.Name)
  return t and t.title or z.Name, t and t.oilRig == true
end

local function zoneMine(z)
  return attr(z, "CaptureState") == "Captured" and attr(z, "CaptureOwnerUserId") == lp.UserId
end

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
  for i, t in ipairs(PRIORITY) do if t == title then return i end end
  return #PRIORITY + 1
end

-- zona darat saja (oil rig dilewati)
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

-- ===== unit darat milik sendiri =====
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

-- titik di tanah: tembak ray ke bawah, abaikan zona dan unit
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local function ground(p, z)
  local skip = { z, lp.Character }
  for _, n in ipairs({ "MilitaryTrucks", "Squads" }) do skip[#skip + 1] = workspace:FindFirstChild(n) end
  rayParams.FilterDescendantsInstances = skip
  local hit = workspace:Raycast(Vector3.new(p.X, p.Y + 500, p.Z), Vector3.new(0, -2000, 0), rayParams)
  return hit and hit.Position or p
end

local function slotPoint(z, slot)
  local r = math.min(z.Size.X, z.Size.Z) / 2 * SPREAD
  local a = (slot - 1) * 2.399      -- sudut emas: sebaran rata
  local off = slot == 1 and Vector3.zero or Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
  return z.Position + off
end

-- tujuan langkah berikutnya: maksimal a.leg stud dari posisi unit ke arah titik zona
local function nextStep(a, pos)
  local goal = slotPoint(a.zone, a.slot)
  local flat = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
  local d = flat.Magnitude
  local target = d > a.leg and (pos + flat.Unit * a.leg) or goal
  return ground(target, a.zone)
end

-- ===== jawaban server: kalau blocked, perpendek langkah =====
local function current() return alive and G.BC_CAPTURE_RUN == RUN end

local function onOrderStatus(p)
  if not current() or type(p) ~= "table" or p.state == "Planning" then return end
  local reasons = {}
  if p.reason then reasons[#reasons + 1] = tostring(p.reason) end
  for _, r in ipairs(p.results or {}) do
    if type(r) == "table" then
      local a = r.unit and assign[r.unit]
      local st = tostring(r.state)
      local why = r.reason or r.message or r.error
      if why then reasons[#reasons + 1] = tostring(why) end
      if a then
        a.result = st .. (why and (" (" .. tostring(why) .. ")") or "")
        if st ~= "Moving" and st ~= "Queued" then
          a.leg = math.max(LEG_MIN, math.floor(a.leg / 2))
          a.orderedAt = 0        -- coba lagi tick berikutnya dengan langkah lebih pendek
          log(("SERVER %s: %s -> langkah jadi %d stud"):format(unitName(r.unit), a.result, a.leg))
        else
          a.leg = math.min(LEG, a.leg * 2)   -- berhasil: langkah dipanjangkan lagi
        end
      end
    end
  end
  lastResult = ("%s: %s moving, %s blocked%s"):format(tostring(p.state), tostring(p.moving or 0),
    tostring(p.blocked or 0), #reasons > 0 and (" (" .. table.concat(reasons, "; ") .. ")") or "")
end
pcall(function() table.insert(conns, GameActions.UnitOrderStatusChanged:Connect(onOrderStatus)) end)

-- ===== pembagian unit =====
local function release(u, why)
  log(("LEPAS %s: %s"):format(unitName(u), why))
  assign[u] = nil
end

local function evaluate()
  tickN, lastTickAt = tickN + 1, os.clock()
  local units = myUnits()
  local byUnit = {}
  for _, e in ipairs(units) do byUnit[e.unit] = e end
  for u, a in pairs(assign) do
    if not byUnit[u] then release(u, "unit hilang / hancur / bukan milikmu lagi")
    elseif not a.zone.Parent then release(u, "zona hilang (tidak ter-stream)")
    elseif zoneOn[a.zone] == false then release(u, "zona dimatikan di panel")
    elseif not garrison and zoneMine(a.zone) then release(u, "zona sudah direbut, pindah ke zona lain")
    end
  end
  local count = {}
  for _, a in pairs(assign) do count[a.zone] = (count[a.zone] or 0) + 1 end
  local pool = {}
  for _, e in ipairs(units) do if not assign[e.unit] then pool[#pool + 1] = e end end
  for _, z in ipairs(zones()) do
    if zoneOn[z] ~= false and not zoneMine(z) then
      local need = perZone - (count[z] or 0)
      while need > 0 and #pool > 0 do
        local best, bd = 1, math.huge
        for i, e in ipairs(pool) do
          local d = (e.pos - z.Position).Magnitude
          if d < bd then best, bd = i, d end
        end
        local e = table.remove(pool, best)
        count[z] = (count[z] or 0) + 1
        assign[e.unit] = { zone = z, slot = count[z], orderedAt = 0, leg = LEG, state = "baru", result = "-" }
        log(("TUGAS %s -> %s (%d stud)"):format(unitName(e.unit), (zoneTitle(z)), math.floor(bd)))
        need = need - 1
      end
    end
  end
  -- perintah: unit yang diam dan belum di dalam zona dapat langkah berikutnya
  local now, orders = os.clock(), {}
  for u, a in pairs(assign) do
    local e = byUnit[u]
    local moving = a.lastPos and (e.pos - a.lastPos).Magnitude > STILL_STUD
    a.lastPos = e.pos
    a.dist = math.floor(Vector3.new(a.zone.Position.X - e.pos.X, 0, a.zone.Position.Z - e.pos.Z).Magnitude)
    local inZone = inside(a.zone, e.pos)
    if inZone then
      if a.state ~= "SAMPAI" then log(("SAMPAI %s di %s"):format(unitName(u), (zoneTitle(a.zone)))) end
      a.state = "SAMPAI"
    elseif moving then
      a.state = "jalan"
    else
      a.state = "diam"
      if now - a.orderedAt >= REORDER_MIN then
        orders[#orders + 1] = { unit = u, position = nextStep(a, e.pos) }
        a.orderedAt = now
        a.state = "diperintah"
      else
        a.state = ("diam, tunggu %ds"):format(math.ceil(REORDER_MIN - (now - a.orderedAt)))
      end
    end
  end
  if #orders > 0 then
    local ok, res = pcall(GameActions.OrderUnits, orders, "Move")
    if not ok then
      statusText = "Order ERR: " .. tostring(res)
      log("ERROR OrderUnits: " .. tostring(res))
      return
    end
    for _, o in ipairs(orders) do
      local a = assign[o.unit]
      log(("PERINTAH %s langkah %d stud, sisa %d stud ke %s"):format(unitName(o.unit), a.leg, a.dist, (zoneTitle(a.zone))))
    end
    if res == false then log("OrderUnits menolak (return false)") end
  end
  local n, legs = 0, {}
  for _, a in pairs(assign) do n = n + 1 legs[#legs + 1] = a.leg end
  table.sort(legs)
  statusText = ("Unit darat %d, ditugaskan %d%s, langkah %s stud\nServer: %s"):format(#units, n,
    #orders > 0 and (", perintah %d"):format(#orders) or "", legs[1] and tostring(legs[1]) or "-",
    lastResult ~= "" and lastResult or "-")
end

-- ===== panel =====
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "BCCapturePanel", false, 50
gui.Parent = GUI_PARENT
local W, ROW = 300, 22
local panel = Instance.new("Frame")
panel.Position, panel.BackgroundColor3, panel.BorderSizePixel = UDim2.fromOffset(300, 160), Color3.fromRGB(16, 15, 22), 0
panel.BackgroundTransparency = 0.1
panel.Parent = gui
local layout = Instance.new("UIListLayout")
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = panel

local nRows = 0
local function row(text, onClick)
  local b = Instance.new(onClick and "TextButton" or "TextLabel")
  b.Size, b.BackgroundTransparency, b.BorderSizePixel = UDim2.fromOffset(W, ROW), 1, 0
  b.Font, b.TextSize, b.TextXAlignment = Enum.Font.GothamBold, 13, Enum.TextXAlignment.Left
  b.TextColor3, b.TextStrokeTransparency, b.Text = Color3.fromRGB(215, 212, 228), 0.5, text
  nRows = nRows + 1
  b.LayoutOrder = nRows
  local pad = Instance.new("UIPadding")
  pad.PaddingLeft = UDim.new(0, 8)
  pad.Parent = b
  if onClick then
    b.AutoButtonColor = false
    b.MouseButton1Click:Connect(onClick)
  end
  b.Parent = panel
  return b
end

local render
local title = row("BC Auto Capture  [Delete]  (seret)")
title.TextColor3 = Color3.new(1, 1, 1)
local onRow = row("", function()
  enabled = not enabled
  assign = {}
  lastTickAt = os.clock()
  log("Auto Capture " .. (enabled and "ON" or "OFF"))
  render()
end)
local garRow = row("", function() garrison = not garrison render() end)
local perRow = row("Unit per zona:")
local perBox = Instance.new("TextBox")
perBox.Size, perBox.Position = UDim2.fromOffset(60, ROW - 4), UDim2.fromOffset(W - 76, 2)
perBox.BackgroundColor3, perBox.BorderSizePixel = Color3.fromRGB(40, 38, 52), 0
perBox.Font, perBox.TextSize, perBox.TextColor3 = Enum.Font.GothamBold, 13, Color3.new(1, 1, 1)
perBox.ClearTextOnFocus, perBox.Text = false, tostring(perZone)
perBox.Parent = perRow
table.insert(conns, perBox.FocusLost:Connect(function()
  local n = tonumber((perBox.Text:gsub("%D", "")))
  perZone = (n and n > 0) and math.floor(n) or perZone
  perBox.Text = tostring(perZone)
  assign = {}                -- bagi ulang dengan jumlah baru
  log("Unit per zona = " .. perZone .. " (semua unit dibagi ulang)")
end))
local rewardRow = row("Private server: zona TIDAK memberi hadiah")
rewardRow.TextColor3 = Color3.fromRGB(255, 130, 130)
local MAX_ZONES = 10
local zoneRows, zoneAt = {}, {}  -- zoneAt[i] = zona yang tampil di baris i
for i = 1, MAX_ZONES do
  zoneRows[i] = row("", function()
    local z = zoneAt[i]
    if z then
      zoneOn[z] = zoneOn[z] == false
      log(("Zona %s %s (semua unit dibagi ulang)"):format((zoneTitle(z)), zoneOn[z] == false and "dimatikan" or "dinyalakan"))
    end
    assign = {}
    render()
  end)
end
local statusRow = row("")
statusRow.TextColor3 = Color3.fromRGB(150, 150, 150)
statusRow.TextWrapped, statusRow.TextYAlignment = true, Enum.TextYAlignment.Top
statusRow.Size = UDim2.fromOffset(W, ROW * 4)
-- detak loop: diperbarui oleh loop terpisah, jadi kalau loop utama mati tetap kelihatan
local beatRow = row("")
local dbgToggle = row("", function() debugOn = not debugOn render() end)
local dbgRow = row("")
dbgRow.Font, dbgRow.TextSize = Enum.Font.Code, 12
dbgRow.TextColor3 = Color3.fromRGB(190, 230, 190)
dbgRow.TextWrapped, dbgRow.TextYAlignment = true, Enum.TextYAlignment.Top
dbgRow.Size = UDim2.fromOffset(W, ROW * 14)

render = function()
  onRow.Text = ">> Auto Capture: " .. (enabled and "ON" or "OFF")
  onRow.TextColor3 = enabled and Color3.fromRGB(120, 255, 120) or Color3.fromRGB(255, 220, 80)
  garRow.Text = "Jaga zona yang sudah direbut: " .. (garrison and "ON" or "OFF")
  rewardRow.Visible = workspace:GetAttribute("CaptureRewardsOff") == true
  local per = {}
  for _, a in pairs(assign) do per[a.zone] = (per[a.zone] or 0) + 1 end
  local list = zones()
  for i, r in ipairs(zoneRows) do
    local z = list[i]
    zoneAt[i] = z
    r.Visible = z ~= nil
    if z then
      local on = zoneOn[z] ~= false
      r.Text = ("[%s] %s - %s%s"):format(on and "x" or " ", (zoneTitle(z)), zoneStatus(z),
        per[z] and ("  (%d unit)"):format(per[z]) or "")
      r.TextColor3 = not on and Color3.fromRGB(120, 120, 120)
        or (zoneMine(z) and Color3.fromRGB(130, 200, 255) or Color3.fromRGB(215, 212, 228))
    end
  end
  statusRow.Text = enabled and statusText
    or ("OFF. %d zona darat ditemukan%s"):format(#list, #list == 0 and " (arahkan kamera ke tengah map)" or "")
  dbgToggle.Text = "Debug: " .. (debugOn and "ON" or "OFF") .. "  (log: " .. LOG_FILE .. ")"
  dbgRow.Visible = debugOn
  if debugOn then
    local lines = {}
    local shown = 0
    for u, a in pairs(assign) do
      shown = shown + 1
      if shown > DEBUG_UNITS then break end
      lines[#lines + 1] = ("%s > %s | %s | sisa %s | step %d | %s"):format(unitName(u):sub(1, 14),
        (zoneTitle(a.zone)):sub(1, 10), a.state or "-", tostring(a.dist or "?"), a.leg, a.result or "-")
    end
    if shown == 0 then lines[1] = enabled and "(belum ada unit ditugaskan)" or "(Auto Capture OFF)" end
    lines[#lines + 1] = "-- log --"
    for _, l in ipairs(logLines) do lines[#lines + 1] = l end
    dbgRow.Text = table.concat(lines, "\n")
  end
  local h = 0
  for _, c in ipairs(panel:GetChildren()) do
    if c:IsA("GuiObject") and c.Visible then h = h + c.Size.Y.Offset end
  end
  panel.Size = UDim2.fromOffset(W, h)
end

do -- seret panel dari judul
  local dragging, start, origin
  table.insert(conns, title.InputBegan:Connect(function(i)
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
table.insert(conns, UIS.InputBegan:Connect(function(i, processed)
  if not processed and i.KeyCode == Enum.KeyCode.Delete then gui.Enabled = not gui.Enabled end
end))

local function stop()
  alive = false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  pcall(function() gui:Destroy() end)
end

task.spawn(function()
  while current() and gui.Parent do
    if enabled then
      local ok, err = pcall(evaluate)
      if not ok then statusText = "ERR: " .. tostring(err) log("ERROR evaluate: " .. tostring(err)) end
    end
    local ok, err = pcall(render)
    if not ok then statusRow.Text = "Panel ERR: " .. tostring(err) end
    task.wait(TICK)
  end
  log("loop utama berhenti: " .. (G.BC_CAPTURE_RUN ~= RUN and "diganti versi baru" or "panel dihapus / stop"))
  stop()
end)

-- detak terpisah: tunjukkan loop utama masih hidup atau tidak
task.spawn(function()
  while alive and gui.Parent do
    local ago = os.clock() - lastTickAt
    if not enabled then
      beatRow.Text, beatRow.TextColor3 = "Loop: hidup (Auto Capture OFF)", Color3.fromRGB(150, 150, 150)
    elseif ago <= TICK * 3 then
      beatRow.Text = ("Loop: JALAN  tick #%d  (%.0fs lalu)"):format(tickN, ago)
      beatRow.TextColor3 = Color3.fromRGB(120, 255, 120)
    else
      beatRow.Text = ("Loop: MACET/MATI  tick terakhir %.0fs lalu"):format(ago)
      beatRow.TextColor3 = Color3.fromRGB(255, 90, 90)
    end
    task.wait(1)
  end
end)

G.BC_CAPTURE = { stop = stop }
