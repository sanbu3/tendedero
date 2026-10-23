import AppKit
import SwiftUI

/// A miniature clothesline just under the menu bar, with a clothespin hanging
/// at its lowest point. Moving the pointer up pulls the little line taut; when
/// it is completely straight against the bar, the real line drops.
///
/// Only the rope, the clip, and the glow. No text, no target, no backing.
@MainActor
final class HoverHintPanel: NSPanel {
    /// A crisp two-times-resolution white arrow with a black edge: the
    /// cursor shown while the pull line is visible.
    static let pullCursor: NSCursor = {
        let points = NSSize(width: 20, height: 20)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 40,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return .arrow
        }
        rep.size = points
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let transform = NSAffineTransform()
        transform.scale(by: 2)
        transform.concat()

        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 10, y: 18))
        arrow.line(to: NSPoint(x: 17, y: 11))
        arrow.line(to: NSPoint(x: 13, y: 11))
        arrow.line(to: NSPoint(x: 13, y: 4))
        arrow.line(to: NSPoint(x: 7, y: 4))
        arrow.line(to: NSPoint(x: 7, y: 11))
        arrow.line(to: NSPoint(x: 3, y: 11))
        arrow.close()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        NSColor.white.setFill()
        arrow.fill()
        NSColor.black.withAlphaComponent(0.85).setStroke()
        arrow.lineWidth = 1.2
        arrow.stroke()

        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: points)
        image.addRepresentation(rep)
        return NSCursor(image: image, hotSpot: NSPoint(x: 10, y: 10))
    }()

    private let hosting: NSHostingView<HoverHintView>
    private var lastProgress = -1.0
    private var lastSnap = -1.0
    private var isShown = false

    init() {
        hosting = NSHostingView(rootView: HoverHintView(progress: 0, snap: 0))
        hosting.sizingOptions = []
        super.init(contentRect: NSRect(x: 0, y: 0, width: 88, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        contentView = hosting
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The little line hangs from the menu bar's lower edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Shows or updates the miniature line. `progress` runs from 0 at the
    /// bottom of the hot zone to 1 at the top edge; the sag disappears as the
    /// pointer climbs. The content is replaced on every change so the clip
    /// keeps up with the 30 Hz pointer timer in a non-activating panel.
    func show(on screen: NSScreen, progress: Double, snap: Double = 0) {
        let clamped = min(1, max(0, progress))
        let snapPhase = min(1, max(0, snap))
        if abs(clamped - lastProgress) > 0.0005 || abs(snapPhase - lastSnap) > 0.0005 {
            lastProgress = clamped
            lastSnap = snapPhase
            hosting.rootView = HoverHintView(progress: clamped, snap: snapPhase)
            hosting.needsDisplay = true
        }

        let size = NSSize(width: 88, height: 64)
        let bar = AppDelegate.menuBarBand(of: screen)
        let target = NSRect(x: screen.frame.midX - size.width / 2,
                            y: bar.minY - size.height,
                            width: size.width, height: size.height)
        if frame != target { setFrame(target, display: true) }

        guard !isShown else { return }
        isShown = true
        // Set the alpha outright: a window animation can be skipped while the
        // app is an accessory, which would leave the line invisible.
        alphaValue = 1
        orderFrontRegardless()
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        alphaValue = 0
        orderOut(nil)
    }
}

private struct HoverHintView: View {
    let progress: Double
    let snap: Double

    var body: some View {
        MiniLine(progress: progress, snap: snap)
            .frame(width: 88, height: 64)
    }
}

/// A tiny clothesline segment: two ends at the menu bar, a sagging rope, and a
/// clothespin at the lowest point. The sag is the remaining pull.
private struct MiniLine: View {
    let progress: Double
    let snap: Double

    private var warm: Bool { progress > 0.85 }

    /// The rope starts cool and turns warm as the sag disappears.
    private var glowColor: Color {
        Color(hue: 0.42 - 0.32 * progress, saturation: 0.8, brightness: 1)
    }

    private var glowAlpha: Double { 0.14 + 0.26 * progress }

    var body: some View {
        GeometryReader { geometry in
            let mid = geometry.size.width / 2
            let left: CGFloat = 12
            let right = geometry.size.width - 12
            let baseSag = CGFloat(1 - progress) * 34
            // A very short, decaying twang when the line snaps taut. It only
            // bows downward; the upward half is hidden by the menu bar.
            let twang = CGFloat(sin(snap * .pi * 3) * 4 * (1 - snap))
            let sag = max(0, baseSag + twang)
            let pin = CGPoint(x: mid, y: sag)
            let rope = Path { path in
                path.move(to: CGPoint(x: left, y: 0))
                path.addQuadCurve(to: CGPoint(x: right, y: 0),
                                  control: CGPoint(x: mid, y: sag * 2))
            }

            ZStack {
                // Soft light along the little rope.
                rope
                    .stroke(glowColor.opacity(glowAlpha),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .blur(radius: 4)

                // A dark edge keeps the rope readable over light tab bars.
                rope
                    .stroke(Color.black.opacity(0.22),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))

                rope
                    .stroke(glowColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                // Halo riding with the clip.
                Circle()
                    .fill(
                        RadialGradient(colors: [glowColor.opacity(0.5), glowColor.opacity(0)],
                                       center: .center, startRadius: 0, endRadius: 16)
                    )
                    .frame(width: CGFloat(26 + 8 * progress),
                           height: CGFloat(26 + 8 * progress))
                    .position(pin)
                    .blur(radius: 2)

                ClothespinMarker(warm: warm)
                    .position(pin)

                // The "snap": one warm ring and a small white flash at the
                // clip as the line goes taut.
                if snap > 0 {
                    let flash = max(0, sin(snap * .pi))
                    Circle()
                        .stroke(glowColor.opacity(flash), lineWidth: 1.5)
                        .frame(width: CGFloat(8 + 30 * snap),
                               height: CGFloat(8 + 30 * snap))
                        .position(pin)
                        .blur(radius: 1)
                    Circle()
                        .fill(Color.white.opacity(flash * 0.7))
                        .frame(width: CGFloat(6 + 10 * snap),
                               height: CGFloat(6 + 10 * snap))
                        .position(pin)
                        .blur(radius: 1)
                }
            }
        }
    }
}

/// A compact aluminium clip hanging at the sag. The slot is enough to read it
/// as a clothespin at this size.
private struct ClothespinMarker: View {
    let warm: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.62)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 26, height: 10)
            .overlay(
                Capsule()
                    .fill(Color.black.opacity(0.30))
                    .frame(width: 14, height: 0.9)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(warm ? Color.orange : Color.black.opacity(0.25), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.30), radius: 1.5, y: 0.8)
    }
}
