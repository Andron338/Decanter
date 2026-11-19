import DecanterCore
import SwiftUI

@main
struct DecanterApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    init() {
        // Lets `swift run Decanter` behave like a real app (Dock icon, key window) without a bundle.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        // One window, not a WindowGroup: a WindowGroup opens another window for every program
        // opened with Decanter or dropped on its Dock icon. A Window gets the file in the window
        // already open, and the Dock icon brings it back after it is closed.
        Window("Decanter", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
                .onOpenURL { model.add($0) }
                // Coming back from Steam is when it is likely to have finished a download.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.findSteamGames()
                }
        }
        .defaultSize(width: 960, height: 640)
        .commands {
            CommandGroup(replacing: .newItem) {}
            GameCommands(model: model)
        }

        Settings {
            TabView {
                PreferencesView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                RuntimesView()
                    .frame(width: 560, height: 520)
                    .tabItem { Label("Runtimes", systemImage: "shippingbox") }
            }
            .environment(model)
        }
    }
}

/// A single `Window` scene quits the app when it is closed; Decanter keeps running instead, so a game
/// that is still playing keeps being tracked, and the Dock icon brings the window back.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct PreferencesView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("autoCovers") private var autoCovers = true
    @AppStorage(AppModel.newestEnginesKey) private var newestEngines = false

    var body: some View {
        Form {
            Section {
                Toggle("Find cover art automatically", isOn: $autoCovers)
            } footer: {
                Text("Decanter looks each new game's name up in the Steam store, once, and uses the cover if the title matches. Nothing else is sent. You can always set a cover yourself.")
            }
            Section {
                Toggle("Download the newest engine builds", isOn: $newestEngines)
            } footer: {
                Text("Off: Wine, DXMT and the engines come in the versions this Decanter was tested with. On: the newest upstream builds, untested. It applies to the next setup or engine download; engines already installed stay as they are.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: autoCovers) { _, enabled in
            if enabled { model.fetchMissingCovers() }
        }
        .onChange(of: newestEngines) { _, newest in
            EngineBuilds.useNewest = newest
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.needsSetup {
                SetupView()
            } else {
                LibraryView()
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "wineglass.fill")
                .font(.system(size: 64))
                .foregroundStyle(.linearGradient(colors: [.purple, .pink], startPoint: .top, endPoint: .bottom))
            Text("Windows games on your Mac")
                .font(.largeTitle.bold())
            Text("Decanter sets everything up for you: the Wine compatibility layer and a Metal renderer for DirectX. One download of about 235 MB, then just drop in your games.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            if model.rosettaMissing {
                Text(rosettaNote)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)
            }

            switch model.setupState {
            case .needed:
                if model.rosettaMissing {
                    setupChoices
                } else {
                    setupButton("Set Up")
                }
            case .working(let stage, let fraction):
                VStack(spacing: 8) {
                    if let fraction {
                        ProgressView(value: fraction).frame(width: 320)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(stage).font(.callout).foregroundStyle(.secondary)
                    Button("Cancel") { model.cancelSetup() }
                        .keyboardShortcut(.cancelAction)
                }
                .frame(height: 90)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                if model.rosettaMissing {
                    setupChoices
                } else {
                    setupButton("Try Again")
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.checkRosetta() }
    }

    private var rosettaNote: String {
        let start = model.runtime == nil
            ? "Wine is an Intel program, and this Mac doesn't have Rosetta 2 to run it."
            : "Rosetta 2 isn't available any more, so the Wine Decanter set up earlier can't run."
        return start + " Decanter can install Rosetta 2, which agrees to Apple's Rosetta 2 license (macOS may ask for your password)."
    }

    private func setupButton(_ title: String) -> some View {
        Button(title) { model.runSetup() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }

    /// Without Rosetta 2: install it (recommended), or use the experimental Wine that doesn't need it.
    @ViewBuilder private var setupChoices: some View {
        setupButton("Install Rosetta 2 and Set Up")
        if RuntimeManager.canRunWithoutRosetta {
            VStack(spacing: 6) {
                Button("Set Up Without Rosetta") { model.runSetup(native: true) }
                    .controlSize(.large)
                Text("Experimental. Uses MetalSharp Wine, an early-access arm64 build that runs Intel games through FEX. About 1.3 GB, and only its own engine: CrossOver, the Steam engine and D3DMetal need Rosetta.")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
        }
    }
}

/// The Game menu: shortcuts for the game selected in the library.
struct GameCommands: Commands {
    let model: AppModel
    @FocusedValue(\.selectedGameID) private var selectedID

    private var game: Game? { model.games.first { $0.id == selectedID } }

    var body: some Commands {
        CommandMenu("Game") {
            let isRunning = game.map { model.running.contains($0.id) } ?? false
            Button(isRunning ? "Stop" : "Play") {
                guard let game else { return }
                isRunning ? model.stop(game) : model.play(game)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(game == nil)
            Button("Configure…") { model.editing = game }
                .keyboardShortcut("i")
                .disabled(game == nil)
            Divider()
            Button(game?.isFavorite == true ? "Remove from Favorites" : "Add to Favorites") {
                if let game { model.toggleFavorite(game) }
            }
            .keyboardShortcut("d")
            .disabled(game == nil)
            Button(game?.isHidden == true ? "Unhide" : "Hide") {
                if let game { model.toggleHidden(game) }
            }
            .keyboardShortcut("h", modifiers: [.command, .option, .shift])
            .disabled(game == nil)
            Button("New Category…") { model.namingCategory = game }
                .disabled(game == nil)
            Divider()
            Button("Open Game Folder") {
                if let game { model.openGameFolder(game) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(game == nil)
            Button("Show Program in Finder") {
                if let game { model.showInFinder(game) }
            }
            .keyboardShortcut("r")
            .disabled(game == nil)
            Divider()
            Button("Remove…") { model.pendingRemoval = game }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(game == nil)
        }
    }
}
