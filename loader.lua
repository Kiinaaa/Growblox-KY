-- Growblox Hansel - LOADER. Ini satu-satunya file yang dijalankan:
--
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/USERNAME/REPO/main/loader.lua"))()
--
-- Loader mengunduh manifest.lua, lalu semua modul di src/ (paralel), merangkainya, dan menjalankan main.
-- Opsional (isi sebelum menjalankan loader):
--   getgenv().GrowbloxHanselBase    = "https://raw.githubusercontent.com/USERNAME/REPO/dev/"  -- cabang lain
--   getgenv().GrowbloxHanselDevPath = "GrowbloxHansel"  -- baca dari folder workspace executor, bukan internet

local BASE = "https://raw.githubusercontent.com/Kiinaaa/Growblox-Ky/main/" -- GANTI: username & nama repo kamu
local RETRIES, TIMEOUT = 3, 60

local env = getgenv and getgenv() or _G
if type(env.GrowbloxHanselBase) == "string" and env.GrowbloxHanselBase ~= "" then BASE = env.GrowbloxHanselBase end
if BASE:sub(-1) ~= "/" then BASE = BASE .. "/" end
local DEV = type(env.GrowbloxHanselDevPath) == "string" and env.GrowbloxHanselDevPath or nil

-- Ambil teks satu file (dari internet, atau dari folder workspace kalau mode dev).
local function fetch(path)
    if DEV then
        assert(type(readfile) == "function" and type(isfile) == "function", "Mode dev butuh readfile/isfile.")
        local full = DEV .. "/" .. path
        assert(isfile(full), "File tidak ada di workspace: " .. full)
        return readfile(full)
    end
    local lastProblem
    for attempt = 1, RETRIES do
        local ok, body = pcall(function() return game:HttpGet(BASE .. path) end)
        -- raw.githubusercontent membalas teks "404: Not Found" untuk file yang tidak ada
        if ok and type(body) == "string" and #body > 20 and body:sub(1, 3) ~= "404" then return body end
        lastProblem = ok and ("balasan tidak valid (" .. tostring(body):sub(1, 40) .. ")") or tostring(body)
        if attempt < RETRIES then task.wait(0.5 * attempt) end
    end
    error(path .. ": " .. tostring(lastProblem), 0)
end

local function compile(source, path)
    local chunk, message = loadstring(source, "=" .. path)
    assert(chunk, "Gagal membaca " .. path .. ": " .. tostring(message))
    return chunk
end

-- 1) manifest
local manifest = compile(fetch("manifest.lua"), "manifest.lua")()
assert(type(manifest) == "table" and type(manifest.modules) == "table", "manifest.lua rusak.")

-- 2) unduh semua modul sekaligus
local sources, failures, pending = {}, {}, #manifest.modules
for _, entry in ipairs(manifest.modules) do
    task.spawn(function()
        local ok, result = pcall(fetch, entry[2])
        if ok then sources[entry[1]] = result else table.insert(failures, tostring(result)) end
        pending = pending - 1
    end)
end
local deadline = os.clock() + TIMEOUT
while pending > 0 and os.clock() < deadline do task.wait(0.05) end
if pending > 0 then table.insert(failures, "timeout: " .. pending .. " file belum selesai diunduh") end
if #failures > 0 then
    error("Growblox Hansel gagal dimuat:\n  " .. table.concat(failures, "\n  "), 0)
end

-- 3) jalankan tiap file (hasilnya modul: tabel, atau function(G)) dan simpan per nama
local modules = {}
for _, entry in ipairs(manifest.modules) do
    modules[entry[1]] = compile(sources[entry[1]], entry[2])()
end
assert(type(modules.main) == "function", "Modul main tidak ditemukan di manifest.")

-- 4) untuk auto-rejoin: setelah pindah server, executor menjalankan loader ini lagi
env.GrowbloxHanselLoaderURL = BASE .. "loader.lua"
env.GrowbloxHanselLoaderDebug = (DEV and ("dev " .. DEV) or ("remote " .. BASE)) .. " v" .. tostring(manifest.version)

return modules.main(modules, manifest.version)
