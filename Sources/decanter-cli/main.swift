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
    case "install":
        // decanter-cli install <installer> [wine|crossover|gptk] [installer arguments]
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard let path = arguments.first else { throw DecanterError("usage: decanter-cli install <installer> [engine]") }
        guard let runtime = RuntimeManager.load() else { throw DecanterError("Run `decanter-cli setup` first.") }
        let engine = arguments.dropFirst().first.flatMap(Engine.init(rawValue:)) ?? .wine
        let bottleID = try await GameInstaller.prepareBottle(engine: engine)
        print("Running the installer in bottle \(bottleID.uuidString)…")
        try await GameInstaller.run(URL(fileURLWithPath: path), bottleID: bottleID, engine: engine, runtime: runtime,
                                    arguments: arguments.dropFirst(2).joined(separator: " "))
        let programs = GameInstaller.installedPrograms(bottleID: bottleID, engine: engine)
        if programs.isEmpty { print("Nothing new was installed.") }
        let choice = GameInstaller.obviousChoice(among: programs)
        for program in programs {
            print("\(program == choice ? "→" : " ") \(program.name)\(program.hasShortcut ? " (shortcut)" : ""): \(program.executable.path)")
        }
    case "scan":
        // decanter-cli scan <bottle id> [engine]: what an installer left in a bottle.
        let arguments = Array(CommandLine.arguments.dropFirst(2))
        guard let id = arguments.first.flatMap(UUID.init(uuidString:)) else { throw DecanterError("usage: decanter-cli scan <bottle id> [engine]") }
        let engine = arguments.dropFirst().first.flatMap(Engine.init(rawValue:)) ?? .wine
        for program in GameInstaller.installedPrograms(bottleID: id, engine: engine) {
            print("\(program.name)\(program.hasShortcut ? " (shortcut)" : ""): \(program.executable.path) \(program.arguments)")
        }
    default:
        print("usage: decanter-cli [setup|d3dmetal|crossover|status|inspect <exe>…|install <installer> [engine]|scan <bottle id> [engine]]")
        exit(2)
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
