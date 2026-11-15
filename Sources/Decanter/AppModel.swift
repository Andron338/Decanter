import AppKit
import DecanterCore
import Observation
import UniformTypeIdentifiers

enum SetupState: Equatable {
    case needed
    case working(stage: String, fraction: Double?)
    case failed(String)
}

/// An installer the user picked explicitly, waiting for them to confirm how to run it.
struct InstallRequest: Identifiable {
    let id = UUID()
    let installer: URL
    let kind: InstallerKind?
    /// The bottle to offer first; the default one when nil.
    var bottleID: UUID?
    /// Offer a new bottle with this name instead, unless one already has it.
    var newBottleName: String?
}

/// Where an installer should run.
enum BottleChoice: Hashable {
    case existing(UUID)
    case new(name: String)
}

/// What an installer left behind, when Decanter needs the user to say which program is the game.
struct InstallerResult: Identifiable {
    let id = UUID()
    let bottleID: UUID
    let bottleName: String
    let prefix: URL
    let engine: Engine
    /// The bottle was made for this install, so discarding the install deletes it.
    let createdBottle: Bool
    var programs: [InstalledProgram]
}

/// An installer that is running right now.
struct ActiveInstall: Equatable {
    let prefix: URL
    let engine: Engine
    /// false when it runs for an existing game (a patch, DLC or missing component).
    let isNewGame: Bool
    /// Cancelling throws the whole bottle away, because it was made for this install.
    var discardsOnCancel = false
}

/// A game the Steam client in a bottle has downloaded that isn't in the library yet.
struct SteamSuggestion: Identifiable, Equatable, Sendable {
    let app: SteamApp
    let bottleID: UUID
    let engine: Engine
    /// The game's own program, which its icon comes from.
    let program: URL?

    var id: String { Self.id(bottleID: bottleID, appID: app.appID) }

    static func id(bottleID: UUID, appID: Int) -> String { "\(bottleID.uuidString):\(appID)" }
}

@MainActor
@Observable
final class AppModel {
    var runtime: InstalledRuntime? = RuntimeManager.load()
    var games: [Game]
    private(set) var bottles: [Bottle]
    /// Where new games and installers go unless the user picks another bottle.
    private(set) var defaultBottleID: UUID?
    var managingBottles = false
    /// Prefixes being cloned right now, so two launches don't each make one for the same bottle.
    @ObservationIgnored private var prefixTasks: [String: Task<UUID, Error>] = [:]
    var setupState: SetupState = .needed
    var busyMessage: String?
    var errorMessage: String?
    var running: Set<UUID> = []
    /// Games that lowered the screen resolution to fill it; the last one to quit restores it.
    private var fillingScreen: Set<UUID> = []
    var installerResult: InstallerResult?
    var installRequest: InstallRequest?
    var activeInstall: ActiveInstall?
    private var installCancelled = false
    var editing: Game?
    /// nil when idle; progress or failure of the optional D3DMetal download.
    var d3dMetalInstall: SetupState?
    /// A game waiting for the user to confirm its removal.
    var pendingRemoval: Game?
    /// A game whose cover the user is picking from online results.
    var coverSearch: Game?
    /// Cover images by game. Games without one fall back to `icons`, then to a generated placeholder.
    private(set) var covers: [UUID: NSImage] = [:]
    /// The icon embedded in each game's program.
    private(set) var icons: [UUID: NSImage] = [:]
    /// Steam games found in the bottles that the library doesn't have, offered in a banner.
    private(set) var steamSuggestions: [SteamSuggestion] = []
    /// Each suggestion's cover, or failing that its program's icon, by `SteamSuggestion.id`.
    private(set) var steamArtwork: [String: NSImage] = [:]
    /// The user is picking which of the suggested Steam games to add.
    var choosingSteamGames = false
    @ObservationIgnored private var scanningSteam = false

    static var downloadsCoversAutomatically: Bool {
        UserDefaults.standard.object(forKey: "autoCovers") as? Bool ?? true
    }

    init() {
        // Before the library: this is what moves older libraries' bottles into the bottle list.
        let list = BottleStore.loadAdopting()
        bottles = list.bottles
        defaultBottleID = list.defaultID
        games = AppModel.loadLibrary()
        for game in games { loadArtwork(for: game) }
        fetchMissingCovers()
        findSteamGames()
    }

