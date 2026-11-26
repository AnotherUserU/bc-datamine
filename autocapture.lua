-- Build and Conquer: auto-capture zona tengah. INTERNAL (Delta). Hanya unit darat.
-- Zona = part dengan tag CollectionService "CaptureZone" (nama CaptureZone..CaptureZone10, lihat CaptureZoneTypes).
-- Status: atribut CaptureState ("Captured"/"Contested") + CaptureOwnerUserId. Cara capture (dari game):
-- "Have the only units inside the border to take it." Oil rig (hanya kapal) dilewati.
-- Unit = model milik sendiri di workspace.MilitaryTrucks dan workspace.Squads, digerakkan lewat fungsi game
-- GameActions.OrderUnits (sama seperti perintah gerak biasa; server yang menentukan jalur).
-- Tujuan = tepi dalam zona yang menghadap unit (bukan tengah). Perjalanan jauh dipecah per langkah (LEG stud).
-- Blocked / macet: langkah diperpendek dan titik diputar ke sisi lain zona; gagal MAX_FAILS kali = unit
-- diganti unit lain (unit itu tidak dikirim ke zona itu selama BAN_SECONDS).
-- Private server: zona tidak memberi hadiah (atribut workspace.CaptureRewardsOff), ditampilkan di panel.
-- Jalankan ulang = versi lama berhenti sendiri (tidak perlu rejoin). Penanda versi aktif disimpan sebagai
-- ATRIBUT di folder GUI (instance dipakai bersama semua eksekusi, getgenv/_G belum tentu): tiap loop/handler
-- mengecek atribut itu; berganti = berhenti. Panel lama juga dihapus.
if game.GameId ~= 10757247806 then return end
local G = (getgenv and getgenv()) or _G
for _, env in ipairs({ G, _G }) do
  if env.BC_CAPTURE then pcall(env.BC_CAPTURE.stop) env.BC_CAPTURE = nil end
end
local GUI_PARENT = (gethui and gethui()) or game:GetService("CoreGui")
local RUN_ID = ("%04x"):format(math.random(0, 0xffff))
GUI_PARENT:SetAttribute("BCCaptureRun", RUN_ID)
for _, old in ipairs(GUI_PARENT:GetChildren()) do
  if old.Name == "BCCapturePanel" then old:Destroy() end
end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local UIS = game:GetService("UserInputService")
local lp = Players.LocalPlayer

local TICK = 3                 -- dtk antar evaluasi
local LEG = 400                -- stud per langkah perjalanan
local LEG_MIN = 40             -- langkah terpendek setelah berkali-kali blocked
local STILL_STUD = 3           -- gerak kurang dari ini dalam 1 tick = diam
local REORDER_MIN = 3          -- dtk minimal antar perintah ke unit yang sama
-- Jalan memutar: kalau blocked/macet, langkah berikutnya dibelokkan bergantian (derajat dari arah lurus ke
-- zona). Setelah satu langkah belok berhasil, kembali lurus. Semua arah habis = coba sisi lain zona.
local DETOURS = { 0, 45, -45, 90, -90 }
local STUCK_ORDERS = 2         -- perintah berturut-turut tanpa kemajuan = macet, ganti titik tujuan
local STUCK_GAIN = 10          -- stud; kemajuan lebih kecil dari ini dianggap tidak maju
local MAX_FAILS = 6            -- macet/blocked sekian kali di satu zona -> unit diganti unit lain
                               -- (cukup untuk mencoba semua arah DETOURS dulu)
local BAN_SECONDS = 300        -- unit yang gagal tidak dikirim ke zona itu lagi selama ini
-- Tujuan = titik di TEPI DALAM zona yang menghadap unit (bukan tengah: tengah sering lubang tambang /
-- bangunan yang tidak bisa didatangi). Cukup masuk batas zona untuk merebutnya.
local EDGE_INSET = 0.75        -- posisi dari tengah ke tepi (0 = tengah, 1 = tepi)
local RETRY_TURN = 0.9         -- rad; titik baru setelah macet = diputar sejauh ini di sekeliling zona
local PRIORITY = { "URANIUM MINE", "CITY", "INDUSTRIAL ZONE", "NUCLEAR POWER PLANT", "OIL FIELD",
  "MINING SITE", "AIRPORT" }

local GameActions = require(RS:WaitForChild("GameActions"))
local ZoneTypes = require(RS:WaitForChild("CaptureZoneTypes"))

local alive, enabled, garrison = true, false, true
local perZone = 3
local zoneOn = {}              -- zona -> false kalau dimatikan di panel
local assign = {}              -- unit -> { zone, angle, orderedAt, lastPos, leg, fails }
local conns = {}
local statusText = "OFF"
local lastResult = ""          -- jawaban server terakhir (state + alasan)
local debugOn = true
local DEBUG_UNITS = 8          -- maks unit yang tampil di panel debug

