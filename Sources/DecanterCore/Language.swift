import Foundation

/// The language Windows runs in. Besides the wording of Wine's own dialogs, it decides the codepage
/// that older, non-Unicode programs use for text: a Russian game on an English Windows shows
/// `Çàïóñê` where it means `Запуск`.
public struct WindowsLanguage: Identifiable, Equatable, Sendable {
    /// Unix locale name, e.g. `ru_RU`. This is what is stored in a game's settings.
    public let locale: String
    public let name: String
    /// Windows ANSI codepage of the language.
    public let codepage: Int

    public var id: String { locale }

    public static let all: [WindowsLanguage] = [
        .init(locale: "en_US", name: "English", codepage: 1252),
        .init(locale: "ru_RU", name: "Russian", codepage: 1251),
        .init(locale: "uk_UA", name: "Ukrainian", codepage: 1251),
        .init(locale: "be_BY", name: "Belarusian", codepage: 1251),
        .init(locale: "bg_BG", name: "Bulgarian", codepage: 1251),
        .init(locale: "pl_PL", name: "Polish", codepage: 1250),
        .init(locale: "cs_CZ", name: "Czech", codepage: 1250),
        .init(locale: "sk_SK", name: "Slovak", codepage: 1250),
        .init(locale: "hu_HU", name: "Hungarian", codepage: 1250),
        .init(locale: "ro_RO", name: "Romanian", codepage: 1250),
        .init(locale: "el_GR", name: "Greek", codepage: 1253),
        .init(locale: "tr_TR", name: "Turkish", codepage: 1254),
        .init(locale: "ja_JP", name: "Japanese", codepage: 932),
        .init(locale: "ko_KR", name: "Korean", codepage: 949),
        .init(locale: "zh_CN", name: "Chinese (Simplified)", codepage: 936),
        .init(locale: "zh_TW", name: "Chinese (Traditional)", codepage: 950),
    ]

    /// What "Automatic" means on this Mac: the first of the user's languages that needs a codepage
    /// of its own. English text reads the same in every codepage, so a Mac set to English and
    /// Ukrainian gets Ukrainian. nil leaves the choice to Wine, which follows the Mac's region.
    public static func automatic(preferred: [String] = Locale.preferredLanguages) -> WindowsLanguage? {
        for identifier in preferred {
            let parts = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            guard let code = parts.first?.lowercased() else { continue }
            let match: WindowsLanguage?
            if code == "zh" {
                let traditional = parts.contains("Hant") || parts.contains("TW") || parts.contains("HK")
                match = all.first { $0.locale == (traditional ? "zh_TW" : "zh_CN") }
            } else {
                match = all.first { $0.locale.hasPrefix(code + "_") }
            }
            if let match, match.codepage != 1252 { return match }
        }
        return nil
    }

    /// The language for a game's `language` setting; empty means automatic.
    public static func resolve(_ setting: String, preferred: [String] = Locale.preferredLanguages) -> WindowsLanguage? {
        all.first { $0.locale == setting } ?? automatic(preferred: preferred)
    }

    /// Decodes text stored in this language's codepage; nil if the bytes don't fit it.
    func decode(_ bytes: [UInt8]) -> String? {
        let encoding = CFStringConvertWindowsCodepageToEncoding(UInt32(codepage))
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String(bytes: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding)))
    }

    /// Text from a non-Unicode Windows file: UTF-8 if it is, else the user's codepage, else Western.
    static func decodeANSI(_ bytes: [UInt8], preferred: [String] = Locale.preferredLanguages) -> String? {
        String(bytes: bytes, encoding: .utf8)
            ?? automatic(preferred: preferred)?.decode(bytes)
            ?? String(bytes: bytes, encoding: .windowsCP1252)
    }
}
