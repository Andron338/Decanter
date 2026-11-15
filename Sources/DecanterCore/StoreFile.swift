import Foundation

/// Reads and writes Decanter's own JSON files (the library, the bottle list) so that a file it
/// can't read is never replaced by an empty one.
///
/// A file that exists but doesn't decode (a hand edit gone wrong, a newer version's settings, a
/// damaged disk) is copied aside as `<name>.unreadable-<time>.json` first. Then whatever entries
/// still decode are kept and written back. A file that can't even be opened isn't touched: saving
/// over it is refused until Decanter starts again.
enum StoreFile {
    /// What went wrong while loading, worded for the user. `takeProblems()` hands them over once.
    private static var problems: [String] = []
    /// Files that exist but couldn't be opened, which saving must leave alone.
    private static var locked: Set<String> = []
    private static let lock = NSLock()

    static func takeProblems() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let taken = problems
        problems = []
        return taken
    }

    /// The decoded file, nil when there is none (or nothing in it could be read).
    /// `salvage` decodes what it can of a damaged file and says how many entries were lost; `what`
    /// names the file's contents for the user ("its library").
    static func load<T: Codable>(
        _ url: URL, what: String, salvage: (Data) -> (value: T, lost: Int, total: Int)?
    ) -> T? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            report("Decanter couldn't open \(what) (\(url.lastPathComponent)). Nothing will be saved to it until "
                   + "Decanter is opened again, so the file stays as it is.", locking: url)
            return nil
        }
        if let value = try? JSONDecoder().decode(T.self, from: data) { return value }

        let kept = url.deletingLastPathComponent().appendingPathComponent(asideName(for: url))
        do {
            try fm.copyItem(at: url, to: kept)
        } catch {
            // Without a copy, writing the salvaged part back would lose the rest for good.
            report("Decanter couldn't read \(what) (\(url.lastPathComponent)) or keep a copy of it. Nothing will "
                   + "be saved to it until Decanter is opened again.", locking: url)
            return salvage(data)?.value
        }
        let rescued = salvage(data)
        let detail: String
        if let rescued, rescued.lost > 0, rescued.total > rescued.lost {
            detail = "Decanter couldn't read \(rescued.lost) of the \(rescued.total) entries in \(what), so they are missing."
        } else if let rescued, rescued.lost == 0, rescued.total > 0 {
            detail = "Part of \(what) couldn't be read and was left out."
        } else {
            detail = "Decanter couldn't read \(what), so it starts out empty."
        }
        report(detail + " The file as it was is kept as \(kept.lastPathComponent) in "
               + "\(url.deletingLastPathComponent().path).", locking: nil)
        if let rescued { save(rescued.value, to: url) } else { try? fm.removeItem(at: url) }
        return rescued?.value
    }

    static func save<T: Encodable>(_ value: T, to url: URL) {
        lock.lock()
        let refused = locked.contains(url.path)
        lock.unlock()
        guard !refused else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? Paths.ensure(url.deletingLastPathComponent())
        try? data.write(to: url, options: .atomic)
    }

    /// `library.json` → `library.unreadable-2026-11-15-103012.json`, unique within the folder.
    static func asideName(for url: URL, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = url.deletingPathExtension().lastPathComponent + ".unreadable-" + formatter.string(from: now)
        let folder = url.deletingLastPathComponent()
        var name = stem + ".json", counter = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = "\(stem)-\(counter).json"
            counter += 1
        }
        return name
    }

    private static func report(_ problem: String, locking url: URL?) {
        lock.lock(); defer { lock.unlock() }
        problems.append(problem)
        if let url { locked.insert(url.path) }
    }

    /// Forgets refused files and unreported problems. For tests, which point `Paths.root` elsewhere.
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        problems = []
        locked = []
    }
}

/// An array element that decodes to nil instead of failing the whole array.
struct Lenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension StoreFile {
    /// The entries of a JSON array that still decode.
    static func salvageArray<T: Decodable>(_ data: Data, of: T.Type) -> (value: [T], lost: Int, total: Int)? {
        guard let entries = try? JSONDecoder().decode([Lenient<T>].self, from: data) else { return nil }
        let kept = entries.compactMap(\.value)
        return (kept, entries.count - kept.count, entries.count)
    }
}