-- ===== debug: log ke panel (6 baris terakhir) + file bc_capture_log.txt di workspace executor =====
local LOG_FILE = "bc_capture_log.txt"
local logLines = {}
local tickN, lastTickAt = 0, os.clock()
local phase = "-"              -- langkah yang sedang dikerjakan tick (untuk melacak macet)
local unitDebug = ""           -- baris status per unit, disusun di evaluate (bukan di render)
local function log(msg)
  local line = os.date("%H:%M:%S") .. " [" .. RUN_ID .. "] " .. msg   -- [id] = salinan script yang menulis
  logLines[#logLines + 1] = line
  if #logLines > 6 then table.remove(logLines, 1) end
  pcall(function()
    local ok = appendfile and pcall(appendfile, LOG_FILE, line .. "\n")
    if not ok then writefile(LOG_FILE, line .. "\n") end
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
-- titik di TANAH (hanya Terrain, bukan atap bangunan: titik di atap tidak bisa dicapai unit)
local terrainRay = RaycastParams.new()
terrainRay.FilterType = Enum.RaycastFilterType.Include
terrainRay.FilterDescendantsInstances = { workspace.Terrain }
terrainRay.IgnoreWater = false
local function ground(p, z)
  local hit = workspace:Raycast(Vector3.new(p.X, p.Y + 500, p.Z), Vector3.new(0, -2000, 0), terrainRay)
  if hit then return hit.Position end
  rayParams.FilterDescendantsInstances = { z, lp.Character, workspace:FindFirstChild("MilitaryTrucks"),
    workspace:FindFirstChild("Squads") }
  hit = workspace:Raycast(Vector3.new(p.X, p.Y + 500, p.Z), Vector3.new(0, -2000, 0), rayParams)
  return hit and hit.Position or p
end

-- sudut (di ruang lokal zona) dari tengah zona ke posisi p: sisi zona yang menghadap unit
local function angleFrom(z, p)
  local o = z.CFrame:PointToObjectSpace(p)
  return math.atan2(o.Z, o.X)
end

-- titik di tepi dalam zona pada sudut a.angle (diputar RETRY_TURN tiap kali unit macet)
local function edgePoint(a)
  local z = a.zone
  local local_ = Vector3.new(math.cos(a.angle) * z.Size.X / 2 * EDGE_INSET, 0,
    math.sin(a.angle) * z.Size.Z / 2 * EDGE_INSET)
  return z.CFrame:PointToWorldSpace(local_)
end

-- tujuan langkah berikutnya: maksimal a.leg stud dari posisi unit ke arah titik zona
local function nextStep(a, pos)
  local goal = edgePoint(a)
  local flat = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
  local d = flat.Magnitude
  local turn = DETOURS[a.detour or 1]
  if turn == 0 then
    local target = d > a.leg and (pos + flat.Unit * a.leg) or goal
    return ground(target, a.zone)
  end
  -- belok: arah lurus diputar 'turn' derajat di sumbu Y, panjang = langkah (tidak melewati jarak ke tujuan)
  local dir = (CFrame.Angles(0, math.rad(turn), 0) * flat.Unit)
  return ground(pos + dir * math.min(a.leg, d), a.zone)
end

-- gagal (blocked/macet): pindah ke arah belok berikutnya; semua arah habis = sisi lain zona
local function nextDetour(a)
  a.detour = (a.detour or 1) % #DETOURS + 1
  if a.detour == 1 then
    a.angle = a.angle + RETRY_TURN
    return "semua arah dicoba, pindah ke sisi lain zona"
  end
  return ("belok %+d derajat"):format(DETOURS[a.detour])
end

-- ===== jawaban server: kalau blocked, perpendek langkah =====
local function current() return alive and GUI_PARENT:GetAttribute("BCCaptureRun") == RUN_ID end

-- jawaban server yang berarti GAGAL (selain ini, mis. Moving/Queued/Arrived, dianggap berhasil)
local FAIL_WORDS = { "block", "fail", "reject", "invalid", "cancel", "unreach" }
local function isFail(st)
  st = st:lower()
  for _, w in ipairs(FAIL_WORDS) do if st:find(w, 1, true) then return true end end
  return false
end

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
        if isFail(st) then
          a.fails = (a.fails or 0) + 1
          local how = nextDetour(a)          -- arah ini ditolak: belok / sisi lain zona
          a.leg = math.max(LEG_MIN, math.floor(a.leg / 2))
          a.orderedAt = 0        -- coba lagi tick berikutnya dengan langkah lebih pendek
          log(("SERVER %s: %s -> gagal %d/%d, %s, langkah %d stud"):format(
            unitName(r.unit), a.result, a.fails, MAX_FAILS, how, a.leg))
        else
          a.leg = math.min(LEG, a.leg * 2)   -- berhasil: langkah dipanjangkan lagi
          if (a.detour or 1) ~= 1 then a.detourDone = true end   -- langkah belok diterima: berikutnya lurus
          if st:lower():find("arriv", 1, true) then
            a.orderedAt = 0      -- sampai di ujung langkah: langkah berikutnya tanpa menunggu
            log(("SERVER %s: %s (ujung langkah), lanjut"):format(unitName(r.unit), st))
          end
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

-- unit yang gagal MAX_FAILS kali di satu zona tidak dikirim ke zona itu selama BAN_SECONDS
local banned = {}              -- unit -> { [zona] = os.clock() sampai kapan }
local function isBanned(u, z)
  local b = banned[u]
  return b ~= nil and b[z] ~= nil and b[z] > os.clock()
end

local function evaluate()
  tickN, lastTickAt = tickN + 1, os.clock()
  phase = "cari unit"
  local units = myUnits()
  local byUnit = {}
  for _, e in ipairs(units) do byUnit[e.unit] = e end
  for u, a in pairs(assign) do
    if not byUnit[u] then release(u, "unit hilang / hancur / bukan milikmu lagi")
    elseif not a.zone.Parent then release(u, "zona hilang (tidak ter-stream)")
    elseif zoneOn[a.zone] == false then release(u, "zona dimatikan di panel")
    elseif not garrison and zoneMine(a.zone) then release(u, "zona sudah direbut, pindah ke zona lain")
    elseif (a.fails or 0) >= MAX_FAILS then
      banned[u] = banned[u] or {}
      banned[u][a.zone] = os.clock() + BAN_SECONDS
      release(u, ("gagal %dx ke %s, diganti unit lain (%d dtk)"):format(a.fails, (zoneTitle(a.zone)), BAN_SECONDS))
    end
  end
  local count = {}
  for _, a in pairs(assign) do count[a.zone] = (count[a.zone] or 0) + 1 end
  phase = "bagi unit ke zona"
  local pool = {}
  for _, e in ipairs(units) do if not assign[e.unit] then pool[#pool + 1] = e end end
  for _, z in ipairs(zones()) do
    if zoneOn[z] ~= false and not zoneMine(z) then
      local need = perZone - (count[z] or 0)
      while need > 0 do
        local best, bd = nil, math.huge
        for i, e in ipairs(pool) do
          local d = (e.pos - z.Position).Magnitude
          if d < bd and not isBanned(e.unit, z) then best, bd = i, d end
        end
        if not best then break end   -- tidak ada unit bebas yang boleh ke zona ini
        local e = table.remove(pool, best)
        count[z] = (count[z] or 0) + 1
        assign[e.unit] = { zone = z, orderedAt = 0, leg = LEG, state = "baru", result = "-", fails = 0, detour = 1,
          angle = angleFrom(z, e.pos) + (count[z] - 1) * 0.5 }   -- sisi yang menghadap unit, disebar
        log(("TUGAS %s -> %s (%d stud)"):format(unitName(e.unit), (zoneTitle(z)), math.floor(bd)))
        need = need - 1
      end
    end
  end
  -- perintah: unit yang diam dan belum di dalam zona dapat langkah berikutnya
  phase = "hitung langkah"
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
        -- macet: jarak tidak berkurang setelah beberapa perintah -> coba titik lain di zona
        if a.bestDist and a.dist >= a.bestDist - STUCK_GAIN then
          a.stuck = (a.stuck or 0) + 1
        else
          a.stuck, a.bestDist = 0, a.dist
        end
        if a.stuck >= STUCK_ORDERS then
          a.stuck, a.bestDist, a.detourDone = 0, nil, false
          a.fails = (a.fails or 0) + 1
          local how = nextDetour(a)
          log(("MACET %s di sisa %d stud, gagal %d/%d, %s"):format(unitName(u), a.dist, a.fails, MAX_FAILS, how))
        elseif a.detourDone then
          a.detour, a.detourDone = 1, false  -- sudah memutar satu langkah: kembali lurus ke zona
        end
        orders[#orders + 1] = { unit = u, position = nextStep(a, e.pos) }
        a.orderedAt = now
        a.state = "diperintah"
      else
        a.state = ("diam, tunggu %ds"):format(math.ceil(REORDER_MIN - (now - a.orderedAt)))
      end
    end
  end
  if #orders > 0 then
    for _, o in ipairs(orders) do
      local a = assign[o.unit]
      local turn = DETOURS[a.detour or 1]
      log(("PERINTAH %s langkah %d stud%s, sisa %d stud ke %s"):format(unitName(o.unit), a.leg,
        turn ~= 0 and (" belok %+d"):format(turn) or "", a.dist, (zoneTitle(a.zone))))
    end
    -- Dikirim dari thread TERPISAH: thread yang memanggil fungsi game tidak bisa lagi menulis ke panel
    -- (di Delta tertahan selamanya = "MACET di fase render"). Thread ini tidak menyentuh GUI.
    task.spawn(function()
      local ok, res = pcall(GameActions.OrderUnits, orders, "Move")
      if not ok then
        statusText = "Order ERR: " .. tostring(res)
        log("ERROR OrderUnits: " .. tostring(res))
      elseif res == false then
        log("OrderUnits menolak (return false)")
      end
    end)
  end
  phase = "susun teks debug"
  local okDbg, errDbg = pcall(function()
    local lines = {}
    for u, a in pairs(assign) do
      if #lines >= DEBUG_UNITS then break end
      lines[#lines + 1] = tostring(unitName(u)):sub(1, 14) .. " > " .. tostring((zoneTitle(a.zone))):sub(1, 10)
        .. " | " .. tostring(a.state) .. " | sisa " .. tostring(a.dist) .. " | step " .. tostring(a.leg)
        .. ((a.detour or 1) ~= 1 and (" belok " .. DETOURS[a.detour]) or "") .. " | gagal " .. tostring(a.fails or 0)
        .. " | " .. tostring(a.result or "-")
    end
    unitDebug = table.concat(lines, "\n")
  end)
  if not okDbg then unitDebug = "debug ERR: " .. tostring(errDbg) log(unitDebug) end
  phase = "status"
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
    local lastClick = 0      -- emulator bisa mengirim klik ganda (mouse + sentuh): abaikan < 0.35 dtk
    b.MouseButton1Click:Connect(function()
      if not current() or os.clock() - lastClick < 0.35 then return end
      lastClick = os.clock()
      onClick()
    end)
  end
  b.Parent = panel
  return b
end

local render
local title = row("BC Auto Capture  [Delete]  (seret)")
title.TextColor3 = Color3.new(1, 1, 1)
local onRow = row("", function()
  enabled = not enabled
  assign, unitDebug = {}, ""
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
    local lines = { unitDebug ~= "" and unitDebug or (enabled and "(belum ada unit ditugaskan)" or "(Auto Capture OFF)"),
      "-- log --" }
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

-- Loop utama dengan watchdog: tiap tick jalan di thread sendiri. Kalau satu tick tidak selesai dalam
-- TICK_TIMEOUT dtk, fase terakhirnya dicatat ("MACET di ...") dan loop lanjut dengan tick baru.
local TICK_TIMEOUT = 20
local function runTick()             -- hanya logika; panel digambar oleh loop detak di bawah
  if enabled then
    local ok, err = pcall(evaluate)
    if not ok then statusText = "ERR: " .. tostring(err) log("ERROR evaluate: " .. tostring(err)) end
  end
  phase = "selesai"
end

task.spawn(function()
  while current() and gui.Parent do
    local done = false
    phase = "mulai"
    task.spawn(function() runTick() done = true end)
    local t0 = os.clock()
    while not done and os.clock() - t0 < TICK_TIMEOUT do task.wait(0.25) end
    if not done then log(("MACET di fase '%s' > %ds, tick dilewati"):format(phase, TICK_TIMEOUT)) end
    task.wait(TICK)
  end
  log("loop utama berhenti: " .. (alive and "diganti salinan baru" or "stop"))
  stop()
end)

-- loop panel (terpisah dari logika): gambar panel + detak tiap 1 dtk. Thread ini tidak pernah memanggil
-- fungsi game, jadi penulisan ke panel tidak tertahan.
task.spawn(function()
  while alive and gui.Parent and current() do
    local okR, errR = pcall(render)
    if not okR then statusRow.Text = "Panel ERR: " .. tostring(errR) end
    local ago = os.clock() - lastTickAt
    if not enabled then
      beatRow.Text, beatRow.TextColor3 = "Loop: hidup (Auto Capture OFF)", Color3.fromRGB(150, 150, 150)
    elseif ago <= TICK * 3 then
      beatRow.Text = ("Loop: JALAN  tick #%d  (%.0fs lalu)"):format(tickN, ago)
      beatRow.TextColor3 = Color3.fromRGB(120, 255, 120)
    else
      beatRow.Text = ("Loop: MACET/MATI  tick terakhir %.0fs lalu, fase '%s'"):format(ago, phase)
      beatRow.TextColor3 = Color3.fromRGB(255, 90, 90)
    end
    task.wait(1)
  end
end)

G.BC_CAPTURE = { stop = stop }
