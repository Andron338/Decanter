# Decanter

A free, open-source way to run Windows games on Apple Silicon Macs. A native SwiftUI app with
no setup questions: click **Set Up** once, then drop a game's `.exe` (or its installer) on the window.

> Status: early. Tested on an M5 Max, macOS 27.2 (12 Nov 2026): setup, the DXMT overlay, the D3DMetal
> engine install, adding a game and launching it all work. One game is confirmed playable so far: a modded
> 32-bit DirectX 9 title (GTA: San Andreas) on the CrossOver engine. The DXMT and D3DMetal render paths
> are installed but not yet exercised by a real DirectX 11/12 game.

## How it works

| Step | What Decanter does |
|---|---|
| **Set Up** (once, ~235 MB) | Downloads the latest [Wine Staging build for macOS](https://github.com/Gcenx/macOS_Wine_builds) and [DXMT](https://github.com/3Shain/dxmt) (Direct3D 10/11 → Metal), verifies their SHA-256 digests, and pre-builds a template Windows environment. |
| **Drop a game** | Clones the template into a private bottle for that game (instant on APFS, no extra disk), reads the `.exe` to see whether it is 32/64-bit and which DirectX it uses, and picks the renderer to match. |
| **Drop an installer** | Recognises Inno Setup (GOG), NSIS, InstallShield, WiX and `.msi` installers from the file itself, not its name. Runs it in a fresh bottle, reads the Start menu and desktop shortcuts it created to find the game (and its name and launch arguments), and adds it to the library. If it can't tell which program is the game, it asks. |
| **Play** | Launches through Wine with the renderer chosen for that game. |

**Installing, in more detail.** The **+** menu's *Install from Installer…* runs any `.exe` as an installer
and lets you pick the engine it installs on (Wine 11, the CrossOver engine for older games, or Apple's Wine
when D3DMetal is installed). While the installer runs you can cancel it, or tell Decanter it is done if it
left a launcher or the game open. Installers get a private desktop, so no `.lnk` files land on your Mac's.
Right-click a game → **Run Patch or Installer…** runs a patch, DLC or missing component in that game's bottle.

Per-game fixes live behind right-click → **Settings…**: pick a renderer (DXMT, Apple's D3DMetal, the
CrossOver engine, or Wine 11's built-in), run in a fixed-size window
(fixes old games that crash on fullscreen mode switches), Retina rendering, MSync, Metal HUD, launch arguments.

Everything Decanter owns is in `~/Library/Application Support/Decanter`. Delete that folder to uninstall.

## Design notes

- **Two runtimes, one download.** Stock Wine searches its own DLL directory *before* `WINEDLLPATH`
  (`set_dll_path` in `dlls/ntdll/unix/loader.c`), so DXMT's builtin DLLs can't be injected by environment
  variable; they have to replace Wine's `d3d11`/`dxgi`/`d3d10core`. Decanter does that on an APFS clone of
  the runtime, so the pristine Wine stays available as a per-game fallback at almost no disk cost.
- **Detection without running anything.** Decanter parses the PE import and delay-import tables of the
  `.exe` and the DLLs beside it (engines such as Unity keep the renderer in a DLL). Packed or
  copy-protected executables hide their imports, so it falls back to DLL names found as text in the file
  and marks the result as a best guess. DirectX 10/11 → DXMT, DirectX 12 only → D3DMetal, DirectX 9 and
  older (and other 32-bit games) → CrossOver engine.
- **A third engine for older games.** Current Wine on Apple Silicon runs 32-bit code through a newer
  compatibility mode that some games don't survive (the test title crashed in three different Wine
  builds before reaching Direct3D). CodeWeavers' open-source CrossOver Wine 9, as packaged for
  [Sikarugir](https://github.com/Sikarugir-App/Engines), runs it. Decanter downloads that engine
  (about 165 MB) automatically the first time a game needs it. The archive ships without its support
  libraries, so Decanter points it at the copies in the main Wine via `DYLD_FALLBACK_LIBRARY_PATH`.
- **One bottle per game.** A broken install or a registry tweak for one game can't affect another.
- **Nothing proprietary is bundled.** Wine and DXMT are both LGPL-2.1 and are downloaded from their
  upstream releases.
- **D3DMetal is an opt-in second engine.** Apple's D3DMetal (from the Game Porting Toolkit) is proprietary
  and only works inside Apple's own, older Wine. Choosing it in a game's settings offers a separate
  ~230 MB download of the [community binary build](https://github.com/Gcenx/game-porting-toolkit) after
  you accept Apple's licence. Because that Wine can't share a prefix with Wine 11, each game gets a second
  bottle for D3DMetal the first time it's used; saves don't carry over between the two.

## What is and isn't covered

| API | Path | Notes |
|---|---|---|
| Direct3D 10 / 11 | DXMT → Metal | Default. |
| Direct3D 11 / 12 | D3DMetal → Metal | Opt-in download (Apple licence). The way to run DirectX 12 games. Optional ray tracing, DLSS-through-MetalFX and AVX switches. |
| Direct3D 9 and older, 32-bit games | CrossOver engine (Wine 9, wined3d) | Chosen automatically; downloaded on first play. Some games also need the fixed-size window option. |
| Anti-cheat (EAC, BattlEye, Vanguard) | — | Does not work under Wine on macOS, in any app. |

Wine for macOS is an x86-64 build and runs through Rosetta 2, so Rosetta must be installed.

## Build

```bash
./Scripts/bundle.sh
```

```bash
open build/Decanter.app
```

Requires Xcode 15+ (Swift 5.9+) and macOS 14+. `swift test` runs the core tests.
`swift run decanter-cli setup|d3dmetal|crossover|status|inspect|install|scan` drives the same setup and install code without the UI. `Package.swift` opens directly in Xcode.

## Layout

- `Sources/DecanterCore` — no UI: runtime setup, bottles, library, launch planning.
- `Sources/Decanter` — the SwiftUI app.
- `Sources/decanter-cli` — headless setup/status tool.
- `Scripts/try-engine.sh` — try a game on any Wine build in a throwaway bottle and report how far it got.

## Roadmap

- Real game icons extracted from the `.exe`
- D3DMetal 4 (Game Porting Toolkit 4) once a non-beta build is available
- DXVK option for Direct3D 9
- Runtime updates from inside the app
- One-click Steam / Epic / GOG launchers
- A community compatibility database with per-game presets

## Prior art

Decanter stands on [Wine](https://www.winehq.org), [Gcenx's macOS builds](https://github.com/Gcenx/macOS_Wine_builds),
[DXMT](https://github.com/3Shain/dxmt) and [MoltenVK](https://github.com/KhronosGroup/MoltenVK).
Related open-source front ends worth knowing: [Whisky](https://github.com/Whisky-App/Whisky) (archived May 2025)
and its [community fork](https://github.com/frankea/Whisky), [Sikarugir](https://github.com/Sikarugir-App/Sikarugir)
(per-game wrapper apps), and [Heroic](https://heroicgameslauncher.com) (store launcher).

## License

MIT. See [LICENSE](LICENSE).
