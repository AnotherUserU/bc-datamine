-- Build and Conquer: datamine lengkap untuk executor INTERNAL. READ ONLY (hanya membaca & menulis file).
-- 1) require() tiap ModuleScript di ReplicatedStorage (bagian "bcdump_mod_<Nama>") (tabel lengkap, rekursif)
-- 2) AirDefenseInfo + bangunan AD/launcher di peta: SEMUA atribut (bagian "bcdump_attrs")
-- 3) getgc(true): tabel yang punya key reload/cooldown/chance/interval dll (bagian "bcdump_gc")
-- 4) decompile script bernama patriot/defense/intercept/missile/launcher/... (bagian "bcdump_src")
-- 5) status live semua air defense/launcher di server: amunisi, magazine, ReadyAt (bagian "bcdump_ad_live")
-- Tiap bagian ditulis sebagai file sendiri (seperti versi awal) DAN digabung ke bcdump_all.txt.
-- bcdump_all.txt dicoba ke /storage/emulated/0/Download, kalau ditolak ke workspace executor.
local DOWNLOAD_PATH = "/storage/emulated/0/Download/bcdump_all.txt"
local ALL = {}
local function save(name, text)
  ALL[#ALL + 1] = "##### " .. name .. "\n" .. text
  pcall(writefile, name, text)
end
local MAX_DEPTH, MAX_LINES = 8, 200000
local GC_KEY_WORDS = { "reload", "cooldown", "chance", "interval", "firerate", "salvo", "intercept", "ammo", "magazine" }
local function interestingKey(k)
  local low = k:lower()
  for _, w in ipairs(GC_KEY_WORDS) do if low:find(w, 1, true) then return true end end
  return false
end

local RS = game:GetService("ReplicatedStorage")
local function safeName(s) return (tostring(s):gsub("[^%w%-_]", "_")) end
local function fmt(v)
  local t = typeof(v)
  if t == "string" then return ("%q"):format(v)
  elseif t == "number" or t == "boolean" or t == "nil" then return tostring(v)
  elseif t == "Instance" then return "<Instance " .. v:GetFullName() .. ">"
  elseif t == "function" then return "<function>"
  else return "<" .. t .. " " .. tostring(v) .. ">" end
end

-- serialisasi tabel, kunci diurutkan, siklus ditandai
local function serialize(root)
  local out, seen = {}, {}
  local function walk(t, indent, depth)
    if #out > MAX_LINES then return end
    if seen[t] then out[#out + 1] = indent .. "<siklus>" return end
    seen[t] = true
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local v = rawget(t, k)
      if type(v) == "table" and depth < MAX_DEPTH then
        out[#out + 1] = indent .. tostring(k) .. " = {"
        walk(v, indent .. "  ", depth + 1)
        out[#out + 1] = indent .. "}"
      else
        out[#out + 1] = indent .. tostring(k) .. " = " .. fmt(v)
      end
    end
    seen[t] = nil
  end
  walk(root, "", 0)
  return table.concat(out, "\n")
end

-- ===== 1) module =====
local okMods, failMods = 0, {}
for _, m in ipairs(RS:GetDescendants()) do
  if m:IsA("ModuleScript") then
    local ok, res = pcall(require, m)
    if ok then
      okMods = okMods + 1
      local body = type(res) == "table" and serialize(res) or fmt(res)
      save("bcdump_mod_" .. safeName(m.Name) .. ".txt", "-- " .. m:GetFullName() .. "\n" .. body .. "\n")
    else
      failMods[#failMods + 1] = m:GetFullName() .. " : " .. tostring(res)
    end
  end
end

-- ===== 2) atribut =====
local attrLines = {}
local function dumpAttrs(inst, label)
  attrLines[#attrLines + 1] = "== " .. label
  local attrs = inst:GetAttributes()
  local keys = {}
  for k in pairs(attrs) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do attrLines[#attrLines + 1] = ("  %s = %s"):format(k, fmt(attrs[k])) end
end
local function norm(x) return (tostring(x):lower():gsub("[^%w]", "")) end
local adInfo = RS:FindFirstChild("AirDefenseInfo")
local adNorm = {}
if adInfo then
  for _, c in ipairs(adInfo:GetChildren()) do
    dumpAttrs(c, "AirDefenseInfo." .. c.Name)
    adNorm[norm(c.Name)] = true
  end
end
local WEAPON_WORDS = { "launch", "silo", "rail", "himars", "typhon", "patriot", "pantsir", "ciws", "irondome", "manpads", "vads", "rapidfire", "aagun", "radar" }
local placedRoot = workspace:FindFirstChild("PlacedRoads")
local placed = placedRoot and placedRoot:GetChildren() or {}
attrLines[#attrLines + 1] = ("-- workspace.PlacedRoads: %d bangunan terlihat (bangunan jauh bisa belum ter-stream)"):format(#placed)
local done, liveRows = {}, {}
local LIVE_ATTRS = { "PatriotAmmo", "PatriotMagazine", "PatriotReadyAt", "PatriotResupplying", "PatriotEnabled", "Health", "Operational" }
for _, m in ipairs(placed) do
  local tmpl = m:GetAttribute("RoadTemplateName") or m.Name:gsub("^Placed", "")
  local key = norm(tmpl)
  local weapon = adNorm[key] or m:GetAttribute("PatriotMagazine") ~= nil
  for _, w in ipairs(WEAPON_WORDS) do if key:find(w, 1, true) then weapon = true end end
  if weapon then
    -- satu dump atribut lengkap per jenis
    if not done[key] then
      done[key] = true
      dumpAttrs(m, tostring(tmpl) .. " (owner " .. tostring(m:GetAttribute("PlacementOwnerUserId")) .. ")")
    end
    -- status live semua bangunan senjata
    local row = { tostring(tmpl), tostring(m:GetAttribute("PlacementOwnerUserId")) }
    for _, a in ipairs(LIVE_ATTRS) do row[#row + 1] = tostring(m:GetAttribute(a)) end
    liveRows[#liveRows + 1] = table.concat(row, ",")
  end
end
save("bcdump_attrs.txt", table.concat(attrLines, "\n") .. "\n")
table.sort(liveRows)
save("bcdump_ad_live.txt", ("serverTime=%s\nTemplate,Owner,%s\n"):format(tostring(workspace:GetServerTimeNow()), table.concat(LIVE_ATTRS, ","))
  .. table.concat(liveRows, "\n") .. "\n")

-- ===== 3) getgc =====
local gcLines, gcCount = {}, 0
if getgc then
  local seenT = {}
  local okGc, objs = pcall(getgc, true)
  if not okGc or type(objs) ~= "table" then gcLines[1] = "getgc gagal: " .. tostring(objs); objs = {} end
  for _, o in ipairs(objs) do
    if type(o) == "table" and not seenT[o] then
      local hit = false
      pcall(function()
        for k in pairs(o) do
          if type(k) == "string" and interestingKey(k) then hit = true break end
        end
      end)
      if hit then
        seenT[o] = true
        gcCount = gcCount + 1
        local ok, s = pcall(serialize, o)
        gcLines[#gcLines + 1] = "== #" .. gcCount .. "\n" .. (ok and s or "<gagal>")
      end
    end
  end
end
save("bcdump_gc.txt", table.concat(gcLines, "\n") .. "\n")

-- ===== 4) decompile script yang berhubungan dengan senjata/air defense (kalau executor punya decompile) =====
local SRC_WORDS = { "patriot", "defen", "intercept", "missile", "launcher", "pantsir", "ciws", "radar", "weapon", "combat", "reload" }
local srcCount, srcLines = 0, {}
if decompile then
  local roots = { RS }
  local lp = game:GetService("Players").LocalPlayer
  if lp:FindFirstChild("PlayerScripts") then roots[#roots + 1] = lp.PlayerScripts end
  if lp:FindFirstChild("PlayerGui") then roots[#roots + 1] = lp.PlayerGui end
  for _, root in ipairs(roots) do
    for _, sc in ipairs(root:GetDescendants()) do
      if sc:IsA("LuaSourceContainer") then
        local low, hit = sc.Name:lower(), false
        for _, w in ipairs(SRC_WORDS) do if low:find(w, 1, true) then hit = true break end end
        if hit then
          local ok, src = pcall(decompile, sc)
          srcCount = srcCount + 1
          srcLines[#srcLines + 1] = "== " .. sc:GetFullName() .. "\n" .. (ok and tostring(src) or ("<decompile gagal: " .. tostring(src) .. ">"))
        end
      end
    end
  end
else
  srcLines[1] = "executor tidak punya decompile"
end
save("bcdump_src.txt", table.concat(srcLines, "\n\n") .. "\n")

-- satu file gabungan: coba langsung ke folder Download (Android); kalau executor menolak, ke workspace
local allText = table.concat(ALL, "\n")
local savedTo = "workspace executor/bcdump_all.txt"
if not pcall(writefile, DOWNLOAD_PATH, allText) then pcall(writefile, "bcdump_all.txt", allText) else savedTo = DOWNLOAD_PATH end
print("bc_dump: file gabungan -> " .. savedTo)
print(("bc_dump: %d module, %d gagal, %d baris atribut, %d tabel getgc, %d script didecompile"):format(okMods, #failMods, #attrLines, gcCount, srcCount))
for _, f in ipairs(failMods) do print("  gagal: " .. f) end
