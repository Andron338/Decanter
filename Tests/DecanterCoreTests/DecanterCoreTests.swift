import XCTest
@testable import DecanterCore

final class DecanterCoreTests: XCTestCase {
    let runtime = InstalledRuntime(wineTag: "11.21", dxmtTag: "v0.80", basePath: "/rt/base", metalPath: "/rt/metal")

    func testPlanUsesMetalRuntimeByDefault() {
        let game = Game(name: "X", executablePath: "/Games/X/x.exe", bottleID: UUID())
        let plan = Launcher.plan(game: game, runtime: runtime)
        XCTAssertEqual(plan.executable.path, "/rt/metal/bin/wine")
        XCTAssertEqual(plan.arguments, ["/Games/X/x.exe"])
        XCTAssertEqual(plan.workingDirectory.path, "/Games/X")
        XCTAssertEqual(plan.environment["WINEPREFIX"], BottleStore.prefix(game.bottleID).path)
        XCTAssertEqual(plan.environment["WINEMSYNC"], "1")
        XCTAssertNil(plan.environment["MTL_HUD_ENABLED"])
    }

    func testPlanFallsBackToBaseRuntime() {
        var game = Game(name: "X", executablePath: "/Games/X/x.exe", bottleID: UUID())
        game.settings.renderer = .wine
        XCTAssertEqual(Launcher.plan(game: game, runtime: runtime).executable.path, "/rt/base/bin/wine")

        var noMetal = runtime
        noMetal.metalPath = nil
        game.settings.renderer = .metal
        XCTAssertEqual(Launcher.plan(game: game, runtime: noMetal).executable.path, "/rt/base/bin/wine")
    }

    func testD3DMetalUsesItsOwnEngineAndBottle() {
        var withGPTK = runtime
        withGPTK.gptkPath = "/rt/gptk"
        var game = Game(name: "X", executablePath: "/Games/X/x.exe", bottleID: UUID())
        game.gptkBottleID = UUID()
        game.settings.renderer = .d3dmetal
        game.settings.rayTracing = true
        let plan = Launcher.plan(game: game, runtime: withGPTK)
        XCTAssertEqual(plan.executable.path, "/rt/gptk/bin/wine64")
        XCTAssertEqual(plan.environment["WINEPREFIX"], BottleStore.prefix(game.gptkBottleID!).path)
        XCTAssertEqual(plan.environment["D3DM_SUPPORT_DXR"], "1")
        XCTAssertNil(plan.environment["D3DM_ENABLE_METALFX"])

        // Not installed: falls back to DXMT in the standard bottle, with no D3DMetal variables.
        let fallback = Launcher.plan(game: game, runtime: runtime)
        XCTAssertEqual(fallback.executable.path, "/rt/metal/bin/wine")
        XCTAssertEqual(fallback.environment["WINEPREFIX"], BottleStore.prefix(game.bottleID).path)
        XCTAssertNil(fallback.environment["D3DM_SUPPORT_DXR"])
    }

    func testCrossOverUsesItsOwnEngineBottleAndBorrowedLibraries() {
        var withCX = runtime
        withCX.crossoverPath = "/rt/cx"
        var game = Game(name: "X", executablePath: "/Games/X/x.exe", bottleID: UUID())
        game.settings.renderer = .crossover
        XCTAssertNil(game.existingBottle(for: .crossover))
        game.setBottle(UUID(), for: .crossover)
        let plan = Launcher.plan(game: game, runtime: withCX)
        XCTAssertEqual(plan.executable.path, "/rt/cx/bin/wine")
        XCTAssertEqual(plan.environment["WINEPREFIX"], BottleStore.prefix(game.crossoverBottleID!).path)
        XCTAssertEqual(plan.environment["DYLD_FALLBACK_LIBRARY_PATH"], "/rt/cx/lib:/rt/base/lib:/usr/local/lib:/usr/lib")
        XCTAssertEqual(game.bottles.count, 2)

        // Not installed yet: runs on the main Wine in the standard bottle, with no library override.
        let fallback = Launcher.plan(game: game, runtime: runtime)
        XCTAssertEqual(fallback.executable.path, "/rt/base/bin/wine")
        XCTAssertEqual(fallback.environment["WINEPREFIX"], BottleStore.prefix(game.bottleID).path)
        XCTAssertNil(fallback.environment["DYLD_FALLBACK_LIBRARY_PATH"])
    }

