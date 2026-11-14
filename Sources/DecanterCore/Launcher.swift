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
        libraryFallback: String? = nil, preferredLanguages: [String] = Locale.preferredLanguages
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
            arguments = ["msiexec", "/i", windowsPath(exe)]
        } else if game.settings.virtualDesktop {
            arguments = ["explorer", "/desktop=Decanter,\(game.settings.virtualDesktopSize)", windowsPath(exe)]
        } else {
            arguments = [exe.path]
        }
        arguments += splitArguments(game.settings.arguments)
        return LaunchPlan(
            executable: runtime.wine(for: game.settings.renderer),
            arguments: arguments,
            environment: gameEnvironment(game, prefix: prefix, runtime: runtime),
            workingDirectory: workingDirectory(for: game))
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
        return environment(prefix: prefix, settings: game.settings,
                           engine: engine, quiet: quiet, libraryFallback: runtime.libraryFallback(for: engine))
    }

    /// Starts the game, streaming Wine's output to a per-game log. `onExit` fires on a background queue.
    public static func start(_ plan: LaunchPlan, log: URL, onExit: @escaping @Sendable (Int32) -> Void) throws -> Process {
        try Paths.ensure(log.deletingLastPathComponent())
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
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
