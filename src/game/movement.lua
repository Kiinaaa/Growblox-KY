-- movement.lua: ambil alih kontrol karakter, jalan/lompat ke tile, dan masuk world.
-- Diadaptasi dari Clarissv main.lua v0.1.43: takeControls, releaseControls, navigationMap,
-- walkTo, moveTo, moveToPoint, withoutPickups, suspendHarvestVehicle, harvestEquipmentScope,
-- queueResume, enterPlantWorld. Logikanya dipertahankan; cabang Rotation/Botting dibuang dulu.
return function(G)
    local App, Bridge, Net, Actions, Navigation, task = G.App, G.Bridge, G.Net, G.Actions, G.Navigation, G.task
    local Movement = {}
    local worldCheck, position, pause, checkpoint = Bridge.worldCheck, Bridge.position, Net.pause, Net.checkpoint

    ---------------------------------------------------------------- kontrol
    -- Ganti fungsi arah/lompat milik game dengan versi kita. Selama dipegang, karakter
    -- bergerak sesuai hold.direction (-1 kiri, 0 diam, 1 kanan) dan hold.jump.
    -- Pickup bawaan game juga dibungkus: bisa ditahan (pausePickup) saat menanam/sinkron tas.
    -- v0.9.6: kontrol dianggap MASIH terpasang hanya kalau fungsi arah/lompat di game masih versi kita. Kalau game
    -- memasang ulang (respawn, masuk world, reset avatar), override kita lepas dan karakter tidak menurut lagi
    -- (kelihatan diam / tidak jalan). Di kasus itu kontrol dipasang ulang otomatis.
    local function stillAttached(hold, r)
        return hold.table == r.controls and hold.world == r.world
            and r.controls.dir == hold.dirOverride and r.controls.jumping == hold.jumpOverride
    end
    -- v0.9.10: pasang override ke `hold` yang SUDAH ADA (objek yang sama dipakai ulang). Dulu pemasangan ulang membuat
    -- objek hold baru, sementara walkTo masih menulis arah ke objek lama = karakter diam walau script jalan.
    local function install(hold, r)
        local controls, world = r.controls, r.world
        hold.table, hold.world = controls, world
        if controls.dir ~= hold.dirOverride then hold.dir = controls.dir end
        if controls.jumping ~= hold.jumpOverride then hold.jumping = controls.jumping end
        if world.displayTake ~= hold.displayOverride then hold.displayTake = world.displayTake end
        if world.takeDrop ~= hold.takeOverride then hold.takeDrop = world.takeDrop end
        controls.dir, controls.jumping = hold.dirOverride, hold.jumpOverride
        world.displayTake, world.takeDrop = hold.displayOverride, hold.takeOverride
    end
    function Movement.takeControls()
        local current = App.controls
        if current then
            local ok, rt = pcall(Bridge.runtime)
            if not ok then
                Movement.releaseControls()
                Bridge.runtime() -- lempar errornya
            end
            if stillAttached(current, rt) then return current end
            install(current, rt)
            current.suppressedTakes = {}
            App.controlsReattached = (App.controlsReattached or 0) + 1
            return current
        end
        local r = Bridge.runtime()
        local hold = { direction = 0, jump = false, autoTakes = 0, syncing = false, pausePickup = false, suppressedTakes = {} }
        hold.dirOverride = function() return hold.direction end
        hold.jumpOverride = function() return hold.jump end
        hold.displayOverride = function() end
        hold.takeOverride = function(uid, ...)
            if hold.syncing or hold.pausePickup then
                hold.suppressedTakes[uid] = { grid = hold.world.fg, at = os.clock() }
                return 0
            end
            hold.suppressedTakes[uid] = nil
            hold.autoTakes = hold.autoTakes + 1
            local result = table.pack(pcall(hold.takeDrop, uid, ...))
            task.defer(function() hold.autoTakes = hold.autoTakes - 1 end)
            if not result[1] then error(result[2]) end
            return table.unpack(result, 2, result.n)
        end
        install(hold, r)
        App.controls = hold
        return hold
    end

    -- Kembalikan fungsi asli, tapi cuma kalau yang terpasang masih versi kita.
    function Movement.releaseControls()
        local hold = App.controls
        if hold then
            if hold.table.dir == hold.dirOverride then hold.table.dir = hold.dir end
            if hold.table.jumping == hold.jumpOverride then hold.table.jumping = hold.jumping end
            if hold.world.displayTake == hold.displayOverride then hold.world.displayTake = hold.displayTake end
            if hold.world.takeDrop == hold.takeOverride then hold.world.takeDrop = hold.takeDrop end
            App.controls = nil
        end
    end

    -- Jalankan fn dengan pickup bawaan game ditahan (dipakai saat menanam).
    -- Pakai penghitung (bukan simpan/pulihkan nilai lama): Auto Collect berjalan paralel dengan task, dan dua
    -- pemanggil yang saling tumpang tindih tidak boleh meninggalkan pickup bawaan game tertahan selamanya.
    function Movement.withoutPickups(fn)
        local hold = App.controls
        if hold then
            hold.pauseDepth = (hold.pauseDepth or 0) + 1
            hold.pausePickup = true
        end
        local result = table.pack(pcall(fn))
        if hold then
            hold.pauseDepth = math.max(0, (hold.pauseDepth or 1) - 1)
            hold.pausePickup = hold.pauseDepth > 0
        end
        if not result[1] then error(result[2], 0) end
        return table.unpack(result, 2, result.n)
    end

    ---------------------------------------------------------------- jalan
    -- Peta untuk navigation.lua: ukuran world, kecepatan, gravitasi, tile padat/platform/berbahaya.
    function Movement.navigationMap(r)
        local world = r.world
        local function itemAt(x, y) return r.items[world.fg[y] and world.fg[y][x] or 0] end
        return {
            w = world.w, h = world.h, speed = (world.riding and world.riding.speed or 7.2) * (world.speedScale or 1),
            gravity = 55 * (world.gravityScale or 1),
            solid = function(x, y) return r.body.solidAt(x, y) end,
            platform = function(x, y) local item = itemAt(x, y); return item and item.platform end,
            danger = function(x, y)
                local item = itemAt(x, y)
                return item and (item.deadly or item.hurts)
            end,
        }
    end

    local function transientRouteFault(problem)
        if type(problem) ~= "string" then return false end
        return problem:find("Returning to the saved position timed out", 1, true)
            or problem:find("Could not reach the saved position", 1, true)
            or problem:find("The planned jumps did not reach the platforms", 1, true)
            or problem:find("The avatar did not land on a reachable floor or platform", 1, true)
    end

    -- Jalan ke tile (x, y) = tile tempat kaki berdiri. onStep(state) dipanggil tiap langkah:
    -- return false = berhenti, "hold" = diam sebentar (misal menunggu tanam), lainnya = lanjut.
    local function walkTo(x, y, worldName, token, onStep)
        local r = worldCheck(worldName, token)
        Actions.tileAt(x, y)
        local hold = Movement.takeControls()
        local targetX, targetY = x + 0.5, y + 1
        local farmNavigation = App.job == "plant" or App.job == "harvest" or App.job == "rotation"
        local timeout = farmNavigation and math.max(90, App.config.options.moveTimeout) or App.config.options.moveTimeout -- v0.9.11: kembali seperti v0.9.4 (farm minimal 90 dtk)
        local deadline, banned, replans = os.clock() + timeout, {}, 0
        local function collectionStep(state)
            if not onStep then return true, 0 end
            local started = os.clock()
            local proceed = onStep(state)
            local waited = os.clock() - started
            deadline = deadline + waited -- waktu menunggu aksi tidak dihitung sebagai gagal jalan
            return proceed ~= false, waited, proceed == "hold"
        end
        -- v0.9.5: BATAS KECEPATAN JALAN. Hanya saat ada onStep (menyapu panen / menanam / mendekati pohon): kecepatan
        -- horizontal dibatasi walkSpeed x kecepatan penuh (slider di tab Rotation, langsung berlaku). Di atas batas,
        -- tombol arah dilepas (karakter melambat), di bawahnya jalan lagi. Lompat / turun / di udara tidak dibatasi.
        local baseSpeed = Movement.navigationMap(r).speed or 7.2
        local function pace()
            if not onStep then return 1 end
            return math.min(1, math.max(0.2, App.config.options.walkSpeed or 1))
        end
        local function limited(direction, state, waypoint)
            local scale = pace()
            if scale >= 0.999 or direction == 0 or waypoint.jump or waypoint.drop or not state.grounded then return direction end
            local vx = state.vx or 0
            if vx * direction > 0 and math.abs(vx) >= baseSpeed * scale then return 0 end
            return direction
        end
        local function reached(state, tx, ty)
            return state.grounded and math.abs(state.x - tx) < 0.16
                and math.abs(state.y - ty) < 0.22 and math.abs(state.vx or 0) < 0.8
        end
        while true do
            worldCheck(worldName, token)
            hold = Movement.takeControls() -- v0.9.6: pastikan kontrol masih terpasang (replan juga lewat sini)
            local state = position()
            local proceed, _, pacing = collectionStep(state)
            if not proceed then hold.direction, hold.jump = 0, false; return false end
            while pacing do
                hold.direction, hold.jump = 0, false
                pause(0.025, token)
                deadline = deadline + 0.025
                worldCheck(worldName, token)
                state = position()
                proceed, _, pacing = collectionStep(state)
                if not proceed then return false end
            end
            state = position()
            if reached(state, targetX, targetY) then hold.direction, hold.jump = 0, false; return end
            assert(os.clock() < deadline, "Could not reach the saved position. Check stepping platforms and door access.")
            hold.direction, hold.jump = 0, false
            local landingDeadline = math.min(deadline, os.clock() + 2.5 + r.world.h / 24)
            while not state.grounded do
                assert(os.clock() < landingDeadline, "The avatar did not land on a reachable floor or platform.")
                pause(0.03, token)
                worldCheck(worldName, token)
                state = position()
            end
            local start = { x = math.floor(state.x), y = math.floor(state.y - 0.01) }
            local routeContext = worldName .. ": from tile " .. start.x .. ", " .. start.y
                .. " to standing tile " .. x .. ", " .. y
            App.navigationDebug = "Planning " .. routeContext
            local route, message
            -- JALUR CEPAT: satu baris, lantai rata sampai tujuan = jalan lurus tanpa perencanaan rute (A*).
            -- Kalau ada langkah gagal (banned terisi), kembali ke perencana biasa.
            if next(banned) == nil and start.y == y and x ~= start.x then -- v0.9.2: berapa pun jaraknya, selama satu baris rata
                local map = Movement.navigationMap(r)
                local dir = x > start.x and 1 or -1
                local last = Navigation.rowEnd(map, start, dir)
                if (dir == 1 and last >= x) or (dir == -1 and last <= x) then
                    route = {}
                    for tx = start.x + dir, x, dir do
                        table.insert(route, { x = tx, y = y, fromX = tx - dir, fromY = y, jump = false,
                            duration = 1 / (map.speed or 7.2) })
                    end
                end
            end
            if not route then
                route, message = Navigation.plan(Movement.navigationMap(r), start, { x = x, y = y }, {
                    banned = banned, fullWorld = farmNavigation,
                    maxNodes = farmNavigation and math.min(12000, r.world.w * r.world.h) or 1600,
                    step = function() pause(0, token); worldCheck(worldName, token) end,
                })
            end
            if not route then
                App.navigationDebug = "Failed " .. routeContext .. "; " .. tostring(message)
                error(tostring(message) .. " Route: " .. routeContext, 0)
            end
            if #route == 0 then route = { { x = x, y = y, fromX = start.x, fromY = start.y, jump = false, duration = 0.2 } } end
            route = Navigation.straightRuns(route)
            App.navigationDebug = "Planned " .. #route .. " walking/jumping steps to " .. x .. ", " .. y
            local failed
            for _, waypoint in ipairs(route) do
                local began, movedAt, movedX, movedY = os.clock(), os.clock(), state.x, state.y
                local launchAt, airborne = nil, false
                while true do
                    worldCheck(worldName, token)
                    state = position()
                    local stepProceed, waited, stepPacing = collectionStep(state)
                    began, movedAt = began + waited, movedAt + waited
                    if not stepProceed then hold.direction, hold.jump = 0, false; return false end
                    state = position()
                    if not stepPacing and reached(state, waypoint.x + 0.5, waypoint.y + 1) then break end
                    assert(os.clock() < deadline, "Returning to the saved position timed out. Check the route.")
                    -- v0.9.6: kotak teks yang masih fokus (mis. habis mengetik nama world di UI) dulu MEMBEKUKAN karakter
                    -- selamanya. Sekarang fokusnya dilepas dan jalan lanjut.
                    local focused = G.focusedTextBox()
                    if focused then pcall(function() focused:ReleaseFocus() end) end
                    if stepPacing then
                        hold.direction, hold.jump = 0, false
                        movedAt = os.clock()
                        if stepPacing then began, deadline = began + 0.025, deadline + 0.025 end
                    else
                        hold.direction = waypoint.drop and Navigation.dropSteer(state, waypoint)
                            or Navigation.steer(waypoint.x + 0.5 - state.x, state.vx or 0, state.grounded and 48 or 17)
                        hold.direction = limited(hold.direction, state, waypoint)
                        if waypoint.jump and not launchAt and state.grounded then launchAt = os.clock() end
                        if launchAt and not state.grounded then airborne = true end
                        hold.jump = launchAt ~= nil and ((not airborne and os.clock() - launchAt < 0.2)
                            or (airborne and not state.grounded and (state.vy or 0) < -0.1))
                        if math.abs(state.x - movedX) + math.abs(state.y - movedY) > 0.08 then
                            movedX, movedY, movedAt = state.x, state.y, os.clock()
                        end
                        -- batas waktu per langkah ikut diperpanjang saat jalan diperlambat (1 / walkSpeed)
                        if os.clock() - movedAt > 1 or os.clock() - began > math.max(2.5, waypoint.duration / pace() + 1.5) then
                            failed = waypoint
                            break
                        end
                    end
                    pause(0.012, token) -- per frame (dulu 0,025)
                end
                hold.direction, hold.jump = 0, false
                if failed then break end
            end
            if failed then
                -- Langkah yang gagal dilarang, lalu rute direncanakan ulang (maks 4x).
                for _, edge in ipairs(failed.edges) do
                    local from = edge.fromY * r.world.w + edge.fromX
                    local destination = edge.y * r.world.w + edge.x
                    banned[from .. ":" .. destination .. ":" .. tostring(edge.jump)] = true
                end
                replans = replans + 1
                assert(replans <= 4, "The planned jumps did not reach the platforms. Check the entrance and route layout.")
                G.setStatus("Trying another route around the obstacle...")
                failed = nil
            end
        end
    end

    function Movement.moveTo(x, y, worldName, token, onStep)
        for attempt = 1, 3 do
            local result = table.pack(pcall(walkTo, x, y, worldName, token, onStep))
            if result[1] then return table.unpack(result, 2, result.n) end
            checkpoint(token)
            local pending = App.plantState and App.plantState.pending
            -- Clarissv: retry rute cuma untuk Rotation/Botting. Mode tunggal langsung lempar error.
            if App.job ~= "rotation" or App.pending > 0 or pending or not transientRouteFault(result[2]) or attempt == 3 then
                error(result[2], 0)
            end
            worldCheck(worldName, token)
            local hold = Movement.takeControls()
            hold.direction, hold.jump = 0, false
            App.navigationRecovery = worldName .. ": replanning walking route, attempt " .. (attempt + 1) .. "/3"
            G.setStatus("Movement delayed; " .. App.navigationRecovery .. "...")
            pause(0.5, token)
        end
    end

    function Movement.moveToPoint(point, token)
        return Movement.moveTo(point.standX or point.x, point.standY or point.y, point.world, token)
    end

    ---------------------------------------------------------------- tractor
    -- Tractor (Dear John) harus dicopot sebelum jalan/menanam, lalu sepatu lama dipasang lagi.
    local function rememberHarvestEquipment(gear)
        if App.harvestGearRestore then return end
        local previousFeet = gear.feet()
        App.harvestGearRestore = function()
            local current = gear.feet()
            if current ~= previousFeet then
                if current then gear.wear(current) end
                if previousFeet then gear.wear(previousFeet) end
            end
        end
    end
    function Movement.suspendHarvestVehicle(token)
        local r = Bridge.runtime()
        if not r.world.riding or not r.world.riding.harvest then return end
        local gear = r.harvestGear
        assert(gear and gear.feet(), "Remove your harvesting vehicle; equipment hooks are unavailable.")
        rememberHarvestEquipment(gear)
        gear.wear(gear.feet())
        local deadline = os.clock() + App.config.options.actionTimeout
        while r.world.riding and r.world.riding.harvest do
            checkpoint(token)
            assert(os.clock() < deadline, "The harvesting vehicle did not unequip.")
            pause(0.025, token)
        end
    end
    function Movement.harvestEquipmentScope(fn)
        local parentRestore = App.harvestGearRestore
        App.harvestGearRestore = nil
        local result = table.pack(pcall(fn))
        local restore = App.harvestGearRestore
        App.harvestGearRestore = parentRestore
        local restored, issue = true, nil
        if restore then restored, issue = pcall(restore) end
        if not restored then App.harvestGearError = tostring(issue) end
        if not result[1] then error(result[2], 0) end
        assert(restored, "Could not restore previous footwear: " .. tostring(issue))
        return table.unpack(result, 2, result.n)
    end

    ---------------------------------------------------------------- masuk world
    -- Titip loader ke executor: setelah pindah server, script otomatis jalan lagi dan resume.
    function Movement.queueResume()
        local queue, loader = G.queueOnTeleport, G.env.GrowbloxHanselLoaderURL
        if type(queue) ~= "function" or type(loader) ~= "string" or not loader:match("^https://") then return false end
        if not App.queued then
            queue("getgenv().GrowbloxHanselAutoResume = true; loadstring(game:HttpGet("
                .. string.format("%q", loader) .. "))()")
            App.queued = true
        end
        return true
    end

    -- Masuk world `name` dan tunggu sampai stabil. options:
    --   save()        simpan checkpoint SEBELUM masuk (bisa pindah server)
    --   label         nama task di pesan status, misal "planting"
    --   resumeButton  nama tombol resume di pesan status
    --   moving        true = jangan tunggu 1 detik & jangan sinkron tas (dipakai Moving Drops nanti)
    function Movement.enterWorld(name, token, options)
        options = options or {}
        Movement.suspendHarvestVehicle(token)
        local r = Bridge.runtime()
        local attempts, nextEntry, stableSince = 0, 0, nil
        local deadline = os.clock() + App.config.options.actionTimeout + 15
        Movement.releaseControls()
        while App.pending > 0 do
            checkpoint(token)
            assert(os.clock() < deadline, "A previous request did not settle; cannot enter another world yet.")
            pause(0.05, token)
        end
        while true do
            checkpoint(token)
            if (r.world.name ~= name or Bridge.pickerOpen(r)) and os.clock() >= nextEntry then
                attempts = attempts + 1
                assert(attempts <= 3, "World entry repeatedly returned to the picker: " .. name)
                assert(type(r.world.enter) == "function", "The world entry hook is unavailable.")
                if options.save then options.save() end
                local queued = Movement.queueResume()
                G.setStatus("Entering " .. name .. "...")
                local entered, message, teleport = Net.bounded(r.world.enter, App.config.options.actionTimeout + 15, token, name)
                if teleport then
                    App.teleporting = true
                    G.setStatus(queued and ("Changing servers; " .. (options.label or "the task") .. " will resume after loading.")
                        or ("Changing servers. Run the loader after arrival, then use " .. (options.resumeButton or "Resume") .. "."))
                    local teleportDeadline = os.clock() + 45
                    while os.clock() < teleportDeadline do pause(0.2, token) end
                    error("Server teleport did not finish. Use " .. (options.resumeButton or "Resume") .. " after arrival.")
                end
                if not entered then assert(attempts < 3, tostring(message or "Could not enter " .. name))
                elseif r.picker and r.world.name == name then r.picker.complete() end
                nextEntry, stableSince = os.clock() + 2, nil
                deadline = os.clock() + App.config.options.actionTimeout + 15
            end
            local avatar = r.body and r.body.state()
            if r.world.name == name and not Bridge.pickerOpen(r) and avatar and avatar.active and not avatar.dead
                and not G.frozen() then
                stableSince = stableSince or os.clock()
                if os.clock() - stableSince >= (options.moving and 0 or 1) then break end
            else stableSince = nil end
            assert(os.clock() < deadline, "World or avatar did not finish loading: " .. name)
            pause(0.1, token)
        end
        App.teleporting = false
        -- World yang dimuat ulang bisa memasang tractor lagi. Copot sebelum jalan.
        Movement.suspendHarvestVehicle(token)
        Movement.takeControls()
        if not options.moving then Actions.refreshInventory(token) end
    end

    -- Error biasa saat aksi bisa jadi efek keluar world / avatar mati yang belum kelihatan
    -- (classifyPNBFault Clarissv). Tunggu 1,5 detik: kalau ternyata karena itu, ubah jadi error
    -- "recoverable" supaya task bisa masuk lagi ke world. Dipakai PNB dan Harvest.
    function Movement.classifyFault(problem, token, name)
        if type(problem) == "table" and problem.recoverable then return problem end
        if tostring(problem):find("Stopped", 1, true) then return problem end
        Movement.releaseControls()
        local deadline = os.clock() + 1.5
        repeat
            checkpoint(token)
            local r = Bridge.runtime()
            if r.world.name == "" or r.world.name == nil or Bridge.pickerOpen(r) then
                return Bridge.recoverable("Keluar ke world picker saat aksi: " .. tostring(problem), name, "worldPicker")
            end
            if r.world.name ~= name then return problem end
            local state = r.body and r.body.state()
            if state and (not state.active or state.dead) then
                return Bridge.recoverable("Avatar tidak aktif saat aksi: " .. tostring(problem), name, "avatar")
            end
            if os.clock() >= deadline then return problem end
            pause(0.1, token)
        until false
    end

    return Movement
end
