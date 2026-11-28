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
G.BCAttackRun = RUN_ID   -- dicek dari thread tombol: thread itu tidak boleh menyentuh gethui (capability)
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
  ALL_COUNT = 9999,        -- jumlah untuk "semua <jenis>"
  NAVY_WEAPONS = { "Tomahawk", "SLBM" },   -- senjata kapal untuk sasaran darat (ShipKinds role "land")
  NAVY_RANGE = { Tomahawk = { 150, 12000 }, SLBM = { 300, 12000 } },
  REPAIR_EVERY = 10,       -- detik antar-cek auto repair
  REPAIR_RETRY = 30,       -- detik sebelum minta repair bangunan yang sama lagi
  SCAN_HEIGHT = 600,       -- kamera pindai: tinggi & mundur dari tengah kota musuh
  SCAN_BACK = 400,
  SCAN_MAX = 90,           -- detik maks seluruh pindai
  SCAN_SPOT_MAX = 20,      -- detik maks di satu titik kamera
  SCAN_SPOT_MIN = 5,       -- detik min di satu titik (load sering mulai telat)
  SCAN_STABLE = 4,         -- pindah titik kalau jumlah bangunan tidak naik 4 detik berturut-turut
  SCAN_SPREAD = 600,       -- stud maks geser kamera dari tengah kota ke tiap kuadran
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
local st = { target = nil, picking = false, loop = true, navy = true, repair = true,
  status = "Pilih target dulu.", log = {}, serverMsg = "", repairMsg = "" }

