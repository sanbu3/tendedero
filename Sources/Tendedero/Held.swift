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
    /// The file itself: the small form hands it to other apps, and copies it.
    private let url: URL
    /// What it shows, kept so the flight back to the line can start at once.
    private let image: NSImage
    /// The size it had before it went small, to come back to.
    private var fullFrame: NSRect?
    /// The system drag of the file, while it lasts.
    private var dragSource: FileDragSource?
    /// Its size at 100%, in points.
    private let natural: NSSize
    /// The frame-by-frame slide off the line, while it runs.
    private var slideTimer: Timer?
    private var animationStart: CFTimeInterval = 0
    /// One hand back at a time: the wheel can send a burst.
    private var isHangingBack = false
    /// Called with where it was on screen and what it showed, to fly back to
    /// its clip from there.
    private let onHangBack: (UUID, CGRect, NSImage) -> Void

    static var heldIDs: Set<UUID> { Set(open.keys) }

    /// How long the button must be held before the photo becomes its file.
    /// Two seconds by default; the menu bar changes it.
    static var holdDelay: TimeInterval {
        get {
            let saved = UserDefaults.standard.double(forKey: "holdDelay")
            return saved > 0 ? saved : 1.2
        }
        set { UserDefaults.standard.set(newValue, forKey: "holdDelay") }
    }

    static let holdChoices: [TimeInterval] = [0.8, 1.2, 1.8]

    /// `from` is where the card hangs on the line, so the photo can slide
    /// off it; without it, the photo simply opens in the middle.
    static func show(_ id: UUID, url: URL, line: Line, from: NSRect? = nil,
                     onHangBack: @escaping (UUID, CGRect, NSImage) -> Void) {
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
            held.close()
            open[id] = nil
        }
    }

    private init(id: UUID, url: URL, image: NSImage, on screen: NSScreen, line: Line,
                 from: NSRect?, onHangBack: @escaping (UUID, CGRect, NSImage) -> Void) {
        self.id = id
        self.url = url
        self.image = image
        self.onHangBack = onHangBack
        let scale = screen.backingScaleFactor
        natural = NSSize(width: image.size.width / scale + HeldView.border * 2,
                         height: image.size.height / scale + HeldView.border * 2)
        view = HeldView(image: image, url: url)
        panel = HeldPanel(content: view)
        super.init()
        view.onHangBack = { [weak self] in self?.hangBack() }
        view.onZoom = { [weak self] factor, anchor in self?.zoom(by: factor, around: anchor) }
        view.onActualSize = { [weak self] in self?.actualSize() }
        view.onCopy = { line.copy(id) }
        view.onMarkup = { line.markup(id) }
        view.onQuickLook = { line.quickLook(id) }
        view.onRelease = { [weak self] in self?.releasePage() }
        view.onLongPress = { [weak self, weak view] event in
            guard let self, let view else { return }
            self.shrinkToIcon(event: event, from: view)
        }
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

    private static let slideDuration: TimeInterval = 0.24
    /// How much of it the fall takes on its own, and when the opening starts.
    private static let fallShare: CGFloat = 0.82
    private static let openDelay: CGFloat = 0.1

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

    /// Held down, it turns into the file itself: the photo, whole and in
    /// proportion, on a small page. The pointer holds it by its bottom right
    /// corner, the way a file comes out of the Finder, and it goes where the
    /// hand takes it. Letting go brings the photo back.
    private func shrinkToIcon(event: NSEvent, from view: HeldView) {
        guard fullFrame == nil else { return }
        guard let icon = Self.fileIcon(image) else { return }
        fullFrame = panel.frame
        let cursor = NSEvent.mouseLocation
        let inset: CGFloat = 18
        let target = NSRect(x: cursor.x - icon.size.width + inset,
                            y: cursor.y - inset,
                            width: icon.size.width, height: icon.size.height)
        panel.contentAspectRatio = .zero
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // The animator can land a point or two off; the page is exactly
            // where the hand expects it.
            panel.setFrame(target, display: false)
            view.showPage(icon)
            view.beginPageDrag()
            self.startFileDrag(icon: icon, event: event, from: view)
        })
    }

    /// The picture with a white border: what an image file looks like in the
    /// Finder. The page takes the picture's own shape, so nothing is cropped
    /// and nothing is stretched.
    private static func fileIcon(_ image: NSImage) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let border: CGFloat = 5
        let longest: CGFloat = 108
        let scale = longest / max(size.width, size.height)
        let inner = NSSize(width: max(24, size.width * scale), height: max(24, size.height * scale))
        let page = NSSize(width: inner.width + border * 2, height: inner.height + border * 2)
        let icon = NSImage(size: page)
        icon.lockFocus()
        defer { icon.unlockFocus() }
        let rect = NSRect(origin: .zero, size: page)
        let pagePath = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.white.setFill()
        pagePath.fill()
        let photo = rect.insetBy(dx: border, dy: border)
        let photoPath = NSBezierPath(roundedRect: photo, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        photoPath.addClip()
        image.draw(in: photo, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.2).setStroke()
        photoPath.lineWidth = 0.5
        photoPath.stroke()
        NSColor.black.withAlphaComponent(0.12).setStroke()
        pagePath.lineWidth = 1
        pagePath.stroke()
        return icon
    }

    /// Hands the page to the system as a file drag: other apps light up as
    /// drop targets, and the file lands where it is let go. Our window steps
    /// aside while the drag image carries the same page.
    private func startFileDrag(icon: NSImage, event: NSEvent, from view: HeldView) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            releasePage()
            return
        }
        let source = FileDragSource(url: url) { [weak self] operation in self?.endFileDrag(operation) }
        dragSource = source
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(origin: .zero, size: icon.size), contents: icon)
        // Anchored on the pointer as it is now, not on where the button went
        // down on the big photo: otherwise the page trails far behind.
        let inWindow = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let anchor = NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow,
                                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: panel.windowNumber, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1) ?? event
        let session = view.beginDraggingSession(with: [item], event: anchor, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = false
        // The drag image carries the page now; the window steps aside without
        // leaving the screen, which would cancel the drag with it.
        panel.alphaValue = 0
    }

    /// Dropped somewhere: the photo has been shared, so it goes back to the
    /// line, as if it had been dragged off it. Dropped nowhere: it is still
    /// in the hand, and the photo comes back as it was.
    private func endFileDrag(_ operation: NSDragOperation) {
        dragSource = nil
        guard fullFrame != nil else { return }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if operation != [] {
            fullFrame = nil
            hangBack()
        } else {
            releasePage()
        }
    }

    /// Let go: the photo is back, the size it was.
    private func releasePage() {
        guard let full = fullFrame else { return }
        fullFrame = nil
        view.hidePage()
        panel.contentAspectRatio = natural
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(full, display: true)
        }
    }

    /// Hands it to the flight: the window stays until the app says the photo
    /// is flying, so there is no blink between the two.
    private func hangBack() {
        guard !isHangingBack else { return }
        isHangingBack = true
        slideTimer?.invalidate()
        slideTimer = nil
        onHangBack(id, panel.frame, image)
    }

    /// The flight is drawing the photo now: the window can go.
    fileprivate func close() {
        slideTimer?.invalidate()
        slideTimer = nil
        panel.close()
    }

    static func letGo(_ id: UUID) {
        open[id]?.close()
        open[id] = nil
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
/// the button at the top left reads the text in the picture, and while it is
/// on, a drag across the text picks it out for ⌘C. Keys: C copies the photo
/// and leaves it in hand, ⌘C copies what was picked, Escape puts the pick
/// down and then hangs the photo back. A double click hangs it back, and
/// holding the button down for a moment turns it into the file itself.
private final class HeldView: NSVisualEffectView {
    static let border: CGFloat = 6

    var onHangBack: () -> Void = {}
    var onLongPress: (NSEvent) -> Void = { _ in }
    /// The button came up, whatever it was doing.
    var onRelease: () -> Void = {}
    var onZoom: (CGFloat, NSPoint) -> Void = { _, _ in }
    var onActualSize: () -> Void = {}
    var onCopy: () -> Void = {}
    var onMarkup: () -> Void = {}
    var onQuickLook: () -> Void = {}

    private let image: NSImage
    private let url: URL
    private let photo = CALayer()
    /// The small page the photo turns into while it is carried.
    private let page = CALayer()
    private var pageMode = false
    private var pageStart: NSPoint?
    private var pageOrigin: NSPoint?
    private let hangBackButton = CornerButton(symbol: "arrow.up.to.line")
    private let textButton = CornerButton(symbol: "text.viewfinder")
    /// The text read from the picture, and the two lights over it: everything
    /// that can be picked, and what is picked. Off until the button is used.
    private var text: PhotoText?
    private var readingText = false
    private var textOn = false
    private let standing = CAShapeLayer()
    private let pickLayer = CAShapeLayer()
    private var pickingFrom: NSPoint?
    private var pickingTo: NSPoint?
    /// What the pick holds, ready for ⌘C, and the boxes to draw over it.
    private var picked = ""
    private var pickedBoxes: [CGRect] = []
    /// Holding the button down turns the photo into its file.
    private let holdRing = CAShapeLayer()
    private var holdTimer: Timer?
    private var ringTimer: Timer?
    private var pressEvent: NSEvent?
    private var pressAt: NSPoint?
    private var pressScreen: NSPoint?
    private var pressOrigin: NSPoint?
    private var moving = false
    private var copyKeyDown = false
    private var hangBackPull: CGFloat = 0
    private var hangBackAt = Date.distantPast

    init(image: NSImage, url: URL) {
        self.image = image
        self.url = url
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
        page.isHidden = true
        layer?.addSublayer(page)
        // Everything the picture has to offer, and what is picked of it.
        for light in [standing, pickLayer] {
            light.isHidden = true
            light.fillColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
            layer?.addSublayer(light)
        }
        pickLayer.fillColor = NSColor.systemBlue.withAlphaComponent(0.30).cgColor
        // The ring that fills while the button is held down.
        holdRing.isHidden = true
        holdRing.fillColor = nil
        holdRing.actions = ["path": NSNull(), "strokeEnd": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        holdRing.strokeColor = NSColor.controlAccentColor.cgColor
        holdRing.lineWidth = 2.5
        holdRing.lineCap = .round
        layer?.addSublayer(holdRing)
        textButton.isOn = false
        textButton.onPress = { [weak self] in self?.toggleText() }
        textButton.setAccessibilityLabel(L("Read the text"))
        addSubview(textButton)
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
        textButton.frame = NSRect(x: 9, y: bounds.height - 29, width: 20, height: 20)
        hangBackButton.frame = NSRect(x: bounds.width - 29, y: bounds.height - 29, width: 20, height: 20)
        if pageMode {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            page.frame = bounds
            page.contentsScale = window?.backingScaleFactor ?? 2
            CATransaction.commit()
            return
        }
        // The lights follow the picture as the window is stretched.
        drawStanding()
        drawPick()
    }

    /// The picture's own rectangle: resizeAspect may leave a margin on one
    /// axis of the frame.
    private var shown: NSRect {
        let frame = photo.frame
        let size = image.size
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0 else { return frame }
        let scale = min(frame.width / size.width, frame.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
    }

    /// A point in the picture's own coordinates, 0…1 from the bottom left.
    private func unit(_ point: NSPoint) -> CGPoint {
        let area = shown
        guard area.width > 0, area.height > 0 else { return .zero }
        return CGPoint(x: (point.x - area.minX) / area.width, y: (point.y - area.minY) / area.height)
    }

    /// A rectangle of the picture's coordinates from two points on the view.
    private func unitRect(from start: NSPoint, to end: NSPoint) -> CGRect {
        let a = unit(start), b = unit(end)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Reading the text

    /// Off by default: the picture is left alone until the button is used.
    private func toggleText() {
        textOn.toggle()
        textButton.isOn = textOn
        if textOn {
            if text != nil {
                drawStanding()
            } else if !readingText {
                readingText = true
                textButton.isBusy = true
                PhotoText.read(image) { [weak self] text in
                    guard let self else { return }
                    self.readingText = false
                    self.textButton.isBusy = false
                    self.text = text
                    self.drawStanding()
                }
            }
        } else {
            clearPick()
            standing.isHidden = true
            NSCursor.arrow.set()
        }
    }

    private func drawStanding() {
        guard textOn, let text else {
            standing.isHidden = true
            return
        }
        let area = shown
        let path = CGMutablePath()
        for line in text.lines {
            path.addRect(CGRect(x: area.minX + line.box.minX * area.width,
                                y: area.minY + line.box.minY * area.height,
                                width: line.box.width * area.width,
                                height: line.box.height * area.height).insetBy(dx: -1, dy: -1))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        standing.path = path
        standing.isHidden = false
        CATransaction.commit()
    }

    private func drawPick() {
        let area = shown
        let path = CGMutablePath()
        for box in pickedBoxes {
            path.addRect(CGRect(x: area.minX + box.minX * area.width,
                                y: area.minY + box.minY * area.height,
                                width: box.width * area.width,
                                height: box.height * area.height))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pickLayer.path = path
        pickLayer.isHidden = pickedBoxes.isEmpty
        CATransaction.commit()
    }

    private func updatePick(from start: NSPoint, to end: NSPoint) {
        guard let text else { return }
        pickingTo = end
        let rect = unitRect(from: start, to: end).insetBy(dx: -0.004, dy: -0.008)
        let picked = text.pick(in: rect)
        self.picked = picked.text
        pickedBoxes = picked.boxes
        drawPick()
    }

    private func clearPick() {
        pickingFrom = nil
        pickingTo = nil
        picked = ""
        pickedBoxes = []
        pickLayer.isHidden = true
    }

    private func copyPick() -> Bool {
        guard !picked.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(picked, forType: .string)
        flash(L("Copied"))
        return true
    }

    // MARK: Carrying the file

    /// Small and in your hand: the photo is the page now.
    func showPage(_ icon: NSImage) {
        pageMode = true
        page.contents = icon
        page.frame = bounds
        page.contentsScale = window?.backingScaleFactor ?? 2
        page.isHidden = false
        photo.isHidden = true
        standing.isHidden = true
        pickLayer.isHidden = true
        holdRing.isHidden = true
        hangBackButton.isHidden = true
        textButton.isHidden = true
        layer?.borderWidth = 0
        layer?.cornerRadius = 9
        NSCursor.arrow.set()
    }

    /// The photo again, at its size.
    func hidePage() {
        pageMode = false
        page.isHidden = true
        photo.isHidden = false
        hangBackButton.isHidden = false
        textButton.isHidden = false
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 12
        drawStanding()
    }

    /// Where the window is while the hand carries the page.
    func beginPageDrag() {
        pageStart = NSEvent.mouseLocation
        pageOrigin = window?.frame.origin
    }

    // MARK: Moving and holding

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { showButton(true) }
    override func mouseExited(with event: NSEvent) {
        showButton(false)
        NSCursor.arrow.set()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if textOn, text?.hasText(at: unit(point)) == true, pickingFrom == nil {
            NSCursor.iBeam.set()
        } else if pickingFrom == nil {
            NSCursor.arrow.set()
        }
    }

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
        // A double click hands it back; with C held down, or Option, the photo
        // is copied first.
        if event.clickCount == 2 {
            if copyKeyDown || event.modifierFlags.contains(.option) { onCopy() }
            onHangBack()
            return
        }
        window?.makeKey()
        window?.makeFirstResponder(self)
        // While the text is lit, a drag across it picks it. Anywhere else the
        // photo is moved, as ever.
        if textOn, text?.hasText(at: unit(point)) == true {
            clearPick()
            pickingFrom = point
            pickingTo = point
            return
        }
        beginPress(at: point, event: event)
    }

    /// Press and hold without moving: after a moment the photo becomes its
    /// file. The ring only shows after a short grace, so a quick press leaves
    /// nothing on the screen.
    private func beginPress(at point: NSPoint, event: NSEvent) {
        pressEvent = event
        pressAt = point
        pressScreen = NSEvent.mouseLocation
        pressOrigin = window?.frame.origin
        moving = false
        let delay = Held.holdDelay
        let ringDelay = min(0.4, delay * 0.3)
        let ring = Timer(timeInterval: ringDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showRing(fillingOver: max(0.2, delay - ringDelay)) }
        }
        RunLoop.main.add(ring, forMode: .common)
        ringTimer = ring
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.longPressFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func longPressFired() {
        holdTimer = nil
        ringTimer?.invalidate()
        ringTimer = nil
        guard let pressEvent, let pressAt, !moving else { return }
        hideRing()
        self.pressAt = nil
        self.pressEvent = nil
        onLongPress(pressEvent)
    }

    private func showRing(fillingOver duration: TimeInterval) {
        guard let pressAt, !moving, holdRing.isHidden else { return }
        let radius: CGFloat = 13
        let circle = CGPath(ellipseIn: NSRect(x: pressAt.x - radius, y: pressAt.y - radius,
                                              width: radius * 2, height: radius * 2), transform: nil)
        // No implicit animations here: a jump to the full ring for one frame
        // read as a flash.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holdRing.removeAllAnimations()
        holdRing.path = circle
        holdRing.strokeStart = 0
        holdRing.strokeEnd = 0
        holdRing.isHidden = false
        CATransaction.commit()
        let fill = CABasicAnimation(keyPath: "strokeEnd")
        fill.fromValue = 0
        fill.toValue = 1
        fill.duration = max(0.2, duration)
        fill.timingFunction = CAMediaTimingFunction(name: .linear)
        fill.isRemovedOnCompletion = false
        holdRing.add(fill, forKey: "hold")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holdRing.strokeEnd = 1
        CATransaction.commit()
    }

    private func hideRing() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        holdRing.removeAllAnimations()
        holdRing.strokeEnd = 0
        holdRing.isHidden = true
        CATransaction.commit()
    }

    private func endPress() {
        holdTimer?.invalidate()
        holdTimer = nil
        ringTimer?.invalidate()
        ringTimer = nil
        pressEvent = nil
        pressAt = nil
        hideRing()
    }

    override func mouseDragged(with event: NSEvent) {
        if let from = pageStart, let origin = pageOrigin {
            let now = NSEvent.mouseLocation
            window?.setFrameOrigin(NSPoint(x: origin.x + now.x - from.x, y: origin.y + now.y - from.y))
            return
        }
        if let start = pickingFrom {
            updatePick(from: start, to: convert(event.locationInWindow, from: nil))
            return
        }
        guard let origin = pressOrigin, let from = pressScreen else { return }
        let now = NSEvent.mouseLocation
        let moved = hypot(now.x - from.x, now.y - from.y)
        guard moving || moved > 6 else { return }
        if !moving {
            moving = true
            holdTimer?.invalidate()
            holdTimer = nil
            hideRing()
        }
        window?.setFrameOrigin(NSPoint(x: origin.x + now.x - from.x, y: origin.y + now.y - from.y))
    }

    override func mouseUp(with event: NSEvent) {
        if pageMode {
            pageStart = nil
            pageOrigin = nil
            onRelease()
            return
        }
        if let start = pickingFrom {
            updatePick(from: start, to: convert(event.locationInWindow, from: nil))
            pickingFrom = nil
            pickingTo = nil
            NSCursor.arrow.set()
            return
        }
        endPress()
        pressOrigin = nil
        pressScreen = nil
        onRelease()
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
        // The tail of a gesture must not send it away twice.
        guard device > 0, event.momentumPhase.isEmpty else {
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

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else { return }
        // While the file is carried: ⌘C or C copies the file, Escape puts the
        // photo back.
        if pageMode {
            if event.keyCode == 53 {
                onRelease()
            } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
                onHangBack()
            } else if event.charactersIgnoringModifiers == "c" {
                copyFile()
            }
            return
        }
        if event.keyCode == 53 {
            // Escape first puts down what was picked, then the photo itself.
            if !picked.isEmpty {
                clearPick()
            } else {
                onHangBack()
            }
            return
        }
        // ⌘W hands the photo back to the line, as closing a window would.
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            onHangBack()
            return
        }
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            if !copyPick() { onCopy() }
            return
        }
        // C alone copies the photo and leaves it in hand, but only while the
        // pointer rests on it: a key pressed for another app is not ours.
        if plain, event.charactersIgnoringModifiers == "c",
           window?.frame.contains(NSEvent.mouseLocation) == true {
            copyKeyDown = true
            onCopy()
            flash(L("Copied"))
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "c" { copyKeyDown = false }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        if pageMode {
            menu.addItem(ClosureMenuItem(L("Copy")) { [weak self] in self?.copyFile() })
            menu.addItem(ClosureMenuItem(L("Share")) { [weak self] in self?.shareFile() })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Back to the photo")) { [weak self] in self?.onRelease() })
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if !picked.isEmpty {
            menu.addItem(ClosureMenuItem(L("Copy text")) { [weak self] in _ = self?.copyPick() })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(L("Hang back")) { [weak self] in self?.onHangBack() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Copy")) { [weak self] in self?.onCopy() })
        menu.addItem(ClosureMenuItem(L("Quick Look")) { [weak self] in self?.onQuickLook() })
        menu.addItem(ClosureMenuItem(L("Markup")) { [weak self] in self?.onMarkup() })
        menu.addItem(ClosureMenuItem(L("Actual Size")) { [weak self] in self?.onActualSize() })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// The file on the clipboard, to paste in the Finder or anywhere else.
    private func copyFile() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        FlashWord.show(L("Copied"), in: self)
    }

    private func shareFile() {
        NSSharingServicePicker(items: [url]).show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    /// A small word over the photo, for a moment: what just happened.
    private func flash(_ text: String) {
        FlashWord.show(text, in: self)
    }
}

/// The file being dragged by the pointer, until it is let go.
private final class FileDragSource: NSObject, NSDraggingSource {
    let url: URL
    private let onEnd: (NSDragOperation) -> Void

    init(url: URL, onEnd: @escaping (NSDragOperation) -> Void) {
        self.url = url
        self.onEnd = onEnd
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onEnd(operation)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
}

/// A small word over a view for a moment: what just happened.
private enum FlashWord {
    static func show(_ text: String, in view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()
        let pad: CGFloat = 9
        let box = NSVisualEffectView(frame: NSRect(x: view.bounds.midX - (label.frame.width + pad * 2) / 2,
                                                  y: view.bounds.midY - label.frame.height / 2 - pad,
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
        view.addSubview(box)
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
}

/// A small glass disc with a symbol, as on the line's cards.
private final class CornerButton: NSVisualEffectView {
    var onPress: () -> Void = {}
    /// The button that is switched on, like the text reader, shows it.
    var isOn = false { didSet { updateLook() } }
    /// Working, with nothing to show yet.
    var isBusy = false { didSet { updateLook() } }
    private var symbolView: NSImageView?

    private func updateLook() {
        layer?.backgroundColor = isOn ? NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor : nil
        symbolView?.contentTintColor = isOn ? .white : .labelColor
        symbolView?.alphaValue = isBusy ? 0.4 : 1
    }

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
        symbolView = icon
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
