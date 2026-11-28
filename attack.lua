-- Build and Conquer: AUTO ATTACK bergelombang. INTERNAL (Delta). Script terpisah dari hub.
-- Rencana diketik per baris, dijalankan dari atas ke bawah. Satu baris = satu gelombang, bagian dipisah "+":
--   99 shahed 136
--   40 cruise + 59 karrar
-- Peluncuran memakai remote game yang sama dengan tombol FIRE (MissileRemotes.LaunchMissileVolley),
-- hanya launcher milik sendiri yang siap (tidak reload, ada stok). Maks 99 target per barrage; sisanya
-- langsung dikirim sebagai barrage berikutnya, baru lanjut ke baris di bawahnya.
-- ULANG ON (default): habis baris terakhir balik ke baris pertama, terus sampai BERHENTI ditekan.
-- Tombol "-" menyembunyikan panel; klik tab "ATTACK" untuk memunculkan lagi.
if game.GameId ~= 10757247806 then return end
local G = (getgenv and getgenv()) or _G
if G.BC_ATTACK then pcall(G.BC_ATTACK.stop) G.BC_ATTACK = nil end
local GUI_PARENT = (gethui and gethui()) or game:GetService("CoreGui")
local RUN_ID = ("%04x"):format(math.random(0, 0xffff))
GUI_PARENT:SetAttribute("BCAttackRun", RUN_ID)
for _, old in ipairs(GUI_PARENT:GetChildren()) do
  if old.Name == "BCAttack" then old:Destroy() end
end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local lp = Players.LocalPlayer
local MissileRemotes = RS:WaitForChild("MissileRemotes")
local Volley = MissileRemotes:WaitForChild("LaunchMissileVolley")
local Placed = workspace:WaitForChild("PlacedRoads")

local K = {
  PLAN_FILE = "bc_attack_plan.txt",
  DEFAULT_PLAN = "99 shahed 136\n99 shahed 236\n40 cruise + 59 karrar\n5 cluster + 40 mrbm + 59 srbm\n12 hypers",
  BARRAGE_LIMIT = 99,      -- target per FireServer (game menolak target ke-101; 99 biar aman)
  CHUNK_GAP = 0.3,         -- detik antar-potongan kalau satu gelombang > 100
  DEFAULT_GAP = 3,         -- detik antar-gelombang
  IDLE_WAIT = 5,           -- detik tunggu kalau satu putaran penuh tidak ada yang bisa ditembak
}

