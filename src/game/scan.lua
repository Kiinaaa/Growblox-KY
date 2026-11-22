-- scan.lua: World Scan, mirip Growscan di Growtopia, untuk world yang sedang dimasuki.
-- Semua data dibaca dari memori game (tanpa request ke server):
--   grid tile (world.fg)    -> jumlah blok per jenis, pohon per jenis seed
--   data pohon              -> mateng / tumbuh + sisa waktu (waktu tanam + lama tumbuh item)
--   daftar drop             -> total item floating per jenis
--   isi Display Box         -> isi semua box di world
-- Data pohon dicari dengan 2 cara:
--   1) hook game (treeGrowthHooks, cara Clarissv) kalau masih tersedia;
--   2) sidik jari: tabel di sekitar fungsi milik world yang, untuk tile berisi seed, punya entri
--      pohon (tabel dengan angka waktu tanam). Dipakai setelah update Growblox 17 Nov 2026.
-- Hasil cara 2 juga dicatat detail di diagnostics supaya bisa disesuaikan kalau game berubah lagi.
return function(G)
    local App, Bridge = G.App, G.Bridge
    local Scan = {}
    -- Pencarian besar dijeda sesekali supaya game tidak nge-freeze (cuma kalau sedang di dalam task).
    local work = 0
    local function breathe(cost)
        work = work + (cost or 1)
        if work >= 3000 then
            work = 0
            local scheduler = G.task or task
            if coroutine.isyieldable() and scheduler and scheduler.wait then scheduler.wait() end
        end
    end

    -- Kumpulkan tabel kandidat: upvalue fungsi milik world + field tabel konteks (satu tingkat).
    local function candidateTables(r)
        -- cache per world: pindah world bisa membuat tabel pohon baru
        if r.treeCandidates and r.treeCandidatesWorld == r.world.name then return r.treeCandidates end
        local list, seen = {}, {}
        local function add(value)
            if type(value) == "table" and not seen[value] and value ~= r.world and value ~= r.items and #list < 6000 then
                seen[value] = true
                table.insert(list, value)
                return true
            end
        end
        local functions = {}
        for _, fn in ipairs(r.ownedFunctions or {}) do table.insert(functions, fn) end
        for _, key in ipairs({ "ride", "fg", "displayPut", "call" }) do
            if type(r.world[key]) == "function" then table.insert(functions, r.world[key]) end
        end
        for _, fn in pairs(r.handlers or {}) do if type(fn) == "function" then table.insert(functions, fn) end end
        for _, fn in ipairs(functions) do
            for _, value in pairs(Bridge.upvalues(fn)) do
                breathe(1)
                if add(value) then
                    -- tabel konteks: lihat field-nya juga (maks 256 per tabel)
                    pcall(function()
                        local n = 0
                        for _, field in next, value do
                            n = n + 1
                            breathe(1)
                            if n > 256 then break end
                            add(field)
                        end
                    end)
                end
            end
        end
        r.treeCandidates, r.treeCandidatesWorld = list, r.world.name
        return list
    end

    -- Entri pohon = tabel yang punya angka (waktu tanam). Kunci angka pertama yang mirip
    -- waktu server (> 1e9) dipakai sebagai "waktu tanam". Clarissv: tree.p.
    local function plantedField(entry)
        if type(entry) ~= "table" then return nil end
        if type(rawget(entry, "p")) == "number" then return "p" end
        local found
        pcall(function()
            for key, value in next, entry do
                if type(value) == "number" and value > 1e9 then found = key; break end
            end
        end)
        return found
    end
    -- Cara tabel pohon menyimpan entri: indeks y*w+x (Clarissv), 1-based, [y][x], [x][y], atau "x:y".
    local LAYOUTS = {
        { name = "y*w+x", get = function(t, x, y, w) return rawget(t, y * w + x) end },
        { name = "y*w+x+1", get = function(t, x, y, w) return rawget(t, y * w + x + 1) end },
        { name = "[y][x]", get = function(t, x, y) local row = rawget(t, y); return type(row) == "table" and rawget(row, x) or nil end },
        { name = "[x][y]", get = function(t, x, y) local col = rawget(t, x); return type(col) == "table" and rawget(col, y) or nil end },
        { name = "\"x:y\"", get = function(t, x, y) return rawget(t, x .. ":" .. y) end },
        { name = "\"x,y\"", get = function(t, x, y) return rawget(t, x .. "," .. y) end },
    }

    -- Cari tabel pohon memakai beberapa tile seed sebagai bukti. Return accessor + keterangan.
    function Scan.resolveTrees(r, seedTiles, retried)
        if r.treeRipe and r.treeRemaining then
            return { source = "hook game (cara Clarissv)", ripe = r.treeRipe, remaining = r.treeRemaining }
        end
        if #seedTiles == 0 then return nil, "tidak ada pohon di world ini" end
        local w = r.world.w
        local best
        -- Cache per world: tabel pohon yang sudah ketemu dipakai lagi kalau masih cocok (cek cepat),
        -- jadi pencarian besar cuma sekali per world, bukan tiap siklus panen.
        local cached = r.treeResolved
        if cached and cached.world == r.world.name then
            local hits = 0
            for i = 1, math.min(#seedTiles, 8) do
                local tile = seedTiles[i]
                local ok, entry = pcall(cached.layout.get, cached.table, tile.x, tile.y, w)
                if ok and type(entry) == "table" and type(rawget(entry, cached.field)) == "number" then hits = hits + 1 end
            end
            if hits > 0 then best = { table = cached.table, layout = cached.layout, field = cached.field, hits = hits } end
        end
        for _, t in ipairs(best and {} or candidateTables(r)) do
            breathe(#LAYOUTS)
            for _, layout in ipairs(LAYOUTS) do
                local hits, field = 0, nil
                for i = 1, math.min(#seedTiles, 8) do
                    local tile = seedTiles[i]
                    local ok, entry = pcall(layout.get, t, tile.x, tile.y, w)
                    local key = ok and plantedField(entry)
                    if key then hits, field = hits + 1, field or key end
                end
                if hits > 0 and (not best or hits > best.hits) then
                    best = { table = t, layout = layout, field = field, hits = hits }
                end
            end
        end
        if not best then
            if not retried then
                r.treeCandidates = nil -- tabel bisa sudah diganti game; kumpulkan ulang sekali
                return Scan.resolveTrees(r, seedTiles, true)
            end
            return nil, "tabel pohon tidak ketemu di " .. #candidateTables(r) .. " tabel kandidat"
        end
        local t, layout, field = best.table, best.layout, best.field
        r.treeResolved = { world = r.world.name, table = t, layout = layout, field = field }
        local function entryAt(x, y) local ok, e = pcall(layout.get, t, x, y, w); return ok and e or nil end
        local function remaining(x, y, id)
            local entry, item = entryAt(x, y), r.items[id]
            if type(entry) ~= "table" or type(entry[field]) ~= "number" or not item then return nil end
            return math.max(0, entry[field] + (item.grow or 0) - G.serverTime())
        end
        return {
            source = string.format("sidik jari: layout %s, field waktu tanam '%s', cocok %d/%d tile",
                layout.name, tostring(field), best.hits, math.min(#seedTiles, 8)),
            remaining = remaining,
            ripe = function(x, y, id)
                local left = remaining(x, y, id)
                if left == nil then return nil end
                return left <= 0
            end,
            entryAt = entryAt,
        }
    end

    -- Ringkas isi satu entri pohon untuk diagnostics (field: tipe/nilai).
    local function describeEntry(entry)
        if type(entry) ~= "table" then return type(entry) end
        local parts, n = {}, 0
        pcall(function()
            for key, value in next, entry do
                n = n + 1
                if n > 8 then break end
                local text = type(value) == "number" and string.format("%.1f", value) or type(value)
                table.insert(parts, tostring(key) .. "=" .. text)
            end
        end)
        return "{" .. table.concat(parts, ", ") .. "}"
    end

    local function itemName(r, id)
        local item = r.items[id]
        return (item and item.name or "Item") .. " (" .. tostring(id) .. ")"
    end
    local function duration(seconds)
        seconds = math.floor(seconds + 0.5)
        if seconds >= 3600 then return string.format("%dj %dm", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)) end
        if seconds >= 60 then return string.format("%dm %dd", math.floor(seconds / 60), seconds % 60) end
        return seconds .. "d"
    end
    local function sortedCounts(map)
        local list = {}
        for id, n in pairs(map) do table.insert(list, { id = id, n = n }) end
        table.sort(list, function(a, b) return a.n == b.n and a.id < b.id or a.n > b.n end)
        return list
    end

    -- Scan world sekarang. Return: daftar baris laporan (juga disimpan di App.scanReport).
    function Scan.run()
        local r = Bridge.worldCheck(nil)
        local world, items = r.world, r.items
        local blocks, trees, seedTiles, boxes = {}, {}, {}, {}
        for y = 0, world.h - 1 do
            local row = world.fg[y]
            if row then
                for x = 0, world.w - 1 do
                    local id = row[x]
                    if id and id ~= 0 then
                        local item = items[id]
                        if item and item.kind == "seed" then
                            trees[id] = trees[id] or { total = 0, ripe = 0, growing = 0, unknown = 0, longest = 0 }
                            trees[id].total = trees[id].total + 1
                            table.insert(seedTiles, { x = x, y = y, id = id })
                        else
                            blocks[id] = (blocks[id] or 0) + 1
                            if item and item.display and not item.displayOne then table.insert(boxes, { x = x, y = y }) end
                        end
                    end
                end
            end
        end

        local resolver, problem = Scan.resolveTrees(r, seedTiles)
        for _, tile in ipairs(seedTiles) do
            local info = trees[tile.id]
            local ripe = resolver and resolver.ripe(tile.x, tile.y, tile.id)
            if ripe == true then info.ripe = info.ripe + 1
            elseif ripe == false then
                info.growing = info.growing + 1
                local left = resolver.remaining(tile.x, tile.y, tile.id)
                if type(left) == "number" then info.longest = math.max(info.longest, left) end
            else info.unknown = info.unknown + 1 end
        end

        local floating, hidden = {}, 0
        for _, drop in pairs(world.dropList()) do
            if type(drop) == "table" and type(drop.id) == "number" and type(drop.n) == "number" then
                if drop.display then hidden = hidden + 1
                else floating[drop.id] = (floating[drop.id] or 0) + drop.n end
            end
        end

        local lines = { string.format("World %s (%dx%d), %s", tostring(world.name), world.w, world.h, os.date("%H:%M:%S")) }
        table.insert(lines, "POHON:")
        local treeList = {}
        for id, info in pairs(trees) do table.insert(treeList, { id = id, info = info }) end
        table.sort(treeList, function(a, b) return a.info.total > b.info.total end)
        if #treeList == 0 then table.insert(lines, "  (tidak ada pohon)") end
        for _, entry in ipairs(treeList) do
            local info = entry.info
            local text = string.format("  %s: %d pohon, %d mateng, %d tumbuh", itemName(r, entry.id), info.total, info.ripe, info.growing)
            if info.growing > 0 then text = text .. ", semua mateng dalam " .. duration(info.longest) end
            if info.unknown > 0 then text = text .. ", " .. info.unknown .. " status tidak terbaca" end
            table.insert(lines, text)
        end
        table.insert(lines, "  Data pohon: " .. (resolver and resolver.source or ("belum bisa dibaca: " .. tostring(problem))))
        if seedTiles[1] and not (r.treeRipe and r.treeRemaining) then
            local tile = seedTiles[1]
            table.insert(lines, string.format("  Contoh pohon di %d,%d: %s", tile.x, tile.y,
                resolver and resolver.entryAt and describeEntry(resolver.entryAt(tile.x, tile.y)) or "-"))
            local item = items[tile.id]
            table.insert(lines, "  Lama tumbuh item: " .. tostring(item and item.grow))
        end

        table.insert(lines, "FLOATING:")
        local floatList = sortedCounts(floating)
        if #floatList == 0 then table.insert(lines, "  (kosong)") end
        for i = 1, math.min(#floatList, 12) do
            table.insert(lines, "  " .. itemName(r, floatList[i].id) .. ": " .. floatList[i].n)
        end
        if hidden > 0 then table.insert(lines, "  (" .. hidden .. " drop bertanda display tidak dihitung)") end

        table.insert(lines, "BLOK:")
        local blockList = sortedCounts(blocks)
        for i = 1, math.min(#blockList, 12) do
            table.insert(lines, "  " .. itemName(r, blockList[i].id) .. ": " .. blockList[i].n)
        end

        table.insert(lines, "DISPLAY BOX: " .. #boxes)
        for i = 1, math.min(#boxes, 6) do
            local box = boxes[i]
            local ok, rows = pcall(function() return world.displays.get(box.x, box.y) end)
            local parts = {}
            if ok and type(rows) == "table" then
                for _, row in pairs(rows) do
                    if type(row) == "table" then table.insert(parts, itemName(r, row[1]) .. " " .. tostring(row[2])) end
                end
            end
            table.insert(lines, string.format("  %d,%d: %s", box.x, box.y, #parts > 0 and table.concat(parts, ", ") or "kosong"))
        end
        App.scanReport = lines
        App.scanTrees = trees
        return lines
    end

    return Scan
end
