-- Build and Conquer: auto shuffle kandidat City Hall sampai Augustus Vale muncul, lalu berhenti. INTERNAL (Delta).
-- Dari ReplicatedStorage.Politics: Shuffle = RemoteFunction PoliticsRemotes.Shuffle (tanpa argumen, 25 PP).
-- Pool kandidat ada di atribut player "PoliticsState" (JSON, dibaca lewat Politics.Decode). Augustus = entri r == true
-- (peluang 0,01% per kandidat, 5 kandidat per shuffle -> rata-rata ~2000 shuffle / ~50.000 PP).
-- PP bertambah tiap 30 dtk (maks 500), jadi script menunggu PP cukup lalu shuffle lagi. Anti-AFK ikut aktif.
-- Jalankan ulang = versi lama berhenti sendiri (atribut BCShuffleRun di folder GUI).
if game.GameId ~= 10757247806 then return end
local G = (getgenv and getgenv()) or _G
for _, env in ipairs({ G, _G }) do
  if env.BC_SHUFFLE then pcall(env.BC_SHUFFLE.stop) env.BC_SHUFFLE = nil end
end
local GUI_PARENT = (gethui and gethui()) or game:GetService("CoreGui")
local RUN_ID = ("%04x"):format(math.random(0, 0xffff))
GUI_PARENT:SetAttribute("BCShuffleRun", RUN_ID)
for _, old in ipairs(GUI_PARENT:GetChildren()) do
  if old.Name == "BCShufflePanel" then old:Destroy() end
end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local UIS = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local lp = Players.LocalPlayer

local Politics = require(RS:WaitForChild("Politics"))
local ShuffleRemote = RS:WaitForChild(Politics.RemoteFolderName):WaitForChild("Shuffle")

local SHUFFLE_GAP = 1.5        -- dtk minimal antar shuffle (beri waktu state ter-update)
local STATE_WAIT = 5           -- dtk maks menunggu state berubah setelah shuffle

local alive, enabled = true, false
local found = false
local count, spent, fails = 0, 0, 0
local statusText, lastResult = "OFF", "-"
local afkCount = 0
local conns = {}

local LOG_FILE = "bc_shuffle_log.txt"
local function log(msg)
  local line = os.date("%H:%M:%S") .. " [" .. RUN_ID .. "] " .. msg
  pcall(function()
    local ok = appendfile and pcall(appendfile, LOG_FILE, line .. "\n")
    if not ok then writefile(LOG_FILE, line .. "\n") end
  end)
end
log("=== auto shuffle mulai ===")

local function current() return alive and GUI_PARENT:GetAttribute("BCShuffleRun") == RUN_ID end

local function state() return Politics.Decode(lp:GetAttribute(Politics.StateAttribute)) end

local function rareIndex(s)
  for i, c in ipairs(s.pool) do
    if c.r == true then return i end
  end
  return nil
end

local function poolText(s)
  local parts = {}
  for _, c in ipairs(s.pool) do parts[#parts + 1] = ("%s %d*"):format(tostring(c.n), tonumber(c.s) or 0) end
  return #parts > 0 and table.concat(parts, ", ") or "(kosong)"
end

local function notify(text)
  pcall(StarterGui.SetCore, StarterGui, "SendNotification", { Title = "Auto Shuffle", Text = text, Duration = 30 })
end

local function onFound(s, i)
  found, enabled = true, false
  statusText = ("AUGUSTUS DITEMUKAN (kandidat #%d)! Appoint sekarang."):format(i)
  log(("DITEMUKAN Augustus Vale di slot %d setelah %d shuffle (%d PP). Pool: %s"):format(i, count, spent, poolText(s)))
  notify("Augustus Vale muncul! Buka City Hall dan appoint.")
end

-- Satu shuffle: panggil remote, lalu tunggu state berubah. Dipanggil dari thread sendiri (bukan thread GUI).
local function shuffleOnce()
  local before = lp:GetAttribute(Politics.StateAttribute)
  local ok, res, msg = pcall(ShuffleRemote.InvokeServer, ShuffleRemote)
  if not ok then
    fails = fails + 1
    lastResult = "error: " .. tostring(res)
    log("SHUFFLE error: " .. tostring(res))
    return
  end
  if res ~= true then
    fails = fails + 1
    lastResult = "ditolak: " .. tostring(msg or res)
    log("SHUFFLE ditolak: " .. tostring(msg or res))
    return
  end
  count = count + 1
  spent = spent + Politics.ShuffleCost
  local t0 = os.clock()
  while lp:GetAttribute(Politics.StateAttribute) == before and os.clock() - t0 < STATE_WAIT do task.wait(0.1) end
  local s = state()
  lastResult = poolText(s)
  if count % 25 == 0 then log(("shuffle #%d, %d PP terpakai, sisa PP %d"):format(count, spent, s.pp)) end
end

local function step()
  if lp:GetAttribute(Politics.ReadyAttribute) ~= true then
    statusText = "City Hall belum jadi / belum ada"
    return 2
  end
  local s = state()
  local i = rareIndex(s)
  if i then onFound(s, i) return 1 end
  if s.pp < Politics.ShuffleCost then
    statusText = ("Menunggu PP: %d/%d (bertambah tiap %d dtk)"):format(s.pp, Politics.ShuffleCost, Politics.PowerInterval)
    return 2
  end
  statusText = ("Shuffle... PP %d"):format(s.pp)
  shuffleOnce()
  local after = state()
  local j = rareIndex(after)
  if j then onFound(after, j) end
  return SHUFFLE_GAP
end

-- ===== anti-AFK =====
pcall(function()
  local VirtualUser = game:GetService("VirtualUser")
  conns[#conns + 1] = lp.Idled:Connect(function()
    if not current() then return end
    VirtualUser:CaptureController()
    VirtualUser:ClickButton2(Vector2.new())
    afkCount = afkCount + 1
  end)
end)

-- ===== panel =====
local gui = Instance.new("ScreenGui")
gui.Name = "BCShufflePanel"
gui.ResetOnSpawn = false
local frame = Instance.new("Frame")
frame.Size = UDim2.fromOffset(300, 170)
frame.Position = UDim2.new(0, 12, 0.5, -85)
frame.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
frame.BorderSizePixel = 0
frame.Active, frame.Draggable = true, true
frame.Parent = gui
Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 8)

