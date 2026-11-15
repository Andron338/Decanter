import Foundation
import os

private let log = Logger(subsystem: "app.decanter.Decanter", category: "GameProcesses")

/// Follows a game Steam starts by the game's own processes rather than by `steam.exe`.
///
/// `steam.exe -applaunch <id>` hands the game to a Steam that is already running and exits within
/// seconds; when Steam wasn't running it *becomes* Steam and lives as long as the client does.
/// Either way its lifetime says nothing about the game's. Wine shows each Windows process under its
/// command line (`C:\Program Files (x86)\Steam\steamapps\common\Game\game.exe -flag`, sometimes after
/// the loader's own path), so the game can be found with `ps` like any Mac process.
public enum GameProcesses {
    /// What identifies a game's processes in `ps`. Matched ignoring case.
    public struct Watch: Equatable, Sendable {
        /// The program's file name, `riseofnations.exe`; empty when only the folder is known.
        public var name: String
        /// The game's own folder as Windows and as the Mac see it, each ending in its separator.
        /// Anything started from there counts: Unreal's launcher stub starts a `-Shipping.exe` in a
        /// subfolder, and the stub may quit first.
        public var folders: [String]
    }

    /// The watch for a game Steam starts, nil for any other game (its own process is the game) and
    /// for one where neither the game's program nor its folder is known (only `steam.exe` would be).
    ///
    /// The folder comes from Steam's own manifest for the app, which also covers a game set up by
    /// hand as `steam.exe -applaunch <id>`; failing that, from the game's program.
    public static func watch(for game: Game, prefix: URL) -> Watch? {
        guard Launcher.startsThroughSteam(game) else { return nil }
        var name = ""
        var folders: [URL] = []
        if let appID = steamAppID(of: game),
           let app = SteamLibrary.apps(client: URL(fileURLWithPath: game.executablePath), prefix: prefix)
            .first(where: { $0.appID == appID }) {
            folders.append(app.folder.standardizedFileURL)
        }
        let program = URL(fileURLWithPath: game.programPath).standardizedFileURL
        if program.lastPathComponent.lowercased() != "steam.exe", program.pathExtension.lowercased() == "exe" {
            name = program.lastPathComponent.lowercased()
            if isGameFolder(program.deletingLastPathComponent()) { folders.append(program.deletingLastPathComponent()) }
        }
        var patterns: [String] = []
        for folder in folders {
            var forms = [folder.path.lowercased() + "/"]
            if let windows = Launcher.cDrivePath(folder, prefix: prefix) { forms.append(windows.lowercased() + "\\") }
            for form in forms where !patterns.contains(form) { patterns.append(form) }
        }
        guard !name.isEmpty || !patterns.isEmpty else { return nil }
        return Watch(name: name, folders: patterns)
    }

    /// The Steam app a game starts: its own, or the one in `-applaunch <id>` for one set up by hand.
    static func steamAppID(of game: Game) -> Int? {
        if let id = game.steamAppID { return id }
        let arguments = Launcher.splitArguments(game.settings.arguments)
        guard let index = arguments.firstIndex(where: { $0.lowercased() == "-applaunch" }),
              index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    /// Only a folder of the game's own: one loose in Steam's folder or C:\ would match far too much.
    static func isGameFolder(_ folder: URL) -> Bool {
        let lowered = folder.standardizedFileURL.path.lowercased()
        guard let common = lowered.range(of: "/steamapps/common/") else { return false }
        return !lowered[common.upperBound...].isEmpty
    }

    /// Whether one `ps` command line belongs to the watched game.
    public static func matches(_ commandLine: String, _ watch: Watch) -> Bool {
        let line = commandLine.lowercased()
        if watch.folders.contains(where: { line.contains($0) }) { return true }
        guard !watch.name.isEmpty else { return false }
        // By name alone: as a whole path component followed by the end, a space or a quote, so that
        // `game.exe` isn't found inside `mygame.exe` or `game.exe.bak`.
        var searchStart = line.startIndex
        while let found = line.range(of: watch.name, range: searchStart..<line.endIndex) {
            let before = found.lowerBound == line.startIndex ? nil : line[line.index(before: found.lowerBound)]
            let after = found.upperBound == line.endIndex ? nil : line[found.upperBound]
            let startsComponent = before == nil || before == "\\" || before == "/" || before == "\"" || before == " "
            let endsComponent = after == nil || after == " " || after == "\""
            if startsComponent && endsComponent { return true }
            searchStart = found.upperBound
        }
        return false
    }

    /// The command line of every process the user can see.
    @Sendable public static func commandLines() async -> [String] {
        guard let result = try? await Shell.run(URL(fileURLWithPath: "/bin/ps"), ["-axww", "-o", "args="], check: false),
              result.status == 0 else { return [] }
        return result.output.split(separator: "\n").map(String.init)
    }

    /// Waits for the game to start and then to quit, and returns how long it ran; nil if it never
    /// started. It stops waiting for the start after `appearWithin`, or as soon as `stillStarting`
    /// says nothing is running for it any more (Steam was quit or the bottle stopped).
    public static func waitForSession(
        of watch: Watch,
        appearWithin: Duration = .seconds(300),
        poll: Duration = .seconds(2),
        stillStarting: @Sendable () async -> Bool = { true },
        commandLines: @Sendable () async -> [String] = GameProcesses.commandLines
    ) async -> TimeInterval? {
        let clock = ContinuousClock()
        let deadline = clock.now + appearWithin
        func running() async -> Bool { await commandLines().contains { matches($0, watch) } }
        let label = watch.name.isEmpty ? "the game" : watch.name

        log.notice("Waiting for \(label, privacy: .public): \(watch.name, privacy: .public) or anything in \(watch.folders, privacy: .public)")
        var polls = 0
        while !(await running()) {
            polls += 1
            guard clock.now < deadline, !Task.isCancelled, await stillStarting() else {
                log.notice("Gave up waiting for \(label, privacy: .public) after \(polls) polls")
                return nil
            }
            try? await Task.sleep(for: poll)
        }
        log.notice("\(label, privacy: .public) is running")
        let started = clock.now
        var lastSeen = started
        // A launcher can hand over to the real game a moment after quitting, so the game only
        // counts as quit once it has been gone for two polls in a row.
        var missed = 0
        while missed < 2, !Task.isCancelled {
            try? await Task.sleep(for: poll)
            if await running() {
                missed = 0
                lastSeen = clock.now
            } else {
                missed += 1
            }
        }
        let elapsed = lastSeen - started
        log.notice("\(label, privacy: .public) quit after \(elapsed.components.seconds) s")
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
}
