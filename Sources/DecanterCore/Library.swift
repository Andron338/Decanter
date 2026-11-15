import Foundation

public struct GameSettings: Codable, Equatable {
    public var renderer: Renderer = .metal
    /// Run inside a fixed-size Wine desktop. Fixes old games that crash on fullscreen mode switches.
    public var virtualDesktop = false
    public var virtualDesktopSize = "1440x900"
    /// With a fixed-size window: lower the Mac's screen resolution while the game runs, so the
    /// window nearly fills the screen.
    public var fillScreen = false
    /// Let the game switch to resolutions the Mac's screen doesn't have, scaled to the whole screen.
    /// See `ScaledFullscreen`. Takes the place of the fixed-size window.
    public var scaledFullscreen = false
    public var retina = false
    public var fastSync = true
    public var performanceHUD = false
    public var arguments = ""
    // D3DMetal only:
    public var rayTracing = false
    public var metalFX = false
    public var advertiseAVX = false
    /// Wine 10 only: which translator each DirectX version gets.
    public var wine10Graphics = Wine10Graphics.automatic
    /// Whether Wine uses a mod loader in the game folder instead of its own DLL (see `ModLoaders`).
    public var modLoaders = ModLoaderMode.automatic
    /// Wine DLL overrides, in WINEDLLOVERRIDES form: `dinput8=n,b;d3d9=n`.
    public var dllOverrides = ""
    /// Extra environment variables, one `NAME=value` per line.
    public var environment = ""
    /// Folder the game starts in; empty means the folder its program is in.
    public var workingDirectory = ""
    /// Windows language as a locale name (`ru_RU`); empty picks one from the Mac's languages.
    public var language = ""

    public init() {}

    /// Tolerant decoding so libraries saved by older versions keep loading as settings are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GameSettings()
        renderer = (try? c.decodeIfPresent(Renderer.self, forKey: .renderer)) ?? d.renderer
        virtualDesktop = try c.decodeIfPresent(Bool.self, forKey: .virtualDesktop) ?? d.virtualDesktop
        virtualDesktopSize = try c.decodeIfPresent(String.self, forKey: .virtualDesktopSize) ?? d.virtualDesktopSize
        fillScreen = try c.decodeIfPresent(Bool.self, forKey: .fillScreen) ?? d.fillScreen
        scaledFullscreen = try c.decodeIfPresent(Bool.self, forKey: .scaledFullscreen) ?? d.scaledFullscreen
        retina = try c.decodeIfPresent(Bool.self, forKey: .retina) ?? d.retina
        fastSync = try c.decodeIfPresent(Bool.self, forKey: .fastSync) ?? d.fastSync
        performanceHUD = try c.decodeIfPresent(Bool.self, forKey: .performanceHUD) ?? d.performanceHUD
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? d.arguments
        rayTracing = try c.decodeIfPresent(Bool.self, forKey: .rayTracing) ?? d.rayTracing
        metalFX = try c.decodeIfPresent(Bool.self, forKey: .metalFX) ?? d.metalFX
        advertiseAVX = try c.decodeIfPresent(Bool.self, forKey: .advertiseAVX) ?? d.advertiseAVX
        wine10Graphics = (try? c.decodeIfPresent(Wine10Graphics.self, forKey: .wine10Graphics)) ?? d.wine10Graphics
        modLoaders = (try? c.decodeIfPresent(ModLoaderMode.self, forKey: .modLoaders)) ?? d.modLoaders
        dllOverrides = try c.decodeIfPresent(String.self, forKey: .dllOverrides) ?? d.dllOverrides
        environment = try c.decodeIfPresent(String.self, forKey: .environment) ?? d.environment
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory) ?? d.workingDirectory
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
    }
}

