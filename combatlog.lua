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
    return ("v3(%.0f,%.0f,%.0f)"):format(v.X, v.Y, v.Z)
  elseif t == "CFrame" then
    return ("cf(%.0f,%.0f,%.0f)"):format(v.X, v.Y, v.Z)
  elseif t == "number" then
    return ("%.4g"):format(v)
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
    lines[#lines + 1] = ("%.2f %s %s"):format(workspace:GetServerTimeNow(), remote.Name, table.concat(parts, " | "))
  end)
end

-- semua RemoteEvent di folder remote yang berhubungan dengan pertempuran
local WORDS = { "patriot", "missile", "radar", "intercept", "combat", "ciws", "defen", "launch" }
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

local running = true
local function flush() pcall(writefile, OUT, table.concat(lines, "\n") .. "\n") end
local function stop()
  running = false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  flush()
end
if getgenv then getgenv().BC_COMBATLOG_STOP = stop end

print(("bc_combatlog: mendengar %d remote -> %s"):format(#found, OUT))
task.spawn(function()
  while running do
    task.wait(FLUSH_EVERY)
    if running then flush() end
  end
end)
