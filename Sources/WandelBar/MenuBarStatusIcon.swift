import AppKit

/// What the status item draws for a given controller state.
enum MenuBarStatusIconKind: Equatable {
    case off
    case active
    case unsupported
    case error
}

/// The menu bar icon is a small display outline with its top strip called out, which is
/// exactly the region WandelBar redraws. A drawn template image is used instead of an SF
/// Symbol because no symbol expresses "the band behind the menu bar".
@MainActor
enum MenuBarStatusIcon {
    static let size = NSSize(width: 18, height: 18)

    private static let offImage = makeImage(for: .off)
    private static let activeImage = makeImage(for: .active)
    private static let unsupportedImage = makeImage(for: .unsupported)
    private static let errorImage = makeImage(for: .error)

    static func kind(for state: WandelBarState) -> MenuBarStatusIconKind {
        switch state {
        case .error:
            return .error
        case .unsupported:
            return .unsupported
        case .active:
            return .active
        case .off:
            return .off
        }
    }

    static func image(for state: WandelBarState) -> NSImage {
        image(for: kind(for: state))
    }

    static func image(for kind: MenuBarStatusIconKind) -> NSImage {
        switch kind {
        case .off:
            return offImage
        case .active:
            return activeImage
        case .unsupported:
            return unsupportedImage
        case .error:
            return errorImage
        }
    }

    private static func makeImage(for kind: MenuBarStatusIconKind) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(kind)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(for: kind)
        return image
    }

    private static func accessibilityDescription(for kind: MenuBarStatusIconKind) -> String {
        switch kind {
        case .off:
            return "WandelBar off"
        case .active:
            return "WandelBar active"
        case .unsupported:
            return "WandelBar unsupported wallpaper"
        case .error:
            return "WandelBar error"
        }
    }

    // MARK: - Drawing

    /// The app icon's mark, reduced to a template glyph: the treated strip above, the
    /// WandelBar "W" below. State is carried by the strip, so the mark never changes.
    private static let barRect = NSRect(x: 1.2, y: 13.3, width: 15.6, height: 2.6)
    private static let markLineWidth: CGFloat = 2.6

    private static func draw(_ kind: MenuBarStatusIconKind) {
        NSColor.black.setFill()
        NSColor.black.setStroke()

        switch kind {
        case .off:
            strokeBar()
        case .active, .unsupported, .error:
            fillBar()
        }

        drawMark()

        switch kind {
        case .off, .active:
            break
        case .unsupported:
            drawSlash()
        case .error:
            drawWarningBadge()
        }
    }

    private static func fillBar() {
        NSBezierPath(roundedRect: barRect, xRadius: 1.25, yRadius: 1.25).fill()
    }

    private static func strokeBar() {
        let inset = barRect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: inset, xRadius: 0.9, yRadius: 0.9)
        path.lineWidth = 1.0
        path.stroke()
    }

    private static func drawMark() {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 1.9, y: 10.7))
        path.line(to: NSPoint(x: 5.4, y: 2.5))
        path.line(to: NSPoint(x: 9.0, y: 9.3))
        path.line(to: NSPoint(x: 12.6, y: 2.5))
        path.line(to: NSPoint(x: 16.1, y: 10.7))
        path.lineWidth = markLineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        path.stroke()
    }

    /// A diagonal cut across the whole glyph reads as "this wallpaper cannot be treated".
    private static func drawSlash() {
        let start = NSPoint(x: 1.2, y: 1.4)
        let end = NSPoint(x: 16.8, y: 16.6)

        strokeLine(from: start, to: end, width: markLineWidth + 1.7, clear: true)
        NSColor.black.setStroke()
        strokeLine(from: start, to: end, width: markLineWidth - 0.5, clear: false)
    }

    private static func drawWarningBadge() {
        let badge = NSRect(x: 11.6, y: 0.2, width: 6.2, height: 5.6)

        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: badge.insetBy(dx: -1.0, dy: -1.0)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.black.setFill()
        let triangle = NSBezierPath()
        triangle.move(to: NSPoint(x: badge.midX, y: badge.maxY))
        triangle.line(to: NSPoint(x: badge.maxX, y: badge.minY))
        triangle.line(to: NSPoint(x: badge.minX, y: badge.minY))
        triangle.close()
        triangle.lineJoinStyle = .round
        triangle.lineWidth = 1.2
        triangle.fill()
        triangle.stroke()
    }

    private static func strokeLine(
        from start: NSPoint,
        to end: NSPoint,
        width: CGFloat,
        clear: Bool
    ) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = width
        path.lineCapStyle = .round

        if clear {
            NSGraphicsContext.current?.compositingOperation = .clear
            path.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        } else {
            path.stroke()
        }
    }
}
