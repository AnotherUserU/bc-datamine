-- Build and Conquer: combat logger untuk mengukur hit chance air defense. READ ONLY (hanya mendengar event).
-- Mencatat setiap event dari server tentang interceptor & rudal (peluncuran interceptor, rudal dicegat,
-- efek rudal) lengkap dengan isinya + waktu, supaya rasio intercept per air defense bisa dihitung.
-- Biarkan jalan selama perang. Ditulis tiap 5 dtk ke bc_combatlog.txt (workspace executor).
-- Jalankan lagi = logger lama dimatikan dulu.
local OUT, FLUSH_EVERY, MAX_DEPTH = "bc_combatlog.txt", 5, 4
local RS = game:GetService("ReplicatedStorage")

if getgenv and getgenv().BC_COMBATLOG_STOP then pcall(getgenv().BC_COMBATLOG_STOP) end

local function fmt(v, depth)
  depth = depth or 0
  local t = typeof(v)
  if t == "table" then
    if depth >= MAX_DEPTH then return "{...}" end
    local parts = {}
    for k, x in pairs(v) do parts[#parts + 1] = tostring(k) .. "=" .. fmt(x, depth + 1) end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
  elseif t == "Instance" then
    local tmpl = v:GetAttribute("RoadTemplateName")
    local owner = v:GetAttribute("PlacementOwnerUserId")
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

local lines, conns, count = { "-- mulai serverTime=" .. tostring(workspace:GetServerTimeNow()) }, {}, 0
local function listen(remote)
  conns[#conns + 1] = remote.OnClientEvent:Connect(function(...)
    count = count + 1
    local args = table.pack(...)
    local parts = {}
    for i = 1, args.n do parts[#parts + 1] = fmt(args[i]) end
    lines[#lines + 1] = ("%.3f %s %s"):format(workspace:GetServerTimeNow(), remote.Name, table.concat(parts, " | "))
  end)
end

-- semua RemoteEvent di folder remote yang berhubungan dengan pertempuran
local WORDS = { "patriot", "missile", "radar", "intercept", "combat", "ciws", "defen", "launch", "naval", "ship", "torpedo" }
local found = {}
for _, f in ipairs(RS:GetChildren()) do
  local low = f.Name:lower()
  for _, w in ipairs(WORDS) do
    if low:find(w, 1, true) then
      for _, r in ipairs(f:GetDescendants()) do
        if r:IsA("RemoteEvent") then listen(r); found[#found + 1] = r:GetFullName() end
      end
      break
    end
  end
end
lines[#lines + 1] = "-- mendengar: " .. table.concat(found, ", ")

-- v2: atribut status air defense (amunisi, magazine, ReadyAt = reload pasti dari server)
local WATCH = { "PatriotAmmo", "PatriotMagazine", "PatriotReadyAt", "PatriotResupplying", "PatriotEnabled", "Operational" }
local watched = 0
local function watchBuilding(m)
  if not m:IsA("Model") or m:GetAttribute("PatriotMagazine") == nil then return end
  watched = watched + 1
  local p = m:GetPivot().Position
  local tag = ("%s owner=%s at=(%.0f,%.0f)"):format(tostring(m:GetAttribute("RoadTemplateName")), tostring(m:GetAttribute("PlacementOwnerUserId")), p.X, p.Z)
  local snap = {}
  for _, a in ipairs(WATCH) do snap[#snap + 1] = a .. "=" .. fmt(m:GetAttribute(a)) end
  lines[#lines + 1] = ("%.3f ADSNAP %s | %s"):format(workspace:GetServerTimeNow(), tag, table.concat(snap, ", "))
  for _, a in ipairs(WATCH) do
    conns[#conns + 1] = m:GetAttributeChangedSignal(a):Connect(function()
      lines[#lines + 1] = ("%.3f ADATTR %s | %s=%s"):format(workspace:GetServerTimeNow(), tag, a, fmt(m:GetAttribute(a)))
    end)
  end
end
local placed = workspace:FindFirstChild("PlacedRoads")
if placed then
  for _, m in ipairs(placed:GetChildren()) do pcall(watchBuilding, m) end
  conns[#conns + 1] = placed.ChildAdded:Connect(function(m) task.wait(1) pcall(watchBuilding, m) end)
end
lines[#lines + 1] = ("-- air defense dilacak: %d"):format(watched)

local running = true
local function flush() pcall(writefile, OUT, table.concat(lines, "\n") .. "\n") end
local function stop()
  running = false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  flush()
end
if getgenv then getgenv().BC_COMBATLOG_STOP = stop end

print(("bc_combatlog: mendengar %d remote, %d air defense -> %s"):format(#found, watched, OUT))
task.spawn(function()
  while running do
    task.wait(FLUSH_EVERY)
    if running then flush() end
  end
end)
