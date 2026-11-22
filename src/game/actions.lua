-- actions.lua: aksi dasar yang dipakai semua fitur (PNB, plant, harvest, auto collect).
-- Pondasi baru berisi aksi inventory. Jalan, ambil drop, dan box ditambah bareng fiturnya.
-- Diadaptasi dari Clarissv main.lua (count, tileAt, refreshInventory).
return function(G)
    local App, Bridge, Net = G.App, G.Bridge, G.Net
    local Actions = {}

    function Actions.count(id)
        return Bridge.runtime().inventory:count(id)
    end

    function Actions.tileAt(x, y)
        local world = Bridge.runtime().world
        assert(x >= 0 and y >= 0 and x < world.w and y < world.h, "Tile di luar world.")
        return world.fg[y] and world.fg[y][x] or 0
    end

    -- Minta isi tas versi SERVER, lalu samakan tas lokal. Dipanggil sebelum keputusan penting,
    -- karena hitungan lokal bisa meleset (contoh: takeDrop tidak update tas lokal).
    function Actions.refreshInventory(token)
        local r = Bridge.runtime()
        local name = r.world.name
        local timeout = App.config.options.actionTimeout
        -- Kalau script sedang pegang kontrol, tunggu pickup bawaan game yang masih jalan selesai
        -- dulu, dan tahan pickup baru selama sinkron, biar snapshot server tidak ketinggalan item.
        local hold = App.controls
        -- Penghitung: refreshInventory bisa dipanggil bersamaan oleh task dan Auto Collect.
        local function release()
            if hold then
                hold.syncDepth = math.max(0, (hold.syncDepth or 1) - 1)
                hold.syncing = hold.syncDepth > 0
            end
        end
        if hold then
            hold.syncDepth = (hold.syncDepth or 0) + 1
            hold.syncing = true
            local waited, problem = pcall(function()
                local deadline = os.clock() + timeout
                while true do
                    if token then Net.checkpoint(token) end
                    local taking = hold.autoTakes > 0
                    for _, drop in pairs(r.world.dropList()) do
                        if drop.taking then taking = true end
                    end
                    if not taking then break end
                    assert(os.clock() < deadline, "Menunggu pickup yang sedang jalan: timeout.")
                    Net.pause(0.05, token)
                end
            end)
            if not waited then release(); error(problem, 0) end
        end
        local ok, result = pcall(Actions.syncInventory, r, name, timeout, token)
        release()
        if not ok then error(result, 0) end
        return result
    end

    function Actions.syncInventory(r, name, timeout, token)
        local snapshot
        for attempt = 1, 3 do
            if token then Bridge.worldCheck(name, token) end
            snapshot = Net.bounded(r.world.call, timeout, token, "GetInventory")
            if token then Bridge.worldCheck(name, token) end -- balasan bisa datang pas sudah keluar world
            if type(snapshot) == "table" and type(snapshot.slots) == "table" then break end
            if attempt < 3 then Net.pause(0.25, token) end
        end
        assert(type(snapshot) == "table" and type(snapshot.slots) == "table", "Balasan backpack dari server tidak valid.")
        local desired = {}
        for _, slot in pairs(snapshot.slots) do
            local id, n = slot[1], slot[2]
            assert(type(id) == "number" and type(n) == "number", "Slot backpack dari server tidak valid.")
            desired[id] = (desired[id] or 0) + n
        end
        if type(snapshot.capacity) == "number" then r.inventory.capacity = snapshot.capacity end
        -- Kurangi yang kelebihan (kecuali tool), tambah yang kurang. Sama seperti handler InventorySync game.
        local current = {}
        for _, slot in ipairs(r.inventory.slots) do current[slot.id] = slot.n end
        for id, n in pairs(current) do
            if r.items[id] and r.items[id].kind ~= "tool" and n > (desired[id] or 0) then
                r.inventory:remove(id, n - (desired[id] or 0))
            end
        end
        for id, n in pairs(desired) do
            local missing = n - r.inventory:count(id)
            if missing > 0 then r.inventory:add(id, missing) end
        end
        return desired
    end

    -- Daftar blok di tas yang bisa di-PNB (buat dropdown UI).
    function Actions.farmableBlocks()
        local r = Bridge.runtime()
        local list, seen = {}, {}
        for _, slot in ipairs(r.inventory.slots) do
            local item = r.items[slot.id]
            if not seen[slot.id] and G.Core.farmable(item) then
                seen[slot.id] = true
                table.insert(list, { id = slot.id, name = item.name or ("Item " .. slot.id) })
            end
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        return list
    end

    return Actions
end
