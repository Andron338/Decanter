import Foundation

/// How a game's Direct3D calls reach the GPU.
public enum Renderer: String, Codable, CaseIterable, Identifiable, Sendable {
    /// DXMT: open-source Direct3D 10/11 → Metal.
    case metal
    /// Apple's D3DMetal (Game Porting Toolkit): Direct3D 11/12 → Metal. Optional download, Apple licence.
    case d3dmetal
    /// Wine 11's built-in renderers.
    case wine
    /// CrossOver's Wine 9 with its built-in renderers. The most compatible choice for 32-bit and
    /// Direct3D 9-era games; downloaded the first time a game needs it.
    case crossover

    public var id: String { rawValue }
}

/// D3DMetal only works inside Apple's own (older) Wine, so it is a separate engine with separate bottles.
public enum Engine: String, Sendable, CaseIterable {
    case wine
    case gptk
    /// CodeWeavers' open-source CrossOver Wine, as packaged for Sikarugir.
    case crossover
}

public struct InstalledRuntime: Codable, Equatable {
    public var wineTag: String
    public var dxmtTag: String?
    /// Wine root (the folder containing `bin/`), untouched upstream build.
    public var basePath: String
    /// Wine root of the APFS-cloned copy with DXMT's DLLs in place, if DXMT installed.
    public var metalPath: String?
    public var gptkTag: String?
    /// Wine root of the Game Porting Toolkit build (Apple's Wine + D3DMetal), if the user installed it.
    public var gptkPath: String?
    public var crossoverTag: String?
    /// Wine root of the CrossOver engine, if installed.
    public var crossoverPath: String?

    public init(wineTag: String, dxmtTag: String? = nil, basePath: String, metalPath: String? = nil,
                gptkTag: String? = nil, gptkPath: String? = nil) {
        self.wineTag = wineTag
        self.dxmtTag = dxmtTag
        self.basePath = basePath
        self.metalPath = metalPath
        self.gptkTag = gptkTag
        self.gptkPath = gptkPath
    }

    public var hasD3DMetal: Bool { gptkPath != nil }
    public var hasCrossOver: Bool { crossoverPath != nil }

    /// The renderer that will actually be used, falling back when the requested one isn't installed.
    public func effectiveRenderer(_ requested: Renderer) -> Renderer {
        switch requested {
        case .d3dmetal: return gptkPath != nil ? .d3dmetal : effectiveRenderer(.metal)
        case .metal: return metalPath != nil ? .metal : .wine
        case .crossover: return crossoverPath != nil ? .crossover : .wine
        case .wine: return .wine
        }
    }

    public func engine(for renderer: Renderer) -> Engine {
        switch effectiveRenderer(renderer) {
        case .d3dmetal: return .gptk
        case .crossover: return .crossover
        case .metal, .wine: return .wine
        }
    }

    /// The CrossOver engine archive ships without its support libraries (libinotify, FreeType, GnuTLS…)
    /// because a wrapper app normally supplies them. Decanter's main Wine carries compatible copies.
    public func libraryFallback(for engine: Engine) -> String? {
        guard engine == .crossover else { return nil }
        return ([crossoverPath, basePath, gptkPath].compactMap { $0 }.map { $0 + "/lib" } + ["/usr/local/lib", "/usr/lib"])
            .joined(separator: ":")
    }

    public func wineRoot(for renderer: Renderer) -> URL {
        let path: String
        switch effectiveRenderer(renderer) {
        case .d3dmetal: path = gptkPath ?? basePath
        case .metal: path = metalPath ?? basePath
        case .crossover: path = crossoverPath ?? basePath
        case .wine: path = basePath
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Modern Wine ships a single `wine` loader; Apple's older Wine ships `wine64`.
    public func wine(for renderer: Renderer) -> URL {
        let bin = wineRoot(for: renderer).appendingPathComponent("bin")
        let names = engine(for: renderer) == .gptk ? ["wine64", "wine"] : ["wine", "wine64"]
        for name in names where FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent(name).path) {
            return bin.appendingPathComponent(name)
        }
        return bin.appendingPathComponent(names[0])
    }

    public func wineserver(for renderer: Renderer) -> URL {
        wineRoot(for: renderer).appendingPathComponent("bin/wineserver")
    }

    public var summary: String {
        var parts = ["Wine \(wineTag)"]
        if let dxmtTag { parts.append("DXMT \(dxmtTag)") }
        if gptkPath != nil { parts.append("D3DMetal") }
        if crossoverPath != nil { parts.append("CrossOver") }
        return parts.joined(separator: " · ")
    }
}

public struct SetupProgress: Sendable {
    public let stage: String
    /// nil = indeterminate
    public let fraction: Double?
}

public typealias ProgressHandler = @Sendable (SetupProgress) -> Void

/// One-shot, zero-question setup: fetch Wine, fetch DXMT, overlay, pre-build a template prefix.
public enum RuntimeManager {
    static let wineRepo = "Gcenx/macOS_Wine_builds"
    static let dxmtRepo = "3Shain/dxmt"
    static let gptkRepo = "Gcenx/game-porting-toolkit"
    static let crossoverRepo = "Sikarugir-App/Engines"
    static let crossoverPrefix = "WS12WineCX"
    static let dxmtArchDirs = ["x86_64-windows", "x86_64-unix", "i386-windows"]

