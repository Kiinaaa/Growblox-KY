# Growblox KY

Yang dijalankan di executor hanya loader:

    loadstring(game:HttpGet("https://raw.githubusercontent.com/kiinaaa/Growblox-KY/main/loader.lua"))()

## Struktur
    loader.lua          satu-satunya file yang dijalankan (unduh manifest + semua modul, lalu jalankan main)
    manifest.lua        daftar modul + urutan muat + versi
    src/
      main.lua          titik masuk: rangkai modul, connect ke game, heartbeat
      core/             logika murni: core.lua, navigation.lua
      system/           net.lua, state.lua, bridge.lua
      game/             actions.lua, movement.lua, storage.lua, drops.lua, scan.lua
      jobs/             jobs.lua
      ui/               ui.lua
      features/         pnb.lua, harvest.lua, rotation.lua, autocollect.lua

## Pasang
1. Buat repo GitHub (public), upload isi folder ini apa adanya (loader.lua di root, folder src/).
2. Di loader.lua ganti USERNAME/REPO pada baris BASE.
3. Jalankan baris loadstring di atas dengan URL loader.lua kamu.

## Tambah modul baru
Taruh file di src/<folder>/nama.lua, tambah satu baris di manifest.lua, dan pasang di src/main.lua
(`G.Nama = modules.nama(G)`). Naikkan `version` di manifest.lua tiap rilis.

## Mode dev (tanpa internet)
Taruh folder ini di workspace executor, lalu sebelum loader:
    getgenv().GrowbloxHanselDevPath = "GrowbloxHansel"
