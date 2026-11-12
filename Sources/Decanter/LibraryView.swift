import DecanterCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    /// The file chooser was opened from "Install from Installer…", so whatever is picked is run as one.
    @State private var importingInstaller = false
    @State private var dropTargeted = false

    private let windowsTypes: [UTType] = [.exe, UTType(filenameExtension: "msi") ?? .data]

    var body: some View {
        @Bindable var model = model
        ZStack {
            if model.games.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 18)], spacing: 18) {
                        ForEach(model.games) { GameCard(game: $0) }
                    }
                    .padding(22)
                }
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .padding(10)
                    .allowsHitTesting(false)
            }
            if let message = model.busyMessage {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(message).multilineTextAlignment(.center).frame(maxWidth: 320)
                    if let active = model.activeInstall {
                        HStack {
                            if active.isNewGame {
                                Button("Cancel Install", role: .destructive) { model.cancelInstall() }
                                    .help("Stop the installer and throw away what it installed so far")
                                Button("Installer Is Done") { model.finishInstall() }
                                    .help("Use this if the installer has finished but left a launcher or the game running")
                            } else {
                                Button("Stop") { model.finishInstall() }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(28)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: {
            dropTargeted = $0
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Add Game…") { chooseFile(installer: false) }
                        .keyboardShortcut("o")
                    Button("Install from Installer…") { chooseFile(installer: true) }
                        .keyboardShortcut("i")
                } label: {
                    Label("Add Game", systemImage: "plus")
                } primaryAction: {
                    chooseFile(installer: false)
                }
                .help("Add a Windows game, or install one from its installer")
            }
        }
        .navigationSubtitle(model.runtime?.summary ?? "")
        .fileImporter(isPresented: $importing, allowedContentTypes: windowsTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            if importingInstaller, let first = urls.first {
                model.requestInstall(first)
            } else {
                model.add(urls)
            }
        }
        .sheet(item: $model.installRequest) { InstallSheet(request: $0) }
        .sheet(item: $model.editing) { GameSettingsSheet(game: $0) }
        .sheet(item: $model.installerResult) { InstallerResultSheet(result: $0) }
    }

    private func chooseFile(installer: Bool) {
        importingInstaller = installer
        importing = true
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a Windows game here").font(.title2.bold())
            Text("A game's .exe, or its installer. Decanter handles the rest.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose File…") { chooseFile(installer: false) }
                Button("Install from Installer…") { chooseFile(installer: true) }
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
    }
}

