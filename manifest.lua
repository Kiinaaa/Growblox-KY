-- manifest.lua: daftar modul + urutan muat. Tambah file baru = cukup tambah satu baris di sini.
-- Format tiap baris: { nama modul, path file di repo }.
return {
    version = "0.9.9",
    modules = {
        -- core: logika murni, tidak menyentuh game
        { "core",        "src/core/core.lua" },
        { "navigation",  "src/core/navigation.lua" },
        -- system: token Stop, request, simpan setting, jembatan ke game
        { "net",         "src/system/net.lua" },
        { "state",       "src/system/state.lua" },
        { "bridge",      "src/system/bridge.lua" },
        -- game: aksi dasar (tas, jalan, box, pungut drop, scan world)
        { "actions",     "src/game/actions.lua" },
        { "movement",    "src/game/movement.lua" },
        { "storage",     "src/game/storage.lua" },
        { "drops",       "src/game/drops.lua" },
        { "scan",        "src/game/scan.lua" },
        -- jobs + ui
        { "jobs",        "src/jobs/jobs.lua" },
        { "ui",          "src/ui/ui.lua" },
        -- features: fitur yang bisa dijalankan user
        { "pnb",         "src/features/pnb.lua" },
        { "harvest",     "src/features/harvest.lua" },
        { "rotation",    "src/features/rotation.lua" },
        { "autocollect", "src/features/autocollect.lua" },
        -- titik masuk (paling akhir)
        { "main",        "src/main.lua" },
    },
}
