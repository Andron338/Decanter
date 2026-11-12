import Foundation

/// The installer technologies Decanter can recognise from the file itself, whatever it is named.
public enum InstallerKind: String, Sendable, CaseIterable {
    case msi
    case innoSetup
    case nsis
    case installShield
    case wix

    public var displayName: String {
        switch self {
        case .msi: return "Windows Installer package"
        case .innoSetup: return "Inno Setup installer"
        case .nsis: return "NSIS installer"
        case .installShield: return "InstallShield installer"
        case .wix: return "WiX installer"
        }
    }
}

public enum InstallerDetector {
    /// Text each installer builder leaves in its stub (manifest, version info or section names).
    static let signatures: [(kind: InstallerKind, markers: [String])] = [
        (.innoSetup, ["Inno Setup", "JR.Inno.Setup"]),
        (.nsis, ["Nullsoft.NSIS", "NullsoftInst", "Nullsoft Install System"]),
        (.wix, [".wixburn", "WixBundle"]),
        (.installShield, ["InstallShield"]),
    ]

    /// nil when the file doesn't look like an installer. GOG's offline installers are Inno Setup.
    public static func kind(of url: URL) -> InstallerKind? {
        if url.pathExtension.lowercased() == "msi" { return .msi }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return kind(of: data)
    }

    static func kind(of data: Data) -> InstallerKind? {
        guard let image = PEImage(data: data) else { return nil }
        // Only the program part: the payload behind it is compressed, and huge.
        let stub = data.prefix(min(image.imageEnd, 16 << 20))
        for (kind, markers) in signatures {
            for marker in markers
            where contains(stub, Array(marker.utf8)) || contains(stub, Array(marker.utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) {
                return kind
            }
        }
        return nil
    }

    private static func contains(_ haystack: Data, _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            memmem(bytes.baseAddress, bytes.count, needle, needle.count) != nil
        }
    }
}

/// The parts of a Windows `.lnk` shortcut that say what it starts ([MS-SHLLINK]).
public struct WindowsShortcut: Equatable, Sendable {
    /// Windows path of the program, e.g. `C:\Games\Foo\foo.exe`.
    public var target: String
    public var arguments = ""
    public var workingDirectory = ""

    public init?(url: URL) {
        guard let data = try? Data(contentsOf: url), data.count < 1 << 20 else { return nil }
        self.init(data: data)
    }

    public init?(data: Data) {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int? {
            offset >= 0 && offset + 2 <= bytes.count ? Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 : nil
        }
        func u32(_ offset: Int) -> Int? {
            guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
            return low | high << 16
        }
        func ansi(at offset: Int) -> String? {
            guard offset >= 0, offset < bytes.count else { return nil }
            let end = bytes[offset...].firstIndex(of: 0) ?? bytes.count
            let raw = Array(bytes[offset..<end])
            return String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .windowsCP1252)
        }
        func wide(at offset: Int, maxUnits: Int = 4096) -> String? {
            guard offset >= 0, offset < bytes.count else { return nil }
            var units: [UInt16] = []
            var index = offset
            while units.count < maxUnits, let unit = u16(index), unit != 0 {
                units.append(UInt16(unit))
                index += 2
            }
            return String(decoding: units, as: UTF16.self)
        }

        let classID: [UInt8] = [0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46]
        guard u32(0) == 0x4C, bytes.count >= 0x4C, Array(bytes[4..<20]) == classID, let flags = u32(0x14) else { return nil }
        var offset = 0x4C
        var path = ""

        if flags & 0x1 != 0 {  // HasLinkTargetIDList
            guard let size = u16(offset) else { return nil }
            offset += 2 + size
        }
        if flags & 0x2 != 0 {  // HasLinkInfo
            guard let size = u32(offset), let headerSize = u32(offset + 4), let infoFlags = u32(offset + 8),
                  size >= 0x1C, offset + size <= bytes.count else { return nil }
            if infoFlags & 0x1 != 0 {  // VolumeIDAndLocalBasePath
                var base: String?, suffix: String?
                if headerSize >= 0x24, let baseOffset = u32(offset + 28), let suffixOffset = u32(offset + 32) {
                    if baseOffset != 0 { base = wide(at: offset + baseOffset) }
                    if suffixOffset != 0 { suffix = wide(at: offset + suffixOffset) }
                }
                if base == nil, let baseOffset = u32(offset + 16), baseOffset != 0 { base = ansi(at: offset + baseOffset) }
                if suffix == nil, let suffixOffset = u32(offset + 24), suffixOffset != 0 { suffix = ansi(at: offset + suffixOffset) }
                path = (base ?? "") + (suffix ?? "")
            }
            offset += size
        }

