-- Build and Conquer: datamine lengkap untuk executor INTERNAL. READ ONLY (hanya membaca & menulis file).
-- 1) require() tiap ModuleScript di ReplicatedStorage -> bcdump_mod_<Nama>.txt (tabel lengkap, rekursif)
-- 2) AirDefenseInfo + bangunan AD/launcher di peta: SEMUA atribut -> bcdump_attrs.txt
-- 3) getgc(true): tabel yang punya key reload/cooldown/chance/interval dll -> bcdump_gc.txt
-- File muncul di folder workspace executor. Semua juga digabung ke bcdump_all.txt (satu file, gampang dipindah).
local ALL = {}
local function save(name, text)
  ALL[#ALL + 1] = "##### " .. name .. "
" .. text
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
local adInfo = RS:FindFirstChild("AirDefenseInfo")
local adTemplate = {}
if adInfo then
  for _, c in ipairs(adInfo:GetChildren()) do
    dumpAttrs(c, "AirDefenseInfo." .. c.Name)
    adTemplate["Placed" .. c.Name] = true
  end
end
local isWeapon = { launch = true, silo = true, rail = true, himars = true, typhon = true }
local done = {}
for _, m in ipairs(workspace.PlacedRoads:GetChildren()) do
  local n = m.Name
  local low = n:lower()
  local weapon = adTemplate[n]
  for k in pairs(isWeapon) do if low:find(k, 1, true) then weapon = true end end
  if weapon and not done[n] then
    done[n] = true
    dumpAttrs(m, n .. " (owner " .. tostring(m:GetAttribute("PlacementOwnerUserId")) .. ")")
  end
end
save("bcdump_attrs.txt", table.concat(attrLines, "\n") .. "\n")

-- ===== 3) getgc =====
local gcLines, gcCount = {}, 0
if getgc then
  local seenT = {}
  for _, o in ipairs(getgc(true)) do
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

pcall(writefile, "bcdump_all.txt", table.concat(ALL, "
"))
print(("bc_dump: %d module, %d gagal, %d baris atribut, %d tabel getgc"):format(okMods, #failMods, #attrLines, gcCount))
for _, f in ipairs(failMods) do print("  gagal: " .. f) end
