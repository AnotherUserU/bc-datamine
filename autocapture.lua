-- Build and Conquer: auto-capture zona tengah. INTERNAL (Delta).
-- Zona = part dengan tag CollectionService "CaptureZone" (nama CaptureZone..CaptureZone10, lihat CaptureZoneTypes).
-- Status: atribut CaptureState ("Captured"/"Contested") + CaptureOwnerUserId. Cara capture (dari game):
-- "Have the only units inside the border to take it." Oil rig hanya bisa direbut kapal.
-- Script mengirim unit milik sendiri (workspace.MilitaryTrucks, Squads, Ships) lewat fungsi game
-- GameActions.OrderUnits, sama seperti perintah gerak biasa; server tetap menentukan jalurnya.
-- Tiap zona yang belum milikmu diberi beberapa unit terdekat (Unit per zona). "Jaga zona" ON = unit tetap
-- di zona yang sudah direbut; OFF = unit pindah ke zona berikutnya.
-- Private server: zona tidak memberi hadiah (atribut workspace.CaptureRewardsOff), ditampilkan di panel.
if game.GameId ~= 10757247806 then return end
if _G.BC_CAPTURE then pcall(_G.BC_CAPTURE.stop) end
if not game:IsLoaded() then game.Loaded:Wait() end

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local CS = game:GetService("CollectionService")
local UIS = game:GetService("UserInputService")
local lp = Players.LocalPlayer

local TICK = 3                 -- dtk antar evaluasi
local REORDER_AFTER = 25       -- dtk; unit yang belum sampai diperintah ulang (bisa macet/terblokir)
local SPREAD = 0.3             -- unit disebar di lingkaran = SPREAD x setengah ukuran zona terkecil
-- urutan prioritas zona (judul dari CaptureZoneTypes); yang tidak ada di daftar paling akhir
local PRIORITY = { "URANIUM MINE", "CITY", "INDUSTRIAL ZONE", "NUCLEAR POWER PLANT", "OIL FIELD",
  "MINING SITE", "AIRPORT", "OIL RIG" }

local GameActions = require(RS:WaitForChild("GameActions"))
local ZoneTypes = require(RS:WaitForChild("CaptureZoneTypes"))

local alive, enabled, garrison = true, false, true
local perZone = 3
local zoneOn = {}              -- zona -> false kalau dimatikan di panel
local assign = {}              -- unit -> { zone, slot, orderedAt }
local conns = {}
local statusText = "OFF"

local function attr(i, k)
  local ok, v = pcall(i.GetAttribute, i, k)
  return ok and v or nil
end

local function zoneInfo(z)
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
  local lpnt = z.CFrame:PointToObjectSpace(p)
  return math.abs(lpnt.X) <= z.Size.X / 2 and math.abs(lpnt.Z) <= z.Size.Z / 2
end

