import DecanterCore
import SwiftUI

/// Confirms an explicit "Install from Installer…" and lets the user pick the bottle and the engine it
/// runs on.
struct InstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: InstallRequest
    @State private var engine = Engine.wine
    /// nil means a new bottle, named `newName`.
    @State private var bottleID: UUID?
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install a game").font(.title2.bold())
            VStack(alignment: .leading, spacing: 2) {
                Text(request.installer.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(request.kind?.displayName ?? "Not a known installer type. Decanter will run it as one anyway.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Bottle", selection: $bottleID) {
                ForEach(model.bottles) { bottle in
                    Text(bottle.id == model.defaultBottleID ? "\(bottle.displayName) (default)" : bottle.displayName)
                        .tag(UUID?.some(bottle.id))
                }
                Divider()
                Text("New Bottle…").tag(UUID?.none)
            }
            if bottleID == nil {
                TextField("Name", text: $newName, prompt: Text("New Bottle"))
            }
            Picker("Install for", selection: $engine) {
                Text("Modern games (DirectX 10 and newer)").tag(Engine.wine)
                Text("Older games (DirectX 9 and earlier, 32-bit)").tag(Engine.crossover)
                if model.runtime?.hasD3DMetal == true {
                    Text("DirectX 12 games (D3DMetal)").tag(Engine.gptk)
                }
            }
            Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let warning = engineWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("The installer opens in its own window. Go through it as you would on Windows, and leave the install location as it is.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Install") {
                    model.install(request.installer, engine: engine,
                                  into: bottleID.map(BottleChoice.existing) ?? .new(name: newName))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            bottleID = request.bottleID ?? model.defaultBottleID
            newName = GameNaming.displayName(for: request.installer)
            followBottle()
        }
        .onChange(of: bottleID) { followBottle() }
    }

    private var bottle: Bottle? { bottleID.flatMap(model.bottle) }

    /// Start on the engine the bottle's last installer used: only that one sees what it installed.
    private func followBottle() {
        guard let bottle, !bottle.engines.isEmpty, model.runtime?.has(bottle.installEngine) == true else { return }
        engine = bottle.installEngine
    }

    /// Each engine keeps its own Windows environment inside a bottle, so an installer on a new engine
    /// starts from nothing even in a bottle that has games.
    private var engineWarning: String? {
        guard let bottle, !bottle.engines.isEmpty, !bottle.engines.contains(engine) else { return nil }
        let used = bottle.engines.map(\.title).joined(separator: " and ")
        return "Nothing in “\(bottle.displayName)” was installed with this choice yet, so the installer won't see what is installed there for \(used). Pick that to patch or add to those games."
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
            Text(programs.isEmpty ? (result.createdBottle ? "Couldn't find the game" : "Nothing new to add")
                 : "Which one is the game?").font(.title2.bold())
            Text(programs.isEmpty
                 ? (result.createdBottle
                    ? "The installer finished, but Decanter found nothing new. If it installed somewhere unusual, choose the game's program yourself. If you cancelled it, discard this install."
                    : "The installer finished without adding a new program to “\(result.bottleName)”. If it was a patch or an add-on, you're done. Otherwise choose the game's program yourself.")
                 : "The installer added several programs to “\(result.bottleName)”. Pick the ones you want in your library.")
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
                if result.createdBottle {
                    Button("Discard Install", role: .destructive) {
                        model.discardInstallerResult(result)
                        dismiss()
                    }
                    .help("Delete the bottle made for this install, with everything in it")
                } else {
                    Button(programs.isEmpty ? "Done" : "Add Nothing") { dismiss() }
                        .help("What the installer put in the bottle stays there")
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

extension Engine {
    /// How the install sheet and the bottle manager name an engine.
    var title: String {
        switch self {
        case .wine: return "modern games (Wine 11)"
        case .crossover: return "older games (CrossOver)"
        case .gptk: return "DirectX 12 games (D3DMetal)"
        }
    }
}
