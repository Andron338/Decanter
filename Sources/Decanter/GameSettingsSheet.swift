import DecanterCore
import SwiftUI
import UniformTypeIdentifiers

/// Per-game configuration, in four tabs: what the game is, how it is started, how it is rendered, and
/// the lower-level system options.
struct GameSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var game: Game
    @State private var tab = Tab.info
    @State private var searchingCover = false
    @State private var newCategory = ""

    /// Categories already in the library plus any this sheet added and hasn't saved yet.
    private var categoryChoices: [String] {
        GameCategories.all(in: model.games.filter { $0.id != game.id } + [game])
    }

    private func addCategory() {
        game.setCategory(newCategory, included: true)
        newCategory = ""
    }
    /// Set when the game's program is a launcher menu that Decanter knows how to skip.
    @State private var directStart: LauncherDetector.DirectStart?

    private enum Tab: String, CaseIterable, Identifiable {
        case info = "Game Info", options = "Game Options", graphics = "Graphics", system = "System"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 4)

            Group {
                switch tab {
                case .info: infoTab
                case .options: optionsTab
                case .graphics: graphicsTab
                case .system: systemTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.update(game)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(game.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 640, height: 600)
        .sheet(isPresented: $searchingCover) { CoverSearchSheet(game: game) }
        .task(id: game.executablePath) {
            directStart = LauncherDetector.directStart(for: URL(fileURLWithPath: game.executablePath))
        }
    }

    // MARK: Game info

    private var infoTab: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 10) {
                CoverArt(game: game)
                    .frame(width: 160, height: 240)
                    .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
                    .dropDestination(for: URL.self) { urls, _ in
                        guard let url = urls.first else { return false }
                        model.setCover(from: url, for: game)
                        return true
                    }
                Button { model.chooseCover(for: game) } label: { Text("Choose Image…").frame(maxWidth: .infinity) }
                Button { searchingCover = true } label: { Text("Find Online…").frame(maxWidth: .infinity) }
                if model.covers[game.id] != nil {
                    Button { model.removeCover(for: game) } label: { Text("Remove Cover").frame(maxWidth: .infinity) }
                }
                Text("Cover changes apply straight away.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(width: 160)
            .padding(.leading, 20)
            .padding(.top, 20)

            Form {
                Section {
                    TextField("Name", text: $game.name)
                    Toggle("Favorite", isOn: Binding(
                        get: { game.isFavorite }, set: { game.favorite = $0 ? true : nil }))
                    Toggle(isOn: Binding(get: { game.isHidden }, set: { game.hidden = $0 ? true : nil })) {
                        Text("Hidden")
                        Text("Shown only under Hidden in the sidebar.")
                    }
                    LabeledContent("Categories") {
                        Menu(game.categoryNames.isEmpty ? "None" : game.categoryNames.joined(separator: ", ")) {
                            ForEach(categoryChoices, id: \.self) { name in
                                Toggle(name, isOn: Binding(
                                    get: { game.isIn(category: name) },
                                    set: { game.setCategory(name, included: $0) }))
                            }
                        }
                        .fixedSize()
                    }
                    HStack {
                        TextField("New category", text: $newCategory, prompt: Text("Name"))
                            .onSubmit(addCategory)
                        Button("Add", action: addCategory)
                            .disabled(GameCategories.clean(newCategory).isEmpty)
                    }
                }
                Section("Activity") {
                    LabeledContent("Last played") {
                        Text(game.lastPlayed?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    }
                    LabeledContent("Play time", value: game.playTimeText ?? "None yet")
                    if let added = game.added {
                        LabeledContent("Added") { Text(added.formatted(date: .abbreviated, time: .omitted)) }
                    }
                }
                if let requirements = game.requirements {
                    Section("Detected") {
                        LabeledContent("Program", value: requirements.is64Bit ? "64-bit" : "32-bit")
                        LabeledContent("Graphics", value: requirements.graphicsSummary)
                        if !requirements.runtimes.isEmpty {
                            LabeledContent("Needs", value: requirements.runtimes.joined(separator: ", "))
                        }
                        if requirements.guessedFromStrings {
                            Text("A best guess: this program is packed, which hides what it uses.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: Game options

    private var optionsTab: some View {
        Form {
            Section("Program") {
                LabeledContent("Executable") {
                    HStack {
                        Text(game.executablePath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Button("Change…", action: chooseExecutable)
                    }
                }
                if !FileManager.default.fileExists(atPath: game.executablePath) {
                    Label("This file is missing. Was the game moved or its drive unplugged?",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let directStart {
                    LabeledContent {
                        Button("Skip the Launcher") {
                            game.executablePath = directStart.executable.path
                            game.settings.arguments = directStart.arguments
                        }
                    } label: {
                        Text("This program is the game's launcher")
                        Text("Decanter can start the game itself instead. Change the program back to reach the launcher's options.")
                    }
                }
                TextField("Arguments", text: $game.settings.arguments, prompt: Text("e.g. -windowed"))
                LabeledContent("Working folder") {
                    HStack {
                        Text(game.settings.workingDirectory.isEmpty
                             ? "The program's own folder" : game.settings.workingDirectory)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        if !game.settings.workingDirectory.isEmpty {
                            Button("Reset") { game.settings.workingDirectory = "" }
                        }
                        Button("Choose…", action: chooseWorkingDirectory)
                    }
                }
            }
            Section {
                Picker("Bottle", selection: $game.bottleID) {
                    ForEach(model.bottles) { Text($0.displayName).tag($0.id) }
                }
                LabeledContent("C: drive") {
                    Button("Open in Finder") { model.openDriveC(game) }
                }
                LabeledContent("Patches and add-ons") {
                    Button("Run Patch or Installer…") {
                        dismiss()
                        model.runInstaller(in: game)
                    }
                }
            } header: {
                Text("Windows Environment")
            } footer: {
                Text("Games in the same bottle share one Windows environment, so installers and patches see each other's files. Moving a game to another bottle doesn't move what was installed for it; do that only for games that live outside Decanter. Manage bottles from the + menu.")
            }
        }
        .formStyle(.grouped)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.exe]
        panel.directoryURL = URL(fileURLWithPath: game.executablePath).deletingLastPathComponent()
        panel.message = "Choose the program that starts \(game.name)"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        game.executablePath = url.path
    }

    private func chooseWorkingDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = URL(fileURLWithPath: game.executablePath).deletingLastPathComponent()
        panel.message = "Choose the folder \(game.name) should start in"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        game.settings.workingDirectory = url.path
    }

    // MARK: Graphics

    private var graphicsTab: some View {
        Form {
            Section {
                if let requirements = game.requirements {
                    LabeledContent("Detected") {
                        Text(requirements.summary).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                    if let advice = rendererAdvice(requirements) {
                        Label(advice, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Picker("Renderer", selection: $game.settings.renderer) {
                    Text("Metal — DXMT (DirectX 10/11)").tag(Renderer.metal)
                    Text("D3DMetal — Apple (DirectX 11/12)").tag(Renderer.d3dmetal)
                    Text("CrossOver engine (DirectX 9 and older, 32-bit)").tag(Renderer.crossover)
                    Text("Wine 10 — DirectX 9 to 12 (Steam)").tag(Renderer.sikarugir)
                    Text("Wine 11 built-in").tag(Renderer.wine)
                }
                if game.settings.renderer == .sikarugir {
                    Picker(selection: $game.settings.wine10Graphics) {
                        Text("Automatic").tag(Wine10Graphics.automatic)
                        Text("DXMT (DirectX 10, 11)").tag(Wine10Graphics.metal)
                        Text("vkd3d (DirectX 12)").tag(Wine10Graphics.vkd3d)
                        Text("D3DMetal (DirectX 11, 12)").tag(Wine10Graphics.d3dmetal)
                        Text("Wine's own").tag(Wine10Graphics.wine)
                    } label: {
                        Text("DirectX")
                        Text(wine10Explanation)
                    }
                }
                if game.settings.renderer == .crossover {
                    Text(model.runtime?.hasCrossOver == true
                         ? "Runs on CrossOver's Wine 9, which keeps its own Windows environment inside the bottle, separate from the other renderers."
                         : "Runs on CrossOver's Wine 9. Decanter downloads it (about 165 MB) the first time you press Play.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if game.settings.renderer == .sikarugir, Launcher.wine10Graphics(for: game) == .d3dmetal,
                   model.runtime?.hasD3DMetal == true {
                    Toggle("Ray tracing (DXR)", isOn: $game.settings.rayTracing)
                    Toggle("DLSS through MetalFX", isOn: $game.settings.metalFX)
                    Toggle("Report AVX support to the game", isOn: $game.settings.advertiseAVX)
                    if game.steamAppID != nil {
                        Text("Steam passes these to its games when it starts, so it restarts when they change.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if game.settings.renderer == .d3dmetal {
                    if model.runtime?.hasD3DMetal == true {
                        Toggle("Ray tracing (DXR)", isOn: $game.settings.rayTracing)
                        Toggle("DLSS through MetalFX", isOn: $game.settings.metalFX)
                        Toggle("Report AVX support to the game", isOn: $game.settings.advertiseAVX)
                        Text(Launcher.startsThroughSteam(game)
                             ? "Steam crashes on Apple's own Wine, so this game will run on Wine 10 with D3DMetal, beside Steam."
                             : "D3DMetal runs on Apple's own Wine with a separate Windows environment, so saves and anything an installer set up don't carry over from the other renderers.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        D3DMetalInstallRow()
                    }
                }
            } header: {
                Text("Renderer")
            } footer: {
                Text("If a game shows a black screen or quits at launch, try another renderer.")
            }
            Section("Display") {
                Toggle(isOn: $game.settings.scaledFullscreen) {
                    Text("Scaled fullscreen")
                    Text("For games stuck in a small window: lets the game use resolutions this Mac's screen "
                         + "doesn't have, such as 800x600 or 1024x768, stretched to the whole screen with black "
                         + "bars at the sides. The Mac's screen looks softer while the game runs.")
                }
                Toggle(isOn: $game.settings.virtualDesktop) {
                    Text("Run in a fixed-size window")
                    Text("Fixes older games that crash when switching to fullscreen.")
                }
                .disabled(game.settings.scaledFullscreen)
                if game.settings.virtualDesktop && !game.settings.scaledFullscreen {
                    Picker(selection: $game.settings.virtualDesktopSize) {
                        Text("Match screen").tag(Launcher.screenSizedDesktop)
                        ForEach(["1024x768", "1280x720", "1440x900", "1920x1080", "2560x1440"], id: \.self) { Text($0) }
                    } label: {
                        Text("Largest window size")
                        Text("The window takes the resolution the game is set to, up to this size. "
                             + "To make it bigger, raise the resolution in the game's own video options.")
                    }
                    if game.settings.virtualDesktopSize != Launcher.screenSizedDesktop {
                        Toggle(isOn: $game.settings.fillScreen) {
                            Text("Fill the screen")
                            Text("Lowers the Mac's resolution while the game runs, so a window of this size nearly "
                                 + "fills the screen. Set the game to this resolution in its video options.")
                        }
                        .disabled(game.settings.retina)
                    }
                }
                Toggle("High-resolution (Retina) rendering", isOn: $game.settings.retina)
                Toggle("Show Metal performance overlay", isOn: $game.settings.performanceHUD)
            }
        }
        .formStyle(.grouped)
    }

    private var wine10Explanation: String {
        let route = Launcher.wine10Graphics(for: game)
        let automatic = game.settings.wine10Graphics == .automatic ? "Using \(route == .vkd3d ? "vkd3d" : route == .d3dmetal ? "D3DMetal" : "DXMT") for this game. " : ""
        let steam = game.steamAppID != nil ? " If Steam is already running with the other choice, it restarts first." : ""
        switch route {
        case .vkd3d:
            return automatic + "DirectX 12 through vkd3d on MoltenVK. DirectX 9, 10 and 11 use Wine's own renderer." + steam
        case .d3dmetal:
            return automatic + "DirectX 11 and 12 through Apple's D3DMetal, from the Game Porting Toolkit download"
                + " (vkd3d stands in until that's installed). DirectX 9 uses Wine's own renderer." + steam
        case .wine:
            return (game.settings.wine10Graphics == .automatic ? "Using Wine's own for this older game. " : "")
                + "Wine's own renderer for every DirectX version." + steam
        case .metal, .automatic:
            return automatic + "DirectX 10/11 through DXMT; DirectX 9 uses Wine's own renderer. "
                + "DirectX 12 needs the vkd3d choice: the two can't share a game." + steam
        }
    }

    /// A warning when the chosen renderer can't handle what the game was detected to use.
    private func rendererAdvice(_ requirements: GameRequirements) -> String? {
        guard let top = requirements.directX.last else { return nil }
        let hasModern = requirements.directX.contains { $0 >= 10 }
        let wine10 = Launcher.wine10Graphics(for: game)
        switch game.settings.renderer {
        case .sikarugir where wine10 == .metal && top == 12 && !requirements.directX.contains(11) && !requirements.directX.contains(10):
            return "This game uses DirectX 12, which DXMT can't translate. Choose vkd3d."
        case .sikarugir where wine10 == .vkd3d && !requirements.directX.contains(12) && hasModern:
            return "This game uses DirectX 10/11, which runs best through DXMT. Choose DXMT."
        case .metal where top == 12 && !requirements.directX.contains(11) && !requirements.directX.contains(10):
            return "This game uses DirectX 12, which DXMT can't translate. Choose D3DMetal."
        case .metal where !hasModern, .d3dmetal where !hasModern:
            return "This game uses DirectX \(top <= 7 ? "7 or older" : String(top)), which this renderer doesn't cover. The CrossOver engine is the best choice for it."
        case .d3dmetal where !requirements.is64Bit:
            return "D3DMetal is built for 64-bit games; this one is 32-bit and may not start."
        default:
            return nil
        }
    }

    // MARK: System

    /// What the mod-loader setting will do, from the files next to the game's program. A hand-made
    /// Steam entry's program is only known once Steam's library is read at launch.
    private var modLoaderExplanation: String {
        let base = "Uses a mod loader in the game's folder (such as Ultimate ASI Loader posing as d3d8.dll) "
            + "instead of Wine's own DLL, so .asi mods load, including in games Steam starts."
        let program = Launcher.startsThroughSteam(game)
            ? game.iconPath.map { URL(fileURLWithPath: $0) }
            : URL(fileURLWithPath: game.executablePath)
        guard let program else { return base + " The game's folder is checked when it starts." }
        let dlls = ModLoaders.proxyDLLs(besides: program).map { $0 + ".dll" }
        let found = dlls.isEmpty ? "No loader DLL found next to \(program.lastPathComponent)."
            : "Found \(dlls.joined(separator: ", "))" + (ModLoaders.hasASIMods(besides: program) ? " and .asi mods." : ", but no .asi mods.")
        let effect = ModLoaders.wanted(game.settings.modLoaders, program: program).isEmpty ? " Wine uses its own." : " Wine will use the game's."
        return base + " " + found + effect
    }

    private var systemTab: some View {
        Form {
            Section("Wine") {
                Toggle(isOn: $game.settings.fastSync) {
                    Text("Fast synchronisation")
                    Text("MSync. Faster for most games; turn it off if one hangs or stutters.")
                }
                Picker(selection: $game.settings.modLoaders) {
                    Text("Automatic").tag(ModLoaderMode.automatic)
                    Text("On").tag(ModLoaderMode.on)
                    Text("Off").tag(ModLoaderMode.off)
                } label: {
                    Text("Mod loaders")
                    Text(modLoaderExplanation)
                }
                TextField("DLL overrides", text: $game.settings.dllOverrides, prompt: Text("e.g. dinput8=n,b;d3d9=n"))
                Text("Makes Wine prefer a DLL shipped with the game or a mod (n) over its own (b). Many mod loaders need this.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Windows language", selection: $game.settings.language) {
                    Text("Automatic (\(WindowsLanguage.automatic()?.name ?? "same as this Mac"))").tag("")
                    Divider()
                    ForEach(WindowsLanguage.all) { Text($0.name).tag($0.locale) }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Older games store text in their language's own encoding. If letters come out as symbols like Çàïóñê, choose the language the game was made in.")
            }
            Section {
                TextEditor(text: $game.settings.environment)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 88)
                    .scrollContentBackground(.hidden)
                let count = Launcher.parseEnvironment(game.settings.environment).count
                Text(count == 0 ? "One per line, as NAME=value." : "\(count) variable\(count == 1 ? "" : "s") will be set.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Environment Variables")
            }
            Section("Tools") {
                LabeledContent("Wine") {
                    HStack {
                        Button("Configuration") { model.runTool("winecfg", in: game) }
                        Button("Registry Editor") { model.runTool("regedit", in: game) }
                    }
                }
                LabeledContent("Last run") {
                    Button("Show Log") { model.showLog(game) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Shown when D3DMetal is picked but not downloaded yet. Downloading requires accepting Apple's licence.
struct D3DMetalInstallRow: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        switch model.d3dMetalInstall {
        case .working(let stage, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                if let fraction { ProgressView(value: fraction) } else { ProgressView().controlSize(.small) }
                Text(stage).font(.caption).foregroundStyle(.secondary)
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                if case .failed(let message) = model.d3dMetalInstall {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Text("D3DMetal isn't installed yet. Until it is, this game uses the Metal (DXMT) renderer.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Download…") { confirming = true }
                }
            }
            .confirmationDialog("Download Apple's D3DMetal?", isPresented: $confirming) {
                Button("Agree and Download (about 230 MB)") { model.installD3DMetal() }
                Button("Read Apple's Licence") { NSWorkspace.shared.open(RuntimeManager.d3dMetalLicenseURL) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("D3DMetal is Apple's proprietary DirectX 11/12 translator from the Game Porting Toolkit. It isn't open source and is covered by Apple's licence, which you accept by downloading. Decanter fetches the community binary build of the toolkit.")
            }
        }
    }
}
