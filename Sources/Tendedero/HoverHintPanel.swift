import AppKit
import SwiftUI

/// A slim glass pull rail under the menu bar. A clothespin climbs the rope as
/// the pointer moves up; the little bar at the top is the wake threshold.
/// There is no text: the climbing peg and the chevrons at the bottom are the
/// instruction.
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: 64, height: 220),
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

    /// Let the rail climb into the menu bar if needed. The default window
    /// constraint would stop it at the menu bar's lower edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Shows or updates the rail. `progress` runs from 0 at the bottom of the
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

        let size = NSSize(width: 64, height: 220)
        let bar = AppDelegate.menuBarBand(of: screen)
        let target = NSRect(x: screen.frame.midX - size.width / 2,
                            y: bar.minY - size.height - 6,
                            width: size.width, height: size.height)
        if frame != target { setFrame(target, display: true) }

        guard !isShown else { return }
        isShown = true
        // Set the alpha outright: a window animation can be skipped while the
        // app is an accessory, which would leave the rail invisible.
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
        ZStack(alignment: .top) {
            // The slim glass rail the rope hangs in.
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 26, height: 186)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(
                            LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.12)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.75)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(.black.opacity(0.10), lineWidth: 0.5)
                        .padding(-0.5)
                )
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .offset(y: 12)

            PullRail(progress: progress)
                .frame(width: 44, height: 190)
                .offset(y: 10)

        }
        .frame(width: 64, height: 220)
    }
}

/// The rope, the big aluminium peg, and the threshold bar at the top.
private struct PullRail: View {
    let progress: Double

    private var warm: Bool { progress > 0.85 }

    var body: some View {
        GeometryReader { geometry in
            let mid = geometry.size.width / 2
            let top: CGFloat = 10
            let bottom: CGFloat = 180
            let pegY = top + (bottom - top) * (1 - CGFloat(progress))

            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 3, height: bottom - top)
                    .position(x: mid, y: (top + bottom) / 2)

                Path { path in
                    path.move(to: CGPoint(x: mid, y: bottom))
                    path.addLine(to: CGPoint(x: mid, y: pegY))
                }
                .stroke(warm ? Color.orange : Color.accentColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))

                // A dashed ghost clip at the top shows the target shape;
                // the real peg has to reach it.
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(Color.primary.opacity(0.22),
                            style: StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
                    .frame(width: 34, height: 14)
                    .position(x: mid, y: top)

                // The line end at the top is the wake threshold. It glows
                // warm just before the peg reaches it.
                Capsule()
                    .fill(warm ? Color.orange : Color.primary.opacity(0.55))
                    .frame(width: 44, height: 3)
                    .position(x: mid, y: top)
                    .shadow(color: warm ? Color.orange.opacity(0.65) : .clear, radius: 3)

                ClothespinMarker(warm: warm)
                    .position(x: mid, y: pegY)
            }
        }
        .frame(width: 44, height: 190)
    }
}

/// A big horizontal aluminium clip, gripping the rope.
private struct ClothespinMarker: View {
    let warm: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.63)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 34, height: 14)
            .overlay(
                Capsule()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: 18, height: 1.2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .stroke(warm ? Color.orange : Color.black.opacity(0.25), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.30), radius: 2, y: 1)
    }
}
