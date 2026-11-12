import DecanterCore
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
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
                Button {
                    importing = true
                } label: {
                    Label("Add Game", systemImage: "plus")
                }
                .help("Add a Windows game or installer")
                .keyboardShortcut("o")
            }
        }
        .navigationSubtitle(model.runtime?.summary ?? "")
        .fileImporter(isPresented: $importing, allowedContentTypes: windowsTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .sheet(item: $model.editing) { GameSettingsSheet(game: $0) }
        .sheet(item: $model.installerResult) { InstallerResultSheet(result: $0) }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a Windows game here").font(.title2.bold())
            Text("A game's .exe, or its installer. Decanter handles the rest.")
                .foregroundStyle(.secondary)
            Button("Choose File…") { importing = true }
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

struct InstallerResultSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let result: InstallerResult
    @State private var selection: Set<URL> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which one is the game?").font(.title2.bold())
            Text("The installer added several programs. Pick the ones you want in your library.")
                .foregroundStyle(.secondary)
            List(result.executables, id: \.self, selection: $selection) { url in
                VStack(alignment: .leading) {
                    Text(url.lastPathComponent)
                    Text(url.deletingLastPathComponent().lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancelInstallerResult(result)
                    dismiss()
                }
                Button("Add to Library") {
                    for url in result.executables where selection.contains(url) {
                        model.appendGame(executable: url, bottleID: result.bottleID)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .interactiveDismissDisabled()
    }
}
