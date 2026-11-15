import DecanterCore
import SwiftUI
import UniformTypeIdentifiers

extension Renderer {
    var shortName: String {
        switch self {
        case .metal: return "DXMT"
        case .d3dmetal: return "D3DMetal"
        case .crossover: return "CrossOver"
        case .sikarugir: return "Wine 10"
        case .wine: return "Wine 11"
        }
    }

    var symbol: String {
        switch self {
        case .metal: return "cube"
        case .d3dmetal: return "apple.logo"
        case .crossover: return "clock.arrow.circlepath"
        case .sikarugir: return "gamecontroller"
        case .wine: return "wineglass"
        }
    }
}

extension Game {
    var lastPlayedText: String {
        guard let lastPlayed else { return "Never played" }
        return "Played " + lastPlayed.formatted(.relative(presentation: .named))
    }

    /// "3 h 12 min", "45 min", or nil when it has run for under a minute.
    var playTimeText: String? {
        let minutes = Int(playTime / 60)
        guard minutes > 0 else { return nil }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// A game's cover: its cover image if it has one, otherwise the program's own icon on a coloured
/// backdrop, otherwise its initials. Fills whatever frame it is given.
struct CoverArt: View {
    @Environment(AppModel.self) private var model
    let game: Game
    var cornerRadius: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let cover = model.covers[game.id] {
                    coverImage(cover, in: geometry.size)
                } else {
                    gradient
                    if let icon = model.icons[game.id] {
                        let side = min(geometry.size.width * 0.5, 128)
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(icon.size.width < 48 ? .none : .high)
                            .scaledToFit()
                            .frame(width: side, height: side)
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                    } else {
                        Text(initials)
                            .font(.system(size: max(12, geometry.size.width * 0.3), weight: .heavy, design: .rounded))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Art close to the frame's shape fills it. Anything else (a landscape banner, a square logo) is
    /// shown whole over a blurred copy of itself rather than being cropped to a sliver.
    @ViewBuilder
    private func coverImage(_ cover: NSImage, in size: CGSize) -> some View {
        let imageAspect = cover.size.width / max(cover.size.height, 1)
        let frameAspect = size.width / max(size.height, 1)
        let fill = Image(nsImage: cover).resizable().interpolation(.high).scaledToFill()
            .frame(width: size.width, height: size.height).clipped()
        if abs(imageAspect - frameAspect) / max(frameAspect, 0.01) < 0.25 {
            fill
        } else {
            fill.blur(radius: 18).overlay(Color.black.opacity(0.3)).clipped()
            Image(nsImage: cover).resizable().interpolation(.high).scaledToFit()
                .frame(width: size.width, height: size.height)
        }
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
            colors: [Color(hue: hue, saturation: 0.55, brightness: 0.6),
                     Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.28)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct GameCard: View {
    @Environment(AppModel.self) private var model
    let game: Game
    let isSelected: Bool
    @State private var hovering = false
    @State private var dropTargeted = false

    private var isRunning: Bool { model.running.contains(game.id) }

    var body: some View {
        VStack(spacing: 7) {
            CoverArt(game: game)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    if hovering || isRunning {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.35))
                            Button {
                                isRunning ? model.stop(game) : model.play(game)
                            } label: {
                                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .frame(width: 52, height: 52)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help(isRunning ? "Stop" : "Play")
                        }
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if game.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(6)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(dropTargeted ? Color.green : Color.accentColor,
                                      lineWidth: isSelected || dropTargeted ? 3 : 0)
                }
                .shadow(color: .black.opacity(0.3), radius: hovering ? 9 : 4, y: hovering ? 5 : 2)
                .scaleEffect(hovering ? 1.025 : 1)
                .animation(.easeOut(duration: 0.12), value: hovering)

            Text(game.name)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(isRunning ? "Running" : game.lastPlayedText)
                .font(.caption)
                .foregroundStyle(isRunning ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { GameMenu(game: game) }
        // An image dropped on a card becomes its cover; anything else is a game being added.
        .dropDestination(for: URL.self) { urls, _ in
            let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            if let image = images.first { model.setCover(from: image, for: game) }
            model.add(urls.filter { !images.contains($0) })
            return true
        } isTargeted: {
            dropTargeted = $0
        }
    }
}

/// The actions for one game, shared by the right-click menu and the action bar's menu.
struct GameMenu: View {
    @Environment(AppModel.self) private var model
    let game: Game

    var body: some View {
        let isRunning = model.running.contains(game.id)
        Button(isRunning ? "Stop" : "Play", systemImage: isRunning ? "stop.fill" : "play.fill") {
            isRunning ? model.stop(game) : model.play(game)
        }
        Button("Configure…", systemImage: "gearshape") { model.editing = game }
        Button(game.isFavorite ? "Remove from Favorites" : "Add to Favorites",
               systemImage: game.isFavorite ? "star.slash" : "star") { model.toggleFavorite(game) }
        Menu("Categories", systemImage: "tag") {
            ForEach(model.categories, id: \.self) { name in
                Toggle(name, isOn: Binding(
                    get: { game.isIn(category: name) },
                    set: { model.setCategory(name, included: $0, for: game) }))
            }
            if !model.categories.isEmpty { Divider() }
            Button("New Category…") { model.namingCategory = game }
        }
        Button(game.isHidden ? "Unhide" : "Hide", systemImage: game.isHidden ? "eye" : "eye.slash") {
            model.toggleHidden(game)
        }
        Divider()
        Menu("Cover", systemImage: "photo") {
            Button("Choose Image…") { model.chooseCover(for: game) }
            Button("Find Online…") { model.coverSearch = game }
            if model.covers[game.id] != nil {
                Button("Remove Cover") { model.removeCover(for: game) }
            }
        }
        Divider()
        Button("Show Program in Finder", systemImage: "folder") { model.showInFinder(game) }
        Button("Open C: Drive", systemImage: "externaldrive") { model.openDriveC(game) }
        Button("Show Log", systemImage: "doc.text") { model.showLog(game) }
        Divider()
        Button("Wine Configuration", systemImage: "slider.horizontal.3") { model.runTool("winecfg", in: game) }
        Button("Registry Editor", systemImage: "list.bullet.indent") { model.runTool("regedit", in: game) }
        Button("Run Patch or Installer…", systemImage: "shippingbox") { model.runInstaller(in: game) }
        Divider()
        Button("Remove…", systemImage: "trash", role: .destructive) { model.pendingRemoval = game }
    }
}

/// Picks a cover from online search results. The search starts from the game's name and can be edited,
/// for games whose library name isn't quite their title.
struct CoverSearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let game: Game
    @State private var query = ""
    @State private var results: [CoverCandidate] = []
    @State private var status = Status.idle
    @State private var applying: Int?

    private enum Status: Equatable { case idle, searching, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find a cover").font(.title2.bold())
            HStack {
                TextField("Game title", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search", action: search)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || status == .searching)
            }
            Group {
                switch status {
                case .searching:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                case .idle where results.isEmpty:
                    Text("No games found with that title.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .idle:
                    List(results) { candidate in
                        Button {
                            apply(candidate)
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: candidate.thumbnail) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Color.secondary.opacity(0.2)
                                }
                                .frame(width: 116, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                Text(candidate.name)
                                Spacer()
                                if applying == candidate.id { ProgressView().controlSize(.small) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(applying != nil)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(height: 300)
            HStack {
                Text("Results come from the Steam store.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            query = game.name
            search()
        }
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        status = .searching
        Task {
            do {
                results = try await CoverFinder.search(term)
                status = .idle
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    private func apply(_ candidate: CoverCandidate) {
        applying = candidate.id
        Task {
            defer { applying = nil }
            if let data = await CoverFinder.download(candidate), model.setCover(data, for: game) {
                dismiss()
            } else {
                status = .failed("Couldn't download a cover for \(candidate.name).")
            }
        }
    }
}
