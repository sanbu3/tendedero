import AppKit
import Vision

/// A photo taken off the line to keep in front of you while you work: a
/// design to copy, numbers to type in, steps to follow. It is the photo
/// itself, not a copy: its clip waits empty on the line, and Hang back, or
/// Escape, sends it home.
///
/// It slides off its clip, down to the middle of the screen you are on, and
/// opens up as it lands, like a photo lifted from a real clothesline. Drag it
/// anywhere; stretch it from an edge or a corner, or pinch or scroll over it
/// to zoom. A double click hangs it back. Several can be held at once. It
/// never takes the app you are working in out of the front.
@MainActor
final class Held: NSObject {
    private static var open: [UUID: Held] = [:]

    let id: UUID
    private let panel: HeldPanel
    private let view: HeldView
    /// Its size at 100%, in points.
    private let natural: NSSize
    /// The frame-by-frame slide off the line, while it runs.
    private var slideTimer: Timer?
    private var animationStart: CFTimeInterval = 0
    /// Called with where it was on screen, to fly back to its clip from there.
    private let onHangBack: (UUID, CGRect) -> Void

    static var heldIDs: Set<UUID> { Set(open.keys) }

    /// `from` is where the card hangs on the line, so the photo can slide
    /// off it; without it, the photo simply opens in the middle.
    static func show(_ id: UUID, url: URL, line: Line, from: NSRect? = nil,
                     onHangBack: @escaping (UUID, CGRect) -> Void) {
        guard open[id] == nil,
              let screen = LinePanel.screenUnderPointer() else { return }
        // No sharper than the screen can show, so a huge image stays light.
        let longest = max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor
        guard let image = makeThumbnail(url, maxPixels: Int(longest)), image.size.width > 0 else { return }
        open[id] = Held(id: id, url: url, image: image, on: screen, line: line,
                        from: from, onHangBack: onHangBack)
    }

    static func hangBack(_ id: UUID) { open[id]?.hangBack() }

    static func hangEverythingBack() {
        for held in open.values { held.hangBack() }
    }

    /// Its photo left the line some other way: the file moved, for example.
    static func forget(except live: Set<UUID>) {
        for (id, held) in open where !live.contains(id) {
            held.slideTimer?.invalidate()
            held.slideTimer = nil
            held.panel.close()
            open[id] = nil
        }
    }

    private init(id: UUID, url: URL, image: NSImage, on screen: NSScreen, line: Line,
                 from: NSRect?, onHangBack: @escaping (UUID, CGRect) -> Void) {
        self.id = id
        self.onHangBack = onHangBack
        let scale = screen.backingScaleFactor
        natural = NSSize(width: image.size.width / scale + HeldView.border * 2,
                         height: image.size.height / scale + HeldView.border * 2)
        view = HeldView(image: image)
        panel = HeldPanel(content: view)
        super.init()
        view.onHangBack = { [weak self] in self?.hangBack() }
        view.onZoom = { [weak self] factor, anchor in self?.zoom(by: factor, around: anchor) }
        view.onActualSize = { [weak self] in self?.actualSize() }
        view.onCopy = { line.copy(id) }
        view.onMarkup = { line.markup(id) }
        view.onQuickLook = { line.quickLook(id) }
        // Stretched from an edge or a corner, it keeps the photo's shape.
        panel.minSize = NSSize(width: 80, height: 80)
        let target = startFrame(on: screen)
        panel.setFrame(from ?? target, display: false)
        panel.orderFrontRegardless()
        // Holding it means it takes the keys: Escape and ⌘C work at once, and
        // the first drag is a drag, not the click that makes it key.
        panel.makeKey()
        panel.makeFirstResponder(view)
        if let from {
            slideIn(from: from, to: target)
        } else {
            panel.contentAspectRatio = natural
        }
    }

