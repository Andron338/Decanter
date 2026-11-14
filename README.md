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
| **Drop a game** | Puts it in the default bottle (a Windows environment cloned from the template: instant on APFS, no extra disk), reads the `.exe` to see whether it is 32/64-bit and which DirectX it uses, and picks the renderer to match. |
| **Drop an installer** | Recognises Inno Setup (GOG), NSIS, InstallShield, WiX and `.msi` installers from the file itself, not its name. Runs it in the default bottle, where it can see the games already installed there, reads the Start menu and desktop shortcuts it added to find the game (and its name and launch arguments), and adds it to the library. If it can't tell which program is the game, it asks. |
| **Play** | Launches through Wine with the renderer chosen for that game. |

**Installing, in more detail.** The **+** menu's *Install from Installer…* runs any `.exe` as an installer
and lets you pick the engine it installs on (Wine 11, the CrossOver engine for older games, or Apple's Wine
when D3DMetal is installed). While the installer runs you can cancel it, or tell Decanter it is done if it
left a launcher or the game open. Installers get a private desktop, so no `.lnk` files land on your Mac's.
Right-click a game → **Run Patch or Installer…** runs a patch, DLC or missing component in that game's bottle.
*Install Steam…* downloads Valve's own installer for the Windows Steam client (about 2 MB, from Steam's
servers) and runs it the same way, offering a bottle named Steam on the one engine the Steam client runs
on: Sikarugir's Wine 10 (about 160 MB, fetched the first time). Stock Wine 11 can't draw Steam's window and
CrossOver's Wine 9 can't complete Steam's internal connection on current macOS; Wine 10 with CrossOver's
fixes does both. Games started from Steam run on Steam's engine, so it gets the same DXMT overlay as the
main Wine for DirectX 10/11. Confirmed so far: signing in, downloading, and a DirectX 11 game (Rise of
Nations: Extended Edition) reaching its menu.

**Bottles.** A bottle is a named Windows environment that any number of games share, so patches, add-ons
and multi-disc installers find what is already installed. Everything goes in the default bottle unless you
pick another in the install sheet. **+ → Manage Bottles…** creates, renames and deletes bottles, sets the
default, opens each one's C: drive and Wine tools, and adds a program that is already in a bottle to the
library. The sidebar lists bottles too, and a game's bottle can be changed under Configure → Game Options.

**The library.** Games show as covers or as a list (name, renderer, last played, play time), with a
sidebar for Recent, Favorites and each renderer, search, sorting and a cover-size slider. Select a game
and the bar along the bottom has Play, Configure and everything else that right-click offers.

**Covers.** When a game is added, Decanter looks its name up once in the Steam store (a public search, no
account) and uses the cover if the title clearly matches. Nothing but the name is sent, and
*Decanter → Settings…* turns this off. You can also drop an image on a game, choose one, or pick from
search results under right-click → **Cover**. Games without a cover show the icon from their `.exe`.

Per-game settings live behind **Configure…**, in four tabs. *Game Info*: name, cover, favorite, play
time and what was detected. *Game Options*: the program, launch arguments and working folder. *Graphics*:
the renderer (DXMT, Apple's D3DMetal, the CrossOver engine, or Wine 11's built-in), a fixed-size window
(fixes old games that crash on fullscreen mode switches), Retina rendering and the Metal HUD. *System*:
MSync, DLL overrides (for mod loaders), environment variables, and Wine's own configuration and registry
editor.

**Scaled fullscreen.** A Mac's screen only offers its own resolutions, so a game that asks for 800x600 or
1024x768 is refused and ends up in a small window. With *Scaled fullscreen* on in a game's *Graphics*
settings, Decanter puts a virtual screen that has those resolutions in charge while the game runs and makes
the real screen mirror it: the game goes fullscreen as it would on a PC, and macOS scales the picture to
the whole screen, with black bars where the shape differs. The Mac's screen is back to normal when the game
quits (or if Decanter does). Everything looks softer meanwhile, because the virtual screen isn't Retina.
Virtual screens come from an undocumented part of macOS, the one display utilities use. Confirmed so far
with Need for Speed Carbon on the CrossOver engine.

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
- **Shared bottles, a prefix per engine.** Games in a bottle share one Windows environment; make a
  separate bottle for a game that needs isolating. Inside a bottle each engine has its own Wine prefix,
  made on first use, because a prefix can't move between Wine versions. An installer therefore only sees
  what was installed with the same engine, and Decanter runs the next installer on the engine the last one used.
- **Nothing proprietary is bundled.** Wine and DXMT are both LGPL-2.1 and are downloaded from their
  upstream releases.
- **D3DMetal is an opt-in second engine.** Apple's D3DMetal (from the Game Porting Toolkit) is proprietary
  and only works inside Apple's own, older Wine. Choosing it in a game's settings offers a separate
  ~230 MB download of the [community binary build](https://github.com/Gcenx/game-porting-toolkit) after
  you accept Apple's licence. Because that Wine can't share a prefix with Wine 11, a bottle gets a second
  prefix for D3DMetal the first time it's used; saves don't carry over between the two.

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
