-- jobs.lua: mulai/stop task (Planting, Harvest, PNB, Rotation) dengan satu cara yang sama.
-- Diadaptasi dari Clarissv main.lua v0.1.43: start, App:stop, setRunningEnabled, syncRunToggles.
-- Bedanya: tiap fitur MENDAFTAR di sini (Jobs.register), jadi start() tidak perlu tahu isi fiturnya.
return function(G)
    local App, Core, Bridge, Net, Movement, task = G.App, G.Core, G.Bridge, G.Net, G.Movement, G.task
    local Jobs = { specs = {}, toggles = {} }

    -- spec = {
    --   label        nama di status, misal "Planting"
    --   prepare(r, saved)   cek hook game yang dibutuhkan (opsional; saved = checkpoint resume)
    --   run(token, saved)   isi task; selesai normal = return, gagal = error
    --   clear()      hapus checkpoint fitur ini (dipanggil saat Stop / task lain mulai)
    --   resume       true = checkpoint `mode` dilanjutkan otomatis setelah pindah server
    --   validResume(data)   cek isi checkpoint sebelum dilanjutkan (opsional)
    -- }
    function Jobs.register(mode, spec)
        Jobs.specs[mode] = spec
        if spec.resume then
            table.insert(G.resumeHandlers, function()
                local record = G.State.loadCheckpoint(mode)
                if not record or type(record.data) ~= "table" then return false end
                if spec.validResume and not spec.validResume(record.data) then return false end
                App.config, App.profile = record.config, Core.profileName(record.profile)
                Jobs.start(mode, record.data)
                return true
            end)
        end
    end

    ---------------------------------------------------------------- dipakai bersama PNB, Harvest, Rotation
    -- Checkpoint task: save() simpan data(), refresh() simpan ulang tiap 2 menit (supaya tidak basi
    -- saat task jalan lama, batas 6 jam), clear() hapus. Error simpan dicatat, task tetap jalan.
    App.resumeErrors = App.resumeErrors or {}
    function Jobs.checkpointer(name, data)
        local last = -math.huge
        local cp = {}
        function cp.save()
            G.State.saveCheckpoint(name, data())
            last = os.clock()
        end
        function cp.refresh()
            if App.pending == 0 and os.clock() - last >= 120 then
                local ok, issue = pcall(cp.save)
                App.resumeErrors[name] = not ok and tostring(issue) or nil
            end
        end
        function cp.clear() G.State.clearCheckpoint(name) end
        return cp
    end

    -- Loop tahan banting (satu aturan untuk semua task):
    --   keluar world / avatar mati  -> kalau setting Rejoin nyala, ulangi loop (loop masuk lagi ke world);
    --                                   kalau mati, task berhenti;
    --   error lain                  -> diulang hanya kalau opts.anyError (Rotation), selain itu berhenti;
    --   gagal opts.maxFailures kali berturut-turut tanpa kemajuan (opts.progress tidak berubah) -> berhenti.
    -- opts = { label, loop(token, resume), world() -> nama world task, progress() -> angka,
    --          anyError, maxFailures (bawaan 3), wait (detik jeda sebelum ulang),
    --          onRetry(problem, left) -> data resume untuk loop berikutnya }
    App.rejoins, App.retries = App.rejoins or {}, App.retries or {}
    function Jobs.resilient(token, resume, opts)
        local failures, mark = 0, nil
        local key = opts.label
        while true do
            local completed, problem = pcall(opts.loop, token, resume)
            if completed then return end
            Net.checkpoint(token)
            problem = Movement.classifyFault(problem, token, opts.world())
            local left = type(problem) == "table" and problem.recoverable
            if left and not App.config.options.autoRejoin then error(problem, 0) end
            if not left and not opts.anyError then error(problem, 0) end
            local now = opts.progress and opts.progress() or 0
            if mark ~= now then failures = 0 end
            failures, mark = failures + 1, now
            local limit = opts.maxFailures or 3
            assert(failures <= limit, opts.label .. " gagal " .. limit .. "x tanpa kemajuan: " .. tostring(problem))
            if left then App.rejoins[key] = (App.rejoins[key] or 0) + 1
            else App.retries[key] = (App.retries[key] or 0) + 1 end
            App.lastRetryError = os.date("%H:%M:%S") .. " " .. opts.label .. ": " .. tostring(problem)
            G.setStatus((left and "Keluar dari world" or "Error") .. " (" .. tostring(problem) .. "). "
                .. opts.label .. " diulang (" .. failures .. "/" .. limit .. ")...")
            resume = opts.onRetry and opts.onRetry(problem, left) or { retry = true }
            if opts.wait then
                Movement.releaseControls()
                Net.pause(opts.wait, token)
                Movement.takeControls()
            end
        end
    end

    -- Samakan posisi toggle On/Off di UI dengan job yang benar-benar jalan.
    function Jobs.syncToggles()
        App.syncingRunToggles = true
        for mode, control in pairs(Jobs.toggles) do
            local enabled = App.alive and App.job == mode and App.jobToken == App.token
            if control.Value ~= enabled then pcall(function() control:Set(enabled, false, false) end) end
        end
        App.syncingRunToggles = false
    end

    function Jobs.start(mode, saved)
        Net.idle()
        local spec = assert(Jobs.specs[mode], "Task tidak dikenal: " .. tostring(mode))
        local r = Bridge.runtime()
        if spec.prepare then spec.prepare(r, saved) end
        Core.checkSetup(App.config, mode, r.items)
        for other, otherSpec in pairs(Jobs.specs) do
            if other ~= mode and otherSpec.clear then pcall(otherSpec.clear) end
        end
        G.State.saveSession()
        local token = Net.beginJob(mode)
        App.teleporting, App.recovering = false, false
        Jobs.syncToggles()
        task.spawn(function()
            local ok, message = xpcall(function()
                Net.checkpoint(token)
                Movement.takeControls()
                spec.run(token, saved)
            end, function(err) return tostring(err) end)
            Movement.releaseControls()
            App.job, App.jobToken, App.recovering = nil, nil, false
            Jobs.syncToggles()
            if not ok and token == App.token and App.alive then
                App.lastError = message
                G.setStatus("Paused: " .. message)
                G.notify(message)
            end
        end)
        return token
    end

    -- Stop: token naik, jadi loop task berhenti di checkpoint berikutnya. Checkpoint semua fitur dihapus.
    function Jobs.stop()
        App.token = App.token + 1
        App.teleporting, App.recovering = false, false
        Jobs.syncToggles()
        Movement.releaseControls()
        for _, spec in pairs(Jobs.specs) do if spec.clear then pcall(spec.clear) end end
        pcall(G.State.saveSession)
        G.setStatus(App.pending > 0 and "Stopped; waiting for a pending server request." or "Stopped.")
    end

    -- Dipanggil toggle UI. On = mulai (kalau belum jalan), Off = stop (kalau task ini yang jalan).
    function Jobs.setRunning(mode, enabled)
        if App.syncingRunToggles then return true end
        local ok, message = pcall(function()
            if enabled then
                if App.job == mode and App.jobToken == App.token then return end
                Jobs.start(mode)
            elseif App.job == mode and App.jobToken == App.token then
                Jobs.stop()
            end
        end)
        Jobs.syncToggles()
        if not ok then G.notify(tostring(message)) end
        return ok, message
    end

    return Jobs
end