public struct Game: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    /// Absolute macOS path to the .exe (inside the bottle or anywhere on disk).
    public var executablePath: String
    /// The bottle the game runs in. Several games can share one.
    public var bottleID: UUID
    /// Only read from libraries saved when every game had a bottle per engine; `BottleStore.adopt`
    /// folds these into the bottle list and clears them.
    public var gptkBottleID: UUID?
    public var crossoverBottleID: UUID?
    public var settings = GameSettings()
    public var lastPlayed: Date?
    /// What the executable was detected to need; nil if never inspected or unreadable.
    public var requirements: GameRequirements?
    // Optional so libraries saved by older versions keep loading.
    public var favorite: Bool?
    /// Total time the game has been running, in seconds.
    public var playSeconds: Double?
    public var added: Date?
    /// An automatic cover lookup has been tried, so it isn't repeated on every launch.
    public var coverLookedUp: Bool?
    /// Set for a game the Steam client in its bottle starts: `executablePath` is then `steam.exe`.
    public var steamAppID: Int?
    /// The program whose icon stands for the game, when that isn't the one that starts it.
    public var iconPath: String?
    /// Kept out of the library views; shown only under Hidden.
    public var hidden: Bool?
    /// The user's own groupings ("Finished", "Co-op"…), shown in the sidebar.
    public var categories: [String]?

    public init(name: String, executablePath: String, bottleID: UUID) {
        self.name = name
        self.executablePath = executablePath
        self.bottleID = bottleID
        self.added = Date()
    }

    public var isFavorite: Bool { favorite ?? false }
    public var playTime: TimeInterval { playSeconds ?? 0 }
    public var isHidden: Bool { hidden ?? false }
    public var categoryNames: [String] { categories ?? [] }

    public func isIn(category: String) -> Bool {
        categoryNames.contains { GameCategories.same($0, category) }
    }

    /// Adds or removes the game from a category. Names are matched ignoring case and surrounding spaces.
    public mutating func setCategory(_ name: String, included: Bool) {
        let name = GameCategories.clean(name)
        guard !name.isEmpty else { return }
        var names = categoryNames.filter { !GameCategories.same($0, name) }
        if included { names.append(name) }
        categories = names.isEmpty ? nil : names
    }

    /// The program that is the game: for a Steam game, the one in its folder rather than `steam.exe`.
    public var programPath: String { steamAppID != nil ? (iconPath ?? executablePath) : executablePath }

    /// Steam crashes on Apple's own Wine, so for a game Steam starts, D3DMetal means the Wine 10
    /// engine's D3DMetal route, where Steam runs. True when that changed the settings.
    @discardableResult
    public mutating func keepSteamOnWine10() -> Bool {
        guard Launcher.startsThroughSteam(self), settings.renderer == .d3dmetal else { return false }
        settings.renderer = .sikarugir
        settings.wine10Graphics = .d3dmetal
        return true
    }

    /// Reads the executable and, when `chooseRenderer` is set, switches to the renderer that suits it.
    public mutating func inspect(chooseRenderer: Bool) {
        requirements = ExecutableInspector.inspect(URL(fileURLWithPath: programPath))
        if chooseRenderer, let renderer = requirements?.recommendedRenderer {
            settings.renderer = renderer
            keepSteamOnWine10()
        }
    }
}

/// Categories have no list of their own: one exists while some game is in it.
public enum GameCategories {
    public static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func same(_ a: String, _ b: String) -> Bool {
        clean(a).caseInsensitiveCompare(clean(b)) == .orderedSame
    }

    /// Every category in use, once each (the first spelling seen wins), in Finder order.
    public static func all(in games: [Game]) -> [String] {
        var names: [String] = []
        for name in games.flatMap(\.categoryNames).map(clean) where !name.isEmpty {
            if !names.contains(where: { same($0, name) }) { names.append(name) }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Renames a category in every game. Renaming onto an existing name merges the two.
    public static func rename(_ old: String, to new: String, in games: inout [Game]) {
        let new = clean(new)
        guard !new.isEmpty else { return }
        for index in games.indices where games[index].isIn(category: old) {
            games[index].setCategory(old, included: false)
            games[index].setCategory(new, included: true)
        }
    }

    public static func delete(_ name: String, in games: inout [Game]) {
        for index in games.indices { games[index].setCategory(name, included: false) }
    }
}

public enum LibraryStore {
    public static func load() -> [Game] {
        guard let data = try? Data(contentsOf: Paths.library) else { return [] }
        return (try? JSONDecoder().decode([Game].self, from: data)) ?? []
    }

    public static func save(_ games: [Game]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(games) else { return }
        try? Paths.ensure(Paths.root)
        try? data.write(to: Paths.library, options: .atomic)
    }
}

/// A bottle is a named Windows environment that any number of games can be installed in, so an
/// installer, patch or add-on run there sees what is already installed.
public struct Bottle: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var created: Date
    /// The folder holding each engine's Wine prefix, by `Engine.rawValue`. Engines can't share a prefix:
    /// each is a different Wine version, and prefixes don't survive a downgrade. Made on first use.
    public var prefixes: [String: UUID]
    /// The engine an installer last ran on here, which is where the next one should run to see it.
    public var lastEngine: String?

    public init(id: UUID = UUID(), name: String, prefixes: [String: UUID] = [:]) {
        self.id = id
        self.name = name
        self.created = Date()
        self.prefixes = prefixes
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Untitled Bottle" : trimmed
    }

    public func prefixID(for engine: Engine) -> UUID? { prefixes[engine.rawValue] }

    /// nil until something has run in this bottle on that engine.
    public func prefix(for engine: Engine) -> URL? { prefixID(for: engine).map(BottleStore.prefix) }

    public var engines: [Engine] { Engine.allCases.filter { prefixes[$0.rawValue] != nil } }

    public var installEngine: Engine { lastEngine.flatMap(Engine.init(rawValue:)) ?? engines.first ?? .wine }
}

public struct BottleList: Codable, Equatable {
    public var bottles: [Bottle] = []
    /// Where new games and installers go unless the user picks another.
    public var defaultID: UUID?

