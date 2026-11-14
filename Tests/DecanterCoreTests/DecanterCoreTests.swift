import XCTest
@testable import DecanterCore

final class DecanterCoreTests: XCTestCase {
    let runtime = InstalledRuntime(wineTag: "11.21", dxmtTag: "v0.80", basePath: "/rt/base", metalPath: "/rt/metal")
    /// Where the plans below are told the game's bottle keeps its prefix.
    let prefix = URL(fileURLWithPath: "/bottles/x/prefix")

    func testPlanUsesMetalRuntimeByDefault() {
        let game = Game(name: "X", executablePath: "/Games/X/x.exe", bottleID: UUID())
        let plan = Launcher.plan(game: game, prefix: prefix, runtime: runtime)
        XCTAssertEqual(plan.executable.path, "/rt/metal/bin/wine")
        XCTAssertEqual(plan.arguments, ["/Games/X/x.exe"])
        XCTAssertEqual(plan.workingDirectory.path, "/Games/X")
        XCTAssertEqual(plan.environment["WINEPREFIX"], prefix.path)
        XCTAssertEqual(plan.environment["WINEMSYNC"], "1")
        XCTAssertNil(plan.environment["MTL_HUD_ENABLED"])
    }

    func testPlanFallsBackToBaseRuntime() {
        var game = Game(name: "X", executablePath: "/Games/X/x.exe", bottleID: UUID())
        game.settings.renderer = .wine
        XCTAssertEqual(Launcher.plan(game: game, prefix: prefix, runtime: runtime).executable.path, "/rt/base/bin/wine")

        var noMetal = runtime
        noMetal.metalPath = nil
        game.settings.renderer = .metal
        XCTAssertEqual(Launcher.plan(game: game, prefix: prefix, runtime: noMetal).executable.path, "/rt/base/bin/wine")
    }

    func testD3DMetalUsesItsOwnEngine() {
        var withGPTK = runtime
        withGPTK.gptkPath = "/rt/gptk"
        var game = Game(name: "X", executablePath: "/Games/X/x.exe", bottleID: UUID())
        game.settings.renderer = .d3dmetal
        game.settings.rayTracing = true
        XCTAssertEqual(withGPTK.engine(for: .d3dmetal), .gptk)
        let plan = Launcher.plan(game: game, prefix: prefix, runtime: withGPTK)
        XCTAssertEqual(plan.executable.path, "/rt/gptk/bin/wine64")
        XCTAssertEqual(plan.environment["D3DM_SUPPORT_DXR"], "1")
        XCTAssertNil(plan.environment["D3DM_ENABLE_METALFX"])

        // Not installed: falls back to DXMT on the standard engine, with no D3DMetal variables.
        XCTAssertEqual(runtime.engine(for: .d3dmetal), .wine)
        XCTAssertFalse(runtime.has(.gptk))
        let fallback = Launcher.plan(game: game, prefix: prefix, runtime: runtime)
        XCTAssertEqual(fallback.executable.path, "/rt/metal/bin/wine")
        XCTAssertNil(fallback.environment["D3DM_SUPPORT_DXR"])
    }

    func testCrossOverUsesItsOwnEngineAndBorrowedLibraries() {
        var withCX = runtime
        withCX.crossoverPath = "/rt/cx"
        var game = Game(name: "X", executablePath: "/Games/X/x.exe", bottleID: UUID())
        game.settings.renderer = .crossover
        let plan = Launcher.plan(game: game, prefix: prefix, runtime: withCX)
        XCTAssertEqual(plan.executable.path, "/rt/cx/bin/wine")
        XCTAssertEqual(plan.environment["WINEPREFIX"], prefix.path)
        XCTAssertEqual(plan.environment["DYLD_FALLBACK_LIBRARY_PATH"], "/rt/cx/lib:/rt/base/lib:/usr/local/lib:/usr/lib")

        // Not installed yet: runs on the main Wine, with no library override.
        let fallback = Launcher.plan(game: game, prefix: prefix, runtime: runtime)
        XCTAssertEqual(fallback.executable.path, "/rt/base/bin/wine")
        XCTAssertNil(fallback.environment["DYLD_FALLBACK_LIBRARY_PATH"])
    }