    /// Off the line: it falls away from its clip and opens up into the
    /// middle of the screen, the two as one motion. The fall starts at once
    /// and the opening joins it a beat later, so there is no seam where one
    /// animation stops and the next begins. The card behind it fades to a
    /// trace, so it looks like the photo that left the clip.
    private func slideIn(from start: NSRect, to end: NSRect) {
        animationStart = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated { self?.stepSlide(from: start, to: end, timer: timer) }
        }
        RunLoop.main.add(timer, forMode: .common)
        slideTimer = timer
    }

    private func stepSlide(from start: NSRect, to end: NSRect, timer: Timer) {
        let t = min(1, CGFloat((CACurrentMediaTime() - animationStart) / Self.slideDuration))
        // The fall leads; the opening catches up and settles with a small
        // overshoot, like a photo coming loose and opening in the hand.
        let fall = Self.easeOutCubic(min(1, t / Self.fallShare))
        let open = Self.easeOutBack(max(0, (t - Self.openDelay) / (1 - Self.openDelay)), overshoot: 0.7)
        // It hangs from its top edge, so it grows out of the point it left.
        let anchorX = start.midX + (end.midX - start.midX) * fall
        let anchorTop = start.maxY + (end.maxY - start.maxY) * fall
        let w = start.width + (end.width - start.width) * open
        let h = start.height + (end.height - start.height) * open
        panel.setFrame(NSRect(x: anchorX - w / 2, y: anchorTop - h, width: w, height: h), display: true)
        guard t >= 1 else { return }
        timer.invalidate()
        slideTimer = nil
        panel.setFrame(end, display: true)
        // While it was opening, the frame had a shape of its own.
        panel.contentAspectRatio = natural
    }

    private static let slideDuration: TimeInterval = 0.46
    /// How much of it the fall takes on its own, and when the opening starts.
    private static let fallShare: CGFloat = 0.82
    private static let openDelay: CGFloat = 0.16

    private static func easeOutCubic(_ t: CGFloat) -> CGFloat {
        1 - pow(1 - t, 3)
    }

    /// Eases out with a small overshoot: the size passes the mark and settles.
    private static func easeOutBack(_ t: CGFloat, overshoot: CGFloat) -> CGFloat {
        let c = 1 + overshoot
        let u = t - 1
        return 1 + c * u * u * u + overshoot * u * u
    }

    /// In the middle of the screen, each new one a little lower and to the
    /// right so none hides another. Never bigger than most of the screen.
    private func startFrame(on screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame
        let fit = min(1, area.width * 0.7 / natural.width, area.height * 0.7 / natural.height)
        let w = natural.width * fit, h = natural.height * fit
        let step = CGFloat((Self.open.count) % 8) * 24
        return NSRect(x: area.midX - w / 2 + step, y: area.midY - h / 2 - step, width: w, height: h)
    }

    /// Zooms keeping the point under the pointer where it is.
    private func zoom(by factor: CGFloat, around anchor: NSPoint) {
        let frame = panel.frame
        let scale = min(max(frame.width * factor / natural.width, 0.1), 4)
        let w = natural.width * scale, h = natural.height * scale
        guard w >= 60, h >= 60 else { return }
        let fx = (anchor.x - frame.minX) / frame.width, fy = (anchor.y - frame.minY) / frame.height
        panel.setFrame(NSRect(x: anchor.x - w * fx, y: anchor.y - h * fy, width: w, height: h), display: true)
    }

    private func actualSize() {
        let frame = panel.frame
        panel.setFrame(NSRect(x: frame.midX - natural.width / 2, y: frame.midY - natural.height / 2,
                              width: natural.width, height: natural.height), display: true)
    }

    private func hangBack() {
        slideTimer?.invalidate()
        slideTimer = nil
        let frame = panel.frame
        panel.close()
        Self.open[id] = nil
        onHangBack(id, frame)
    }
}

