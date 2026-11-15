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
    /// Sikarugir's Wine 10, the one engine the Windows Steam client runs on, with Direct3D 10/11
    /// or 12 routed to a translator per game (see `Wine10Graphics`). Downloaded the first time
    /// something needs it.
    case sikarugir

    public var id: String { rawValue }
}

/// Which translator each DirectX version gets on the Wine 10 engine.
///
/// That engine is CrossOver-based, and its loader searches one folder per graphics backend
/// (`WINEDLLPATH_DXMT`, `WINEDLLPATH_D9VK`, …) before its own DLLs, chosen by environment variable
/// for each process. So one engine and one Windows environment serve every route, and switching
/// between them needs no second copy of Wine.
///
/// What can't be had at once: Wine's Direct3D 12 (vkd3d) only works with Wine's own DXGI, and DXMT
/// replaces DXGI, so a process gets either DXMT's Direct3D 10/11 or Direct3D 12.
///
/// Direct3D 9 stays on Wine's own renderer. DXVK was tried for it (Nov 2026): Gcenx's 2023 macOS
/// build can't create a device on current MoltenVK, and Sikarugir's 2025 d9vk only draws, wrongly,
/// with CrossOver's patched MoltenVK.
public enum Wine10Graphics: String, Codable, CaseIterable, Identifiable, Sendable {
    /// From what the game was detected to use: DXMT for Direct3D 10/11, vkd3d for 12 alone, Wine's
    /// own for 9 and older. DXMT also replaces DXGI, which older games never use but Steam's overlay
    /// hooks inside them (GTA: Vice City hangs with it). Undetected programs, Steam itself
    /// among them, get DXMT, as Steam's engine always did.
    case automatic
    /// Direct3D 10/11 → DXMT → Metal.
    case metal
    /// Direct3D 12 → vkd3d → MoltenVK → Metal; 10/11 → Wine's own.
    case vkd3d
    /// Wine's own renderers for everything (wined3d), as before.
    case wine
    /// Direct3D 11/12 → Apple's D3DMetal → Metal, from the Game Porting Toolkit download. The Wine 10
    /// engine's loader takes it like the other backends, so Steam needn't move to Apple's older Wine,
    /// which it crashes on. Falls back to vkd3d when D3DMetal isn't installed.
    case d3dmetal

    public var id: String { rawValue }

    public func resolved(for requirements: GameRequirements?) -> Wine10Graphics {
        guard self == .automatic else { return self }
        guard let requirements, !requirements.directX.isEmpty else { return .metal }
        let directX = requirements.directX
        // DXMT replaces DXGI, which leaves a game that needs Direct3D 12 with none at all.
        if requirements.requiresD3D12 { return .d3dmetal }
        if directX.contains(10) || directX.contains(11) { return .metal }
        return directX.contains(12) ? .vkd3d : .wine
    }
}

/// D3DMetal only works inside Apple's own (older) Wine, so it is a separate engine with separate bottles.
public enum Engine: String, Sendable, CaseIterable {
    case wine
    case gptk
    /// CodeWeavers' open-source CrossOver Wine, as packaged for Sikarugir.
    case crossover
    /// Wine 10 with CrossOver's application fixes, as built for Sikarugir. Steam needs both a fix that
    /// stock Wine lacks (its browser must draw in-process) and one CrossOver's Wine 9 lacks on current
    /// macOS (telling which process owns a local connection).
    case sikarugir
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
    public var sikarugirTag: String?
    /// Wine root of the Sikarugir Wine 10 engine, if installed. Left as downloaded: the graphics
    /// backends reach it through environment variables (see `wine10Environment`).
    public var sikarugirPath: String?

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
    public var hasSikarugir: Bool { sikarugirPath != nil }
    /// Still pointing at the copy with DXMT in place of the engine's own DLLs that older versions
    /// made: installing it again moves to the engine as downloaded, without downloading it.
    public var sikarugirNeedsUpdate: Bool {
        sikarugirPath?.contains("+dxmt-") == true
    }