    func testOldSettingsStillDecode() throws {
        let old = #"{"virtualDesktop":true,"metalRenderer":false}"#
        let settings = try JSONDecoder().decode(GameSettings.self, from: Data(old.utf8))
        XCTAssertTrue(settings.virtualDesktop)
        XCTAssertEqual(settings.renderer, .metal)
        XCTAssertTrue(settings.fastSync)
    }

    func testVirtualDesktopAndArguments() {
        var game = Game(name: "X", executablePath: "/Games/My Game/x.exe", bottleID: UUID())
        game.settings.virtualDesktop = true
        game.settings.virtualDesktopSize = "1280x720"
        game.settings.arguments = #"-windowed -name "John Doe""#
        let plan = Launcher.plan(game: game, runtime: runtime)
        XCTAssertEqual(plan.arguments, [
            "explorer", "/desktop=Decanter,1280x720", #"Z:\Games\My Game\x.exe"#, "-windowed", "-name", "John Doe",
        ])
    }

    func testMsiGoesThroughMsiexec() {
        let game = Game(name: "X", executablePath: "/tmp/thing.msi", bottleID: UUID())
        XCTAssertEqual(Launcher.plan(game: game, runtime: runtime).arguments, ["msiexec", "/i", #"Z:\tmp\thing.msi"#])
    }

    func testInstallerDetection() {
        XCTAssertTrue(GameNaming.looksLikeInstaller(URL(fileURLWithPath: "/d/SteamSetup.exe")))
        XCTAssertTrue(GameNaming.looksLikeInstaller(URL(fileURLWithPath: "/d/setup_game_1.2.exe")))
        XCTAssertTrue(GameNaming.looksLikeInstaller(URL(fileURLWithPath: "/d/thing.msi")))
        XCTAssertFalse(GameNaming.looksLikeInstaller(URL(fileURLWithPath: "/d/gta_sa.exe")))
        XCTAssertFalse(GameNaming.looksLikeInstaller(URL(fileURLWithPath: "/d/uninstall.exe")))
    }

    func testDisplayName() {
        XCTAssertEqual(GameNaming.displayName(for: URL(fileURLWithPath: "/Volumes/G/Grand Theft Auto San Andreas/gta_sa.exe")),
                       "Grand Theft Auto San Andreas")
        XCTAssertEqual(GameNaming.displayName(for: URL(fileURLWithPath: "/Volumes/G/Hades/x64/Hades.exe")), "Hades")
        XCTAssertEqual(GameNaming.tidy("half_life-2"), "Half Life 2")
    }

    /// Builds a tiny but structurally valid PE with one section holding an import table.
    private func makePE(is64Bit: Bool, imports: [String], extra: String = "") -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put(_ value: Int, at offset: Int, width: Int) {
            for index in 0..<width { bytes[offset + index] = UInt8((value >> (8 * index)) & 0xFF) }
        }
        let pe = 0x80, optional = pe + 24, optionalSize = is64Bit ? 240 : 224
        put(0x5A4D, at: 0, width: 2)
        put(pe, at: 0x3C, width: 4)
        put(0x4550, at: pe, width: 4)
        put(is64Bit ? 0x8664 : 0x14C, at: pe + 4, width: 2)
        put(1, at: pe + 6, width: 2)  // one section
        put(optionalSize, at: pe + 20, width: 2)
        put(is64Bit ? 0x20B : 0x10B, at: optional, width: 2)
        let directories = optional + (is64Bit ? 112 : 96)
        put(16, at: directories - 4, width: 4)
        put(0x1000, at: directories + 8, width: 4)  // import directory RVA
        let section = optional + optionalSize
        put(0x1000, at: section + 8, width: 4)   // virtual size
        put(0x1000, at: section + 12, width: 4)  // virtual address
        put(0x200, at: section + 16, width: 4)   // raw size
        put(0x200, at: section + 20, width: 4)   // raw offset
        var nameOffset = 0x200 + (imports.count + 1) * 20
        for (index, name) in imports.enumerated() {
            let entry = 0x200 + index * 20
            put(0x1000 + nameOffset - 0x200, at: entry + 12, width: 4)
            put(0x1F00, at: entry + 16, width: 4)
            for (i, character) in name.utf8.enumerated() { bytes[nameOffset + i] = character }
            nameOffset += name.utf8.count + 1
        }
        return Data(bytes) + Data(extra.utf8)
    }

    private func inspect(_ data: Data, named name: String = "game.exe") throws -> GameRequirements {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return try XCTUnwrap(ExecutableInspector.inspect(url))
    }

    func testInspectorReadsImports() throws {
        let dx11 = try inspect(makePE(is64Bit: true, imports: ["KERNEL32.dll", "d3d11.dll", "DXGI.dll", "VCRUNTIME140.dll"]))
        XCTAssertTrue(dx11.is64Bit)
        XCTAssertEqual(dx11.directX, [11])
        XCTAssertEqual(dx11.runtimes, ["Visual C++ 2015+"])
        XCTAssertFalse(dx11.guessedFromStrings)
        XCTAssertEqual(dx11.recommendedRenderer, .metal)

        let dx12 = try inspect(makePE(is64Bit: true, imports: ["KERNEL32.dll", "D3D12.dll"]))
        XCTAssertEqual(dx12.recommendedRenderer, .d3dmetal)

        let both = try inspect(makePE(is64Bit: true, imports: ["d3d11.dll", "d3d12.dll"]))
        XCTAssertEqual(both.graphicsSummary, "DirectX 11/12")
        XCTAssertEqual(both.recommendedRenderer, .metal)

        let dx9 = try inspect(makePE(is64Bit: false, imports: ["KERNEL32.dll", "d3d9.dll", "USER32.dll", "GDI32.dll"]))
        XCTAssertFalse(dx9.is64Bit)
        XCTAssertEqual(dx9.recommendedRenderer, .crossover)

        let dx11in32 = try inspect(makePE(is64Bit: false, imports: ["d3d11.dll"]))
        XCTAssertEqual(dx11in32.recommendedRenderer, .metal)
    }

    func testInspectorFallsBackToStringsForPackedExecutables() throws {
        let packed = try inspect(makePE(is64Bit: false, imports: ["WINMM.dll"], extra: "\0D3D9.DLL\0DDRAW.DLL\0mscoree.dll\0"))
        XCTAssertEqual(packed.directX, [7, 9])
        XCTAssertTrue(packed.guessedFromStrings)
        XCTAssertEqual(packed.runtimes, [], "mscoree appears as a string in every MSVC program; only real imports count")
        XCTAssertEqual(packed.recommendedRenderer, .crossover)

        let unknown = try inspect(makePE(is64Bit: true, imports: ["KERNEL32.dll", "USER32.dll", "a.dll", "b.dll"]))
        XCTAssertNil(unknown.recommendedRenderer)
    }

    func testInspectorRejectsNonExecutables() {
        XCTAssertNil(PEImage(data: Data("not a program".utf8)))
        XCTAssertNil(PEImage(data: Data([0x4D, 0x5A])))
    }

    func testSplitArguments() {
        XCTAssertEqual(Launcher.splitArguments(""), [])
        XCTAssertEqual(Launcher.splitArguments("  -a   -b "), ["-a", "-b"])
        XCTAssertEqual(Launcher.splitArguments(#"-x "" y"#), ["-x", "", "y"])
    }

    // MARK: Installers

    /// A PE with `marker` inside its one section, where an installer's manifest and version info live.
    private func makeInstaller(_ marker: String, wide: Bool = false) -> Data {
        var data = makePE(is64Bit: false, imports: ["kernel32.dll"])
        let bytes = wide ? marker.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } : Array(marker.utf8)
        data.replaceSubrange(0x300..<(0x300 + bytes.count), with: bytes)
        return data
    }

    func testInstallerKindComesFromTheFileNotItsName() throws {
        XCTAssertEqual(InstallerDetector.kind(of: makeInstaller("name=\"JR.Inno.Setup\"")), .innoSetup)
        XCTAssertEqual(InstallerDetector.kind(of: makeInstaller("Nullsoft.NSIS.exehead")), .nsis)
        XCTAssertNil(InstallerDetector.kind(of: makePE(is64Bit: true, imports: ["d3d11.dll"])))
        XCTAssertNil(InstallerDetector.kind(of: Data("Inno Setup".utf8)))
        // A game that merely carries the words in its data files (after the program) is not an installer.
        XCTAssertNil(InstallerDetector.kind(of: makePE(is64Bit: true, imports: ["d3d11.dll"], extra: "Inno Setup")))

        // Version info is stored as UTF-16.
        XCTAssertEqual(InstallerDetector.kind(of: makeInstaller("InstallShield", wide: true)), .installShield)

        let folder = try temporaryFolder()
        let gog = folder.appendingPathComponent("game_name_1.0.exe")
        try makeInstaller("Inno Setup").write(to: gog)
        XCTAssertTrue(GameNaming.looksLikeInstaller(gog))
        let uninstaller = folder.appendingPathComponent("unins000.exe")
        try makeInstaller("Inno Setup").write(to: uninstaller)
        XCTAssertFalse(GameNaming.looksLikeInstaller(uninstaller))
    }

    /// A shortcut as Windows writes it: ID list, link info with an ANSI path, Unicode strings.
    private func makeShortcut(target: String, arguments: String = "", workingDirectory: String = "") -> Data {
        func le(_ value: Int, _ width: Int) -> [UInt8] { (0..<width).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        func counted(_ string: String) -> [UInt8] {
            le(string.utf16.count, 2) + string.utf16.flatMap { le(Int($0), 2) }
        }
        var flags = 0x1 | 0x2 | 0x80
        if !workingDirectory.isEmpty { flags |= 0x10 }
        if !arguments.isEmpty { flags |= 0x20 }
        var bytes = le(0x4C, 4) + [0x01, 0x14, 0x02, 0, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46] + le(flags, 4)
        bytes += [UInt8](repeating: 0, count: 0x4C - bytes.count)
        bytes += le(6, 2) + [4, 0, 0xAA, 0xBB, 0, 0]  // ID list: one opaque item and the terminator
        let path = Array(target.utf8) + [0]
        let header = 0x1C
        bytes += le(header + path.count + 1, 4) + le(header, 4) + le(1, 4) + le(0, 4)
            + le(header, 4) + le(0, 4) + le(header + path.count, 4) + path + [0]
        if !workingDirectory.isEmpty { bytes += counted(workingDirectory) }
        if !arguments.isEmpty { bytes += counted(arguments) }
        return Data(bytes)
    }

    func testShortcutParsing() throws {
        let shortcut = try XCTUnwrap(WindowsShortcut(data: makeShortcut(
            target: #"C:\Program Files\Foo\foo.exe"#, arguments: "-windowed", workingDirectory: #"C:\Program Files\Foo"#)))
        XCTAssertEqual(shortcut.target, #"C:\Program Files\Foo\foo.exe"#)
        XCTAssertEqual(shortcut.arguments, "-windowed")
        XCTAssertEqual(shortcut.workingDirectory, #"C:\Program Files\Foo"#)
        XCTAssertNil(WindowsShortcut(data: Data("not a shortcut".utf8)))
        XCTAssertNil(WindowsShortcut(data: makeShortcut(target: #"C:\a.exe"#).prefix(0x60)))
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// A bottle on disk: `files` are created empty under drive_c, with C: mapped like Wine does.
    private func makePrefix(in folder: URL, named name: String, files: [String]) throws -> URL {
        let fm = FileManager.default
        let prefix = folder.appendingPathComponent(name)
        for file in files {
            let url = prefix.appendingPathComponent("drive_c/" + file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        return prefix
    }

    func testInstalledProgramsPreferShortcuts() throws {
        let folder = try temporaryFolder()
        let template = try makePrefix(in: folder, named: "template", files: ["Program Files/Internet Explorer/iexplore.exe"])
        let prefix = try makePrefix(in: folder, named: "bottle", files: [
            "Program Files/Internet Explorer/iexplore.exe",
            "GOG Games/Foo/Foo.exe", "GOG Games/Foo/config.exe", "GOG Games/Foo/unins000.exe",
            "users/me/Desktop/placeholder",
        ])
        let startMenu = prefix.appendingPathComponent("drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Foo")
        try FileManager.default.createDirectory(at: startMenu, withIntermediateDirectories: true)
        // Windows paths ignore case; the shortcut needn't match the folder's spelling.
        try makeShortcut(target: #"C:\gog games\FOO\foo.exe"#, arguments: "-skipintro")
            .write(to: startMenu.appendingPathComponent("Foo Deluxe.lnk"))
        try makeShortcut(target: #"C:\GOG Games\Foo\unins000.exe"#).write(to: startMenu.appendingPathComponent("Uninstall Foo.lnk"))
        try makeShortcut(target: #"C:\GOG Games\Foo\Foo.exe"#)
            .write(to: prefix.appendingPathComponent("drive_c/users/me/Desktop/Foo Deluxe.lnk"))

        let programs = GameInstaller.installedPrograms(prefix: prefix, templatePrefix: template)
        XCTAssertEqual(programs.map(\.name), ["Foo Deluxe", "Foo"])
        XCTAssertEqual(programs.map(\.executable.lastPathComponent), ["Foo.exe", "config.exe"])
        XCTAssertEqual(programs.map(\.hasShortcut), [true, false])
        XCTAssertEqual(programs[0].arguments, "-skipintro")
        XCTAssertEqual(GameInstaller.obviousChoice(among: programs), programs[0])
        XCTAssertNil(GameInstaller.obviousChoice(among: Array(programs.dropFirst()) + [programs[1]]))
        XCTAssertNil(GameInstaller.resolve(windowsPath: #"C:\GOG Games\Missing\x.exe"#, prefix: prefix))
    }

    func testInstallBottleGetsItsOwnDesktop() throws {
        let folder = try temporaryFolder()
        let prefix = try makePrefix(in: folder, named: "bottle", files: ["users/me/placeholder"])
        let desktop = prefix.appendingPathComponent("drive_c/users/me/Desktop")
        try FileManager.default.createSymbolicLink(at: desktop, withDestinationURL: folder)
        XCTAssertTrue(GameInstaller.shortcuts(in: prefix).isEmpty)
        GameInstaller.isolateDesktop(prefix: prefix)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: desktop.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktop.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testInstallerPlanRunsOnTheChosenEngine() {
        var withCrossOver = runtime
        withCrossOver.crossoverPath = "/rt/cx"
        let bottle = UUID()
        let plan = GameInstaller.plan(for: URL(fileURLWithPath: "/d/setup.exe"), bottleID: bottle, engine: .crossover,
                                      runtime: withCrossOver, arguments: "/S")
        XCTAssertEqual(plan.executable.path, "/rt/cx/bin/wine")
        XCTAssertEqual(plan.arguments, ["/d/setup.exe", "/S"])
        XCTAssertEqual(plan.environment["WINEPREFIX"], BottleStore.prefix(bottle).path)
        XCTAssertEqual(plan.environment["WINEDLLOVERRIDES"], "winemenubuilder.exe=d")
        XCTAssertEqual(plan.workingDirectory.path, "/d")
    }
}
