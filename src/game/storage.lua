-- storage.lua: Display Box. Baca isi, ambil (withdraw), setor (deposit), dan simpan posisi box.
-- Diadaptasi dari Clarissv main.lua v0.1.43: boxRows, storageCount, settleStorage, closerStorage,
-- storageRequest, withdraw, deposit, captureNearby, pointText. Hook Botting dibuang.
return function(G)
    local App, Core, Bridge, Net, Actions, Movement, Navigation =
        G.App, G.Core, G.Bridge, G.Net, G.Actions, G.Movement, G.Navigation
    local Storage = {}
    local worldCheck, position, pause = Bridge.worldCheck, Bridge.position, Net.pause
    local count, refreshInventory = Actions.count, Actions.refreshInventory

    -- Isi box = daftar baris { itemId, jumlah }.
    function Storage.boxRows(point)
        local r = Bridge.runtime()
        assert(r.world.name == point.world, "Storage box is in another world.")
        local item = r.items[Actions.tileAt(point.x, point.y)]
        assert(item and item.display and not item.displayOne, "The saved tile is not a Display Box.")
        return r.world.displays.get(point.x, point.y) or {}
    end
    -- Hitung item di box. Item lain selain id/companionId = error (box harus khusus).
    function Storage.count(point, id, companionId)
        return Core.storageCount(Storage.boxRows(point), id, companionId)
    end

    local function settleStorage(point, token, refused)
        local hold = Movement.takeControls()
        hold.direction, hold.jump = 0, false
        local deadline = os.clock() + 0.75
        while math.abs(position().vx or 0) > 0.2 and os.clock() < deadline do pause(0.025, token) end
        if refused then pause(0.15, token) end -- beri waktu posisi baru sampai ke server
        worldCheck(point.world, token)
    end

    -- Server bilang "Get closer"? Cari tile berpijak paling dekat ke box lalu mendekat.
    local function closerStorage(point, token)
        local r, state = worldCheck(point.world, token), position()
        local map, goals = Movement.navigationMap(r), {}
        for y = math.max(0, point.y - 1), math.min(r.world.h - 2, point.y + 1) do
            for x = math.max(0, point.x - 1), math.min(r.world.w - 1, point.x + 1) do
                goals[#goals + 1] = { x = x, y = y, score = (x - point.x) ^ 2 + (y - point.y) ^ 2 }
            end
        end
        table.sort(goals, function(a, b)
            if a.score ~= b.score then return a.score < b.score end
            local ad = math.abs(a.x + 0.5 - state.x) + math.abs(a.y + 1 - state.y)
            local bd = math.abs(b.x + 0.5 - state.x) + math.abs(b.y + 1 - state.y)
            if ad ~= bd then return ad < bd end
            return a.y == b.y and a.x < b.x or a.y < b.y
        end)
        local start = { x = math.floor(state.x), y = math.floor(state.y - 0.01) }
        local goal
        for _, candidate in ipairs(goals) do
            local route = Navigation.plan(map, start, candidate, { fullWorld = true, maxNodes = math.min(12000, map.w * map.h),
                step = function() pause(0, token); worldCheck(point.world, token) end })
            if route then goal = candidate; break end
        end
        assert(goal, "No supported storage approach reaches this Display Box. Check the nearby floor or platform.")
        Movement.moveTo(goal.x, goal.y, point.world, token)
        if goal.x ~= point.x then
            -- Geser di dalam tile berpijak ke arah box, badan tetap di tile itu.
            local target = goal.x + 0.5 + (point.x > goal.x and 0.18 or -0.18)
            local hold, deadline = Movement.takeControls(), os.clock() + 2
            while os.clock() < deadline do
                state = position()
                assert(state.grounded and math.abs(state.y - (goal.y + 1)) < 0.25, "Storage approach left its supported tile.")
                if math.abs(target - state.x) < 0.075 and math.abs(state.vx or 0) < 0.2 then break end
                hold.direction, hold.jump = Navigation.steer(target - state.x, state.vx or 0), false
                pause(0.025, token)
                worldCheck(point.world, token)
            end
            hold.direction, hold.jump = 0, false
        end
        App.storageApproachDebug = point.world .. " box " .. point.x .. ", " .. point.y .. "; closer stand " .. goal.x .. ", " .. goal.y
        settleStorage(point, token, true)
    end

    -- world.call("DisplayItem", ...) dari game mengembalikan (ok, hasil). Timeout tetap jadi error.
    -- Coba request box maks 3x. Yang diulang CUMA penolakan "Get closer"; error lain dilempar.
    local function storageRequest(point, token, request)
        for attempt = 1, 3 do
            local ok, result = request()
            if ok then return ok, result end
            if type(result) ~= "string" or not result:find("Get closer to the Display Box.", 1, true) or attempt == 3 then
                return ok, result
            end
            G.setStatus("Display Box requires a closer approach; retry " .. (attempt + 1) .. "/3...")
            closerStorage(point, token)
        end
    end

    -- Ambil semua item `id` (dan companionId) dari box. onReady dipanggil tepat sebelum request,
    -- biasanya untuk menulis checkpoint "pickupPending". Return: jumlah id, jumlah companion.
    function Storage.withdraw(point, id, token, companionId, onReady)
        worldCheck(point.world, token)
        Movement.moveToPoint(point, token)
        settleStorage(point, token)
        if Storage.count(point, id, companionId) == 0
            and (not companionId or Storage.count(point, companionId, id) == 0) then return 0, 0 end
        refreshInventory(token)
        assert(Bridge.runtime().inventory:room(id) > 0, "Your backpack has no room for this block.")
        local before, companionBefore = count(id), companionId and count(companionId) or 0
        if onReady then onReady(before) end
        local ok, result = storageRequest(point, token, function()
            return Net.bounded(Bridge.runtime().world.call, App.config.options.actionTimeout, token,
                "DisplayItem", point.x, point.y, nil)
        end)
        assert(ok and type(result) == "table", type(result) == "string" and result or "Storage withdrawal failed.")
        local taken, companionTaken = 0, 0
        for _, row in pairs(result.taken or {}) do
            assert(row[1] == id or companionId and row[1] == companionId,
                "The storage box changed and another item was withdrawn. Check your backpack.")
            assert(type(row[2]) == "number" and row[2] > 0 and row[2] == math.floor(row[2]), "Invalid storage withdrawal count.")
            if row[1] == id then taken = taken + row[2] else companionTaken = companionTaken + row[2] end
        end
        refreshInventory(token)
        assert(taken + companionTaken > 0 and count(id) == before + taken, "The server did not confirm blocks in your backpack.")
        if companionId then
            assert(count(companionId) == companionBefore + companionTaken, "The server did not confirm seeds in your backpack.")
        end
        return taken, companionTaken
    end

    function Storage.deposit(point, id, amount, token, onReady, companionId)
        worldCheck(point.world, token)
        Movement.moveToPoint(point, token)
        settleStorage(point, token)
        Storage.count(point, id, companionId)
        refreshInventory(token)
        if onReady then onReady(count(id)) end
        amount = math.min(math.floor(amount), count(id))
        assert(amount > 0, "No items are available to deposit.")
        local before = count(id)
        local ok, result = storageRequest(point, token, function()
            return Net.bounded(Bridge.runtime().world.call, App.config.options.actionTimeout, token,
                "DisplayItem", point.x, point.y, id, nil, nil, amount, point.x + 0.5)
        end)
        assert(ok, type(result) == "string" and result or "The storage deposit was rejected.")
        refreshInventory(token)
        assert(count(id) <= before - amount, "The server did not confirm the storage deposit.")
        return amount
    end

    -- Jumlah item `id` di box, tanpa peduli item lain di box itu (box campur).
    function Storage.countOnly(point, id)
        return Core.itemCount(Storage.boxRows(point), id)
    end

    -- Ambil HANYA item `id` dari box yang juga berisi item lain (box campur).
    -- Game cuma punya perintah "ambil semua" (DisplayItem x, y, nil), jadi caranya: ambil semua,
    -- lalu item lain langsung ditaruh balik ke box yang sama (DisplayItem deposit).
    -- Box yang isinya cuma `id` memakai Storage.withdraw biasa. Return: jumlah `id` yang diambil.
    function Storage.withdrawSelected(point, id, token, onReady)
        local others = false
        for _, row in pairs(Storage.boxRows(point)) do
            if type(row) == "table" and row[1] ~= id then others = true end
        end
        if not others then return (Storage.withdraw(point, id, token, nil, onReady)) end
        worldCheck(point.world, token)
        Movement.moveToPoint(point, token)
        settleStorage(point, token)
        if Storage.countOnly(point, id) == 0 then return 0 end
        refreshInventory(token)
        assert(Bridge.runtime().inventory:room(id) > 0, "Tas tidak punya ruang untuk item ini.")
        local before = count(id)
        if onReady then onReady(before) end
        local ok, result = storageRequest(point, token, function()
            return Net.bounded(Bridge.runtime().world.call, App.config.options.actionTimeout, token,
                "DisplayItem", point.x, point.y, nil)
        end)
        assert(ok and type(result) == "table", type(result) == "string" and result or "Storage withdrawal failed.")
        refreshInventory(token)
        local taken, back = 0, {}
        for _, row in pairs(result.taken or {}) do
            assert(type(row[2]) == "number" and row[2] > 0 and row[2] == math.floor(row[2]), "Invalid storage withdrawal count.")
            if row[1] == id then taken = taken + row[2] else table.insert(back, { row[1], row[2] }) end
        end
        -- Taruh balik item lain. Gagal di sini = berhenti dengan pesan jelas (item ada di tas).
        for _, row in ipairs(back) do
            local itemId, amount = row[1], math.min(row[2], count(row[1]))
            if amount > 0 then
                local before2 = count(itemId)
                local put, issue = storageRequest(point, token, function()
                    return Net.bounded(Bridge.runtime().world.call, App.config.options.actionTimeout, token,
                        "DisplayItem", point.x, point.y, itemId, nil, nil, amount, point.x + 0.5)
                end)
                assert(put, "Item lain (" .. tostring(itemId) .. " x" .. amount .. ") terambil dan gagal ditaruh balik ke box: "
                    .. tostring(issue) .. ". Item itu ada di tas.")
                refreshInventory(token)
                assert(count(itemId) <= before2 - amount, "Server tidak mengonfirmasi item " .. tostring(itemId) .. " kembali ke box. Item itu ada di tas.")
            end
        end
        assert(count(id) == before + taken, "The server did not confirm the withdrawn items in your backpack.")
        return taken
    end

    ---------------------------------------------------------------- deteksi box otomatis
    -- Cari Display Box di world sekarang yang boleh dipakai untuk menyimpan `allowed` (daftar id):
    -- isinya kosong atau hanya item `allowed`. Box yang sudah berisi item itu didahulukan, lalu box
    -- kosong; kalau seri, yang paling dekat karakter. Posisi berdiri = tile di samping box (kiri,
    -- kanan, di box itu sendiri, 2 tile kiri/kanan) yang bisa dipijak. Return: point box.
    function Storage.findBox(allowed)
        local r, state = Bridge.runtime(), position()
        local map = Movement.navigationMap(r)
        local ok = {}
        for _, id in ipairs(allowed) do ok[id] = true end
        local function standable(x, y)
            if x < 0 or x >= r.world.w or y < 0 or y + 1 >= r.world.h then return false end
            return not map.solid(x, y) and (map.solid(x, y + 1) or map.platform(x, y + 1)) and true or false
        end
        local best, bestRank
        local seen, skipped = 0, 0
        for y = 0, r.world.h - 1 do
            local row = r.world.fg[y]
            for x = 0, r.world.w - 1 do
                local item = row and r.items[row[x] or 0]
                if item and item.display and not item.displayOne then
                    seen = seen + 1
                    local rows = r.world.displays.get(x, y) or {}
                    local usable, used = true, false
                    for _, entry in pairs(rows) do
                        if type(entry) == "table" then
                            if ok[entry[1]] then used = true else usable = false end
                        end
                    end
                    local stand
                    for _, dx in ipairs({ -1, 1, 0, -2, 2 }) do
                        if standable(x + dx, y) then stand = { x = x + dx, y = y }; break end
                    end
                    if usable and stand then
                        local distance = math.abs(x + 0.5 - state.x) + math.abs(y + 1 - state.y)
                        local rank = (used and 0 or 100000) + distance
                        if not bestRank or rank < bestRank then
                            best, bestRank = { world = r.world.name, x = x, y = y, standX = stand.x, standY = stand.y }, rank
                        end
                    else
                        skipped = skipped + 1
                    end
                end
            end
        end
        assert(best, string.format("Tidak ada Display Box yang bisa dipakai di %s (%d box, %d berisi item lain / tidak bisa didekati). "
            .. "Taruh 1 Display Box kosong di world ini.", r.world.name, seen, skipped))
        return best
    end

    ---------------------------------------------------------------- simpan posisi box
    function Storage.pointText(point)
        if not point then return "Belum disimpan" end
        local text = point.world .. "  |  tile " .. point.x .. ", " .. point.y
        if point.standX then text = text .. "  |  stand " .. point.standX .. ", " .. point.standY end
        return text
    end

    -- Cari box/door terdekat di sekitar karakter (3 tile kiri-kanan, 2 atas, 1 bawah) dan simpan
    -- posisinya beserta tempat karakter berdiri sekarang.
    function Storage.captureNearby(key, kind)
        local r, state = Bridge.runtime(), position()
        local standX, standY = math.floor(state.x), math.floor(state.y - 0.01)
        local candidates = {}
        for y = math.max(0, standY - 2), math.min(r.world.h - 1, standY + 1) do
            for x = math.max(0, standX - 3), math.min(r.world.w - 1, standX + 3) do
                local item = r.items[Actions.tileAt(x, y)]
                local matches = item and (kind == "box" and item.display and not item.displayOne
                    or kind == "door" and (item.door or item.vip))
                if matches then
                    local distance = (x + 0.5 - state.x) ^ 2 + (y + 1 - state.y) ^ 2
                    table.insert(candidates, { x = x, y = y, distance = distance })
                end
            end
        end
        table.sort(candidates, function(a, b) return a.distance < b.distance end)
        assert(candidates[1], "Stand beside the " .. kind .. " and try saving again.")
        assert(not candidates[2] or math.abs(candidates[1].distance - candidates[2].distance) > 0.1,
            "Two targets are equally close. Stand closer to the one you want to save.")
        local chosen = candidates[1]
        App.config.points[key] = { world = r.world.name, x = chosen.x, y = chosen.y, standX = standX, standY = standY }
        return App.config.points[key]
    end

    return Storage
end