struct GameCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    @State private var hovering = false

    private var isRunning: Bool { model.running.contains(game.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(gradient)
                Text(initials)
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                if hovering || isRunning {
                    RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.35))
                    Button {
                        isRunning ? model.stop(game) : model.play(game)
                    } label: {
                        Image(systemName: isRunning ? "stop.fill" : "play.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                            .frame(width: 60, height: 60)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(isRunning ? "Stop" : "Play")
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)

            Text(game.name).font(.headline).lineLimit(1)
            Text(isRunning ? "Running" : lastPlayedText)
                .font(.caption)
                .foregroundStyle(isRunning ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.play(game) }
        .contextMenu {
            Button(isRunning ? "Stop" : "Play") { isRunning ? model.stop(game) : model.play(game) }
            Button("Settings…") { model.editing = game }
            Divider()
            Button("Show Log") { model.showLog(game) }
            Button("Open C: Drive") { model.openDriveC(game) }
            Button("Wine Configuration") { model.runTool("winecfg", in: game) }
            Button("Run Patch or Installer…") { model.runInstaller(in: game) }
            Divider()
            Button("Remove", role: .destructive) { model.remove(game) }
        }
    }

    private var lastPlayedText: String {
        guard let date = game.lastPlayed else { return "Never played" }
        return "Played " + date.formatted(.relative(presentation: .named))
    }

    private var initials: String {
        let words = game.name.split(separator: " ").filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
        return words.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var gradient: LinearGradient {
        // Stable per-name hue (String.hashValue changes every launch).
        let seed = game.name.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        let hue = Double(seed % 360) / 360
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.65, brightness: 0.75),
                     Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.45)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct GameSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var game: Game

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $game.name)
                    LabeledContent("Program") {
                        Text(game.executablePath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    }
                }
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
                        Text("Wine 11 built-in").tag(Renderer.wine)
                    }
                    if game.settings.renderer == .crossover {
                        Text(model.runtime?.hasCrossOver == true
                             ? "Runs on CrossOver's Wine 9 in its own Windows environment, separate from the other renderers."
                             : "Runs on CrossOver's Wine 9. Decanter downloads it (about 165 MB) the first time you press Play.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if game.settings.renderer == .d3dmetal {
                        if model.runtime?.hasD3DMetal == true {
                            Toggle("Ray tracing (DXR)", isOn: $game.settings.rayTracing)
                            Toggle("DLSS through MetalFX", isOn: $game.settings.metalFX)
                            Toggle("Report AVX support to the game", isOn: $game.settings.advertiseAVX)
                            Text("D3DMetal runs on Apple's own Wine with a separate Windows environment, so saves and anything an installer set up don't carry over from the other renderers.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            D3DMetalInstallRow()
                        }
                    }
                } header: {
                    Text("Graphics")
                } footer: {
                    Text("If a game shows a black screen or quits at launch, try another renderer.")
                }
                Section("Compatibility") {
                    Toggle(isOn: $game.settings.virtualDesktop) {
                        Text("Run in a fixed-size window")
                        Text("Fixes older games that crash when switching to fullscreen.")
                    }
                    if game.settings.virtualDesktop {
                        Picker("Window size", selection: $game.settings.virtualDesktopSize) {
                            ForEach(["1024x768", "1280x720", "1440x900", "1920x1080", "2560x1440"], id: \.self) { Text($0) }
                        }
                    }
                }
                Section("Extras") {
                    Toggle("High-resolution (Retina) rendering", isOn: $game.settings.retina)
                    Toggle("Fast synchronisation", isOn: $game.settings.fastSync)
                    Toggle("Show Metal performance overlay", isOn: $game.settings.performanceHUD)
                    TextField("Launch arguments", text: $game.settings.arguments, prompt: Text("e.g. -windowed"))
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.update(game)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 540, height: 680)
    }

    /// A warning when the chosen renderer can't handle what the game was detected to use.
    private func rendererAdvice(_ requirements: GameRequirements) -> String? {
        guard let top = requirements.directX.last else { return nil }
        let hasModern = requirements.directX.contains { $0 >= 10 }
        switch game.settings.renderer {
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

/// Confirms an explicit "Install from Installer…" and lets the user pick the engine it runs on.
struct InstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: InstallRequest
    @State private var engine = Engine.wine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install a game").font(.title2.bold())
            VStack(alignment: .leading, spacing: 2) {
                Text(request.installer.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(request.kind?.displayName ?? "Not a known installer type. Decanter will run it as one anyway.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Install for", selection: $engine) {
                Text("Modern games (DirectX 10 and newer)").tag(Engine.wine)
                Text("Older games (DirectX 9 and earlier, 32-bit)").tag(Engine.crossover)
                if model.runtime?.hasD3DMetal == true {
                    Text("DirectX 12 games (D3DMetal)").tag(Engine.gptk)
                }
            }
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("The installer opens in its own window. Go through it as you would on Windows, and leave the install location as it is.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") {
                    model.install(request.installer, engine: engine)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var note: String {
        switch engine {
        case .wine:
            return "Runs on Wine 11. If the game turns out to be an older one, Decanter still switches its renderer for you."
        case .crossover:
            return model.runtime?.hasCrossOver == true
                ? "Runs on CrossOver's Wine 9, which also suits installers that crash on Wine 11."
                : "Runs on CrossOver's Wine 9, which also suits installers that crash on Wine 11. Decanter downloads it first (about 165 MB)."
        case .gptk:
            return "Runs on Apple's Wine, so the game is installed where D3DMetal can use it."
        }
    }
}

struct InstallerResultSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let result: InstallerResult
    @State private var programs: [InstalledProgram] = []
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(programs.isEmpty ? "Couldn't find the game" : "Which one is the game?").font(.title2.bold())
            Text(programs.isEmpty
                 ? "The installer finished, but Decanter found nothing new. If it installed somewhere unusual, choose the game's program yourself. If you cancelled it, discard this install."
                 : "The installer added several programs. Pick the ones you want in your library.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(programs, selection: $selection) { program in
                HStack {
                    VStack(alignment: .leading) {
                        Text(program.name)
                        Text(program.executable.deletingLastPathComponent().lastPathComponent + "\\" + program.executable.lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if program.hasShortcut {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                            .help("The installer made a shortcut for this one")
                    }
                }
            }
            .frame(minHeight: 220)
            HStack {
                Button("Choose Another…") {
                    guard let program = model.browseInstalled(result) else { return }
                    if !programs.contains(where: { $0.id == program.id }) { programs.append(program) }
                    selection.insert(program.id)
                }
                Spacer()
                Button("Discard Install", role: .destructive) {
                    model.discardInstallerResult(result)
                    dismiss()
                }
                Button("Add to Library") {
                    model.addInstalled(programs.filter { selection.contains($0.id) }, from: result)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled()
        .onAppear {
            programs = result.programs
            selection = Set(result.programs.filter(\.hasShortcut).map(\.id))
        }
    }
}
