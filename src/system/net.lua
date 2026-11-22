-- net.lua: token Stop, jeda yang bisa dibatalkan, dan request ke server dengan batas waktu.
-- Diadaptasi dari Clarissv main.lua (checkpoint, pause, beginRequest, awaitRequest, bounded).
return function(G)
    local App, task = G.App, G.task
    local Net = {}

    -- Tiap job dapat nomor token. Stop = token naik, jadi semua loop yang pegang
    -- token lama langsung gagal di checkpoint() dan berhenti dengan rapi.
    function Net.checkpoint(token)
        assert(App.alive and App.job and token == App.token, "Stopped.")
        assert(G.accountOk(), "Akun Roblox berubah. Reload script.")
    end

    -- Jeda dalam potongan maks 0,05 detik, sambil cek Stop di tiap potongan.
    -- TURBO: jeda <= 2 ms tidak menunggu sama sekali. Game cuma dikasih napas (task.wait) tiap ~12 ms
    -- supaya tidak freeze. Net.tick = satu yield paksa (dipakai loop pukul supaya tidak spam dalam satu frame).
    local lastYield = os.clock()
    function Net.tick(token)
        if token then Net.checkpoint(token) end
        task.wait()
        lastYield = os.clock()
    end
    function Net.pause(seconds, token)
        if seconds <= 0.002 then
            if token then Net.checkpoint(token) end
            if os.clock() - lastYield >= 0.008 then task.wait(); lastYield = os.clock() end
            return
        end
        local deadline = os.clock() + seconds
        repeat
            if token then Net.checkpoint(token) end
            task.wait(math.min(0.05, math.max(0, deadline - os.clock())))
            lastYield = os.clock()
        until os.clock() >= deadline
    end

    -- Jalankan fn di thread terpisah. App.pending > 0 = ada request yang belum selesai,
    -- dan selama itu task baru tidak boleh mulai (lihat Net.idle).
    function Net.beginRequest(fn, ...)
        local args = table.pack(...)
        local request = { done = false }
        App.pending = App.pending + 1
        task.spawn(function()
            request.result = table.pack(pcall(fn, table.unpack(args, 1, args.n)))
            App.pending = App.pending - 1
            request.done = true
        end)
        return request
    end

    function Net.awaitRequest(request, deadline, token)
        while not request.done do
            if token then Net.checkpoint(token) end
            assert(App.alive, "Script di-unload.")
            assert(os.clock() < deadline, "Request ke server timeout.")
            task.wait() -- tiap frame (dulu 0,05 detik = ~3 frame per batch)
        end
        if not request.result[1] then error(request.result[2], 0) end
        return table.unpack(request.result, 2, request.result.n)
    end

    -- Panggil fn(...) dan tunggu maksimal `seconds` detik.
    function Net.bounded(fn, seconds, token, ...)
        return Net.awaitRequest(Net.beginRequest(fn, ...), os.clock() + seconds, token)
    end

    function Net.idle()
        assert(App.alive, "Script sudah di-unload.")
        -- Auto Collect (saat idle) sedang mungut: minta berhenti & tunggu sebentar (maks 3 detik).
        if App.autoCollecting then
            App.autoCollectHold = true
            local deadline = os.clock() + 3
            while App.autoCollecting and os.clock() < deadline do task.wait(0.05) end
            App.autoCollectHold = false
        end
        assert(not App.job and not App.configuring and App.pending == 0,
            "Stop task yang jalan dan tunggu request selesai dulu.")
    end

    -- Mulai job baru: token naik, jadi job lama (kalau ada) ikut berhenti.
    function Net.beginJob(name)
        Net.idle()
        App.token = App.token + 1
        App.job, App.jobToken, App.lastError = name, App.token, nil
        return App.token
    end
    function Net.stopJob()
        App.token = App.token + 1
        App.job, App.jobToken = nil, nil
    end

    return Net
end