        // StringData, always in this order: name, relative path, working directory, arguments, icon.
        let unicode = flags & 0x80 != 0
        var strings: [Int: String] = [:]
        for flag in [0x4, 0x8, 0x10, 0x20, 0x40] where flags & flag != 0 {
            guard let count = u16(offset) else { break }
            let length = unicode ? count * 2 : count
            guard offset + 2 + length <= bytes.count else { break }
            let raw = Array(bytes[(offset + 2)..<(offset + 2 + length)])
            strings[flag] = unicode
                ? String(decoding: stride(from: 0, to: raw.count - 1, by: 2).map { UInt16(raw[$0]) | UInt16(raw[$0 + 1]) << 8 }, as: UTF16.self)
                : String(bytes: raw, encoding: .utf8) ?? String(bytes: raw, encoding: .windowsCP1252) ?? ""
            offset += 2 + length
        }
        workingDirectory = strings[0x10] ?? ""
        arguments = strings[0x20] ?? ""

        // Shortcuts to `%ProgramFiles%\…` style paths keep the target in an extra data block instead.
        if path.isEmpty {
            while let size = u32(offset), size >= 8, offset + size <= bytes.count {
                if u32(offset + 4) == 0xA000_0001, size >= 0x314 {
                    path = wide(at: offset + 8 + 260, maxUnits: 260) ?? ""
                    if path.isEmpty { path = ansi(at: offset + 8) ?? "" }
                    break
                }
                offset += size
            }
        }
        // Last resort: a relative path only makes sense from the working directory.
        if path.isEmpty, let relative = strings[0x8], !workingDirectory.isEmpty {
            path = workingDirectory + "\\" + (relative.split(separator: "\\").last.map(String.init) ?? relative)
        }
        guard !path.isEmpty else { return nil }
        target = path
    }
}

/// Something an installer put in a bottle that could be the game.
public struct InstalledProgram: Identifiable, Equatable, Sendable {
    public var executable: URL
    public var name: String
    /// Launch arguments carried by the shortcut, if any.
    public var arguments = ""
    /// The installer made a Start menu or desktop shortcut for it, the strongest hint that it is the game.
    public var hasShortcut = false

    public var id: String { executable.path }

    public init(executable: URL, name: String, arguments: String = "", hasShortcut: Bool = false) {
        self.executable = executable
        self.name = name
        self.arguments = arguments
        self.hasShortcut = hasShortcut
    }
}

/// Runs a Windows installer in a fresh bottle and works out what it installed, the way Lutris's
/// "install from an executable" does: installer → private prefix → pick the game's program.
public enum GameInstaller {
    /// The renderer whose Wine runs installers for an engine.
    public static func renderer(for engine: Engine) -> Renderer {
        switch engine {
        case .wine: return .metal
        case .gptk: return .d3dmetal
        case .crossover: return .crossover
        }
    }

    /// A new bottle ready for an installer.
    public static func prepareBottle(engine: Engine) async throws -> UUID {
        let id = UUID()
        try await BottleStore.create(id, engine: engine)
        isolateDesktop(prefix: BottleStore.prefix(id))
        return id
    }

    /// Wine links the Windows desktop to the Mac's, so installers would litter the real Desktop with
    /// `.lnk` files. Give the bottle a desktop of its own, which also lets Decanter read those shortcuts.
    static func isolateDesktop(prefix: URL) {
        let fm = FileManager.default
        let users = prefix.appendingPathComponent("drive_c/users")
        for user in (try? fm.contentsOfDirectory(at: users, includingPropertiesForKeys: nil)) ?? [] {
            let desktop = user.appendingPathComponent("Desktop")
            guard (try? fm.destinationOfSymbolicLink(atPath: desktop.path)) != nil else { continue }
            try? fm.removeItem(at: desktop)
            try? fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        }
    }

    public static func plan(
        for file: URL, bottleID: UUID, engine: Engine, runtime: InstalledRuntime, arguments: String = ""
    ) -> LaunchPlan {
        var installer = Game(name: "Installer", executablePath: file.path, bottleID: bottleID)
        installer.setBottle(bottleID, for: engine)
        installer.settings.renderer = renderer(for: engine)
        installer.settings.arguments = arguments
        var plan = Launcher.plan(game: installer, runtime: runtime)
        // Stops Wine turning the installer's shortcuts into Mac launchers outside the bottle.
        plan.environment["WINEDLLOVERRIDES"] = "winemenubuilder.exe=d"
        return plan
    }

    public static func log(for bottleID: UUID) -> URL {
        Paths.logs.appendingPathComponent("install-\(bottleID.uuidString).log")
    }

