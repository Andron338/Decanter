import Foundation

/// Valve's text KeyValues format, which Steam keeps its library and app manifests in:
/// `"key" "value"` pairs and `"key" { … }` blocks.
public indirect enum VDF: Equatable, Sendable {
    case string(String)
    /// Keys are lowercased: Steam's own spelling varies between versions.
    case object([String: VDF])

    public subscript(key: String) -> VDF? {
        guard case .object(let members) = self else { return nil }
        return members[key.lowercased()]
    }

    public var text: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var members: [String: VDF] {
        guard case .object(let members) = self else { return [:] }
        return members
    }

    public static func parse(_ text: String) -> VDF {
        var reader = Reader(characters: Array(text))
        return .object(reader.object())
    }

    private enum Token: Equatable {
        case text(String), open, close
    }

    private struct Reader {
        let characters: [Character]
        var index = 0

        mutating func object() -> [String: VDF] {
            var members: [String: VDF] = [:]
            while case .text(let key)? = next() {
                switch next() {
                case .text(let value)?: members[key.lowercased()] = .string(value)
                case .open?: members[key.lowercased()] = .object(object())
                default: return members
                }
            }
            return members
        }

        mutating func next() -> Token? {
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace {
                    index += 1
                } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                    while index < characters.count, !characters[index].isNewline { index += 1 }
                } else {
                    break
                }
            }
            guard index < characters.count else { return nil }
            let first = characters[index]
            index += 1
            if first == "{" { return .open }
            if first == "}" { return .close }
            var value = ""
            if first == "\"" {
                while index < characters.count, characters[index] != "\"" {
                    if characters[index] == "\\", index + 1 < characters.count {
                        index += 1
                        switch characters[index] {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        case "\\", "\"": value.append(characters[index])
                        default: value += "\\" + String(characters[index])
                        }
                    } else {
                        value.append(characters[index])
                    }
                    index += 1
                }
                index += 1
            } else {
                value.append(first)
                while index < characters.count, !characters[index].isWhitespace, !"{}\"".contains(characters[index]) {
                    value.append(characters[index])
                    index += 1
                }
            }
            return .text(value)
        }
    }
}

/// A game the Windows Steam client in a bottle has finished downloading.
public struct SteamApp: Identifiable, Equatable, Sendable {
    public var appID: Int
    public var name: String
    /// The `steam.exe` that owns the game, and has to start it: most Steam games won't run without it.
    public var client: URL
    /// The game's own folder, under `steamapps/common`.
    public var folder: URL

    public var id: Int { appID }

    /// What to pass `steam.exe` to start the game.
    public var launchArguments: String { "-applaunch \(appID)" }

    /// The cover Steam already downloaded for its own library view, if it has.
    public var cachedCover: URL? {
        let cache = client.deletingLastPathComponent().appendingPathComponent("appcache/librarycache/\(appID)")
        // Newer clients keep each image in a folder of its own inside the app's.
        let files = (FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).sorted { $0.path < $1.path }
        for name in ["library_600x900_2x.jpg", "library_600x900.jpg", "library_capsule.jpg", "header.jpg"] {
            if let file = files.first(where: { $0.lastPathComponent == name }) { return file }
        }
        return nil
    }

    /// The program in the game's folder that most likely is the game, for its icon: the largest one
    /// near the top that isn't an installer or helper. nil if the folder holds no program at all.
    public func mainProgram() -> URL? {
        let base = folder.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey]) else { return nil }
        var found: [(url: URL, depth: Int, size: Int)] = []
        for case let url as URL in walker {
            if walker.level > 3 {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "exe", !GameNaming.isHelperExecutable(url) else { continue }
            found.append((url, walker.level, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        found.sort { ($0.depth, -$0.size, $0.url.path) < ($1.depth, -$1.size, $1.url.path) }
        return found.first { ExecutableInspector.icon(of: $0.url) != nil }?.url ?? found.first?.url
    }
}

/// Reads what the Windows Steam client in a bottle has installed, from Steam's own files.
public enum SteamLibrary {
    /// Things Steam lists as installed apps that aren't games.
    static let tools: Set<Int> = [228980]  // Steamworks Common Redistributables

    /// The Steam clients installed in a prefix, as their `steam.exe`.
    public static func clients(in prefix: URL) -> [URL] {
        var seen = Set<String>()
        return [#"C:\Program Files (x86)\Steam\steam.exe"#, #"C:\Program Files\Steam\steam.exe"#]
            .compactMap { GameInstaller.resolve(windowsPath: $0, prefix: prefix) }
            .filter { seen.insert($0.path).inserted }
    }

    /// Fully downloaded games in every library folder of a Steam client, by name.
    public static func apps(client: URL, prefix: URL) -> [SteamApp] {
        let fm = FileManager.default
        let root = client.deletingLastPathComponent()
        // The client's own folder, plus any library the user added on another drive of the bottle.
        var libraries = [root]
        if let text = try? String(contentsOf: root.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) {
            let folders = VDF.parse(text)["libraryfolders"]?.members ?? [:]
            for key in folders.keys.sorted() {
                guard let path = folders[key]?["path"]?.text,
                      let folder = GameInstaller.resolve(windowsPath: path, prefix: prefix) else { continue }
                libraries.append(folder)
            }
        }
        var apps: [Int: SteamApp] = [:]
        var visited = Set<String>()
        for library in libraries where visited.insert(library.resolvingSymlinksInPath().path.lowercased()).inserted {
            let steamapps = library.appendingPathComponent("steamapps")
            for file in (try? fm.contentsOfDirectory(atPath: steamapps.path)) ?? []
            where file.lowercased().hasPrefix("appmanifest_") && file.lowercased().hasSuffix(".acf") {
                guard let text = try? String(contentsOf: steamapps.appendingPathComponent(file), encoding: .utf8),
                      let app = app(manifest: text, client: client, steamapps: steamapps),
                      apps[app.appID] == nil else { continue }
                apps[app.appID] = app
            }
        }
        return apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// nil for tools, and for games that are still downloading or whose files are gone.
    static func app(manifest: String, client: URL, steamapps: URL) -> SteamApp? {
        let state = VDF.parse(manifest)["appstate"]
        guard let appID = state?["appid"]?.text.flatMap(Int.init), !tools.contains(appID),
              let name = state?["name"]?.text, !name.isEmpty,
              let installDir = state?["installdir"]?.text, !installDir.isEmpty,
              // Bit 4 is "fully installed"; a download or update in progress doesn't have it alone.
              let flags = state?["stateflags"]?.text.flatMap(Int.init), flags & 4 != 0 else { return nil }
        let folder = steamapps.appendingPathComponent("common").appendingPathComponent(installDir)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return SteamApp(appID: appID, name: name, client: client, folder: folder)
    }
}
