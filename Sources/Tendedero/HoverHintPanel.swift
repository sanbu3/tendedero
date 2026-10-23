import AppKit
import SwiftUI

/// A short tail of the clothesline, hanging from the menu bar edge. The
/// clothespin at its end is the handle: pulling the pointer up retracts the
/// tail into the bar, and when the tail is gone the line drops.
///
/// Only the rope, the clip, and the glow. No text, no target line, no backing.
@MainActor
final class HoverHintPanel: NSPanel {
    /// A crisp two-times-resolution white arrow with a black edge: the
    /// cursor shown while the pull cord is visible.
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
    private var isShown = false

    init() {
        hosting = NSHostingView(rootView: HoverHintView(progress: 0))
        hosting.sizingOptions = []
        super.init(contentRect: NSRect(x: 0, y: 0, width: 40, height: 130),
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

    /// The rail hangs from the menu bar's lower edge, so the window is allowed
    /// to sit right against it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Shows or updates the tail. `progress` runs from 0 at the bottom of the
    /// hot zone to 1 at the top edge: the rope gets shorter as it approaches
    /// the menu bar. The content is replaced on every change so the clip keeps
    /// up with the 30 Hz pointer timer in a non-activating panel.
    func show(on screen: NSScreen, progress: Double) {
        let clamped = min(1, max(0, progress))
        if abs(clamped - lastProgress) > 0.0005 {
            lastProgress = clamped
            hosting.rootView = HoverHintView(progress: clamped)
            hosting.needsDisplay = true
        }

        let size = NSSize(width: 40, height: 130)
        let bar = AppDelegate.menuBarBand(of: screen)
        let target = NSRect(x: screen.frame.midX - size.width / 2,
                            y: bar.minY - size.height,
                            width: size.width, height: size.height)
        if frame != target { setFrame(target, display: true) }

        guard !isShown else { return }
        isShown = true
        // Set the alpha outright: a window animation can be skipped while the
        // app is an accessory, which would leave the tail invisible.
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

    var body: some View {
        PullCord(progress: progress)
            .frame(width: 40, height: 130)
    }
}

/// The whole hint: a rope tail whose length is the remaining pull, the clip
/// at its end, and a glow that travels with the clip.
private struct PullCord: View {
    let progress: Double

    private var warm: Bool { progress > 0.85 }

    /// The rope starts cool and turns warm as it retracts.
    private var glowColor: Color {
        Color(hue: 0.42 - 0.32 * progress, saturation: 0.8, brightness: 1)
    }

    private var glowAlpha: Double { 0.14 + 0.26 * progress }

    var body: some View {
        GeometryReader { geometry in
            let mid = geometry.size.width / 2
            let maxRope: CGFloat = 112
            let pinY = maxRope * (1 - CGFloat(progress))
            let rope = Path { path in
                path.move(to: CGPoint(x: mid, y: 0))
                path.addLine(to: CGPoint(x: mid, y: pinY))
            }

            ZStack {
                // Soft light along the remaining tail.
                rope
                    .stroke(glowColor.opacity(glowAlpha),
                            style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .blur(radius: 4)

                // A dark edge keeps the tail readable over light tab bars.
                rope
                    .stroke(Color.black.opacity(0.22),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))

                rope
                    .stroke(glowColor,
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                // The halo that rides with the clip.
                Circle()
                    .fill(
                        RadialGradient(colors: [glowColor.opacity(0.5), glowColor.opacity(0)],
                                       center: .center, startRadius: 0, endRadius: 16)
                    )
                    .frame(width: CGFloat(26 + 8 * progress),
                           height: CGFloat(26 + 8 * progress))
                    .position(x: mid, y: pinY)
                    .blur(radius: 2)

                ClothespinMarker(warm: warm)
                    .position(x: mid, y: pinY)
            }
        }
    }
}

/// A compact aluminium clip at the tail's end. The slot is enough to read it
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
