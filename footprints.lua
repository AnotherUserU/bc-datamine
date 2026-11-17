-- Build and Conquer: ukur tapak (stud) SEMUA jenis bangunan yang ada di peta. READ ONLY.
-- Cara sama dengan game (BuildTools): model:GetBoundingBox() pada bangunan di workspace.PlacedRoads,
-- diputar balik sesuai RoadRotationDegrees supaya ukuran = posisi tanpa rotasi.
-- Mencakup bangunan semua pemain yang sudah ter-stream (kamera dekat = lebih banyak). Jalankan di beberapa
-- tempat/server: hasil digabung dengan file lama (ukuran terkecil per template disimpan).
-- Output: bc_footprints.txt (workspace executor) -> template | X stud | Z stud | tinggi | jalan (X/2 x Z/2) | contoh
local OUT = "bc_footprints.txt"

local known = {}
pcall(function()
  for line in readfile(OUT):gmatch("[^\n]+") do
    local t, x, z, y, n = line:match("^(.-) | ([%d%.]+) | ([%d%.]+) | ([%d%.]+) | .- | (%d+)$")
    if t then known[t] = { x = tonumber(x), z = tonumber(z), y = tonumber(y), n = tonumber(n) } end
  end
end)

-- muat bangunan di semua plot dulu (StreamingEnabled): 3x3 titik per plot lewat RequestStreamAroundAsync
if workspace.StreamingEnabled and workspace:FindFirstChild("Plots") then
  local lp = game:GetService("Players").LocalPlayer
  for _, plot in ipairs(workspace.Plots:GetChildren()) do
    local ok, c = pcall(function() return plot:IsA("BasePart") and plot.Position or plot:GetPivot().Position end)
    if ok then
      for _, dx in ipairs({ -200, 0, 200 }) do
        for _, dz in ipairs({ -200, 0, 200 }) do
          pcall(lp.RequestStreamAroundAsync, lp, c + Vector3.new(dx, 0, dz), 10)
        end
      end
    end
  end
  task.wait(2)
end

local placed = workspace:FindFirstChild("PlacedRoads")
if not placed then error("workspace.PlacedRoads tidak ada") end
local added, seen = 0, 0
for _, m in ipairs(placed:GetChildren()) do
  local tmpl = m:GetAttribute("RoadTemplateName")
  if tmpl and m:IsA("Model") then
    local ok, _, size = pcall(m.GetBoundingBox, m)
    if ok and size then
      seen = seen + 1
      local rot = tonumber(m:GetAttribute("RoadRotationDegrees")) or 0
      local x, z = size.X, size.Z
      if math.floor(rot / 90 + 0.5) % 2 == 1 then x, z = z, x end
      x, z = math.floor(x * 10 + 0.5) / 10, math.floor(z * 10 + 0.5) / 10
      local k = known[tmpl]
      if not k then
        known[tmpl] = { x = x, z = z, y = math.floor(size.Y * 10 + 0.5) / 10, n = 1 }
        added = added + 1
      else
        k.n = k.n + 1
        if x * z < k.x * k.z then k.x, k.z = x, z end -- terkecil = paling sedikit dekorasi menonjol
      end
    end
  end
end

local lines, names = {}, {}
for t in pairs(known) do names[#names + 1] = t end
table.sort(names)
for _, t in ipairs(names) do
  local k = known[t]
  lines[#lines + 1] = ("%s | %.1f | %.1f | %.1f | %.1f x %.1f jalan | %d"):format(t, k.x, k.z, k.y, k.x / 2, k.z / 2, k.n)
end
writefile(OUT, table.concat(lines, "\n") .. "\n")
print(("bc_footprints: %d bangunan diukur, %d jenis baru, total %d jenis -> %s"):format(seen, added, #names, OUT))