    /// Games added before detection existed get inspected once; their renderer choice is left alone
    /// unless it was still the untouched default.
    private static func loadLibrary() -> [Game] {
        var games = LibraryStore.load()
        var changed = false
        // Steam games were once inspected through steam.exe or Unreal's launcher stub, which name no graphics.
        for index in games.indices where games[index].requirements == nil
            || (games[index].steamAppID != nil && games[index].requirements?.directX.isEmpty == true) {
            games[index].inspect(chooseRenderer: games[index].settings == GameSettings())
            changed = changed || games[index].requirements != nil
        }
        // Before the CrossOver engine existed, "Wine built-in" was the option for DirectX 9-era games.
        // Move those games across once; after that, choosing Wine 11 by hand is respected.
        let migrationKey = "migratedOlderGamesToCrossOver"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            for index in games.indices
            where games[index].settings.renderer == .wine && games[index].requirements?.recommendedRenderer == .crossover {
                games[index].settings.renderer = .crossover
                changed = true
            }
            UserDefaults.standard.set(true, forKey: migrationKey)
        }
        if changed { LibraryStore.save(games) }
        return games
    }

    // MARK: Setup

    func runSetup() {
        if case .working = setupState { return }
        setupState = .working(stage: "Starting…", fraction: nil)
        Task {
            do {
                let installed = try await RuntimeManager.setup { progress in
                    Task { @MainActor in
                        if case .working = self.setupState {
                            self.setupState = .working(stage: progress.stage, fraction: progress.fraction)
                        }
                    }
                }
                runtime = installed
                setupState = .needed
            } catch {
                setupState = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Adding games

    func add(_ urls: [URL]) {
        for url in urls { add(url) }
    }

    func add(_ url: URL) {
        guard runtime != nil, isWindowsProgram(url) else { return }
        if GameNaming.looksLikeInstaller(url) {
            install(url)
        } else {
            addExecutable(url)
        }
    }

    private func isWindowsProgram(_ url: URL) -> Bool {
        if ["exe", "msi"].contains(url.pathExtension.lowercased()) { return true }
        errorMessage = "“\(url.lastPathComponent)” isn't a Windows program. Drop a .exe or .msi file."
        return false
    }

    /// Adds a game that is already installed (or portable) somewhere on disk. Its bottle's prefix is
    /// made the first time it is played.
    private func addExecutable(_ url: URL, bottleID: UUID? = nil, engine: Engine? = nil) {
        var game = Game(name: GameNaming.displayName(for: url), executablePath: url.path,
                        bottleID: bottleID ?? sharedBottle().id)
        game.inspect(chooseRenderer: true)
        // A program picked out of a prefix belongs to that engine: its registry entries exist nowhere else.
        if let engine, runtime?.engine(for: game.settings.renderer) != engine {
            game.settings.renderer = GameInstaller.renderer(for: engine)
        }
        games.append(game)
        LibraryStore.save(games)
        loadArtwork(for: game)
        fetchMissingCovers()
    }

    // MARK: Installing

    /// Treats the file as an installer no matter what it's called, after asking where to run it.
    func requestInstall(_ url: URL, bottleID: UUID? = nil) {
        guard runtime != nil, isWindowsProgram(url) else { return }
        installRequest = InstallRequest(installer: url, kind: InstallerDetector.kind(of: url),
                                        bottleID: bottleID ?? sharedBottle().id)
    }

    /// Downloads Valve's installer for the Windows Steam client and offers to run it, in a bottle of
    /// its own unless there already is a Steam bottle.
    func installSteam() {
        guard runtime != nil, busyMessage == nil else { return }
        busyMessage = "Downloading the Steam installer…"
        Task {
            defer { busyMessage = nil }
            do {
                let file = try await SteamInstaller.download()
                installRequest = InstallRequest(installer: file, kind: InstallerDetector.kind(of: file),
                                                bottleID: nil, newBottleName: SteamInstaller.bottleName)
            } catch {
                errorMessage = "Couldn't download Steam: \(error.localizedDescription)"
            }
        }
    }

    /// Runs an installer in a bottle, then adds what it installed to the library. With nothing chosen
    /// it goes in the default bottle, on the engine the last installer there used, so it sees what
    /// that one installed.
    func install(_ url: URL, engine requested: Engine? = nil, into choice: BottleChoice? = nil) {
        guard busyMessage == nil else { return }
        busyMessage = "Preparing the Windows environment…"
        installCancelled = false
        Task {
            defer {
                busyMessage = nil
                activeInstall = nil
                findSteamGames()
            }
            var created: UUID?
            do {
                let bottle: Bottle
                switch choice {
                case .new(let name):
                    bottle = createBottle(named: name)
                    created = bottle.id
                case .existing(let id):
                    guard let found = self.bottle(id) else { throw DecanterError("That bottle no longer exists.") }
                    bottle = found
                case nil:
                    bottle = sharedBottle()
                }
                var engine = requested ?? bottle.installEngine
                if runtime?.has(engine) == false && engine == .gptk { engine = .wine }
                let runtime = try await readyRuntime(for: GameInstaller.renderer(for: engine))
                let prefix = try await prefix(in: bottle.id, engine: engine)
                if let index = bottles.firstIndex(where: { $0.id == bottle.id }) {
                    bottles[index].lastEngine = engine.rawValue
                    saveBottles()
                }
                let before = await Task.detached {
                    GameInstaller.isolateDesktop(prefix: prefix)
                    return BottleSnapshot.take(prefix: prefix)
                }.value
                busyMessage = "Running the installer in “\(bottle.displayName)”. Finish it, and Decanter will pick up from there."
                activeInstall = ActiveInstall(prefix: prefix, engine: engine, isNewGame: true,
                                              discardsOnCancel: created != nil)
                try await GameInstaller.run(url, prefix: prefix, engine: engine, runtime: runtime)
                activeInstall = nil
                if installCancelled {
                    if let created { discardBottle(created) }
                    return
                }
                busyMessage = "Looking for the game…"
                let programs = await Task.detached {
                    GameInstaller.installedPrograms(prefix: prefix, since: before)
                }.value
                if let choice = GameInstaller.obviousChoice(among: programs) {
                    addInstalled([choice], bottleID: bottle.id, engine: engine)
                } else {
                    installerResult = InstallerResult(
                        bottleID: bottle.id, bottleName: bottle.displayName, prefix: prefix, engine: engine,
                        createdBottle: created != nil, programs: programs)
                }
            } catch {
                if let created { discardBottle(created) }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Abandons a running install. A bottle made for it is thrown away; in a bottle that was already
    /// there, whatever the installer wrote so far stays.
    func cancelInstall() {
        installCancelled = true
        finishInstall()
    }

    /// Ends whatever is still running in the installer's prefix, for installers that leave a launcher
    /// or the game itself open, so Decanter can carry on.
    func finishInstall() {
        guard let runtime, let active = activeInstall else { return }
        busyMessage = installCancelled ? "Cancelling…" : "Finishing up…"
        Task { await Launcher.stop(prefix: active.prefix, engine: active.engine, runtime: runtime) }
    }

    /// Adds installed programs as games in the bottle the installer ran in.
    func addInstalled(_ programs: [InstalledProgram], bottleID: UUID, engine: Engine) {
        for program in programs {
            var game = Game(name: program.name, executablePath: program.executable.path, bottleID: bottleID)
            game.settings.arguments = program.arguments
            game.inspect(chooseRenderer: true)
            if engine != .wine {
                // Stay on the engine the install belongs to: its registry entries exist nowhere else.
                game.settings.renderer = GameInstaller.renderer(for: engine)
            }
            games.append(game)
            loadArtwork(for: game)
        }
        LibraryStore.save(games)
        fetchMissingCovers()
    }

    func addInstalled(_ programs: [InstalledProgram], from result: InstallerResult) {
        addInstalled(programs, bottleID: result.bottleID, engine: result.engine)
    }

    /// Lets the user point at the game inside the bottle when Decanter couldn't find it.
    func browseInstalled(_ result: InstallerResult) -> InstalledProgram? {
        chooseProgram(in: result.prefix).map { InstalledProgram(executable: $0, name: GameNaming.displayName(for: $0)) }
    }

    private func chooseProgram(in prefix: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.directoryURL = prefix.appendingPathComponent("drive_c", isDirectory: true)
        panel.allowedContentTypes = [.exe]
        panel.message = "Choose the game's program"
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func discardInstallerResult(_ result: InstallerResult) {
        if result.createdBottle { discardBottle(result.bottleID) }
    }

    /// Runs a patch, DLC or component installer in the prefix a game runs in.
    func runInstaller(in game: Game) {
        guard runtime != nil, busyMessage == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.exe, UTType(filenameExtension: "msi") ?? .data]
        panel.message = "Choose a patch, add-on or installer to run where \(game.name) is installed"
        panel.prompt = "Run"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busyMessage = "Preparing…"
        Task {
            defer {
                busyMessage = nil
                activeInstall = nil
            }
            do {
                let (runtime, prefix) = try await prepared(game)
                let engine = runtime.engine(for: game.settings.renderer)
                busyMessage = "Running \(url.lastPathComponent) for \(game.name)…"
                activeInstall = ActiveInstall(prefix: prefix, engine: engine, isNewGame: false)
                try await GameInstaller.run(url, prefix: prefix, engine: engine, runtime: runtime)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Bottles

    func bottle(_ id: UUID) -> Bottle? { bottles.first { $0.id == id } }

    func games(in bottle: Bottle) -> [Game] { games.filter { $0.bottleID == bottle.id } }

    private func saveBottles() {
        BottleStore.save(BottleList(bottles: bottles, defaultID: defaultBottleID))
    }

    /// The default bottle, made the first time something needs it.
    @discardableResult
    func sharedBottle() -> Bottle {
        if let bottle = bottles.first(where: { $0.id == defaultBottleID }) { return bottle }
        let bottle = createBottle(named: "Shared")
        defaultBottleID = bottle.id
        saveBottles()
        return bottle
    }

    /// An empty bottle. Its Windows environment is made when something first runs in it.
    @discardableResult
    func createBottle(named name: String) -> Bottle {
        let wanted = name.trimmingCharacters(in: .whitespaces).isEmpty ? "New Bottle" : name.trimmingCharacters(in: .whitespaces)
        var unique = wanted, number = 2
        while bottles.contains(where: { $0.name.caseInsensitiveCompare(unique) == .orderedSame }) {
            unique = "\(wanted) \(number)"
            number += 1
        }
        let bottle = Bottle(name: unique)
        bottles.append(bottle)
        saveBottles()
        return bottle
    }

    func renameBottle(_ id: UUID, to name: String) {
        guard let index = bottles.firstIndex(where: { $0.id == id }), bottles[index].name != name else { return }
        bottles[index].name = name
        saveBottles()
    }

    func setDefaultBottle(_ id: UUID) {
        guard bottle(id) != nil else { return }
        defaultBottleID = id
        saveBottles()
    }

    /// Deletes a bottle with everything installed in it, and takes its games out of the library.
    /// The default bottle stays: something has to receive new games.
    func deleteBottle(_ id: UUID) {
        guard id != defaultBottleID, let bottle = bottle(id) else { return }
        for game in games(in: bottle) { forget(game) }
        LibraryStore.save(games)
        discardBottle(id)
    }

    private func discardBottle(_ id: UUID) {
        guard let bottle = bottle(id) else { return }
        bottles.removeAll { $0.id == id }
        if defaultBottleID == id { defaultBottleID = nil }
        saveBottles()
        steamSuggestions.removeAll { $0.bottleID == id }
        let runtime = runtime
        Task {
            // Wine keeps files open while it runs; stop it before the folder goes.
            if let runtime { await Launcher.stop(bottle, runtime: runtime) }
            BottleStore.delete(bottle)
        }
    }

    /// The bottle's prefix for an engine, cloned from the template the first time it is needed.
    private func prefix(in bottleID: UUID, engine: Engine) async throws -> URL {
        guard let bottle = bottle(bottleID) else {
            throw DecanterError("This game's bottle no longer exists. Choose another one in its settings.")
        }
        let key = bottleID.uuidString + engine.rawValue
        let task = prefixTasks[key] ?? Task { try await BottleStore.ensurePrefix(for: engine, in: bottle) }
        prefixTasks[key] = task
        defer { prefixTasks[key] = nil }
        let prefixID = try await task.value
        if let index = bottles.firstIndex(where: { $0.id == bottleID }), bottles[index].prefixID(for: engine) != prefixID {
            bottles[index].prefixes[engine.rawValue] = prefixID
            saveBottles()
        }
        return BottleStore.prefix(prefixID)
    }

    func openDriveC(_ bottle: Bottle, engine: Engine) {
        guard let prefix = bottle.prefix(for: engine) else { return }
        NSWorkspace.shared.open(prefix.appendingPathComponent("drive_c", isDirectory: true))
    }

    /// Runs one of Wine's own tools (winecfg, regedit, …) in a bottle, on one of its engines.
    func runTool(_ tool: String, in bottle: Bottle, engine: Engine) {
        guard let runtime, let prefix = bottle.prefix(for: engine) else { return }
        var probe = Game(name: bottle.displayName, executablePath: prefix.appendingPathComponent("drive_c").path,
                         bottleID: bottle.id)
        probe.settings.renderer = GameInstaller.renderer(for: engine)
        start(tool, plan: Launcher.plan(game: probe, prefix: prefix, runtime: runtime))
    }

    private func start(_ tool: String, plan: LaunchPlan) {
        var plan = plan
        plan.arguments = [tool]
        do {
            _ = try Launcher.start(plan, log: Paths.logs.appendingPathComponent("tools.log")) { _ in }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Adds a program that is already in a bottle (installed by hand, or by an installer Decanter
    /// couldn't follow) to the library.
    func addProgram(from bottle: Bottle, engine: Engine) {
        guard let prefix = bottle.prefix(for: engine), let url = chooseProgram(in: prefix) else { return }
        addExecutable(url, bottleID: bottle.id, engine: engine)
    }

    // MARK: Steam games

    private static let dismissedSteamKey = "dismissedSteamGames"

    /// Suggestions the user closed, or games they removed: not offered again until they ask.
    private var dismissedSteamGames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.dismissedSteamKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Self.dismissedSteamKey) }
    }

    /// Reads what the Steam client in each bottle has downloaded and offers whatever the library
    /// lacks. `includingDismissed` is the user asking outright, which brings back what they closed.
    func findSteamGames(includingDismissed: Bool = false) {
        if includingDismissed { dismissedSteamGames = [] }
        guard !scanningSteam else { return }
        scanningSteam = true
        let places = bottles.flatMap { bottle in
            bottle.engines.compactMap { engine in bottle.prefix(for: engine).map { (bottle.id, engine, $0) } }
        }
        let skipped = dismissedSteamGames.union(games.compactMap { game in
            game.steamAppID.map { SteamSuggestion.id(bottleID: game.bottleID, appID: $0) }
        })
        Task {
            let found = await Task.detached { () -> [(SteamSuggestion, Data?)] in
                var found: [(SteamSuggestion, Data?)] = []
                for (bottleID, engine, prefix) in places {
                    for client in SteamLibrary.clients(in: prefix) {
                        for app in SteamLibrary.apps(client: client, prefix: prefix)
                        where !skipped.contains(SteamSuggestion.id(bottleID: bottleID, appID: app.appID)) {
                            // Something with no program in it (a soundtrack, say) can't be played.
                            guard let program = app.mainProgram() else { continue }
                            let artwork = app.cachedCover.flatMap { try? Data(contentsOf: $0) }
                                ?? ExecutableInspector.icon(of: program)
                            found.append((SteamSuggestion(app: app, bottleID: bottleID, engine: engine, program: program), artwork))
                        }
                    }
                }
                return found
            }.value
            scanningSteam = false
            // A game added by hand from Steam's folder is already here.
            let fresh = found.filter { suggestion, _ in
                bottle(suggestion.bottleID) != nil && !games.contains { game in
                    game.steamAppID == suggestion.app.appID && game.bottleID == suggestion.bottleID
                        || game.executablePath.hasPrefix(suggestion.app.folder.path + "/")
                }
            }
            steamSuggestions = fresh.map(\.0)
            steamArtwork = Dictionary(fresh.compactMap { suggestion, data in
                data.flatMap(NSImage.init(data:)).map { (suggestion.id, $0) }
            }, uniquingKeysWith: { first, _ in first })
            if steamSuggestions.isEmpty { choosingSteamGames = false }
        }
    }

    /// Adds Steam games to the library. Steam starts them, so each one is `steam.exe -applaunch <id>`
    /// in Steam's bottle, with the game's own icon and the cover Steam already has for it.
    func addSteamGames(_ suggestions: [SteamSuggestion]) {
        for suggestion in suggestions {
            let app = suggestion.app
            var game = Game(name: app.name, executablePath: app.client.path, bottleID: suggestion.bottleID)
            game.steamAppID = app.appID
            game.iconPath = suggestion.program?.path
            game.settings.arguments = app.launchArguments
            // Steam's engine runs it, whatever the game itself would have suited.
            game.settings.renderer = GameInstaller.renderer(for: suggestion.engine)
            game.requirements = suggestion.program.flatMap(ExecutableInspector.inspect)
            // Its cover is found by Steam's own id for it rather than by searching for its name.
            game.coverLookedUp = true
            games.append(game)
            loadArtwork(for: game)
            if let data = app.cachedCover.flatMap({ try? Data(contentsOf: $0) }), setCover(data, for: game) {
                continue
            }
            guard Self.downloadsCoversAutomatically else { continue }
            let id = game.id
            Task {
                let candidate = CoverCandidate(id: app.appID, name: app.name, thumbnail: nil)
                if let data = await CoverFinder.download(candidate), covers[id] == nil,
                   let game = games.first(where: { $0.id == id }) {
                    setCover(data, for: game)
                }
            }
        }
        LibraryStore.save(games)
        let added = Set(suggestions.map(\.id))
        steamSuggestions.removeAll { added.contains($0.id) }
        for id in added { steamArtwork[id] = nil }
    }

    /// Closes the banner. These games aren't offered again unless the user asks to look for them.
    func dismissSteamSuggestions() {
        dismissedSteamGames.formUnion(steamSuggestions.map(\.id))
        steamSuggestions = []
        steamArtwork = [:]
    }

    // MARK: D3DMetal add-on

    func installD3DMetal() {
        guard let runtime else { return }
        if case .working = d3dMetalInstall { return }
        d3dMetalInstall = .working(stage: "Starting…", fraction: nil)
        Task {
            do {
                self.runtime = try await RuntimeManager.installD3DMetal(into: runtime) { progress in
                    Task { @MainActor in
                        if case .working = self.d3dMetalInstall {
                            self.d3dMetalInstall = .working(stage: progress.stage, fraction: progress.fraction)
                        }
                    }
                }
                d3dMetalInstall = nil
            } catch {
                d3dMetalInstall = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Playing

    /// The runtime with the engine behind `renderer` installed, downloading the CrossOver engine the
    /// first time something needs it.
    private func readyRuntime(for renderer: Renderer) async throws -> InstalledRuntime {
        guard var runtime else { throw DecanterError("Decanter isn't set up yet.") }
        if renderer == .crossover && !runtime.hasCrossOver {
            let previous = busyMessage
            busyMessage = "Getting the engine for older games (about 165 MB, one time)…"
            defer { busyMessage = previous }
            runtime = try await RuntimeManager.installCrossOver(into: runtime) { progress in
                Task { @MainActor in
                    guard self.busyMessage != nil else { return }
                    let percent = progress.fraction.map { " \(Int($0 * 100))%" } ?? ""
                    self.busyMessage = progress.stage + percent
                }
            }
            self.runtime = runtime
        }
        if renderer == .sikarugir && (!runtime.hasSikarugir || runtime.sikarugirNeedsUpdate) {
            let previous = busyMessage
            busyMessage = runtime.hasSikarugir ? "Updating the engine for Steam…" : "Getting the engine for Steam (about 160 MB, one time)…"
            defer { busyMessage = previous }
            runtime = try await RuntimeManager.installSikarugir(into: runtime) { progress in
                Task { @MainActor in
                    guard self.busyMessage != nil else { return }
                    let percent = progress.fraction.map { " \(Int($0 * 100))%" } ?? ""
                    self.busyMessage = progress.stage + percent
                }
            }
            self.runtime = runtime
        }
        return runtime
    }

    /// Gets everything a game's chosen engine needs in place before launch: downloads the CrossOver
    /// engine the first time a game wants it, and makes its bottle's prefix for that engine.
    private func prepared(_ game: Game) async throws -> (runtime: InstalledRuntime, prefix: URL) {
        let runtime = try await readyRuntime(for: game.settings.renderer)
        let prefix = try await prefix(in: game.bottleID, engine: runtime.engine(for: game.settings.renderer))
        return (runtime, prefix)
    }

    func play(_ game: Game) {
        guard runtime != nil, !running.contains(game.id) else { return }
        guard FileManager.default.fileExists(atPath: game.executablePath) else {
            errorMessage = "Can't find \(game.executablePath). Was the game moved or its drive unplugged?"
            return
        }
        running.insert(game.id)
        let id = game.id
        Task {
            do {
                let (runtime, prefix) = try await prepared(game)
                if let index = games.firstIndex(where: { $0.id == id }) {
                    games[index].lastPlayed = Date()
                    LibraryStore.save(games)
                }
                await matchSteamRouting(for: game, prefix: prefix, runtime: runtime)
                await installVisualCppIfNeeded(for: game, prefix: prefix, runtime: runtime)
                await Launcher.applyRegistrySettings(game: game, prefix: prefix, runtime: runtime)
                // Fill the screen: the Mac drops to the resolution that best fits the window, and the
                // Windows desktop takes that size, leaving the game's own resolution to size the window.
                var launched = game
                var filled = false
                // Scaled fullscreen: a virtual screen with the resolutions old games ask for stands
                // in for the real one, which mirrors it. If it can't be made the game runs as before.
                let scaled = game.settings.scaledFullscreen ? await ScaledFullscreen.begin() : false
                if !scaled { launched.settings.scaledFullscreen = false }
                if !scaled, game.settings.virtualDesktop, game.settings.fillScreen, !game.settings.retina,
                   let window = DisplayFit.Size(game.settings.virtualDesktopSize),
                   let screen = DisplayFit.apply(for: window) {
                    launched.settings.virtualDesktopSize = screen.text
                    filled = true
                    fillingScreen.insert(id)
                }
                await Launcher.applySteamDesktop(game: launched, prefix: prefix, runtime: runtime)
                await ModLoaders.apply(game: launched, prefix: prefix, runtime: runtime)
                let started = Date()
                let restoreScreen = {
                    if scaled { ScaledFullscreen.end() }
                    guard filled else { return }
                    self.fillingScreen.remove(id)
                    if self.fillingScreen.isEmpty { DisplayFit.restore() }
                }
                do {
                    _ = try Launcher.start(Launcher.plan(game: launched, prefix: prefix, runtime: runtime), log: logURL(for: game)) { status in
                        Task { @MainActor in
                            restoreScreen()
                            self.running.remove(id)
                            self.addPlayTime(Date().timeIntervalSince(started), to: id)
                            // Steam just quit, perhaps after downloading something.
                            self.findSteamGames()
                            if status != 0 && Date().timeIntervalSince(started) < 10 {
                                self.errorMessage = "\(game.name) quit right after starting. "
                                    + "Open its settings to try a different renderer or a fixed-size window, or check the log."
                            }
                        }
                    }
                } catch {
                    restoreScreen()
                    throw error
                }
            } catch {
                running.remove(id)
                errorMessage = error.localizedDescription
            }
        }
    }

    /// A game started through Steam runs with the environment Steam was started with, so its DirectX
    /// routing is Steam's. When the game wants another one and Steam is already running, Steam is
    /// asked to quit first and then starts again, with the game, on the game's routing.
    private func matchSteamRouting(for game: Game, prefix: URL, runtime: InstalledRuntime) async {
        guard runtime.engine(for: game.settings.renderer) == .sikarugir, Self.startsSteam(game) else { return }
        let wanted = Launcher.wine10Graphics(for: game)
        let steamRunning = games.contains {
            $0.id != game.id && running.contains($0.id) && $0.bottleID == game.bottleID && Self.startsSteam($0)
                && runtime.engine(for: $0.settings.renderer) == .sikarugir
        }
        if steamRunning, let current = Launcher.runningRouting(in: prefix), current != wanted {
            let previous = busyMessage
            busyMessage = "Restarting Steam for \(game.name)'s DirectX setting…"
            defer { busyMessage = previous }
            await Launcher.shutDownSteam(URL(fileURLWithPath: game.executablePath), prefix: prefix, runtime: runtime)
        } else if steamRunning {
            return
        }
        Launcher.recordRouting(wanted, in: prefix)
    }

    /// Puts Microsoft's Visual C++ runtime into the game's prefix the first time a game there needs
    /// it. A failure is left to the game to report: many run on Wine's own copy of the runtime.
    private func installVisualCppIfNeeded(for game: Game, prefix: URL, runtime: InstalledRuntime) async {
        guard VisualCpp.isNeeded(by: game) else { return }
        let installed = VisualCpp.isInstalled(in: prefix)
        guard !installed || !VisualCpp.prefersNative(in: prefix) else { return }
        let previous = busyMessage
        busyMessage = "Installing the Visual C++ runtime (one time per bottle)…"
        defer { busyMessage = previous }
        let engine = runtime.engine(for: game.settings.renderer)
        let env = Launcher.environment(prefix: prefix, settings: GameSettings(), engine: engine, quiet: true,
                                       libraryFallback: runtime.libraryFallback(for: engine))
        let wine = runtime.wine(for: game.settings.renderer)
        do {
            if !installed {
                try await VisualCpp.install(in: prefix, wine: wine, environment: env) { progress in
                    Task { @MainActor in
                        guard self.busyMessage != nil else { return }
                        let percent = progress.fraction.map { " \(Int($0 * 100))%" } ?? ""
                        self.busyMessage = progress.stage + percent
                    }
                }
            }
            try await VisualCpp.preferNative(in: prefix, wine: wine, environment: env)
        } catch {
            try? ("Visual C++ runtime: \(error.localizedDescription)\n").write(
                to: Paths.logs.appendingPathComponent("visual-cpp.log"), atomically: true, encoding: .utf8)
        }
    }

    private static func startsSteam(_ game: Game) -> Bool {
        game.steamAppID != nil || URL(fileURLWithPath: game.executablePath).lastPathComponent.lowercased() == "steam.exe"
    }

    /// Wine can only end a whole prefix at once, so this also ends anything else running in the
    /// game's bottle on the same engine.
    func stop(_ game: Game) {
        guard let runtime else { return }
        let engine = runtime.engine(for: game.settings.renderer)
        Task {
            if let prefix = bottle(game.bottleID)?.prefix(for: engine) {
                await Launcher.stop(prefix: prefix, engine: engine, runtime: runtime)
            }
            running.remove(game.id)
        }
    }

    // MARK: Managing

    func update(_ game: Game) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        var game = game
        let programChanged = games[index].executablePath != game.executablePath
        if programChanged { game.inspect(chooseRenderer: false) }
        // Play time and the cover lookup can change while the settings sheet holds an older copy.
        game.playSeconds = games[index].playSeconds
        game.lastPlayed = games[index].lastPlayed
        game.coverLookedUp = games[index].coverLookedUp
        games[index] = game
        LibraryStore.save(games)
        if programChanged { loadArtwork(for: game) }
    }

    func toggleFavorite(_ game: Game) {
        guard let index = games.firstIndex(where: { $0.id == game.id }) else { return }
        games[index].favorite = games[index].isFavorite ? nil : true
        LibraryStore.save(games)
    }

    private func addPlayTime(_ seconds: TimeInterval, to id: UUID) {
        guard seconds > 0, let index = games.firstIndex(where: { $0.id == id }) else { return }
        games[index].playSeconds = games[index].playTime + seconds
        LibraryStore.save(games)
    }

    func showInFinder(_ game: Game) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.executablePath)])
    }

    // MARK: Artwork

    private func loadArtwork(for game: Game) {
        covers[game.id] = CoverStore.data(for: game.id).flatMap(NSImage.init(data:))
        // A game Steam starts shows its own icon, not Steam's.
        icons[game.id] = [game.iconPath, game.executablePath].lazy
            .compactMap { $0.flatMap { ExecutableInspector.icon(of: URL(fileURLWithPath: $0)) } }
            .compactMap(NSImage.init(data:)).first
    }

    /// Saves image data as the game's cover. Returns false if it isn't an image.
    @discardableResult
    func setCover(_ data: Data, for game: Game) -> Bool {
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0 else { return false }
        do {
            try CoverStore.save(data, for: game.id)
            covers[game.id] = image
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setCover(from file: URL, for game: Game) {
        guard let data = try? Data(contentsOf: file), setCover(data, for: game) else {
            errorMessage = "“\(file.lastPathComponent)” isn't an image Decanter can use as a cover."
            return
        }
    }

    func chooseCover(for game: Game) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a cover image for \(game.name)"
        panel.prompt = "Use as Cover"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setCover(from: url, for: game)
    }

    func removeCover(for game: Game) {
        CoverStore.remove(game.id)
        covers[game.id] = nil
    }

    /// Looks up covers for games that have none and haven't been looked up before. Each game is tried
    /// once; after that a cover only changes when the user picks one.
    func fetchMissingCovers() {
        guard Self.downloadsCoversAutomatically else { return }
        for game in games where covers[game.id] == nil && game.coverLookedUp != true {
            let id = game.id
            let name = game.name
            // Marked up front so a second call while this one is in flight doesn't repeat it.
            setCoverLookedUp(true, for: id)
            Task {
                do {
                    if let data = try await CoverFinder.cover(forGameNamed: name), covers[id] == nil,
                       let game = games.first(where: { $0.id == id }) {
                        setCover(data, for: game)
                    }
                } catch {
                    // Offline or the store was unreachable: try again next launch.
                    setCoverLookedUp(nil, for: id)
                }
            }
        }
    }

    private func setCoverLookedUp(_ value: Bool?, for id: UUID) {
        guard let index = games.firstIndex(where: { $0.id == id }) else { return }
        games[index].coverLookedUp = value
        LibraryStore.save(games)
    }

    /// True when removing the game would leave its bottle with nothing in it, so the bottle can go too.
    func isOnlyGame(inItsBottle game: Game) -> Bool {
        game.bottleID != defaultBottleID && !games.contains { $0.id != game.id && $0.bottleID == game.bottleID }
    }

    /// Takes a game out of the library. Its bottle, and whatever is installed there, stays unless
    /// `deletingBottle` is set and no other game uses it.
    func remove(_ game: Game, deletingBottle: Bool = false) {
        let alone = isOnlyGame(inItsBottle: game)
        if !deletingBottle || !alone { stop(game) }
        forget(game)
        LibraryStore.save(games)
        if deletingBottle && alone { discardBottle(game.bottleID) }
    }

    private func forget(_ game: Game) {
        // Taken out on purpose: don't offer it straight back.
        if let appID = game.steamAppID {
            dismissedSteamGames.insert(SteamSuggestion.id(bottleID: game.bottleID, appID: appID))
        }
        games.removeAll { $0.id == game.id }
        running.remove(game.id)
        CoverStore.remove(game.id)
        covers[game.id] = nil
        icons[game.id] = nil
    }

    func logURL(for game: Game) -> URL { Paths.logs.appendingPathComponent("\(game.id.uuidString).log") }

    func showLog(_ game: Game) {
        let url = logURL(for: game)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            errorMessage = "No log yet — \(game.name) hasn't been played."
        }
    }

    func openDriveC(_ game: Game) {
        Task {
            do {
                let (_, prefix) = try await prepared(game)
                NSWorkspace.shared.open(prefix.appendingPathComponent("drive_c", isDirectory: true))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs one of Wine's own tools (winecfg, regedit, …) where the game runs.
    func runTool(_ tool: String, in game: Game) {
        guard runtime != nil else { return }
        Task {
            do {
                let (runtime, prefix) = try await prepared(game)
                start(tool, plan: Launcher.plan(game: game, prefix: prefix, runtime: runtime))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
