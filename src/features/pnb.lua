-- pnb.lua: Place & Break dengan grid 5x5 (layout terinspirasi Crusader), stock & seed lewat Display Box,
-- dan Auto Collect.
-- placeTile/breakTile/settleTile diadaptasi dari Clarissv main.lua v0.1.43; bedanya grid bisa
-- sampai 24 tile di sekitar karakter, dan tile yang terisi blok lain dilewati, bukan error.
return function(G)
    local App, Core, Bridge, Net, Actions, Movement, Drops, State, task =
        G.App, G.Core, G.Bridge, G.Net, G.Actions, G.Movement, G.Drops, G.State, G.task
    local Pnb = {}
    local worldCheck, position, checkpoint, pause = Bridge.worldCheck, Bridge.position, Net.checkpoint, Net.pause
    local count, tileAt, refreshInventory = Actions.count, Actions.tileAt, Actions.refreshInventory

    ---------------------------------------------------------------- posisi
    -- Tile berdiri karakter sekarang: x = kolom, y = baris tempat badan (kaki di y + 1).
    function Pnb.standingTile()
        local r, state = Bridge.runtime(), position()
        assert(state.grounded, "Berdiri di lantai dulu, jangan sambil lompat.")
        return { world = r.world.name, x = math.floor(state.x), y = math.floor(state.y - 0.01) }
    end
    -- Tile absolut dari daftar offset, urut atas ke bawah, kiri ke kanan.
    function Pnb.targets(anchor)
        local list = {}
        for _, tile in ipairs(Core.sortPNBTiles(Core.validatePNBTiles(App.config.pnb.tiles))) do
            table.insert(list, { x = anchor.x + tile.dx, y = anchor.y + tile.dy })
        end
        return list
    end
    local function atAnchor(anchor)
        local state = position()
        return state.grounded and math.abs(state.x - (anchor.x + 0.5)) < 0.3 and math.abs(state.y - (anchor.y + 1)) < 0.3
    end
    local function ensureAnchor(anchor, token)
        if not atAnchor(anchor) then Movement.moveTo(anchor.x, anchor.y, anchor.world, token) end
    end
    -- Karakter terdorong/terangkat dari spot (seperti di Clarissv: dipulihkan, bukan stop).
    -- Tunggu sebentar kalau masih di udara, lalu jalan balik ke spot. Terlalu sering = stop.
    local recoveries = {}
    local function holdAnchor(anchor, token)
        if atAnchor(anchor) then return end
        local settle = os.clock() + 0.6
        while os.clock() < settle and not atAnchor(anchor) do pause(0.05, token) end
        if atAnchor(anchor) then return end
        local now = os.clock()
        table.insert(recoveries, now)
        while recoveries[1] and now - recoveries[1] > 60 do table.remove(recoveries, 1) end
        assert(#recoveries <= 10, "Karakter terus bergeser dari posisi PNB (10x dalam 1 menit). Cek apa yang mendorong karakter.")
        App.pnbRecoveries = (App.pnbRecoveries or 0) + 1
        G.setStatus("Karakter bergeser; kembali ke posisi PNB...")
        local hold = Movement.takeControls()
        hold.direction, hold.jump = 0, false
        Movement.moveTo(anchor.x, anchor.y, anchor.world, token)
    end

    ---------------------------------------------------------------- place & break
    local function settleTile(x, y, id, seconds, worldName, token)
        local deadline = os.clock() + seconds
        repeat
            worldCheck(worldName, token)
            assert(tileAt(x, y) == id, "Tile " .. x .. ", " .. y .. " changed while the action settled. Stopping.")
            pause(0.03, token)
        until os.clock() >= deadline
    end

    -- Taruh satu blok, lalu tunggu server benar-benar mengurangi blok di tas.
    local function placeTile(anchor, point, id, token)
        return Movement.withoutPickups(function()
            local r = worldCheck(anchor.world, token)
            holdAnchor(anchor, token)
            -- TURBO: tanpa sinkron tas ke server per tile (itu 2 round trip per place). Pakai hitungan
            -- tas lokal; sinkron + cek hasilnya SEKALI per putaran di Pnb.run.
            if tileAt(point.x, point.y) ~= 0 then return false end
            assert(r.handlers.canPlace(r.items[id], point.x, point.y),
                "Cannot place at " .. point.x .. ", " .. point.y .. ". Check reach, access, and empty tiles.")
            assert(count(id) > 0, "No blocks are left in your backpack.")
            r.handlers.setTile("fg", point.x, point.y, id, false, (position().facing or 1) < 0)
            App.lastPlacement = { x = point.x, y = point.y, world = anchor.world, grid = r.world.fg, at = os.clock() }
            r.inventory:remove(id, 1)
            pause(App.config.options.placeDelay, token)
            if App.config.options.placeDelay > 0.002 then
                settleTile(point.x, point.y, id, math.min(0.12, App.config.options.placeDelay), anchor.world, token)
            end
            return true
        end)
    end

    -- Pukul sampai pecah. Jeda antar pukulan = Hit delay (punchDelay).
    local function breakTile(anchor, point, id, token)
        local r = worldCheck(anchor.world, token)
        assert(tileAt(point.x, point.y) == id, "The target tile changed. Stopping before punching another block.")
        local deadline = os.clock() + App.config.options.actionTimeout + (r.items[id].hits or 1) * App.config.options.punchDelay
        local placed = App.lastPlacement
        if placed and placed.world == anchor.world and placed.grid == r.world.fg and placed.x == point.x and placed.y == point.y then
            -- blok baru ditaruh butuh waktu sebelum bisa dipukul; ikut Place delay + Hit delay (maks 0,32 detik)
            local grace = math.min(0.32, App.config.options.placeDelay + App.config.options.punchDelay)
            local remaining = grace - (os.clock() - placed.at)
            if remaining > 0 then pause(remaining, token) end
        end
        while tileAt(point.x, point.y) == id do
            worldCheck(anchor.world, token)
            if not atAnchor(anchor) then
                holdAnchor(anchor, token)
                deadline = os.clock() + App.config.options.actionTimeout -- waktu jalan balik tidak dihitung
            end
            assert(os.clock() < deadline, "Block did not break. Check permissions and your punching range.")
            -- TURBO: beberapa pukulan sekaligus per frame (sebanyak hit yang dibutuhkan blok, maks 8).
            for _ = 1, math.max(1, math.min(r.items[id].hits or 1, 8)) do
                if tileAt(point.x, point.y) ~= id then break end
                r.handlers.hit(point.x, point.y)
            end
            if App.config.options.punchDelay <= 0.002 then Net.tick(token)
            else pause(App.config.options.punchDelay, token) end
        end
        assert(tileAt(point.x, point.y) == 0, "The block changed while breaking.")
        settleTile(point.x, point.y, 0, App.config.options.punchDelay, anchor.world, token)
        App.stats.broken = App.stats.broken + 1
    end

    Pnb.placeTile, Pnb.breakTile = placeTile, breakTile

    -- TURBO: pecahkan SEMUA tile terpilih bersamaan. Tiap frame semua tile yang tersisa dipukul
    -- (beberapa pukulan per tile), lalu satu yield. 24 tile = jumlah frame sama dengan 1 tile.
    local function breakAll(anchor, targets, id, token)
        local r = worldCheck(anchor.world, token)
        local opts = App.config.options
        local hits = r.items[id].hits or 1
        local burst = math.max(1, math.min(hits, 8))
        local placed = App.lastPlacement
        if placed and placed.world == anchor.world and placed.grid == r.world.fg then
            local remaining = math.min(0.32, opts.placeDelay + opts.punchDelay) - (os.clock() - placed.at)
            if remaining > 0 then pause(remaining, token) end
        end
        local deadline = os.clock() + opts.actionTimeout + hits * opts.punchDelay
        local left = {}
        for _, point in ipairs(targets) do
            if tileAt(point.x, point.y) == id then table.insert(left, point) end
        end
        while #left > 0 do
            worldCheck(anchor.world, token)
            if not atAnchor(anchor) then
                holdAnchor(anchor, token)
                deadline = os.clock() + opts.actionTimeout -- waktu jalan balik tidak dihitung
            end
            assert(os.clock() < deadline, "Block did not break. Check permissions and your punching range.")
            local still = {}
            for _, point in ipairs(left) do
                local now = tileAt(point.x, point.y)
                assert(now == id or now == 0, "The block changed while breaking.")
                if now == id then
                    for _ = 1, burst do
                        if tileAt(point.x, point.y) ~= id then break end
                        r.handlers.hit(point.x, point.y)
                    end
                end
                if tileAt(point.x, point.y) == 0 then App.stats.broken = App.stats.broken + 1
                else table.insert(still, point) end
            end
            left = still
            if #left > 0 then
                if opts.punchDelay <= 0.002 then Net.tick(token) else pause(opts.punchDelay, token) end
            end
        end
    end

    -- v0.9.5: DUA delay terpisah. Place delay (placeDelay) = jeda sebelum place ulang di tile kosong.
    -- Break delay (punchDelay) = jeda antar pukulan DAN tunggu setelah place sebelum dipukul (tanpa batas bawah paksa).
    -- Boost otomatis (opsional, toggle "Auto naikkan delay kalau miss") mengalikan keduanya; kalau mati, delay dipakai apa adanya.
    App.delayBoost = App.delayBoost or 1
    local function boost()
        return (App.config.options.autoBoost and App.delayBoost) or 1
    end
    local function placeGapOf(opts) return math.max(0.001, opts.placeDelay or 0.1) * boost() end
    local function breakGapOf(opts) return math.max(0.001, opts.punchDelay or 0.03) * boost() end
    Pnb.placeGap, Pnb.breakGap = placeGapOf, breakGapOf
    function Pnb.safeDelay(opts) return math.max(placeGapOf(opts), breakGapOf(opts)) end
    -- Boost: maks 1.6x, naik 1.15x per miss, turun 10% per putaran bersih (hanya berpengaruh kalau autoBoost nyala).
    local function raiseBoost()
        App.delayBoost = math.min(1.6, App.delayBoost * 1.15)
        App.delayMisses = (App.delayMisses or 0) + 1
    end
    local function easeBoost() App.delayBoost = math.max(1, App.delayBoost * 0.9) end

    -- v0.9: seed yang masih tergeletak (belum terpungut). Tile yang ada seed-nya TIDAK di-place / dipukul dulu.
    function Pnb.seedDrops(r, seedId)
        local list = {}
        if not seedId then return list end
        for _, drop in pairs(r.world.dropList()) do
            if type(drop) == "table" and drop.id == seedId and not drop.display and type(drop.n) == "number" and drop.n > 0
                and type(drop.x) == "number" and type(drop.y) == "number" then
                table.insert(list, drop)
            end
        end
        return list
    end
    function Pnb.seedOnTile(list, x, y)
        for _, drop in ipairs(list) do
            if math.abs(drop.x - (x + 0.5)) <= 0.75 and drop.y >= y - 0.4 and drop.y <= y + 1.4 then return true end
        end
        return false
    end
    -- Ada seed belum terpungut di salah satu tile PNB?
    function Pnb.seedBlocks(r, tiles, seedId)
        if not seedId then return false end
        local list = Pnb.seedDrops(r, seedId)
        if #list == 0 then return false end
        for _, tile in ipairs(tiles) do
            if Pnb.seedOnTile(list, tile.x, tile.y) then return true end
        end
        return false
    end

    -- PIPELINE: tiap frame, tiap tile diperlakukan sendiri: kosong -> place, ada blok -> pukul (semua hit sekaligus).
    -- v0.9.5:
    --   * Delay Place & Delay Break TERPISAH (opts.placeDelay / opts.punchDelay). Tidak ada lagi batas bawah 0,12 dtk
    --     setelah place; tunggu sebelum pukul pertama = Delay Break; jeda antar putaran = 1 frame (bukan 0,05 dtk).
    --   * PUNGUT drop jalan di thread sendiri (tidak menahan loop place/break menunggu balasan server tiap pickup).
    --   * Blok LAIN yang menghalangi tile PNB (blok biasa yang bisa dihancurkan, bukan seed/lock/pintu/box) langsung
    --     DIHANCURKAN. Tile tepat di bawah karakter (lantai berdiri) tidak pernah disentuh.
    --   * speed (opsional) = tabel: placeDelay, punchDelay, actionTimeout, collectEvery.
    --   * avoidSeed (opsional) = id seed: tile yang ada seed-nya belum terpungut dilewati sampai seed itu terpungut.
    function Pnb.pipeline(anchor, targets, id, token, speed, avoidSeed, collectIds)
        local r = worldCheck(anchor.world, token)
        local opts = speed or App.config.options
        local timeout = opts.actionTimeout or App.config.options.actionTimeout or 10
        local hitsNeeded = r.items[id].hits or 1
        local burst = math.max(1, math.min(hitsNeeded, 8))
        local stallRounds = math.ceil(hitsNeeded / burst) + 6 -- pukulan sebanyak ini tanpa pecah = miss
        local roundStart, lastProgress = os.clock(), os.clock()
        local phase, placedAt, hitAt, emptyAt, bursts = {}, {}, {}, {}, {}
        local rejected, stalled = 0, 0
        local pipeAttempts = {}
        local seedCache, seedCacheAt = nil, nil
        -- pungut di thread sendiri
        local collecting, collectedAny, collectProblem, collectAt = false, false, nil, 0
        local function drain()
            local deadline = os.clock() + (App.config.options.actionTimeout or 10) + 2
            while collecting and os.clock() < deadline do Net.tick(token) end
        end
        local function startCollect()
            collecting = true
            local probing = App.reach.no == 0
            local area = probing and { radius = 2.75, up = 3, down = 2.5 } or Drops.reach()
            task.spawn(function()
                local ok, got = pcall(Drops.collectNear, anchor, collectIds, token, { radius = area.radius, up = area.up,
                    down = area.down, fast = true, noWait = true, attempts = pipeAttempts, maxAttempts = probing and 1 or 2 })
                collecting = false
                if ok then
                    for _, amount in pairs(got or {}) do
                        if amount > 0 then collectedAny = true; App.pnbCollected = (App.pnbCollected or 0) + amount end
                    end
                elseif not tostring(got):find("Stopped", 1, true) then
                    collectProblem = got
                end
            end)
        end
        -- blok lain di tile PNB yang boleh dihancurkan (nil = tidak boleh)
        local function obstacleItem(now, point)
            if now == 0 or now == id or now == avoidSeed then return nil end
            if point.x == anchor.x and point.y == anchor.y + 1 then return nil end -- lantai tempat berdiri
            local item = r.items[now]
            if Core.farmable(item) then return item end
            return nil
        end
        local function finish()
            drain()
            -- blok yang pecah tepat di akhir putaran ikut dihitung (kalau tidak, hilang dari statistik)
            for index, point in ipairs(targets) do
                if phase[index] == "block" and tileAt(point.x, point.y) == 0 then
                    App.stats.broken = App.stats.broken + 1
                    phase[index] = nil
                end
            end
            if rejected > 0 then
                App.pnbRejected = (App.pnbRejected or 0) + rejected
                pcall(refreshInventory, token) -- hitungan blok lokal disamakan dengan server
            end
            if rejected > 0 or stalled > 0 then raiseBoost() else easeBoost() end
        end
        while true do
            checkpoint(token)
            worldCheck(anchor.world, token)
            if collectProblem then
                local problem = collectProblem
                collectProblem = nil
                drain()
                error(problem, 0)
            end
            local state = position()
            if not (state.grounded and math.abs(state.x - (anchor.x + 0.5)) < 0.3 and math.abs(state.y - (anchor.y + 1)) < 0.3) then
                holdAnchor(anchor, token)
                lastProgress = os.clock()
                state = position()
            end
            local facing = (state.facing or 1) < 0
            -- dibaca ulang tiap putaran: slider Delay Place / Delay Break langsung berlaku tanpa stop.
            opts = speed or App.config.options
            local placeGap, hitGap = placeGapOf(opts), breakGapOf(opts)
            local grace = hitGap -- tunggu setelah place sebelum pukul pertama = Delay Break
            local pendingTimeout = 0.5 + placeGap -- balasan server untuk banyak place sekaligus bisa lambat; jangan dianggap ditolak
            local collectEvery = opts.collectEvery or 2.5
            local stagger = math.min(0.02, placeGap / 3)
            -- daftar seed di lantai dibaca ulang tiap 0,1 dtk saja (bukan tiap frame)
            local seeds
            if avoidSeed then
                if not seedCacheAt or os.clock() - seedCacheAt >= 0.1 then
                    seedCache, seedCacheAt = Pnb.seedDrops(r, avoidSeed), os.clock()
                end
                seeds = seedCache
                if seeds and #seeds == 0 then seeds = nil end
            end
            local usable, active, progressed, waiting, avoided = false, false, false, false, false
            local t = os.clock()
            for index, point in ipairs(targets) do
                local now = tileAt(point.x, point.y)
                local blocked = seeds ~= nil and Pnb.seedOnTile(seeds, point.x, point.y)
                if now == 0 then
                    usable = true
                    local ph = phase[index]
                    if ph == "block" then -- blok yang tadi dipukul sudah pecah
                        phase[index], placedAt[index], hitAt[index], emptyAt[index], bursts[index] = nil, nil, nil, t, nil
                        App.stats.broken = App.stats.broken + 1
                        progressed, ph = true, nil
                    elseif ph == "obstacle" then -- penghalang sudah hancur
                        phase[index], hitAt[index], bursts[index], emptyAt[index] = nil, nil, nil, t
                        App.pnbObstacles = (App.pnbObstacles or 0) + 1
                        progressed, ph = true, nil
                    elseif ph == "placed" and t - placedAt[index] >= pendingTimeout then -- place tidak pernah muncul
                        phase[index], placedAt[index], emptyAt[index] = nil, nil, t
                        rejected, ph = rejected + 1, nil
                    end
                    if ph == "placed" then
                        active, waiting = true, true -- server belum memproses place; jangan place dua kali
                    elseif blocked then
                        avoided, emptyAt[index] = true, nil -- ada seed di tile ini: jangan put di sini
                    else
                        emptyAt[index] = emptyAt[index] or t
                        if count(id) > 0 and t - emptyAt[index] >= placeGap then
                            if r.handlers.canPlace(r.items[id], point.x, point.y) then
                                r.handlers.setTile("fg", point.x, point.y, id, false, facing)
                                r.inventory:remove(id, 1)
                                phase[index], placedAt[index], hitAt[index], emptyAt[index], bursts[index] = "placed", os.clock(), nil, nil, nil
                                active, progressed, waiting = true, true, true
                                pause(stagger, token); t = os.clock() -- selang kecil antar place supaya server tidak kebanjiran
                            else
                                App.pnbCantPlace = (App.pnbCantPlace or 0) + 1
                            end
                        end
                    end
                elseif now == id then
                    usable = true
                    if blocked then
                        avoided = true -- ada seed di tile ini: jangan break di sini
                    else
                        active = true
                        phase[index], emptyAt[index] = "block", nil
                        if t - (placedAt[index] or 0) >= grace and t - (hitAt[index] or 0) >= hitGap then
                            hitAt[index] = t
                            bursts[index] = (bursts[index] or 0) + 1
                            if bursts[index] == stallRounds then stalled = stalled + 1 end -- pukulan tidak memecahkan blok: miss
                            for _ = 1, burst do
                                if tileAt(point.x, point.y) ~= id then break end
                                r.handlers.hit(point.x, point.y)
                            end
                        end
                    end
                else
                    -- blok lain menghalangi tile ini: hancurkan saja
                    local item = (not blocked) and obstacleItem(now, point) or nil
                    if item then
                        usable, active = true, true
                        phase[index], emptyAt[index] = "obstacle", nil
                        if t - (hitAt[index] or 0) >= hitGap then
                            hitAt[index] = t
                            for _ = 1, math.max(1, math.min(item.hits or 1, 8)) do
                                if tileAt(point.x, point.y) ~= now then break end
                                r.handlers.hit(point.x, point.y)
                            end
                        end
                    end
                end
            end
            -- PUNGUT di thread sendiri (tiap 0,1 dtk, tidak menumpuk): loop place/break tidak menunggu balasan server.
            if collectIds and not collecting and os.clock() - collectAt >= 0.1 then
                collectAt = os.clock()
                startCollect()
            end
            if collectedAny then collectedAny, progressed = false, true end
            assert(usable, "Semua tile PNB terhalang blok yang tidak bisa dihancurkan. Kosongkan tile yang dipilih atau pilih tile lain.")
            if progressed then lastProgress = os.clock() end
            -- tidak ada kerjaan lagi (blok habis, atau sisa tile tertahan seed): kembali supaya pemanggil memungut dulu
            if not active and (count(id) == 0 or avoided) then finish(); return end
            if os.clock() - roundStart >= collectEvery and not waiting then finish(); return end
            assert(os.clock() - lastProgress < timeout,
                "Place & Break macet: tidak ada kemajuan. Cek izin dan jangkauan pukul.")
            Net.tick(token) -- satu frame (bukan jeda tetap 0,05 dtk)
        end
    end

    ---------------------------------------------------------------- stock & seed
    -- Ambil stock dari Display Box (sama seperti PNB Clarissv: "Refilling blocks from the right
    -- storage box", world.call("DisplayItem", x, y, nil)). Box berisi blok yang di-PNB saja.
    -- Return: jumlah blok yang diambil (0 = box kosong).
    function Pnb.takeStock(anchor, blockId, token)
        local box = App.config.points.stock
        G.setStatus("Mengambil stock blok dari Display Box...")
        local taken = G.Storage.withdraw(box, blockId, token)
        App.stockDebug = os.date("%H:%M:%S") .. " +" .. taken .. " blok dari box " .. box.x .. ", " .. box.y
        ensureAnchor(anchor, token)
        return taken
    end

    -- Auto drop seed = taruh seed ke Display Box (sama seperti PNB Clarissv: "Putting seeds into
    -- the left storage box", world.call("DisplayItem", ...)). Drop ke lantai tidak dipakai karena
    -- belum ada perintah server yang diketahui untuk itu.
    function Pnb.dropSeeds(anchor, seedId, token)
        local box = App.config.points.seedDrop
        G.setStatus("Menaruh seed ke Display Box...")
        G.Storage.deposit(box, seedId, count(seedId), token)
        refreshInventory(token)
        ensureAnchor(anchor, token)
    end

    -- Pungut hasil PNB: semua blok/seed/gem (atau semua item kalau Auto Collect nyala) di area
    -- grid 5x5. Tile di pinggir grid (2 tile dari karakter) di luar jangkauan server, jadi
    -- karakter melangkah ke sana, memungut, lalu kembali ke posisi PNB.
    local GRID_AREA = { radius = 2.75, up = 3, down = 2.5 }
    -- id yang dipungut: semua item kalau Auto Collect nyala, kalau tidak cuma blok/seed/gem.
    function Pnb.collectIds(pickupIds)
        return App.config.options.autoCollect and "all" or pickupIds
    end
    function Pnb.collect(anchor, pickupIds, token, noWait)
        local ids, area = pickupIds, GRID_AREA
        if App.config.options.autoCollect then
            local range = App.config.options.collectRange
            ids = "all"
            area = { radius = math.max(GRID_AREA.radius, range), up = math.max(GRID_AREA.up, range),
                down = math.max(GRID_AREA.down, range) }
        end
        local got = Drops.collectArea(anchor, ids, token, area, { fast = true, noWait = noWait })
        local n = 0
        for _, amount in pairs(got) do n = n + amount end
        App.pnbCollected = (App.pnbCollected or 0) + n
        ensureAnchor(anchor, token)
    end

    ---------------------------------------------------------------- Auto Collect
    -- Auto Collect (idle + selama PNB/Rotation) sekarang ada di features/autocollect.lua (G.AutoCollect).
    -- Di sini tinggal Pnb.collect / Pnb.collectIds untuk pungut hasil PNB di akhir putaran.

    ---------------------------------------------------------------- rejoin & resume
    -- Adaptasi Clarissv v0.1.43: savePNBResume, refreshPNBCheckpoint, classifyPNBFault, recoverPNB.
    -- Setting "Rejoin world and return to PNB" (options.autoRejoin): kalau terlempar ke world picker,
    -- avatar mati/respawn, atau pindah server, masuk lagi ke world PNB lalu jalan balik ke spot.
    local resumePoint = G.Jobs.checkpointer("pnb", function() return { anchor = App.config.points.pnb } end)
    Pnb.saveResume, Pnb.clearResume = resumePoint.save, resumePoint.clear

    -- Masuk lagi ke world PNB (lewat world picker, bisa pindah server) lalu jalan ke spot.
    function Pnb.returnToSpot(token)
        local anchor = App.config.points.pnb
        App.recovering = true
        G.setStatus("Masuk lagi ke " .. anchor.world .. "...")
        Movement.enterWorld(anchor.world, token, { save = Pnb.saveResume, label = "Place & Break",
            resumeButton = "Place & Break" })
        Movement.takeControls()
        refreshInventory(token)
        G.setStatus("Jalan balik ke spot PNB...")
        Movement.moveTo(anchor.x, anchor.y, anchor.world, token)
        App.recovering = false
        G.setStatus("Sudah di spot PNB. Lanjut Place & Break...")
    end

    ---------------------------------------------------------------- loop utama
    function Pnb.run(token)
        local r = Bridge.runtime()
        local anchor, blockId = App.config.points.pnb, App.config.blockId
        local okSeed, seedId = pcall(Core.seedId, r.items, blockId)
        if not okSeed then seedId = nil end
        local pickupIds = { blockId, Drops.GEM }
        if seedId then table.insert(pickupIds, seedId) end
        worldCheck(anchor.world, token)
        ensureAnchor(anchor, token)
        if App.config.options.autoRejoin then Pnb.saveResume(); Movement.queueResume() end
        G.setStatus("PNB mulai di " .. anchor.world .. " (" .. anchor.x .. ", " .. anchor.y .. "), " .. #App.config.pnb.tiles .. " tile.")
        local idleRounds = 0
        while true do
            checkpoint(token)
            worldCheck(anchor.world, token)
            resumePoint.refresh()
            holdAnchor(anchor, token)
            if seedId and App.config.pnb.autoDrop and count(seedId) >= App.config.options.seedThreshold then
                Pnb.dropSeeds(anchor, seedId, token)
            end
            local targets, existing = Pnb.targets(anchor), false
            for _, point in ipairs(targets) do if tileAt(point.x, point.y) == blockId then existing = true end end
            if count(blockId) == 0 and not existing then
                Pnb.collect(anchor, pickupIds, token)
                -- Auto Collect jalan paralel: samakan tas lokal dengan server sebelum menyimpulkan blok habis.
                if count(blockId) == 0 then refreshInventory(token) end
                if count(blockId) == 0 then
                    if App.config.pnb.autoStock then Pnb.takeStock(anchor, blockId, token) end
                    if not (App.config.pnb.autoStock and (refreshInventory(token)[blockId] or 0) > 0) then
                        G.setStatus(App.config.pnb.autoStock and "Selesai: Display Box stock kosong."
                            or "Selesai: blok di tas habis. Nyalakan Auto take stock untuk ambil dari Display Box.")
                        return
                    end
                end
            end
            -- Status di putaran panas cuma isi variabel (tanpa log/print/UI) supaya tidak menghambat gerakan.
            App.status = "Place & Break: " .. r.items[blockId].name
            local brokenBefore = App.stats.broken
            -- v0.9: tile yang masih ada seed belum terpungut dilewati (tidak put/break di situ).
            Pnb.pipeline(anchor, targets, blockId, token, nil, seedId, Pnb.collectIds(pickupIds))
            App.status = "Place & Break: collecting"
            -- Masih punya blok & tidak ada seed yang menahan tile = jangan menunggu drop yang belum siap (langsung lanjut PNB).
            local seedHold = Pnb.seedBlocks(r, targets, seedId)
            Pnb.collect(anchor, pickupIds, token, count(blockId) > 0 and not seedHold)
            if seedHold and App.stats.broken == brokenBefore then
                idleRounds = idleRounds + 1
                assert(idleRounds < 8, "Ada seed di area PNB yang tidak bisa dipungut, jadi put/break berhenti. Pungut manual lalu nyalakan lagi.")
            else
                idleRounds = 0
            end
        end
    end

    G.Jobs.register("pnb", {
        label = "Place & Break",
        prepare = function(r, saved)
            assert(r.body and r.controls and r.handlers.setTile and r.handlers.hit and r.handlers.canPlace,
                "Hook place/break tidak tersedia. Copy diagnostics dari Settings.")
            -- Posisi PNB = tempat karakter berdiri saat toggle dinyalakan (seperti Crusader).
            -- Resume setelah pindah server: pakai spot dari checkpoint.
            if saved and saved.anchor then App.config.points.pnb = saved.anchor
            else App.config.points.pnb = Pnb.standingTile() end
        end,
        -- Sama seperti Clarissv: keluar world / avatar mati + setting Rejoin nyala = masuk lagi ke
        -- world, balik ke spot, lanjut PNB (Jobs.resilient). Gagal 3x tanpa kemajuan = berhenti.
        run = function(token, saved)
            G.Jobs.resilient(token, saved, {
                label = "Place & Break",
                world = function() return App.config.points.pnb.world end,
                progress = function() return App.stats.broken end,
                loop = function(loopToken, resume)
                    local anchor, r = App.config.points.pnb, Bridge.runtime()
                    if resume and (r.world.name ~= anchor.world or Bridge.pickerOpen(r) or resume.retry) then
                        Pnb.returnToSpot(loopToken)
                    end
                    Pnb.run(loopToken)
                end,
            })
            Pnb.clearResume()
        end,
        clear = function() Pnb.clearResume() end,
        resume = true, -- lanjut otomatis setelah pindah server
        validResume = function(data) return type(data.anchor) == "table" end,
    })

    ---------------------------------------------------------------- tab Place & Break
    local function tileSet(list)
        local set = {}
        for _, tile in ipairs(list or App.config.pnb.tiles) do set[tile.dx .. ":" .. tile.dy] = true end
        return set
    end
    -- Peta teks 5x5 untuk paragraf: [Y] = karakter, [#] = dipilih, [ ] = kosong.
    function Pnb.gridText(list)
        local set, lines = tileSet(list), {}
        for dy = -2, 2 do
            local row = {}
            for dx = -2, 2 do
                row[#row + 1] = (dx == 0 and dy == 0) and "[Y]" or (set[dx .. ":" .. dy] and "[#]" or "[  ]")
            end
            lines[#lines + 1] = table.concat(row, " ")
        end
        return table.concat(lines, "\n")
    end
    function Pnb.toggleTile(dx, dy)
        Net.idle()
        if dx == 0 and dy == 0 then return end
        local tiles, removed = {}, false
        for _, tile in ipairs(App.config.pnb.tiles) do
            if tile.dx == dx and tile.dy == dy then removed = true else table.insert(tiles, tile) end
        end
        if not removed then table.insert(tiles, { dx = dx, dy = dy }) end
        App.config.pnb.tiles = Core.validatePNBTiles(tiles)
        State.saveSession()
        if Pnb.refreshTab then Pnb.refreshTab() end
    end

    -- Panel 5x5 melayang (Roblox GUI). Klik kotak = pilih/batal pilih tile; kotak tengah = karakter.
    -- spec (opsional): { key, title, get() -> daftar tile, toggle(dx, dy) }. Tanpa spec = tile PNB biasa.
    Pnb.panels = {}
    function Pnb.openGridPanel(spec)
        spec = spec or { key = "pnb", title = "PNB tiles - klik untuk pilih", get = function() return App.config.pnb.tiles end, toggle = Pnb.toggleTile }
        local existing = Pnb.panels[spec.key]
        if existing and existing.Parent then existing:Destroy(); Pnb.panels[spec.key] = nil; return end
        local new = G.newInstance
        local gui = new("ScreenGui")
        gui.Name, gui.ResetOnSpawn = "GrowbloxHansel_" .. spec.key .. "_Tiles", false
        local frame = new("Frame")
        frame.Size, frame.Position = G.UDim2.fromOffset(250, 300), G.UDim2.new(0.5, -125, 0.5, -150)
        frame.BackgroundColor3, frame.BorderSizePixel, frame.Active = G.Color3.fromRGB(30, 30, 36), 0, true
        frame.Parent = gui
        local title = new("TextLabel")
        title.Size, title.Position, title.BackgroundTransparency = G.UDim2.fromOffset(250, 30), G.UDim2.fromOffset(0, 0), 1
        title.Text, title.TextColor3, title.TextSize = spec.title, G.Color3.fromRGB(235, 235, 235), 14
        title.Parent = frame
        local buttons = {}
        local function paint()
            local set = tileSet(spec.get())
            for key, button in pairs(buttons) do
                local selected = set[key]
                button.BackgroundColor3 = selected and G.Color3.fromRGB(70, 160, 90) or G.Color3.fromRGB(60, 60, 70)
                button.Text = selected and "#" or ""
            end
        end
        for dy = -2, 2 do
            for dx = -2, 2 do
                local button = new("TextButton")
                button.Size = G.UDim2.fromOffset(42, 42)
                button.Position = G.UDim2.fromOffset(15 + (dx + 2) * 45, 38 + (dy + 2) * 45)
                button.BorderSizePixel, button.TextColor3, button.TextSize = 0, G.Color3.fromRGB(255, 255, 255), 16
                button.Parent = frame
                if dx == 0 and dy == 0 then
                    button.Text, button.BackgroundColor3, button.AutoButtonColor = "You", G.Color3.fromRGB(70, 110, 190), false
                else
                    buttons[dx .. ":" .. dy] = button
                    button.MouseButton1Click:Connect(function()
                        local ok, message = pcall(spec.toggle, dx, dy)
                        if not ok then G.notify(tostring(message)) end
                        paint()
                    end)
                end
            end
        end
        local close = new("TextButton")
        close.Size, close.Position = G.UDim2.fromOffset(220, 30), G.UDim2.fromOffset(15, 262)
        close.Text, close.BackgroundColor3, close.TextColor3 = "Tutup", G.Color3.fromRGB(90, 50, 50), G.Color3.fromRGB(255, 255, 255)
        close.BorderSizePixel, close.Parent = 0, frame
        close.MouseButton1Click:Connect(function() gui:Destroy(); Pnb.panels[spec.key] = nil end)
        paint()
        gui.Parent = G.guiParent()
        Pnb.panels[spec.key] = gui
    end

    -- v0.9.5: slider Delay Place & Delay Break (terpisah). Dipakai di tab Place & Break DAN tab Rotation;
    -- semua slider yang tampil disinkronkan, dan langsung berlaku saat task jalan (pipeline membaca ulang tiap frame).
    Pnb.delayControls, Pnb.delaySyncing = {}, false
    function Pnb.syncDelaySliders()
        Pnb.delaySyncing = true
        for _, entry in ipairs(Pnb.delayControls) do
            local want = App.config.options[entry.key]
            if entry.shown ~= want then
                entry.shown = want
                pcall(function() entry.slider:Set(want) end)
            end
        end
        Pnb.delaySyncing = false
    end
    function Pnb.addDelaySliders(tab)
        local specs = {
            { key = "placeDelay", title = "Delay Place (detik)", step = 0.005, setter = Core.setPlaceDelay,
                desc = "Jeda sebelum blok ditaruh lagi di tile yang baru kosong. Langsung berlaku saat jalan." },
            { key = "punchDelay", title = "Delay Break (detik)", step = 0.001, setter = Core.setBreakDelay,
                desc = "Jeda antar pukulan, dan tunggu setelah place sebelum dipukul. Makin kecil makin cepat. Kalau ada blok yang tidak pecah / miss, naikkan sedikit. Berlaku untuk Place & Break dan PNB di Rotation. Langsung berlaku saat jalan." },
        }
        for _, spec in ipairs(specs) do
            local limit = Core.LIMITS[spec.key]
            local entry = { key = spec.key, shown = App.config.options[spec.key] }
            entry.slider = tab:Slider({ Title = spec.title, Step = spec.step, Desc = spec.desc,
                Value = { Min = limit[1], Max = limit[2], Default = App.config.options[spec.key] },
                Callback = function(value)
                    if Pnb.delaySyncing then return end
                    local ok, message = pcall(function() spec.setter(App.config, tonumber(value)); State.saveSession() end)
                    if not ok then G.notify(tostring(message)) end
                    entry.shown = App.config.options[spec.key]
                    Pnb.syncDelaySliders()
                end })
            table.insert(Pnb.delayControls, entry)
        end
    end

    function Pnb.buildTab(tab)
        local UI = G.UI
        local controls, blockLookup, syncing = {}, {}, true

        local function refreshBlocks()
            if not App.runtime then return end
            local labels, selected = {}, nil
            blockLookup = {}
            for _, block in ipairs(Actions.farmableBlocks()) do
                local label = block.name .. " [" .. block.id .. "] x" .. count(block.id)
                table.insert(labels, label)
                blockLookup[label] = block.id
                if block.id == App.config.blockId then selected = label end
            end
            syncing = true
            pcall(function() controls.block:Refresh(labels) end)
            if selected then pcall(function() controls.block:Select(selected) end) end
            syncing = false
        end
        function Pnb.refreshTab()
            UI.paragraph(controls.grid, "PNB tiles", Pnb.gridText())
            UI.paragraph(controls.stock, "Stock (Display Box)", G.Storage.pointText(App.config.points.stock))
            UI.paragraph(controls.drop, "Seed drop (Display Box)", G.Storage.pointText(App.config.points.seedDrop))
            Pnb.syncDelaySliders()
        end
        local function setOption(fn)
            if syncing then return end
            local ok, message = pcall(function() Net.idle(); fn(); State.saveSession() end)
            if not ok then G.notify(tostring(message)) end
        end
        -- Slider delay: langsung berlaku saat PNB jalan (pipeline membaca ulang tiap putaran), tanpa Net.idle.
        local function liveOption(fn)
            if syncing then return end
            local ok, message = pcall(function() fn(); State.saveSession() end)
            if not ok then G.notify(tostring(message)) end
        end

        UI.addStatus(tab:Paragraph({ Title = "Status", Desc = App.status }))
        controls.block = tab:Dropdown({ Title = "Block in your backpack", Values = {}, SearchBarEnabled = true,
            Callback = function(value)
                if type(value) == "table" then value = value[1] end
                setOption(function() App.config.blockId = assert(blockLookup[value], "Pilih blok.") end)
            end })
        tab:Button({ Title = "Refresh block", Callback = UI.action(refreshBlocks) })
        G.Jobs.toggles.pnb = tab:Toggle({ Title = "Place & Break", Value = false,
            Desc = "Posisi PNB = tempat lo berdiri saat toggle dinyalakan.",
            Callback = function(enabled) G.Jobs.setRunning("pnb", enabled) end })
        Pnb.addDelaySliders(tab)
        controls.autoBoost = tab:Toggle({ Title = "Auto naikkan delay kalau miss", Value = App.config.options.autoBoost == true,
            Desc = "MATI (bawaan) = Delay Place & Delay Break dipakai apa adanya. NYALA = kalau script mendeteksi place/pukul yang miss, delay efektif naik sendiri (maks 1.6x) lalu turun lagi. Langsung berlaku.",
            Callback = function(enabled) liveOption(function() App.config.options.autoBoost = enabled == true end) end })

        pcall(function() tab:Section({ Title = "Auto Collect" }) end)
        controls.autoCollect = tab:Toggle({ Title = "Auto Collect", Value = App.config.options.autoCollect,
            Desc = "Saat PNB/Rotation jalan, blok & gem yang jatuh SELALU dipungut otomatis (tidak perlu toggle ini). Toggle ini menambah: pungut SEMUA item (seed, dll.) dan juga jalan saat idle.",
            Callback = function(enabled) setOption(function() App.config.options.autoCollect = enabled == true end) end })
        tab:Slider({ Title = "Jangkauan collect (tile)", Step = 0.5,
            Value = { Min = Core.LIMITS.collectRange[1], Max = Core.LIMITS.collectRange[2], Default = App.config.options.collectRange },
            Callback = function(value) setOption(function() App.config.options.collectRange = tonumber(value) end) end })

        pcall(function() tab:Section({ Title = "Stock" }) end)
        controls.stock = tab:Paragraph({ Title = "Stock (Display Box)", Desc = "Belum diset" })
        tab:Button({ Title = "Set stock position here", Desc = "Berdiri di samping Display Box berisi blok yang di-PNB.",
            Callback = UI.action(function()
                local box = G.Storage.captureNearby("stock", "box")
                Pnb.refreshTab()
                G.setStatus("Display Box stock disimpan: tile " .. box.x .. ", " .. box.y .. ".")
            end) })
        controls.autoStock = tab:Toggle({ Title = "Auto take stock", Value = App.config.pnb.autoStock,
            Desc = "Blok di tas habis: jalan ke Display Box stock, ambil blok, lalu lanjut PNB.",
            Callback = function(enabled) setOption(function() App.config.pnb.autoStock = enabled == true end) end })

        controls.drop = tab:Paragraph({ Title = "Seed drop (Display Box)", Desc = "Belum diset" })
        tab:Button({ Title = "Set seed drop position here", Desc = "Berdiri di samping Display Box tempat seed ditaruh.", Callback = UI.action(function()
            local box = G.Storage.captureNearby("seedDrop", "box")
            Pnb.refreshTab()
            G.setStatus("Display Box seed disimpan: tile " .. box.x .. ", " .. box.y .. ".")
        end) })
        controls.autoDrop = tab:Toggle({ Title = "Auto drop seed", Value = App.config.pnb.autoDrop,
            Desc = "Seed di tas mencapai batas: jalan ke Display Box seed, taruh semua seed, lalu lanjut PNB.",
            Callback = function(enabled) setOption(function() App.config.pnb.autoDrop = enabled == true end) end })
        tab:Slider({ Title = "Drop seed saat seed di tas >=", Step = 1,
            Value = { Min = 1, Max = 200, Default = App.config.options.seedThreshold },
            Callback = function(value) setOption(function() App.config.options.seedThreshold = math.floor(tonumber(value)) end) end })

        controls.grid = tab:Paragraph({ Title = "PNB tiles", Desc = Pnb.gridText() })
        tab:Button({ Title = "Atur PNB tiles (5x5)", Desc = "Buka panel kotak 5x5. Kotak tengah = lo. Klik kotak lain untuk dipilih.",
            Callback = function() local ok, message = pcall(Pnb.openGridPanel); if not ok then G.notify(tostring(message)) end end })
        tab:Button({ Title = "Clear tiles", Callback = UI.action(function()
            App.config.pnb.tiles = {}
            Pnb.refreshTab()
            G.setStatus("Semua tile PNB dihapus. Pilih lagi lewat Atur PNB tiles.")
        end) })
        syncing = false
        Pnb.refreshTab()
        table.insert(G.onConnected, function() pcall(refreshBlocks); pcall(Pnb.refreshTab) end)
    end

    return Pnb
end
