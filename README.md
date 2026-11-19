# Decanter

A free, open-source way to run Windows games on Apple Silicon Macs. A native SwiftUI app with
no setup questions: click **Set Up** once, then drop a game's `.exe` (or its installer) on the window.

> Status: early. Tested on an M5 Max, macOS 27.2 (15 Nov 2026): setup, the DXMT overlay, the D3DMetal
> engine install, adding a game and launching it all work. Confirmed so far: a modded 32-bit DirectX 9
> title (GTA: San Andreas) is playable on the CrossOver engine, a DirectX 11 game (Rise of Nations:
> Extended Edition) reaches its menu through Steam on DXMT, and a DirectX 12-only game (S.T.A.L.K.E.R. 2)
> starts through Steam on D3DMetal. D3DMetal on Apple's own Wine, outside Steam, has not been exercised
> by a real game yet.

## How it works

| Step | What Decanter does |
|---|---|
| **Set Up** (once, ~235 MB) | Downloads the tested [Wine Staging build for macOS](https://github.com/Gcenx/macOS_Wine_builds) and [DXMT](https://github.com/3Shain/dxmt) (Direct3D 10/11 → Metal), checks them against the SHA-256 checksums recorded in Decanter, and pre-builds a template Windows environment. |
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
fixes does both. Games started from Steam run on Steam's engine, which covers every DirectX version (see
*One engine for DirectX 9 to 12* below). Confirmed so far: signing in, downloading, a DirectX 11 game
(Rise of Nations: Extended Edition) reaching its menu, and a DirectX 12-only game (S.T.A.L.K.E.R. 2)
starting on D3DMetal. Before a Steam game starts, Decanter installs Microsoft's Visual C++ 2015-2022
runtime into its prefix if it is missing, because Unreal's launcher checks for it and refuses Wine's own
copies.

**Steam games.** Decanter reads the Steam client's own files in each bottle (`steamapps/appmanifest_*.acf`,
in every library folder) and, when Steam has finished downloading a game the library lacks, offers it in a
banner above the library: *Add*, *Choose…* or dismiss. A game added this way is started through Steam
(`steam.exe -applaunch <id>` in Steam's bottle), shows the cover Steam already downloaded, and falls back
to the icon of the game's own program rather than Steam's. Dismissed or removed games aren't offered again
until **+ → Find Steam Games**.

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
MSync, mod loaders (Wine uses a loader such as Ultimate ASI Loader from the game folder instead of its
own DLL, set per program in the bottle's registry so it also works when Steam starts the game; automatic when
`.asi` mods are present), DLL overrides, environment variables, and Wine's own configuration and registry
editor.

**Scaled fullscreen.** A Mac's screen only offers its own resolutions, so a game that asks for 800x600 or
1024x768 is refused and ends up in a small window. With *Scaled fullscreen* on in a game's *Graphics*
settings, Decanter puts a virtual screen that has those resolutions in charge while the game runs and makes
the real screen mirror it: the game goes fullscreen as it would on a PC, and macOS scales the picture to
the whole screen, with black bars where the shape differs. The Mac's screen is back to normal when the game
quits (or if Decanter does). Everything looks softer meanwhile, because the virtual screen isn't Retina.
Virtual screens come from an undocumented part of macOS, the one display utilities use. Confirmed so far
with Need for Speed Carbon on the CrossOver engine. The refusals don't depend on the engine: Wine 11,
CrossOver's Wine 9, Wine 10 and Apple's Wine all list exactly the modes macOS offers and all turn down
640x480, 800x600, 1024x768 and 1280x720 on a MacBook screen.

Everything Decanter owns is in `~/Library/Application Support/Decanter`. Delete that folder to uninstall.

## Design notes

- **Two runtimes, one download.** Stock Wine searches its own DLL directory *before* `WINEDLLPATH`
  (`set_dll_path` in `dlls/ntdll/unix/loader.c`), so DXMT's builtin DLLs can't be injected by environment
  variable; they have to replace Wine's `d3d11`/`dxgi`/`d3d10core`. Decanter does that on an APFS clone of
  the runtime, so the pristine Wine stays available as a per-game fallback at almost no disk cost.
- **One engine for DirectX 9 to 12.** The Wine 10 engine is CrossOver-based, and its loader searches one
  folder per graphics backend (`WINEDLLPATH_DXMT`, `WINEDLLPATH_D9VK`, …) *before* its own DLLs, picked by
  environment variable for each process. So nothing is copied into the engine: per game, Direct3D 10/11
  goes to DXMT, Direct3D 12 to Apple's D3DMetal (`WINEDLLPATH_D3DMETAL`, from the Game Porting Toolkit
  download) or to Wine's own vkd3d on MoltenVK, and Direct3D 9 stays on Wine's own renderer. The engine
  finds the main Wine's Vulkan loader, which hides MoltenVK from it, so Decanter links MoltenVK in the
  loader's place, as CrossOver does. One limit: Direct3D 12 needs a DXGI other than DXMT's, so a game
  gets either DXMT's 10/11 or Direct3D 12. *Automatic* picks D3DMetal for games that require Direct3D 12
  (they ship the D3D12 Agility SDK), DXMT for Direct3D 10/11, vkd3d for other games that use Direct3D 12
  alone, and Wine's own renderer for Direct3D 9 and older, which keeps DXMT's DXGI away from Steam's
  overlay in old games (GTA: Vice City hangs with it). vkd3d also stands in for D3DMetal until that is
  installed, but it is the weaker route: it could not create a device for S.T.A.L.K.E.R. 2 ("Metal does
  not support buffer robustness"), and no game has been confirmed on it. Steam's games inherit Steam's environment, so when a
  library game needs the other choice and Steam is running, Decanter asks Steam to quit and starts it again.
  Tried and left out (Nov 2026): DXVK for Direct3D 9 (Gcenx's 2023 macOS build can't create a device on
  current MoltenVK; Sikarugir's 2025 d9vk draws GTA: San Andreas wrongly even on CrossOver's patched
  MoltenVK), DXVK 3.x and vkd3d-proton on Mesa's KosmicKrisp Metal driver (refused for missing wireframe
  fill and transform feedback), and moving Steam to Apple's own Wine for D3DMetal (the Steam client
  crashes there at startup).
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
  and ships with Apple's own, older Wine. Choosing it in a game's settings offers a separate
  ~230 MB download of the [community binary build](https://github.com/Gcenx/game-porting-toolkit) after
  you accept Apple's licence. Because that Wine can't share a prefix with Wine 11, a bottle gets a second
  prefix for D3DMetal the first time it's used; saves don't carry over between the two. Steam games are
  the exception: the Wine 10 engine loads the same D3DMetal files itself, so they stay in Steam's prefix.

## What is and isn't covered

| API | Path | Notes |
|---|---|---|
| Direct3D 10 / 11 | DXMT → Metal | Default. |
| Direct3D 11 / 12 | D3DMetal → Metal | Opt-in download (Apple licence). The way to run DirectX 12 games. Optional ray tracing, DLSS-through-MetalFX and AVX switches. |
| Direct3D 9 and older, 32-bit games | CrossOver engine (Wine 9, wined3d) | Chosen automatically; downloaded on first play. Some games also need the fixed-size window option. |
| Direct3D 9 / 10 / 11 / 12 | Wine 10 engine: wined3d, DXMT, D3DMetal or vkd3d → Metal | The Steam engine. DXMT by default; D3DMetal for games that require Direct3D 12 (S.T.A.L.K.E.R. 2 starts this way), with vkd3d as the fallback until D3DMetal is installed. |
| Anti-cheat (EAC, BattlEye, Vanguard) | — | Does not work under Wine on macOS, in any app. |

Wine for macOS is an x86-64 build and runs through Rosetta 2. If Rosetta isn't installed, setup installs it first through Software Update (the setup screen says so, since that agrees to Apple's Rosetta 2 license), asking for an administrator password only if Software Update needs one.

