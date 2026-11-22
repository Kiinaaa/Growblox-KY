-- autocollect.lua: Auto Collect yang SELALU menyala saat ada aktivitas.
--   * Saat PNB / Rotation (panen) jalan: blok & gem yang jatuh di sekitar karakter SELALU dipungut,
--     tanpa perlu menyalakan toggle. Kalau toggle "Auto Collect" juga nyala, yang dipungut jadi SEMUA item.
--   * Saat tidak ada task (idle): jalan hanya kalau toggle "Auto Collect" nyala (sama seperti sebelumnya).
-- Berjalan di thread sendiri (tiap frame), paralel dengan task. Aman terhadap task karena:
--   - hanya jalan kalau script sedang memegang karakter (App.controls) dan tidak sedang pindah world;
--   - berhenti seketika kalau task minta (autoCollectHold), token task berubah, atau tas sedang disinkron;
--   - setelah memungut, tas lokal langsung disinkron ke server, jadi hitungan blok milik task tidak basi.
return function(G)
    local App, Core, Bridge, Actions, Drops, task = G.App, G.Core, G.Bridge, G.Actions, G.Drops, G.task
    local AutoCollect = {}
    local position, refreshInventory = Bridge.position, Actions.refreshInventory

    -- Task yang dilayani (PNB, Rotation, panen). Planting dan task lain tidak diganggu (mereka memverifikasi jumlah seed per tile).
    local JOB_MODES = { pnb = true, rotation = true, harvest = true }
    -- Sebelum server pernah menolak pungut, coba jangkauan lebar; setelah itu pakai jangkauan yang dipelajari.
    local PROBE = { radius = 2.75, up = 3, down = 2.5 }

    local attempts, attemptsReset = {}, 0

    local function runtime()
        local ok, r = pcall(Bridge.runtime)
        if ok and type(r) == "table" and r.world and r.inventory then return r end
        return nil
    end

    -- Id yang dipungut selama task: blok yang sedang dikerjakan + gem. Seed sengaja TIDAK ikut:
    -- task menghitung seed per tile (tanam & verifikasi), jadi seed tetap diurus task sendiri.
    local function jobIds(r, job)
        local ids, seen = { Drops.GEM }, { [Drops.GEM] = true }
        local function add(id)
            if type(id) == "number" and id > 0 and not seen[id] then
                seen[id] = true
                table.insert(ids, id)
            end
        end
        local config = App.config
        if job == "pnb" then
            add(config.blockId)
        elseif job == "rotation" or job == "harvest" then
            local seedId = job == "rotation" and config.rotation.seedId or config.harvesting.seedId
            local ok, blockId = pcall(Core.blockForSeed, r.items, seedId)
            if ok then add(blockId) end
        end
        return ids
    end

    function AutoCollect.mode()
        local options = App.config and App.config.options
        if App.job then return JOB_MODES[App.job] and "task" or "off" end
        return (options and options.autoCollect) and "idle" or "off"
    end

    function AutoCollect.tick()
        local options = App.config and App.config.options
        if not (App.alive and options) then return false end
        if App.configuring or App.teleporting or App.recovering or App.autoCollectHold then return false end

        local job = App.job
        local jobMode = job ~= nil and JOB_MODES[job] == true
        if job and not jobMode then return false end
        if not job and not options.autoCollect then return false end

        local r = runtime()
        if not r then return false end

        local hold = App.controls
        if jobMode then
            -- Karakter belum dipegang script (misal sedang masuk world) atau tas sedang disinkron: tunggu.
            if not hold or hold.syncing then return false end
        elseif App.pending > 0 then
            return false
        end

        local okPos, state = pcall(position)
        if not okPos or type(state) ~= "table" then return false end
        if os.clock() > attemptsReset then attempts, attemptsReset = {}, os.clock() + 4 end

        local here = { world = r.world.name, x = math.floor(state.x), y = math.floor(state.y - 0.01) }
        local all = options.autoCollect == true
        local ids, area
        if jobMode then
            ids = all and "all" or jobIds(r, job)
            local base = (App.reach and App.reach.no == 0) and PROBE or Drops.reach()
            local range = all and options.collectRange or 0
            area = { radius = math.max(base.radius, range), up = math.max(base.up, range), down = math.max(base.down, range) }
        else
            ids = "all"
            area = { radius = options.collectRange, up = options.collectRange, down = options.collectRange }
        end

        local wanted
        if ids ~= "all" then
            wanted = {}
            for _, id in ipairs(ids) do wanted[id] = true end
        end

        -- Ada drop yang layak dipungut? Kalau tidak, jangan bikin request apa pun.
        local any = false
        for _, drop in pairs(r.world.dropList()) do
            if not drop.display and not drop.taking and not drop.pending and type(drop.uid) == "number"
                and type(drop.n) == "number" and drop.n > 0 and type(drop.x) == "number" and type(drop.y) == "number"
                and (not wanted or wanted[drop.id]) and (attempts[drop.uid] or 0) < 3
                and math.abs(drop.x - (here.x + 0.5)) <= area.radius
                and drop.y >= here.y - area.up and drop.y <= here.y + area.down
                and (drop.id == Drops.GEM or r.inventory:room(drop.id) > 0) then
                any = true
                break
            end
        end

        if not any then
            -- Mode idle: sinkron tas ke server saat tidak ada drop (maks sekali per detik), bukan tiap tick.
            if not jobMode and App.inventoryDirty and os.clock() - (App.lastInventorySync or 0) >= 1 then
                App.autoCollecting = true
                pcall(refreshInventory, nil)
                App.autoCollecting = false
                App.inventoryDirty, App.lastInventorySync = false, os.clock()
            end
            return false
        end

        local token = App.token
        App.autoCollecting = true
        local ok, got = pcall(Drops.collectNear, here, ids, nil, {
            radius = area.radius, up = area.up, down = area.down, attempts = attempts, fast = true,
            -- Task: ambil hanya yang sudah siap lalu kembali (putaran berikutnya satu frame lagi), dan sinkron tas
            -- langsung supaya hitungan blok milik task tidak tertinggal. Idle: seperti Auto Collect lama.
            noWait = jobMode, deferSync = not jobMode,
            stopIf = function()
                if App.autoCollectHold or not App.alive or App.teleporting or App.recovering then return true end
                if jobMode then
                    local h = App.controls
                    return App.token ~= token or App.job ~= job or not h or h.syncing == true
                end
                return App.job ~= nil
            end,
        })
        App.autoCollecting = false

        if ok then
            local n = 0
            for _, amount in pairs(got or {}) do n = n + amount end
            if n > 0 then
                App.autoCollected = (App.autoCollected or 0) + n
                App.autoCollectInfo = string.format("terakhir +%d item (%s), total %d", n, jobMode and "saat task" or "idle", App.autoCollected)
            end
        else
            App.autoCollectInfo = "error: " .. tostring(got)
        end
        return ok
    end

    -- Loop sendiri; berhenti otomatis kalau script di-unload / dijalankan ulang (App.alive = false).
    task.spawn(function()
        while App.alive do
            task.wait()
            pcall(AutoCollect.tick)
        end
    end)

    return AutoCollect
end