local function current() return alive and G.BCAttackRun == RUN_ID end
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
    local all = false
    if not n then   -- "semua shahed" / "all srbm" = semua launcher yang siap (ikut naik kalau HQ di-upgrade)
      name = chunk:lower():match("^%s*semua%s+(.-)%s*$") or chunk:lower():match("^%s*all%s+(.-)%s*$")
      all, n = name ~= nil, K.ALL_COUNT
    end
    if not n or not name or name == "" then return nil, "format salah: \"" .. chunk .. "\"" end
    local templates = resolve(name)
    if not templates then return nil, "jenis tidak dikenal: \"" .. name .. "\"" end
    parts[#parts + 1] = { count = tonumber(n), name = name, templates = templates, all = all }
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

-- entri untuk satu bagian: { {launcher, point[, point2]} ... }, jumlah misil yang didapat.
-- aim() memberi titik sasaran berikutnya (tiap misil bisa beda bangunan).
local function buildPart(part, aim, used, entries)
  local got = 0
  for _, l in ipairs(readyLaunchers(part.templates, used)) do
    if got >= part.count then break end
    used[l] = true
    local shots = math.min(shotsOf(l), part.count - got)
    if SEPARATE[l:GetAttribute("RoadTemplateName")] then
      for _ = 1, shots do entries[#entries + 1] = { launcher = l, point = aim() } end
    else
      local e = { launcher = l, point = aim() }
      if shots >= 2 then e.point2 = aim() end
      entries[#entries + 1] = e
    end
    got = got + shots
  end
  return got
end

-- ===== sasaran tersebar di kota musuh =====
-- Urutan: AD -> radar -> launcher rudal -> semua bangunan lain dari yang termahal. Jalan tidak dihitung.
-- Tiap gelombang mulai lagi dari atas daftar, jadi AD selalu kebagian duluan; 1 misil per bangunan,
-- kalau misil lebih banyak dari bangunan, daftar diulang dari atas.
local AD_TEMPLATES = {}
for _, t in ipairs({ "Stinger MANPADS", "Mistral MANPADS", "Igla-S MANPADS", "AA Gun", "RapidFire", "M163 VADS",
  "CIWS", "Mistral Launcher", "VL MICA Launcher", "S-300 Launcher", "US PAC-2 Launcher", "PatriotPac2", "Pantsir",
  "Iron Dome", "Enduring Shield Launcher", "US PAC-3 MSE Launcher", "SAMP-TG", "S-400 Launcher", "PatriotPac3",
  "THAAD Launcher", "S-500Launcher", "Arrow3", "Aquilla Base Launcher" }) do AD_TEMPLATES[t] = true end
local LAUNCHER_TEMPLATES = {}
for _, a in ipairs(ALIASES) do for _, t in ipairs(a[2]) do LAUNCHER_TEMPLATES[t] = true end end
for t in pairs(SEPARATE) do LAUNCHER_TEMPLATES[t] = true end
local okCatalog, Catalog = pcall(function() return require(RS:WaitForChild("BuildCatalog", 5)) end)

-- prioritas & harga: AD (1) -> radar (2) -> launcher (3) -> sisanya (4) dari yang TERMAHAL (harga BuildCatalog).
-- Di dalam tiap prioritas juga yang termahal dulu (THAAD sebelum MANPADS). Jalan = nil (bukan sasaran).
local costCache = {}
local function catalogItem(template)
  local item = okCatalog and Catalog and Catalog.GetItemByTemplateName
    and select(2, pcall(Catalog.GetItemByTemplateName, template))
  return type(item) == "table" and item or nil
end
local function rankOf(template)
  local item = catalogItem(template)
  local category = item and item.category
  if category == "Roads" or (not category and tostring(template):lower():find("road")) then return nil end
  if costCache[template] == nil then costCache[template] = tonumber(item and item.cost) or 0 end
  local cost = costCache[template]
  if AD_TEMPLATES[template] then return 1, cost end
  if template == "Early Warning Radar" then return 2, cost end
  if LAUNCHER_TEMPLATES[template] then return 3, cost end
  return 4, cost
end
local function byPriority(a, b)
  if a.rank ~= b.rank then return a.rank < b.rank end
  if a.cost ~= b.cost then return a.cost > b.cost end
  return a.name < b.name
end

local function enemyTargets(uid)
  local list = {}
  for _, b in ipairs(Placed:GetChildren()) do
    if b:IsA("Model") and b:GetAttribute("PlacementOwnerUserId") == uid and b:GetAttribute("Destroyed") ~= true then
      local rank, cost = rankOf(b:GetAttribute("RoadTemplateName"))
      local ok, cf = pcall(b.GetPivot, b)
      if rank and ok then
        list[#list + 1] = { rank = rank, cost = cost, pos = cf.Position, name = b.Name, model = b }
      end
    end
  end
  table.sort(list, byPriority)
  local nAd = 0
  for _, t in ipairs(list) do if t.rank == 1 then nAd = nAd + 1 end end
  return list, nAd
end

-- Sasaran untuk gelombang ini: hasil pindai (st.targets) dikurangi yang sudah hancur, ditambah bangunan
-- yang sekarang ter-load tapi belum ada di daftar. Bangunan yang tidak ter-load lagi tetap dipakai
-- (posisinya tidak berubah), jadi kamera tidak perlu tetap di kota musuh.
local function currentTargets(uid)
  local live, seen, list = enemyTargets(uid), {}, {}
  for _, t in ipairs(live) do seen[t.model] = true end
  for _, t in ipairs(st.targets or {}) do
    local gone = t.model.Parent ~= nil and t.model:GetAttribute("Destroyed") == true
    if not gone and not seen[t.model] then list[#list + 1] = t end
  end
  for _, t in ipairs(live) do list[#list + 1] = t end
  table.sort(list, byPriority)
  return list
end

-- aim() untuk satu gelombang: tersebar kalau target = musuh, satu titik kalau target = klik peta
local function makeAim()
  local single = st.target
  if st.enemyUid then
    local list = currentTargets(st.enemyUid)
    if #list > 0 then
      local i = 0
      return function()
        i = i % #list + 1
        return list[i].pos
      end, #list
    end
  end
  return function() return single end, 1
end

-- kirim entries[from..to] sebagai satu barrage
local function sendBarrage(entries, from, to)
  local chunk = {}
  for j = from, to do chunk[#chunk + 1] = entries[j] end
  local ok, err = pcall(Volley.FireServer, Volley, chunk)
  if not ok then note("GAGAL kirim: " .. tostring(err)) return 0 end
  return #chunk
end

-- ===== cadangan kapal: tutup kekurangan launcher darat (rusak / repair / reload) =====
-- Sama dengan tombol fire kapal di game: NavalRemotes.Fire {ships={kapal}, weapon, target, rounds=1}
-- per sasaran. Hanya kapal sendiri yang aktif, tidak hancur, masih punya amunisi, dan sasaran dalam jangkauan.
local function shipPos(ship)
  local s = ship:GetAttribute("ShipState")
  if typeof(s) == "Vector3" then return Vector2.new(s.X, s.Y) end
  local ok, cf = pcall(ship.GetPivot, ship)
  return ok and Vector2.new(cf.Position.X, cf.Position.Z) or nil
end

local function navyShooters()
  local list, ships = {}, workspace:FindFirstChild("Ships")
  for _, ship in ipairs(ships and ships:GetChildren() or {}) do
    local readiness = ship:GetAttribute("Readiness")
    if ship:GetAttribute("OwnerUserId") == lp.UserId and ship:GetAttribute("Destroyed") ~= true
      and (readiness == nil or readiness == "Active") then
      local motion = ship:GetAttribute("ShipMotion")
      local submerged = typeof(motion) == "Vector3" and motion.Z > 1.5
      for _, w in ipairs(K.NAVY_WEAPONS) do
        local ammo = tonumber(ship:GetAttribute("Ammo_" .. w)) or 0
        if ammo > 0 and (w ~= "SLBM" or submerged) then
          list[#list + 1] = { ship = ship, weapon = w, ammo = ammo, pos = shipPos(ship) }
        end
      end
    end
  end
  return list
end

local function navyFire(count, aim)
  local remotes = RS:FindFirstChild("NavalRemotes")
  local fire = remotes and remotes:FindFirstChild("Fire")
  if count <= 0 or not fire then return 0 end
  local shooters, sent = navyShooters(), 0
  for _ = 1, count do
    if not (current() and running) then break end
    local point = aim()
    local pick
    for _, s in ipairs(shooters) do
      local range = K.NAVY_RANGE[s.weapon]
      local d = s.pos and (s.pos - Vector2.new(point.X, point.Z)).Magnitude
      if s.ammo > 0 and d and d >= range[1] and d <= range[2] then pick = s break end
    end
    if not pick then break end
    local ok = pcall(fire.FireServer, fire, { ships = { pick.ship }, weapon = pick.weapon, target = point, rounds = 1 })
    if ok then pick.ammo, sent = pick.ammo - 1, sent + 1 end
  end
  return sent
end

-- Satu gelombang: sisa gelombang sebelumnya (carry) + launcher gelombang ini.
-- Tembak per 99. Kalau totalnya lewat 99, sisanya TIDAK ditembak sendiri tapi ikut barrage gelombang
-- berikutnya (contoh: 104 -> 99 sekarang, 5 ikut 12 hypers = 17). Gelombang terakhir menembak semuanya.
local function fireWave(index, wave, aim, used, carry, isLast)
  local entries, summary = carry, {}
  local fromCarry, short = #carry, 0
  for _, part in ipairs(wave.parts) do
    local got = buildPart(part, aim, used, entries)
    if part.all then
      summary[#summary + 1] = ("%s %d (semua)"):format(part.name, got)
    else
      summary[#summary + 1] = ("%s %d/%d"):format(part.name, got, part.count)
      short = short + (part.count - got)
    end
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
  local navy = (st.navy and short > 0 and current() and running) and navyFire(short, aim) or 0
  note(("G%d: %s | tembak %d%s%s%s"):format(index, table.concat(summary, ", "), sent,
    fromCarry > 0 and (" (+%d sisa sebelumnya)"):format(fromCarry) or "",
    #nextCarry > 0 and (", %d ikut gelombang berikut"):format(#nextCarry) or "",
    short > 0 and (" | kurang %d, kapal %d"):format(short, navy) or ""))
  return sent + navy, nextCarry
end

-- satu putaran = semua baris dari atas ke bawah. Mode ulang: putar terus sampai BERHENTI ditekan.
local function runPlan(waves, gap)
  local round = 0
  repeat
    round = round + 1
    local fired, used, carry = 0, {}, {}   -- used: launcher yang sudah dipakai di putaran ini
    for i, wave in ipairs(waves) do
      if not (current() and running) then break end
      st.status = ("Putaran %d, gelombang %d/%d: %s"):format(round, i, #waves, wave.text)
      local aim = makeAim()   -- daftar sasaran disegarkan tiap gelombang (bangunan hancur dilewati)
      local sent
      sent, carry = fireWave(i, wave, aim, used, carry, i == #waves)
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

-- ===== auto repair: launcher rudal & AD milik sendiri yang hancur =====
-- Sama dengan tombol Rebuild di game (BuildingRepairRemotes.RepairBuilding). Biaya ditanggung seperti biasa;
-- kalau uang kurang, server menolak dan alasannya tampil di panel.
local repairAsked = {}
local function autoRepairOnce()
  local remotes = RS:FindFirstChild("BuildingRepairRemotes")
  local repair = remotes and remotes:FindFirstChild("RepairBuilding")
  if not repair then return end
  local now, asked = os.clock(), 0
  for _, b in ipairs(Placed:GetChildren()) do
    local t = b:IsA("Model") and b:GetAttribute("RoadTemplateName")
    if t and (LAUNCHER_TEMPLATES[t] or AD_TEMPLATES[t]) and b:GetAttribute("PlacementOwnerUserId") == lp.UserId
      and b:GetAttribute("Destroyed") == true and b:GetAttribute("UnderRepair") ~= true
      and now - (repairAsked[b] or -math.huge) >= K.REPAIR_RETRY then
      repairAsked[b] = now
      if pcall(repair.FireServer, repair, b) then asked = asked + 1 end
    end
  end
  if asked > 0 then st.repairMsg = os.date("%H:%M:%S ") .. ("minta repair %d bangunan"):format(asked) end
end
do
  local remotes = RS:FindFirstChild("BuildingRepairRemotes")
  local result = remotes and remotes:FindFirstChild("RepairResult")
  if result then
    table.insert(conns, result.OnClientEvent:Connect(function(ok, msg)
      if not ok and msg then st.repairMsg = "Repair ditolak: " .. tostring(msg) end
    end))
  end
end
task.spawn(function()
  while current() do
    if st.repair then pcall(autoRepairOnce) end
    task.wait(K.REPAIR_EVERY)
  end
end)

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
    st.target, st.picking, st.enemyName, st.enemyUid, st.targets = p, false, nil, nil, nil
    st.status = ("Target terkunci (%.0f, %.0f)."):format(p.X, p.Z)
  end
end))
table.insert(conns, MissileRemotes:WaitForChild("MissileResult").OnClientEvent:Connect(function(ok, msg)
  if not ok and msg then st.serverMsg = tostring(msg) end
end))

-- ===== target dari daftar musuh (tanpa perlu geser kamera peta) =====
-- Musuh = pemilik plot lain yang PVP-nya aktif dan bukan sekutu. Titik target = bangunannya yang paling
-- dekat ke tengah-tengah semua bangunannya (pasti kena bangunan, bukan tanah kosong).
local function enemies()
  local allies = "," .. tostring(lp:GetAttribute("AlliedUserIds") or "") .. ","
  local list, plots = {}, workspace:FindFirstChild("Plots")
  for _, plot in ipairs(plots and plots:GetChildren() or {}) do
    local uid = plot:GetAttribute("OwnerUserId")
    local p = type(uid) == "number" and uid > 0 and uid ~= lp.UserId
      and not allies:find("," .. uid .. ",", 1, true) and Players:GetPlayerByUserId(uid)
    if p and p:GetAttribute("PvpEnabled") == true then
      list[#list + 1] = { uid = uid, name = p.DisplayName, plot = plot }
    end
  end
  table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
  return list
end

local function enemyPoint(e)
  local sum, parts = Vector3.zero, {}
  for _, b in ipairs(Placed:GetChildren()) do
    if b:IsA("Model") and b:GetAttribute("PlacementOwnerUserId") == e.uid and b:GetAttribute("Destroyed") ~= true then
      local ok, cf = pcall(b.GetPivot, b)
      if ok then parts[#parts + 1] = cf.Position sum = sum + cf.Position end
    end
  end
  if #parts == 0 then
    local ok, cf = pcall(e.plot.GetPivot, e.plot)
    return ok and cf.Position or nil, 0
  end
  local mid, best, bestD = sum / #parts, nil, math.huge
  for _, pos in ipairs(parts) do
    local d = (Vector2.new(pos.X, pos.Z) - Vector2.new(mid.X, mid.Z)).Magnitude
    if d < bestD then best, bestD = pos, d end
  end
  return best, #parts
end

-- Paksa load kota musuh: game memuat bangunan di sekitar KAMERA (RemoteViewStreaming + PlotInterest),
-- jadi kamera dipindah ke atas kota itu, tunggu sampai jumlah bangunan berhenti naik, lalu kamera kembali.
-- titik-titik kamera: tengah kota + 4 kuadran (kota besar tidak ter-load semua dari satu titik)
local function scanSpots(e)
  local ok, cf, size = pcall(function()
    if e.plot:IsA("BasePart") then return e.plot.CFrame, e.plot.Size end
    return e.plot:GetBoundingBox()
  end)
  if not ok then
    local p = enemyPoint(e)
    return p and { p } or {}
  end
  local c, hx, hz = cf.Position, math.min(size.X / 4, K.SCAN_SPREAD), math.min(size.Z / 4, K.SCAN_SPREAD)
  return { c, c + Vector3.new(hx, 0, hz), c + Vector3.new(-hx, 0, hz), c + Vector3.new(-hx, 0, -hz),
    c + Vector3.new(hx, 0, -hz), c }
end

-- tahan kamera di satu titik sampai jumlah bangunan tidak naik selama SCAN_STABLE detik
local function holdUntilStable(cam, spot, e, label, started)
  local view = CFrame.lookAt(spot + Vector3.new(0, K.SCAN_HEIGHT, K.SCAN_BACK), spot)
  local last, stable, t0 = -1, 0, os.clock()
  -- minta server mengalirkan area ini juga (fungsi yang sama dipakai peta rudal game)
  task.spawn(pcall, lp.RequestStreamAroundAsync, lp, spot)
  while os.clock() - t0 < K.SCAN_SPOT_MAX and os.clock() - started < K.SCAN_MAX and current() do
    cam.CFrame = view
    task.wait(1)
    local n = #enemyTargets(e.uid)
    st.status = ("Memuat kota %s %s: %d bangunan (%d dtk)"):format(e.name, label, n, math.floor(os.clock() - started))
    stable = (n <= last) and stable + 1 or 0
    last = math.max(n, last)
    if stable >= K.SCAN_STABLE and os.clock() - t0 >= K.SCAN_SPOT_MIN then return end
  end
end

local function scanCity(e)
  local spots = scanSpots(e)
  if #spots == 0 then
    st.status = "Lokasi kota " .. e.name .. " tidak ditemukan."
    return
  end
  local cam = workspace.CurrentCamera
  local saved = { type = cam.CameraType, subject = cam.CameraSubject, cframe = cam.CFrame }
  local started = os.clock()
  local ok, err = pcall(function()
    cam.CameraType = Enum.CameraType.Scriptable
    for i, spot in ipairs(spots) do
      if not current() or os.clock() - started >= K.SCAN_MAX then break end
      holdUntilStable(cam, spot, e, ("titik %d/%d"):format(i, #spots), started)
    end
  end)
  pcall(function()
    cam.CameraType = saved.type
    cam.CameraSubject = saved.subject
    cam.CFrame = saved.cframe
  end)
  if not ok then error(err) end
  local targets, nAd = enemyTargets(e.uid)
  st.targets = targets
  st.target = targets[1] and targets[1].pos or spots[1]
  st.status = ("Kota %s: %d sasaran (%d AD duluan), dimuat %d dtk. Klik nama musuh untuk pindai ulang.")
    :format(e.name, #targets, nAd, math.floor(os.clock() - started))
end

local function pickEnemy(step)
  local list = enemies()
  if #list == 0 then
    st.enemyName, st.status = nil, "Tidak ada musuh dengan PVP aktif (selain sekutu)."
    return
  end
  local idx = 1
  for i, e in ipairs(list) do if e.uid == st.enemyUid then idx = i end end
  if st.enemyUid then idx = (idx - 1 + step) % #list + 1 end
  local e = list[idx]
  st.enemyUid, st.enemyName, st.targets, st.picking = e.uid, ("%s (%d/%d)"):format(e.name, idx, #list), {}, false
  st.scanning = true
  task.spawn(function()
    local ok, err = pcall(scanCity, e)
    st.scanning = false
    if not ok then st.status = "Pindai gagal: " .. tostring(err) end
  end)
end

-- ===== panel =====
local C = {
  bg = Color3.fromRGB(22, 24, 30), field = Color3.fromRGB(34, 37, 46), text = Color3.fromRGB(225, 228, 235),
  dim = Color3.fromRGB(150, 155, 165), go = Color3.fromRGB(40, 150, 80), stop = Color3.fromRGB(170, 60, 60),
  btn = Color3.fromRGB(55, 60, 75), warn = Color3.fromRGB(240, 170, 80),
}
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "BCAttack", false, 60
local frame = Instance.new("Frame")
frame.Size, frame.Position = UDim2.fromOffset(320, 514), UDim2.new(1, -332, 0, 60)
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
local prevBtn = button(10, 182, 30, 30, "<")
local enemyBtn = button(44, 182, 232, 30, "PILIH MUSUH")
local nextBtn = button(280, 182, 30, 30, ">")
enemyBtn.TextTruncate = Enum.TextTruncate.AtEnd
local pickBtn = button(10, 218, 96, 30, "KLIK PETA")
local loopBtn = button(112, 218, 96, 30, "ULANG: ON")
local fireBtn = button(214, 218, 96, 30, "SERANG", C.go)
local navyBtn = button(10, 254, 148, 28, "KAPAL CADANGAN")
local repairBtn = button(162, 254, 148, 28, "AUTO REPAIR")
navyBtn.TextSize, repairBtn.TextSize = 11, 11
local statusLbl = label(290, 58, 12)
local logLbl = label(350, 156, 11, C.dim, Enum.Font.Code)

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
for btn, step in pairs({ [prevBtn] = -1, [enemyBtn] = 0, [nextBtn] = 1 }) do
  table.insert(conns, btn.MouseButton1Click:Connect(clicked(function()
    if running then st.status = "Hentikan serangan dulu untuk ganti target." return end
    if st.scanning then return end
    pickEnemy(step)
  end)))
end
table.insert(conns, navyBtn.MouseButton1Click:Connect(clicked(function() st.navy = not st.navy end)))
table.insert(conns, repairBtn.MouseButton1Click:Connect(clicked(function() st.repair = not st.repair end)))
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
  if st.scanning then st.status = "Tunggu, kota musuh masih dimuat..." return end
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
      enemyBtn.Text = st.enemyName and ("MUSUH: " .. st.enemyName) or "PILIH MUSUH"
      pickBtn.Text = st.picking and "BATAL" or "KLIK PETA"
      pickBtn.BackgroundColor3 = st.picking and C.warn or C.btn
      navyBtn.Text = "KAPAL CADANGAN: " .. (st.navy and "ON" or "OFF")
      navyBtn.BackgroundColor3 = st.navy and C.go or C.btn
      repairBtn.Text = "AUTO REPAIR: " .. (st.repair and "ON" or "OFF")
      repairBtn.BackgroundColor3 = st.repair and C.go or C.btn
      loopBtn.Text = st.loop and "ULANG: ON" or "ULANG: OFF"
      loopBtn.BackgroundColor3 = st.loop and C.go or C.btn
      fireBtn.Text = running and "BERHENTI" or "SERANG"
      fireBtn.BackgroundColor3 = running and C.stop or C.go
      local tgt = st.target and ("Target: %.0f, %.0f"):format(st.target.X, st.target.Z) or "Target: belum ada"
      statusLbl.Text = tgt .. "\n" .. st.status .. (st.serverMsg ~= "" and ("\nServer: " .. st.serverMsg) or "")
        .. (st.repairMsg ~= "" and ("\nRepair: " .. st.repairMsg) or "")
      logLbl.Text = table.concat(st.log, "\n")
    end)
    task.wait(0.3)
  end
  stop()
end)