    func testBottleKeepsAPrefixPerEngine() {
        var bottle = Bottle(name: " ")
        XCTAssertEqual(bottle.displayName, "Untitled Bottle")
        XCTAssertNil(bottle.prefix(for: .crossover))
        XCTAssertEqual(bottle.installEngine, .wine)
        let folder = UUID()
        bottle.prefixes[Engine.crossover.rawValue] = folder
        XCTAssertEqual(bottle.prefix(for: .crossover), BottleStore.prefix(folder))
        XCTAssertEqual(bottle.engines, [.crossover])
        // With nothing recorded, installers go where the bottle already has something.
        XCTAssertEqual(bottle.installEngine, .crossover)
        bottle.lastEngine = Engine.gptk.rawValue
        XCTAssertEqual(bottle.installEngine, .gptk)
        let saved = try? JSONDecoder().decode(Bottle.self, from: JSONEncoder().encode(bottle))
        XCTAssertEqual(saved, bottle)
    }

    func testOlderLibrariesKeepTheirBottles() {
        let shared = UUID(), cx = UUID(), gptk = UUID(), otherCX = UUID()
        var first = Game(name: "First", executablePath: "/g/a.exe", bottleID: shared)
        first.crossoverBottleID = cx
        var second = Game(name: "Second", executablePath: "/g/b.exe", bottleID: shared)
        second.crossoverBottleID = otherCX
        second.gptkBottleID = gptk
        let alone = Game(name: "Alone", executablePath: "/g/c.exe", bottleID: UUID())
        var games = [first, second, alone]
        var list = BottleList()
        let changed = BottleStore.adopt(games: &games, into: &list)
        XCTAssertTrue(changed.bottles && changed.games)
        XCTAssertEqual(list.bottles.map(\.name), ["First + 1 more", "Alone"])
        XCTAssertNil(list.defaultID)
        // The bottle's id is the game's old one, so the library needs no rewriting.
        XCTAssertEqual(list.bottles[0].id, shared)
        XCTAssertEqual(list.bottles[0].prefixID(for: .wine), shared)
        XCTAssertEqual(list.bottles[0].prefixID(for: .crossover), cx)
        XCTAssertEqual(list.bottles[0].prefixID(for: .gptk), gptk)
        XCTAssertEqual(list.bottles[1].engines, [.wine])
        XCTAssertTrue(games.allSatisfy { $0.gptkBottleID == nil && $0.crossoverBottleID == nil })

        // A second pass has nothing left to do, and renamed bottles keep their names.
        list.bottles[1].name = "Mine"
        let again = BottleStore.adopt(games: &games, into: &list)
        XCTAssertFalse(again.bottles || again.games)
        XCTAssertEqual(list.bottles.map(\.name), ["First + 1 more", "Mine"])
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
        let plan = Launcher.plan(game: game, prefix: prefix, runtime: runtime)
        XCTAssertEqual(plan.arguments, [
            "explorer", "/desktop=Decanter,1280x720", #"Z:\Games\My Game\x.exe"#, "-windowed", "-name", "John Doe",
        ])
    }

