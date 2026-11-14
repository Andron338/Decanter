import DecanterCore
import SwiftUI
import UniformTypeIdentifiers

/// Create, rename, inspect and delete bottles, and choose the one new games go in.
struct BottlesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The bottle to show first; the default one when nil.
    let initial: UUID?
    @State private var selection: UUID?
    @State private var pendingDelete: Bottle?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                list.frame(width: 210)
                Divider()
                Group {
                    if let bottle = selection.flatMap(model.bottle) {
                        detail(bottle)
                    } else {
                        ContentUnavailableView("No Bottle Selected", systemImage: "wineglass",
                                               description: Text("Choose a bottle, or make one with +."))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("A bottle is a Windows environment. Games installed in the same one see each other's files.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 720, height: 520)
        .onAppear { selection = initial ?? model.defaultBottleID ?? model.bottles.first?.id }
        .confirmationDialog(
            "Delete “\(pendingDelete?.displayName ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { bottle in
            Button("Delete Bottle", role: .destructive) {
                if selection == bottle.id { selection = model.defaultBottleID }
                model.deleteBottle(bottle.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { bottle in
            let games = model.games(in: bottle).map(\.name)
            Text("This deletes everything installed in the bottle and any saves kept there. It can't be undone."
                 + (games.isEmpty ? "" : " \(games.count == 1 ? "This game leaves" : "These games leave") your library: \(games.joined(separator: ", ")).")
                 + " Files outside Decanter aren't touched.")
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            List(model.bottles, selection: $selection) { bottle in
                HStack {
                    Image(systemName: bottle.id == model.defaultBottleID ? "wineglass.fill" : "wineglass")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bottle.displayName).lineLimit(1)
                        Text(subtitle(bottle)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(bottle.id)
            }
            Divider()
            HStack(spacing: 2) {
                Button {
                    selection = model.createBottle(named: "New Bottle").id
                } label: {
                    Image(systemName: "plus").frame(width: 22, height: 20)
                }
                .help("Make a new, empty bottle")
                .accessibilityLabel("New Bottle")
                Button {
                    pendingDelete = selection.flatMap(model.bottle)
                } label: {
                    Image(systemName: "minus").frame(width: 22, height: 20)
                }
                .disabled(selection == nil || selection == model.defaultBottleID)
                .help(selection == model.defaultBottleID
                      ? "The default bottle can't be deleted. Make another bottle the default first."
                      : "Delete the selected bottle")
                .accessibilityLabel("Delete Bottle")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private func subtitle(_ bottle: Bottle) -> String {
        let count = model.games(in: bottle).count
        let games = count == 1 ? "1 game" : "\(count) games"
        return bottle.id == model.defaultBottleID ? "Default · \(games)" : games
    }

    private func detail(_ bottle: Bottle) -> some View {
        let isDefault = bottle.id == model.defaultBottleID
        let games = model.games(in: bottle)
        return Form {
            Section {
                TextField("Name", text: Binding(
                    get: { bottle.name }, set: { model.renameBottle(bottle.id, to: $0) }))
                LabeledContent {
                    if isDefault {
                        Text("Yes")
                    } else {
                        Button("Make Default") { model.setDefaultBottle(bottle.id) }
                    }
                } label: {
                    Text("Default bottle")
                    Text("Where games and installers you drop on Decanter go.")
                }
                LabeledContent("Created") { Text(bottle.created.formatted(date: .abbreviated, time: .omitted)) }
            }
            Section {
                if bottle.engines.isEmpty {
                    Text("Nothing has run here yet. The Windows environment is made the first time a game or an installer does.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(bottle.engines, id: \.self) { engine in
                    LabeledContent(engine.title.prefix(1).uppercased() + engine.title.dropFirst()) {
                        HStack {
                            Button("Open C:") { model.openDriveC(bottle, engine: engine) }
                            Menu("More") {
                                Button("Add a Program from Here to the Library…") {
                                    model.addProgram(from: bottle, engine: engine)
                                }
                                Divider()
                                Button("Wine Configuration") { model.runTool("winecfg", in: bottle, engine: engine) }
                                Button("Registry Editor") { model.runTool("regedit", in: bottle, engine: engine) }
                            }
                            .fixedSize()
                        }
                    }
                }
                LabeledContent("Installers, patches and add-ons") {
                    Button("Install into This Bottle…") { install(into: bottle) }
                }
            } header: {
                Text("Windows Environment")
            } footer: {
                if bottle.engines.count > 1 {
                    Text("Each engine keeps its own C: drive here, because they are different versions of Wine. An installer only sees what was installed with the same engine.")
                }
            }
            Section("Games") {
                if games.isEmpty {
                    Text("No games use this bottle.").foregroundStyle(.secondary)
                }
                ForEach(games) { game in
                    LabeledContent(game.name) { Text(game.settings.renderer.shortName) }
                }
            }
            Section {
                Button("Delete Bottle…", role: .destructive) { pendingDelete = bottle }
                    .disabled(isDefault)
            } footer: {
                if isDefault {
                    Text("The default bottle can't be deleted. Make another bottle the default first.")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The install sheet belongs to the library window, so this one has to close first.
    private func install(into bottle: Bottle) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.exe, UTType(filenameExtension: "msi") ?? .data]
        panel.message = "Choose an installer, patch or add-on to run in “\(bottle.displayName)”"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.requestInstall(url, bottleID: bottle.id) }
    }
}
