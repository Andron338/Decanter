import DecanterCore
import Foundation

// Headless driver for the same setup code the app uses. Handy for testing and scripting.
setvbuf(stdout, nil, _IOLBF, 0)
let command = CommandLine.arguments.dropFirst().first ?? "status"
var lastStage = ""
let report: ProgressHandler = { progress in
    let percent = progress.fraction.map { " \(Int($0 * 100))%" } ?? ""
    let line = progress.stage + percent
    // Only print each 10% step so logs stay readable.
    if progress.fraction == nil || Int((progress.fraction ?? 0) * 100) % 10 == 0, line != lastStage {
        lastStage = line
        print(line)
    }
}

/// Runs an installer in a new bottle, which the app then lists like any other, and prints what it added.
func install(_ file: URL, bottleName: String, engine: Engine, arguments: String) async throws {
    guard var runtime = RuntimeManager.load() else { throw DecanterError("Run `decanter-cli setup` first.") }
    // The optional engines are fetched the first time something is installed on them, as in the app.
    if engine == .sikarugir, !runtime.hasSikarugir || runtime.sikarugirLacksDXMT { runtime = try await RuntimeManager.installSikarugir(into: runtime, progress: report) }
    if engine == .crossover, !runtime.hasCrossOver { runtime = try await RuntimeManager.installCrossOver(into: runtime, progress: report) }
    guard runtime.has(engine) else { throw DecanterError("That engine isn't installed.") }
    var list = BottleStore.loadAdopting()
    var bottle = Bottle(name: bottleName)
    let prefixID = try await BottleStore.ensurePrefix(for: engine, in: bottle)
    bottle.prefixes[engine.rawValue] = prefixID
    bottle.lastEngine = engine.rawValue
    list.bottles.append(bottle)
    BottleStore.save(list)
    let prefix = BottleStore.prefix(prefixID)
    GameInstaller.isolateDesktop(prefix: prefix)
    let before = BottleSnapshot.take(prefix: prefix)
    print("Running the installer in bottle “\(bottle.name)” (\(prefixID.uuidString))…")
    try await GameInstaller.run(file, prefix: prefix, engine: engine, runtime: runtime, arguments: arguments)
    let programs = GameInstaller.installedPrograms(prefix: prefix, since: before)
    if programs.isEmpty { print("Nothing new was installed.") }
    let choice = GameInstaller.obviousChoice(among: programs)
    for program in programs {
        print("\(program == choice ? "→" : " ") \(program.name)\(program.hasShortcut ? " (shortcut)" : ""): \(program.executable.path)")
    }
}

do {
    switch command {
    case "setup":
        print(try await RuntimeManager.setup(progress: report).summary)
    case "d3dmetal":
        guard let runtime = RuntimeManager.load() else { throw DecanterError("Run `decanter-cli setup` first.") }
        print(try await RuntimeManager.installD3DMetal(into: runtime, progress: report).summary)
    case "crossover":
        guard let runtime = RuntimeManager.load() else { throw DecanterError("Run `decanter-cli setup` first.") }
        print(try await RuntimeManager.installCrossOver(into: runtime, progress: report).summary)
    case "sikarugir":
        guard let runtime = RuntimeManager.load() else { throw DecanterError("Run `decanter-cli setup` first.") }
        print(try await RuntimeManager.installSikarugir(into: runtime, progress: report).summary)
    case "status":
        if let runtime = RuntimeManager.load() {
            print(runtime.summary)
            for renderer in Renderer.allCases {
                print("  \(renderer.rawValue): \(runtime.wine(for: renderer).path)")
            }
        } else {
            print("Not set up. Data folder: \(Paths.root.path)")
        }
    case "inspect":
        for path in CommandLine.arguments.dropFirst(2) {
            let url = URL(fileURLWithPath: path)
            if let found = ExecutableInspector.inspect(url) {
                print("\(url.lastPathComponent): \(found.summary) → \(found.recommendedRenderer?.rawValue ?? "default")")
                if let kind = InstallerDetector.kind(of: url) { print("  \(kind.displayName)") }
            } else {
                print("\(url.lastPathComponent): not a Windows executable")
            }
        }
    case "icon":
        // decanter-cli icon <exe> <out.ico>: the icon Decanter shows for a game without a cover.
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard arguments.count == 2 else { throw DecanterError("usage: decanter-cli icon <exe> <out.ico>") }
        guard let icon = ExecutableInspector.icon(of: URL(fileURLWithPath: arguments[0])) else {
            throw DecanterError("\(arguments[0]) has no icon.")
        }
        try icon.write(to: URL(fileURLWithPath: arguments[1]))
        print("Wrote \(icon.count) bytes")
    case "install":
        // decanter-cli install <installer> [wine|crossover|gptk] [installer arguments]
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard let path = arguments.first else { throw DecanterError("usage: decanter-cli install <installer> [engine]") }
        let file = URL(fileURLWithPath: path)
        try await install(file, bottleName: GameNaming.displayName(for: file),
                          engine: arguments.dropFirst().first.flatMap(Engine.init(rawValue:)) ?? .wine,
                          arguments: arguments.dropFirst(2).joined(separator: " "))
    case "steam":
        // decanter-cli steam [wine|crossover|gptk] [installer arguments]: what the app's "Install Steam…" does.
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        print("Downloading \(SteamInstaller.source.absoluteString)…")
        let file = try await SteamInstaller.download()
        print("Saved \(file.path)\(InstallerDetector.kind(of: file).map { " (\($0.displayName))" } ?? "")")
        try await install(file, bottleName: SteamInstaller.bottleName,
                          engine: arguments.first.flatMap(Engine.init(rawValue:)) ?? SteamInstaller.engine,
                          arguments: arguments.dropFirst().joined(separator: " "))
    case "scan":
        // decanter-cli scan <prefix id> [engine]: everything in a prefix that its template didn't have.
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard let id = arguments.first.flatMap(UUID.init(uuidString:)) else { throw DecanterError("usage: decanter-cli scan <prefix id> [engine]") }
        let engine = arguments.dropFirst().first.flatMap(Engine.init(rawValue:)) ?? .wine
        let template = BottleSnapshot.take(prefix: BottleStore.templatePrefix(engine))
        for program in GameInstaller.installedPrograms(prefix: BottleStore.prefix(id), since: template) {
            print("\(program.name)\(program.hasShortcut ? " (shortcut)" : ""): \(program.executable.path) \(program.arguments)")
        }
    case "steam-games":
        // decanter-cli steam-games: what the app offers to add from the Steam clients in every bottle.
        for bottle in BottleStore.load().bottles {
            for engine in bottle.engines {
                guard let prefix = bottle.prefix(for: engine) else { continue }
                for client in SteamLibrary.clients(in: prefix) {
                    for app in SteamLibrary.apps(client: client, prefix: prefix) {
                        print("\(app.appID) \(app.name) [\(bottle.displayName), \(engine.rawValue)]")
                        print("  icon from: \(app.mainProgram()?.path ?? "none")")
                        print("  cover: \(app.cachedCover?.path ?? "none")")
                    }
                }
            }
        }
    default:
        print("usage: decanter-cli [setup|d3dmetal|crossover|sikarugir|status|inspect <exe>…|icon <exe> <out.ico>|install <installer> [engine]|steam [engine]|steam-games|scan <prefix id> [engine]]")
        exit(2)
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
