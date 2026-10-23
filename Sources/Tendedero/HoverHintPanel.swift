import AppKit
import SwiftUI

/// A small pull cord under the menu bar. A clothespin climbs a rope toward a
/// short target line. Three elements only — rope, clip, target — and no text.
/// The cord hides at once when the pointer leaves or the line is woken.
///
/// It never takes a click and never becomes key: it is a sign, not a control.
@MainActor
final class HoverHintPanel: NSPanel {
    private let hosting: NSHostingView<HoverHintView>
    private var lastProgress = -1.0
    private var isShown = false

    init() {
        hosting = NSHostingView(rootView: HoverHintView(progress: 0))
        hosting.sizingOptions = []
        super.init(contentRect: NSRect(x: 0, y: 0, width: 40, height: 140),
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

    /// Let the cord climb into the menu bar if needed. The default window
    /// constraint would stop it at the menu bar's lower edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Shows or updates the cord. `progress` runs from 0 at the bottom of the
    /// hot zone to 1 at the top edge. The content is replaced on every change
    /// so the peg keeps up with the 30 Hz pointer timer in a non-activating
    /// panel.
    func show(on screen: NSScreen, progress: Double) {
        let clamped = min(1, max(0, progress))
        if abs(clamped - lastProgress) > 0.0005 {
            lastProgress = clamped
            hosting.rootView = HoverHintView(progress: clamped)
            hosting.needsDisplay = true
        }

        let size = NSSize(width: 40, height: 140)
        let bar = AppDelegate.menuBarBand(of: screen)
        let target = NSRect(x: screen.frame.midX - size.width / 2,
                            y: bar.minY - size.height - 6,
                            width: size.width, height: size.height)
        if frame != target { setFrame(target, display: true) }

        guard !isShown else { return }
        isShown = true
        // Set the alpha outright: a window animation can be skipped while the
        // app is an accessory, which would leave the cord invisible.
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
            .frame(width: 40, height: 140)
    }
}

/// The rope, the target line, and the climbing clothespin.
private struct PullCord: View {
    let progress: Double

    private var warm: Bool { progress > 0.85 }

    var body: some View {
        GeometryReader { geometry in
            let mid = geometry.size.width / 2
            let top: CGFloat = 14
            let bottom: CGFloat = 118
            let pegY = top + (bottom - top) * (1 - CGFloat(progress))

            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 2, height: bottom - top)
                    .position(x: mid, y: (top + bottom) / 2)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)

                Path { path in
                    path.move(to: CGPoint(x: mid, y: bottom))
                    path.addLine(to: CGPoint(x: mid, y: pegY))
                }
                .stroke(warm ? Color.orange : Color.accentColor,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))

                // The short line at the top is both the clothesline end and
                // the wake threshold.
                Capsule()
                    .fill(warm ? Color.orange : Color.primary.opacity(0.55))
                    .frame(width: 30, height: 2)
                    .position(x: mid, y: top)
                    .shadow(color: warm ? Color.orange.opacity(0.7) : .clear, radius: 3)

                ClothespinMarker(warm: warm)
                    .position(x: mid, y: pegY)
            }
        }
    }
}

/// A compact aluminium clip. No extra outline or handle: the slot is enough
/// to read it as a clothespin at this size.
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