    /// The folder holding DXMT's `x86_64-windows`, `x86_64-unix` and `i386-windows`, if installed.
    public var dxmtRoot: URL? {
        guard let dxmtTag else { return nil }
        let component = Paths.components.appendingPathComponent("dxmt-\(dxmtTag)", isDirectory: true)
        return RuntimeManager.archDirectories(in: component).first?.deletingLastPathComponent()
    }

    /// Environment that routes each DirectX version on the Wine 10 engine. The variables are read by
    /// that engine's loader alone; the other engines ignore them.
    public func wine10Environment(_ graphics: Wine10Graphics) -> [String: String] {
        var env: [String: String] = [:]
        switch graphics {
        case .metal, .automatic:
            if let dxmtRoot { env["WINEDLLPATH_DXMT"] = dxmtRoot.path }
        case .d3dmetal:
            if let d3dMetal = d3dMetalComponent() {
                env["WINEDLLPATH_D3DMETAL"] = d3dMetal.root.path
                env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = d3dMetal.shared.path
            }
        case .wine, .vkd3d:
            break
        }
        return env
    }

    /// D3DMetal's DLLs, which Apple ships as Wine builtins with a Mac-side half each.
    static let d3dMetalDLLs = ["d3d10", "d3d10core", "d3d11", "d3d12", "dxgi", "nvapi64", "nvngx", "atidxx64"]

    /// A folder of links to the Game Porting Toolkit's D3DMetal files laid out as the Wine 10 engine's
    /// loader wants a backend (`x86_64-windows`, `x86_64-unix`), made the first time it's needed.
    /// The Mac halves find `libd3dshared.dylib` and `D3DMetal.framework` beside themselves.
    public func d3dMetalComponent() -> (root: URL, shared: URL)? {
        guard let gptkPath, let gptkTag else { return nil }
        let lib = URL(fileURLWithPath: gptkPath).appendingPathComponent("lib")
        let external = lib.appendingPathComponent("external")
        let root = Paths.components.appendingPathComponent("d3dmetal-\(gptkTag)", isDirectory: true)
        let windows = root.appendingPathComponent("x86_64-windows"), unix = root.appendingPathComponent("x86_64-unix")
        let shared = unix.appendingPathComponent("libd3dshared.dylib")
        let fm = FileManager.default
        if fm.fileExists(atPath: shared.path) { return (root, shared) }
        guard fm.fileExists(atPath: external.appendingPathComponent("libd3dshared.dylib").path) else { return nil }
        try? fm.removeItem(at: root)
        do {
            try fm.createDirectory(at: windows, withIntermediateDirectories: true)
            try fm.createDirectory(at: unix, withIntermediateDirectories: true)
            for dll in Self.d3dMetalDLLs {
                let pe = lib.appendingPathComponent("wine/x86_64-windows/\(dll).dll")
                let so = lib.appendingPathComponent("wine/x86_64-unix/\(dll).so")
                if fm.fileExists(atPath: pe.path) {
                    try fm.createSymbolicLink(at: windows.appendingPathComponent("\(dll).dll"), withDestinationURL: pe)
                }
                if fm.fileExists(atPath: so.path) {
                    try fm.createSymbolicLink(at: unix.appendingPathComponent("\(dll).so"), withDestinationURL: so)
                }
            }
            try fm.createSymbolicLink(at: unix.appendingPathComponent("D3DMetal.framework"),
                                      withDestinationURL: external.appendingPathComponent("D3DMetal.framework"))
            // Last, as the sign that the folder is complete.
            try fm.createSymbolicLink(at: shared, withDestinationURL: external.appendingPathComponent("libd3dshared.dylib"))
        } catch {
            try? fm.removeItem(at: root)
            return nil
        }
        return (root, shared)
    }

    public func has(_ engine: Engine) -> Bool {
        switch engine {
        case .wine: return true
        case .gptk: return hasD3DMetal
        case .crossover: return hasCrossOver
        case .sikarugir: return hasSikarugir
        }
    }

