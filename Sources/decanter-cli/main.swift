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
        guard let runtime = RuntimeManager.load() else { throw DecanterError("Run `decanter-cli setup` first.") }
        let engine = arguments.dropFirst().first.flatMap(Engine.init(rawValue:)) ?? .wine
        // Installs go in a bottle of their own, which the app then lists like any other.
        var list = BottleStore.loadAdopting()
        var bottle = Bottle(name: GameNaming.displayName(for: URL(fileURLWithPath: path)))
        let prefixID = try await BottleStore.ensurePrefix(for: engine, in: bottle)
        bottle.prefixes[engine.rawValue] = prefixID
        bottle.lastEngine = engine.rawValue
        list.bottles.append(bottle)
        BottleStore.save(list)
        let prefix = BottleStore.prefix(prefixID)
        GameInstaller.isolateDesktop(prefix: prefix)
        let before = BottleSnapshot.take(prefix: prefix)
        print("Running the installer in bottle “\(bottle.name)” (\(prefixID.uuidString))…")
        try await GameInstaller.run(URL(fileURLWithPath: path), prefix: prefix, engine: engine, runtime: runtime,
                                    arguments: arguments.dropFirst(2).joined(separator: " "))
        let programs = GameInstaller.installedPrograms(prefix: prefix, since: before)
        if programs.isEmpty { print("Nothing new was installed.") }
        let choice = GameInstaller.obviousChoice(among: programs)
        for program in programs {
            print("\(program == choice ? "→" : " ") \(program.name)\(program.hasShortcut ? " (shortcut)" : ""): \(program.executable.path)")
        }
    case "scan":
        // decanter-cli scan <prefix id> [engine]: everything in a prefix that its template didn't have.
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard let id = arguments.first.flatMap(UUID.init(uuidString:)) else { throw DecanterError("usage: decanter-cli scan <prefix id> [engine]") }
        let engine = arguments.dropFirst().first.flatMap(Engine.init(rawValue:)) ?? .wine
        let template = BottleSnapshot.take(prefix: BottleStore.templatePrefix(engine))
        for program in GameInstaller.installedPrograms(prefix: BottleStore.prefix(id), since: template) {
            print("\(program.name)\(program.hasShortcut ? " (shortcut)" : ""): \(program.executable.path) \(program.arguments)")
        }
    default:
        print("usage: decanter-cli [setup|d3dmetal|crossover|status|inspect <exe>…|icon <exe> <out.ico>|install <installer> [engine]|scan <prefix id> [engine]]")
        exit(2)
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
