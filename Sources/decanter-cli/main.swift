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
            } else {
                print("\(url.lastPathComponent): not a Windows executable")
            }
        }
    default:
        print("usage: decanter-cli [setup|d3dmetal|crossover|status|inspect <exe>…]")
        exit(2)
    }
} catch {
    print("error: \(error.localizedDescription)")
    exit(1)
}