    /// The renderer that will actually be used, falling back when the requested one isn't installed.
    public func effectiveRenderer(_ requested: Renderer) -> Renderer {
        switch requested {
        case .d3dmetal: return gptkPath != nil ? .d3dmetal : effectiveRenderer(.metal)
        case .metal: return metalPath != nil ? .metal : .wine
        case .crossover: return crossoverPath != nil ? .crossover : .wine
        case .sikarugir: return sikarugirPath != nil ? .sikarugir : .wine
        case .wine: return .wine
        }
    }

    public func engine(for renderer: Renderer) -> Engine {
        switch effectiveRenderer(renderer) {
        case .d3dmetal: return .gptk
        case .crossover: return .crossover
        case .sikarugir: return .sikarugir
        case .metal, .wine: return .wine
        }
    }

    /// Sikarugir's engine archives ship without their support libraries (libinotify, FreeType, GnuTLS…)
    /// because a wrapper app normally supplies them. Decanter's main Wine carries compatible copies.
    public func libraryFallback(for engine: Engine) -> String? {
        let own: String?
        var first: [String] = []
        switch engine {
        case .crossover: own = crossoverPath
        case .sikarugir:
            own = sikarugirPath
            // Ahead of the main Wine's Vulkan loader, which hides MoltenVK from this older Wine.
            first = [RuntimeManager.moltenVKFolder.path]
        case .wine, .gptk: return nil
        }
        return (first + [own, basePath, gptkPath].compactMap { $0 }.map { $0 + "/lib" } + ["/usr/local/lib", "/usr/lib"])
            .joined(separator: ":")
    }

