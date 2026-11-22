-- ui.lua: jendela WindUI. Pondasi baru bikin kerangka tab + tab Settings.
-- Tab: Place & Break (+ Auto Collect), Rotation, dan Settings.
return function(G)
    local App, task = G.App, G.task
    local UI = { tabs = {}, statuses = {} }

    -- Paragraf "Status" di tiap tab, diupdate bareng oleh UI.refresh().
    function UI.addStatus(paragraph) table.insert(UI.statuses, paragraph); return paragraph end

    -- Bungkus aksi tombol: jalan di thread sendiri, cek sedang tidak ada task,
    -- dan kalau error tampilkan pesannya, bukan bikin script crash.
    function UI.action(fn)
        return function()
            task.spawn(function()
                local ok, message = pcall(G.Net.idle)
                if not ok then G.notify(tostring(message)); return end
                App.configuring = true
                ok, message = pcall(fn)
                App.configuring = false
                if ok then ok, message = pcall(G.State.saveSession) end
                if not ok then G.setStatus(tostring(message)); G.notify(tostring(message)) end
            end)
        end
    end

    function UI.paragraph(paragraph, title, desc)
        if paragraph and paragraph.ParagraphFrame then
            paragraph.ParagraphFrame:SetTitle(title)
            paragraph.ParagraphFrame:SetDesc(desc)
        end
    end

    function UI.build(WindUI)
        local window = WindUI:CreateWindow({
            Title = "Growblox PNB", Author = "v" .. G.VERSION .. " | Place & Break + Rotation",
            Folder = G.State.ROOT, Icon = "sprout", Size = G.UDim2.fromOffset(600, 520),
            OpenButton = { Title = "Growblox PNB", Enabled = true, Draggable = true, OnlyMobile = false },
        })
        UI.window = window
        App.window = window
        window:OnDestroy(function() G.unload() end)

        -- Urutan tab = urutan muncul di layar. Auto Collect ada di dalam tab Place & Break.
        UI.tabs.pnb = window:Tab({ Title = "Place & Break", Icon = "hammer" })
        UI.tabs.rotation = window:Tab({ Title = "Rotation", Icon = "repeat" })
        UI.tabs.settings = window:Tab({ Title = "Settings", Icon = "settings" })
        G.Pnb.buildTab(UI.tabs.pnb)
        G.Rotation.buildTab(UI.tabs.rotation)

        local s = UI.tabs.settings
        UI.status = UI.addStatus(s:Paragraph({ Title = "Status", Desc = App.status }))
        s:Button({ Title = "Stop task", Desc = "Hentikan task yang lagi jalan. Checkpoint resume ikut dihapus.",
            Callback = function() G.Jobs.stop() end })
        s:Button({ Title = "Reconnect to game", Desc = "Pakai ini kalau muncul 'found 0'. Masuk world dulu, baru pencet.",
            Callback = UI.action(function() G.connect() end) })
        s:Button({ Title = "Copy diagnostics", Callback = function()
            local text = G.diagnostics()
            if type(G.exec.setclipboard) == "function" then G.exec.setclipboard(text); G.notify("Diagnostics di-copy.")
            else print(text); G.notify("Diagnostics dicetak ke console.") end
        end })
        UI.buildSettings(s)
        s:Button({ Title = "Unload script", Callback = function() G.unload() end })
        UI.log = s:Paragraph({ Title = "Aktivitas terakhir", Desc = "-" })
        return window
    end

    -- Setting umum (adaptasi tab Settings Clarissv v0.1.43). Hanya bisa diubah saat tidak ada task.
    -- Hit delay, Place delay, dan batas seed ada di tab Place & Break.
    function UI.buildSettings(s)
        local Core, State, Net = G.Core, G.State, G.Net
        UI.settings = {}
        pcall(function() s:Section({ Title = "Settings" }) end)
        for _, info in ipairs({
            { "antiAFK", "Anti-AFK", "Jaga sesi tetap aktif saat Roblox mendeteksi idle (klik virtual tiap idle, maks sekali per menit)." },
            { "autoRejoin", "Rejoin world and return to PNB & Rotation", "Keluar ke world picker, avatar mati, atau pindah server: masuk lagi ke world task (PNB: balik ke spot; Rotation: scan ulang, lanjut dari world terakhir)." },
        }) do
            local key = info[1]
            UI.settings[key] = s:Toggle({ Title = info[2], Desc = info[3], Value = App.config.options[key],
                Callback = function(value)
                    if App.syncingSettings then return end
                    local ok, message = pcall(function()
                        Net.idle()
                        App.config.options[key] = value == true
                        if key == "antiAFK" and value then G.installAntiAFK() end
                        State.saveSession()
                    end)
                    if not ok then
                        G.notify("Stop task dulu sebelum mengubah setting.")
                        App.syncingSettings = true
                        pcall(function() UI.settings[key]:Set(App.config.options[key], false, false) end)
                        App.syncingSettings = false
                    end
                end })
        end
        for _, info in ipairs({
            -- v0.9: delay Put & Break cuma ada SATU, di tab Place & Break. Waktu tunggu drop dihapus (otomatis).
            { "actionTimeout", "Batas waktu request server (detik)", 1 }, { "moveTimeout", "Batas waktu jalan (detik)", 1 },
        }) do
            local key, limits = info[1], Core.LIMITS[info[1]]
            UI.settings[key] = s:Slider({ Title = info[2], Step = info[3],
                Value = { Min = limits[1], Max = limits[2], Default = App.config.options[key] },
                Callback = function(value)
                    if App.syncingSettings then return end
                    local ok = pcall(function()
                        if not Core.DELAYS[key] then Net.idle() end -- delay boleh diubah saat task jalan
                        value = tonumber(value)
                        if Core.DELAYS[key] then value = math.max(limits[1], value) end -- tidak boleh 0
                        App.config.options[key] = value
                        State.saveSession()
                    end)
                    if not ok then G.notify("Stop task dulu sebelum mengubah setting.") end
                end })
        end
    end

    -- Dipanggil berkala dari main.lua.
    -- Hanya menyentuh UI kalau teksnya berubah (SetDesc WindUI itu berat dan bikin patah-patah).
    function UI.refresh()
        if App.status ~= UI.lastStatus then
            UI.lastStatus = App.status
            for _, paragraph in ipairs(UI.statuses) do UI.paragraph(paragraph, "Status", App.status) end
        end
        G.Jobs.syncToggles()
        local logText = table.concat(App.logs, "\n", 1, math.min(#App.logs, 8))
        if logText ~= UI.lastLog then
            UI.lastLog = logText
            UI.paragraph(UI.log, "Aktivitas terakhir", logText)
        end
    end

    return UI
end
