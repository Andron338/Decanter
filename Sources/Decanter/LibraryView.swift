import DecanterCore
import SwiftUI
import UniformTypeIdentifiers

enum LibraryFilter: Hashable {
    case all, recent, favorites, running, hidden
    case renderer(Renderer)
    case bottle(UUID)
    case category(String)
}

/// The game selected in the frontmost library window, for the Game menu.
struct SelectedGameKey: FocusedValueKey {
    typealias Value = UUID
}

extension FocusedValues {
    var selectedGameID: UUID? {
        get { self[SelectedGameKey.self] }
        set { self[SelectedGameKey.self] = newValue }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case name, lastPlayed, playTime, added

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .lastPlayed: return "Last Played"
        case .playTime: return "Play Time"
        case .added: return "Date Added"
        }
    }
}

enum LibraryLayout: String {
    case grid, list
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    /// The file chooser was opened from "Install from Installer…", so whatever is picked is run as one.
    @State private var importingInstaller = false
    /// The bottle "Install into This Bottle…" was chosen on; nil offers the default one.
    @State private var installing: UUID?
    @State private var dropTargeted = false
    @State private var filter: LibraryFilter? = .all
    @State private var selection: Game.ID?
    @State private var search = ""
    /// Text of the New Category / Rename Category prompt.
    @State private var categoryName = ""
    @FocusState private var gridFocused: Bool
    @AppStorage("libraryLayout") private var layout = LibraryLayout.grid
    @AppStorage("librarySort") private var sort = LibrarySort.name
    @AppStorage("librarySortReversed") private var sortReversed = false
    @AppStorage("coverSize") private var coverSize = 160.0

