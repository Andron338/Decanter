import Foundation

/// Cover images live beside the library, one file per game, in whatever format they arrived in.
public enum CoverStore {
    public static func url(for gameID: UUID) -> URL {
        Paths.covers.appendingPathComponent(gameID.uuidString)
    }

    public static func data(for gameID: UUID) -> Data? {
        try? Data(contentsOf: url(for: gameID))
    }

    public static func save(_ data: Data, for gameID: UUID) throws {
        try Paths.ensure(Paths.covers)
        try data.write(to: url(for: gameID), options: .atomic)
    }

    public static func remove(_ gameID: UUID) {
        try? FileManager.default.removeItem(at: url(for: gameID))
    }
}

public extension ExecutableInspector {
    /// The icon embedded in a Windows program, as `.ico` data, or nil if it has none.
    static func icon(of executable: URL) -> Data? {
        PEImage(url: executable)?.iconFile
    }
}

/// A game found in an online catalogue, with the places its cover might be.
public struct CoverCandidate: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let thumbnail: URL?

    public init(id: Int, name: String, thumbnail: URL? = nil) {
        self.id = id
        self.name = name
        self.thumbnail = thumbnail
    }

    /// Portrait cover first; older catalogue entries only have the landscape banner.
    public var imageURLs: [URL] {
        ["library_600x900_2x.jpg", "library_600x900.jpg", "header.jpg"].compactMap {
            URL(string: "https://shared.steamstatic.com/store_item_assets/steam/apps/\(id)/\($0)")
        } + [thumbnail].compactMap { $0 }
    }
}

/// Looks covers up by name in Steam's public store search, which needs no account or key.
public enum CoverFinder {
    public static func search(_ name: String) async throws -> [CoverCandidate] {
        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        components.queryItems = [
            URLQueryItem(name: "term", value: name), URLQueryItem(name: "l", value: "english"),
            URLQueryItem(name: "cc", value: "US"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("Decanter", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DecanterError("Couldn't reach the Steam store to look for covers.")
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [CoverCandidate] {
        struct Response: Decodable {
            struct Item: Decodable {
                let type: String?
                let name: String
                let id: Int
                let tiny_image: String?
            }
            let items: [Item]
        }
        return try JSONDecoder().decode(Response.self, from: data).items
            .filter { ($0.type ?? "app") == "app" }
            .map { CoverCandidate(id: $0.id, name: $0.name, thumbnail: $0.tiny_image.flatMap(URL.init(string:))) }
    }

    /// The candidate that is clearly the same game: the same title once punctuation is ignored, or the
    /// title plus an edition name. Anything looser risks putting a sequel's cover on the wrong game.
    public static func bestMatch(for name: String, among candidates: [CoverCandidate]) -> CoverCandidate? {
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return nil }
        if let exact = candidates.first(where: { normalize($0.name) == wanted }) { return exact }
        return candidates.first { candidate in
            let other = normalize(candidate.name)
            guard other.hasPrefix(wanted + " ") else { return false }
            let rest = other.dropFirst(wanted.count + 1)
            return editionSuffixes.contains { rest == $0 }
        }
    }

    static let editionSuffixes = Set([
        "Definitive Edition", "Enhanced Edition", "Complete Edition", "Game of the Year Edition", "GOTY Edition",
        "GOTY", "Remastered", "Gold Edition", "Gold", "Deluxe Edition", "Special Edition", "Legendary Edition",
        "Anniversary Edition", "Director's Cut", "HD", "Classic",
    ].map(normalize))

    /// Lowercased words only: no punctuation, accents, trademark signs or leading articles.
    static func normalize(_ name: String) -> String {
        name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .split(separator: " ")
            .map { String($0) }
            .filter { !["the", "a", "of", "tm"].contains($0) }
            .joined(separator: " ")
    }

    /// Downloads the first of the candidate's images that exists.
    public static func download(_ candidate: CoverCandidate) async -> Data? {
        for url in candidate.imageURLs {
            if let data = await fetchImage(url) { return data }
        }
        return nil
    }

    public static func fetchImage(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("Decanter", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 512 else { return nil }
        return data
    }

    /// Searches for `name` and returns the cover of the game that clearly matches, if there is one.
    public static func cover(forGameNamed name: String) async throws -> Data? {
        guard let match = bestMatch(for: name, among: try await search(name)) else { return nil }
        return await download(match)
    }
}