-- Padanan antar-pack (dari MilitaryPacks.Skins di game). Nama Standard = semua padanannya, jadi
-- "srbm" memakai SRBM + B-Strike 1000 + ATACMS + Iskander yang kamu punya. Nama pack = launcher itu saja.
local GROUP = {
  shahed = { "Shahed Launcher", "Rodeur 330 Rail", "Switchblade Launcher", "LUCAS Launcher" },
  shahed236 = { "Shahed-236 Launcher", "Veloce 330 Rail", "Red Wolf Launcher" },
  karrar = { "Karrar Launcher", "One Way Effector Rail", "Barracuda Launcher", "Geran-5 Launcher" },
  cruise = { "GLCM Launcher", "MdCN Launcher", "FP-5 Flamingo Launcher" },
  srbm = { "SRBMLauncher", "B-Strike1000Launcher", "M270Launcher", "IskanderLauncher" },
  mrbm = { "MRBMLauncher", "B-STRIKE 2500 Launcher", "Himars PrSM", "FP9 Pelican Launcher" },
  heavymrbm = { "HeavyMRBMLauncher", "Typhon Launcher" },
  cluster = { "ClusterBMLauncher", "ATACMS Cluster Launcher" },
  hyper = { "Hypersonic BM Launcher", "B-STRIKE Hypersonic launcher", "Dark Eagle Launcher", "Zircon Launcher" },
}
-- nama di rencana -> template launcher. Kunci dicocokkan (awalan) setelah huruf kecil & tanpa spasi/strip/titik.
-- Urutan penting: yang lebih spesifik dulu (shahed236 sebelum shahed, heavymrbm sebelum mrbm).
local ALIASES = {
  -- Standard (+ semua padanan pack)
  { "shahed236", GROUP.shahed236 }, { "sh236", GROUP.shahed236 },
  { "shahed136", GROUP.shahed }, { "sh136", GROUP.shahed }, { "shahed", GROUP.shahed },
  { "karrar", GROUP.karrar },
  { "cruise", GROUP.cruise }, { "glcm", GROUP.cruise },
  { "heavymrbm", GROUP.heavymrbm }, { "hvmrbm", GROUP.heavymrbm },
  { "mrbm", GROUP.mrbm }, { "srbm", GROUP.srbm },
  { "cluster", GROUP.cluster }, { "hyper", GROUP.hyper },
  { "asbm", { "ASBMLauncher" } },                      -- anti-kapal: target harus kapal musuh
  { "coastal", { "CoastalLauncher" } }, { "yakhont", { "CoastalLauncher" } },
  -- France
  { "rodeur", { "Rodeur 330 Rail" } }, { "veloce", { "Veloce 330 Rail" } },
  { "oneway", { "One Way Effector Rail" } }, { "owe", { "One Way Effector Rail" } },
  { "mdcn", { "MdCN Launcher" } },
  { "bstrike1000", { "B-Strike1000Launcher" } }, { "bstrike2500", { "B-STRIKE 2500 Launcher" } },
  { "bstrikehgv", { "B-STRIKE Hypersonic launcher" } }, { "hades", { "Hades Launcher" } },
  -- USA
  { "switchblade", { "Switchblade Launcher" } }, { "lucas", { "LUCAS Launcher" } },
  { "redwolf", { "Red Wolf Launcher" } }, { "barracuda", { "Barracuda Launcher" } },
  { "tomahawk", { "GLCM Launcher" } },
  { "atacmscluster", { "ATACMS Cluster Launcher" } }, { "atacms", { "M270Launcher" } },
  { "prsm", { "Himars PrSM" } }, { "typhon", { "Typhon Launcher" } }, { "sm6", { "Typhon Launcher" } },
  { "darkeagle", { "Dark Eagle Launcher" } }, { "blackbeard", { "Blackbeard Launcher" } },
  -- Eastern (Russia). Geran-2/Geran-3 cuma skin Shahed-136/236 (launcher sama).
  { "geran2", { "Shahed Launcher" } }, { "geran3", { "Shahed-236 Launcher" } },
  { "geran", { "Geran-5 Launcher" } },
  { "flamingo", { "FP-5 Flamingo Launcher" } }, { "fp5", { "FP-5 Flamingo Launcher" } },
  { "iskander", { "IskanderLauncher" } },
  { "pelican", { "FP9 Pelican Launcher" } }, { "fp9", { "FP9 Pelican Launcher" } },
  { "zircon", { "Zircon Launcher" } },
}
-- launcher yang tiap misilnya jadi entri sendiri (sama seperti fireBarrage di game)
local SEPARATE = {
  ["Typhon Launcher"] = true, ["Dark Eagle Launcher"] = true, ["Blackbeard Launcher"] = true,
  ["M270Launcher"] = true, ["ATACMS Cluster Launcher"] = true, ["Himars PrSM"] = true,
  ["CoastalLauncher"] = true, ["GLCM Launcher"] = true,
}

local alive, running = true, false
local conns = {}
local st = { target = nil, picking = false, loop = true, status = "Pilih target dulu.", log = {}, serverMsg = "" }

local function current() return alive and GUI_PARENT:GetAttribute("BCAttackRun") == RUN_ID end
local function note(msg)
  table.insert(st.log, 1, os.date("%H:%M:%S ") .. msg)
  while #st.log > 8 do table.remove(st.log) end
end