local function label(y, h, size)
  local l = Instance.new("TextLabel")
  l.BackgroundTransparency = 1
  l.Position = UDim2.fromOffset(10, y)
  l.Size = UDim2.new(1, -20, 0, h)
  l.Font = Enum.Font.GothamMedium
  l.TextSize = size or 12
  l.TextColor3 = Color3.fromRGB(225, 228, 235)
  l.TextXAlignment = Enum.TextXAlignment.Left
  l.TextYAlignment = Enum.TextYAlignment.Top
  l.TextWrapped = true
  l.Parent = frame
  return l
end
local title = label(8, 18, 14)
title.Text = "Auto Shuffle -> Augustus Vale"
local btn = Instance.new("TextButton")
btn.Position = UDim2.fromOffset(10, 30)
btn.Size = UDim2.new(1, -20, 0, 26)
btn.Font = Enum.Font.GothamBold
btn.TextSize = 13
btn.TextColor3 = Color3.new(1, 1, 1)
btn.BorderSizePixel = 0
btn.Parent = frame
Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
local info = label(62, 100, 12)

local lastClick = 0
btn.MouseButton1Click:Connect(function()
  if os.clock() - lastClick < 0.35 then return end
  lastClick = os.clock()
  if found then found = false end   -- mulai lagi setelah ditemukan (mis. Augustus sudah di-appoint)
  enabled = not enabled
  statusText = enabled and "ON" or "OFF"
  log(enabled and "ON" or "OFF")
end)
gui.Parent = GUI_PARENT

local function render()
  btn.Text = enabled and "ON (klik untuk berhenti)" or (found and "DITEMUKAN - klik untuk lanjut" or "OFF (klik untuk mulai)")
  btn.BackgroundColor3 = found and Color3.fromRGB(200, 150, 30)
    or (enabled and Color3.fromRGB(40, 150, 80) or Color3.fromRGB(90, 90, 100))
  local s = state()
  info.Text = ("%s\nShuffle: %d  |  PP terpakai: %d  |  PP: %d\nGagal: %d  |  Anti-AFK: %d\nPool: %s")
    :format(statusText, count, spent, s.pp, fails, afkCount, lastResult)
end

local function stop()
  alive = false
  for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
  pcall(function() gui:Destroy() end)
end
G.BC_SHUFFLE = { stop = stop }

conns[#conns + 1] = UIS.InputBegan:Connect(function(input, processed)
  if processed or not current() then return end
  if input.KeyCode == Enum.KeyCode.Delete then frame.Visible = not frame.Visible end
end)

-- Loop kerja dan loop panel terpisah: thread yang memanggil remote tidak menulis GUI.
task.spawn(function()
  while current() and gui.Parent do
    local delay = 1
    if enabled then
      local ok, res = pcall(step)
      if ok then delay = res else
        statusText = "error: " .. tostring(res)
        log("STEP error: " .. tostring(res))
        delay = 3
      end
    end
    task.wait(delay)
  end
  stop()
end)

task.spawn(function()
  while current() and gui.Parent do
    pcall(render)
    task.wait(0.5)
  end
end)