    func testMsiGoesThroughMsiexec() {
        let game = Game(name: "X", executablePath: "/tmp/thing.msi", bottleID: UUID())
        XCTAssertEqual(Launcher.plan(game: game, prefix: prefix, runtime: runtime).arguments, ["msiexec", "/i", #"Z:\tmp\thing.msi"#])
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
    private func makeShortcut(
        target: String, arguments: String = "", workingDirectory: String = "", targetBytes: [UInt8]? = nil
    ) -> Data {
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
        let path = (targetBytes ?? Array(target.utf8)) + [0]
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

    func testShortcutTextInTheUsersCodepage() throws {
        // "C:\Игра\a.exe" as a Russian installer writes it: one byte per letter, codepage 1251.
        let path: [UInt8] = Array(#"C:\"#.utf8) + [0xC8, 0xE3, 0xF0, 0xE0] + Array(#"\a.exe"#.utf8)
        let data = makeShortcut(target: "", arguments: "\0", targetBytes: path)
        let russian = try XCTUnwrap(WindowsShortcut(data: data, preferredLanguages: ["en-US", "uk-UA"]))
        XCTAssertEqual(russian.target, #"C:\Игра\a.exe"#)
        // Some installers write an argument string holding nothing but a NUL.
        XCTAssertEqual(russian.arguments, "")
        let western = try XCTUnwrap(WindowsShortcut(data: data, preferredLanguages: ["en-US"]))
        XCTAssertEqual(western.target, #"C:\Èãðà\a.exe"#)
        XCTAssertEqual(Launcher.splitArguments("\0"), [])
        XCTAssertEqual(Launcher.splitArguments("-a\0 -b"), ["-a", "-b"])
    }

    func testWindowsLanguageFollowsTheMacsLanguages() {
        XCTAssertEqual(WindowsLanguage.automatic(preferred: ["en-US", "uk-UA"])?.locale, "uk_UA")
        XCTAssertEqual(WindowsLanguage.automatic(preferred: ["ru"])?.codepage, 1251)
        XCTAssertEqual(WindowsLanguage.automatic(preferred: ["zh-Hant-TW"])?.locale, "zh_TW")
        XCTAssertEqual(WindowsLanguage.automatic(preferred: ["zh-Hans-CN"])?.locale, "zh_CN")
        XCTAssertNil(WindowsLanguage.automatic(preferred: ["en-US", "fr-FR"]))
        XCTAssertEqual(WindowsLanguage.resolve("ja_JP", preferred: ["ru-RU"])?.locale, "ja_JP")

        var settings = GameSettings()
        let prefix = URL(fileURLWithPath: "/p")
        XCTAssertEqual(Launcher.environment(prefix: prefix, settings: settings, preferredLanguages: ["en-US", "uk-UA"])["LC_ALL"],
                       "uk_UA.UTF-8")
        settings.language = "en_US"
        XCTAssertEqual(Launcher.environment(prefix: prefix, settings: settings, preferredLanguages: ["ru-RU"])["LC_ALL"],
                       "en_US.UTF-8")
        settings.language = "ru_RU"
        settings.environment = "LC_ALL=C"
        XCTAssertEqual(Launcher.environment(prefix: prefix, settings: settings, preferredLanguages: [])["LC_ALL"], "C")
    }

    func testShortcutToALithTechLauncherStartsTheGame() throws {
        let folder = try temporaryFolder()
        let template = try makePrefix(in: folder, named: "template", files: [])
        let prefix = try makePrefix(in: folder, named: "bottle", files: [
            "Games/AvP2/Avp2.exe", "Games/AvP2/Lithtech.exe", "Games/AvP2/avp2cmds.txt",
            "Games/Other/Play.exe", "Games/Other/Lithtech.exe", "users/me/Desktop/placeholder",
        ])
        let game = prefix.appendingPathComponent("drive_c/Games/AvP2")
        try (Data("MZ\0LITHTECH.EXE\0\\lithtech.exe -cmdfile AVP2cmds.txt\0more".utf8))
            .write(to: game.appendingPathComponent("Avp2.exe"))
        let direct = try XCTUnwrap(LauncherDetector.directStart(for: game.appendingPathComponent("Avp2.exe")))
        XCTAssertEqual(direct.executable.lastPathComponent, "Lithtech.exe")
        XCTAssertEqual(direct.arguments, "-cmdfile avp2cmds.txt")
        XCTAssertNil(LauncherDetector.directStart(for: game.appendingPathComponent("Lithtech.exe")))
        // Names the engine but not how it is started, or the command file is missing: left alone.
        let other = prefix.appendingPathComponent("drive_c/Games/Other/Play.exe")
        XCTAssertNil(LauncherDetector.directStart(for: other))
        try Data("lithtech.exe -cmdfile gone.txt".utf8).write(to: other)
        XCTAssertNil(LauncherDetector.directStart(for: other))

        let startMenu = prefix.appendingPathComponent("drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs")
        try FileManager.default.createDirectory(at: startMenu, withIntermediateDirectories: true)
        try makeShortcut(target: #"C:\Games\AvP2\Avp2.exe"#).write(to: startMenu.appendingPathComponent("AvP 2.lnk"))
        // Installers usually add a desktop shortcut to the same launcher.
        try makeShortcut(target: #"C:\Games\AvP2\Avp2.exe"#)
            .write(to: prefix.appendingPathComponent("drive_c/users/me/Desktop/AvP 2.lnk"))
        let programs = GameInstaller.installedPrograms(prefix: prefix, since: .take(prefix: template))
        let choice = try XCTUnwrap(GameInstaller.obviousChoice(among: programs))
        XCTAssertEqual(choice.name, "AvP 2")
        XCTAssertEqual(choice.executable.lastPathComponent, "Lithtech.exe")
        XCTAssertEqual(choice.arguments, "-cmdfile avp2cmds.txt")
        // The launcher is still offered, once, and the engine isn't listed a second time.
        XCTAssertEqual(programs.filter { $0.executable.path.contains("AvP2") }.map(\.executable.lastPathComponent),
                       ["Lithtech.exe", "Avp2.exe"])
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

        let programs = GameInstaller.installedPrograms(prefix: prefix, since: .take(prefix: template))
        XCTAssertEqual(programs.map(\.name), ["Foo Deluxe", "Foo"])
        XCTAssertEqual(programs.map(\.executable.lastPathComponent), ["Foo.exe", "config.exe"])
        XCTAssertEqual(programs.map(\.hasShortcut), [true, false])
        XCTAssertEqual(programs[0].arguments, "-skipintro")
        XCTAssertEqual(GameInstaller.obviousChoice(among: programs), programs[0])
        XCTAssertNil(GameInstaller.obviousChoice(among: Array(programs.dropFirst()) + [programs[1]]))
        XCTAssertNil(GameInstaller.resolve(windowsPath: #"C:\GOG Games\Missing\x.exe"#, prefix: prefix))
    }

    func testPlainShortcutWinsOverVariantsOfTheSameProgram() throws {
        let folder = try temporaryFolder()
        let template = try makePrefix(in: folder, named: "template", files: [])
        let prefix = try makePrefix(in: folder, named: "bottle", files: [
            "EA/Carbon/nfsc.exe", "EA/Carbon/nfs_inst.exe", "EA/Carbon/nfs_uninst.exe", "EA/Carbon/against.exe",
        ])
        let startMenu = prefix.appendingPathComponent("drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Carbon")
        try FileManager.default.createDirectory(at: startMenu, withIntermediateDirectories: true)
        // "Carbon Safemode.lnk" sorts before "Carbon.lnk", and the installer spells the target differently.
        try makeShortcut(target: #"C:\EA\Carbon\nfsc.exe"#, arguments: "/s").write(to: startMenu.appendingPathComponent("Carbon Safemode.lnk"))
        try makeShortcut(target: #"C:\EA\Carbon\NFSC.exe"#).write(to: startMenu.appendingPathComponent("Carbon.lnk"))

        let programs = GameInstaller.installedPrograms(prefix: prefix, since: .take(prefix: template))
        XCTAssertEqual(programs.map(\.name), ["Carbon", "Carbon"])
        XCTAssertEqual(programs.map(\.executable.lastPathComponent), ["nfsc.exe", "against.exe"])
        XCTAssertEqual(programs[0].arguments, "")
        XCTAssertEqual(GameInstaller.obviousChoice(among: programs), programs[0])

        // With only the variant, its arguments are kept.
        try FileManager.default.removeItem(at: startMenu.appendingPathComponent("Carbon.lnk"))
        let variant = GameInstaller.installedPrograms(prefix: prefix, since: .take(prefix: template))
        XCTAssertEqual(variant.first?.name, "Carbon Safemode")
        XCTAssertEqual(variant.first?.arguments, "/s")
    }

    func testInstallingIntoASharedBottleOnlyOffersWhatIsNew() throws {
        let folder = try temporaryFolder()
        let fm = FileManager.default
        let prefix = try makePrefix(in: folder, named: "bottle", files: [
            "Games/Old/Old.exe", "users/me/Desktop/placeholder",
        ])
        let desktop = prefix.appendingPathComponent("drive_c/users/me/Desktop")
        try makeShortcut(target: #"C:\Games\Old\Old.exe"#).write(to: desktop.appendingPathComponent("Old.lnk"))
        let before = BottleSnapshot.take(prefix: prefix)
        XCTAssertTrue(GameInstaller.installedPrograms(prefix: prefix, since: before).isEmpty)

        // A second game arrives beside the first, which the installer could see and patch.
        let new = prefix.appendingPathComponent("drive_c/Games/New/New.exe")
        try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: new)
        try makeShortcut(target: #"C:\Games\New\New.exe"#).write(to: desktop.appendingPathComponent("New Game.lnk"))
        let programs = GameInstaller.installedPrograms(prefix: prefix, since: before)
        XCTAssertEqual(programs.map(\.name), ["New Game"])
        XCTAssertEqual(GameInstaller.obviousChoice(among: programs)?.executable.lastPathComponent, "New.exe")

        // A patch that rewrites the old game's shortcut offers that game again.
        let later = BottleSnapshot.take(prefix: prefix)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                             ofItemAtPath: desktop.appendingPathComponent("Old.lnk").path)
        XCTAssertEqual(GameInstaller.installedPrograms(prefix: prefix, since: later).map(\.name), ["Old"])
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
        let plan = GameInstaller.plan(for: URL(fileURLWithPath: "/d/setup.exe"), prefix: prefix, engine: .crossover,
                                      runtime: withCrossOver, arguments: "/S")
        XCTAssertEqual(plan.executable.path, "/rt/cx/bin/wine")
        XCTAssertEqual(plan.arguments, ["/d/setup.exe", "/S"])
        XCTAssertEqual(plan.environment["WINEPREFIX"], prefix.path)
        XCTAssertEqual(plan.environment["WINEDLLOVERRIDES"], "winemenubuilder.exe=d")
        XCTAssertEqual(plan.workingDirectory.path, "/d")
    }

    func testEnvironmentOverridesAndWorkingFolder() throws {
        var game = Game(name: "X", executablePath: "/Games/X/x.exe", bottleID: UUID())
        game.settings.dllOverrides = " dinput8=n,b "
        game.settings.environment = "# a comment\nDXVK_HUD = fps\n\nnot a variable\n9 LIVES=1\nWINEPREFIX=/elsewhere\nEMPTY=\nPATHS=a=b"
        let environment = Launcher.plan(game: game, prefix: prefix, runtime: runtime).environment
        XCTAssertEqual(environment["WINEDLLOVERRIDES"], "dinput8=n,b")
        XCTAssertEqual(environment["DXVK_HUD"], "fps")
        XCTAssertEqual(environment["EMPTY"], "")
        XCTAssertEqual(environment["PATHS"], "a=b")
        XCTAssertNil(environment["9 LIVES"])
        XCTAssertEqual(environment["WINEPREFIX"], prefix.path)
        XCTAssertEqual(Launcher.parseEnvironment(game.settings.environment).map(\.name),
                       ["DXVK_HUD", "WINEPREFIX", "EMPTY", "PATHS"])

        let folder = try temporaryFolder()
        game.settings.workingDirectory = folder.path
        XCTAssertEqual(Launcher.plan(game: game, prefix: prefix, runtime: runtime).workingDirectory.path, folder.path)
        // A folder that has gone missing falls back to the program's own.
        game.settings.workingDirectory = folder.appendingPathComponent("gone").path
        XCTAssertEqual(Launcher.plan(game: game, prefix: prefix, runtime: runtime).workingDirectory.path, "/Games/X")
    }

    func testOldLibraryEntriesStillDecode() throws {
        let json = #"[{"id":"7E5A8E0C-3F0B-4F0E-9B67-0D0A1C2B3D4E","name":"Old","executablePath":"/g/old.exe","#
            + #""bottleID":"1E5A8E0C-3F0B-4F0E-9B67-0D0A1C2B3D4E","settings":{"renderer":"wine"}}]"#
        let game = try XCTUnwrap(JSONDecoder().decode([Game].self, from: Data(json.utf8)).first)
        XCTAssertFalse(game.isFavorite)
        XCTAssertEqual(game.playTime, 0)
        XCTAssertEqual(game.settings.dllOverrides, "")
        XCTAssertEqual(game.settings.environment, "")
    }

    func testCoverMatchingOnlyAcceptsTheSameGame() throws {
        let json = #"{"total":4,"items":[{"type":"app","name":"Portal 2","id":620,"tiny_image":"https://example.com/a.jpg"},"#
            + #"{"type":"app","name":"Portal™","id":400},{"type":"bundle","name":"Portal","id":7},"#
            + #"{"type":"app","name":"Grand Theft Auto: San Andreas – The Definitive Edition","id":1547000}]}"#
        let candidates = try CoverFinder.parse(Data(json.utf8))
        XCTAssertEqual(candidates.map(\.id), [620, 400, 1547000])
        XCTAssertEqual(CoverFinder.bestMatch(for: "portal", among: candidates)?.id, 400)
        XCTAssertEqual(CoverFinder.bestMatch(for: "Portal 2", among: candidates)?.id, 620)
        XCTAssertEqual(CoverFinder.bestMatch(for: "Grand Theft Auto San Andreas", among: candidates)?.id, 1547000)
        XCTAssertNil(CoverFinder.bestMatch(for: "Portal 3", among: candidates))
        XCTAssertNil(CoverFinder.bestMatch(for: "Grand Theft Auto", among: candidates))
        XCTAssertNil(CoverFinder.bestMatch(for: "™", among: candidates))
        XCTAssertEqual(candidates[0].imageURLs.last?.absoluteString, "https://example.com/a.jpg")
        XCTAssertEqual(candidates[0].imageURLs.count, 4)
    }

    /// A PE whose only section is a resource tree holding one icon group with a 16px and a 32px image.
    private func makePEWithIcon() -> Data {
        var data = Data(count: 0x200)
        func put(_ value: Int, at offset: Int, width: Int) {
            for index in 0..<width { data[offset + index] = UInt8((value >> (8 * index)) & 0xFF) }
        }
        let pe = 0x80, optional = pe + 24, sectionTable = optional + 224
        put(0x5A4D, at: 0, width: 2)
        put(pe, at: 0x3C, width: 4)
        put(0x4550, at: pe, width: 4)
        put(1, at: pe + 6, width: 2)
        put(224, at: pe + 20, width: 2)
        put(0x10B, at: optional, width: 2)
        put(16, at: optional + 92, width: 4)
        put(0x1000, at: optional + 96 + 2 * 8, width: 4)  // resource directory RVA
        put(0x1000, at: sectionTable + 8, width: 4)  // virtual size
        put(0x1000, at: sectionTable + 12, width: 4)  // virtual address
        put(0x1000, at: sectionTable + 16, width: 4)  // raw size
        put(0x200, at: sectionTable + 20, width: 4)  // raw offset
        data.append(Data(count: 0x1000))
        let root = 0x200
        /// A directory at `offset` (relative to the root) with the given (id, target) entries.
        func directory(_ offset: Int, _ entries: [(Int, Int)]) {
            put(entries.count, at: root + offset + 14, width: 2)
            for (index, entry) in entries.enumerated() {
                put(entry.0, at: root + offset + 16 + index * 8, width: 4)
                put(entry.1, at: root + offset + 20 + index * 8, width: 4)
            }
        }
        func leaf(_ offset: Int, dataAt: Int, size: Int) {
            put(0x1000 + dataAt, at: root + offset, width: 4)
            put(size, at: root + offset + 4, width: 4)
        }
        let sub = 0x8000_0000
        directory(0x000, [(3, sub | 0x040), (14, sub | 0x0C0)])
        directory(0x040, [(1, sub | 0x060), (2, sub | 0x080)])  // RT_ICON: ids 1 and 2
        directory(0x060, [(1033, 0x200)])
        directory(0x080, [(1033, 0x210)])
        directory(0x0C0, [(1, sub | 0x0E0)])  // RT_GROUP_ICON
        directory(0x0E0, [(1033, 0x220)])
        leaf(0x200, dataAt: 0x300, size: 4)
        leaf(0x210, dataAt: 0x310, size: 6)
        leaf(0x220, dataAt: 0x400, size: 6 + 28)
        for (index, byte) in Array("tiny".utf8).enumerated() { data[root + 0x300 + index] = byte }
        for (index, byte) in Array("bigger".utf8).enumerated() { data[root + 0x310 + index] = byte }
        let group = root + 0x400
        put(1, at: group + 2, width: 2)
        put(2, at: group + 4, width: 2)
        for (index, icon) in [(size: 16, bytes: 4, id: 1), (size: 32, bytes: 6, id: 2)].enumerated() {
            let entry = group + 6 + index * 14
            put(icon.size, at: entry, width: 1)
            put(icon.size, at: entry + 1, width: 1)
            put(1, at: entry + 4, width: 2)
            put(32, at: entry + 6, width: 2)
            put(icon.bytes, at: entry + 8, width: 4)
            put(icon.id, at: entry + 12, width: 2)
        }
        return data
    }

    func testIconExtractionPicksTheLargestImage() throws {
        let icon = try XCTUnwrap(PEImage(data: makePEWithIcon())?.iconFile)
        XCTAssertEqual(Array(icon.prefix(6)), [0, 0, 1, 0, 1, 0])
        XCTAssertEqual(Array(icon[6..<8]), [32, 32])
        XCTAssertEqual(Array(icon[14..<22]), [6, 0, 0, 0, 22, 0, 0, 0])
        XCTAssertEqual(String(decoding: icon.dropFirst(22), as: UTF8.self), "bigger")
        XCTAssertNil(PEImage(data: makePE(is64Bit: true, imports: ["d3d11.dll"]))?.iconFile)
    }
}
