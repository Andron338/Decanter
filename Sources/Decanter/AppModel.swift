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
}

/// What an installer left behind, when Decanter needs the user to say which program is the game.
struct InstallerResult: Identifiable {
    let id = UUID()
    let bottleID: UUID
    let engine: Engine
    var programs: [InstalledProgram]
}

/// An installer that is running right now.
struct ActiveInstall: Equatable {
    let bottleID: UUID
    let engine: Engine
    /// false when it runs inside an existing game's bottle (a patch, DLC or missing component).
    let isNewGame: Bool
}

@MainActor
@Observable
final class AppModel {
    var runtime: InstalledRuntime? = RuntimeManager.load()
    var games: [Game] = AppModel.loadLibrary()
    var setupState: SetupState = .needed
    var busyMessage: String?
    var errorMessage: String?
    var running: Set<UUID> = []
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

    static var downloadsCoversAutomatically: Bool {
        UserDefaults.standard.object(forKey: "autoCovers") as? Bool ?? true
    }

    init() {
        for game in games { loadArtwork(for: game) }
        fetchMissingCovers()
    }

    /// Games added before detection existed get inspected once; their renderer choice is left alone
    /// unless it was still the untouched default.
    private static func loadLibrary() -> [Game] {
        var games = LibraryStore.load()
        var changed = false
        for index in games.indices where games[index].requirements == nil {
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
            install(url, engine: .wine)
        } else {
            addExecutable(url)
        }
    }

    private func isWindowsProgram(_ url: URL) -> Bool {
        if ["exe", "msi"].contains(url.pathExtension.lowercased()) { return true }
        errorMessage = "“\(url.lastPathComponent)” isn't a Windows program. Drop a .exe or .msi file."
        return false
    }