local function zones()
  local list = {}
  for _, z in ipairs(CS:GetTagged("CaptureZone")) do
    if z:IsA("BasePart") and z.Parent then list[#list + 1] = z end
  end
  local function rank(z)
    local title = zoneInfo(z)
    for i, t in ipairs(PRIORITY) do if t == title then return i end end
    return #PRIORITY + 1
  end
  table.sort(list, function(a, b)
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    return a.Name < b.Name
  end)
  return list
end

-- ===== unit milik sendiri =====
local function unitPos(u)
  local ok, cf = pcall(u.GetPivot, u)
  return ok and cf.Position or nil
end

local function myUnits()
  local land, sea = {}, {}
  for _, folder in ipairs({ "MilitaryTrucks", "Squads", "Ships" }) do
    local f = workspace:FindFirstChild(folder)
    for _, u in ipairs(f and f:GetChildren() or {}) do
      if u:IsA("Model") and attr(u, "OwnerUserId") == lp.UserId and attr(u, "Destroyed") ~= true
        and attr(u, "Faction") ~= "Hostile" then
        local p = unitPos(u)
        if p then
          local list = folder == "Ships" and sea or land
          list[#list + 1] = { unit = u, pos = p }
        end
      end
    end
  end
  return land, sea
end

-- titik di tanah dekat tengah zona, disebar per slot supaya unit tidak bertumpuk
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local function slotPoint(z, slot, isSea)
  local r = math.min(z.Size.X, z.Size.Z) / 2 * SPREAD
  local a = (slot - 1) * 2.399      -- sudut emas: sebaran rata
  local off = slot == 1 and Vector3.zero or Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
  local c = z.Position + off
  if isSea then return Vector3.new(c.X, -5.5, c.Z) end   -- ShipKinds.SeaLevel
  rayParams.FilterDescendantsInstances = { z, lp.Character }
  local hit = workspace:Raycast(c + Vector3.new(0, 500, 0), Vector3.new(0, -2000, 0), rayParams)
  return hit and hit.Position or c
end

-- ===== pembagian unit =====
local function evaluate()
  local land, sea = myUnits()
  local alive_ = {}
  for _, e in ipairs(land) do alive_[e.unit] = e end
  for _, e in ipairs(sea) do alive_[e.unit] = e end
  -- lepas unit yang hilang / zonanya dimatikan / zona sudah milikmu (kalau tidak dijaga)
  for u, a in pairs(assign) do
    if not alive_[u] or not a.zone.Parent or zoneOn[a.zone] == false or (not garrison and zoneMine(a.zone)) then
      assign[u] = nil
    end
  end
  local count = {}
  for _, a in pairs(assign) do count[a.zone] = (count[a.zone] or 0) + 1 end
  local function free(list)
    local out = {}
    for _, e in ipairs(list) do if not assign[e.unit] then out[#out + 1] = e end end
    return out
  end
  local freeLand, freeSea = free(land), free(sea)
  for _, z in ipairs(zones()) do
    if zoneOn[z] ~= false and not zoneMine(z) then
      local _, rig = zoneInfo(z)
      local pool = rig and freeSea or freeLand
      local need = perZone - (count[z] or 0)
      while need > 0 and #pool > 0 do
        local best, bd = nil, math.huge
        for i, e in ipairs(pool) do
          local d = (e.pos - z.Position).Magnitude
          if d < bd then best, bd = i, d end
        end
        local e = table.remove(pool, best)
        count[z] = (count[z] or 0) + 1
        assign[e.unit] = { zone = z, slot = count[z], orderedAt = 0, sea = rig }
        need = need - 1
      end
    end
  end
  -- kirim perintah: unit baru, atau belum sampai setelah REORDER_AFTER dtk
  local now, orders, sent = os.clock(), {}, 0
  for u, a in pairs(assign) do
    local e = alive_[u]
    if e and not inside(a.zone, e.pos) and now - a.orderedAt >= REORDER_AFTER then
      orders[#orders + 1] = { unit = u, position = slotPoint(a.zone, a.slot, a.sea) }
      a.orderedAt = now
    end
  end
  if #orders > 0 then
    local ok, res = pcall(GameActions.OrderUnits, orders, "Move")
    sent = (ok and res) and #orders or 0
    if not ok then statusText = "Order ERR: " .. tostring(res) return end
  end
  local n = 0
  for _ in pairs(assign) do n = n + 1 end
  statusText = ("Unit darat %d, kapal %d, ditugaskan %d%s"):format(#land, #sea, n,
    sent > 0 and (", perintah baru %d"):format(sent) or "")
end

-- ===== panel =====
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "BCCapturePanel", false, 50
gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
local W, ROW = 270, 22
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
local onRow = row("", function() enabled = not enabled; if not enabled then assign = {} end; render() end)
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
end))
local rewardRow = row("")
rewardRow.TextColor3 = Color3.fromRGB(255, 130, 130)
local zoneRows = {}
local MAX_ZONES = 12
for i = 1, MAX_ZONES do
  zoneRows[i] = row("", function()
    local z = zoneRows[i].zone
    if z then zoneOn[z] = zoneOn[z] == false end
    assign = {}
    render()
  end)
end
local statusRow = row("")
statusRow.TextColor3 = Color3.fromRGB(150, 150, 150)
statusRow.TextWrapped = true
statusRow.Size = UDim2.fromOffset(W, ROW * 2)

render = function()
  onRow.Text = ">> Auto Capture: " .. (enabled and "ON" or "OFF")
  onRow.TextColor3 = enabled and Color3.fromRGB(120, 255, 120) or Color3.fromRGB(255, 220, 80)
  garRow.Text = "Jaga zona yang sudah direbut: " .. (garrison and "ON" or "OFF")
  local off = workspace:GetAttribute("CaptureRewardsOff") == true
  rewardRow.Visible = off
  rewardRow.Text = "Private server: zona TIDAK memberi hadiah"
  local per = {}
  for _, a in pairs(assign) do per[a.zone] = (per[a.zone] or 0) + 1 end
  local list = zones()
  for i, r in ipairs(zoneRows) do
    local z = list[i]
    r.zone, r.Visible = z, z ~= nil
    if z then
      local t = zoneInfo(z)
      local on = zoneOn[z] ~= false
      r.Text = ("[%s] %s - %s%s"):format(on and "x" or " ", t, zoneStatus(z),
        per[z] and ("  (%d unit)"):format(per[z]) or "")
      r.TextColor3 = not on and Color3.fromRGB(120, 120, 120)
        or (zoneMine(z) and Color3.fromRGB(130, 200, 255) or Color3.fromRGB(215, 212, 228))
    end
  end
  statusRow.Text = enabled and statusText or ("OFF. " .. #list .. " zona ditemukan")
  local shown = 0
  for _, c in ipairs(panel:GetChildren()) do
    if c:IsA("GuiObject") and c.Visible then shown = shown + c.Size.Y.Offset / ROW end
  end
  panel.Size = UDim2.fromOffset(W, ROW * shown)
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

task.spawn(function()
  while alive do
    if enabled then
      local ok, err = pcall(evaluate)
      if not ok then statusText = "ERR: " .. tostring(err) end
    end
    pcall(render)
    task.wait(TICK)
  end
end)

_G.BC_CAPTURE = {
  stop = function()
    alive = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    pcall(function() gui:Destroy() end)
  end,
}
