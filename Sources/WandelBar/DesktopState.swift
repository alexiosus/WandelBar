import AppKit
import CoreGraphics

struct StoredDesktop: Codable, Sendable {
    var urlString: String
    var imageScaling: Int?
    var allowClipping: Bool?
    var fillColorData: Data?
    /// Stable identity from the wallpaper store. Unlike an exported Photos cache URL,
    /// this changes when the user selects a different source asset.
    var sourceIdentity: String?
    /// Filesystem path of the generated wallpaper currently applied for this entry, if any.
    var generatedPath: String?

    var url: URL? {
        URL(string: urlString)
    }

    var renderOptions: DesktopRenderOptions {
        DesktopRenderOptions(
            imageScaling: imageScaling.flatMap { NSImageScaling(rawValue: UInt($0)) } ?? .scaleProportionallyUpOrDown,
            allowClipping: allowClipping ?? true,
            fillColor: Self.unarchiveColor(from: fillColorData)
        )
    }

    var workspaceOptions: [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]

        if let imageScaling {
            options[.imageScaling] = imageScaling
        }

        if let allowClipping {
            options[.allowClipping] = allowClipping
        }

        if let fillColor = Self.unarchiveColor(from: fillColorData) {
            options[.fillColor] = fillColor
        }

        return options
    }

    static func capture(
        url: URL,
        options: DesktopOptionsSnapshot,
        sourceIdentity: WallpaperIdentity? = nil
    ) -> StoredDesktop {
        StoredDesktop(
            urlString: url.absoluteString,
            imageScaling: options.imageScaling,
            allowClipping: options.allowClipping,
            fillColorData: options.fillColorData,
            sourceIdentity: sourceIdentity?.stableIdentifier
        )
    }

    static func archiveColor(_ color: NSColor?) -> Data? {
        guard let color else { return nil }
        return try? NSKeyedArchiver.archivedData(withRootObject: color, requiringSecureCoding: true)
    }

    private static func unarchiveColor(from data: Data?) -> NSColor? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data)
    }
}

/// A `Sendable` snapshot of the AppKit desktop-image options, captured on the main
/// thread so wallpaper generation can run off the main thread.
struct DesktopOptionsSnapshot: Sendable {
    var imageScaling: Int?
    var allowClipping: Bool?
    var fillColorData: Data?

    init(options: [NSWorkspace.DesktopImageOptionKey: Any]) {
        imageScaling = (options[.imageScaling] as? NSNumber)?.intValue
        allowClipping = (options[.allowClipping] as? NSNumber)?.boolValue
        fillColorData = StoredDesktop.archiveColor(options[.fillColor] as? NSColor)
    }
}

struct DesktopRenderOptions {
    var imageScaling: NSImageScaling
    var allowClipping: Bool
    var fillColor: NSColor?
}

struct DisplaySnapshot: Sendable {
    var id: String
    var legacyID: String
    var uuid: String?
    var localizedName: String
    var frame: CGRect
    var visibleFrame: CGRect
    var backingScaleFactor: CGFloat
    var statusBarThickness: CGFloat

    var pixelSize: CGSize {
        CGSize(
            width: max(1, round(frame.width * backingScaleFactor)),
            height: max(1, round(frame.height * backingScaleFactor))
        )
    }

    var menuBarHeightPoints: CGFloat {
        let visibleTopInset = max(0, frame.maxY - visibleFrame.maxY)
        return max(visibleTopInset, statusBarThickness, 24)
    }

    init(screen: NSScreen) {
        id = screen.displayIdentifier
        legacyID = screen.legacyDisplayIdentifier
        uuid = screen.displayUUID
        localizedName = screen.localizedName
        frame = screen.frame
        visibleFrame = screen.visibleFrame
        backingScaleFactor = screen.backingScaleFactor
        statusBarThickness = NSStatusBar.system.thickness
    }

    init(
        id: String,
        legacyID: String? = nil,
        uuid: String? = nil,
        localizedName: String,
        frame: CGRect,
        visibleFrame: CGRect? = nil,
        backingScaleFactor: CGFloat,
        statusBarThickness: CGFloat
    ) {
        self.id = id
        self.legacyID = legacyID ?? id
        self.uuid = uuid
        self.localizedName = localizedName
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.backingScaleFactor = backingScaleFactor
        self.statusBarThickness = statusBarThickness
    }
}

extension NSScreen {
    var displayIdentifier: String {
        if let uuid = displayUUID {
            return uuid
        }

        return legacyDisplayIdentifier
    }

    var legacyDisplayIdentifier: String {
        if let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return String(number.uint32Value)
        }

        return "\(Int(frame.origin.x))x\(Int(frame.origin.y))-\(Int(frame.width))x\(Int(frame.height))"
    }

    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(number.uint32Value) else {
            return nil
        }

        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(nil, uuid) as String
    }
}
