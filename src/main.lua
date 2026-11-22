-- main.lua: titik masuk. Kumpulkan alat dari executor/Roblox, rangkai semua modul, connect ke game.
-- Urutan: bersihkan sesi lama -> App -> modul -> UI -> connect (dengan retry) -> loop heartbeat.
return function(modules, VERSION)
    local HttpService = game:GetService("HttpService")
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local UserInputService = game:GetService("UserInputService")
    local Workspace = game:GetService("Workspace")
    local player = Players.LocalPlayer
    local env = getgenv and getgenv() or _G
    local ACCOUNT_ID = player.UserId
    assert(type(ACCOUNT_ID) == "number" and ACCOUNT_ID > 0, "Akun Roblox belum siap. Jalankan lagi setelah login.")

    -- 1) Script dijalankan ulang? Matikan instance lama dulu biar nggak ada dua yang jalan.
    local previous = env.GrowbloxHanselApp
    if previous then
        previous.alive = false
        previous.token = (previous.token or 0) + 1
        -- Kembalikan kontrol karakter yang mungkin masih dipegang instance lama.
        local hold = previous.controls
        if hold then
            if hold.table.dir == hold.dirOverride then hold.table.dir = hold.dir end
            if hold.table.jumping == hold.jumpOverride then hold.table.jumping = hold.jumping end
            if hold.world.displayTake == hold.displayOverride then hold.world.displayTake = hold.displayTake end
            if hold.world.takeDrop == hold.takeOverride then hold.world.takeDrop = hold.takeDrop end
            previous.controls = nil
        end
        if previous.window then pcall(function() previous.window:Destroy() end) end
        if previous.idleConnection then pcall(function() previous.idleConnection:Disconnect() end) end
    end
    -- Window lama sudah dihancurkan, jadi library WindUI yang di-cache ikut basi (error "Window is not a
    -- valid member of ScreenGui"). Buang cache-nya supaya WindUI dimuat ulang bersih.
    env.GrowbloxHanselWindUI = nil

    -- 2) App = seluruh state yang hidup selama script jalan.
    local App = {
        alive = true, job = nil, jobToken = nil, token = 0, pending = 0, configuring = false,
        status = "Menyambung ke Growblox...", logs = {}, runtime = nil, connectionError = nil,
        discoveryReport = {}, startupStage = "Memuat", profile = "Default",
        stats = { gems = 0, broken = 0, planted = 0, harvested = 0 },
    }
    env.GrowbloxHanselApp = App

    -- 3) G = "kotak alat" yang dibagikan ke semua modul. Semua akses ke executor/Roblox lewat sini,
    -- jadi di tes kita tinggal ganti isi G dengan versi palsu (mock).
    local G = { App = App, VERSION = VERSION, task = task, UDim2 = UDim2, accountId = ACCOUNT_ID }
    G.exec = {
        getgc = getgc, getupvalues = getupvalues or (debug and debug.getupvalues),
        getupvalue = getupvalue or (debug and debug.getupvalue),
        debugInfo = debug and debug.info, getinfo = getinfo or (debug and debug.getinfo),
        getrawmetatable = getrawmetatable, setclipboard = setclipboard or toclipboard,
        sharedTables = { { label = "executor shared", value = shared }, { label = "executor globals", value = env.shared } },
    }
    if type(getrenv) == "function" then
        local ok, gameEnv = pcall(getrenv)
        if ok and type(gameEnv) == "table" then
            table.insert(G.exec.sharedTables, { label = "game runtime shared", value = gameEnv.shared })
        end
    end
    G.fs = { isfile = isfile, readfile = readfile, writefile = writefile, isfolder = isfolder,
        makefolder = makefolder, delfile = delfile }
    G.json = { encode = function(v) return HttpService:JSONEncode(v) end,
        decode = function(s) return HttpService:JSONDecode(s) end }
    G.registryKey = function() return ReplicatedStorage:GetAttribute("Qz") end
    G.serverTime = function() return Workspace:GetServerTimeNow() end
    G.isInstance = function(v) return type(typeof) == "function" and typeof(v) == "Instance" end
    G.frozen = function() return player:GetAttribute("Frozen") == true end
    G.accountOk = function() return player.UserId == ACCOUNT_ID end
    G.focusedTextBox = function() return UserInputService:GetFocusedTextBox() end
    G.env = env
    G.queueOnTeleport = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
    G.newInstance, G.Color3 = Instance and Instance.new, Color3
    G.guiParent = function()
        if type(gethui) == "function" then return gethui() end
        return game:GetService("CoreGui")
    end

    local WindUI
    function G.setStatus(text)
        if text == App.status then return end -- teks sama: jangan kerja lagi
        App.status = text
        if App.debugPrint then print("[Growblox Hansel] " .. text) end -- print ke console lambat; hanya saat debug
        table.insert(App.logs, 1, os.date("%H:%M:%S") .. "  " .. text)
        if #App.logs > 30 then table.remove(App.logs) end
    end
    function G.notify(text)
        if WindUI then pcall(function() WindUI:Notify({ Title = "Growblox Hansel", Content = text, Duration = 6 }) end) end
    end

    -- 4) Rangkai modul. Urutannya mengikuti siapa butuh siapa.
    G.resumeHandlers = {} -- fitur yang bisa di-resume mendaftar di sini
    G.onConnected = {}    -- dipanggil setiap kali berhasil tersambung (misal isi ulang pilihan seed)
    G.Core = modules.core
    G.Navigation = modules.navigation
    G.Net = modules.net(G)
    G.State = modules.state(G)
    G.Bridge = modules.bridge(G)
    G.Actions = modules.actions(G)
    G.Movement = modules.movement(G)
    G.Storage = modules.storage(G)
    G.Drops = modules.drops(G)
    G.Jobs = modules.jobs(G)
    G.Scan = modules.scan(G)
    G.UI = modules.ui(G)
    G.Pnb = modules.pnb(G)
    G.Harvest = modules.harvest(G)
    G.Rotation = modules.rotation(G)
    G.AutoCollect = modules.autocollect(G)
    App.config = G.Core.defaults()

    function G.connect()
        G.setStatus("Menyambung ke game...")
        local r = G.Bridge.connect({ attempts = 8, delay = 4, onRetry = function(attempt, total, message)
            G.setStatus("World belum siap (" .. message .. "). Coba lagi " .. attempt .. "/" .. (total - 1) .. "...")
        end })
        G.setStatus(r.ready and ("Tersambung ke " .. r.world.name .. ".")
            or ("Tersambung ke " .. r.world.name .. ", tapi ada hook yang hilang. Cek diagnostics."))
        for _, handler in ipairs(G.onConnected) do pcall(handler, r) end
        return r
    end

    function G.diagnostics()
        local lines = {
            "Growblox Hansel " .. VERSION,
            "World: " .. (App.runtime and App.runtime.world.name or "belum tersambung"),
            "Profil: " .. App.profile .. " | Akun: " .. ACCOUNT_ID,
            "Status: " .. App.status,
            "Connect error: " .. (App.connectionError or "tidak ada"),
            "Percobaan connect: " .. tostring(App.connectAttempts or "-"),
            "Tahap startup: " .. App.startupStage,
            "Loader: " .. tostring(env.GrowbloxHanselLoaderDebug or "lokal / tidak diketahui"),
            "Job: " .. tostring(App.job or "idle") .. " | Request pending: " .. App.pending,
            "Navigasi: " .. tostring(App.navigationDebug or "-"),
            "Anti-AFK: " .. (App.config.options.antiAFK and "on" or "off") .. "; "
                .. (App.antiAFKError or (App.idleConnection and "siap" or "belum terpasang"))
                .. (App.lastIdleInput and string.format("; input terakhir %.0f detik lalu", os.clock() - App.lastIdleInput) or ""),
            (function()
                local function counts(map)
                    local parts = {}
                    for _, key in ipairs({ "Place & Break", "Rotation" }) do
                        if map[key] then table.insert(parts, key .. " " .. map[key] .. "x") end
                    end
                    return #parts > 0 and table.concat(parts, ", ") or "0"
                end
                local errors = {}
                for name, issue in pairs(App.resumeErrors or {}) do table.insert(errors, name .. ": " .. issue) end
                return "Rejoin: " .. (App.config.options.autoRejoin and "on" or "off") .. "; masuk ulang " .. counts(App.rejoins or {})
                    .. "; diulang karena error " .. counts(App.retries or {})
                    .. (App.lastRetryError and ("; terakhir: " .. App.lastRetryError) or "")
                    .. (#errors > 0 and ("; checkpoint error: " .. table.concat(errors, ", ")) or "")
            end)(),
            "Jangkauan pungut server: " .. G.Drops.reachText(),
            "Delay Put & Break: " .. tostring(App.config.options.placeDelay) .. "s, boost otomatis x"
                .. string.format("%.2f", App.delayBoost or 1) .. ", miss terdeteksi " .. tostring(App.delayMisses or 0) .. "x",
            "Panen: jangkauan pukul sambil jalan " .. string.format("%.2f", App.harvestReach or 1.5) .. " tile, pohon miss " .. tostring(App.harvestMisses or 0) .. "x",
            "Stock terakhir: " .. tostring(App.stockDebug or "-"),
            "Auto collect: " .. (App.config and App.config.options.autoCollect and "semua item" or "idle off") .. ", saat PNB/Rotation SELALU (blok & gem), mode " .. G.AutoCollect.mode() .. ", jangkauan "
                .. tostring(App.config and App.config.options.collectRange) .. ", " .. tostring(App.autoCollectInfo or "-"),
            "Rotation: " .. tostring(App.rotationInfo or "-") .. " | world ke-" .. tostring(App.rotationIndex or "-")
                .. ", putaran " .. tostring(App.rotationLaps or 0)
                .. ", error kecil dilewati " .. tostring(App.rotationSoftErrors or 0) .. "x"
                .. (App.rotationLastError and ("; error kecil terakhir: " .. App.rotationLastError) or ""),
            "Rotation cepat: replant dari jarak " .. tostring(App.rotationFastReplant ~= false) .. ", seed ditolak server "
                .. tostring(App.rotationReplantMiss or 0) .. "x, tile PNB paralel " .. tostring(App.config.rotation.pnbTiles)
                .. ", break kiri farm " .. tostring(App.config.rotation.breakLeft) .. ", tile break pilihan " .. #App.config.rotation.breakTiles
                .. ", place " .. tostring(App.config.rotation.placeDelay) .. "s, break " .. tostring(App.config.rotation.punchDelay) .. "s",
            "Blok dipecah sesi ini: " .. App.stats.broken .. " | Pohon dipanen: " .. tostring(App.stats.trees or 0)
                .. " | Seed ditanam ulang: " .. tostring(App.stats.replanted or 0),
            "PNB: blok " .. tostring(App.config.blockId) .. ", " .. #App.config.pnb.tiles .. " tile, auto stock "
                .. tostring(App.config.pnb.autoStock) .. ", auto drop " .. tostring(App.config.pnb.autoDrop) .. ", balik ke spot " .. (App.pnbRecoveries or 0) .. "x, tile ditolak canPlace " .. (App.pnbCantPlace or 0) .. "x, place tidak muncul di server " .. (App.pnbRejected or 0) .. "x",
        }
        for _, line in ipairs(App.discoveryReport) do table.insert(lines, line) end
        if App.scanReport then
            table.insert(lines, "World Scan:")
            for _, line in ipairs(App.scanReport) do table.insert(lines, "  " .. line) end
        end
        table.insert(lines, "Log:")
        for i = 1, math.min(#App.logs, 15) do table.insert(lines, App.logs[i]) end
        return table.concat(lines, "\n")
    end

    -- Anti-AFK (adaptasi installAntiAFK Clarissv v0.1.43): saat Roblox mendeteksi idle,
    -- kirim klik kanan virtual lewat VirtualUser. Maksimal sekali per menit.
    function G.installAntiAFK()
        if App.idleConnection then return true end
        local ok, service = pcall(function() return game:GetService("VirtualUser") end)
        if not ok then App.antiAFKError = tostring(service); return false end
        local connected, connection = pcall(function()
            return player.Idled:Connect(function()
                if not App.alive or not App.config.options.antiAFK then return end
                if App.lastIdleInput and os.clock() - App.lastIdleInput < 60 then return end
                local sent, message = pcall(function()
                    service:CaptureController()
                    service:ClickButton2(Vector2.new(0, 0))
                end)
                if sent then App.lastIdleInput, App.antiAFKError = os.clock(), nil
                else App.antiAFKError = tostring(message) end
            end)
        end)
        if not connected then App.antiAFKError = tostring(connection); return false end
        App.idleConnection, App.antiAFKError = connection, nil
        return true
    end

    function G.unload()
        if not App.alive then return end
        if App.idleConnection then pcall(function() App.idleConnection:Disconnect() end); App.idleConnection = nil end
        if App.job then pcall(G.Jobs.stop) end
        pcall(G.Movement.releaseControls)
        App.alive = false
        App.token = App.token + 1
        if env.GrowbloxHanselApp == App then env.GrowbloxHanselApp = nil end
        if App.window then pcall(function() App.window:Destroy() end) end
        env.GrowbloxHanselWindUI = nil
    end

    -- 5) Pulihkan setting terakhir (kalau ada), lalu muat UI.
    local restored, problem = pcall(G.State.restoreSession)
    if not restored then G.setStatus("Session lama nggak bisa dibaca: " .. tostring(problem)) end
    if App.config.options.antiAFK then G.installAntiAFK() end

    local function loadWindUI()
        -- Urutan: file lokal (kalau ada) -> URL kustom -> rilis resmi WindUI. Satu file main.lua cukup.
        -- Library TIDAK di-cache antar run, supaya window lama yang sudah dihancurkan tidak ikut terpakai.
        local urls = {}
        if type(env.GrowbloxHanselWindUIURL) == "string" then table.insert(urls, env.GrowbloxHanselWindUIURL) end
        table.insert(urls, "https://github.com/Footagesus/WindUI/releases/latest/download/main.lua")
        table.insert(urls, "https://raw.githubusercontent.com/Footagesus/WindUI/main/dist/main.lua")
        local source, lastProblem
        if G.State.exists("GrowbloxHansel/WindUI.lua") then source = readfile("GrowbloxHansel/WindUI.lua") end
        for _, url in ipairs(urls) do
            if source then break end
            local okGet, body = pcall(function() return game:HttpGet(url) end)
            if okGet and type(body) == "string" and #body > 10000 then source = body
            else lastProblem = tostring(body) end
        end
        if not source then error("WindUI gagal diunduh (" .. tostring(lastProblem) .. "). Cek koneksi, atau taruh WindUI.lua di workspace/GrowbloxHansel/.") end
        local chunk, message = loadstring(source, "WindUI")
        assert(chunk, "WindUI gagal dibaca: " .. tostring(message))
        local ui = chunk()
        env.GrowbloxHanselWindUI = ui
        return ui
    end
    WindUI = loadWindUI()
    G.UI.build(WindUI)

    -- 6) Connect di latar belakang. Tunggu atribut Qz (tanda game sudah memuat modulnya), maks 30 detik.
    task.spawn(function()
        local deadline = os.clock() + 30
        while App.alive and ReplicatedStorage:GetAttribute("Qz") == nil and os.clock() < deadline do task.wait(0.25) end
        if not App.alive then return end
        App.configuring = true
        local ok, message = pcall(G.connect)
        App.configuring = false
        if not ok then
            G.setStatus(tostring(message))
            G.notify(tostring(message))
            return
        end
        -- Setelah pindah server, fitur yang punya checkpoint dilanjutkan otomatis.
        if env.GrowbloxHanselAutoResume then
            env.GrowbloxHanselAutoResume = nil
            for _, handler in ipairs(G.resumeHandlers) do
                local found, resumed = pcall(handler)
                if found and resumed then break end
                if not found then G.setStatus("Gagal resume: " .. tostring(resumed)) end
            end
        end
    end)

    -- 7) Heartbeat: update UI dan simpan setting berkala.
    task.spawn(function()
        local nextSave = 0
        while App.alive do
            pcall(G.UI.refresh)
            if not App.configuring and not App.job and os.clock() >= nextSave then -- saat task jalan config tidak berubah
                nextSave = os.clock() + 5
                local saved, issue = pcall(G.State.saveSession)
                App.sessionSaveError = not saved and tostring(issue) or nil
            end
            task.wait(0.5)
        end
    end)

    G.setStatus("Script dimuat. Menunggu game...")
    return App
end
