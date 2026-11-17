-- Build and Conquer: decompile SEMUA script client (LocalScript + ModuleScript). READ ONLY.
-- Hanya script yang ada di client (server script tidak pernah dikirim ke client).
-- Hasil: folder bcsrc/ di workspace executor, satu file per script + bcsrc/_index.txt.
-- Progress tampil di console; bisa lama (decompile ~0,2-1 dtk per script).
local OUT_DIR = "bcsrc"
local YIELD_EVERY = 5

if not decompile then error("executor ini tidak punya decompile()") end
pcall(makefolder, OUT_DIR)

local Players = game:GetService("Players")
local lp = Players.LocalPlayer
local roots = {
  game:GetService("ReplicatedStorage"), game:GetService("ReplicatedFirst"),
  game:GetService("StarterPlayer"), game:GetService("StarterGui"), game:GetService("StarterPack"),
  workspace,
}
if lp then
  for _, n in ipairs({ "PlayerScripts", "PlayerGui", "Backpack" }) do
    local f = lp:FindFirstChild(n)
    if f then roots[#roots + 1] = f end
  end
  if lp.Character then roots[#roots + 1] = lp.Character end
end

-- kumpulkan script unik (StarterPlayerScripts dan PlayerScripts sering berisi salinan yang sama)
local list, seenPath = {}, {}
for _, root in ipairs(roots) do
  local ok, desc = pcall(function() return root:GetDescendants() end)
  for _, s in ipairs(ok and desc or {}) do
    local isSrc = s:IsA("LocalScript") or s:IsA("ModuleScript") or (s:IsA("Script") and s.RunContext == Enum.RunContext.Client)
    if isSrc then
      local path = s:GetFullName()
      if not seenPath[path] then seenPath[path] = true; list[#list + 1] = s end
    end
  end
end
print(("bc_decompile: %d script ditemukan"):format(#list))

local index, okCount, failCount, used = {}, 0, 0, {}
for i, s in ipairs(list) do
  local path = s:GetFullName()
  local base = path:gsub("^Players%.[^%.]+%.", "Player."):gsub("[^%w%._%-]", "_")
  if #base > 150 then base = base:sub(1, 120) .. "_" .. i end
  if used[base] then base = base .. "_" .. i end
  used[base] = true
  local ok, src = pcall(decompile, s)
  if ok and type(src) == "string" and #src > 0 then
    okCount = okCount + 1
    pcall(writefile, OUT_DIR .. "/" .. base .. ".lua", "-- " .. path .. " [" .. s.ClassName .. "]\n" .. src)
    index[#index + 1] = ("OK    %7d  %s  -> %s.lua"):format(#src, path, base)
  else
    failCount = failCount + 1
    index[#index + 1] = ("FAIL           %s  (%s)"):format(path, tostring(src))
  end
  if i % YIELD_EVERY == 0 then
    print(("bc_decompile: %d/%d"):format(i, #list))
    pcall(writefile, OUT_DIR .. "/_index.txt", table.concat(index, "\n") .. "\n")
    task.wait()
  end
end
pcall(writefile, OUT_DIR .. "/_index.txt", table.concat(index, "\n") .. "\n")
print(("bc_decompile: selesai, %d berhasil, %d gagal -> %s/"):format(okCount, failCount, OUT_DIR))
