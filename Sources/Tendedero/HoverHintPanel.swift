import AppKit
import SwiftUI

/// A small zipper hanging from the menu bar (or the notch). Pulling the pointer
/// up drags the slider up and the two rows of teeth part, opening a seam of
/// light; when the seam is fully open the real clothesline drops.
///
/// Only the zipper, its pull tab, and the glow. No text, no target line, no
/// backing.
@MainActor
final class HoverHintPanel: NSPanel {
    /// A crisp two-times-resolution white arrow with a black edge: the
    /// cursor shown while the zipper is visible.
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

    /// The notch is the gap between the two auxiliary top areas. Nil on a
    /// display without a notch; the zipper then falls back to the top center.
    static func notchWidth(of screen: NSScreen) -> CGFloat? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        let width = right.minX - left.maxX
        return width > 30 ? width : nil
    }

    private let hosting: NSHostingView<HoverHintView>
    private var lastProgress = -1.0
    private var lastSnap = -1.0
    private var lastHasNotch: Bool?
    private var isShown = false

    init() {
        hosting = NSHostingView(rootView: HoverHintView(progress: 0, snap: 0, hasNotch: false))
        hosting.sizingOptions = []
        super.init(contentRect: NSRect(x: 0, y: 0, width: 64, height: 150),
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

    /// The zipper hangs from the menu bar's lower edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Shows or updates the zipper. `progress` runs from 0 at the bottom of
    /// the hot zone to 1 at the top edge; the slider follows it upward while
    /// the teeth part. The content is replaced on every change so it keeps up
    /// with the 30 Hz pointer timer in a non-activating panel.
    func show(on screen: NSScreen, progress: Double, snap: Double = 0) {
        let clamped = min(1, max(0, progress))
        let snapPhase = min(1, max(0, snap))
        let hasNotch = Self.notchWidth(of: screen) != nil
        if abs(clamped - lastProgress) > 0.0015 || abs(snapPhase - lastSnap) > 0.0005
            || hasNotch != lastHasNotch {
            lastProgress = clamped
            lastSnap = snapPhase
            lastHasNotch = hasNotch
            hosting.rootView = HoverHintView(progress: clamped, snap: snapPhase, hasNotch: hasNotch)
            hosting.needsDisplay = true
        }

        let size = NSSize(width: 64, height: 150)
        let bar = AppDelegate.menuBarBand(of: screen)
        let target = NSRect(x: screen.frame.midX - size.width / 2,
                            y: bar.minY - size.height,
                            width: size.width, height: size.height)
        if frame != target { setFrame(target, display: true) }

        guard !isShown else { return }
        isShown = true
        // Set the alpha outright: a window animation can be skipped while the
        // app is an accessory, which would leave the zipper invisible.
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
    let hasNotch: Bool

    var body: some View {
        ZStack(alignment: .top) {
            if hasNotch {
                // A dark tab that blends into the notch above, so the zipper
                // appears to come out of the notch itself.
                Capsule()
                    .fill(Color.black.opacity(0.92))
                    .frame(width: 44, height: 6)
                    .overlay(
                        Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(y: -2)
            }

            ZipperHint(progress: progress, snap: snap)
                .frame(width: 64, height: 150)
        }
        .frame(width: 64, height: 150)
    }
}

/// The zipper itself: two strips, interlocking teeth, a slider, and a pull tab
/// that swings as the pointer pulls.
private struct ZipperHint: View {
    let progress: Double
    let snap: Double

    private var metal: LinearGradient {
        LinearGradient(colors: [Color(white: 0.97), Color(white: 0.6)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// Starts cool and turns warm as the seam opens.
    private var glowColor: Color {
        Color(hue: 0.42 - 0.32 * progress, saturation: 0.8, brightness: 1)
    }

    var body: some View {
        GeometryReader { geometry in
            let mid = geometry.size.width / 2
            let topY: CGFloat = 6
            let bottomY: CGFloat = 120
            let gapHalf: CGFloat = 9
            let open = CGFloat(min(1, max(0, progress)))
            let sliderY = topY + (1 - open) * (bottomY - topY)

            let leftStrip = Path { path in
                path.move(to: CGPoint(x: mid, y: topY))
                path.addLine(to: CGPoint(x: mid, y: sliderY))
                path.addLine(to: CGPoint(x: mid - gapHalf, y: bottomY))
            }
            let rightStrip = Path { path in
                path.move(to: CGPoint(x: mid, y: topY))
                path.addLine(to: CGPoint(x: mid, y: sliderY))
                path.addLine(to: CGPoint(x: mid + gapHalf, y: bottomY))
            }

            ZStack {
                // Light leaking through the opening seam.
                Path { path in
                    path.move(to: CGPoint(x: mid, y: sliderY))
                    path.addLine(to: CGPoint(x: mid - gapHalf, y: bottomY))
                    path.addLine(to: CGPoint(x: mid + gapHalf, y: bottomY))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(colors: [glowColor.opacity(0.28 * open),
                                            glowColor.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .blur(radius: 4)

                // The two fabric strips, with a dark edge for contrast.
                leftStrip.stroke(Color.black.opacity(0.22),
                                 style: StrokeStyle(lineWidth: 5, lineCap: .round))
                rightStrip.stroke(Color.black.opacity(0.22),
                                  style: StrokeStyle(lineWidth: 5, lineCap: .round))
                leftStrip.stroke(metal, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                rightStrip.stroke(metal, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

                // Neat, rounded interlocking teeth along the closed seam.
                ForEach(0..<max(0, Int((sliderY - topY) / 5)), id: \.self) { i in
                    let y = topY + CGFloat(i) * 5
                    let dx: CGFloat = i % 2 == 0 ? -1.5 : 1.5
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(metal)
                        .frame(width: 4.6, height: 2.4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 1, style: .continuous)
                                .stroke(Color.black.opacity(0.28), lineWidth: 0.4)
                        )
                        .position(x: mid + dx, y: y)
                }

                // Halo riding with the slider.
                Circle()
                    .fill(
                        RadialGradient(colors: [glowColor.opacity(0.5), glowColor.opacity(0)],
                                       center: .center, startRadius: 0, endRadius: 16)
                    )
                    .frame(width: CGFloat(36 + 12 * open), height: CGFloat(36 + 12 * open))
                    .position(x: mid, y: sliderY)
                    .blur(radius: 2)

                ZipperSlider(metal: metal)
                    .position(x: mid, y: sliderY)

                PullTab(metal: metal, angle: tabAngle)
                    .position(x: mid, y: sliderY + 9)

                // The snap flash at the slider.
                if snap > 0 {
                    let flash = max(0, sin(snap * .pi))
                    Circle()
                        .stroke(glowColor.opacity(flash), lineWidth: 1.5)
                        .frame(width: CGFloat(8 + 30 * snap), height: CGFloat(8 + 30 * snap))
                        .position(x: mid, y: sliderY)
                        .blur(radius: 1)
                    Circle()
                        .fill(Color.white.opacity(flash * 0.7))
                        .frame(width: CGFloat(6 + 10 * snap), height: CGFloat(6 + 10 * snap))
                        .position(x: mid, y: sliderY)
                        .blur(radius: 1)
                }
            }
        }
    }

    /// The pull tab trails the slider as it climbs and twangs on the snap.
    private var tabAngle: Double {
        8 * sin(Double(progress) * .pi)
            + sin(snap * .pi * 3) * 12 * (1 - snap)
    }
}

/// The metal slider that sits at the join of the two zipper halves.
private struct ZipperSlider: View {
    let metal: LinearGradient

    var body: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(metal)
            .frame(width: 15, height: 20)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.black.opacity(0.3), lineWidth: 0.6)
            )
            .overlay(
                Capsule()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: 9, height: 1)
                    .offset(y: -3)
            )
            .overlay(
                Capsule()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 9, height: 0.5)
                    .offset(y: -3.5)
            )
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

/// The small hanging tab with a ring hole. It swings around its top pivot.
private struct PullTab: View {
    let metal: LinearGradient
    let angle: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(metal)
                .frame(width: 6, height: 15)
                .overlay(
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .stroke(Color.black.opacity(0.3), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.8)

            Circle()
                .stroke(Color.black.opacity(0.45), lineWidth: 1)
                .frame(width: 4, height: 4)
                .offset(y: 5)
        }
        .frame(width: 8, height: 17)
        .rotationEffect(.degrees(angle), anchor: .top)
    }
}
