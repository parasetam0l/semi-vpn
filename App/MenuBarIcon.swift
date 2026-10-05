import AppKit

/// The menu bar icon: the app icon's shield with its two routes. Template
/// images, drawn as vectors on an 18-point canvas, so macOS colors them for
/// the menu bar and they stay sharp at any scale.
///
/// - Not connected: an outlined shield, the routes faint.
/// - Connecting: a bright stretch glides along each route, the two in
///   opposite ways (`connectingFrames`, played in a loop).
/// - Connected: a solid shield with the routes cut out.
enum MenuBarIcon {
    static let notConnected = image { drawShield(.off) }
    static let connected = image { drawShield(.on) }

    /// One loop of the connecting animation; show each for `frameDuration`.
    static let connectingFrames: [NSImage] = (0..<frameCount).map { frame in
        image { drawShield(.connecting(Double(frame) / Double(frameCount))) }
    }
    static let frameDuration: TimeInterval = 0.06
    private static let frameCount = 24

    private enum Look {
        case off, connecting(Double), on
    }

    private static func image(_ draw: @escaping () -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            draw()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "SemiVPN"
        return image
    }

    // MARK: Drawing (y up)

    private static func shield() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 9, y: 16.7))
        path.curve(to: NSPoint(x: 15.4, y: 14.4), controlPoint1: NSPoint(x: 11.3, y: 15.4), controlPoint2: NSPoint(x: 13.6, y: 14.7))
        path.line(to: NSPoint(x: 15.4, y: 9.4))
        path.curve(to: NSPoint(x: 9, y: 1.3), controlPoint1: NSPoint(x: 15.4, y: 5.4), controlPoint2: NSPoint(x: 12.6, y: 2.7))
        path.curve(to: NSPoint(x: 2.6, y: 9.4), controlPoint1: NSPoint(x: 5.4, y: 2.7), controlPoint2: NSPoint(x: 2.6, y: 5.4))
        path.line(to: NSPoint(x: 2.6, y: 14.4))
        path.curve(to: NSPoint(x: 9, y: 16.7), controlPoint1: NSPoint(x: 4.4, y: 14.7), controlPoint2: NSPoint(x: 6.7, y: 15.4))
        path.close()
        return path
    }

    /// The shield's inside, within its rim, where the routes run.
    private static func inside() -> NSBezierPath {
        let path = shield()
        var transform = AffineTransform(translationByX: -9, byY: -9.1)
        transform.append(AffineTransform(scale: 0.74))
        transform.append(AffineTransform(translationByX: 9, byY: 9))
        path.transform(using: transform)
        return path
    }

    /// An S-curve, like the app icon's routes.
    private static func route(_ offset: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 3.2, y: 9.2 + offset))
        path.curve(to: NSPoint(x: 14.8, y: 10.6 + offset),
                   controlPoint1: NSPoint(x: 7.4, y: 14.6 + offset), controlPoint2: NSPoint(x: 10.6, y: 5.2 + offset))
        path.lineCapStyle = .round
        return path
    }

    private static let routeOffsets: [CGFloat] = [1.4, -2.6]

    private static func drawShield(_ look: Look) {
        let outline = shield()
        let ink = NSColor.black
        switch look {
        case .off:
            ink.setStroke()
            outline.lineWidth = 1.6
            outline.stroke()
            withClip(inside()) {
                ink.withAlphaComponent(0.4).setStroke()
                for offset in routeOffsets {
                    let path = route(offset)
                    path.lineWidth = 1.4
                    path.stroke()
                }
            }
        case .connecting(let phase):
            ink.setStroke()
            outline.lineWidth = 1.6
            outline.stroke()
            withClip(inside()) {
                for (index, offset) in routeOffsets.enumerated() {
                    let faint = route(offset)
                    faint.lineWidth = 1.4
                    ink.withAlphaComponent(0.3).setStroke()
                    faint.stroke()
                    let bright = route(offset)
                    bright.lineWidth = 1.6
                    let progress = index == 0 ? phase : 1 - phase
                    bright.setLineDash([4, 12], count: 2, phase: CGFloat(-progress * 16))
                    ink.setStroke()
                    bright.stroke()
                }
            }
        case .on:
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            ink.setFill()
            outline.fill()
            context.setBlendMode(.clear)
            withClip(inside()) {
                for offset in routeOffsets {
                    let path = route(offset)
                    path.lineWidth = 1.4
                    path.stroke()
                }
            }
            context.endTransparencyLayer()
        }
    }

    private static func withClip(_ path: NSBezierPath, _ draw: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        draw()
        NSGraphicsContext.restoreGraphicsState()
    }
}
