import CoreGraphics
import Foundation

/// Lowers the Mac's screen resolution while a game runs, so that a fixed-size window nearly fills
/// the screen. Old games only offer 4:3 resolutions, which a Mac's display has no modes for, so
/// their fullscreen can't work; this is the closest thing to it.
public enum DisplayFit {
    public struct Size: Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }

        /// Reads `1024x768`.
        public init?(_ text: String) {
            let parts = text.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
            self.init(width: parts[0], height: parts[1])
        }

        public var text: String { "\(width)x\(height)" }
    }

    /// Room the menu bar takes above the window, in points.
    static let menuBarHeight = 30

    /// The smallest screen resolution a window of this size still fits on, below the menu bar.
    static func bestMode(for window: Size, among modes: [Size]) -> Size? {
        modes.filter { $0.width >= window.width && $0.height >= window.height + menuBarHeight }
            .min { ($0.width * $0.height, $0.width) < ($1.width * $1.height, $1.width) }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var original: CGDisplayMode?

    private static func allModes() -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(CGMainDisplayID(), options) as? [CGDisplayMode] ?? [])
            .filter { $0.isUsableForDesktopGUI() }
    }

    /// Switches the main screen to the resolution that best fits `window` and returns it; nil when
    /// the screen is already the best fit or nothing fits. The switch belongs to this app: macOS
    /// undoes it by itself if the app quits or crashes before `restore()`.
    public static func apply(for window: Size) -> Size? {
        lock.lock()
        defer { lock.unlock() }
        guard let current = CGDisplayCopyDisplayMode(CGMainDisplayID()) else { return nil }
        let modes = allModes()
        guard let best = bestMode(for: window, among: modes.map { Size(width: $0.width, height: $0.height) }),
              best.width * best.height < current.width * current.height,
              // The sharpest (HiDPI) variant of that resolution.
              let mode = modes.filter({ $0.width == best.width && $0.height == best.height })
                .max(by: { $0.pixelWidth < $1.pixelWidth }),
              set(mode) else { return nil }
        if original == nil { original = current }
        return best
    }

    /// Puts the screen back the way `apply` found it.
    public static func restore() {
        lock.lock()
        defer { lock.unlock() }
        guard let mode = original else { return }
        original = nil
        _ = set(mode)
    }

    private static func set(_ mode: CGDisplayMode) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, CGMainDisplayID(), mode, nil)
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }
}