    /// Apple's licence for D3DMetal, as linked from the Game Porting Toolkit binary releases.
    public static let d3dMetalLicenseURL = URL(string: "https://github.com/user-attachments/files/23971305/License.pdf")!

    public static func load() -> InstalledRuntime? {
        guard let data = try? Data(contentsOf: Paths.runtimeManifest),
              var runtime = try? JSONDecoder().decode(InstalledRuntime.self, from: data),
              FileManager.default.isExecutableFile(atPath: runtime.wineserver(for: .wine).path),
              BottleStore.templateReady(.wine)
        else { return nil }
        if let gptk = runtime.gptkPath,
           !FileManager.default.isExecutableFile(atPath: gptk + "/bin/wineserver") || !BottleStore.templateReady(.gptk) {
            runtime.gptkPath = nil
            runtime.gptkTag = nil
        }
        if let crossover = runtime.crossoverPath,
           !FileManager.default.isExecutableFile(atPath: crossover + "/bin/wineserver") || !BottleStore.templateReady(.crossover) {
            runtime.crossoverPath = nil
            runtime.crossoverTag = nil
        }
        return runtime
    }

    public static func setup(progress: @escaping ProgressHandler) async throws -> InstalledRuntime {
        try [Paths.runtimes, Paths.components, Paths.downloads, Paths.bottles, Paths.logs].forEach(Paths.ensure)

        // 1. Wine
        progress(.init(stage: "Finding the latest Wine build…", fraction: nil))
        let (wineTag, wineAsset) = try await latestAsset(repo: wineRepo) {
            $0.hasPrefix("wine-staging-") && $0.hasSuffix(".tar.xz")
        }
        let wineDir = Paths.runtimes.appendingPathComponent("wine-\(wineTag)", isDirectory: true)
        let baseRoot = try await installWineArchive(wineAsset, into: wineDir, label: "Wine \(wineTag)", progress: progress)
        var runtime = load() ?? InstalledRuntime(wineTag: wineTag, basePath: baseRoot.path)
        runtime.wineTag = wineTag
        runtime.basePath = baseRoot.path
        runtime.dxmtTag = nil
        runtime.metalPath = nil

        // 2. DXMT overlay. Optional: if it fails, games still run through Wine's own renderer.
        do {
            let (tag, root) = try await installDXMT(wineDir: wineDir, baseRoot: baseRoot, wineTag: wineTag, progress: progress)
            runtime.dxmtTag = tag
            runtime.metalPath = root.path
        } catch {
            progress(.init(stage: "Metal renderer unavailable (\(error.localizedDescription)) — continuing…", fraction: nil))
        }

        // 3. Template prefix, cloned instantly for every game added later.
        try await buildTemplate(.wine, runtime: runtime, renderer: .wine, progress: progress)

        try save(runtime)
        progress(.init(stage: "Ready", fraction: 1))
        return runtime
    }

