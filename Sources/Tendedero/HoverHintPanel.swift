import AppKit
import SwiftUI

/// A small glass pill under the menu bar. It appears as soon as the pointer
/// rests at the top center, then slides upward toward the menu bar while the
/// hover delay runs. Reaching the top wakes the line; so does letting the
/// pill finish its climb. The upward motion is the affordance: keep pushing
/// up, and the line comes down.
///
/// It never takes a click and never becomes key: it is a sign, not a control.
@MainActor
final class HoverHintPanel: NSPanel {
    private let hosting: NSHostingView<HoverHintView>
    private var shownCount = -1
    private var isShown = false

    init() {
        hosting = NSHostingView(rootView: HoverHintView(count: 0))
        hosting.sizingOptions = []
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 44),
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

    /// Shows, repositions or updates the hint. `progress` runs from 0 to 1
    /// over the hover delay and lifts the pill toward the menu bar. Cheap to
    /// call from the 30 Hz pointer timer: the window just moves.
    func show(count: Int, on screen: NSScreen, progress: Double) {
        if count != shownCount {
            shownCount = count
            hosting.rootView = HoverHintView(count: count)
        }
        let size = NSSize(width: 280, height: 44)
        let bar = AppDelegate.menuBarBand(of: screen)
        // The last stretch lifts the pill into the menu bar, as if it were
        // being pulled up to wake the line.
        let lift = CGFloat(min(1, max(0, progress))) * 22
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
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 272, height: 36)
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