    public init(bottles: [Bottle] = [], defaultID: UUID? = nil) {
        self.bottles = bottles
        self.defaultID = defaultID
    }
}

public enum BottleStore {
    public static func load() -> BottleList {
        guard let data = try? Data(contentsOf: Paths.bottleList) else { return BottleList() }
        return (try? JSONDecoder().decode(BottleList.self, from: data)) ?? BottleList()
    }

    public static func save(_ list: BottleList) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(list) else { return }
        try? Paths.ensure(Paths.root)
        try? data.write(to: Paths.bottleList, options: .atomic)
    }

    /// The bottle list, with a bottle for every game in the library. Libraries from before bottles
    /// had names are converted on the way: each game keeps the environment it already had.
    public static func loadAdopting() -> BottleList {
        var list = load()
        var games = LibraryStore.load()
        let (bottlesChanged, gamesChanged) = adopt(games: &games, into: &list)
        // Bottles first: a library without its legacy fields is useless without the list they went to.
        if bottlesChanged { save(list) }
        if gamesChanged { LibraryStore.save(games) }
        return list
    }

    /// Adds a bottle for each game whose bottle isn't listed, and moves the per-engine bottles that
    /// older libraries kept on the game itself into its bottle.
    static func adopt(games: inout [Game], into list: inout BottleList) -> (bottles: Bool, games: Bool) {
        var bottlesChanged = false, gamesChanged = false
        var adopted: [UUID: [String]] = [:]
        for index in games.indices {
            let game = games[index]
            var position = list.bottles.firstIndex { $0.id == game.bottleID }
            if position == nil {
                // Until now a game's bottle id was also its standard prefix's folder name.
                list.bottles.append(Bottle(id: game.bottleID, name: game.name,
                                           prefixes: [Engine.wine.rawValue: game.bottleID]))
                position = list.bottles.count - 1
                adopted[game.bottleID] = []
                bottlesChanged = true
            }
            if adopted[game.bottleID] != nil { adopted[game.bottleID]?.append(game.name) }
            for (engine, legacy) in [(Engine.gptk, game.gptkBottleID), (.crossover, game.crossoverBottleID)] {
                guard let legacy else { continue }
                if list.bottles[position!].prefixID(for: engine) == nil {
                    list.bottles[position!].prefixes[engine.rawValue] = legacy
                    bottlesChanged = true
                }
                gamesChanged = true
            }
            games[index].gptkBottleID = nil
            games[index].crossoverBottleID = nil
        }
        for (id, names) in adopted where names.count > 1 {
            guard let position = list.bottles.firstIndex(where: { $0.id == id }) else { continue }
            list.bottles[position].name = "\(names[0]) + \(names.count - 1) more"
        }
        return (bottlesChanged, gamesChanged)
    }

    public static func templatePrefix(_ engine: Engine) -> URL {
        let name: String
        switch engine {
        case .wine: name = "prefix"
        case .gptk: name = "gptk-prefix"
        case .crossover: name = "cx-prefix"
        case .sikarugir: name = "sk-prefix"
        }
        return Paths.template.appendingPathComponent(name, isDirectory: true)
    }

    public static func templateReady(_ engine: Engine) -> Bool {
        FileManager.default.fileExists(atPath: templatePrefix(engine).appendingPathComponent("system.reg").path)
    }