    /// Adds a game that is already installed (or portable) somewhere on disk.
    private func addExecutable(_ url: URL) {
        guard busyMessage == nil else { return }
        busyMessage = "Preparing a fresh Windows environment…"
        Task {
            defer { busyMessage = nil }
            do {
                let bottleID = UUID()
                try await BottleStore.create(bottleID)
                var game = Game(name: GameNaming.displayName(for: url), executablePath: url.path, bottleID: bottleID)
                game.inspect(chooseRenderer: true)
                games.append(game)
                LibraryStore.save(games)
                loadArtwork(for: game)
                fetchMissingCovers()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Installing

    /// Treats the file as an installer no matter what it's called, after asking which engine to use.
    func requestInstall(_ url: URL) {
        guard runtime != nil, isWindowsProgram(url) else { return }
        installRequest = InstallRequest(installer: url, kind: InstallerDetector.kind(of: url))
    }

    /// Runs an installer in a new bottle for `engine`, then adds what it installed to the library.
    func install(_ url: URL, engine: Engine) {
        guard busyMessage == nil else { return }
        busyMessage = "Preparing a fresh Windows environment…"
        installCancelled = false
        Task {
            defer {
                busyMessage = nil
                activeInstall = nil
            }
            var created: UUID?
            do {
                let runtime = try await readyRuntime(for: GameInstaller.renderer(for: engine))
                let bottleID = try await GameInstaller.prepareBottle(engine: engine)
                created = bottleID
                busyMessage = "Running the installer. Finish it, and Decanter will pick up from there."
                activeInstall = ActiveInstall(bottleID: bottleID, engine: engine, isNewGame: true)
                try await GameInstaller.run(url, bottleID: bottleID, engine: engine, runtime: runtime)
                activeInstall = nil
                if installCancelled {
                    BottleStore.delete(bottleID)
                    return
                }
                busyMessage = "Looking for the game…"
                let programs = await Task.detached {
                    GameInstaller.installedPrograms(bottleID: bottleID, engine: engine)
                }.value
                if let choice = GameInstaller.obviousChoice(among: programs) {
                    try await addInstalled([choice], bottleID: bottleID, engine: engine)
                } else {
                    installerResult = InstallerResult(bottleID: bottleID, engine: engine, programs: programs)
                }
            } catch {
                if let created { BottleStore.delete(created) }
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Abandons a running install and throws away its bottle.
    func cancelInstall() {
        installCancelled = true
        finishInstall()
    }

    /// Ends whatever is still running in the installer's bottle, for installers that leave a launcher
    /// or the game itself open, so Decanter can carry on.
    func finishInstall() {
        guard let runtime, let active = activeInstall else { return }
        busyMessage = installCancelled ? "Cancelling…" : "Finishing up…"
        Task { await GameInstaller.stop(bottleID: active.bottleID, engine: active.engine, runtime: runtime) }
    }

    /// Adds installed programs as games. They share the bottle the installer ran in.
    func addInstalled(_ programs: [InstalledProgram], bottleID: UUID, engine: Engine) async throws {
        // Every game needs a bottle for the standard engine; the install lives in the one it ran on.
        var standardBottle = bottleID
        if engine != .wine {
            standardBottle = UUID()
            try await BottleStore.create(standardBottle)
        }
        for program in programs {
            var game = Game(name: program.name, executablePath: program.executable.path, bottleID: standardBottle)
            game.settings.arguments = program.arguments
            game.inspect(chooseRenderer: true)
            if engine != .wine {
                game.setBottle(bottleID, for: engine)
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
        Task {
            do {
                try await addInstalled(programs, bottleID: result.bottleID, engine: result.engine)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Lets the user point at the game inside the bottle when Decanter couldn't find it.
    func browseInstalled(_ result: InstallerResult) -> InstalledProgram? {
        let panel = NSOpenPanel()
        panel.directoryURL = BottleStore.driveC(result.bottleID)
        panel.allowedContentTypes = [.exe]
        panel.message = "Choose the game's program"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return InstalledProgram(executable: url, name: GameNaming.displayName(for: url))
    }

    func discardInstallerResult(_ result: InstallerResult) {
        BottleStore.delete(result.bottleID)
    }

    /// Runs a patch, DLC or component installer inside a game's existing bottle.
    func runInstaller(in game: Game) {
        guard runtime != nil, busyMessage == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.exe, UTType(filenameExtension: "msi") ?? .data]
        panel.message = "Choose a patch, add-on or installer to run in \(game.name)'s Windows environment"
        panel.prompt = "Run"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busyMessage = "Preparing…"
        Task {
            defer {
                busyMessage = nil
                activeInstall = nil
            }
            do {
                let game = try await prepared(game)
                guard let runtime else { return }
                let engine = runtime.engine(for: game.settings.renderer)
                let bottleID = game.bottle(for: engine)
                busyMessage = "Running \(url.lastPathComponent) for \(game.name)…"
                activeInstall = ActiveInstall(bottleID: bottleID, engine: engine, isNewGame: false)
                try await GameInstaller.run(url, bottleID: bottleID, engine: engine, runtime: runtime)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
        return runtime
    }

    /// Gets everything a game's chosen engine needs in place before launch: downloads the CrossOver
    /// engine the first time a game wants it, and creates the game's bottle for that engine.
    private func prepared(_ game: Game) async throws -> Game {
        let runtime = try await readyRuntime(for: game.settings.renderer)
        let engine = runtime.engine(for: game.settings.renderer)
        guard game.existingBottle(for: engine) == nil,
              let index = games.firstIndex(where: { $0.id == game.id }) else { return game }
        let id = UUID()
        try await BottleStore.create(id, engine: engine)
        games[index].setBottle(id, for: engine)
        LibraryStore.save(games)
        return games[index]
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
                let game = try await prepared(game)
                guard let runtime else { return }
                if let index = games.firstIndex(where: { $0.id == id }) {
                    games[index].lastPlayed = Date()
                    LibraryStore.save(games)
                }
                await Launcher.applyRegistrySettings(game: game, runtime: runtime)
                let started = Date()
                _ = try Launcher.start(Launcher.plan(game: game, runtime: runtime), log: logURL(for: game)) { status in
                    Task { @MainActor in
                        self.running.remove(id)
                        self.addPlayTime(Date().timeIntervalSince(started), to: id)
                        if status != 0 && Date().timeIntervalSince(started) < 10 {
                            self.errorMessage = "\(game.name) quit right after starting. "
                                + "Open its settings to try a different renderer or a fixed-size window, or check the log."
                        }
                    }
                }
            } catch {
                running.remove(id)
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop(_ game: Game) {
        guard let runtime else { return }
        Task {
            await Launcher.stop(game, runtime: runtime)
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
        icons[game.id] = ExecutableInspector.icon(of: URL(fileURLWithPath: game.executablePath))
            .flatMap(NSImage.init(data:))
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

    func remove(_ game: Game) {
        stop(game)
        games.removeAll { $0.id == game.id }
        LibraryStore.save(games)
        CoverStore.remove(game.id)
        covers[game.id] = nil
        icons[game.id] = nil
        for bottle in game.bottles where !games.contains(where: { $0.bottles.contains(bottle) }) {
            BottleStore.delete(bottle)
        }
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
        let engine = runtime?.engine(for: game.settings.renderer) ?? .wine
        NSWorkspace.shared.open(BottleStore.driveC(game.bottle(for: engine)))
    }

    /// Runs one of Wine's own tools (winecfg, regedit, …) inside the game's bottle.
    func runTool(_ tool: String, in game: Game) {
        guard runtime != nil else { return }
        Task {
            do {
                let game = try await prepared(game)
                guard let runtime else { return }
                var plan = Launcher.plan(game: game, runtime: runtime)
                plan.arguments = [tool]
                _ = try Launcher.start(plan, log: Paths.logs.appendingPathComponent("tools.log")) { _ in }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