    /// Optional add-on: Apple's Game Porting Toolkit Wine with D3DMetal, for Direct3D 12 games.
    /// Call only after the user has accepted Apple's licence.
    public static func installD3DMetal(
        into current: InstalledRuntime, progress: @escaping ProgressHandler
    ) async throws -> InstalledRuntime {
        progress(.init(stage: "Finding the Game Porting Toolkit build…", fraction: nil))
        let (tag, asset) = try await latestAsset(repo: gptkRepo) {
            $0.hasPrefix("game-porting-toolkit") && $0.hasSuffix(".tar.xz")
        }
        let directory = Paths.runtimes.appendingPathComponent("gptk-\(tag)", isDirectory: true)
        let root = try await installWineArchive(asset, into: directory, label: "D3DMetal", progress: progress)
        guard contains("D3DMetal.framework", in: directory) else {
            throw DecanterError("The Game Porting Toolkit download didn't include D3DMetal.")
        }
        var runtime = current
        runtime.gptkTag = tag
        runtime.gptkPath = root.path
        try await buildTemplate(.gptk, runtime: runtime, renderer: .d3dmetal, progress: progress)
        try save(runtime)
        return runtime
    }

    /// Optional add-on: CrossOver's Wine 9, for 32-bit and Direct3D 9-era games that the main Wine can't run.
    public static func installCrossOver(
        into current: InstalledRuntime, progress: @escaping ProgressHandler
    ) async throws -> InstalledRuntime {
        progress(.init(stage: "Finding the CrossOver engine…", fraction: nil))
        // One release holds every engine build; take the newest CrossOver one (names sort naturally).
        let assets = try await GitHub.releases(crossoverRepo).flatMap(\.assets)
            .filter { $0.name.hasPrefix(crossoverPrefix) && $0.name.hasSuffix(".tar.xz") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let asset = assets.last else { throw DecanterError("No CrossOver engine found in \(crossoverRepo).") }
        let tag = String(asset.name.dropLast(".tar.xz".count))
        let directory = Paths.runtimes.appendingPathComponent("cx-\(tag)", isDirectory: true)
        let root = try await installWineArchive(asset, into: directory, label: "CrossOver engine", progress: progress)
        var runtime = current
        runtime.crossoverTag = tag
        runtime.crossoverPath = root.path
        try await buildTemplate(.crossover, runtime: runtime, renderer: .crossover, progress: progress)
        try save(runtime)
        return runtime
    }

    // MARK: - Pieces

    private static func save(_ runtime: InstalledRuntime) throws {
        try JSONEncoder().encode(runtime).write(to: Paths.runtimeManifest, options: .atomic)
    }

    /// Downloads, verifies and unpacks a Wine archive unless it's already there. Returns the Wine root.
    private static func installWineArchive(
        _ asset: GitHubRelease.Asset, into directory: URL, label: String, progress: @escaping ProgressHandler
    ) async throws -> URL {
        let fm = FileManager.default
        if let existing = findWineRoot(in: directory) { return existing }
        let archive = Paths.downloads.appendingPathComponent(asset.name)
        try await fetch(asset, to: archive, label: "Downloading \(label)", progress: progress)
        progress(.init(stage: "Unpacking \(label)…", fraction: nil))
        try? fm.removeItem(at: directory)
        try Paths.ensure(directory)
        try await Shell.run("/usr/bin/tar", ["-xJf", archive.path, "-C", directory.path])
        try await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", directory.path], check: false)
        try? fm.removeItem(at: archive)
        guard let root = findWineRoot(in: directory) else {
            throw DecanterError("The \(label) archive didn't contain a usable Wine (no bin/wineserver).")
        }
        return root
    }

    private static func buildTemplate(
        _ engine: Engine, runtime: InstalledRuntime, renderer: Renderer, progress: @escaping ProgressHandler
    ) async throws {
        guard !BottleStore.templateReady(engine) else { return }
        progress(.init(stage: "Preparing Windows environment (about a minute)…", fraction: nil))
        let prefix = BottleStore.templatePrefix(engine)
        try? FileManager.default.removeItem(at: prefix)
        try Paths.ensure(prefix.deletingLastPathComponent())
        var env = Launcher.environment(prefix: prefix, settings: GameSettings(), engine: engine, quiet: true,
                                       libraryFallback: runtime.libraryFallback(for: engine))
        if engine == .gptk {
            // Apple's Wine doesn't bundle Mono/Gecko and would stop to ask about installing them.
            env["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        }
        try await Shell.run(runtime.wine(for: renderer), ["wineboot", "-u"], environment: env)
        try await Shell.run(runtime.wineserver(for: renderer), ["-w"], environment: env, check: false)
        guard BottleStore.templateReady(engine) else {
            throw DecanterError("Wine couldn't create its Windows environment. Is Rosetta 2 installed?")
        }
    }

    private static func installDXMT(
        wineDir: URL, baseRoot: URL, wineTag: String, progress: @escaping ProgressHandler
    ) async throws -> (tag: String, root: URL) {
        let fm = FileManager.default
        let (tag, asset) = try await latestAsset(repo: dxmtRepo) { $0.contains("builtin") && $0.hasSuffix(".tar.gz") }
        let overlayDir = Paths.runtimes.appendingPathComponent("wine-\(wineTag)+dxmt-\(tag)", isDirectory: true)
        let marker = overlayDir.appendingPathComponent(".decanter-overlay-complete")
        let relativeRoot = String(baseRoot.path.dropFirst(wineDir.path.count))
        let overlayRoot = URL(fileURLWithPath: overlayDir.path + relativeRoot, isDirectory: true)
        if fm.fileExists(atPath: marker.path) { return (tag, overlayRoot) }

        let componentDir = Paths.components.appendingPathComponent("dxmt-\(tag)", isDirectory: true)
        let archive = Paths.downloads.appendingPathComponent(asset.name)
        try await fetch(asset, to: archive, label: "Downloading Metal renderer (DXMT \(tag))", progress: progress)
        try? fm.removeItem(at: componentDir)
        try Paths.ensure(componentDir)
        try await Shell.run("/usr/bin/tar", ["-xzf", archive.path, "-C", componentDir.path])
        try await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", componentDir.path], check: false)
        try? fm.removeItem(at: archive)

        // Stock Wine searches its own DLL dir before WINEDLLPATH, so DXMT's builtin DLLs must replace
        // Wine's d3d11/dxgi/d3d10core in place. Do that on an APFS clone (near-zero disk) so the
        // pristine runtime stays available as a per-game fallback.
        progress(.init(stage: "Installing Metal renderer…", fraction: nil))
        try? fm.removeItem(at: overlayDir)
        try await Shell.run("/bin/cp", ["-Rcp", wineDir.path, overlayDir.path])

        var copied = 0
        for archDir in archDirectories(in: componentDir) {
            let target = overlayRoot.appendingPathComponent("lib/wine/\(archDir.lastPathComponent)", isDirectory: true)
            guard fm.fileExists(atPath: target.path) else { continue }
            for file in try fm.contentsOfDirectory(at: archDir, includingPropertiesForKeys: nil) {
                let dest = target.appendingPathComponent(file.lastPathComponent)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: file, to: dest)
                copied += 1
            }
        }
        guard copied > 0 else {
            try? fm.removeItem(at: overlayDir)
            throw DecanterError("unexpected DXMT archive layout")
        }
        fm.createFile(atPath: marker.path, contents: nil)
        return (tag, overlayRoot)
    }

    private static func latestAsset(
        repo: String, matching: (String) -> Bool
    ) async throws -> (tag: String, asset: GitHubRelease.Asset) {
        for release in try await GitHub.releases(repo) where !release.prerelease {
            if let asset = release.assets.first(where: { matching($0.name) }) {
                return (release.tag_name, asset)
            }
        }
        throw DecanterError("No suitable download found in \(repo).")
    }

    private static func fetch(
        _ asset: GitHubRelease.Asset, to archive: URL, label: String, progress: @escaping ProgressHandler
    ) async throws {
        progress(.init(stage: label, fraction: 0))
        try await Downloader.download(from: asset.browser_download_url, to: archive) {
            progress(.init(stage: label, fraction: $0))
        }
        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            progress(.init(stage: "Verifying download…", fraction: nil))
            let actual = try Checksum.sha256(of: archive)
            guard actual == digest.dropFirst("sha256:".count) else {
                try? FileManager.default.removeItem(at: archive)
                throw DecanterError("\(asset.name) failed its checksum — the download was corrupted or tampered with.")
            }
        }
    }

    static func contains(_ name: String, in directory: URL) -> Bool {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return false }
        for case let url as URL in walker where url.lastPathComponent == name { return true }
        return false
    }

    static func findWineRoot(in directory: URL) -> URL? {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in walker where url.lastPathComponent == "wineserver" {
            let bin = url.deletingLastPathComponent()
            if bin.lastPathComponent == "bin" { return bin.deletingLastPathComponent() }
        }
        return nil
    }

    static func archDirectories(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where dxmtArchDirs.contains(url.lastPathComponent) {
            found.append(url)
            walker.skipDescendants()
        }
        return found
    }
}
