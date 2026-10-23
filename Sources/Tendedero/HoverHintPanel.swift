import AppKit
import SwiftUI

/// A small glass pill under the menu bar. It appears as soon as the pointer
/// rests at the top center, so the gesture has a visible affordance before
/// the line drops. The line itself still waits for the hover delay.
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

    /// Shows, repositions or updates the hint. Cheap to call from the 30 Hz
    /// pointer timer: the frame only changes when the screen or count does.
    func show(count: Int, on screen: NSScreen) {
        if count != shownCount {
            shownCount = count
            hosting.rootView = HoverHintView(count: count)
        }
        let size = NSSize(width: 280, height: 44)
        let bar = AppDelegate.menuBarBand(of: screen)
        let target = NSRect(x: screen.frame.midX - size.width / 2,
                            y: bar.minY - size.height - 6,
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
                Text(L("Pull down the line"))
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down")
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
