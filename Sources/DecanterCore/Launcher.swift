import CoreGraphics
import Foundation

public struct LaunchPlan: Equatable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
}

public enum Launcher {
    public static func environment(
        prefix: URL, settings: GameSettings, engine: Engine = .wine, quiet: Bool = false,
        libraryFallback: String? = nil, graphics: [String: String] = [:],
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DYLD_") && !$0.key.hasPrefix("WINE") }
        env["WINEPREFIX"] = prefix.path
        env["WINEDEBUG"] = quiet ? "-all" : "fixme-all"
        if settings.fastSync { env["WINEMSYNC"] = "1" }
        if settings.performanceHUD { env["MTL_HUD_ENABLED"] = "1" }
        if let libraryFallback { env["DYLD_FALLBACK_LIBRARY_PATH"] = libraryFallback }
        // LC_ALL is the one variable every engine reads its Windows language (and codepage) from;
        // Apple's and CrossOver's older Wine ignore LC_CTYPE on its own.
        if let language = WindowsLanguage.resolve(settings.language, preferred: preferredLanguages) {
            env["LC_ALL"] = language.locale + ".UTF-8"
        }
        if engine == .gptk {
            // Apple's Wine predates MSync in some builds; ESync is what Apple's own instructions use.
            if settings.fastSync { env["WINEESYNC"] = "1" }
            if settings.rayTracing { env["D3DM_SUPPORT_DXR"] = "1" }
            if settings.metalFX { env["D3DM_ENABLE_METALFX"] = "1" }
            if settings.advertiseAVX { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        }
        env.merge(graphics) { _, new in new }
        let overrides = settings.dllOverrides.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overrides.isEmpty { env["WINEDLLOVERRIDES"] = overrides }
        // The user's own variables go last so they can override anything above except the prefix.
        for (name, value) in parseEnvironment(settings.environment) where name != "WINEPREFIX" {
            env[name] = value
        }
        return env
    }

    /// Reads `NAME=value` lines. Blank lines, `#` comments and lines without a valid name are skipped.
    public static func parseEnvironment(_ text: String) -> [(name: String, value: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { return nil }
            let name = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
                return nil
            }
            return (name, String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// `prefix` is the game's bottle's prefix for the engine its renderer runs on.
    public static func plan(game: Game, prefix: URL, runtime: InstalledRuntime) -> LaunchPlan {
        let exe = URL(fileURLWithPath: game.executablePath)
        var arguments: [String]
        if exe.pathExtension.lowercased() == "msi" {
            arguments = ["msiexec", "/i", windowsPath(exe, prefix: prefix)]
        } else if game.settings.virtualDesktop && !game.settings.scaledFullscreen {
            arguments = ["explorer", "/desktop=\(desktopName),\(desktopSize(game.settings))", windowsPath(exe, prefix: prefix)]
        } else {
            // A program in the bottle goes by its C: path; Wine takes a Mac path for anything else.
            arguments = [cDrivePath(exe, prefix: prefix) ?? exe.path]
        }
        arguments += splitArguments(game.settings.arguments)
        return LaunchPlan(
            executable: runtime.wine(for: game.settings.renderer),
            arguments: arguments,
            environment: gameEnvironment(game, prefix: prefix, runtime: runtime),
            workingDirectory: workingDirectory(for: game))
    }

    /// The `virtualDesktopSize` that means "as large as the Mac's main screen".
    public static let screenSizedDesktop = "screen"

    /// The size of the fixed window's Windows desktop. It is also the largest resolution the game
    /// can pick: the window then shrinks to whatever the game chose.
    static func desktopSize(_ settings: GameSettings, screen: (width: Int, height: Int)? = nil) -> String {
        guard settings.virtualDesktopSize == screenSizedDesktop else { return settings.virtualDesktopSize }
        guard let screen = screen ?? mainScreenSize(retina: settings.retina) else { return GameSettings().virtualDesktopSize }
        return "\(screen.width)x\(screen.height)"
    }

    /// In Retina mode Wine counts the screen's real pixels, otherwise its points.
    static func mainScreenSize(retina: Bool) -> (width: Int, height: Int)? {
        guard let mode = CGDisplayCopyDisplayMode(CGMainDisplayID()), mode.width > 0, mode.height > 0 else { return nil }
        return retina ? (mode.pixelWidth, mode.pixelHeight) : (mode.width, mode.height)
    }

    static func workingDirectory(for game: Game) -> URL {
        let custom = game.settings.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        if !custom.isEmpty, FileManager.default.fileExists(atPath: custom, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return URL(fileURLWithPath: game.executablePath).deletingLastPathComponent()
    }

    static func gameEnvironment(
        _ game: Game, prefix: URL, runtime: InstalledRuntime, quiet: Bool = false
    ) -> [String: String] {
        let engine = runtime.engine(for: game.settings.renderer)
        let graphics = engine == .sikarugir ? runtime.wine10Environment(wine10Graphics(for: game)) : [:]
        return environment(prefix: prefix, settings: game.settings, engine: engine, quiet: quiet,
                           libraryFallback: runtime.libraryFallback(for: engine), graphics: graphics)
    }

    /// The Wine 10 routing a game runs with, `.automatic` worked out from what it was detected to use.
    public static func wine10Graphics(for game: Game) -> Wine10Graphics {
        game.settings.wine10Graphics.resolved(for: game.requirements)
    }

    /// Every program in a Wine prefix inherits the environment of the one that started the prefix's
    /// processes, so a game started through an already-running Steam gets Steam's routing, not its own.
    /// This file remembers which routing a prefix's processes were started with.
    static func routingMarker(for prefix: URL) -> URL {
        prefix.deletingLastPathComponent().appendingPathComponent("wine10-graphics")
    }

    public static func runningRouting(in prefix: URL) -> Wine10Graphics? {
        (try? String(contentsOf: routingMarker(for: prefix), encoding: .utf8)).flatMap(Wine10Graphics.init(rawValue:))
    }

    public static func recordRouting(_ graphics: Wine10Graphics, in prefix: URL) {
        try? graphics.rawValue.write(to: routingMarker(for: prefix), atomically: true, encoding: .utf8)
    }

    /// Asks the Steam client in a prefix to quit, waits up to `timeout` for everything there to end,
    /// then ends whatever is left.
    public static func shutDownSteam(_ client: URL, prefix: URL, runtime: InstalledRuntime, timeout: Duration = .seconds(30)) async {
        let engine = Engine.sikarugir
        let env = environment(prefix: prefix, settings: GameSettings(), engine: engine, quiet: true,
                              libraryFallback: runtime.libraryFallback(for: engine))
        _ = try? await Shell.run(runtime.wine(for: .sikarugir), [client.path, "-shutdown"], environment: env, check: false)
        let wineserver = runtime.wineserver(for: .sikarugir)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await Shell.run(wineserver, ["-w"], environment: env, check: false) }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
        await stop(prefix: prefix, engine: engine, runtime: runtime)
    }

    /// Starts the game, streaming Wine's output to a per-game log. `onExit` fires on a background queue.
    public static func start(_ plan: LaunchPlan, log: URL, onExit: @escaping @Sendable (Int32) -> Void) throws -> Process {
        try Paths.ensure(log.deletingLastPathComponent())
        let handle = try appendingHandle(for: log)
        let stamp = "--- \(ISO8601DateFormatter().string(from: Date())) \(plan.arguments.joined(separator: " ")) ---\n"
        handle.write(Data(stamp.utf8))
        let process = Process()
        process.executableURL = plan.executable
        process.arguments = plan.arguments
        process.environment = plan.environment
        process.currentDirectoryURL = plan.workingDirectory
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { finished in
            try? handle.close()
            onExit(finished.terminationStatus)
        }
        try process.run()
        return process
    }

    /// Above this a log starts over instead of growing.
    static let logLimit = 4 << 20

    /// Opens a log so that each launch adds to it. Starting it over would lose what an earlier
    /// launch is still writing: a game started through Steam logs to whichever launch started Steam,
    /// which is still running when the next game is started.
    static func appendingHandle(for log: URL) throws -> FileHandle {
        let descriptor = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { throw DecanterError("Couldn't open the log at \(log.path).") }
        var info = stat()
        if fstat(descriptor, &info) == 0, info.st_size > logLimit { ftruncate(descriptor, 0) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Runs something in a bottle and waits until every Windows process in it has exited.
    public static func runAndWait(_ plan: LaunchPlan, runtime: InstalledRuntime, renderer: Renderer) async throws {
        try await Shell.run(plan.executable, plan.arguments, environment: plan.environment,
                            cwd: plan.workingDirectory, check: false)
        try await Shell.run(runtime.wineserver(for: renderer), ["-w"], environment: plan.environment, check: false)
    }

    /// Ends every Windows process in a prefix: the game, and anything else running beside it there.
    public static func stop(prefix: URL, engine: Engine, runtime: InstalledRuntime) async {
        let env = environment(prefix: prefix, settings: GameSettings(), engine: engine, quiet: true,
                              libraryFallback: runtime.libraryFallback(for: engine))
        _ = try? await Shell.run(runtime.wineserver(for: GameInstaller.renderer(for: engine)), ["-k"],
                                 environment: env, check: false)
    }

    /// Ends everything running in a bottle, on every engine it has been used with.
    public static func stop(_ bottle: Bottle, runtime: InstalledRuntime) async {
        for engine in bottle.engines where runtime.has(engine) {
            if let prefix = bottle.prefix(for: engine) { await stop(prefix: prefix, engine: engine, runtime: runtime) }
        }
    }

    /// Applies settings that live in the Windows registry rather than the environment. Games sharing
    /// a bottle share its registry, so this runs before each launch and only when the value differs.
    public static func applyRegistrySettings(game: Game, prefix: URL, runtime: InstalledRuntime) async {
        let marker = prefix.deletingLastPathComponent().appendingPathComponent("retina")
        let wanted = game.settings.retina ? "y" : "n"
        let current = (try? String(contentsOf: marker, encoding: .utf8)) ?? "n"
        guard wanted != current else { return }
        let result = try? await Shell.run(
            runtime.wine(for: game.settings.renderer),
            ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/d", wanted, "/f"],
            environment: gameEnvironment(game, prefix: prefix, runtime: runtime, quiet: true), check: false)
        if result?.status == 0 { try? wanted.write(to: marker, atomically: true, encoding: .utf8) }
    }

    /// The fixed-size window for a game Steam starts. `explorer /desktop=…` only reaches the program
    /// it starts, and Steam starts its games itself, usually from a Steam already running outside any
    /// window. They then see every mode the Mac has (hundreds, none of the classic ones), which
    /// crashes games such as GTA: Vice City at startup. Wine also reads a desktop for the whole prefix
    /// from the registry each time a program starts, so this sets that before the launch and clears
    /// it again for the next launch that doesn't want it.
    public static func applySteamDesktop(game: Game, prefix: URL, runtime: InstalledRuntime) async {
        let settings = game.settings
        let wanted = steamDesktop(for: game) ?? ""
        let marker = steamDesktopMarker(for: prefix)
        let current = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        guard wanted != current else { return }
        let env = gameEnvironment(game, prefix: prefix, runtime: runtime, quiet: true)
        let wine = runtime.wine(for: settings.renderer)
        let reg = { (arguments: [String]) async -> Int32? in
            try? await Shell.run(wine, ["reg"] + arguments, environment: env, check: false).status
        }
        if wanted.isEmpty {
            // Fails harmlessly when the value isn't there.
            _ = await reg(["delete", #"HKCU\Software\Wine\Explorer"#, "/v", "Desktop", "/f"])
        } else {
            guard await reg(["add", #"HKCU\Software\Wine\Explorer\Desktops"#, "/v", desktopName, "/d", wanted, "/f"]) == 0,
                  await reg(["add", #"HKCU\Software\Wine\Explorer"#, "/v", "Desktop", "/d", desktopName, "/f"]) == 0
            else { return }
        }
        try? wanted.write(to: marker, atomically: true, encoding: .utf8)
    }

    /// The fixed-size window's size for the whole prefix while `game` runs, or nil for none.
    static func steamDesktop(for game: Game, screen: (width: Int, height: Int)? = nil) -> String? {
        let settings = game.settings
        guard startsThroughSteam(game), settings.virtualDesktop, !settings.scaledFullscreen else { return nil }
        return desktopSize(settings, screen: screen)
    }

    /// A game Steam starts: added from Steam's library, or `steam.exe -applaunch <id>` set up by hand.
    public static func startsThroughSteam(_ game: Game) -> Bool {
        if game.steamAppID != nil { return true }
        let isSteam = URL(fileURLWithPath: game.executablePath).lastPathComponent.lowercased() == "steam.exe"
        return isSteam && splitArguments(game.settings.arguments).contains { $0.lowercased() == "-applaunch" }
    }

    /// The name `explorer /desktop=` and the registry give Decanter's fixed-size window.
    static let desktopName = "Decanter"

    static func steamDesktopMarker(for prefix: URL) -> URL {
        prefix.deletingLastPathComponent().appendingPathComponent("steam-desktop")
    }

    /// A program inside the prefix by its C: path, so that it and whatever it starts see short paths.
    /// Through Z: the same file is `Z:\Users\…\Application Support\Decanter\Bottles\…\drive_c\…`,
    /// and older games keep their own folder in a fixed-size buffer: GTA: Vice City's holds 128
    /// characters, comes back empty for a Steam game there, and the game then can't find its files.
    static func cDrivePath(_ url: URL, prefix: URL) -> String? {
        let drive = prefix.appendingPathComponent("drive_c").standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(drive) else { return nil }
        return "C:\\" + path.dropFirst(drive.count).replacingOccurrences(of: "/", with: "\\")
    }

    /// `windowsPath(_:)`, but by its C: path when the file is inside `prefix`.
    public static func windowsPath(_ url: URL, prefix: URL) -> String {
        cDrivePath(url, prefix: prefix) ?? windowsPath(url)
    }

    /// `/Users/me/Game/a.exe` → `Z:\Users\me\Game\a.exe` (Wine maps Z: to the Mac's root).
    public static func windowsPath(_ url: URL) -> String {
        "Z:" + url.path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Splits on whitespace, honouring double quotes.
    public static func splitArguments(_ string: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quoted = false
        var hasToken = false
        for character in string {
            if character == "\"" {
                quoted.toggle()
                hasToken = true
            } else if character == "\0" {
                // Shortcuts written by some installers carry stray NULs; an argument can't hold one.
                continue
            } else if character.isWhitespace && !quoted {
                if hasToken { result.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        if hasToken { result.append(current) }
        return result
    }
}
