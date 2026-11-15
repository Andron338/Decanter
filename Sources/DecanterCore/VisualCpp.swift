import Foundation

/// Microsoft's Visual C++ 2015-2022 runtime, which nearly every current Windows game links against.
///
/// Wine has its own copies of those DLLs, but games check for the real thing first: Unreal Engine's
/// launcher (`Stalker2.exe`, say) reads the runtime's registry key and refuses to start without it.
/// Steam installs the runtime into the prefix it first runs in, but a bottle has a prefix per engine,
/// and a game on another engine than Steam's runs where nothing installed it. So it goes into the
/// game's prefix before launch, once.
public enum VisualCpp {
    /// Microsoft's permanent links to the newest 2015-2022 runtime installers.
    static let installers: [(arch: String, url: URL)] = [
        ("x64", URL(string: "https://aka.ms/vs/17/release/vc_redist.x64.exe")!),
        ("x86", URL(string: "https://aka.ms/vs/17/release/vc_redist.x86.exe")!),
    ]

    /// The registry keys the runtime's installer leaves behind, as `system.reg` spells them.
    static func registryKey(_ arch: String) -> String {
        let node = arch == "x86" ? #"Software\\Wow6432Node\\"# : #"Software\\"#
        return node + #"Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\"# + arch
    }

    /// Whether `game` needs the runtime: anything Steam starts (the games are hidden behind
    /// `steam.exe`, and Steam itself wants it), and anything detected linking against it.
    public static func isNeeded(by game: Game) -> Bool {
        Launcher.startsThroughSteam(game) || game.requirements?.runtimes.contains("Visual C++ 2015+") == true
    }

    /// Whether both runtimes are installed in `prefix`, read from its registry file.
    public static func isInstalled(in prefix: URL) -> Bool {
        guard let registry = try? String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)
        else { return false }
        return isInstalled(registry: registry, arch: "x64") && isInstalled(registry: registry, arch: "x86")
    }

    static func isInstalled(registry: String, arch: String) -> Bool {
        let header = "[" + registryKey(arch).lowercased() + "]"
        var inKey = false
        for line in registry.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                // Section lines end with a timestamp after the closing bracket.
                inKey = line.lowercased().hasPrefix(header)
            } else if inKey, line.lowercased() == #""installed"=dword:00000001"# {
                return true
            }
        }
        return false
    }

    /// The runtime's DLLs. Wine loads its own copies of these before Microsoft's, and its copies
    /// carry no version information, so a launcher that checks the version of what it loaded
    /// (Unreal Engine's does) still finds no runtime. Once the real one is in, Wine is told to
    /// prefer it, as winetricks does.
    static let dlls = ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait",
                       "msvcp140_codecvt_ids", "vcomp140", "vcruntime140", "vcruntime140_1"]

    /// Remembers that the DLLs were set to Microsoft's copies in a prefix: `user.reg` can lag
    /// behind while Wine is running there.
    static func nativeMarker(for prefix: URL) -> URL {
        prefix.deletingLastPathComponent().appendingPathComponent("visual-cpp-native")
    }

    public static func prefersNative(in prefix: URL) -> Bool {
        FileManager.default.fileExists(atPath: nativeMarker(for: prefix).path)
    }

    /// Has Wine load Microsoft's runtime DLLs before its own throughout `prefix`.
    public static func preferNative(in prefix: URL, wine: URL, environment: [String: String]) async throws {
        for dll in dlls {
            let result = try await Shell.run(
                wine, ["reg", "add", #"HKCU\Software\Wine\DllOverrides"#, "/v", dll, "/d", "native,builtin", "/f"],
                environment: environment, check: false)
            guard result.status == 0 else {
                throw DecanterError("Couldn't set Wine to use Microsoft's \(dll).dll (status \(result.status)).")
            }
        }
        try Data().write(to: nativeMarker(for: prefix))
    }

    /// Downloads the installers once and runs them quietly in `prefix`.
    public static func install(
        in prefix: URL, wine: URL, environment: [String: String], progress: @escaping ProgressHandler
    ) async throws {
        for (arch, url) in installers {
            let file = Paths.downloads.appendingPathComponent("vc_redist.\(arch).exe")
            if PEImage(url: file) == nil {
                try await Downloader.download(from: url, to: file) { fraction in
                    progress(.init(stage: "Downloading the Visual C++ runtime (\(arch))…", fraction: fraction))
                }
                guard PEImage(url: file) != nil else {
                    try? FileManager.default.removeItem(at: file)
                    throw DecanterError("The Visual C++ runtime download wasn't a Windows program.")
                }
            }
            progress(.init(stage: "Installing the Visual C++ runtime (\(arch))…", fraction: nil))
            // Only the installer is waited for: Steam or another game may be running in the prefix.
            let result = try await Shell.run(wine, [file.path, "/install", "/quiet", "/norestart"],
                                             environment: environment, check: false)
            // 1638: a newer version is already there. 3010: done, wants a restart Wine doesn't need.
            guard [0, 1638, 3010].contains(result.status) else {
                throw DecanterError("The Visual C++ runtime (\(arch)) didn't install (status \(result.status)).")
            }
        }
    }
}
