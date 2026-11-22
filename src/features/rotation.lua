-- rotation.lua: Rotation khusus Hansel (bukan Full Rotation Clarissv). VERSI CEPAT: PNB banyak tile
-- sekaligus (Pnb.pipeline), replant dari tempat berdiri tanpa sinkron tas per tile, collect tanpa
-- sinkron tas berulang, pukul pohon tanpa jeda paksa. Per world di list rotasi:
--   1) masuk world, scan pohon;
--   2) HARVEST pohon mateng (zigzag dari atas) sampai blok di tas mencapai target (bawaan 180);
--   3) PNB di tempat berhenti: 1 tile kosong di samping (kanan dulu, lalu kiri), sampai blok habis;
--   4) REPLANT tile yang tadi dipanen (+ tile PNB), lalu kembali ke 2 sampai tidak ada pohon mateng;
--   5) simpan seed sisa (HANYA seed, blok tidak pernah disimpan) ke Display Box world itu, lalu world berikutnya.
-- Replant (v0.5.2): 1) lubang di baris di ATAS posisi sekarang, 2) tile yang barusan dipanen + tile PNB,
--   3) tile kosong lain di farm yang bisa ditanam. Supaya farm tidak bolong-bolong.
-- Resume (v0.5.2): checkpoint selalu disimpan (world ke berapa); error di tengah jalan diulang dari
--   world itu (maks 5x tanpa kemajuan), dan tombol "Resume rotation" melanjutkan setelah berhenti.
-- Setelah world terakhir balik ke world pertama. Kalau satu putaran tidak ada yang dipanen, tunggu
-- sampai pohon tercepat mateng (maks 10 menit per tunggu), lalu putar lagi.
-- Memakai helper Harvest (harvestTree, replant, store) dan PNB (placeTile, breakTile).
return function(G)
    local App, Core, Bridge, Net, Actions, Movement, Drops, State, Harvest, Pnb =
        G.App, G.Core, G.Bridge, G.Net, G.Actions, G.Movement, G.Drops, G.State, G.Harvest, G.Pnb
    local Rotation = {}
    local worldCheck, position, checkpoint, pause = Bridge.worldCheck, Bridge.position, Net.checkpoint, Net.pause
    local count, tileAt, refreshInventory = Actions.count, Actions.tileAt, Actions.refreshInventory
    local SEED_KEEP = 100 -- seed yang disisakan di tas saat simpan di tengah putaran (buat replant)
    -- Opsi collect cepat: jangkauan server + tanpa sinkron tas di awal/tiap batch (sekali di akhir).
    -- Drops.reach() mengembalikan tabel bersama, jadi disalin dulu sebelum diberi `fast`.
    local function fastReach()
        local base = Drops.reach()
        return { radius = base.radius, up = base.up, down = base.down, fast = true }
    end
    -- Collect cepat tanpa jalan, jangkauan lebar (drop dari tile 2 langkah ikut terambil). Tiap drop
    -- dicoba SEKALI; yang ditolak server dilewati (tidak ditunggu) dan diurus Pnb.collect / collectArea.
    local quickAttempts = {}
    -- wait=false: drop yang belum siap diambil dilewati (tidak ditunggu); wait=true: tunggu sampai siap.
    local function quickCollect(spot, ids, token, wait)
        local reach = Drops.reach()
        return Drops.collectNear(spot, ids, token, {
            radius = math.max(reach.radius, 2.75), up = math.max(reach.up, 3), down = math.max(reach.down, 2.5),
            fast = true, attempts = quickAttempts, maxAttempts = 1, noWait = not wait,
        })
    end

    ---------------------------------------------------------------- checkpoint / resume
    local resumePoint = G.Jobs.checkpointer("rotation", function() return { worldIndex = App.rotationIndex or 1 } end)
    Rotation.saveResume, Rotation.clearResume = resumePoint.save, resumePoint.clear
    local refreshResume = resumePoint.refresh

    local function info(text)
        App.rotationInfo = text
        G.setStatus(text)
    end
    -- Jalankan satu langkah kecil (1 pukul / 1 place-break). Error sesaat (timeout request, tile
    -- berubah saat settle, pukul gagal) tidak menghentikan world: dicatat, tunggu 0,5 detik, lanjut.
    -- Stop, keluar world, dan avatar mati tetap dilempar ke atas. Return: true kalau sukses.
    local function soft(token, worldName, fn, ...)
        local ok, problem = pcall(fn, ...)
        if ok then return true end
        if type(problem) == "table" or tostring(problem):find("Stopped", 1, true) then error(problem, 0) end
        problem = Movement.classifyFault(problem, token, worldName)
        if type(problem) == "table" then error(problem, 0) end
        App.rotationLastError = os.date("%H:%M:%S") .. " " .. tostring(problem)
        App.rotationSoftErrors = (App.rotationSoftErrors or 0) + 1
        pause(0.15, token)
        Movement.takeControls()
        return false
    end
    Rotation.soft = soft

    local function standing()
        local state = position()
        return { world = Bridge.runtime().world.name, x = math.floor(state.x), y = math.floor(state.y - 0.01) }
    end

    -- v0.9.2: URUTAN RUTE TERDEKAT. Baris dipilih yang paling dekat dengan posisi sekarang (bukan selalu dari atas),
    -- dan tiap baris dilalui dari ujung yang lebih dekat. rows = { { points = {...} }, ... }
    local function nearestRows(rows, from)
        local list, pos, left = {}, { x = from.x, y = from.y }, {}
        for _, entry in ipairs(rows) do if #entry.points > 0 then table.insert(left, entry) end end
        while #left > 0 do
            local bestIndex, bestCost, bestReverse
            for i, entry in ipairs(left) do
                local first, last = entry.points[1], entry.points[#entry.points]
                local costFirst = math.abs(pos.x - first.x) + math.abs(pos.y - first.y) * 2
                local costLast = math.abs(pos.x - last.x) + math.abs(pos.y - last.y) * 2
                local cost, reverse = costFirst, false
                if costLast < costFirst then cost, reverse = costLast, true end
                if not bestCost or cost < bestCost then bestIndex, bestCost, bestReverse = i, cost, reverse end
            end
            local entry = table.remove(left, bestIndex)
            if bestReverse then
                local reversed = {}
                for i = #entry.points, 1, -1 do table.insert(reversed, entry.points[i]) end
                entry = { row = entry.row, points = reversed }
            end
            table.insert(list, entry)
            pos = entry.points[#entry.points]
        end
        return list
    end
    -- Daftar tile -> urutan terdekat (per baris y, baris terdekat dulu, arah dari ujung terdekat).
    local function routeTiles(list, from)
        local byY, ys = {}, {}
        for _, point in ipairs(list) do
            if not byY[point.y] then byY[point.y] = {}; table.insert(ys, point.y) end
            table.insert(byY[point.y], point)
        end
        local rows = {}
        for _, y in ipairs(ys) do
            table.sort(byY[y], function(a, b) return a.x < b.x end)
            table.insert(rows, { points = byY[y] })
        end
        local out = {}
        for _, entry in ipairs(nearestRows(rows, from)) do
            for _, point in ipairs(entry.points) do table.insert(out, point) end
        end
        return out
    end
    Rotation.nearestRows, Rotation.routeTiles = nearestRows, routeTiles

    -- v0.9.4: URUTAN AWAL DARI UJUNG. Dipakai pada panen pertama tiap kunjungan world: baris paling ATAS dulu,
    -- dimulai dari pohon mateng paling KIRI di baris itu; baris berikutnya turun ke bawah (zigzag: mulai dari
    -- ujung yang lebih dekat ke posisi terakhir). Setelah itu urutan kembali rute terdekat (nearestRows).
    local function topDownRows(rows)
        local list = {}
        for _, entry in ipairs(rows) do
            if #entry.points > 0 then
                local pts = {}
                for _, point in ipairs(entry.points) do table.insert(pts, point) end
                table.sort(pts, function(a, b) return a.x < b.x end)
                table.insert(list, { row = entry.row, points = pts })
            end
        end
        table.sort(list, function(a, b) return a.points[1].y < b.points[1].y end)
        local lastX
        for i, entry in ipairs(list) do
            if i > 1 then
                local first, last = entry.points[1], entry.points[#entry.points]
                if math.abs(lastX - last.x) < math.abs(lastX - first.x) then
                    local reversed = {}
                    for n = #entry.points, 1, -1 do table.insert(reversed, entry.points[n]) end
                    entry.points = reversed
                end
            end
            lastX = entry.points[#entry.points].x
        end
        return list
    end
    Rotation.topDownRows = topDownRows

    -- Simpan HANYA seed ke box world ini (blok tetap di tas untuk PNB). keep = seed yang disisakan.
    function Rotation.storeSeeds(blockId, seedId, keep, token, box)
        refreshInventory(token)
        local amount = count(seedId) - (keep or 0)
        if amount > 0 then
            info(string.format("Menyimpan %d seed: jalan ke Display Box %s tile %d, %d...", amount, box.world, box.x, box.y))
            G.Storage.deposit(box, seedId, amount, token, nil, blockId)
        end
    end
    -- Seed hampir penuh saat PNB/harvest: REPLANT dulu (pakai seed, tanpa jalan jauh ke box),
    -- baru simpan ke box kalau masih penuh. Lalu balik ke `back`.
    local function seedOverflow(r, box, blockId, seedId, token, pending, back)
        if r.inventory:room(seedId) >= 10 then return end
        info("Seed hampir penuh: replant dulu...")
        local order = Rotation.replantOrder(r, pending or {}, back and back.y)
        if #order > 0 then Rotation.replantTiles(r, order, seedId, token) end
        refreshInventory(token)
        if r.inventory:room(seedId) < 10 then
            Rotation.storeSeeds(blockId, seedId, math.min(count(seedId), SEED_KEEP), token, box)
        end
        if back then Movement.moveTo(back.x, back.y, back.world or r.world.name, token) end
    end

    -- Tile kosong di sekitar tempat berdiri yang boleh dipakai PNB (samping dulu, lalu makin jauh).
    -- Dipilih otomatis: kosong + canPlace (jangkauan & akses dicek game). Maksimal `limit` tile.
    local function pnbTiles(r, blockId, here, limit, seeds)
        local list = {}
        seeds = seeds or {}
        for dy = -2, 2 do
            for dx = -2, 2 do
                local x, y = here.x + dx, here.y + dy
                if not (dx == 0 and dy == 0) and x >= 0 and x < r.world.w and y >= 0 and y < r.world.h
                    and tileAt(x, y) == 0 and not Pnb.seedOnTile(seeds, x, y) and r.handlers.canPlace(r.items[blockId], x, y) then
                    table.insert(list, { x = x, y = y, order = math.abs(dx) + math.abs(dy) * 1.5 })
                end
            end
        end
        table.sort(list, function(a, b)
            if a.order ~= b.order then return a.order < b.order end
            if a.y ~= b.y then return a.y < b.y end
            return a.x < b.x
        end)
        while #list > limit do table.remove(list) end
        return list
    end
    local function blocksInTiles(tiles, blockId)
        local n = 0
        for _, tile in ipairs(tiles) do if tileAt(tile.x, tile.y) == blockId then n = n + 1 end end
        return n
    end
    -- Spot break otomatis: ujung KIRI barisan farm. Baris acuan = baris pohon yang terakhir dipanen
    -- (atau baris tempat berdiri). Utamakan tile tepat di kiri baris; kalau tidak bisa dipijak
    -- (tidak ada lantai / dinding), pakai tile paling kiri baris itu sendiri. nil = tidak ketemu.
    local function leftSpot(r, y)
        local row
        for _, candidate in ipairs(Core.farmRows(r.world, r.items)) do
            if not row or math.abs(candidate.y - y) < math.abs(row.y - y) then row = candidate end
        end
        if not row then return nil end
        local function walkable(x)
            if x < 0 or x >= r.world.w then return false end
            local floor = r.items[r.world.fg[row.y + 1] and r.world.fg[row.y + 1][x] or 0]
            local tile = r.items[r.world.fg[row.y] and r.world.fg[row.y][x] or 0]
            return floor ~= nil and (floor.solid == true or floor.platform == true) and (not tile or not tile.solid)
        end
        for _, x in ipairs({ row.left - 1, row.left }) do
            if walkable(x) then return { x = x, y = row.y } end
        end
    end
    -- Tile break dari spot: pilihan user (Set tile break) kalau ada yang bisa dipakai, kalau tidak otomatis.
    local function breakTiles(r, blockId, here, limit, seeds)
        seeds = seeds or {}
        local custom = App.config.rotation.breakTiles or {}
        if #custom > 0 then
            local list = {}
            for _, offset in ipairs(custom) do
                local x, y = here.x + offset.dx, here.y + offset.dy
                if x >= 0 and x < r.world.w and y >= 0 and y < r.world.h and not Pnb.seedOnTile(seeds, x, y) then
                    local inside = tileAt(x, y)
                    if inside == 0 then
                        if r.handlers.canPlace(r.items[blockId], x, y) then table.insert(list, { x = x, y = y }) end
                    elseif inside ~= blockId and not (offset.dx == 0 and offset.dy == 1) and Core.farmable(r.items[inside]) then
                        table.insert(list, { x = x, y = y }) -- v0.9.5: penghalang dihancurkan oleh pipeline, lalu dipakai PNB
                    end
                end
            end
            if #list > 0 then return list end
        end
        return pnbTiles(r, blockId, here, limit, seeds)
    end
    -- Ada tile kosong di samping `spot`? (cek ringan tanpa canPlace; jangkauan dicek setelah sampai)
    local function hasFreeNeighbor(r, spot)
        for dx = -1, 1 do
            for dy = -1, 1 do
                local x, y = spot.x + dx, spot.y + dy
                -- tileAt melempar error di luar peta, jadi batas dicek dulu
                if not (dx == 0 and dy == 0) and x >= 0 and x < r.world.w and y >= 0 and y < r.world.h
                    and tileAt(x, y) == 0 then
                    return true
                end
            end
        end
        return false
    end

    -- PNB di tempat berhenti panen: sampai `pnbTiles` tile kosong sekaligus (pipeline: tile yang pecah
    -- langsung di-place lagi tanpa menunggu tile lain). Kalau di situ tidak ada tile yang bisa dipakai,
    -- coba berdiri di tile bekas panen lain (`spots`), maks 5 kali jalan.
    -- Return: daftar tile PNB (ikut di-replant), atau nil kalau tidak ketemu (blok tetap di tas).
    function Rotation.pnbHere(r, box, blockId, seedId, token, spots, pending)
        local cfg = App.config.rotation
        local limit = cfg.pnbTiles or 6
        local here = standing()
        if cfg.breakLeft ~= false then
            local last = spots and spots[#spots]
            local spot = leftSpot(r, last and last.y or here.y)
            if spot and (spot.x ~= here.x or spot.y ~= here.y) then
                info(string.format("PNB: jalan ke kiri barisan farm (%d,%d)...", spot.x, spot.y))
                soft(token, r.world.name, function() Movement.moveTo(spot.x, spot.y, r.world.name, token) end)
                here = standing()
            end
        end
        local function pick() return breakTiles(r, blockId, here, limit, Pnb.seedDrops(r, seedId)) end
        -- v0.9: seed yang belum terpungut di sekitar spot dipungut dulu; tile yang masih ada seed tidak dipakai put/break.
        if #Pnb.seedDrops(r, seedId) > 0 then
            soft(token, r.world.name, function() Pnb.collect(here, { seedId }, token) end)
            here = standing()
        end
        local tiles = pick()
        local moves = 0
        for index = #(spots or {}), 1, -1 do
            if #tiles > 0 or moves >= 5 then break end
            local spot = spots[index]
            if tileAt(spot.x, spot.y) == 0 and hasFreeNeighbor(r, spot) then
                moves = moves + 1
                Movement.moveTo(spot.x, spot.y, r.world.name, token)
                here = standing()
                tiles = pick()
            end
        end
        if #tiles == 0 then
            info("Tidak ada tile kosong di sekitar untuk PNB; blok tetap di tas, lanjut.")
            return nil
        end
        -- Panen cepat berhenti sebelum tepat di tengah tile. Pusatkan dulu di tile berdiri; kalau tidak,
        -- pipeline menganggap karakter "bergeser" lalu menunggu & jalan balik (terlihat seperti bug).
        soft(token, r.world.name, function()
            local s = position()
            if not s.grounded or math.abs(s.x - (here.x + 0.5)) > 0.15 or math.abs(s.y - (here.y + 1)) > 0.3 then
                Movement.moveTo(here.x, here.y, r.world.name, token)
            end
        end)
        local ids = { blockId, seedId, Drops.GEM }
        -- dibaca ulang tiap putaran: slider kecepatan di tab Rotation langsung berlaku tanpa stop
        local function currentSpeed()
            -- v0.9.4: collectEvery 2.5 dtk: pipeline tidak keluar-masuk tiap 0,8 dtk (tiap keluar, semua tile
            -- kosong menunggu delay lagi dari nol = terasa lag).
            return { placeDelay = cfg.placeDelay, punchDelay = cfg.punchDelay,
                actionTimeout = App.config.options.actionTimeout, collectEvery = 2.5 }
        end
        info(string.format("PNB di %d,%d (%d tile paralel): %d blok...", here.x, here.y, #tiles, count(blockId)))
        local stuck, last = 0, count(blockId) + blocksInTiles(tiles, blockId)
        local planned = {}
        for _, point in ipairs(pending or {}) do table.insert(planned, point) end
        for _, tile in ipairs(tiles) do table.insert(planned, tile) end
        -- v0.8.6: blok yang baru pecah jatuh sebagai drop dan baru bisa dipungut sesaat kemudian. Dengan blok
        -- sedikit (mis. 1-5) tas sempat 0 dan loop berhenti sebelum drop bisa diambil, jadi blok yang kembali
        -- tidak pernah di-break lagi. Sebelum berhenti, tunggu & pungut drop dulu; kalau blok kembali, lanjut.
        local function more() return count(blockId) > 0 or blocksInTiles(tiles, blockId) > 0 end
        local function moreAfterCollect()
            if more() then return true end
            soft(token, r.world.name, function() quickCollect(here, ids, token, true) end)
            return more()
        end
        while moreAfterCollect() do
            checkpoint(token)
            refreshResume()
            seedOverflow(r, box, blockId, seedId, token, planned, here)
            -- v0.9: tile yang masih ada seed belum terpungut dilewati; kalau ada yang menahan, tunggu & pungut dulu.
            soft(token, r.world.name, function() Pnb.pipeline(here, tiles, blockId, token, currentSpeed(), seedId, Pnb.collectIds(ids)) end)
            soft(token, r.world.name, function() quickCollect(here, ids, token, Pnb.seedBlocks(r, tiles, seedId)) end) -- tanpa jalan
            local planted = false
            for _, tile in ipairs(tiles) do
                local inside = tileAt(tile.x, tile.y)
                -- v0.9.5: isi lain yang bisa dihancurkan dihancurkan oleh pipeline; yang tidak bisa dilewati.
                if inside == seedId then planted = true end
            end
            if planted then break end -- tile PNB sudah ditanam saat replant karena seed penuh
            -- jaga-jaga: 8 putaran tanpa blok berkurang = jangan muter selamanya
            local now = count(blockId) + blocksInTiles(tiles, blockId)
            if now < last then stuck, last = 0, now else stuck = stuck + 1 end
            if stuck >= 8 then
                App.rotationLastError = "PNB tidak maju di " .. here.x .. ", " .. here.y .. " (place/break ditolak); lanjut replant."
                break
            end
        end
        -- sapu bersih sekali di akhir PNB: jalan ke drop yang tidak terjangkau dari tempat berdiri, lalu balik
        soft(token, r.world.name, function() Pnb.collect(here, ids, token) end)
        return tiles
    end

    -- Urutan replant: 1) lubang di baris DI ATAS posisi sekarang, 2) tile bekas panen + tile PNB,
    -- 3) tile kosong lain di farm yang bisa ditanam (zigzag). Tanpa duplikat.
    function Rotation.replantOrder(r, pending, currentY)
        local all = Core.plantingTiles(r.world, r.items, Core.farmRows(r.world, r.items))
        local seen, above, recent, rest = {}, {}, {}, {}
        local function add(point, into)
            local key = point.x .. ":" .. point.y
            if not seen[key] and Core.plantingTile(r.world, r.items, point.x, point.y) then
                seen[key] = true
                table.insert(into, { x = point.x, y = point.y })
            end
        end
        for _, point in ipairs(all) do if currentY and point.y < currentY then add(point, above) end end
        for _, point in ipairs(pending) do add(point, recent) end
        for _, point in ipairs(all) do add(point, rest) end
        -- Prioritas tetap (atas -> bekas panen -> sisa farm), tapi di dalam tiap kelompok urutannya RUTE TERDEKAT.
        local out, from = {}, standing()
        for _, group in ipairs({ above, recent, rest }) do
            local routed = routeTiles(group, from)
            for _, point in ipairs(routed) do table.insert(out, point) end
            if #routed > 0 then from = routed[#routed] end
        end
        return out
    end

    -- v0.9.2: cek akhir world sebelum seed disimpan: (1) pungut semua drop blok/seed/gem yang masih tergeletak di
    -- SELURUH world (jalan ke tiap drop, terdekat dulu), (2) tanam ulang tile kosong yang masih ada (miss), maks 3 putaran.
    function Rotation.finalCheck(r, seedId, ids, token, name)
        local function sweep()
            local here = standing()
            Drops.collectArea({ world = name, x = here.x, y = here.y }, ids, token,
                { radius = r.world.w, up = r.world.h, down = r.world.h }, { fast = true, maxTrips = 80 })
            refreshInventory(token)
        end
        sweep()
        local planted = 0
        for pass = 1, 3 do
            if count(seedId) <= 0 then break end
            local again = Rotation.replantOrder(r, {}, nil)
            if #again == 0 then break end
            info(string.format("Cek akhir %s: tanam ulang %d tile yang miss (putaran %d)", name, #again, pass))
            local n = Rotation.replantTiles(r, again, seedId, token)
            planted = planted + n
            if n == 0 then break end
        end
        if planted > 0 then sweep() end
        return planted
    end

    -- Tanam ulang tile kosong di daftar (urut). Seed habis = berhenti; sisanya dicoba putaran berikutnya.
    -- CEPAT (bawaan): tile yang terjangkau dari tempat berdiri langsung ditanam TANPA jalan dan tanpa
    -- sinkron tas per tile; baru jalan kalau tile di luar jangkauan. Hasilnya diverifikasi SEKALI di
    -- akhir lewat jumlah seed di server. Server menolak 3x = otomatis kembali ke cara aman (per tile).
    function Rotation.replantTiles(r, tiles, seedId, token)
        local planted, left = 0, {}
        local fast = App.rotationFastReplant ~= false and r.handlers.plantSeed ~= nil
        local startCount, sent = count(seedId), 0
        if fast and #tiles > 0 then
            -- v0.8.6: tanam sambil berjalan menyusuri tiap baris; tile yang tersisa diurus loop di bawah.
            local sweep = { sent = 0 }
            local ok, problem = pcall(Harvest.sweepPlant, r, tiles, seedId, token, startCount, sweep)
            sent = sweep.sent
            if not ok and (type(problem) == "table" or tostring(problem):find("Stopped", 1, true)) then error(problem, 0) end
        end
        for index, point in ipairs(tiles) do
            checkpoint(token)
            if tileAt(point.x, point.y) == 0 then
                local empty = fast and (startCount - sent <= 0) or (not fast and count(seedId) <= 0)
                if empty then
                    for i = index, #tiles do if tileAt(tiles[i].x, tiles[i].y) == 0 then table.insert(left, tiles[i]) end end
                    break
                end
                if fast then
                    if Harvest.plantFast(r, point, seedId, token) then sent = sent + 1
                    else
                        -- jalan ke tile; tanam begitu sudah terjangkau (tidak menunggu sampai berhenti di tile)
                        local planted = false
                        Movement.moveTo(point.x, point.y, r.world.name, token, function()
                            if Harvest.plantFast(r, point, seedId, token) then planted = true; return false end
                        end)
                        if not planted and Harvest.plantFast(r, point, seedId, token) then planted = true end
                        if planted then sent = sent + 1 else table.insert(left, point) end
                    end
                else
                    Movement.moveTo(point.x, point.y, r.world.name, token)
                    if Harvest.replant(r, point, seedId, token) then planted = planted + 1
                    elseif tileAt(point.x, point.y) == 0 then table.insert(left, point) end
                end
            end
        end
        if sent > 0 then
            local accepted = startCount - (refreshInventory(token)[seedId] or 0)
            local miss = math.max(0, sent - accepted)
            if miss > 0 then
                App.rotationReplantMiss = (App.rotationReplantMiss or 0) + miss
                if App.rotationReplantMiss >= 3 then
                    App.rotationFastReplant = false
                    App.rotationLastError = os.date("%H:%M:%S") .. " replant cepat ditolak server " .. App.rotationReplantMiss
                        .. "x; kembali ke cara aman (per tile)."
                end
            end
            planted = planted + (sent - miss)
            App.stats.replanted = (App.stats.replanted or 0) + (sent - miss)
        end
        return planted, left
    end

    -- Satu world: putaran harvest -> PNB -> replant sampai tidak ada pohon mateng.
    -- Return: jumlah pohon dipanen di world ini, dan detik sampai pohon tercepat berikutnya mateng.
    function Rotation.runWorld(index, token)
        local cfg = App.config.rotation
        local name = cfg.worlds[index]
        local function target() return cfg.blockTarget end -- dibaca ulang tiap dipakai: slider langsung berlaku
        App.rotationIndex = index
        Rotation.saveResume()
        -- Masuk + scan otomatis: tanaman = seed terbanyak di world, Display Box dicari otomatis.
        local setup, why = Harvest.setupWorld(name, token, string.format("Rotasi %d/%d", index, #cfg.worlds), Rotation.saveResume)
        App.rotationWorlds = App.rotationWorlds or {}
        if not setup then
            App.rotationWorlds[name] = "dilewati: " .. why
            return 0, nil
        end
        local r, seedId, blockId, box = setup.r, setup.seedId, setup.blockId, setup.box
        local ids = { blockId, seedId, Drops.GEM }
        for key in pairs(quickAttempts) do quickAttempts[key] = nil end
        local total, pending, plan = 0, {}, nil
        local pnbRetry = 0 -- blok kembali ke tas setelah PNB (drop baru terpungut): ulangi PNB, maks 5x per world
        local stats = { harvested = 0, pnb = 0, replanted = 0 }
        -- extra = pohon yang tetap dipanen walau blok sudah >= target. Dipakai kalau PNB tidak
        -- menemukan tile kosong di samping: panen 2 pohon lagi supaya ada tile kosong untuk PNB.
        local extra = 0
        local firstPass = true -- v0.9.4: panen pertama di world ini mulai dari ujung (atas, kiri)
        -- dipakai juga untuk laporan; diulang dari scan setelah error tidak menghapus hitungan putaran ini
        local function progress(phase)
            info(string.format("Rotasi %s (%d/%d) - %s | dipanen %d, PNB %d blok, ditanam ulang %d",
                name, index, #cfg.worlds, phase, stats.harvested, stats.pnb, stats.replanted))
        end
        -- v0.9.2: pohon mateng yang MASIH BERDIRI setelah sapuan (miss) didatangi lagi satu per satu, urut rute terdekat.
        -- Maks 3 putaran; berhenti kalau satu putaran tidak memanen apa pun (supaya tidak muter selamanya).
        local function retryMissed(list, stopFn)
            for pass = 1, 3 do
                if stopFn and stopFn() then return end
                local again = Harvest.plan(r, seedId)
                if again.ripe == 0 then return end
                progress("panen ulang pohon yang miss: " .. again.ripe .. " (putaran " .. pass .. ")")
                local before = #list
                for _, entry in ipairs(Rotation.nearestRows(again.rows, standing())) do
                    for _, point in ipairs(entry.points) do
                        if stopFn and stopFn() then return end
                        checkpoint(token)
                        soft(token, name, function()
                            if Harvest.harvestTree(r, point, seedId, again.resolver, token) then
                                table.insert(list, point)
                                stats.harvested = stats.harvested + 1
                            end
                        end)
                    end
                end
                soft(token, name, function() quickCollect(standing(), ids, token, true) end)
                if #list == before then return end
            end
        end
        while true do
            checkpoint(token)
            pause(0.05, token) -- selalu beri jeda: loop ini tidak boleh muter tanpa henti
            refreshResume()
            refreshInventory(token)
            -- 1) scan + HARVEST sampai blok di tas mencapai target
            plan = Harvest.plan(r, seedId)
            local harvested = {}
            -- v0.8.5: bawaan panen SEMUA pohon mateng yang ketemu di scan; berhenti hanya kalau tas hampir
            -- penuh (lalu PNB mengosongkan tas dan loop lanjut). Matikan toggle untuk kembali ke target blok.
            -- v0.9: target blok SELALU berlaku. Yang dihitung = blok di tas + blok yang sudah jatuh di lantai (sebentar
            -- lagi terpungut). Begitu mencapai target, panen berhenti SAAT ITU JUGA (per pohon, tidak per potongan)
            -- lalu langsung PNB. Berhenti juga kalau tas hampir penuh.
            local function available()
                local n = count(blockId)
                for _, drop in pairs(r.world.dropList()) do
                    if type(drop) == "table" and drop.id == blockId and not drop.display and type(drop.n) == "number" then
                        n = n + drop.n
                    end
                end
                return n
            end
            local function full()
                if r.inventory:room(blockId) < 5 then return true end
                return available() >= target() and extra <= 0
            end
            if not full() then
                progress("harvest (" .. plan.ripe .. " pohon mateng, break kalau blok >= " .. target() .. ")")
                -- v0.9.4: panen pertama = dari baris paling atas, mulai dari ujung kiri; selanjutnya baris terdekat dulu
                local ordered = firstPass and topDownRows(plan.rows) or Rotation.nearestRows(plan.rows, standing())
                local leadIn = firstPass
                for _, entry in ipairs(ordered) do
                    if leadIn and entry.points[1] then
                        leadIn = false
                        local start = entry.points[1]
                        progress(string.format("jalan ke ujung farm (%d,%d) untuk mulai panen", start.x, start.y))
                        soft(token, name, function() Movement.moveTo(start.x, start.y, name, token) end)
                    end
                    local lastPoint
                    -- v0.8.6: pohon dipanen dalam sapuan kontinu per potongan (10 pohon; 3 kalau mode target blok),
                    -- bukan berhenti & rem di tiap pohon. Tas/seed dicek di antara potongan.
                    local index, chunkSize = 1, 10
                    while index <= #entry.points do
                        if full() then break end
                        checkpoint(token)
                        refreshResume()
                        seedOverflow(r, box, blockId, seedId, token, harvested, nil)
                        local chunk = {}
                        for i = index, math.min(#entry.points, index + chunkSize - 1) do table.insert(chunk, entry.points[i]) end
                        index = index + #chunk
                        local done = {}
                        soft(token, name, function() Harvest.sweepTrees(r, chunk, seedId, plan.resolver, token, done, full) end)
                        for _, point in ipairs(done) do
                            lastPoint = point
                            table.insert(harvested, point)
                            stats.harvested = stats.harvested + 1
                            if count(blockId) >= target() then extra = extra - 1 end
                        end
                        -- ambil drop yang sudah siap (tanpa menunggu); sisanya ikut di potongan berikutnya / akhir baris
                        if #done > 0 then soft(token, name, function() quickCollect(standing(), ids, token, false) end) end
                    end
                    if lastPoint then
                        soft(token, name, function() quickCollect(standing(), ids, token, true) end)
                    end
                    -- sapu drop di sepanjang baris ini (yang sudah siap) sebelum pindah baris
                    if lastPoint then
                        local row = entry.row
                        local mid = row and math.floor((row.left + row.right) / 2) or lastPoint.x
                        local half = row and ((row.right - row.left) / 2 + 2) or 4
                        soft(token, name, function()
                            Drops.collectArea({ world = name, x = mid, y = lastPoint.y }, ids, token,
                                { radius = half, up = 3, down = 3 }, { fast = true, noWait = true })
                        end)
                    end
                    if full() then break end
                end
                if #ordered > 0 then firstPass = false end
                -- cek ulang: pohon mateng yang miss didatangi lagi
                retryMissed(harvested, full)
                -- sisa drop di sekitar pohon yang barusan dipanen
                if #harvested > 0 then
                    local last = harvested[#harvested]
                    Drops.collectArea({ world = name, x = last.x, y = last.y }, ids, token, { radius = 4, up = 1.5, down = 1.25 }, { fast = true })
                end
            end
            total = total + #harvested
            for _, point in ipairs(harvested) do table.insert(pending, point) end
            -- v0.9: blok yang masih tergeletak di lantai (belum terpungut) dipungut dulu, jangan dianggap "tidak ada kerjaan".
            if #harvested == 0 and count(blockId) == 0 and available() > 0 then
                soft(token, name, function() Pnb.collect(standing(), ids, token) end)
                refreshInventory(token)
            end
            if #harvested == 0 and count(blockId) == 0 and #pending == 0 then break end
            -- 2) PNB di tempat berhenti sampai blok habis
            local didPnb = false
            if count(blockId) > 0 then
                local before = count(blockId)
                progress("PNB")
                local used = Rotation.pnbHere(r, box, blockId, seedId, token, harvested, pending)
                if used then
                    for _, tile in ipairs(used) do table.insert(pending, tile) end
                    stats.pnb = stats.pnb + (before - count(blockId))
                    extra = 0
                    didPnb = true
                elseif plan.ripe > #harvested then
                    extra = 2 -- tidak ada tile kosong: panen 2 pohon lagi biar ada tempat PNB
                else
                    info("Blok tidak bisa di-PNB (tidak ada tile kosong & pohon mateng habis); blok tetap di tas.")
                end
            end
            -- 3) REPLANT tile yang dipanen (+ tile PNB), sampai ketemu pohon mateng berikutnya
            local currentY = harvested[#harvested] and harvested[#harvested].y or standing().y
            local order = Rotation.replantOrder(r, pending, currentY)
            if #order > 0 and count(seedId) > 0 then
                progress("replant " .. #order .. " tile (atas -> bekas panen -> sisa farm)")
                local planted = Rotation.replantTiles(r, order, seedId, token)
                stats.replanted = stats.replanted + planted
            end
            -- v0.9.2: cek ulang -> tile yang masih kosong (miss) didatangi lagi, maks 3 putaran
            for pass = 1, 3 do
                if count(seedId) <= 0 then break end
                local again = Rotation.replantOrder(r, {}, nil)
                if #again == 0 then break end
                progress("tanam ulang yang miss: " .. #again .. " tile (putaran " .. pass .. ")")
                local n = Rotation.replantTiles(r, again, seedId, token)
                stats.replanted = stats.replanted + n
                if n == 0 then break end
            end
            -- Tile yang belum kebagian seed tidak dibawa sebagai prioritas: putaran berikutnya
            -- bekas panen terbaru didahulukan, sisanya tertangkap lagi di langkah "sisa farm".
            pending = {}
            -- tidak ada pohon mateng lagi di world ini (atau tidak ada yang bisa dipanen sama sekali)
            -- berhenti kalau pohon mateng habis, atau putaran ini tidak mengubah apa pun
            if plan.ripe == 0 or (#harvested == 0 and not didPnb and extra <= 0) then
                if didPnb and count(blockId) > 0 and pnbRetry < 5 then pnbRetry = pnbRetry + 1
                else break end
            end
        end
        -- 3b) v0.9.2: cek akhir (drop yang tertinggal & tile yang belum ditanam), baru simpan seed
        progress("cek akhir drop & tile kosong")
        soft(token, name, function() Rotation.finalCheck(r, seedId, ids, token, name) end)
        -- 4) simpan seed sisa (dan blok kalau masih ada) ke Display Box world ini
        progress("simpan seed sisa ke Display Box")
        Rotation.storeSeeds(blockId, seedId, 0, token, box)
        plan = Harvest.plan(r, seedId)
        App.rotationWorlds, App.rotationTotals = App.rotationWorlds or {}, App.rotationTotals or {}
        local sum = App.rotationTotals[name] or { harvested = 0, pnb = 0, replanted = 0 }
        for key in pairs(sum) do sum[key] = sum[key] + stats[key] end
        App.rotationTotals[name] = sum
        App.rotationWorlds[name] = string.format("total dipanen %d, PNB %d blok, ditanam ulang %d | %d tile belum ditanam, %d tumbuh%s",
            sum.harvested, sum.pnb, sum.replanted, #Core.plantingTiles(r.world, r.items), plan.growing,
            plan.soonest and (", tercepat mateng " .. Harvest.duration(plan.soonest)) or "")
        return total, plan.soonest
    end

    function Rotation.run(token, saved)
        local cfg = App.config.rotation
        local index = saved and saved.worldIndex or 1
        if index > #cfg.worlds then index = 1 end
        while true do
            local harvested, soonest = 0, nil
            for i = index, #cfg.worlds do
                local got, soon = Rotation.runWorld(i, token)
                harvested = harvested + got
                if soon then soonest = math.min(soonest or soon, soon) end
            end
            index = 1
            App.rotationLaps = (App.rotationLaps or 0) + 1
            if harvested == 0 then
                -- Satu putaran penuh tanpa panen: tunggu pohon tercepat mateng (maks 10 menit).
                local wait = math.max(5, math.min(soonest or 60, 600))
                local deadline = os.clock() + wait
                while os.clock() < deadline do
                    info("Rotasi: belum ada pohon mateng di semua world. Cek lagi dalam "
                        .. Harvest.duration(deadline - os.clock()) .. ".")
                    refreshResume()
                    pause(math.min(5, math.max(0.1, deadline - os.clock())), token)
                end
            end
        end
    end

    G.Jobs.register("rotation", {
        label = "Rotation",
        prepare = function(r)
            assert(r.body and r.controls and r.handlers and type(r.handlers.hit) == "function"
                and type(r.handlers.setTile) == "function" and type(r.handlers.plantSeed) == "function",
                "Hook pukul/place/tanam tidak tersedia. Copy diagnostics dari Settings.")
        end,
        -- Error di tengah jalan TIDAK langsung menghentikan rotasi (Jobs.resilient, anyError):
        --   keluar world / avatar mati (+ setting Rejoin) -> masuk lagi ke world itu, lanjut dari scan;
        --   error lain (jalan timeout, request box gagal, dll.) -> tunggu 3 detik, ulangi world itu dari
        --   scan. Berhenti kalau gagal 5x berturut-turut tanpa kemajuan sama sekali.
        run = function(token, saved)
            if App.config.options.autoRejoin then Movement.queueResume() end
            G.Jobs.resilient(token, saved, {
                label = "Rotation", anyError = true, maxFailures = 5, wait = 3,
                world = function() return App.config.rotation.worlds[App.rotationIndex or 1] end,
                progress = function() return (App.stats.trees or 0) + (App.stats.broken or 0) + (App.stats.replanted or 0) end,
                loop = Rotation.run,
                onRetry = function() return { worldIndex = App.rotationIndex or 1 } end,
            })
        end,
        clear = function() Rotation.clearResume() end,
        resume = true,
        validResume = function(data) return type(data.worldIndex) == "number" end,
    })
    -- Lanjut rotasi dari checkpoint (world terakhir yang dikerjakan). Dipakai tombol "Resume rotation"
    -- setelah rotasi berhenti karena error, dan otomatis setelah pindah server.
    function Rotation.resume()
        local record = State.loadCheckpoint("rotation")
        assert(record and type(record.data) == "table" and type(record.data.worldIndex) == "number",
            "Tidak ada rotasi tersimpan. Nyalakan Rotation untuk mulai dari world pertama.")
        App.config, App.profile = record.config, Core.profileName(record.profile)
        G.Jobs.start("rotation", record.data)
    end


    -- Pilih/batal pilih tile break (relatif ke spot di kiri barisan farm). Daftar kosong = otomatis.
    function Rotation.toggleBreakTile(dx, dy)
        if dx == 0 and dy == 0 then return end
        local tiles, removed = {}, false
        for _, tile in ipairs(App.config.rotation.breakTiles) do
            if tile.dx == dx and tile.dy == dy then removed = true else table.insert(tiles, tile) end
        end
        if not removed then table.insert(tiles, { dx = dx, dy = dy }) end
        App.config.rotation.breakTiles = Core.validatePNBTiles(tiles)
        State.saveSession()
        if Rotation.refreshTab then Rotation.refreshTab() end
    end
    function Rotation.breakGridText()
        local tiles = App.config.rotation.breakTiles
        if #tiles == 0 then
            return "OTOMATIS: sampai " .. tostring(App.config.rotation.pnbTiles or 6) .. " tile kosong terdekat di sekitar spot.\nTekan Set tile break untuk memilih sendiri."
        end
        return Pnb.gridText(tiles)
    end

    ---------------------------------------------------------------- tab Rotation
    function Rotation.buildTab(tab)
        local UI = G.UI
        local controls, syncing = {}, true
        UI.addStatus(tab:Paragraph({ Title = "Status", Desc = App.status }))
        tab:Paragraph({ Title = "Cara kerja", Desc = "Per world di list: masuk & scan otomatis (tanaman = seed terbanyak, Display Box dicari otomatis) -> harvest pohon mateng sampai blok di tas = target -> PNB di beberapa tile kosong sekaligus sampai blok habis -> replant (atas, bekas panen, sisa farm) -> ulangi sampai tidak ada pohon mateng -> simpan seed sisa ke box -> world berikutnya (muter)." })
        local function setOption(fn)
            if syncing then return end
            local ok, message = pcall(function() Net.idle(); fn(); State.saveSession() end)
            if not ok then G.notify(tostring(message)) end
        end
        -- v0.9.5: hampir semua setting Rotation LANGSUNG berlaku saat jalan (dibaca ulang tiap dipakai); hanya list world
        -- yang butuh stop dulu. liveOption = tanpa Net.idle.
        local function liveOption(fn)
            if syncing then return end
            local ok, message = pcall(function() fn(); State.saveSession() end)
            if not ok then G.notify(tostring(message)) end
        end
        function Rotation.refreshTab()
            local lines = {}
            for i, name in ipairs(App.config.rotation.worlds) do
                table.insert(lines, i .. ". " .. name .. (App.rotationWorlds and App.rotationWorlds[name] and (": " .. App.rotationWorlds[name]) or ""))
            end
            UI.paragraph(controls.list, "World rotasi", #lines > 0 and table.concat(lines, "\n") or "Belum ada world.")
            UI.paragraph(controls.grid, "Tile break (relatif ke spot kiri farm)", Rotation.breakGridText())
        end
        tab:Input({ Title = "World farm rotasi (urut)", Value = table.concat(App.config.rotation.worlds, ", "),
            Placeholder = "FARM1, FARM2, FARM3", Desc = "Terpisah dari list world Planting & Harvest. Pisahkan dengan koma.",
            Callback = function(value)
                setOption(function() App.config.rotation.worlds = Core.parseWorlds(value or "") end)
                Rotation.refreshTab()
            end })
        tab:Slider({ Title = "Minimal blok di tas sebelum break", Step = 1,
            Desc = "Panen berhenti begitu blok (di tas + yang sudah jatuh) mencapai angka ini, lalu langsung PNB. Contoh 10 = begitu 10 blok, langsung break.",
            Value = { Min = 1, Max = 200, Default = App.config.rotation.blockTarget },
            Callback = function(value) liveOption(function() App.config.rotation.blockTarget = math.floor(tonumber(value)) end) end })
        tab:Toggle({ Title = "Break di kiri barisan farm (otomatis)", Value = App.config.rotation.breakLeft ~= false,
            Desc = "Spot break dicari otomatis di ujung kiri barisan farm. Matikan untuk break di tempat berhenti panen.",
            Callback = function(value) liveOption(function() App.config.rotation.breakLeft = value == true end) end })
        controls.grid = tab:Paragraph({ Title = "Tile break (relatif ke spot kiri farm)", Desc = Rotation.breakGridText() })
        tab:Button({ Title = "Set tile break", Desc = "Buka panel 5x5: pilih tile yang di-place & break dari spot. Kosong = otomatis.",
            Callback = function()
                local ok, message = pcall(Pnb.openGridPanel, { key = "rotation", title = "Tile break rotasi - klik untuk pilih",
                    get = function() return App.config.rotation.breakTiles end, toggle = Rotation.toggleBreakTile })
                if not ok then G.notify(tostring(message)) end
            end })
        tab:Button({ Title = "Reset tile break (otomatis)", Desc = "Hapus pilihan tile; tile dipilih otomatis lagi.",
            Callback = function()
                liveOption(function() App.config.rotation.breakTiles = {} end)
                Rotation.refreshTab()
            end })
        G.Pnb.addDelaySliders(tab) -- Delay Place & Delay Break (sama dengan di tab Place & Break, saling sinkron)
        tab:Slider({ Title = "Kecepatan jalan saat panen & tanam", Step = 0.05,
            Desc = "1 = kecepatan penuh. Makin kecil makin pelan (bawaan 0.5) supaya pukulan panen & tanam tidak miss. Hanya dipakai saat menyapu pohon / menanam, jalan jauh tetap normal. Langsung berlaku saat jalan.",
            Value = { Min = Core.LIMITS.walkSpeed[1], Max = Core.LIMITS.walkSpeed[2], Default = App.config.options.walkSpeed },
            Callback = function(value) liveOption(function() App.config.options.walkSpeed = math.min(1, math.max(0.2, tonumber(value))) end) end })
        tab:Slider({ Title = "Tile PNB paralel", Step = 1,
            Value = { Min = 1, Max = 12, Default = App.config.rotation.pnbTiles or 6 },
            Desc = "Berapa tile kosong di sekitar karakter yang di-place & break bersamaan. Makin banyak makin cepat.",
            Callback = function(value) liveOption(function() App.config.rotation.pnbTiles = math.floor(tonumber(value)) end) end })
        tab:Toggle({ Title = "Replant cepat (tanpa jalan ke tiap tile)", Value = App.rotationFastReplant ~= false,
            Desc = "Tanam tile yang terjangkau langsung dari tempat berdiri. Matikan kalau farm jadi bolong-bolong.",
            Callback = function(value) App.rotationFastReplant = value == true end })
        controls.list = tab:Paragraph({ Title = "World rotasi", Desc = "Belum ada world." })
        G.Jobs.toggles.rotation = tab:Toggle({ Title = "Rotation", Value = false,
            Desc = "Jalan terus sampai di-stop. Mulai dari world pertama di list.",
            Callback = function(enabled) G.Jobs.setRunning("rotation", enabled) end })
        tab:Button({ Title = "Resume rotation", Desc = "Lanjut dari world terakhir yang dikerjakan (setelah rotasi berhenti karena error atau script dimuat ulang).",
            Callback = function()
                local ok, message = pcall(Rotation.resume)
                if not ok then G.notify(tostring(message)) end
            end })
        syncing = false
        Rotation.refreshTab()
        table.insert(G.onConnected, function() pcall(Rotation.refreshTab) end)
    end

    return Rotation
end
