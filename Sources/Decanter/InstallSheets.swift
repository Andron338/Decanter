import DecanterCore
import SwiftUI

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
