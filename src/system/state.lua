-- state.lua: semua yang disimpan ke file. Folder dipisah per akun Roblox.
-- Diadaptasi dari Clarissv main.lua (writeJSON yang aman, session, checkpoint resume).
return function(G)
    local App, Core, fs, json = G.App, G.Core, G.fs, G.json
    local State = {}

    State.ROOT = "GrowbloxHansel/accounts/" .. tostring(G.accountId)
    State.PROFILE_DIR = State.ROOT .. "/profiles"
    local SESSION = State.ROOT .. "/session.json"

    local function exists(path) return type(fs.isfile) == "function" and fs.isfile(path) == true end
    State.exists = exists

    local function folders()
        assert(G.accountOk(), "Akun Roblox berubah. Reload script.")
        assert(type(fs.readfile) == "function" and type(fs.writefile) == "function"
            and type(fs.isfolder) == "function" and type(fs.makefolder) == "function",
            "Executor tidak punya readfile/writefile/makefolder.")
        local path = ""
        for part in State.PROFILE_DIR:gmatch("[^/]+") do
            path = path == "" and part or path .. "/" .. part
            if not fs.isfolder(path) then fs.makefolder(path) end
        end
    end

    function State.readJSON(path)
        if not exists(path) then return nil end
        local ok, value = pcall(json.decode, fs.readfile(path))
        assert(ok and type(value) == "table", "File rusak: " .. path)
        return value
    end

    -- Tulis aman: tulis ke .pending dulu dan cek, simpan versi lama ke .bak, baru timpa file asli.
    -- Kalau executor crash di tengah, minimal salah satu versi masih utuh.
    function State.writeJSON(path, value)
        folders()
        local text = json.encode(value)
        local staged = path .. ".pending"
        fs.writefile(staged, text)
        assert(fs.readfile(staged) == text, "Gagal verifikasi file yang disimpan.")
        if exists(path) then fs.writefile(path .. ".bak", fs.readfile(path)) end
        fs.writefile(path, text)
        assert(fs.readfile(path) == text, "Gagal menyimpan. Versi lama ada di .bak.")
        if type(fs.delfile) == "function" then pcall(fs.delfile, staged) end
    end

    -- Session = config + profil yang lagi dipakai. Dipulihkan otomatis saat script dimuat.
    function State.saveSession()
        local config, profile = Core.validate(App.config), Core.profileName(App.profile)
        local signature = json.encode({ config = config, profile = profile })
        if signature == App.sessionSignature then return false end -- tidak ada perubahan
        State.writeJSON(SESSION, { version = 1, userId = G.accountId, config = config, profile = profile })
        App.sessionSignature = signature
        return true
    end
    function State.restoreSession()
        local record = State.readJSON(SESSION)
        if not record then return false end
        assert(record.version == 1 and record.userId == G.accountId, "Session milik akun lain atau versi lain.")
        App.config, App.profile = Core.validate(record.config), Core.profileName(record.profile)
        return true
    end

    function State.saveProfile(name)
        name = Core.profileName(name)
        State.writeJSON(State.PROFILE_DIR .. "/" .. name .. ".json", Core.validate(App.config))
        App.profile = name
        return name
    end
    function State.loadProfile(name)
        name = Core.profileName(name)
        local record = State.readJSON(State.PROFILE_DIR .. "/" .. name .. ".json")
        assert(record, "Profil tidak ditemukan: " .. name)
        App.config, App.profile = Core.validate(record), name
        return name
    end

    -- Checkpoint task (buat resume setelah pindah server). Satu file per task.
    -- maxAge: checkpoint yang lebih tua dari ini dianggap basi (isi tas/box bisa sudah berubah).
    function State.saveCheckpoint(name, data)
        State.writeJSON(State.ROOT .. "/" .. name .. "-resume.json", { version = 1, active = true,
            userId = G.accountId, updatedAt = os.time(), config = Core.validate(App.config),
            profile = App.profile, data = data })
    end
    function State.loadCheckpoint(name, maxAge)
        local record = State.readJSON(State.ROOT .. "/" .. name .. "-resume.json")
        if not record or not record.active then return nil end
        assert(record.version == 1 and record.userId == G.accountId, "Checkpoint " .. name .. " milik akun lain.")
        assert(Core.finite(record.updatedAt) and os.time() - record.updatedAt < (maxAge or 21600),
            "Checkpoint " .. name .. " sudah basi. Cek tas dan box, lalu mulai ulang.")
        record.config = Core.validate(record.config)
        return record
    end
    function State.clearCheckpoint(name)
        local path = State.ROOT .. "/" .. name .. "-resume.json"
        if not exists(path) then return end
        if type(fs.delfile) == "function" then fs.delfile(path)
        else State.writeJSON(path, { version = 1, active = false }) end
    end

    return State
end
