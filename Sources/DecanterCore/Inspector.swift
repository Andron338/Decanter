import Foundation

/// What a Windows executable appears to need, read from the file without running it.
public struct GameRequirements: Codable, Equatable, Sendable {
    public var is64Bit: Bool
    /// DirectX major versions referenced, ascending (7 = DirectDraw-era).
    public var directX: [Int]
    public var usesOpenGL: Bool
    public var usesVulkan: Bool
    /// Other runtimes the program links against, e.g. ".NET", "Visual C++ 2015+".
    public var runtimes: [String]
    /// True when the import table was nearly empty (packed/protected exe) and DLL names
    /// were recovered from strings in the file instead, which is less certain.
    public var guessedFromStrings: Bool

    public var graphicsSummary: String {
        var parts: [String] = []
        if let top = directX.last {
            parts.append(directX.contains(11) && top == 12 ? "DirectX 11/12" : "DirectX \(top <= 7 ? "7 or older" : String(top))")
        }
        if usesVulkan { parts.append("Vulkan") }
        if usesOpenGL && directX.isEmpty { parts.append("OpenGL") }
        return parts.isEmpty ? "graphics API not detected" : parts.joined(separator: ", ")
    }

    public var summary: String {
        ([is64Bit ? "64-bit" : "32-bit", graphicsSummary] + runtimes).joined(separator: " · ")
            + (guessedFromStrings ? " (best guess: packed executable)" : "")
    }

    /// nil when nothing useful was detected and the default should stand.
    public var recommendedRenderer: Renderer? {
        if directX.contains(10) || directX.contains(11) { return .metal }
        if directX.contains(12) { return .d3dmetal }
        // DirectX 9 and older, and 32-bit games in general, are where current Wine is weakest on
        // Apple Silicon; CrossOver's Wine 9 handles them far better.
        if !directX.isEmpty || !is64Bit { return .crossover }
        if usesOpenGL || usesVulkan { return .wine }
        return nil
    }
}

public enum ExecutableInspector {
    /// Inspects the exe and the DLLs sitting next to it (engines like Unity keep the renderer in a DLL).
    public static func inspect(_ executable: URL) -> GameRequirements? {
        guard let image = PEImage(url: executable) else { return nil }
        var names = image.importedLibraries
        var runtimes = Set<String>()
        if image.isDotNet { runtimes.insert(".NET") }

        // Windows' own folders hold every system DLL, which says nothing about this particular program.
        let folder = executable.deletingLastPathComponent()
        let isSystemFolder = ["system32", "syswow64", "x86_64-windows", "i386-windows"]
            .contains(folder.lastPathComponent.lowercased())
        let siblings = isSystemFolder ? [] : ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .filter { ["dll", "asi"].contains($0.pathExtension.lowercased()) }
            .prefix(60)
        for sibling in siblings {
            let size = (try? sibling.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size < 300 << 20, let dll = PEImage(url: sibling) else { continue }
            names.formUnion(dll.importedLibraries.filter(isGraphicsLibrary))
        }

        // Packed or copy-protected executables hide their real imports; fall back to names in the file.
        var guessed = false
        if !names.contains(where: isGraphicsLibrary) && image.importedLibraries.count <= 3 {
            let found = image.libraryNamesInStrings().filter(isGraphicsLibrary)
            guessed = !found.isEmpty
            names.formUnion(found)
        }

        var versions = Set<Int>()
        for name in names {
            if let version = directXVersion(of: name) { versions.insert(version) }
            if let runtime = runtimeName(of: name) { runtimes.insert(runtime) }
        }
        return GameRequirements(
            is64Bit: image.is64Bit,
            directX: versions.sorted(),
            usesOpenGL: names.contains("opengl32.dll"),
            usesVulkan: names.contains("vulkan-1.dll"),
            runtimes: runtimes.sorted(),
            guessedFromStrings: guessed)
    }

    static func isGraphicsLibrary(_ name: String) -> Bool {
        directXVersion(of: name) != nil || name == "opengl32.dll" || name == "vulkan-1.dll"
    }

    static func directXVersion(of name: String) -> Int? {
        switch name {
        case "d3d12.dll", "d3d12core.dll": return 12
        case "d3d11.dll", "dxgi.dll": return 11
        case "d3d10.dll", "d3d10_1.dll", "d3d10core.dll": return 10
        case "d3d9.dll": return 9
        case "d3d8.dll": return 8
        case "ddraw.dll": return 7
        default: return nil
        }
    }

    static func runtimeName(of name: String) -> String? {
        if name == "mscoree.dll" { return ".NET" }
        if name.hasPrefix("vcruntime140") || name.hasPrefix("msvcp140") { return "Visual C++ 2015+" }
        for (suffix, year) in [("120", "2013"), ("110", "2012"), ("100", "2010"), ("90", "2008"), ("80", "2005")]
        where name == "msvcr\(suffix).dll" || name == "msvcp\(suffix).dll" {
            return "Visual C++ \(year)"
        }
        return nil
    }
}

/// Minimal read-only parser for the parts of a Windows PE file Decanter cares about.
struct PEImage {
    let data: Data
    let is64Bit: Bool
    let isDotNet: Bool
    private let imageBase: UInt64
    private let sections: [(virtualAddress: Int, virtualSize: Int, rawOffset: Int, rawSize: Int)]
    private let importDirectory: Int
    private let delayImportDirectory: Int

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        self.data = data
        func u16(_ offset: Int) -> Int? { PEImage.read(data, offset, 2) }
        func u32(_ offset: Int) -> Int? { PEImage.read(data, offset, 4) }

