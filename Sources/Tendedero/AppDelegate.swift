import AppKit
import AVFoundation
import Carbon
import Combine
import Quartz
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let line = Line()
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), or another app
    /// saves there, the capture is taken into the queue, and the Desktop
    /// stays clear.
    private var safetyWatcher: ScreenshotWatcher?
    /// Folders chosen in "Also watch folders", like the one another
    /// screenshot app saves to.
    private var folderWatchers: [ScreenshotWatcher] = []
    /// Picks up pointer files the `tendedero` CLI drops in the spool.
    private var spoolWatcher: SpoolWatcher?
    /// Picks up screenshots the iPhone shortcut saves into iCloud Drive, in
    /// both locations the shortcut can reach.
    private var phoneWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var deleteHotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?
    /// The glass hint under the menu bar, shown before the line drops.

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A new screenshot shows itself for a moment, then tucks away.
    private var peekUntil = Date.distantPast
    /// When the pointer first entered the top center hot zone.
    private var topCenterSince: Date?
    /// Whether the pointer has moved upward since it entered the zone. This
    /// is the gesture that wakes the line.
    private var topCenterMovedUp = false
    /// After a click in the menu bar the line stays up there hidden until the
    /// pointer leaves the menu bar, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false
    /// Opened on purpose with the shortcut or the menu, which counts over a
    /// full screen app too, until the line tucks away.
    private var openedOnPurpose = false

    // What brings the line down, from the menu bar's "Bring the line down".
    // Out of the box, the first two are on and the third off.

    /// Resting the pointer at the top center. Off, only the shortcut and the
    /// menu open it.
    static var opensFromTopCenter: Bool {
        get { !UserDefaults.standard.bool(forKey: "topCenterRevealOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "topCenterRevealOff") }
    }

    /// Entering the top center only shows the hint. The line comes down only
    /// when the pointer keeps moving up: it must have moved upward since the
    /// hint appeared, then reach the top edge.
    ///
    /// The pull starts 144 points below the top edge. The old band was barely
    /// taller than the menu bar, so the gauge filled almost at once; a longer
    /// run makes the threshold a deliberate gesture.
    private static let topCenterPullHeight: CGFloat = 144
    private static let topCenterWakeBand: CGFloat = 4
    /// A short guard so a very fast upward push still wakes the line.
    private static let topCenterMinimumHint: TimeInterval = 0.12

    /// Something new hanging shows itself for a moment. Off, it hangs
    /// quietly and waits for you to bring the line down.
    static var peeksAtNew: Bool {
        get { !UserDefaults.standard.bool(forKey: "quietHang") }
        set { UserDefaults.standard.set(!newValue, forKey: "quietHang") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let host = NSHostingView(rootView: LineView(line: line))
        host.sizingOptions = []
        panel = LinePanel(content: host)
        panel.placeOnScreen()
        updateCapacity()

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        clipboardWatcher = ClipboardWatcher { [weak self] url in self?.hangCapture(url) }
        if ClipboardWatcher.isEnabled { clipboardWatcher.start() }

        registerShortcuts()

        setUpStatusItem()
        watchMenuBarClicks()

        // Hang on Tendedero, in the menu of images in Finder and other apps.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        Share.shared.clearAll()
        Trim.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        panel.onScroll = { [weak self] event in
            // Sideways on a trackpad, or the wheel of a mouse.
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            self?.line.scroll(by: event.hasPreciseScrollingDeltas ? delta : delta * 12)
        }
        line.onFall = { [weak self] item in self?.fall(item) }
        line.onHold = { [weak self] id in self?.hold(id) }
        line.onHangBack = { id in Held.hangBack(id) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // Photos kept from last time show themselves for a moment.
        if line.liveCount > 0 { comeDown(on: nil) }

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // Opened on purpose counts for the Space it was opened on.
                    if name == NSWorkspace.activeSpaceDidChangeNotification { self?.openedOnPurpose = false }
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        self?.refresh()
                        self?.keepOnActiveSpace()
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        // The Desktop keeps nothing: captures that landed there while the
        // app was closed are taken into the queue, and so is what waited in
        // the folder. The queue is trimmed first.
        DispatchQueue.main.async { [weak self] in self?.adoptWaitingCaptures() }

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            keepOpen = true
            wanted = true
            refresh()
            reveal(pinned: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.line.liveCount == 0 else { return }
                self.keepOpen = false
                self.wanted = false
                self.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Inbox.isEnabled {
            Inbox.lastQuit = Date()
            Inbox.restore()
        }
        Share.shared.clearAll()
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    // macOS is meant to save into the queue, so this one
                    // slipped through, or came from another app: it joins the
                    // queue too, and the Desktop stays clear.
                    guard let self else { return }
                    guard let moved = Inbox.adopt(url) else {
                        self.hangCapture(url)
                        return
                    }
                    log.notice("Took a Desktop capture into the queue: \(moved.lastPathComponent, privacy: .public)")
                    self.hangCapture(moved)
                },
                onChange: { [weak self] in
                    self?.line.prune()
                    Inbox.enforceQueue(keeping: self?.onLinePaths ?? [])
                })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
        if spoolWatcher == nil {
            let spool = SpoolWatcher { [weak self] url in self?.hangCapture(url) }
            spool.start()
            spoolWatcher = spool
        }
        setPhoneWatching(PhoneSync.isEnabled, announceFailure: false)
    }

    // MARK: Phone sync

    /// Turns the iCloud Drive watcher on or off. The folder is created on
    /// demand, so the phone side of the shortcut has somewhere to save even
    /// before its first run.
    private func setPhoneWatching(_ enabled: Bool, announceFailure: Bool = true) {
        phoneWatchers.forEach { $0.stop() }
        phoneWatchers = []
        guard enabled else { return }
        if !PhoneSync.driveAvailable {
            if announceFailure {
                let alert = NSAlert()
                alert.messageText = L("iCloud Drive is not available")
                alert.informativeText = L("Sign in to iCloud Drive and try again.")
                alert.runModal()
            }
            PhoneSync.isEnabled = false
            return
        }
        for folder in PhoneSync.folders {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let watcher = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            watcher.start()
            phoneWatchers.append(watcher)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        startWatcher()
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
        if on { adoptWaitingCaptures() }
    }

    /// Takes in what the queue is holding and what the Desktop got while the
    /// app was closed, hanging the captures that are not on the line yet.
    private func adoptWaitingCaptures() {
        guard Inbox.isEnabled else { return }
        if let since = Inbox.lastQuit {
            let moved = Inbox.adoptDesktopSince(since)
            if moved > 0 { log.notice("Took in \(moved) captures from the Desktop") }
            Inbox.lastQuit = nil
        }
        Inbox.enforceQueue(keeping: onLinePaths)
        let waiting = Inbox.queuedFiles().filter { !onLinePaths.contains($0.standardizedFileURL.path) }
        guard !waiting.isEmpty else { return }
        comeDown(on: nil)
        // Quietly, oldest first: restoring the queue is not a fanfare, and
        // the decodes stay off the main thread and in order.
        for url in waiting {
            decodeThumbnail(url) { [weak self] thumb in
                guard let self else { return }
                self.line.hang(url, quietly: true, thumb: thumb)
            }
        }
    }

    /// Watching the clipboard is opt in, from the menu bar only.
    private func setClipboard(_ on: Bool) {
        ClipboardWatcher.isEnabled = on
        if on { clipboardWatcher.start() } else { clipboardWatcher.stop() }
        updateStatusIcon()
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                if Inbox.isEnabled {
                    Inbox.lastQuit = Date()
                    Inbox.restore()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        updateStatusIcon()
        Held.forget(except: Set(line.items.filter { !$0.falling && $0.held }.map(\.id)))
        guard line.liveCount == 0, !keepOpen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.keepOpen else { return }
            self.wanted = false
            self.refresh()
        }
    }

    /// The line comes down on that screen for a moment, then tucks away.
    /// Without a screen, it uses the one under the pointer.
    private func comeDown(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
        if Self.peeksAtNew { reveal(peekFor: 2.5) }
    }

    // MARK: The capture flying to the line

    /// A new screenshot lifts off from where it was taken and flies to its
    /// place on the line. Without a known capture area it simply drops in.
    ///
    /// The thumbnail is decoded off the main thread first. Two captures
    /// arriving together — a phone shot over iCloud and something copied
    /// just after — used to decode one after another on the main thread,
    /// long enough for the line to stutter as it came down.
    private func hangCapture(_ url: URL) {
        // Already hanging: a photo put back with ⌘Z comes out of the Trash
        // into the folder, and the watcher sees it arrive. It must not pull
        // the line over to the screen it was first taken on.
        guard !line.items.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL && !$0.falling })
        else { return }
        // A capture joining the queue takes the oldest one down once it is
        // full. The line's own photos are left to the line.
        if Inbox.contains(url) { Inbox.enforceQueue(keeping: onLinePaths) }
        let from = captureRect(of: url)
        let screen = from.flatMap { from in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) }
        }
        // Every capture brings the line down before it hangs, on the screen it
        // was taken on. On a full line the oldest photo then falls in view as
        // the new one flies in.
        comeDown(on: screen)
        // A screenshot macOS took already played its shutter, so it hangs
        // without a chime of its own. Copied images and watched folders,
        // which come with no sound, keep it.
        decodeThenHang(url, flying: from != nil, quietly: from != nil) { [weak self] id in
            guard let self, let from else { return }
            // Let the line come down and lay out before measuring the landing spot.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                self.fly(id, from: from)
            }
        }
    }

    /// Decodes the thumbnail, then hangs. An iCloud file that has not synced
    /// down yet is downloaded first, with a few retries before giving up.
    private func decodeThenHang(_ url: URL, flying: Bool, quietly: Bool = false, then: @escaping (UUID) -> Void) {
        decodeThumbnail(url) { [weak self] thumb in
            guard let self else { return }
            if let id = self.line.hang(url, quietly: quietly, flying: flying, thumb: thumb) {
                then(id)
            } else if thumb == nil, self.iCloudWaitCount[url.path] ?? 0 < 5 {
                // Probably an iCloud placeholder: ask for the file and try
                // again a moment later. A truly unreadable file is dropped
                // once the retries run out.
                self.iCloudWaitCount[url.path] = (self.iCloudWaitCount[url.path] ?? 0) + 1
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.decodeThenHang(url, flying: flying, quietly: quietly, then: then)
                }
            } else {
                // Nothing hung after all, so an empty line goes away again.
                self.iCloudWaitCount[url.path] = nil
                self.itemsChanged()
            }
        }
    }

    /// How many times each not-yet-synced file has been retried.
    private var iCloudWaitCount: [String: Int] = [:]

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, !Self.reducesMotion, CaptureFlight.flightsInProgress < 2,
              let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        let size = min(1500, max(400, pixels))
        // The flying image decodes off the main thread too: the line is
        // coming down just now, and it should not skip while doing so.
        decodeThumbnail(item.url, maxPixels: size) { [weak self] thumb in
            guard let self else { return }
            guard let image = thumb?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                self.line.land(id)
                return
            }
            CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt), on: screen) {
                self.line.land(id)
            }
        }
    }

    /// A discarded card falls over the whole screen, from where it hangs.
    /// Reduce motion in Accessibility settings: photos land and leave
    /// without flying across the screen or falling down it.
    private static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, !Self.reducesMotion, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let image = item.thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        CaptureFlight.fall(image: image, card: card, tilt: CGFloat(item.tilt), pinned: item.kept, on: screen)
    }

    /// The files the line is showing, so the queue does not take one down
    /// that is already about to leave the line.
    private var onLinePaths: Set<String> {
        Set(line.items.map { $0.url.standardizedFileURL.path })
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let index = line.items.firstIndex(where: { $0.id == id }) else { return nil }
        let width = panel.frame.width
        let x = Layout.x(index: index, count: line.items.count, width: width,
                         visible: line.visibleCount, scroll: line.scroll, pinned: line.pinnedLead)
        let viewTop = Layout.ropeY(x: x, width: width) - Layout.pinAbove
        let cardTop = viewTop + PeggedView.cardOffsetBelowTop
        let size = PeggedView.cardSize(for: line.items[index].thumb.size)
        return CGRect(x: panel.frame.minX + x - size.width / 2,
                      y: panel.frame.maxY - cardTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen unless you asked for the line.
    private func refresh() {
        let blocked = !openedOnPurpose && (panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false)
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    /// The line is one window on every Space. After a long time running,
    /// macOS can leave it bound to a single Space, where ordering it in does
    /// nothing on the others while captures keep arriving (#80). Quitting and
    /// opening the app again fixes it because the window is new, so do the
    /// same here: a fresh window with the same contents, in the same place.
    private func keepOnActiveSpace() {
        guard isPresent, isRevealed, panel.isVisible, !panel.isOnActiveSpace else { return }
        log.notice("The line was not on the active Space; making its window again")
        let old = panel!
        let content = old.contentView
        old.contentView = NSView()
        old.orderOut(nil)
        let fresh = LinePanel(content: content ?? NSView())
        fresh.onScroll = old.onScroll
        fresh.setFrame(old.frame, display: false)
        fresh.ignoresMouseEvents = old.ignoresMouseEvents
        fresh.alphaValue = old.alphaValue
        panel = fresh
        fresh.orderFrontRegardless()
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        // It always comes down showing the newest.
        if on { line.scroll = 0 }
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent {
                panel.orderFrontRegardless()
                DispatchQueue.main.async { [weak self] in self?.keepOnActiveSpace() }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            pinned = false
            peekUntil = .distantPast
            line.hoveredID = nil
            panel.ignoresMouseEvents = true
            // Opened on purpose lasts until the line tucks away, however that
            // happens: an empty line then goes, as with the shortcut, and over
            // a full screen app the line goes too.
            if keepOpen || openedOnPurpose {
                keepOpen = false
                openedOnPurpose = false
                if line.liveCount == 0 { wanted = false }
                refresh()
            }
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
        } else {
            keepOpen = true
            wanted = true
            openedOnPurpose = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
        holdPutBackKey(false)
        holdPhotoKeys(over: nil)
    }

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// A narrow strip at the top middle of a screen. It reaches a few points
    /// below the menu bar so the pointer can rest just under the notch too.
    static func topCenterZone(of screen: NSScreen) -> NSRect {
        let bar = menuBarBand(of: screen)
        let width = min(320, max(180, screen.frame.width * 0.22))
        let height = max(Self.topCenterPullHeight, bar.height + 8)
        return NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height,
                      width: width, height: height)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.resetTopCenterHint()
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inMenuBar = screenUnderPointer.map { NSMouseInRect(mouse, Self.menuBarBand(of: $0), false) } ?? false
        if !inMenuBar { menuBarSuppressed = false }

        guard isRevealed else {
            holdPutBackKey(false)
            holdPhotoKeys(over: nil)
            line.closeGaps()
            updateTopCenterHint(mouse: mouse, screen: screenUnderPointer, now: now)
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }
        holdPutBackKey(inside)
        holdPhotoKeys(over: inside ? photo(under: mouse) : nil)
        // Gaps left by discarded photos close once the pointer moves away.
        if !inside { line.closeGaps() }

        let busy = pinned || GrabView.isDragging || GrabView.isShowingMenu || Share.shared.isOpen
            || line.pressedID != nil || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// The pointer resting at the top center only shows the hint. The hint
    /// follows the pointer upward, and the line is woken only when the
    /// pointer reaches the top edge after climbing from where it entered.
    /// The pointer resting at the top center wakes the line: entering the
    /// zone starts the clock, moving up towards the top edge is the gesture,
    /// and reaching the top edge drops the line. No hint panel, no animation.
    private func updateTopCenterHint(mouse: NSPoint, screen: NSScreen?, now: Date) {
        guard Self.opensFromTopCenter, let screen,
              !menuBarSuppressed,
              !FullScreen.blocksLine(on: screen),
              line.liveCount > 0 else {
            resetTopCenterHint()
            return
        }

        let zone = Self.topCenterZone(of: screen)
        guard NSMouseInRect(mouse, zone, false) else {
            resetTopCenterHint()
            return
        }
        if topCenterSince == nil {
            topCenterSince = now
            topCenterMovedUp = false
        }
        guard let since = topCenterSince else { return }
        if mouse.y > zone.minY + zone.height * 0.5 { topCenterMovedUp = true }

        guard mouse.y >= screen.frame.maxY - Self.topCenterWakeBand,
              topCenterMovedUp,
              now.timeIntervalSince(since) >= Self.topCenterMinimumHint else { return }

        topCenterSince = nil
        topCenterMovedUp = false
        if line.soundOn { Line.playWake() }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        if panel.screen != screen {
            panel.placeOnScreen(screen)
            updateCapacity()
        }
        wanted = true
        refresh()
        reveal()
    }

    private func resetTopCenterHint() {
        topCenterSince = nil
        topCenterMovedUp = false
    }

    /// The panel spans the whole width of the screen, so it only accepts the
    /// mouse while the cursor is over a photo. Everywhere else, clicks go to
    /// whatever is underneath.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        var overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        // A line longer than the screen also takes the band the photos hang
        // in, gaps included, so a swipe anywhere along it moves it.
        if !overPhoto, line.items.count > line.visibleCount, Line.keepOnLine != nil {
            let band = line.hitRects.values.reduce(CGRect.null) { $0.union($1) }
            overPhoto = !band.isNull && flipped.y >= band.minY - 4 && flipped.y <= band.maxY + 4
        }
        if panel.ignoresMouseEvents == overPhoto {
            panel.ignoresMouseEvents = !overPhoto
        }
    }

    // MARK: Holding

    /// Takes a photo off the line to hold in front of you. The line goes
    /// up, so it is out of the way of the photo you are looking at.
    private func hold(_ id: UUID) {
        guard let item = line.items.first(where: { $0.id == id && !$0.falling && !$0.held }) else { return }
        line.setHeld(id, true)
        Held.show(id, url: item.url, line: line) { [weak self] id, frame in self?.hangBack(id, from: frame) }
    }

    /// Back onto its clip: the line comes down and the photo flies home.
    private func hangBack(_ id: UUID, from frame: CGRect) {
        line.setHeld(id, false)
        comeDown(on: NSScreen.screens.first { $0.frame.intersects(frame) })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: frame)
        }
    }

    // MARK: Hang on Tendedero

    /// The service macOS lists for images in Finder and elsewhere. What
    /// you hang yourself is pinned, and the line comes down to show it.
    @objc func hangOnLine(_ pasteboard: NSPasteboard, userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        comeDown(on: nil)
        var any = false
        for url in urls where line.hangKept(url) { any = true }
        if !any { NSSound.beep() }
    }

    // MARK: Keys over a photo

    /// Delete and Space while the pointer rests on a photo: Delete does what
    /// its corner button does, Space takes a quick look, as in Finder. Like
    /// ⌘Z, they are borrowed as hot keys only then, so every other app keeps
    /// them.
    private var photoKeys: [HotKey] = []
    private var photoKeysFor: UUID?

    private func holdPhotoKeys(over id: UUID?) {
        let id = id.flatMap { id in line.items.first { $0.id == id && !$0.falling && !$0.held }?.id }
        guard id != photoKeysFor else { return }
        photoKeysFor = id
        photoKeys = []
        guard let id else { return }
        photoKeys = [
            HotKey(Shortcut(keyCode: kVK_Delete, modifiers: [], key: "\u{8}")) { [weak self] in
                self?.line.pressCorner(id)
            },
            HotKey(Shortcut(keyCode: kVK_Space, modifiers: [], key: " ")) { [weak self] in
                self?.quickLookToggle(id)
            },
        ].compactMap { $0 }
    }

    /// The photo whose card is under the pointer, if any.
    private func photo(under mouse: NSPoint) -> UUID? {
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        return line.hitRects.first { $0.value.contains(flipped) }?.key
    }

    /// Space opens Quick Look, and closes it again if it is already open.
    private func quickLookToggle(_ id: UUID) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            line.quickLook(id)
        }
    }

    // MARK: Putting back

    /// ⌘Z while the pointer is on the line. The line never takes the
    /// keyboard, so it only borrows ⌘Z then, as a hot key. Everywhere else
    /// ⌘Z stays the undo of the app you are in.
    private var putBackKey: HotKey?

    /// Set when another app holds ⌘Z, so it is not asked for again on every
    /// tick, only the next time the pointer comes to the line.
    private var putBackKeyRefused = false

    private func holdPutBackKey(_ hold: Bool) {
        guard hold && line.canPutBack else {
            putBackKey = nil
            putBackKeyRefused = false
            return
        }
        guard putBackKey == nil, !putBackKeyRefused else { return }
        putBackKey = HotKey(Shortcut.putBack) { [weak self] in self?.putBack() }
        putBackKeyRefused = putBackKey == nil
    }

    /// From the menu the line is usually up, so it comes down for a moment
    /// to show the photos going back.
    private func putBack() {
        if !isRevealed {
            panel.placeOnScreen()
            updateCapacity()
            wanted = true
            refresh()
            reveal(peekFor: 2.5)
        }
        line.putBack()
    }

    // MARK: Shortcut

    private func registerShortcuts() {
        hotKey = nil
        deleteHotKey = nil
        if let shortcut = Shortcut.current {
            hotKey = HotKey(shortcut, id: 1) { [weak self] in self?.toggle() }
        }
        if let shortcut = Shortcut.deleteHovered {
            deleteHotKey = HotKey(shortcut, id: 2) { [weak self] in self?.deleteHovered() }
        }
    }

    /// The delete shortcut only acts on a photo that is actually under the
    /// pointer while the line is down. Anywhere else it just beeps, so it can
    /// never remove a random screenshot.
    private func deleteHovered() {
        guard isRevealed, let id = line.hoveredID, !GrabView.isShowingMenu else {
            NSSound.beep()
            return
        }
        line.discard(id)
    }

    private func changeShortcut(for slot: ShortcutSlot) {
        // Off while recording, so pressing the current one records it instead
        // of firing.
        if slot == .showLine { hotKey = nil } else { deleteHotKey = nil }
        ShortcutRecorder.shared.record(for: slot) { [weak self] result in
            guard let self else { return }
            if let result {
                let previous = Shortcut.current(for: slot)
                Shortcut.set(result, for: slot)
                self.registerShortcuts()
                // Taken by another app: keep the one that worked.
                let registered = slot == .showLine ? self.hotKey != nil : self.deleteHotKey != nil
                if result != nil && !registered {
                    NSSound.beep()
                    Shortcut.set(previous, for: slot)
                }
            }
            self.registerShortcuts()
        }
    }

    private func setKeep(_ n: Int?) {
        guard n != Line.keepOnLine else { return }
        Line.keepOnLine = n
        updateCapacity()
        line.trim()
    }

    private func setSize(_ size: Layout.Size) {
        guard size != Layout.size else { return }
        Layout.size = size
        panel.placeOnScreen(panel.screen)
        updateCapacity()
        line.reloadThumbnails()
    }

    private func updateCapacity() {
        let usable = panel.frame.width - 200
        let fits = max(3, min(12, Int(usable / Layout.spacing)))
        line.visibleCount = fits
        line.maxItems = max(fits, Line.keepOnLine ?? fits)
        // The folder is the line's queue: it holds exactly what the line keeps.
        Inbox.capacity = line.maxItems
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        // Items say themselves whether they can be used, like Take everything
        // down on an empty line.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The shirt fills in while copied images are hung, so it shows at a
    /// glance that the clipboard is being watched. It is dimmed while the
    /// line is empty, so resting in the menu bar and seeing nothing come down
    /// does not look broken.
    private func updateStatusIcon() {
        let on = ClipboardWatcher.isEnabled
        let count = line.liveCount
        let description = on ? L("Tendedero, hanging copied images") : "Tendedero"
        let state = count == 0 ? L("The line is empty") : String(format: L("%d on the line"), count)
        let image = NSImage(systemSymbolName: on ? "tshirt.fill" : "tshirt",
                            accessibilityDescription: "\(description), \(state)")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = count == 0
        statusItem.button?.toolTip = "\(description)\n\(state)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? L("Hide line") : L("Show line")) { [weak self] in
            self?.toggle()
        }
        if let shortcut = Shortcut.current, shortcut.key.count == 1 {
            toggleItem.keyEquivalent = shortcut.key
            toggleItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let putBackItem = ClosureMenuItem(L("Put back"), key: "z") { [weak self] in
            self?.putBack()
        }
        putBackItem.isEnabled = line.canPutBack
        menu.addItem(putBackItem)

        if !Held.heldIDs.isEmpty {
            menu.addItem(ClosureMenuItem(L("Hang everything back")) { Held.hangEverythingBack() })
        }

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)

        let clipboard = ClosureMenuItem(L("Hang copied images")) { [weak self] in
            self?.setClipboard(!ClipboardWatcher.isEnabled)
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        clipboard.toolTip = L("Images you copy hang on the line too")
        menu.addItem(clipboard)

        let phone = ClosureMenuItem(L("Sync iPhone screenshots")) { [weak self] in
            guard let self else { return }
            PhoneSync.isEnabled.toggle()
            self.setPhoneWatching(PhoneSync.isEnabled)
        }
        phone.state = PhoneSync.isEnabled ? .on : .off
        phone.toolTip = L("Screenshots from the iPhone shortcut in iCloud Drive/Tendedero hang on the line")
        menu.addItem(phone)

        let bringDown = NSMenuItem(title: L("Bring the line down"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        let hover = ClosureMenuItem(L("When the pointer rests at the top center")) {
            AppDelegate.opensFromTopCenter.toggle()
        }
        hover.state = Self.opensFromTopCenter ? .on : .off
        options.addItem(hover)
        let peek = ClosureMenuItem(L("When something new hangs")) {
            AppDelegate.peeksAtNew.toggle()
        }
        peek.state = Self.peeksAtNew ? .on : .off
        options.addItem(peek)
        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showLineOver.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showLineOver ? .on : .off
        options.addItem(fullScreen)
        bringDown.submenu = options
        menu.addItem(bringDown)

        let mouseItem = NSMenuItem(title: L("Mouse"), action: nil, keyEquivalent: "")
        let mouseMenu = NSMenu()
        mouseMenu.autoenablesItems = false
        let click = ClosureMenuItem(L("Click copies")) { [weak self] in
            self?.line.clickCopies.toggle()
        }
        click.state = line.clickCopies ? .on : .off
        mouseMenu.addItem(click)
        let clickNote = NSMenuItem(title: L("When off, a click previews"), action: nil, keyEquivalent: "")
        clickNote.isEnabled = false
        mouseMenu.addItem(clickNote)
        let middle = NSMenuItem(title: L("Middle click deletes the photo under the pointer"), action: nil, keyEquivalent: "")
        middle.isEnabled = false
        mouseMenu.addItem(middle)
        let double = NSMenuItem(title: L("Double-click copies. Right-click keeps the menu."), action: nil, keyEquivalent: "")
        double.isEnabled = false
        mouseMenu.addItem(double)
        let deleteItem = NSMenuItem(title: L("Delete hovered photo"), action: nil, keyEquivalent: "")
        let deleteMenu = NSMenu()
        let currentDelete = NSMenuItem(title: Shortcut.deleteHovered?.display ?? L("None"), action: nil, keyEquivalent: "")
        currentDelete.isEnabled = false
        deleteMenu.addItem(currentDelete)
        deleteMenu.addItem(ClosureMenuItem(L("Change Delete Shortcut…")) { [weak self] in
            self?.changeShortcut(for: .deleteHovered)
        })
        deleteItem.submenu = deleteMenu
        mouseMenu.addItem(deleteItem)
        mouseItem.submenu = mouseMenu
        menu.addItem(mouseItem)

        let folderItem = NSMenuItem(title: L("Also watch folders"), action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let folders = Self.extraFolders
        for folder in folders {
            let item = ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) {
                NSWorkspace.shared.open(folder)
            }
            item.state = .on
            folderMenu.addItem(item)
        }
        if !folders.isEmpty { folderMenu.addItem(.separator()) }
        let add = ClosureMenuItem(L("Add Folder…")) { [weak self] in self?.chooseExtraFolder() }
        add.isEnabled = folders.count < Self.maxExtraFolders
        folderMenu.addItem(add)
        if !folders.isEmpty {
            let stop = NSMenuItem(title: L("Stop Watching"), action: nil, keyEquivalent: "")
            let stopMenu = NSMenu()
            for folder in folders {
                stopMenu.addItem(ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) { [weak self] in
                    AppDelegate.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                    self?.startWatcher()
                })
            }
            stop.submenu = stopMenu
            folderMenu.addItem(stop)
        }
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)

        let keepItem = NSMenuItem(title: L("Keep on line"), action: nil, keyEquivalent: "")
        let keeps = NSMenu()
        let fit = ClosureMenuItem(L("As many as fit")) { [weak self] in self?.setKeep(nil) }
        fit.state = Line.keepOnLine == nil ? .on : .off
        keeps.addItem(fit)
        for n in Line.keepChoices {
            let item = ClosureMenuItem(String(format: L("%d photos"), n)) { [weak self] in self?.setKeep(n) }
            item.state = Line.keepOnLine == n ? .on : .off
            keeps.addItem(item)
        }
        keepItem.submenu = keeps
        menu.addItem(keepItem)

        let sizeItem = NSMenuItem(title: L("Size"), action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (size, title) in [(Layout.Size.small, L("Small")), (.medium, L("Medium")), (.large, L("Large"))] {
            let item = ClosureMenuItem(title) { [weak self] in self?.setSize(size) }
            item.state = Layout.size == size ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let shortcutItem = NSMenuItem(title: L("Shortcut"), action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        let current = NSMenuItem(title: Shortcut.current?.display ?? L("None"), action: nil, keyEquivalent: "")
        current.isEnabled = false
        shortcuts.addItem(current)
        shortcuts.addItem(ClosureMenuItem(L("Change Shortcut…")) { [weak self] in
            self?.changeShortcut(for: .showLine)
        })
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        // The app never connects to anything, so it cannot tell when a new
        // version is out. The website can: it is opened with this version
        // and language, and says whether there is a newer one.
        menu.addItem(ClosureMenuItem(L("Check for Updates…")) {
            NSWorkspace.shared.open(AppDelegate.updatesURL)
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Quit Tendedero"), key: "q") {
            NSApp.terminate(nil)
        })
    }

    /// tendedero.app with the running version, and the menus' language when
    /// the website has it too, so the page answers in the same words.
    private static var updatesURL: URL {
        var components = URLComponents(string: "https://tendedero.app/")!
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        var query = [URLQueryItem(name: "update", value: version)]
        if let language = Bundle.main.preferredLocalizations.first, ["en", "es", "gl", "fr", "pt-BR", "ja", "ko", "zh-Hans"].contains(language) {
            query.append(URLQueryItem(name: "lang", value: language))
        }
        components.queryItems = query
        return components.url!
    }

    private static func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move Tendedero to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}