-- ===== rencana =====
local function resolve(name)
  local key = name:lower():gsub("[%s%-_%.]", "")
  for _, a in ipairs(ALIASES) do
    if key:sub(1, #a[1]) == a[1] then return a[2] end
  end
  return nil
end

-- "40 cruise + 59 karrar" -> { {count=40, name="cruise", templates={...}}, ... } atau nil, pesan error
local function parseLine(line)
  local parts = {}
  for chunk in line:gmatch("[^+]+") do
    local n, name = chunk:match("^%s*(%d+)%s*[xX]?%s*(.-)%s*$")
    if not n or name == "" then return nil, "format salah: \"" .. chunk .. "\"" end
    local templates = resolve(name)
    if not templates then return nil, "jenis tidak dikenal: \"" .. name .. "\"" end
    parts[#parts + 1] = { count = tonumber(n), name = name, templates = templates }
  end
  return parts
end

local function parsePlan(text)
  local waves = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("%S") then
      local parts, err = parseLine(line)
      if not parts then return nil, ("baris %d: %s"):format(#waves + 1, err) end
      waves[#waves + 1] = { text = line:match("^%s*(.-)%s*$"), parts = parts }
    end
  end
  if #waves == 0 then return nil, "rencana kosong" end
  return waves
end

-- ===== launcher siap (sama dengan readyLaunchers di game) =====
local function shotsOf(l)
  local t = l:GetAttribute("RoadTemplateName")
  local stored = tonumber(l:GetAttribute("RoundsLoadedStored"))
  if t == "Typhon Launcher" or t == "Blackbeard Launcher" or t == "GLCM Launcher" then return math.clamp(stored or 4, 1, 4) end
  if t == "CoastalLauncher" then return math.clamp(stored or 6, 1, 6) end
  if t == "M270Launcher" or t == "ATACMS Cluster Launcher" or t == "Himars PrSM" or t == "Dark Eagle Launcher" then
    return math.clamp(stored or 2, 1, 2)
  end
  if t == "Hades Launcher" or t == "B-Strike1000Launcher" or t == "B-STRIKE 2500 Launcher"
    or t == "B-STRIKE Hypersonic launcher" or t == "MdCN Launcher" then return 2 end
  return 1
end

local function readyLaunchers(templates, used)
  local want, now, list = {}, workspace:GetServerTimeNow(), {}
  for _, t in ipairs(templates) do want[t] = true end
  for _, l in ipairs(Placed:GetChildren()) do
    if l:IsA("Model") and not used[l] and want[l:GetAttribute("RoadTemplateName")]
      and l:GetAttribute("PlacementOwnerUserId") == lp.UserId
      and l:GetAttribute("UnderConstruction") ~= true and l:GetAttribute("Destroyed") ~= true
      and not ((l:GetAttribute("ReloadingUntil") or 0) > now)
      and l:GetAttribute("MissileLoaded") ~= false and l:GetAttribute("AwaitingMissileStock") ~= true then
      list[#list + 1] = l
    end
  end
  table.sort(list, function(a, b) return a.Name < b.Name end)
  return list
end

-- entri untuk satu bagian: { {launcher, point[, point2]} ... }, jumlah misil yang didapat
local function buildPart(part, point, used, entries)
  local got = 0
  for _, l in ipairs(readyLaunchers(part.templates, used)) do
    if got >= part.count then break end
    used[l] = true
    local shots = math.min(shotsOf(l), part.count - got)
    if SEPARATE[l:GetAttribute("RoadTemplateName")] then
      for _ = 1, shots do entries[#entries + 1] = { launcher = l, point = point } end
    else
      local e = { launcher = l, point = point }
      if shots >= 2 then e.point2 = point end
      entries[#entries + 1] = e
    end
    got = got + shots
  end
  return got
end

-- kirim entries[from..to] sebagai satu barrage
local function sendBarrage(entries, from, to)
  local chunk = {}
  for j = from, to do chunk[#chunk + 1] = entries[j] end
  local ok, err = pcall(Volley.FireServer, Volley, chunk)
  if not ok then note("GAGAL kirim: " .. tostring(err)) return 0 end
  return #chunk
end

-- Satu gelombang: sisa gelombang sebelumnya (carry) + launcher gelombang ini.
-- Tembak per 99. Kalau totalnya lewat 99, sisanya TIDAK ditembak sendiri tapi ikut barrage gelombang
-- berikutnya (contoh: 104 -> 99 sekarang, 5 ikut 12 hypers = 17). Gelombang terakhir menembak semuanya.
local function fireWave(index, wave, point, used, carry, isLast)
  local entries, summary = carry, {}
  local fromCarry = #carry
  for _, part in ipairs(wave.parts) do
    local got = buildPart(part, point, used, entries)
    summary[#summary + 1] = ("%s %d/%d"):format(part.name, got, part.count)
  end
  local limit, sent, i = K.BARRAGE_LIMIT, 0, 1
  local overflow = #entries > limit
  while #entries - i + 1 >= limit and current() and running do
    sent = sent + sendBarrage(entries, i, i + limit - 1)
    i = i + limit
    if #entries - i + 1 > 0 then task.wait(K.CHUNK_GAP) end
  end
  local rest, nextCarry = #entries - i + 1, {}
  if rest > 0 and overflow and not isLast then
    for j = i, #entries do nextCarry[#nextCarry + 1] = entries[j] end
  elseif rest > 0 and current() and running then
    sent = sent + sendBarrage(entries, i, #entries)
  end
  note(("G%d: %s | tembak %d%s%s"):format(index, table.concat(summary, ", "), sent,
    fromCarry > 0 and (" (+%d sisa sebelumnya)"):format(fromCarry) or "",
    #nextCarry > 0 and (", %d ikut gelombang berikut"):format(#nextCarry) or ""))
  return sent, nextCarry
end

-- satu putaran = semua baris dari atas ke bawah. Mode ulang: putar terus sampai BERHENTI ditekan.
local function runPlan(waves, gap)
  local point, round = st.target, 0
  repeat
    round = round + 1
    local fired, used, carry = 0, {}, {}   -- used: launcher yang sudah dipakai di putaran ini
    for i, wave in ipairs(waves) do
      if not (current() and running) then break end
      st.status = ("Putaran %d, gelombang %d/%d: %s"):format(round, i, #waves, wave.text)
      local sent
      sent, carry = fireWave(i, wave, point, used, carry, i == #waves)
      fired = fired + sent
      if sent > 0 and (i < #waves or st.loop) then task.wait(gap) end
    end
    if st.loop and fired == 0 and current() and running then
      st.status = ("Putaran %d: semua launcher reload, tunggu %d dtk..."):format(round, K.IDLE_WAIT)
      task.wait(K.IDLE_WAIT)
    end
  until not (st.loop and current() and running)
  st.status = running and "Selesai. Cek log di bawah." or "Dihentikan."
  running = false
end

-- ===== pilih target: klik berikutnya di dunia (bukan di panel) =====
local function groundAt(pos)
  local cam = workspace.CurrentCamera
  local ray = cam:ViewportPointToRay(pos.X, pos.Y)
  local params = RaycastParams.new()
  params.FilterType = Enum.RaycastFilterType.Exclude
  params.FilterDescendantsInstances = { lp.Character, workspace:FindFirstChild("MissileFlights") }
  local hit = workspace:Raycast(ray.Origin, ray.Direction * 20000, params)
  return hit and hit.Position
end
table.insert(conns, UIS.InputBegan:Connect(function(input, processed)
  if not st.picking or processed then return end
  if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then return end
  local p = groundAt(input.Position)
  if p then
    st.target, st.picking = p, false
    st.status = ("Target terkunci (%.0f, %.0f)."):format(p.X, p.Z)
  end
end))
table.insert(conns, MissileRemotes:WaitForChild("MissileResult").OnClientEvent:Connect(function(ok, msg)
  if not ok and msg then st.serverMsg = tostring(msg) end
end))

-- ===== panel =====
local C = {
  bg = Color3.fromRGB(22, 24, 30), field = Color3.fromRGB(34, 37, 46), text = Color3.fromRGB(225, 228, 235),
  dim = Color3.fromRGB(150, 155, 165), go = Color3.fromRGB(40, 150, 80), stop = Color3.fromRGB(170, 60, 60),
  btn = Color3.fromRGB(55, 60, 75), warn = Color3.fromRGB(240, 170, 80),
}
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "BCAttack", false, 60
local frame = Instance.new("Frame")
frame.Size, frame.Position = UDim2.fromOffset(320, 430), UDim2.new(1, -332, 0, 80)
frame.BackgroundColor3, frame.BorderSizePixel, frame.Active, frame.Draggable = C.bg, 0, true, true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local function make(class, props, parent)
  local o = Instance.new(class)
  for k, v in pairs(props) do o[k] = v end
  o.Parent = parent or frame
  if class == "TextButton" or class == "TextBox" then Instance.new("UICorner", o).CornerRadius = UDim.new(0, 6) end
  return o
end
local function label(y, h, size, color, font)
  return make("TextLabel", {
    BackgroundTransparency = 1, Position = UDim2.fromOffset(10, y), Size = UDim2.new(1, -20, 0, h),
    Font = font or Enum.Font.GothamMedium, TextSize = size or 12, TextColor3 = color or C.text, Text = "",
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true,
  })
end
local function button(x, y, w, h, text, color)
  return make("TextButton", {
    Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(w, h), BackgroundColor3 = color or C.btn,
    BorderSizePixel = 0, Font = Enum.Font.GothamBold, TextSize = 13, TextColor3 = Color3.new(1, 1, 1), Text = text,
  })
end

label(8, 18, 14, C.text, Enum.Font.GothamBold).Text = "Auto attack (geser di sini)"
local hideBtn = button(286, 6, 26, 22, "-")
label(32, 14, 11, C.dim).Text = "Rencana (atas ke bawah, 1 baris = 1 gelombang):"
local savedPlan
pcall(function() savedPlan = readfile(K.PLAN_FILE) end)
local planBox = make("TextBox", {
  Position = UDim2.fromOffset(10, 48), Size = UDim2.new(1, -20, 0, 104), BackgroundColor3 = C.field,
  BorderSizePixel = 0, Font = Enum.Font.Code, TextSize = 13, TextColor3 = C.text, ClearTextOnFocus = false,
  MultiLine = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
  Text = (type(savedPlan) == "string" and savedPlan:match("%S")) and savedPlan or K.DEFAULT_PLAN,
})
label(158, 14, 11, C.dim).Text = "Jeda antar-gelombang (detik):"
local gapBox = make("TextBox", {
  Position = UDim2.fromOffset(210, 155), Size = UDim2.fromOffset(100, 20), BackgroundColor3 = C.field,
  BorderSizePixel = 0, Font = Enum.Font.Code, TextSize = 13, TextColor3 = C.text, ClearTextOnFocus = false,
  Text = tostring(K.DEFAULT_GAP),
})
local pickBtn = button(10, 182, 96, 30, "TARGET")
local loopBtn = button(112, 182, 96, 30, "ULANG: ON")
local fireBtn = button(214, 182, 96, 30, "SERANG", C.go)
local statusLbl = label(220, 44, 12)
local logLbl = label(266, 156, 11, C.dim, Enum.Font.Code)

local tab = make("TextButton", {
  Position = UDim2.new(1, -92, 0, 80), Size = UDim2.fromOffset(80, 26), BackgroundColor3 = C.bg,
  BorderSizePixel = 0, Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.text, Text = "ATTACK",
  Visible = false,
}, gui)

local function clicked(fn)
  local last = 0
  return function()
    if not current() or os.clock() - last < 0.4 then return end
    last = os.clock()
    fn()
  end
end
table.insert(conns, hideBtn.MouseButton1Click:Connect(clicked(function()
  frame.Visible, tab.Visible = false, true
end)))
table.insert(conns, tab.MouseButton1Click:Connect(clicked(function()
  frame.Visible, tab.Visible = true, false
end)))
table.insert(conns, planBox.FocusLost:Connect(function()
  pcall(writefile, K.PLAN_FILE, planBox.Text)
end))
table.insert(conns, pickBtn.MouseButton1Click:Connect(clicked(function()
  if running then return end
  st.picking = not st.picking
  st.status = st.picking and "Klik lokasi target di peta/dunia..." or "Batal pilih target."
end)))
table.insert(conns, loopBtn.MouseButton1Click:Connect(clicked(function()
  st.loop = not st.loop   -- boleh diubah saat jalan: OFF = berhenti setelah putaran ini selesai
end)))
table.insert(conns, fireBtn.MouseButton1Click:Connect(clicked(function()
  if running then
    running = false
    st.status = "Menghentikan..."
    return
  end
  local waves, err = parsePlan(planBox.Text)
  if not waves then st.status = "Rencana salah: " .. err return end
  if not st.target then st.status = "Pilih target dulu." return end
  pcall(writefile, K.PLAN_FILE, planBox.Text)
  running, st.serverMsg = true, ""
  task.spawn(runPlan, waves, math.max(0, tonumber(gapBox.Text) or K.DEFAULT_GAP))
end)))
gui.Parent = GUI_PARENT

local function stop()
  alive, running = false, false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  pcall(function() gui:Destroy() end)
end
G.BC_ATTACK = { stop = stop }

task.spawn(function()
  while current() and gui.Parent do
    pcall(function()
      pickBtn.Text = st.picking and "BATAL" or "TARGET"
      pickBtn.BackgroundColor3 = st.picking and C.warn or C.btn
      loopBtn.Text = st.loop and "ULANG: ON" or "ULANG: OFF"
      loopBtn.BackgroundColor3 = st.loop and C.go or C.btn
      fireBtn.Text = running and "BERHENTI" or "SERANG"
      fireBtn.BackgroundColor3 = running and C.stop or C.go
      local tgt = st.target and ("Target: %.0f, %.0f"):format(st.target.X, st.target.Z) or "Target: belum ada"
      statusLbl.Text = tgt .. "\n" .. st.status .. (st.serverMsg ~= "" and ("\nServer: " .. st.serverMsg) or "")
      logLbl.Text = table.concat(st.log, "\n")
    end)
    task.wait(0.3)
  end
  stop()
end)