        guard u16(0) == 0x5A4D, let pe = u32(0x3C), u32(pe) == 0x0000_4550,
              let sectionCount = u16(pe + 6), let optionalSize = u16(pe + 20) else { return nil }
        let optional = pe + 24
        guard let magic = u16(optional), magic == 0x10B || magic == 0x20B else { return nil }
        is64Bit = magic == 0x20B
        let directories = optional + (is64Bit ? 112 : 96)
        let directoryCount = u32(directories - 4) ?? 0
        func directory(_ index: Int) -> Int {
            index < directoryCount ? (u32(directories + index * 8) ?? 0) : 0
        }
        importDirectory = directory(1)
        delayImportDirectory = directory(13)
        isDotNet = directory(14) != 0
        if is64Bit {
            imageBase = UInt64(u32(optional + 24) ?? 0) | UInt64(u32(optional + 28) ?? 0) << 32
        } else {
            imageBase = UInt64(u32(optional + 28) ?? 0)
        }

        var parsed: [(Int, Int, Int, Int)] = []
        let table = optional + optionalSize
        for index in 0..<min(sectionCount, 96) {
            let entry = table + index * 40
            guard let virtualSize = u32(entry + 8), let virtualAddress = u32(entry + 12),
                  let rawSize = u32(entry + 16), let rawOffset = u32(entry + 20) else { break }
            parsed.append((virtualAddress, virtualSize, rawOffset, rawSize))
        }
        sections = parsed
    }

    /// Lowercased names of DLLs in the import and delay-import tables.
    var importedLibraries: Set<String> {
        var names = Set<String>()
        // Regular imports: 20-byte descriptors, name RVA at +12, terminated by an all-zero entry.
        if importDirectory != 0, var entry = fileOffset(rva: importDirectory) {
            for _ in 0..<512 {
                guard let nameRVA = PEImage.read(data, entry + 12, 4),
                      let firstThunk = PEImage.read(data, entry + 16, 4), nameRVA != 0 || firstThunk != 0 else { break }
                if let name = string(rva: nameRVA) { names.insert(name) }
                entry += 20
            }
        }
        // Delay imports: 32-byte descriptors, name at +4 (an RVA, or a full address in very old files).
        if delayImportDirectory != 0, var entry = fileOffset(rva: delayImportDirectory) {
            for _ in 0..<512 {
                guard let attributes = PEImage.read(data, entry, 4), var nameRVA = PEImage.read(data, entry + 4, 4),
                      nameRVA != 0 else { break }
                if attributes & 1 == 0, UInt64(nameRVA) > imageBase { nameRVA -= Int(imageBase) }
                if let name = string(rva: nameRVA) { names.insert(name) }
                entry += 32
            }
        }
        return names
    }

    /// Every `something.dll` that appears as plain text in the first 96 MB of the file, lowercased.
    func libraryNamesInStrings() -> Set<String> {
        var names = Set<String>()
        data.prefix(96 << 20).withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let count = bytes.count
            guard count > 8 else { return }
            var index = 1
            while index + 3 < count {
                defer { index += 1 }
                guard bytes[index] == 0x2E,  // "."
                      bytes[index + 1] | 0x20 == 0x64, bytes[index + 2] | 0x20 == 0x6C, bytes[index + 3] | 0x20 == 0x6C
                else { continue }
                var start = index
                while start > 0, index - start < 32, PEImage.isNameByte(bytes[start - 1]) { start -= 1 }
                guard start < index else { continue }
                let stem = String(decoding: UnsafeRawBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self)
                names.insert(stem.lowercased() + ".dll")
            }
        }
        return names
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A) || byte == 0x5F || byte == 0x2D
    }

    private func fileOffset(rva: Int) -> Int? {
        for section in sections where rva >= section.virtualAddress
            && rva < section.virtualAddress + max(section.virtualSize, section.rawSize) {
            let offset = rva - section.virtualAddress
            return offset < section.rawSize ? section.rawOffset + offset : nil
        }
        return nil
    }

    private func string(rva: Int) -> String? {
        guard let start = fileOffset(rva: rva), start < data.count else { return nil }
        let slice = data[(data.startIndex + start)...].prefix(64)
        guard let end = slice.firstIndex(of: 0), end > slice.startIndex else { return nil }
        let name = String(decoding: slice[slice.startIndex..<end], as: UTF8.self).lowercased()
        return name.allSatisfy({ $0.isASCII && !$0.isWhitespace }) ? name : nil
    }

    private static func read(_ data: Data, _ offset: Int, _ width: Int) -> Int? {
        guard offset >= 0, offset + width <= data.count else { return nil }
        var value = 0
        for index in 0..<width {
            value |= Int(data[data.startIndex + offset + index]) << (8 * index)
        }
        return value
    }
}
