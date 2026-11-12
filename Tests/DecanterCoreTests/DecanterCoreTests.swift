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
}