On Apple silicon with macOS 15 or later, setup without Rosetta also offers an experimental alternative: [MetalSharp Wine](https://github.com/metalsharp/MetalSharp-Wine), an early-access arm64 Wine 11.20 that runs Intel programs through FEX (about 1.3 GB). With it every game runs on that one Wine, which picks the Direct3D route itself; CrossOver, the Steam engine and D3DMetal are Intel programs and aren't used. If Rosetta 2 goes away after an Intel setup (macOS 28 drops most of it), Decanter returns to the setup screen with both choices.

**Settings › Runtimes** lists every engine with its installed version: optional engines can be installed, updated to the tested build and removed there, and the main Wine can be switched between the Rosetta and Rosetta-free kinds.

## Build

```bash
./Scripts/bundle.sh
```

```bash
open build/Decanter.app
```

Requires Xcode 15+ (Swift 5.9+) and macOS 14+. `swift test` runs the core tests.
`swift run decanter-cli setup|d3dmetal|crossover|status|inspect|install|scan` drives the same setup and install code without the UI. `Package.swift` opens directly in Xcode.

**Engine versions.** Wine, DXMT, the Game Porting Toolkit and both engines are pinned in
`EngineBuilds` (`Sources/DecanterCore/Runtime.swift`): exact file names and SHA-256 checksums of
builds tried with real games. A bad upstream release can't break setup, and every install of one
Decanter version gets the same files. To move to a newer build, try it first (*Settings → Download
the newest engine builds*, or `DECANTER_NEWEST_ENGINES=1` for `decanter-cli`), then update its pin.

## CI and releases (local)

There is no hosted CI: these scripts run on your Mac.

```bash
git config core.hooksPath .githooks   # once: build and test before every push
```

```bash
./Scripts/ci.sh            # build, test, bundle, verify the signature, zip into dist/
```

```bash
./Scripts/release.sh 0.2.0 --dry-run   # everything except tagging and publishing
```

```bash
./Scripts/release.sh 0.2.0             # CI, tag v0.2.0, push, publish a GitHub release with the zip
```

Releases come from `master` with a clean tree (`--prerelease` allows any branch). Publishing needs
the GitHub CLI, signed in once: `brew install gh && gh auth login`. The release notes list the commits
since the previous tag. Builds are ad-hoc signed, not notarized, so downloaders have to clear the
quarantine flag; the notes say how.

## Layout

- `Sources/DecanterCore` — no UI: runtime setup, bottles, library, launch planning.
- `Sources/Decanter` — the SwiftUI app.
- `Sources/decanter-cli` — headless setup/status tool.
- `Scripts/try-engine.sh` — try a game on any Wine build in a throwaway bottle and report how far it got.

## Roadmap

- DXVK for Direct3D 9 once MoltenVK or KosmicKrisp can run it
- Real game icons extracted from the `.exe`
- D3DMetal 4 (Game Porting Toolkit 4) once a non-beta build is available
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