    /// Runs an installer (or patch) and returns once every Windows process in the bottle has exited.
    public static func run(
        _ file: URL, bottleID: UUID, engine: Engine, runtime: InstalledRuntime, arguments: String = ""
    ) async throws {
        let plan = plan(for: file, bottleID: bottleID, engine: engine, runtime: runtime, arguments: arguments)
        let result = try await Shell.run(plan.executable, plan.arguments, environment: plan.environment,
                                         cwd: plan.workingDirectory, check: false)
        try? Paths.ensure(Paths.logs)
        try? result.output.write(to: log(for: bottleID), atomically: true, encoding: .utf8)
        try await Shell.run(runtime.wineserver(for: renderer(for: engine)), ["-w"],
                            environment: plan.environment, check: false)
    }

    /// Ends everything running in the bottle, which makes a pending `run` return.
    public static func stop(bottleID: UUID, engine: Engine, runtime: InstalledRuntime) async {
        let env = Launcher.environment(prefix: BottleStore.prefix(bottleID), settings: GameSettings(), engine: engine,
                                       quiet: true, libraryFallback: runtime.libraryFallback(for: engine))
        _ = try? await Shell.run(runtime.wineserver(for: renderer(for: engine)), ["-k"], environment: env, check: false)
    }

    public static func installedPrograms(bottleID: UUID, engine: Engine) -> [InstalledProgram] {
        installedPrograms(prefix: BottleStore.prefix(bottleID), templatePrefix: BottleStore.templatePrefix(engine))
    }

    /// Programs with a shortcut first (in the order found), then every other new executable.
    static func installedPrograms(prefix: URL, templatePrefix: URL) -> [InstalledProgram] {
        var programs: [InstalledProgram] = []
        var seen = Set<String>()
        for link in shortcuts(in: prefix) {
            guard let shortcut = WindowsShortcut(url: link),
                  let target = resolve(windowsPath: shortcut.target, prefix: prefix),
                  target.pathExtension.lowercased() == "exe",
                  !GameNaming.isHelperExecutable(target),
                  seen.insert(identity(target)).inserted else { continue }
            let label = link.deletingPathExtension().lastPathComponent
            guard !["uninstall", "remove ", "readme", "manual"].contains(where: label.lowercased().contains) else {
                seen.remove(identity(target))
                continue
            }
            programs.append(InstalledProgram(executable: target, name: label, arguments: shortcut.arguments, hasShortcut: true))
        }
        for url in BottleStore.newExecutables(prefix: prefix, templatePrefix: templatePrefix)
        where seen.insert(identity(url)).inserted {
            programs.append(InstalledProgram(executable: url, name: GameNaming.displayName(for: url)))
        }
        return programs
    }

    /// One spelling per file, however the path was reached (symlinks, letter case).
    private static func identity(_ url: URL) -> String {
        ((try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? url.path).lowercased()
    }

    /// The program to add without asking, when there is no real doubt which one is the game.
    public static func obviousChoice(among programs: [InstalledProgram]) -> InstalledProgram? {
        let withShortcut = programs.filter(\.hasShortcut)
        if withShortcut.count == 1 { return withShortcut[0] }
        return programs.count == 1 ? programs[0] : nil
    }

    /// `.lnk` files in the bottle's Start menus and desktops.
    static func shortcuts(in prefix: URL) -> [URL] {
        let fm = FileManager.default
        let driveC = prefix.appendingPathComponent("drive_c")
        var folders = [driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu")]
        for user in (try? fm.contentsOfDirectory(at: driveC.appendingPathComponent("users"), includingPropertiesForKeys: nil)) ?? [] {
            folders.append(user.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu"))
            folders.append(user.appendingPathComponent("Desktop"))
        }
        var found: [URL] = []
        for folder in folders {
            // A desktop still linked to the Mac's own is not the bottle's to read.
            guard (try? fm.destinationOfSymbolicLink(atPath: folder.path)) == nil,
                  let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { continue }
            var links: [URL] = []
            for case let url as URL in walker where url.pathExtension.lowercased() == "lnk" { links.append(url) }
            found += links.sorted { $0.path < $1.path }
        }
        return found
    }

    /// `C:\Games\Foo\foo.exe` → the file inside the bottle, matching case-insensitively like Windows does.
    static func resolve(windowsPath: String, prefix: URL) -> URL? {
        let parts = windowsPath.split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
        guard let drive = parts.first, drive.count == 2, drive.hasSuffix(":") else { return nil }
        let fm = FileManager.default
        var current = prefix.appendingPathComponent("dosdevices/\(drive.lowercased())").resolvingSymlinksInPath()
        for part in parts.dropFirst() {
            // Take the name as it is spelled on disk, so the path reads the way the installer wrote it.
            guard let names = try? fm.contentsOfDirectory(atPath: current.path),
                  let match = names.first(where: { $0 == part })
                    ?? names.first(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) else { return nil }
            current = current.appendingPathComponent(match)
        }
        return parts.count > 1 ? current : nil
    }
}