    public func wineRoot(for renderer: Renderer) -> URL {
        let path: String
        switch effectiveRenderer(renderer) {
        case .d3dmetal: path = gptkPath ?? basePath
        case .metal: path = metalPath ?? basePath
        case .crossover: path = crossoverPath ?? basePath
        case .sikarugir: path = sikarugirPath ?? basePath
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
        if sikarugirPath != nil { parts.append("Wine 10") }
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
    /// The Wine 10.0 line is the one Steam was seen working on; newer lines are untried.
    static let sikarugirPrefix = "WS12WineSikarugir10.0_"
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
        if let sikarugir = runtime.sikarugirPath,
           !FileManager.default.isExecutableFile(atPath: sikarugir + "/bin/wineserver") || !BottleStore.templateReady(.sikarugir) {
            runtime.sikarugirPath = nil
            runtime.sikarugirTag = nil
        }
        if runtime.hasSikarugir { linkMoltenVK(runtime) }
        return runtime
    }

    // MARK: - Wine 10 graphics

    /// Holds `libvulkan.1.dylib`, a link to the main Wine's MoltenVK.
    public static var moltenVKFolder: URL { Paths.components.appendingPathComponent("moltenvk", isDirectory: true) }

    /// The Wine 10 engine opens `libvulkan.1.dylib` and finds the main Wine's Vulkan loader, which
    /// only lists MoltenVK to programs that ask for "portability" drivers, and this Wine doesn't: it
    /// then has no Vulkan at all. CrossOver links MoltenVK in the loader's place; so does this.
    static func linkMoltenVK(_ runtime: InstalledRuntime) {
        let fm = FileManager.default
        let target = runtime.basePath + "/lib/libMoltenVK.dylib"
        let link = moltenVKFolder.appendingPathComponent("libvulkan.1.dylib")
        guard fm.fileExists(atPath: target),
              (try? fm.destinationOfSymbolicLink(atPath: link.path)) != target else { return }
        try? Paths.ensure(moltenVKFolder)
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
    }

    public static func setup(progress: @escaping ProgressHandler) async throws -> InstalledRuntime {
        try [Paths.runtimes, Paths.components, Paths.downloads, Paths.bottles, Paths.logs].forEach(Paths.ensure)
        try await checkRosetta()

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
            try Task.checkCancellation()
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

    /// Optional add-on: Sikarugir's Wine 10, for the Windows Steam client.
    public static func installSikarugir(
        into current: InstalledRuntime, progress: @escaping ProgressHandler
    ) async throws -> InstalledRuntime {
        progress(.init(stage: "Finding the Wine 10 engine…", fraction: nil))
        let (tag, asset) = try await newestEngine(named: sikarugirPrefix, label: "Wine 10")
        let directory = Paths.runtimes.appendingPathComponent("sk-\(tag)", isDirectory: true)
        let root = try await installWineArchive(asset, into: directory, label: "Wine 10 engine", progress: progress)
        var runtime = current
        runtime.sikarugirTag = tag
        runtime.sikarugirPath = root.path
        // Older versions ran a copy of the engine with DXMT in place of its own DLLs. That copy is
        // left alone (an APFS clone, nearly free): Steam may still be running from it.
        linkMoltenVK(runtime)
        try await buildTemplate(.sikarugir, runtime: runtime, renderer: .sikarugir, progress: progress)
        try save(runtime)
        return runtime
    }

    private static func newestEngine(named prefix: String, label: String) async throws -> (tag: String, asset: GitHubRelease.Asset) {
        guard let found = newestEngine(named: prefix, in: try await GitHub.releases(crossoverRepo)) else {
            throw DecanterError("No \(label) engine with a checksum to verify it by was found in \(crossoverRepo).")
        }
        return found
    }

    /// One release of the engines repository holds every build; the newest of a line sorts last.
    /// Builds without a checksum (uploaded before GitHub kept them) are passed over.
    static func newestEngine(named prefix: String, in releases: [GitHubRelease]) -> (tag: String, asset: GitHubRelease.Asset)? {
        let assets = releases.flatMap(\.assets)
            .filter { $0.name.hasPrefix(prefix) && $0.name.hasSuffix(".tar.xz") && $0.sha256 != nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard let asset = assets.last else { return nil }
        return (String(asset.name.dropLast(".tar.xz".count)), asset)
    }

    /// Optional add-on: CrossOver's Wine 9, for 32-bit and Direct3D 9-era games that the main Wine can't run.
    public static func installCrossOver(
        into current: InstalledRuntime, progress: @escaping ProgressHandler
    ) async throws -> InstalledRuntime {
        progress(.init(stage: "Finding the CrossOver engine…", fraction: nil))
        let (tag, asset) = try await newestEngine(named: crossoverPrefix, label: "CrossOver")
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
        // Unpacked beside its final place and moved there whole, so an unpacking that was cancelled
        // or cut short never leaves a folder that looks installed.
        let partial = directory.deletingLastPathComponent().appendingPathComponent(directory.lastPathComponent + ".partial")
        try? fm.removeItem(at: partial)
        try Paths.ensure(partial)
        do {
            try await Shell.run("/usr/bin/tar", ["-xJf", archive.path, "-C", partial.path], timeout: .seconds(600))
            try await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", partial.path], check: false)
            guard findWineRoot(in: partial) != nil else {
                throw DecanterError("The \(label) archive didn't contain a usable Wine (no bin/wineserver).")
            }
            try? fm.removeItem(at: directory)
            try fm.moveItem(at: partial, to: directory)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
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
        let wineserver = runtime.wineserver(for: renderer)
        do {
            // Usually about a minute. Wine that is stuck (a dialog nobody can see, a missing library)
            // otherwise keeps setup waiting forever.
            try await Shell.run(runtime.wine(for: renderer), ["wineboot", "-u"], environment: env, timeout: .seconds(300))
            try await Shell.run(wineserver, ["-w"], environment: env, check: false, timeout: .seconds(120))
            guard BottleStore.templateReady(engine) else {
                throw DecanterError("Wine couldn't create its Windows environment. Is Rosetta 2 installed?")
            }
        } catch {
            // Whatever Wine left running goes, and so does the half-made environment, which would
            // otherwise count as ready.
            _ = try? await Shell.run(wineserver, ["-k"], environment: env, check: false, timeout: .seconds(30))
            try? FileManager.default.removeItem(at: prefix)
            throw error
        }
    }

    /// Wine for macOS is an Intel program, so on Apple silicon it needs Rosetta 2.
    public static func checkRosetta() async throws {
        #if arch(arm64)
        let result = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/arch"), ["-x86_64", "/usr/bin/true"],
                                          check: false, timeout: .seconds(30))
        guard result?.status == 0 else {
            throw DecanterError("""
                Decanter needs Rosetta 2, which isn't installed. To install it, open Terminal and run \
                softwareupdate --install-rosetta, then click Try Again.
                """)
        }
        #endif
    }

    private static func installDXMT(
        wineDir: URL, baseRoot: URL, wineTag: String, progress: @escaping ProgressHandler
    ) async throws -> (tag: String, root: URL) {
        let fm = FileManager.default
        let (tag, asset) = try await latestAsset(repo: dxmtRepo) { $0.contains("builtin") && $0.hasSuffix(".tar.gz") }
        let overlayDir = Paths.runtimes.appendingPathComponent("wine-\(wineTag)+dxmt-\(tag)", isDirectory: true)
        let marker = overlayDir.appendingPathComponent(overlayMarker)
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

        progress(.init(stage: "Installing Metal renderer…", fraction: nil))
        try await overlayDXMT(from: componentDir, onto: wineDir, as: overlayDir, root: overlayRoot)
        return (tag, overlayRoot)
    }

    static let overlayMarker = ".decanter-overlay-complete"

    /// Stock Wine searches its own DLL dir before WINEDLLPATH, so DXMT's builtin DLLs must replace
    /// Wine's d3d11/dxgi/d3d10core in place. Do that on an APFS clone (near-zero disk) so the
    /// pristine runtime stays available as a per-game fallback.
    static func overlayDXMT(from componentDir: URL, onto wineDir: URL, as overlayDir: URL, root overlayRoot: URL) async throws {
        let fm = FileManager.default
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
        fm.createFile(atPath: overlayDir.appendingPathComponent(overlayMarker).path, contents: nil)
    }

    private static func latestAsset(
        repo: String, matching: (String) -> Bool
    ) async throws -> (tag: String, asset: GitHubRelease.Asset) {
        guard let found = latestAsset(in: try await GitHub.releases(repo), matching: matching) else {
            throw DecanterError("No download with a checksum to verify it by was found in \(repo).")
        }
        return found
    }

    /// The newest full release's matching asset. Releases whose asset has no checksum (uploaded
    /// before GitHub kept them) are passed over for an older one that has.
    static func latestAsset(
        in releases: [GitHubRelease], matching: (String) -> Bool
    ) -> (tag: String, asset: GitHubRelease.Asset)? {
        for release in releases where !release.prerelease {
            if let asset = release.assets.first(where: { matching($0.name) && $0.sha256 != nil }) {
                return (release.tag_name, asset)
            }
        }
        return nil
    }

    private static func fetch(
        _ asset: GitHubRelease.Asset, to archive: URL, label: String, progress: @escaping ProgressHandler
    ) async throws {
        // Nothing is installed unchecked: the asset was picked for having a checksum.
        guard let expected = asset.sha256 else {
            throw DecanterError("\(asset.name) has no checksum to verify it by, so it wasn't installed.")
        }
        // A download kept from a setup that was cancelled or failed later on is used again if it checks out.
        if FileManager.default.fileExists(atPath: archive.path) {
            progress(.init(stage: "Verifying earlier download…", fraction: nil))
            if (try? Checksum.sha256(of: archive)) == expected { return }
            try? FileManager.default.removeItem(at: archive)
        }
        progress(.init(stage: label, fraction: 0))
        try await Downloader.download(from: asset.browser_download_url, to: archive) {
            progress(.init(stage: label, fraction: $0))
        }
        progress(.init(stage: "Verifying download…", fraction: nil))
        guard try Checksum.sha256(of: archive) == expected else {
            try? FileManager.default.removeItem(at: archive)
            throw DecanterError("\(asset.name) failed its checksum — the download was corrupted or tampered with.")
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
