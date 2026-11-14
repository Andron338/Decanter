import CoreGraphics
import CVirtualDisplay
import Foundation

/// Real fullscreen for games that ask for resolutions the Mac's screen doesn't have.
///
/// A Mac's display only offers its own sizes, so a game asking for 800x600 or 1024x768 is refused
/// and ends up in a small window. While a game runs, this puts a virtual screen that does have those
/// resolutions in charge and makes the real screen mirror it: the game switches resolution as it
/// would on a PC, and macOS scales the picture to the real screen, with black bars where the shape
/// differs.
@MainActor
public enum ScaledFullscreen {
    public struct Size: Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// The resolutions games of the last few decades pick from.
    static let classicModes: [Size] = [
        (640, 480), (800, 600), (1024, 768), (1152, 864), (1280, 720), (1280, 768), (1280, 800),
        (1280, 960), (1280, 1024), (1360, 768), (1366, 768), (1400, 1050), (1440, 900), (1600, 900),
        (1600, 1200), (1680, 1050), (1920, 1080), (1920, 1200), (2560, 1440), (2560, 1600),
    ].map { Size(width: $0.0, height: $0.1) }

    /// What the virtual screen offers. `desktop` comes first, which makes it the resolution the
    /// screen starts in: the Mac's desktop keeps its layout until the game picks its own. Nothing
    /// is larger than the real screen's `panel` of pixels, since that could only lose detail.
    static func modes(desktop: Size, panel: Size) -> [Size] {
        var result = [desktop]
        for mode in classicModes where mode.width <= panel.width && mode.height <= panel.height && !result.contains(mode) {
            result.append(mode)
        }
        return result
    }

    private static var display: CGVirtualDisplay?
    private static var mirrored: CGDirectDisplayID = kCGNullDirectDisplay
    private static var users = 0

    public static var isActive: Bool { display != nil }

    /// Takes over the main screen; each successful call needs one `end()`. False when the virtual
    /// screen can't be made, and then nothing has changed.
    public static func begin() async -> Bool {
        if display != nil {
            users += 1
            return true
        }
        let real = CGMainDisplayID()
        guard let current = CGDisplayCopyDisplayMode(real), current.width > 0, current.height > 0 else { return false }
        let offered = modes(desktop: Size(width: current.width, height: current.height),
                            panel: Size(width: current.pixelWidth, height: current.pixelHeight))

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.global(qos: .userInteractive)
        descriptor.name = "Decanter"
        descriptor.maxPixelsWide = UInt32(offered.map(\.width).max() ?? current.width)
        descriptor.maxPixelsHigh = UInt32(offered.map(\.height).max() ?? current.height)
        // The same physical size as the real screen, so nothing takes it for a different kind of display.
        descriptor.sizeInMillimeters = CGDisplayScreenSize(real)
        descriptor.vendorID = 0xDECA
        descriptor.productID = 1
        descriptor.serialNum = 1
        guard let virtual = CGVirtualDisplay(descriptor: descriptor) else { return false }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        let refresh = current.refreshRate > 0 ? current.refreshRate : 60
        settings.modes = offered.map {
            CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height), refreshRate: refresh)
        }
        guard virtual.apply(settings), await wait(until: { CGDisplayIsOnline(virtual.displayID) != 0 }) else { return false }

        // The real screen shows the virtual one, which makes the virtual one the main screen that
        // games see. Tied to this app: macOS undoes it if Decanter quits or crashes.
        // A new screen is refused as a mirror target for a moment after it comes online, until this
        // app has taken note of it, so the request is repeated until it is accepted.
        guard await wait(until: { configure { CGConfigureDisplayMirrorOfDisplay($0, real, virtual.displayID) } }),
              await wait(until: { CGMainDisplayID() == virtual.displayID }) else {
            _ = configure { CGConfigureDisplayMirrorOfDisplay($0, real, kCGNullDirectDisplay) }
            return false
        }
        display = virtual
        mirrored = real
        users = 1
        return true
    }

    /// Gives the screen back once the last game using it has quit.
    public static func end() {
        guard display != nil else { return }
        users -= 1
        guard users <= 0 else { return }
        _ = configure { CGConfigureDisplayMirrorOfDisplay($0, mirrored, kCGNullDirectDisplay) }
        // Letting go of the virtual screen removes it.
        display = nil
        mirrored = kCGNullDirectDisplay
        users = 0
    }

    private static func configure(_ change: (CGDisplayConfigRef?) -> CGError) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        guard change(config) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }

    /// Screens come and go a moment after they are asked to.
    private static func wait(until done: () -> Bool) async -> Bool {
        for _ in 0..<40 {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return done()
    }
}