    public static func prefix(_ id: UUID) -> URL {
        Paths.bottles.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("prefix", isDirectory: true)
    }

    /// Clones the template prefix. On APFS this is instant and takes no extra disk until files diverge.
    public static func create(_ id: UUID, engine: Engine = .wine) async throws {
        let dest = prefix(id)
        try Paths.ensure(dest.deletingLastPathComponent())
        try await Shell.run("/bin/cp", ["-Rcp", templatePrefix(engine).path, dest.path])
    }

    /// The folder of the bottle's prefix for `engine`, cloning the template the first time. The caller
    /// records the returned id in the bottle.
    public static func ensurePrefix(for engine: Engine, in bottle: Bottle) async throws -> UUID {
        let id = bottle.prefixID(for: engine) ?? UUID()
        if !FileManager.default.fileExists(atPath: prefix(id).path) { try await create(id, engine: engine) }
        return id
    }

    public static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Paths.bottles.appendingPathComponent(id.uuidString))
    }

    /// Deletes every engine's prefix of a bottle, with everything installed in them.
    public static func delete(_ bottle: Bottle) {
        for id in bottle.prefixes.values { delete(id) }
    }

    /// Every program on the prefix's C: drive, as paths relative to it.
    static func executablePaths(prefix: URL) -> Set<String> {
        Set(executables(under: prefix.appendingPathComponent("drive_c")).map(\.relative))
    }

    /// Executables in the prefix that aren't in `known`, i.e. what an installer just put there.
    static func newExecutables(prefix: URL, known: Set<String>) -> [URL] {
        executables(under: prefix.appendingPathComponent("drive_c"))
            .filter { !known.contains($0.relative) && !GameNaming.isHelperExecutable($0.url) }
            .map(\.url)
            .sorted { $0.path.count < $1.path.count }
    }

    private static func executables(under driveC: URL) -> [(url: URL, relative: String)] {
        let base = driveC.resolvingSymlinksInPath().path
        guard let walker = FileManager.default.enumerator(
            at: URL(fileURLWithPath: base), includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        var result: [(URL, String)] = []
        for case let url as URL in walker {
            let relative = String(url.path.dropFirst(base.count + 1))
            // `windows` is Wine's own; `users/*` contains symlinks out to the real home folder.
            if relative == "windows" || relative == "users" {
                walker.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == "exe" { result.append((url, relative)) }
        }
        return result
    }
}

public enum GameNaming {
    static let genericFolders: Set<String> = [
        "bin", "bin32", "bin64", "binaries", "win32", "win64", "x64", "x86", "x86_64", "game", "release",
        "retail", "system", "shipping", "downloads", "desktop", "documents", "program files",
        "program files (x86)", "drive_c", "games", "",
    ]

    /// True for files named like an installer and for ones built with a known installer maker,
    /// whatever they are called (GOG's `game_name_1.0.exe`, for instance).
    public static func looksLikeInstaller(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "msi" { return true }
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        if stem.contains("uninstall") || stem.hasPrefix("unins") { return false }
        return ["setup", "install"].contains { stem.contains($0) } || InstallerDetector.kind(of: url) != nil
    }

    static func isHelperExecutable(_ url: URL) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let helpers = ["unins", "crash", "redist", "vcredist", "dxsetup", "dotnet", "directx", "setup",
                       "install", "updater", "helper", "report", "cefprocess", "webhelper", "ue4prereq"]
        if helpers.contains(where: { stem.contains($0) }) { return true }
        // `nfs_inst.exe`, `game-uninst.exe`: only as a whole word, so `against.exe` stays a game.
        let words = stem.split { !$0.isLetter && !$0.isNumber }
        return words.contains { $0 == "inst" || $0 == "uninst" }
    }

    /// Best-effort display name: the game's folder if it's descriptive, otherwise the exe name tidied up.
    public static func displayName(for executable: URL) -> String {
        var folder = executable.deletingLastPathComponent()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for _ in 0..<4 {
            let name = folder.lastPathComponent
            if folder.standardizedFileURL.path == home || folder.path == "/" { break }
            if !genericFolders.contains(name.lowercased()) { return name }
            folder = folder.deletingLastPathComponent()
        }
        return tidy(executable.deletingPathExtension().lastPathComponent)
    }

    static func tidy(_ stem: String) -> String {
        stem.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.count <= 3 ? $0.uppercased() : $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
