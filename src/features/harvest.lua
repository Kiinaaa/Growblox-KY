-- harvest.lua: MESIN panen untuk Rotation (tidak punya tab/job sendiri di build ini).
-- Diadaptasi dari Clarissv main.lua v0.1.43 (runTreeHarvest mode Fist). Versi cepat: pukul tanpa jeda
-- paksa 0,25 detik, tanam ulang tanpa sinkron tas per tile. Aturan Hansel:
--   0) multi world seperti Planting; tanaman & Display Box dideteksi otomatis per world;
--   1) scan dulu; 2) yang dipanen cuma pohon yang SUDAH mateng (Clarissv menunggu semua);
--   3) pukul pohon sambil collect: pickup bawaan game tetap nyala saat jalan, dan sisa drop
--      tiap baris dipungut sebelum pindah baris; 4) hasil (blok + seed) disimpan ke Display Box world itu;
--   5) opsional Replant during harvest: tile yang baru dipanen langsung ditanam lagi.
return function(G)
    local App, Core, Bridge, Net, Actions, Movement, Drops, Storage, Scan =
        G.App, G.Core, G.Bridge, G.Net, G.Actions, G.Movement, G.Drops, G.Storage, G.Scan
    local Harvest = {}
    local worldCheck, checkpoint, pause = Bridge.worldCheck, Net.checkpoint, Net.pause
    local count, tileAt, refreshInventory = Actions.count, Actions.tileAt, Actions.refreshInventory

    local function duration(seconds)
        seconds = math.floor(seconds + 0.5)
        if seconds >= 3600 then return string.format("%dj %dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)) end
        if seconds >= 60 then return string.format("%dm %dd", math.floor(seconds / 60), seconds % 60) end
        return seconds .. "d"
    end

    -- Hasil "scan" untuk panen: baris farm (zigzag) berisi pohon yang sudah mateng.
    function Harvest.plan(r, seedId)
        local tiles = {}
        for y = 0, r.world.h - 1 do
            for x = 0, r.world.w - 1 do
                if r.world.fg[y] and r.world.fg[y][x] == seedId then table.insert(tiles, { x = x, y = y }) end
            end
        end
        local resolver, problem = Scan.resolveTrees(r, tiles)
        assert(#tiles == 0 or resolver, "Data pohon tidak terbaca: " .. tostring(problem) .. ". Scan world lalu copy diagnostics.")
        local work, ripe, growing, longest, soonest = {}, 0, 0, 0, nil
        for _, row in ipairs(Core.farmRows(r.world, r.items)) do
            local points = {}
            local first, last = row.direction == 1 and row.left or row.right, row.direction == 1 and row.right or row.left
            for x = first, last, row.direction do
                if tileAt(x, row.y) == seedId then
                    local ready = resolver.ripe(x, row.y, seedId)
                    if ready then table.insert(points, { x = x, y = row.y }); ripe = ripe + 1
                    elseif ready == false then
                        growing = growing + 1
                        local left = resolver.remaining(x, row.y, seedId) or 0
                        longest = math.max(longest, left)
                        soonest = math.min(soonest or left, left)
                    end
                end
            end
            if #points > 0 then table.insert(work, { row = row, points = points }) end
        end
        return { rows = work, ripe = ripe, growing = growing, longest = longest, soonest = soonest, resolver = resolver }
    end

    -- Simpan blok (dan seed) hasil panen ke Display Box farm. keepSeeds = sisakan seed untuk replant.
    local function store(blockId, seedId, keepSeeds, token, box)
        box = box or App.config.points.farmBox
        refreshInventory(token)
        if count(blockId) > 0 then
            G.setStatus("Menyimpan blok hasil panen ke Display Box farm...")
            Storage.deposit(box, blockId, count(blockId), token, nil, seedId)
        end
        local seeds = count(seedId) - (keepSeeds or 0)
        if seeds > 0 then
            G.setStatus("Menyimpan seed hasil panen ke Display Box farm...")
            Storage.deposit(box, seedId, seeds, token, nil, blockId)
        end
    end

    -- Tanam ulang satu tile (jalur AMAN/lambat): dikonfirmasi ke server tiap tile (jumlah seed berkurang 1
    -- dan tile berisi seed). Dipakai kalau jalur cepat terbukti ditolak server.
    local function replant(r, point, seedId, token)
        if tileAt(point.x, point.y) ~= 0 or count(seedId) <= 0 then return false end
        if not r.handlers.plantSeed or not r.handlers.canPlace(r.items[seedId], point.x, point.y) then return false end
        return Movement.withoutPickups(function()
            local before = refreshInventory(token)[seedId] or 0
            if before <= 0 then return false end
            r.handlers.plantSeed(seedId, point.x, point.y)
            pause(math.max(0.15, App.config.options.placeDelay), token)
            local deadline = os.clock() + App.config.options.actionTimeout
            repeat
                worldCheck(r.world.name, token)
                local now = refreshInventory(token)[seedId] or 0
                if now == before - 1 and tileAt(point.x, point.y) == seedId then
                    App.stats.replanted = (App.stats.replanted or 0) + 1
                    return true
                end
                pause(0.15, token)
            until os.clock() >= deadline
            return false
        end)
    end

    -- Tanam CEPAT dari tempat berdiri: tanpa jalan, tanpa sinkron tas, tanpa tunggu per tile.
    -- Return true kalau perintah tanam dikirim (hasilnya diverifikasi sekali per batch oleh pemanggil).
    function Harvest.plantFast(r, point, seedId, token)
        if tileAt(point.x, point.y) ~= 0 then return false end
        if not r.handlers.plantSeed or not r.handlers.canPlace(r.items[seedId], point.x, point.y) then return false end
        r.handlers.plantSeed(seedId, point.x, point.y)
        pause(math.min(0.03, (App.config.rotation or App.config.options).placeDelay), token) -- replant tidak ikut delay Put & Break
        return true
    end

    -- Pukul satu pohon mateng sampai tile kosong. v0.8.2: pukul SAMBIL jalan menuju pohon (begitu jaraknya
    -- <= hitReach tile), jadi waktu mengerem di tile ikut terpakai memukul. Pohon pecah sebelum sampai =
    -- langsung berhenti jalan dan lanjut ke pohon berikutnya. Kalau server menolak pukulan dari jarak itu
    -- tidak ada error: pukulan diulang saat sudah di tile (cara lama). Error hanya kalau 60 pukulan di tile gagal.
    -- v0.9.2: jangkauan pukul sambil jalan ADAPTIF. Kalau setelah sapuan masih ada pohon berdiri (miss, pukulan dari
    -- jauh ditolak server), jangkauan dikecilkan (min 0.5 tile); kalau bersih, pelan-pelan dinaikkan lagi (maks 1.5).
    local hitReach = 1.5
    -- v0.9.4: ANTI MISS. Kalau ada pohon mateng yang sudah dipukul dan masih berdiri dalam HOLD_REACH tile,
    -- karakter BERHENTI di situ (return "hold" ke Movement) sampai pohon pecah, maksimal HOLD_MAX detik per
    -- pohon (lewat dari itu dilepas supaya tidak macet; pohon itu diselesaikan retryMissed). Jalan tetap
    -- cepat di antara pohon; yang diperlambat cuma saat tepat di pohon.
    local HOLD_REACH, HOLD_MAX = 0.9, 0.8
    local function harvestTree(r, point, seedId, resolver, token)
        local name = r.world.name
        if tileAt(point.x, point.y) ~= seedId or not resolver.ripe(point.x, point.y, seedId) then return false end
        local opts = App.config.rotation or App.config.options
        local item = r.items[seedId]
        local burst = math.max(1, math.min(item and item.hits or 1, 4))
        local struck = false
        local function strike(state)
            if tileAt(point.x, point.y) ~= seedId then return false end -- sudah pecah: berhenti jalan
            if math.abs(state.x - (point.x + 0.5)) <= hitReach and math.abs(state.y - (point.y + 1)) <= 1.25 then
                struck = true
                for _ = 1, burst do r.handlers.hit(point.x, point.y) end
            end
        end
        Movement.moveTo(point.x, point.y, name, token, strike)
        if not struck and tileAt(point.x, point.y) ~= seedId then return false end
        local swings = 0
        while tileAt(point.x, point.y) == seedId do
            worldCheck(name, token)
            swings = swings + 1
            assert(swings <= 60, "Fist tidak berhasil memanen pohon di " .. point.x .. ", " .. point.y .. ". Cek akses world.")
            struck = true
            for _ = 1, burst do r.handlers.hit(point.x, point.y) end
            if opts.punchDelay <= 0.002 then Net.tick(token) else pause(opts.punchDelay, token) end
        end
        App.stats.trees = (App.stats.trees or 0) + 1
        return true
    end

    -- v0.8.6 SAPUAN PANEN: satu kali jalan menyusuri barisan, semua pohon mateng yang masuk jangkauan
    -- dipukul sambil lewat (tanpa berhenti/rem per pohon). `done` diisi tiap pohon yang terbukti hilang,
    -- jadi hasilnya tetap benar walau ada error di tengah jalan. Pohon yang tersisa (server menolak
    -- pukulan dari jarak jauh) diselesaikan dengan cara lama, satu per satu.
    -- v0.9: `stop` (opsional) = fungsi yang dicek tiap pohon pecah (dan tiap 0,05 detik): kalau true, sapuan
    -- BERHENTI SAAT ITU JUGA (tidak jalan terus, tidak memanen sisa pohon). Dipakai Rotation supaya begitu blok
    -- mencapai target, panen berhenti dan langsung PNB.
    function Harvest.sweepTrees(r, points, seedId, resolver, token, done, stop)
        local name = r.world.name
        local opts = App.config.rotation or App.config.options
        local item = r.items[seedId]
        local burst = math.max(1, math.min(item and item.hits or 1, 4))
        local gap = math.min(opts.punchDelay, 0.05) -- panen tidak ikut delay Put & Break
        local alive, hitAt, heldSince = {}, {}, {}
        for _, point in ipairs(points) do
            if tileAt(point.x, point.y) == seedId and resolver.ripe(point.x, point.y, seedId) then table.insert(alive, point) end
        end
        if #alive == 0 then return done end
        local stopped, lastCheck = false, 0
        local function prune()
            local keep, changed = {}, false
            for _, point in ipairs(alive) do
                if tileAt(point.x, point.y) == seedId then table.insert(keep, point)
                else
                    table.insert(done, point)
                    App.stats.trees = (App.stats.trees or 0) + 1
                    changed = true
                end
            end
            alive = keep
            return changed
        end
        local function shouldStop(changed)
            if not stop then return false end
            local t = os.clock()
            if not changed and t - lastCheck < 0.05 then return false end
            lastCheck = t
            if stop() then stopped = true end
            return stopped
        end
        local function strike(state)
            local changed = prune()
            if #alive == 0 then return false end -- semua sudah pecah: berhenti jalan
            if shouldStop(changed) then return false end -- target blok tercapai: berhenti jalan
            local t = os.clock()
            local holding = false
            for _, point in ipairs(alive) do
                local dx = math.abs(state.x - (point.x + 0.5))
                local inY = math.abs(state.y - (point.y + 1)) <= 1.25
                if dx <= hitReach and inY and t - (hitAt[point] or -1) >= gap then
                    hitAt[point] = t
                    for _ = 1, burst do
                        if tileAt(point.x, point.y) ~= seedId then break end
                        r.handlers.hit(point.x, point.y)
                    end
                end
                -- sudah dekat & masih berdiri setelah dipukul: tahan karakter di sini sampai pecah
                if dx <= HOLD_REACH and inY and hitAt[point] and tileAt(point.x, point.y) == seedId then
                    heldSince[point] = heldSince[point] or t
                    if t - heldSince[point] <= HOLD_MAX then holding = true end
                end
            end
            if holding then return "hold" end
        end
        local last = alive[#alive]
        Movement.moveTo(last.x, last.y, name, token, strike)
        prune()
        if not stopped then
            if #alive > 0 then
                hitReach = math.max(0.5, hitReach - 0.25)
                App.harvestMisses = (App.harvestMisses or 0) + #alive
            else
                hitReach = math.min(1.5, hitReach + 0.05)
            end
            App.harvestReach = hitReach
        end
        if stopped then return done end
        local rest = {}
        for _, point in ipairs(alive) do table.insert(rest, point) end
        for _, point in ipairs(rest) do
            checkpoint(token)
            if stop and stop() then break end
            if harvestTree(r, point, seedId, resolver, token) then table.insert(done, point) end
        end
        return done
    end

    -- v0.8.6 SAPUAN TANAM: tile satu baris ditanam sambil berjalan (tanpa berhenti & tanpa jeda per tile).
    -- state.sent dihitung per perintah tanam yang dikirim; hasilnya diverifikasi sekali oleh pemanggil.
    function Harvest.sweepPlant(r, tiles, seedId, token, seeds, state)
        local opts = App.config.rotation or App.config.options
        local name = r.world.name
        local tried, lastAt = {}, -1
        local function key(point) return point.x .. ":" .. point.y end
        local PLANT_NEAR = 1.25 -- v0.9.5: tile baru ditanam kalau karakter sudah dalam jarak ini (bukan di ujung jangkauan = sering ditolak server)
        local function plantReachable(group)
            local t = os.clock()
            if t - lastAt < math.min(0.03, opts.placeDelay) then return end -- replant tidak ikut delay Put & Break
            lastAt = t
            local n = 0
            local here = Bridge.position()
            for _, point in ipairs(group) do
                if state.sent >= seeds or n >= 8 then break end
                if not tried[key(point)] and math.abs(here.x - (point.x + 0.5)) <= PLANT_NEAR
                    and tileAt(point.x, point.y) == 0 and r.handlers.plantSeed
                    and r.handlers.canPlace(r.items[seedId], point.x, point.y) then
                    tried[key(point)] = true
                    r.handlers.plantSeed(seedId, point.x, point.y)
                    state.sent, n = state.sent + 1, n + 1
                end
            end
        end
        local index = 1
        while index <= #tiles and state.sent < seeds do
            checkpoint(token)
            local group, y = {}, tiles[index].y
            while tiles[index] and tiles[index].y == y do
                if tileAt(tiles[index].x, tiles[index].y) == 0 then table.insert(group, tiles[index]) end
                index = index + 1
            end
            if #group > 0 then
                local last = group[#group]
                Movement.moveTo(last.x, last.y, name, token, function()
                    plantReachable(group)
                    for _, point in ipairs(group) do
                        if not tried[key(point)] and tileAt(point.x, point.y) == 0 then return nil end
                    end
                    return false -- semua tile grup sudah dicoba: berhenti jalan
                end)
                plantReachable(group)
            end
        end
    end

    ---------------------------------------------------------------- deteksi otomatis
    -- Tanaman di world = jenis seed yang paling banyak ditanam (pohon) di world itu.
    function Harvest.detectCrop(r)
        local counts = {}
        for y = 0, r.world.h - 1 do
            local row = r.world.fg[y]
            for x = 0, r.world.w - 1 do
                local id = row and row[x]
                local item = id and r.items[id]
                if item and item.kind == "seed" then counts[id] = (counts[id] or 0) + 1 end
            end
        end
        local best, most = nil, 0
        for id, n in pairs(counts) do if n > most or (n == most and id < best) then best, most = id, n end end
        return best, most
    end

    -- Masuk world, deteksi tanaman + blok hasilnya + Display Box untuk menyimpan (blok & seed).
    -- Dipakai Harvest dan Rotation. Return: { r, seedId, blockId, box } atau nil + alasan.
    function Harvest.setupWorld(name, token, label, save)
        local r = Bridge.runtime()
        if r.world.name ~= name or Bridge.pickerOpen(r) then
            G.setStatus(label .. ": masuk " .. name .. "...")
            Movement.enterWorld(name, token, { label = label, resumeButton = label, save = save })
        end
        r = worldCheck(name, token)
        G.setStatus(label .. ": scan " .. name .. "...")
        local seedId, trees = Harvest.detectCrop(r)
        if not seedId then return nil, "tidak ada pohon" end
        local blockId = Core.blockForSeed(r.items, seedId)
        local found, box = pcall(Storage.findBox, { blockId, seedId })
        if not found then return nil, tostring(box) end
        pcall(Scan.run) -- laporan scan lengkap ikut ke diagnostics
        return { r = r, seedId = seedId, blockId = blockId, box = box, trees = trees }
    end

    Harvest.store, Harvest.replant, Harvest.harvestTree, Harvest.duration = store, replant, harvestTree, duration


    return Harvest
end
