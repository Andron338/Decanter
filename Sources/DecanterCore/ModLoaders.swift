import Foundation

/// Whether Wine should use the mod loader a game folder holds in place of its own DLL.
public enum ModLoaderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// On when the folder holds both a DLL a mod loader poses as and `.asi` mods for it to load.
    case automatic
    case on
    case off

    public var id: String { rawValue }
}

/// Mod loaders such as Ultimate ASI Loader pose as a DLL the game loads anyway (`d3d8.dll`,
/// `dinput8.dll`…) and pass the calls on to the real one. Wine prefers its own copy of those DLLs,
/// so the loader, and every mod it would load, is skipped unless the program is told otherwise.
///
/// `WINEDLLOVERRIDES` can't do that for a game Steam starts: it only reaches programs Decanter
/// starts. Wine also reads overrides per program name from the registry
/// (`HKCU\Software\Wine\AppDefaults\<program>\DllOverrides`), whoever starts it, so they go there.
public enum ModLoaders {
    /// DLLs Wine has its own copy of that loaders and wrappers are commonly named after. A DLL Wine
    /// lacks (`vorbisFile.dll`, say) is loaded from the game folder anyway and needs nothing.
    static let proxyNames: Set<String> = [
        "d3d8", "d3d9", "d3d10", "d3d11", "dxgi", "ddraw", "dinput", "dinput8", "dsound", "winmm",
        "version", "wininet", "winhttp", "msacm32", "xinput1_3", "xinput1_4", "xinput9_1_0",
    ]

    /// Proxy DLLs next to `program`, lowercased and without `.dll`, sorted.
    public static func proxyDLLs(besides program: URL) -> [String] {
        let folder = program.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.compactMap { file -> String? in
            let lower = file.lowercased()
            guard lower.hasSuffix(".dll") else { return nil }
            let name = String(lower.dropLast(4))
            return proxyNames.contains(name) ? name : nil
        }.sorted()
    }

    /// `.asi` mods in the program's folder or the subfolders loaders search (`scripts`, `plugins`).
    public static func hasASIMods(besides program: URL) -> Bool {
        let folder = program.deletingLastPathComponent()
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for entry in entries {
            if entry.lowercased().hasSuffix(".asi") { return true }
            guard ["scripts", "plugins"].contains(entry.lowercased()) else { continue }
            let inner = (try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent(entry).path)) ?? []
            if inner.contains(where: { $0.lowercased().hasSuffix(".asi") }) { return true }
        }
        return false
    }

    /// The DLLs Wine should take from the game folder for `program` under `mode`.
    public static func wanted(_ mode: ModLoaderMode, program: URL) -> [String] {
        switch mode {
        case .off: return []
        case .on: return proxyDLLs(besides: program)
        case .automatic: return hasASIMods(besides: program) ? proxyDLLs(besides: program) : []
        }
    }

    /// The program the game itself is. For a game Steam starts that's not the library entry's
    /// `steam.exe` but the game's own, found through Steam's library.
    public static func program(for game: Game, prefix: URL) -> URL? {
        let exe = URL(fileURLWithPath: game.executablePath)
        guard Launcher.startsThroughSteam(game) else { return exe }
        if let appID = game.steamAppID ?? steamAppID(in: game.settings.arguments),
           let app = SteamLibrary.apps(client: exe, prefix: prefix).first(where: { $0.appID == appID }),
           let program = app.mainProgram() {
            return program
        }
        return game.iconPath.map { URL(fileURLWithPath: $0) }
    }

    /// The id after `-applaunch` in a hand-made Steam entry's arguments.
    static func steamAppID(in arguments: String) -> Int? {
        let parts = Launcher.splitArguments(arguments)
        guard let index = parts.firstIndex(where: { $0.lowercased() == "-applaunch" }), index + 1 < parts.count else { return nil }
        return Int(parts[index + 1])
    }

    // MARK: - Registry

    /// Which overrides Decanter wrote in a prefix, by program name, so it removes only its own.
    static func marker(for prefix: URL) -> URL {
        prefix.deletingLastPathComponent().appendingPathComponent("mod-loaders.json")
    }

    static func written(in prefix: URL) -> [String: [String]] {
        (try? Data(contentsOf: marker(for: prefix))).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
    }

    /// Brings the prefix's overrides for the game's program in line with its setting, before launch.
    public static func apply(game: Game, prefix: URL, runtime: InstalledRuntime) async {
        guard let program = program(for: game, prefix: prefix) else { return }
        let name = program.lastPathComponent.lowercased()
        let wanted = wanted(game.settings.modLoaders, program: program)
        var record = written(in: prefix)
        let current = record[name] ?? []
        guard wanted != current else { return }
        let env = Launcher.gameEnvironment(game, prefix: prefix, runtime: runtime, quiet: true)
        let wine = runtime.wine(for: game.settings.renderer)
        let key = #"HKCU\Software\Wine\AppDefaults\"# + program.lastPathComponent + #"\DllOverrides"#
        var done: [String] = []
        for dll in wanted {
            let status = try? await Shell.run(wine, ["reg", "add", key, "/v", dll, "/d", "native,builtin", "/f"],
                                              environment: env, check: false).status
            if status == 0 { done.append(dll) }
        }
        for dll in current where !wanted.contains(dll) {
            _ = try? await Shell.run(wine, ["reg", "delete", key, "/v", dll, "/f"], environment: env, check: false)
        }
        record[name] = done.isEmpty ? nil : done
        try? JSONEncoder().encode(record).write(to: marker(for: prefix), options: .atomic)
    }
}
