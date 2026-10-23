import AppKit
import SwiftUI

/// A small glass pill under the menu bar. It appears as soon as the pointer
/// rests at the top center, then follows the pointer upward toward the menu
/// bar. Its right edge carries a tiny clothesline: a clothespin climbs a rope
/// as the pointer climbs, so the wake threshold is visible as a shape before
/// the line appears.
///
/// It never takes a click and never becomes key: it is a sign, not a control.
@MainActor
final class HoverHintPanel: NSPanel {
    private let hosting: NSHostingView<HoverHintView>
    private var lastCount = -1
    private var lastProgress = -1.0
    private var isShown = false

    init() {
        hosting = NSHostingView(rootView: HoverHintView(count: 0, progress: 0))
        hosting.sizingOptions = []
        super.init(contentRect: NSRect(x: 0, y: 0, width: 308, height: 52),
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

    /// Let the pill climb into the menu bar. The default window constraint
    /// stops it at the menu bar's lower edge, which would hide the whole
    /// upward gesture.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Shows, repositions or updates the hint. `progress` runs from 0 at the
    /// bottom of the hot zone to 1 at the top edge, so the pill and its tiny
    /// clothespin rise with the pointer. Cheap to call from the 30 Hz timer.
    func show(count: Int, on screen: NSScreen, progress: Double) {
        let clamped = min(1, max(0, progress))
        // Replace the content rather than relying on an observed model: the
        // hint lives in a non-activating panel, and this is what keeps the
        // progress fill moving with every 30 Hz pointer update.
        if count != lastCount || abs(clamped - lastProgress) > 0.0005 {
            lastCount = count
            lastProgress = clamped
            hosting.rootView = HoverHintView(count: count, progress: clamped)
            hosting.needsDisplay = true
        }

        let size = NSSize(width: 308, height: 52)
        let bar = AppDelegate.menuBarBand(of: screen)
        // The last stretch lifts the pill toward the menu bar, as if it were
        // being pulled up to wake the line.
        let lift = CGFloat(clamped) * 16
        let target = NSRect(x: screen.frame.midX - size.width / 2,
                            y: bar.minY - size.height - 6 + lift,
                            width: size.width, height: size.height)
        if frame != target { setFrame(target, display: true) }

        guard !isShown else { return }
        isShown = true
        // Set the alpha outright: a window animation can be skipped while the
        // app is an accessory, which would leave the hint invisible.
        alphaValue = 1
        orderFrontRegardless()
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        // Hide at once: the hint is only up for a moment, and a fading
        // window that is already ordered out would just be extra state.
        alphaValue = 0
        orderOut(nil)
    }
}

private struct HoverHintView: View {
    let count: Int
    let progress: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tshirt")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if count == 0 {
                Text(L("Take a screenshot and it will hang here"))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                Text(String(format: L("%d on the line"), count))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text(L("Keep moving up to wake"))
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                PullGauge(progress: progress)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(width: 300, height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(
                LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.12)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        )
        .overlay(Capsule().stroke(.black.opacity(0.10), lineWidth: 0.5).padding(-0.5))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// A tiny vertical clothesline. The dim rope is the distance left; the
/// colored lower part is how far the pointer has climbed. The aluminium peg
/// is the progress marker, and the little cap at the top is the threshold it
/// has to reach before the line is woken.
private struct PullGauge: View {
    let progress: Double

    private var warm: Bool { progress > 0.85 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let mid = width / 2
            let inset: CGFloat = 4
            let pegY = inset + (height - inset * 2) * (1 - CGFloat(progress))

            ZStack {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 3, height: height - inset * 2)
                    .position(x: mid, y: height / 2)

                Path { path in
                    path.move(to: CGPoint(x: mid, y: height - inset))
                    path.addLine(to: CGPoint(x: mid, y: pegY))
                }
                .stroke(warm ? Color.orange : Color.accentColor,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))

                // The small cap at the top is the wake threshold.
                Capsule()
                    .fill(warm ? Color.orange : Color.primary.opacity(0.55))
                    .frame(width: 12, height: 2)
                    .position(x: mid, y: inset)
                    .shadow(color: warm ? Color.orange.opacity(0.65) : .clear, radius: 2)

                MiniClothespin(warm: warm)
                    .position(x: mid, y: pegY)
            }
        }
        .frame(width: 18, height: 32)
    }
}

private struct MiniClothespin: View {
    let warm: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.66)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 14, height: 7)
            .overlay(
                Capsule()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: 8, height: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .stroke(warm ? Color.orange : Color.black.opacity(0.25), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.28), radius: 1, y: 0.5)
    }
}