/// Floats over every app and Space, under the line so it never covers it.
/// A click makes it key without bringing Tendedero to the front, so the app
/// you work in stays active; it then takes Escape and ⌘C.
private final class HeldPanel: NSPanel {
    init(content: NSView) {
        // Resizable from its edges and corners, like any window.
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // A click must reach the view the first time. Moving is done by the
        // view, on a plain drag, once it knows the click is not a text pick.
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = false
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The photo in a glass frame like the cards on the line. Dragging moves it;
/// Command held, a drag picks out the text in the picture and copies it;
/// scrolling up hands it back to the line. Its corner button, shown on
/// hover like the cards' own, hangs it back too, and everything else is in
/// its menu.
private final class HeldView: NSVisualEffectView {
    static let border: CGFloat = 6

    var onHangBack: () -> Void = {}
    var onZoom: (CGFloat, NSPoint) -> Void = { _, _ in }
    var onActualSize: () -> Void = {}
    var onCopy: () -> Void = {}
    var onMarkup: () -> Void = {}
    var onQuickLook: () -> Void = {}

    private let image: NSImage
    private let photo = CALayer()
    private let hangBackButton = CornerButton(symbol: "arrow.up.to.line")
    /// The rectangle a Command-drag is picking out, and where it began.
    private let selection = CAShapeLayer()
    private var selectingFrom: NSPoint?
    private var hangBackPull: CGFloat = 0
    private var hangBackAt = Date.distantPast

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        photo.contents = image
        photo.contentsGravity = .resizeAspect
        photo.cornerRadius = 7
        photo.masksToBounds = true
        layer?.addSublayer(photo)
        // The picking-out of text, over the photo.
        selection.fillColor = NSColor.white.withAlphaComponent(0.16).cgColor
        selection.strokeColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        selection.lineWidth = 1
        selection.lineDashPattern = [4, 3]
        selection.isHidden = true
        layer?.addSublayer(selection)
        hangBackButton.alphaValue = 0
        hangBackButton.onPress = { [weak self] in self?.onHangBack() }
        hangBackButton.setAccessibilityLabel(L("Hang back"))
        addSubview(hangBackButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.frame = bounds.insetBy(dx: Self.border, dy: Self.border)
        photo.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        hangBackButton.frame = NSRect(x: 9, y: bounds.height - 29, width: 20, height: 20)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { showButton(true) }
    override func mouseExited(with event: NSEvent) { showButton(false) }

    private func showButton(_ on: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            hangBackButton.animator().alphaValue = on ? 1 : 0
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // A double click hands it back; with Option held, it is copied first.
        if event.clickCount == 2 {
            if event.modifierFlags.contains(.option) { onCopy() }
            onHangBack()
            return
        }
        // Command and a drag pick out the text in the picture, like Live Text.
        if event.modifierFlags.contains(.command) {
            window?.makeKey()
            window?.makeFirstResponder(self)
            selectingFrom = point
            showSelection(from: point, to: point)
            return
        }
        // Option on its own does nothing, so an Option double click stays put.
        if event.modifierFlags.contains(.option) { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        window?.performDrag(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = selectingFrom else { return }
        showSelection(from: start, to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = selectingFrom else { return }
        selectingFrom = nil
        let end = convert(event.locationInWindow, from: nil)
        showSelection(from: start, to: NSPoint(x: start.x, y: start.y))
        let rect = Self.rect(from: start, to: end).intersection(photo.frame)
        guard rect.width >= 4, rect.height >= 4 else { return }
        copyText(in: rect)
    }

    override func magnify(with event: NSEvent) {
        guard let window else { return }
        onZoom(1 + event.magnification, NSEvent.mouseLocation.clamped(to: window.frame))
    }

    /// Command and the wheel zoom, keeping the point under the pointer. A
    /// plain scroll up hands the photo back to the line; down does nothing,
    /// so brushing the wheel does not zoom or send it away.
    override func scrollWheel(with event: NSEvent) {
        guard let window, event.scrollingDeltaY != 0 else { return }
        // The device's own direction, whichever way Natural Scrolling is set.
        let device = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        if event.modifierFlags.contains(.command) {
            let step = event.hasPreciseScrollingDeltas ? device * 0.005 : device * 0.05
            onZoom(1 + step, NSEvent.mouseLocation.clamped(to: window.frame))
            return
        }
        guard device > 0 else {
            hangBackPull = 0
            return
        }
        let now = Date()
        if now.timeIntervalSince(hangBackAt) > 0.5 { hangBackPull = 0 }
        hangBackAt = now
        hangBackPull += device
        guard hangBackPull >= 14 else { return }
        hangBackPull = 0
        onHangBack()
    }

    private func showSelection(from start: NSPoint, to end: NSPoint) {
        let rect = Self.rect(from: start, to: end)
        selection.path = CGPath(rect: rect, transform: nil)
        selection.isHidden = rect.width < 1 && rect.height < 1
    }

    private static func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The part of the picture that was picked out, read with Vision and put
    /// on the clipboard as plain text.
    private func copyText(in rect: NSRect) {
        let frame = photo.frame
        guard frame.width > 0, frame.height > 0,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        // The photo is drawn to fit its frame, so the picture inside it may
        // be letterboxed by a few points.
        let scale = min(frame.width / w, frame.height / h)
        let shown = NSRect(x: frame.midX - w * scale / 2, y: frame.midY - h * scale / 2,
                           width: w * scale, height: h * scale)
        let crop = CGRect(x: (rect.minX - shown.minX) / shown.width * w,
                          y: (1 - (rect.maxY - shown.minY) / shown.height) * h,
                          width: rect.width / shown.width * w,
                          height: rect.height / shown.height * h).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard crop.width >= 1, crop.height >= 1, let part = cg.cropping(to: crop) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let text = Self.text(in: part)
            DispatchQueue.main.async {
                guard let self else { return }
                guard !text.isEmpty else {
                    self.flash(L("No text"))
                    NSSound.beep()
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
                self.flash(L("Copied"))
            }
        }
    }

    /// All the text Vision finds in the part, top to bottom.
    private static func text(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        let lines = (request.results ?? [])
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    /// A small word over the photo, for a moment: what just happened.
    private func flash(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()
        let pad: CGFloat = 9
        let box = NSVisualEffectView(frame: NSRect(x: bounds.midX - (label.frame.width + pad * 2) / 2,
                                                  y: bounds.midY - label.frame.height / 2 - pad,
                                                  width: label.frame.width + pad * 2,
                                                  height: label.frame.height + pad * 1.6))
        box.material = .hudWindow
        box.blendingMode = .withinWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 8
        label.frame.origin = NSPoint(x: pad, y: pad * 0.8)
        box.addSubview(label)
        box.alphaValue = 0
        addSubview(box)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            box.animator().alphaValue = 1
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    box.animator().alphaValue = 0
                }, completionHandler: { box.removeFromSuperview() })
            }
        })
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onHangBack()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            onCopy()
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(L("Hang back")) { [weak self] in self?.onHangBack() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Copy")) { [weak self] in self?.onCopy() })
        menu.addItem(ClosureMenuItem(L("Quick Look")) { [weak self] in self?.onQuickLook() })
        menu.addItem(ClosureMenuItem(L("Markup")) { [weak self] in self?.onMarkup() })
        menu.addItem(ClosureMenuItem(L("Actual Size")) { [weak self] in self?.onActualSize() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// A small glass disc with a symbol, as on the line's cards.
private final class CornerButton: NSVisualEffectView {
    var onPress: () -> Void = {}

    init(symbol: String) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.5).cgColor
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 8, weight: .bold)
        icon.contentTintColor = .labelColor
        icon.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The whole disc takes the click, symbol included.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
    }
}

private extension NSPoint {
    func clamped(to rect: NSRect) -> NSPoint {
        NSPoint(x: min(max(x, rect.minX), rect.maxX), y: min(max(y, rect.minY), rect.maxY))
    }
}
