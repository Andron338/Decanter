import AppKit
import DecanterCore
import Observation

enum SetupState: Equatable {
    case needed
    case working(stage: String, fraction: Double?)
    case failed(String)
}

struct InstallerResult: Identifiable {
    let id = UUID()
    let bottleID: UUID
    let executables: [URL]
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
    var editing: Game?
    /// nil when idle; progress or failure of the optional D3DMetal download.
    var d3dMetalInstall: SetupState?

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
        guard let runtime else { return }
        guard ["exe", "msi"].contains(url.pathExtension.lowercased()) else {
            errorMessage = "“\(url.lastPathComponent)” isn't a Windows program. Drop a .exe or .msi file."
            return
        }
        guard busyMessage == nil else { return }
        busyMessage = "Preparing a fresh Windows environment…"
        Task {
            defer { busyMessage = nil }
            let bottleID = UUID()
            do {
                try await BottleStore.create(bottleID)
                guard GameNaming.looksLikeInstaller(url) else {
                    appendGame(executable: url, bottleID: bottleID)
                    return
                }
                busyMessage = "Running the installer — finish it, and Decanter will pick up from there."
                let installer = Game(name: "Installer", executablePath: url.path, bottleID: bottleID)
                try await Launcher.runAndWait(
                    Launcher.plan(game: installer, runtime: runtime), runtime: runtime, renderer: .metal)
                let found = BottleStore.installedExecutables(bottleID)
                if found.isEmpty {
                    BottleStore.delete(bottleID)
                    errorMessage = "The installer finished but nothing was installed. If it was cancelled, just drop it again."
                } else if found.count == 1 {
                    appendGame(executable: found[0], bottleID: bottleID)
                } else {
                    installerResult = InstallerResult(bottleID: bottleID, executables: found)
                }
            } catch {
                BottleStore.delete(bottleID)
                errorMessage = error.localizedDescription
            }
        }
    }

    func appendGame(executable: URL, bottleID: UUID) {
        var game = Game(name: GameNaming.displayName(for: executable), executablePath: executable.path, bottleID: bottleID)
        game.inspect(chooseRenderer: true)
        games.append(game)
        LibraryStore.save(games)
    }

    func cancelInstallerResult(_ result: InstallerResult) {
        BottleStore.delete(result.bottleID)
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

    /// Gets everything a game's chosen engine needs in place before launch: downloads the CrossOver
    /// engine the first time a game wants it, and creates the game's bottle for that engine.
    private func prepared(_ game: Game) async throws -> Game {
        guard var runtime else { return game }
        if game.settings.renderer == .crossover && !runtime.hasCrossOver {
            busyMessage = "Getting the engine for older games (about 165 MB, one time)…"
            defer { busyMessage = nil }
            runtime = try await RuntimeManager.installCrossOver(into: runtime) { progress in
                Task { @MainActor in
                    guard self.busyMessage != nil else { return }
                    let percent = progress.fraction.map { " \(Int($0 * 100))%" } ?? ""
                    self.busyMessage = progress.stage + percent
                }
            }
            self.runtime = runtime
        }
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
        games[index] = game
        LibraryStore.save(games)
    }

    func remove(_ game: Game) {
        stop(game)
        games.removeAll { $0.id == game.id }
        LibraryStore.save(games)
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
