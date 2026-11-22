-- bridge.lua: SATU-SATUNYA modul yang mencari objek game di memori.
-- Modul lain cuma pakai hasilnya: Bridge.runtime() -> { world, body, controls, inventory, items, handlers, ... }
-- Kalau Growblox update dan script tiba-tiba "found 0", yang diperbaiki cukup file ini.
--
-- Cara kerja discover() diadaptasi dari Clarissv main.lua (discover, resolveRegistry,
-- resolveItems, treeGrowthHooks, findWorldPicker, findRespawn). Objek game dikenali dari
-- "sidik jari": kombinasi nama fungsi/field yang cuma dimiliki objek itu.
return function(G)
    local App, Core, Net, X, task = G.App, G.Core, G.Net, G.exec, G.task
    local Bridge = {}

    local function report(line) table.insert(App.discoveryReport, line) end

    ---------------------------------------------------------------- alat bantu scan
    local function newScan()
        return { values = {}, names = {}, work = 0, steps = 0, yields = 0, reads = 0, lastYield = os.clock() }
    end
    -- Kasih napas ke game tiap ~6 ms supaya scan memori yang besar tidak bikin freeze.
    local function scanStep(scan, stage)
        assert(App.alive, "Script di-unload saat connect.")
        App.startupStage = stage
        scan.work, scan.steps = scan.work + 1, scan.steps + 1
        if scan.work >= 8192 or os.clock() - scan.lastYield >= 0.006 then
            task.wait()
            assert(App.alive, "Script di-unload saat connect.")
            scan.work, scan.lastYield, scan.yields = 0, os.clock(), scan.yields + 1
        end
    end
    -- Isi "upvalue" sebuah fungsi = variabel luar yang dipakai fungsi itu.
    -- Dipakai untuk membuktikan fungsi A "milik" objek world B.
    local function upvalues(fn, scan)
        if scan and scan.values[fn] then return scan.values[fn] end
        local result
        if type(X.getupvalues) == "function" then
            local ok, values = pcall(X.getupvalues, fn)
            if ok and type(values) == "table" then result = values end
        end
        if not result and type(X.getupvalue) == "function" then
            result = {}
            for index = 1, 100 do
                local ok, first, second = pcall(X.getupvalue, fn, index)
                if not ok or first == nil then break end
                if second ~= nil then result[index] = second else result[index] = first end
            end
        end
        result = result or {}
        if scan then scan.values[fn], scan.reads = result, scan.reads + 1 end
        return result
    end
    local function functionName(fn, scan)
        if scan and scan.names[fn] ~= nil then return scan.names[fn] or nil end
        local name
        if type(X.debugInfo) == "function" then
            local ok, value = pcall(X.debugInfo, fn, "n")
            if ok and value and value ~= "" then name = value end
        end
        if not name and type(X.getinfo) == "function" then
            local ok, info = pcall(X.getinfo, fn)
            if ok and type(info) == "table" then name = info.name end
        end
        if scan then scan.names[fn] = name or false end
        return name
    end
    -- Fungsi "milik" world kalau upvalue-nya memegang tabel world itu (cara Clarissv).
    -- Cadangan v0.2.2 (update Growblox 17 Nov 2026): upvalue berupa tabel KONTEKS yang menyimpan
    -- world di salah satu field-nya (misal ctx.world). Cadangan v0.2.1: tabel lain yang memegang grid sama.
    local ownership = { direct = 0, nested = 0, grid = 0 }
    -- Field mana di tabel `value` yang berisi world? Dibaca mentah (tanpa metamethod), maks 256 field,
    -- dan hasilnya di-cache per tabel supaya tabel besar (misal daftar item) tidak dibaca berulang.
    local function holdsWorld(value, world, scan)
        local cache = scan and scan.holds
        if cache and cache[value] ~= nil then return cache[value] or nil end
        local found, n = nil, 0
        local ok = pcall(function()
            for key, field in next, value do
                n = n + 1
                if n > 256 then break end
                if field == world then found = key; break end
            end
        end)
        if not ok then found = nil end
        if cache then cache[value] = found or false end
        return found
    end
    local function owns(fn, world, scan)
        local nested, viaGrid = false, false
        for _, value in pairs(upvalues(fn, scan)) do
            if value == world then ownership.direct = ownership.direct + 1; return true end
            if type(value) == "table" then
                if not nested and holdsWorld(value, world, scan) ~= nil then nested = true end
                if not viaGrid and type(world.fg) == "table" and rawget(value, "fg") == world.fg then viaGrid = true end
            end
        end
        if nested then ownership.nested = ownership.nested + 1; return true end
        if viaGrid then ownership.grid = ownership.grid + 1; return true end
        return false
    end
    -- Ringkasan upvalue satu fungsi untuk diagnostics.
    local function describeUpvalues(fn, world, scan)
        local parts = {}
        for _, value in pairs(upvalues(fn, scan)) do
            local kind = type(value)
            if kind == "table" then
                local key = holdsWorld(value, world, scan)
                if value == world then kind = "WORLD"
                elseif key ~= nil then kind = "table(world di ." .. tostring(key) .. ")"
                elseif rawget(value, "fg") ~= nil then kind = rawget(value, "fg") == world.fg and "table(fg sama)" or "table(fg beda)"
                elseif type(rawget(value, "backpackNow")) == "function" then kind = "table(mirip world)"
                else
                    local names, n = {}, 0
                    pcall(function()
                        for k in next, value do
                            n = n + 1
                            if n > 6 then break end
                            table.insert(names, tostring(k))
                        end
                    end)
                    kind = "table{" .. table.concat(names, ",") .. (n > 6 and ",..." or "") .. "}"
                end
            end
            table.insert(parts, kind)
            if #parts >= 12 then break end
        end
        return #parts > 0 and table.concat(parts, ", ") or "kosong"
    end
    local function readField(value, key)
        local ok, field = pcall(function() return value[key] end)
        if ok then return field end
    end
    Bridge.upvalues = upvalues -- dipakai modul lain (misal FPS booster nanti)

    ---------------------------------------------------------------- registry & item
    local function registryMap(candidate, scan)
        if type(candidate) ~= "table" then return nil end
        local function matches(value) return type(value) == "table" and rawget(value, "RnyflzPbj74") ~= nil end
        if matches(candidate) then return candidate end
        for _, getMeta in ipairs({ getmetatable, X.getrawmetatable }) do
            if type(getMeta) == "function" then
                local ok, meta = pcall(getMeta, candidate)
                if ok and type(meta) == "table" and matches(rawget(meta, "__index")) then return rawget(meta, "__index") end
            end
        end
        if type(rawget(candidate, "WaitForChild")) == "function" and type(rawget(candidate, "FindFirstChild")) == "function" then
            for _, method in ipairs({ "WaitForChild", "FindFirstChild" }) do
                for _, value in pairs(upvalues(rawget(candidate, method), scan)) do
                    if matches(value) then return value end
                end
            end
        end
    end

    local function resolveRegistry(scan)
        local key = G.registryKey()
        if key ~= nil then
            for _, container in ipairs(X.sharedTables or {}) do
                if type(container.value) == "table" then
                    local map = registryMap(rawget(container.value, key), scan)
                    if map then return map, container.label end
                end
            end
        end
        return nil, "unavailable; Qz attribute: " .. (key ~= nil and "present" or "missing")
    end

    -- Tabel definisi item dikenali dari 5 item yang pasti ada: Blank, Dirt, Door, Fist, Display Box.
    local function itemDefinitions(candidate)
        if type(candidate) ~= "table" then return nil end
        local function entry(id, name)
            local value = rawget(candidate, id)
            if type(value) == "table" and rawget(value, "name") == name then return value end
        end
        local blank, dirt, fist = entry(0, "Blank"), entry(2, "Dirt"), entry(18, "Fist")
        local door, display = entry(12, "Door"), entry(1422, "Display Box")
        if blank and rawget(blank, "solid") == false
            and dirt and rawget(dirt, "solid") == true and type(rawget(dirt, "hits")) == "number"
            and fist and rawget(fist, "kind") == "tool"
            and door and rawget(door, "door") == true
            and display and rawget(display, "display") == true then return candidate end
    end

    local function resolveItems(world, registry, scan)
        local found, sources, seen = {}, {}, {}
        local function consider(candidate, source)
            local items = itemDefinitions(candidate)
            if items and not seen[items] then
                seen[items] = true
                table.insert(found, items)
                sources[items] = source
            end
        end
        -- Paling dipercaya: tabel item yang dipegang fungsi-fungsi milik world aktif.
        for _, value in pairs(world) do
            scanStep(scan, "Mencari definisi item")
            if type(value) == "function" then
                for _, captured in pairs(upvalues(value, scan)) do consider(captured, "upvalue fungsi world") end
            end
        end
        for _, fn in ipairs(scan.owned) do
            scanStep(scan, "Mencari definisi item")
            for _, captured in pairs(upvalues(fn, scan)) do consider(captured, "upvalue fungsi world") end
        end
        assert(#found <= 1, "Definisi item ambigu: ada " .. #found .. " tabel milik world aktif.")
        if #found == 1 then return found[1], sources[found[1]] end
        if registry then
            local items = itemDefinitions(rawget(registry, "RnyflzPbj74"))
            if items then return items, "tabel registry" end
        end
        for _, object in ipairs(scan.tables) do
            scanStep(scan, "Mencari definisi item")
            consider(object, "tabel GC")
        end
        assert(#found == 1, #found > 1 and "Definisi item ambigu di GC." or "Definisi item tidak ditemukan.")
        return found[1], sources[found[1]]
    end

    local function inventoryObject(candidate)
        return type(candidate) == "table" and type(rawget(candidate, "slots")) == "table"
            and type(readField(candidate, "count")) == "function" and type(readField(candidate, "room")) == "function"
            and type(readField(candidate, "add")) == "function" and type(readField(candidate, "remove")) == "function"
    end

    ---------------------------------------------------------------- hook pohon & UI kecil
    -- Cari fungsi "pohon sudah matang?" dan "sisa waktu tumbuh". Dipakai fitur harvest/plant nanti.
    local function treeGrowthHooks(world, items, handlers, scan)
        if type(world.ride) ~= "function" or type(handlers.setTree) ~= "function" then return nil end
        local rideTables, ripe, trees, gear = {}, nil, nil, nil
        for _, value in pairs(upvalues(world.ride, scan)) do
            if type(value) == "table" and value ~= world and value ~= items then rideTables[value] = true end
            if type(value) == "table" and type(rawget(value, "onWear")) == "function"
                and type(rawget(value, "isWorn")) == "function" and owns(value.onWear, world, scan) then
                if gear and gear ~= value then return nil end
                gear = value
            end
            if type(value) == "function" and functionName(value, scan) == "treeRipe" then
                for _, captured in pairs(upvalues(value, scan)) do
                    if captured == items then
                        if ripe and ripe ~= value then return nil end
                        ripe = value
                    end
                end
            end
        end
        for _, value in pairs(upvalues(handlers.setTree, scan)) do
            if rideTables[value] then
                if trees and trees ~= value then return nil end
                trees = value
            end
        end
        if not trees or not ripe then return nil end
        local equipment
        if gear then
            local worn, wearTables = nil, {}
            for _, value in pairs(upvalues(gear.onWear, scan)) do if type(value) == "table" then wearTables[value] = true end end
            for _, value in pairs(upvalues(gear.isWorn, scan)) do
                if type(value) == "table" and wearTables[value] and value ~= world and value ~= items then
                    if worn and worn ~= value then return nil end
                    worn = value
                end
            end
            if worn then equipment = { wear = gear.onWear, feet = function() return rawget(worn, "feet") end } end
        end
        local isRipe = function(x, y, id)
            local tree = trees[y * world.w + x]
            if type(tree) ~= "table" or type(tree.p) ~= "number" then return nil end
            return ripe(id, tree)
        end
        local remaining = function(x, y, id)
            local tree, item = trees[y * world.w + x], items[id]
            if type(tree) ~= "table" or type(tree.p) ~= "number" or not item then return nil end
            return math.max(0, tree.p + (item.grow or 0) - G.serverTime())
        end
        return isRipe, equipment, remaining
    end

    local function findWorldPicker(world, entries, scan)
        if type(world.enter) ~= "function" then return nil end
        local found
        for _, fn in ipairs(entries) do
            scanStep(scan, "Mencari world picker")
            local adapter, panel, hud, input
            for _, value in pairs(upvalues(fn, scan)) do
                if type(value) == "table" and rawget(value, "enter") == world.enter then adapter = value end
                if type(value) == "function" and functionName(value, scan) == "hud" then hud = value end
                if G.isInstance(value) then
                    if value:IsA("GuiObject") and value:FindFirstChild("recent", true)
                        and value:FindFirstChild("WorldName", true) then panel = value end
                    if value:IsA("TextBox") then input = value end
                end
            end
            if adapter and panel and hud then
                if found and found.panel ~= panel then return nil end
                found = { panel = panel, complete = function()
                    panel.Visible = false
                    hud()
                    if input then input:ReleaseFocus() end
                end }
            end
        end
        return found
    end

    local function findRespawn(world, menus, scan)
        if type(rawget(world, "respawn")) == "function" then return world.respawn, "method world" end
        local found
        for _, candidate in ipairs(menus) do
            scanStep(scan, "Mencari respawn")
            if type(rawget(candidate, "respawn")) == "function" and type(rawget(world, "enter")) == "function"
                and rawget(candidate, "enter") == world.enter and type(rawget(candidate, "currentWorld")) == "function"
                and owns(candidate.currentWorld, world, scan) then
                if found and found ~= candidate.respawn then return nil, "ambigu" end
                found = candidate.respawn
            end
        end
        return found, found and "adapter menu" or "tidak tersedia"
    end

    ---------------------------------------------------------------- discover
    -- Satu kali scan memori. Gagal = error dengan pesan yang jelas (dibaca Core.retryable).
    function Bridge.discover()
        assert(type(X.getgc) == "function", "Executor harus punya getgc(true).")
        local scan, startedAt = newScan(), os.clock()
        App.discoveryReport = {}
        ownership.direct, ownership.nested, ownership.grid = 0, 0, 0
        scan.holds = {}
        App.startupStage = "Membaca objek game"
        task.wait()
        local registry, registrySource = resolveRegistry(scan)
        local registryKey = G.registryKey()
        local worlds, physics, controls, huds, backpacks, menus, entries = {}, {}, {}, {}, {}, {}, {}
        scan.tables, scan.functions, scan.owned = {}, {}, {}

        for _, object in pairs(X.getgc(true)) do
            scanStep(scan, "Mengindeks world dan kontrol")
            if type(object) == "table" then
                table.insert(scan.tables, object)
                if not registry then
                    local map = registryMap(object, scan)
                        or (registryKey ~= nil and registryMap(rawget(object, registryKey), scan))
                    if map then registry, registrySource = map, "GC" end
                end
                -- Sidik jari world: 4 field ini sekaligus cuma ada di objek world aktif.
                if type(rawget(object, "backpackNow")) == "function" and type(rawget(object, "displayPut")) == "function"
                    and type(rawget(object, "useDoor")) == "function" and type(rawget(object, "fg")) == "table" then
                    table.insert(worlds, object)
                end
                -- Sidik jari fisika avatar: ukuran badan H = 0.95, HW = 0.3.
                if type(rawget(object, "state")) == "function" and type(rawget(object, "solidAt")) == "function"
                    and rawget(object, "H") == 0.95 and rawget(object, "HW") == 0.3 then
                    table.insert(physics, object)
                end
                if type(rawget(object, "dir")) == "function" and type(rawget(object, "jumping")) == "function"
                    and type(rawget(object, "punchPressed")) == "function" and type(rawget(object, "setScale")) == "function"
                    and type(rawget(object, "place")) == "function" and type(rawget(object, "edit")) == "function" then
                    table.insert(controls, object)
                end
                if type(rawget(object, "setGems")) == "function" and type(rawget(object, "addGems")) == "function"
                    and type(rawget(object, "setWorld")) == "function" and type(rawget(object, "isTyping")) == "function" then
                    table.insert(huds, object)
                end
                if inventoryObject(object) then table.insert(backpacks, object) end
                if type(rawget(object, "respawn")) == "function" then table.insert(menus, object) end
            elseif type(object) == "function" then
                table.insert(scan.functions, object)
                if functionName(object, scan) == "enter" then table.insert(entries, object) end
            end
        end

        report("Registry: " .. registrySource)
        report("World tables: " .. #worlds .. "; avatar controllers: " .. #physics .. "; touch controls: " .. #controls)
        assert(#worlds == 1, "Could not identify one active Growblox world table (found " .. #worlds .. ").")
        local world = worlds[1]
        local issues = {}

        local gemHud
        for _, candidate in ipairs(huds) do
            if not gemHud or (type(rawget(candidate, "onMessage")) == "function" and owns(candidate.onMessage, world, scan)) then
                gemHud = candidate
            end
        end

        local body
        for _, candidate in ipairs(physics) do
            if owns(candidate.state, world, scan) then
                if body then body = nil; table.insert(issues, "Lebih dari satu avatar cocok."); break end
                body = candidate
            end
        end
        if not body then table.insert(issues, "Hook state avatar tidak ada.") end
        if #controls ~= 1 then table.insert(issues, "Touch controller: ketemu " .. #controls .. ", harusnya 1.") end

        -- Backpack: utamakan objek inventory yang dipegang world.backpackNow.
        local inventory
        for _, candidate in pairs(upvalues(world.backpackNow, scan)) do
            if inventoryObject(candidate) then inventory = candidate end
        end
        if not inventory then
            local ok, snapshot = pcall(world.backpackNow)
            local matches = {}
            if ok and type(snapshot) == "table" then
                local counts = {}
                for _, slot in pairs(snapshot) do counts[slot[1]] = (counts[slot[1]] or 0) + slot[2] end
                for _, candidate in ipairs(backpacks) do
                    local same, seen = true, {}
                    for _, slot in pairs(candidate.slots) do
                        if counts[slot.id] ~= slot.n then same = false; break end
                        seen[slot.id] = true
                    end
                    for id in pairs(counts) do if not seen[id] then same = false end end
                    if same then table.insert(matches, candidate) end
                end
            end
            if #matches == 1 then inventory = matches[1] end
        end
        assert(inventory, "Backpack tidak ditemukan.")

        -- Handler farming (place/break/tanam) = fungsi yang dimiliki world dengan nama tertentu.
        local handlers, ambiguous = {}, {}
        for _, fn in ipairs(scan.functions) do
            scanStep(scan, "Mencari handler game")
            if owns(fn, world, scan) then
                table.insert(scan.owned, fn)
                local name = functionName(fn, scan)
                if name == "setTile" or name == "hit" or name == "canPlace" or name == "plantSeed" or name == "setTree" then
                    if handlers[name] or ambiguous[name] then handlers[name], ambiguous[name] = nil, true
                    else handlers[name] = fn end
                end
            end
        end
        for _, name in ipairs({ "setTile", "hit", "canPlace" }) do
            if not handlers[name] then table.insert(issues, (ambiguous[name] and "Ambigu" or "Tidak ada") .. " handler: " .. name) end
        end

        local items, itemSource = resolveItems(world, registry, scan)
        local respawn, respawnSource = findRespawn(world, menus, scan)
        local treeRipe, harvestGear, treeRemaining = treeGrowthHooks(world, items, handlers, scan)
        -- Detail tambahan saat ada hook hilang, untuk melacak perubahan di game.
        if #issues > 0 then
            if physics[1] then report("Upvalue avatar.state: " .. describeUpvalues(physics[1].state, world, scan)) end
            report("Upvalue world.displayPut: " .. describeUpvalues(world.displayPut, world, scan))
            local named = {}
            for _, fn in ipairs(scan.functions) do
                local name = functionName(fn, scan)
                if name == "setTile" or name == "plantSeed" or name == "canPlace" then
                    named[name] = (named[name] or 0) + 1
                    if name == "setTile" and named[name] == 1 then report("Upvalue setTile: " .. describeUpvalues(fn, world, scan)) end
                end
            end
            report(string.format("Fungsi bernama di GC: setTile %d, canPlace %d, plantSeed %d",
                named.setTile or 0, named.canPlace or 0, named.plantSeed or 0))
            report("World name: " .. tostring(world.name) .. "; w/h: " .. tostring(world.w) .. "/" .. tostring(world.h))
        end
        report("Kepemilikan: langsung " .. ownership.direct .. ", lewat konteks " .. ownership.nested .. ", lewat grid " .. ownership.grid)
        local runtime = { world = world, body = body, controls = controls[1], inventory = inventory, items = items,
            handlers = handlers, issues = issues, ready = #issues == 0, gemHud = gemHud,
            picker = findWorldPicker(world, entries, scan), respawn = respawn,
            treeRipe = treeRipe, harvestGear = harvestGear, treeRemaining = treeRemaining,
            ownedFunctions = scan.owned } -- dipakai World Scan untuk mencari tabel pohon

        report("Item definitions: " .. itemSource)
        report("Hooks: " .. (#issues == 0 and "ready" or table.concat(issues, " ")))
        report("Planting hook: " .. (handlers.plantSeed and "ready" or ambiguous.plantSeed and "ambiguous" or "unavailable"))
        report("Tree growth hook: " .. (treeRipe and "ready" or ("unavailable (world.ride " .. type(world.ride)
            .. ", setTree " .. (handlers.setTree and "ada" or ambiguous.setTree and "ambigu" or "tidak ada")
            .. "); pakai World Scan di world farm")))
        report("Respawn: " .. respawnSource .. "; world picker: " .. (runtime.picker and "ready" or "unavailable"))
        report(string.format("Discovery: %d yields, %d upvalue reads, %.2fs", scan.yields, scan.reads, os.clock() - startedAt))
        App.startupStage = "Tersambung"
        return runtime
    end

    ---------------------------------------------------------------- connect + retry
    -- PERBAIKAN dari Clarissv: di sana connect cuma dicoba sekali saat startup, jadi kalau
    -- world belum selesai loading habis pindah server ("found 0"), auto-resume mati.
    -- Di sini error "belum siap" dicoba ulang. Error lain langsung dilempar.
    function Bridge.connect(options)
        options = options or {}
        local attempts, delay = options.attempts or 8, options.delay or 4
        local lastError
        for attempt = 1, attempts do
            local ok, result = pcall(Bridge.discover)
            if ok then
                -- World ketemu, tapi tunggu avatar benar-benar siap sebelum dianggap tersambung.
                local body = result.body
                local state = body and body.state()
                local inWorld = result.world.name ~= nil and result.world.name ~= "" and not Bridge.pickerOpen(result)
                if inWorld and (not body or (state.active and not state.dead)) then
                    App.runtime, App.connectionError = result, nil
                    App.connectAttempts = attempt
                    return result
                end
                result = inWorld and "Your character is not ready yet." or "Still in the world picker. Enter a world first."
            end
            lastError = tostring(result)
            App.connectionError = lastError
            if not Core.retryable(lastError) or attempt == attempts then break end
            if options.onRetry then options.onRetry(attempt, attempts, lastError) end
            for _ = 1, math.floor(delay / 0.25) do
                assert(App.alive, "Script di-unload saat menunggu world.")
                task.wait(0.25)
            end
        end
        App.runtime = nil
        error(lastError, 0)
    end

    ---------------------------------------------------------------- cek kondisi
    function Bridge.runtime()
        assert(App.runtime, App.connectionError or "Belum tersambung ke game. Pakai Reconnect di Settings.")
        return App.runtime
    end
    function Bridge.pickerOpen(r)
        if not r or not r.picker then return false end
        local ok, visible = pcall(function() return r.picker.panel.Visible end)
        return ok and visible == true
    end
    -- Error "recoverable" boleh dipulihkan otomatis (misal masuk ulang world). Error biasa = stop.
    function Bridge.recoverable(message, worldName, reason)
        return setmetatable({ message = message, world = worldName, reason = reason, recoverable = true },
            { __tostring = function(value) return value.message end })
    end
    function Bridge.position()
        local r = Bridge.runtime()
        assert(r.body, "Hook avatar tidak ada. Copy diagnostics di Settings.")
        local state = r.body.state()
        assert(state.active and not state.dead, "Masuk ke world dan tunggu karakter siap.")
        return state
    end
    -- Dipanggil sebelum aksi penting: masih di world yang benar, avatar hidup, tidak di-freeze.
    function Bridge.worldCheck(name, token)
        if token then Net.checkpoint(token) end
        local r = Bridge.runtime()
        if r.world.name == nil or r.world.name == "" or Bridge.pickerOpen(r) then
            error(Bridge.recoverable("Kembali ke world picker.", name, "worldPicker"), 0)
        end
        assert(name == nil or r.world.name == name, "World berubah. Stop demi keamanan posisi tersimpan.")
        assert(not G.frozen(), "Karakter di-freeze.")
        if r.body then
            local state = r.body.state()
            if not state.active or state.dead then
                error(Bridge.recoverable("Menunggu avatar siap.", name, "avatar"), 0)
            end
        end
        return r
    end

    return Bridge
end