    private let windowsTypes: [UTType] = [.exe, UTType(filenameExtension: "msi") ?? .data]

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSubtitle(model.runtime?.summary ?? "")
        .fileImporter(isPresented: $importing, allowedContentTypes: windowsTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            if importingInstaller, let first = urls.first {
                model.requestInstall(first, bottleID: installing)
            } else {
                model.add(urls)
            }
        }
        .sheet(item: $model.installRequest) { InstallSheet(request: $0) }
        .sheet(item: $model.editing) { GameSettingsSheet(game: $0) }
        .sheet(item: $model.installerResult) { InstallerResultSheet(result: $0) }
        .sheet(item: $model.coverSearch) { CoverSearchSheet(game: $0) }
        .sheet(isPresented: $model.managingBottles) { BottlesSheet(initial: selectedBottleID) }
        .sheet(isPresented: $model.choosingSteamGames) { SteamGamesSheet() }
        .focusedSceneValue(\.selectedGameID, selection)
        .alert("New Category", isPresented: Binding(
            get: { model.namingCategory != nil }, set: { if !$0 { model.namingCategory = nil } }
        )) {
            TextField("Name", text: $categoryName)
            Button("Add") {
                if let game = model.namingCategory { model.setCategory(categoryName, included: true, for: game) }
                categoryName = ""
            }
            .disabled(GameCategories.clean(categoryName).isEmpty)
            Button("Cancel", role: .cancel) { categoryName = "" }
        } message: {
            Text("\(model.namingCategory?.name ?? "The game") goes into the new category, which appears in the sidebar.")
        }
        .alert("Rename Category", isPresented: Binding(
            get: { model.renamingCategory != nil }, set: { if !$0 { model.renamingCategory = nil } }
        )) {
            TextField("Name", text: $categoryName)
            Button("Rename") {
                if let old = model.renamingCategory {
                    model.renameCategory(old, to: categoryName)
                    if filter == .category(old) { filter = .category(GameCategories.clean(categoryName)) }
                }
                categoryName = ""
            }
            .disabled(GameCategories.clean(categoryName).isEmpty)
            Button("Cancel", role: .cancel) { categoryName = "" }
        }
        .onChange(of: model.renamingCategory) { _, name in
            if let name { categoryName = name }
        }
        .confirmationDialog(
            "Remove \(model.pendingRemoval?.name ?? "this game")?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            presenting: model.pendingRemoval
        ) { game in
            if model.isOnlyGame(inItsBottle: game) {
                Button("Remove and Delete Its Bottle", role: .destructive) { remove(game, deletingBottle: true) }
                Button("Remove from Library Only") { remove(game, deletingBottle: false) }
            } else {
                Button("Remove", role: .destructive) { remove(game, deletingBottle: false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { game in
            let bottle = model.bottle(game.bottleID)?.displayName ?? "its bottle"
            Text(model.isOnlyGame(inItsBottle: game)
                 ? "It is the only game in the bottle “\(bottle)”. Deleting the bottle also deletes anything installed in it and saves kept there. Files outside Decanter aren't touched."
                 : "The game leaves your library. Anything it installed stays in the bottle “\(bottle)”, which other games may rely on. Files outside Decanter aren't touched.")
        }
    }

    private func remove(_ game: Game, deletingBottle: Bool) {
        if selection == game.id { selection = nil }
        model.remove(game, deletingBottle: deletingBottle)
    }

    /// The bottle the sidebar is showing, which is where the bottle manager opens.
    private var selectedBottleID: UUID? {
        if case .bottle(let id) = filter { return id }
        return nil
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $filter) {
            Section("Library") {
                sidebarRow(.all, "Games", "gamecontroller")
                sidebarRow(.recent, "Recent", "clock")
                sidebarRow(.favorites, "Favorites", "star")
                if !model.running.isEmpty {
                    sidebarRow(.running, "Running", "play.circle")
                }
                if model.games.contains(where: \.isHidden) {
                    sidebarRow(.hidden, "Hidden", "eye.slash")
                }
            }
            let categories = model.categories
            if !categories.isEmpty {
                Section("Categories") {
                    ForEach(categories, id: \.self) { name in
                        sidebarRow(.category(name), name, "tag")
                            .contextMenu {
                                Button("Rename…") { model.renamingCategory = name }
                                Button("Delete Category") { model.deleteCategory(name) }
                            }
                    }
                }
            }
            let renderers = Renderer.allCases.filter { renderer in
                model.games.contains { $0.settings.renderer == renderer }
            }
            if !renderers.isEmpty {
                Section("Renderers") {
                    ForEach(renderers) { sidebarRow(.renderer($0), $0.shortName, $0.symbol) }
                }
            }
            if !model.bottles.isEmpty {
                Section("Bottles") {
                    ForEach(model.bottles) { bottle in
                        sidebarRow(.bottle(bottle.id), bottle.displayName,
                                   bottle.id == model.defaultBottleID ? "wineglass.fill" : "wineglass")
                            .contextMenu {
                                Button("Install into This Bottle…") { chooseFile(installer: true, bottle: bottle.id) }
                                if bottle.id != model.defaultBottleID {
                                    Button("Make Default") { model.setDefaultBottle(bottle.id) }
                                }
                                Divider()
                                Button("Manage Bottles…") {
                                    filter = .bottle(bottle.id)
                                    model.managingBottles = true
                                }
                            }
                    }
                }
            }
        }
        .onChange(of: model.bottles.map(\.id)) { _, ids in
            if let id = selectedBottleID, !ids.contains(id) { filter = .all }
        }
        .onChange(of: model.categories) { _, names in
            if case .category(let name) = filter, !names.contains(where: { GameCategories.same($0, name) }) {
                filter = .all
            }
        }
        .onChange(of: model.games.contains(where: \.isHidden)) { _, anyHidden in
            if !anyHidden && filter == .hidden { filter = .all }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
    }

    private func sidebarRow(_ filter: LibraryFilter, _ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .badge(games(in: filter).count)
            .tag(filter)
    }

    // MARK: Filtering and sorting

    private func games(in filter: LibraryFilter) -> [Game] {
        // Hidden games stay out of every view except Hidden itself and Running.
        let shown = model.games.filter { !$0.isHidden }
        switch filter {
        case .all: return shown
        case .recent: return shown.filter { $0.lastPlayed != nil }
        case .favorites: return shown.filter(\.isFavorite)
        case .running: return model.games.filter { model.running.contains($0.id) }
        case .hidden: return model.games.filter(\.isHidden)
        case .renderer(let renderer): return shown.filter { $0.settings.renderer == renderer }
        case .bottle(let id): return shown.filter { $0.bottleID == id }
        case .category(let name): return shown.filter { $0.isIn(category: name) }
        }
    }

    private var visibleGames: [Game] {
        let filter = filter ?? .all
        var games = games(in: filter)
        let term = search.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty { games = games.filter { $0.name.localizedCaseInsensitiveContains(term) } }
        // "Recent" is only useful newest-first, whatever the library is sorted by.
        let sort = filter == .recent ? LibrarySort.lastPlayed : sort
        let byName: (Game, Game) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        switch sort {
        case .name: games.sort(by: byName)
        case .lastPlayed: games.sort { ($0.lastPlayed ?? .distantPast, $1.name) > ($1.lastPlayed ?? .distantPast, $0.name) }
        case .playTime: games.sort { ($0.playTime, $1.name) > ($1.playTime, $0.name) }
        case .added: games.sort { ($0.added ?? .distantPast, $1.name) > ($1.added ?? .distantPast, $0.name) }
        }
        return sortReversed && filter != .recent ? games.reversed() : games
    }

    private var selectedGame: Game? {
        model.games.first { $0.id == selection }
    }

    // MARK: Detail

    private var detail: some View {
        let games = visibleGames
        return ZStack {
            if model.games.isEmpty {
                emptyState
            } else if games.isEmpty {
                if search.trimmingCharacters(in: .whitespaces).isEmpty {
                    ContentUnavailableView("Nothing here yet", systemImage: "square.grid.2x2",
                                           description: Text("No games match this part of your library."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            } else if layout == .grid {
                grid(games)
            } else {
                table(games)
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    .padding(10)
                    .allowsHitTesting(false)
            }
            if let message = model.busyMessage {
                busyOverlay(message)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            if !model.steamSuggestions.isEmpty { SteamSuggestionBanner() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.games.isEmpty {
                ActionBar(game: selectedGame, gameCount: games.count,
                          coverSize: layout == .grid ? $coverSize : nil)
            }
        }
        .searchable(text: $search, prompt: "Search games")
        .toolbar { toolbar }
        .onChange(of: games.map(\.id)) { _, visible in
            // A game that is filtered out or removed can't stay selected: the action bar would act on
            // something no longer on screen.
            if let selection, !visible.contains(selection) { self.selection = nil }
        }
    }

    private func grid(_ games: [Game]) -> some View {
        GeometryReader { geometry in
            // How many covers fit across, matching the adaptive grid below: 22 pt padding each side,
            // 20 pt between covers.
            let columns = max(1, Int((geometry.size.width - 44 + 20) / (coverSize + 20)))
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: coverSize, maximum: coverSize * 1.35), spacing: 20)],
                              spacing: 22) {
                        ForEach(games) { game in
                            GameCard(game: game, isSelected: selection == game.id)
                                .id(game.id)
                                .simultaneousGesture(TapGesture(count: 2).onEnded { model.play(game) })
                                .simultaneousGesture(TapGesture().onEnded {
                                    selection = game.id
                                    gridFocused = true
                                })
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
                    .background {
                        // Clicking the empty space between covers clears the selection.
                        Color.clear.contentShape(Rectangle()).onTapGesture {
                            selection = nil
                            gridFocused = true
                        }
                    }
                }
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    move(press.key, in: games, columns: columns)
                    if let selection { withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(selection) } }
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let game = selectedGame, !model.running.contains(game.id) else { return .ignored }
                    model.play(game)
                    return .handled
                }
                // The Delete key arrives as the delete command, not as a key press SwiftUI's `.delete` matches.
                .onDeleteCommand {
                    if let game = selectedGame { model.pendingRemoval = game }
                }
            }
        }
    }

    /// Moves the selection like Finder's icon view: left and right step through the list, up and down
    /// jump a row. With nothing selected, any arrow selects the first game.
    private func move(_ key: KeyEquivalent, in games: [Game], columns: Int) {
        guard let current = games.firstIndex(where: { $0.id == selection }) else {
            selection = games.first?.id
            return
        }
        let target: Int
        switch key {
        case .leftArrow: target = current - 1
        case .rightArrow: target = current + 1
        case .upArrow: target = current - columns
        default: target = current + columns
        }
        selection = games[min(max(target, 0), games.count - 1)].id
    }

    private func table(_ games: [Game]) -> some View {
        Table(games, selection: $selection) {
            TableColumn("Name") { game in
                HStack(spacing: 10) {
                    CoverArt(game: game, cornerRadius: 3).frame(width: 24, height: 36)
                    Text(game.name)
                    if game.isFavorite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    }
                    if model.running.contains(game.id) {
                        Text("Running").font(.caption).foregroundStyle(.green)
                    }
                }
                .padding(.vertical, 2)
            }
            TableColumn("Renderer") { game in
                Text(game.settings.renderer.shortName).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100, max: 140)
            TableColumn("Last Played") { game in
                Text(game.lastPlayed?.formatted(.relative(presentation: .named)) ?? "Never")
                    .foregroundStyle(.secondary)
            }
            .width(min: 100, ideal: 130, max: 180)
            TableColumn("Play Time") { game in
                Text(game.playTimeText ?? "—").foregroundStyle(.secondary).monospacedDigit()
            }
            .width(min: 80, ideal: 100, max: 140)
        }
        .contextMenu(forSelectionType: Game.ID.self) { ids in
            if let game = model.games.first(where: { ids.contains($0.id) }) {
                GameMenu(game: game)
            }
        } primaryAction: { ids in
            if let game = model.games.first(where: { ids.contains($0.id) }) { model.play(game) }
        }
        .onDeleteCommand {
            if let game = selectedGame { model.pendingRemoval = game }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Picker("View", selection: $layout) {
                Label("Covers", systemImage: "square.grid.2x2").tag(LibraryLayout.grid)
                Label("List", systemImage: "list.bullet").tag(LibraryLayout.list)
            }
            .pickerStyle(.segmented)
            .help("Show the library as covers or as a list")
        }
        ToolbarItem {
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Toggle("Reverse Order", isOn: $sortReversed)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Change how the library is sorted")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Add Game…") { chooseFile(installer: false) }
                    .keyboardShortcut("o")
                Button("Install from Installer…") { chooseFile(installer: true) }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Install Steam…") { model.installSteam() }
                Button("Find Steam Games") { model.findSteamGames(includingDismissed: true) }
                Divider()
                Button("Manage Bottles…") { model.managingBottles = true }
                    .keyboardShortcut("b")
            } label: {
                Label("Add Game", systemImage: "plus")
            } primaryAction: {
                chooseFile(installer: false)
            }
            .help("Add a Windows game, or install one from its installer")
        }
    }

    private func busyOverlay(_ message: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(message).multilineTextAlignment(.center).frame(maxWidth: 320)
            if let active = model.activeInstall {
                HStack {
                    if active.isNewGame {
                        Button("Cancel Install", role: .destructive) { model.cancelInstall() }
                            .help(active.discardsOnCancel
                                  ? "Stop the installer and throw away the bottle made for it"
                                  : "Stop the installer. What it already put in the bottle stays there")
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

    private func chooseFile(installer: Bool, bottle: UUID? = nil) {
        installing = bottle
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

/// The strip along the bottom of the library: the selected game with its main actions, and the cover
/// size slider when covers are showing.
struct ActionBar: View {
    @Environment(AppModel.self) private var model
    let game: Game?
    let gameCount: Int
    /// nil in the list layout, which has no covers to resize.
    let coverSize: Binding<Double>?

    var body: some View {
        HStack(spacing: 12) {
            if let game {
                let isRunning = model.running.contains(game.id)
                CoverArt(game: game, cornerRadius: 4).frame(width: 30, height: 45)
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name).font(.headline).lineLimit(1)
                    Text(details(game, isRunning: isRunning))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                Button {
                    isRunning ? model.stop(game) : model.play(game)
                } label: {
                    Label(isRunning ? "Stop" : "Play", systemImage: isRunning ? "stop.fill" : "play.fill")
                        .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(isRunning ? .red : .accentColor)
                .controlSize(.large)
                Button {
                    model.editing = game
                } label: {
                    Image(systemName: "gearshape").frame(width: 18, height: 18)
                }
                .accessibilityLabel("Configure")
                .controlSize(.large)
                .help("Configure \(game.name)")
                Menu {
                    GameMenu(game: game)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 18, height: 18)
                }
                .accessibilityLabel("More actions")
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
                .controlSize(.large)
                .fixedSize()
                .help("More actions")
            } else {
                Text(gameCount == 1 ? "1 game" : "\(gameCount) games")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            if let coverSize {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3").font(.caption)
                    Slider(value: coverSize, in: 110...260).frame(width: 110).controlSize(.small)
                    Image(systemName: "square.grid.2x2")
                }
                .foregroundStyle(.secondary)
                .help("Cover size")
                .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func details(_ game: Game, isRunning: Bool) -> String {
        var parts = [game.settings.renderer.shortName, isRunning ? "Running" : game.lastPlayedText]
        if let playTime = game.playTimeText { parts.append(playTime + " played") }
        return parts.joined(separator: " · ")
    }
}
