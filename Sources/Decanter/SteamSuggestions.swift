import DecanterCore
import SwiftUI

/// A suggested Steam game's cover, or its program's icon, or a placeholder.
struct SteamArtwork: View {
    @Environment(AppModel.self) private var model
    let suggestion: SteamSuggestion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary)
            if let image = model.steamArtwork[suggestion.id] {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "gamecontroller.fill").foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// The strip across the top of the library when Steam has games the library doesn't.
struct SteamSuggestionBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let suggestions = model.steamSuggestions
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(suggestions.prefix(3)) { SteamArtwork(suggestion: $0).frame(width: 28, height: 42) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestions.count == 1 ? "Steam has a game that isn't in your library"
                     : "Steam has \(suggestions.count) games that aren't in your library")
                    .font(.headline).lineLimit(1)
                Text(suggestions.map(\.app.name).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            if suggestions.count > 1 {
                Button("Choose…") { model.choosingSteamGames = true }
            }
            Button(suggestions.count == 1 ? "Add" : "Add All") { model.addSteamGames(suggestions) }
                .buttonStyle(.borderedProminent)
            Button {
                model.dismissSteamSuggestions()
            } label: {
                Image(systemName: "xmark").frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss")
            .help("Don't suggest these. “Find Steam Games” in the + menu brings them back")
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// Picks which of the suggested Steam games go in the library.
struct SteamGamesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add games from Steam").font(.title2.bold())
            Text("Steam has downloaded these. Decanter starts them through Steam, in Steam's bottle.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(model.steamSuggestions) { suggestion in
                Toggle(isOn: Binding(
                    get: { selection.contains(suggestion.id) },
                    set: { if $0 { selection.insert(suggestion.id) } else { selection.remove(suggestion.id) } }
                )) {
                    HStack(spacing: 10) {
                        SteamArtwork(suggestion: suggestion).frame(width: 28, height: 42)
                        VStack(alignment: .leading) {
                            Text(suggestion.app.name)
                            Text(model.bottle(suggestion.bottleID)?.displayName ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            .frame(minHeight: 220)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Library") {
                    model.addSteamGames(model.steamSuggestions.filter { selection.contains($0.id) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { selection = Set(model.steamSuggestions.map(\.id)) }
    }
}
