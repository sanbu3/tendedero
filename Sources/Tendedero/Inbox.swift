import Foundation

/// Inbox mode: Tendedero takes over where screenshots go.
///
/// It changes the macOS screenshot settings in the Options menu of
/// Cmd+Shift+5: the floating thumbnail is turned off, so the file is written
/// at once instead of five seconds later, and captures are saved as files in
/// Tendedero's own folder instead of the Desktop. Saving to the clipboard or
/// Preview would leave nothing to hang, and a click on the line copies anyway.
/// Screen recordings go there too, and hang on the line like screenshots.
///
/// The folder is a queue, not a pile. Each capture joins the end, and when
/// the queue is full the oldest one is taken down, so neither the Desktop nor
/// the folder grows without end. Captures that land while Tendedero is closed
/// are taken in and trimmed at the next launch.
///
/// The previous values are saved first and put back when the mode is turned
/// off or the app quits, so macOS is never left pointing at a folder nobody
/// is watching.
enum Inbox {
    private static let domain = "com.apple.screencapture" as CFString
    /// macOS 26 and earlier read "location". macOS 27 reads
    /// "location-screenshot" and ignores the old key, so both are written.
    private static let locationKey = "location" as CFString
    private static let screenshotLocationKey = "location-screenshot" as CFString
    /// macOS 27 keeps screen recordings apart, in "location-screenrecording".
    /// Earlier versions send them wherever "location" points.
    private static let recordingLocationKey = "location-screenrecording" as CFString
    private static let thumbnailKey = "show-thumbnail" as CFString
    /// Whether a capture is saved as a file or sent to the clipboard, Preview
    /// and so on. macOS 26 and earlier read "target"; macOS 27 has one for
    /// screenshots and one for recordings.
    private static let targetKey = "target" as CFString
    private static let screenshotTargetKey = "target-screenshot" as CFString
    private static let recordingTargetKey = "target-screenrecording" as CFString

    private static let enabledKey = "inboxEnabled"
    private static let savedKey = "inboxSavedSettings"
    private static let capacityKey = "inboxCapacity"
    private static let lastQuitKey = "inboxLastQuit"

    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(AppIdentity.supportFolderName)/Screenshots", isDirectory: true)
    }()

    /// The user's choice, kept across launches. On out of the box: the line
    /// is meant to take the captures the Desktop would get, so they never
    /// pile up there, and the menu bar can turn it off.
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// How many captures the queue holds. It follows the line: what the line
    /// keeps is what waits in the folder, and one more takes the oldest down.
    static var capacity: Int {
        get {
            let n = UserDefaults.standard.integer(forKey: capacityKey)
            return n > 0 ? n : 8
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: capacityKey) }
    }

    /// When Tendedero last quit, so captures that landed on the Desktop in
    /// between, while the system setting was put back, are taken in too.
    static var lastQuit: Date? {
        get { UserDefaults.standard.object(forKey: lastQuitKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: lastQuitKey) }
    }

    /// Whether macOS is currently sending screenshots to our folder.
    static var isApplied: Bool {
        guard let current = CFPreferencesCopyAppValue(locationKey, domain) as? String else { return false }
        return URL(fileURLWithPath: (current as NSString).expandingTildeInPath).standardizedFileURL
            == folder.standardizedFileURL
    }

    static func apply() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Never save our own values as the "previous" ones, for example after
        // a crash left them applied.
        var saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        if !isApplied {
            saved = [:]
            saved["location"] = CFPreferencesCopyAppValue(locationKey, domain) as? String
            saved["locationScreenshot"] = CFPreferencesCopyAppValue(screenshotLocationKey, domain) as? String
            saved["thumbnail"] = CFPreferencesCopyAppValue(thumbnailKey, domain) as? Bool
        }
        // Recordings and the target came later: settings saved by an earlier
        // version lack them, and the value macOS has now is still the user's own.
        if saved["recordingSaved"] == nil {
            saved["locationRecording"] = CFPreferencesCopyAppValue(recordingLocationKey, domain) as? String
            saved["recordingSaved"] = true
        }
        if saved["targetSaved"] == nil {
            saved["target"] = CFPreferencesCopyAppValue(targetKey, domain) as? String
            saved["targetScreenshot"] = CFPreferencesCopyAppValue(screenshotTargetKey, domain) as? String
            saved["targetRecording"] = CFPreferencesCopyAppValue(recordingTargetKey, domain) as? String
            saved["targetSaved"] = true
        }
        UserDefaults.standard.set(saved, forKey: savedKey)
        set(locationKey, folder.path)
        set(screenshotLocationKey, folder.path)
        set(recordingLocationKey, folder.path)
        set(targetKey, "file")
        set(screenshotTargetKey, "file")
        set(recordingTargetKey, "file")
        set(thumbnailKey, false)
    }

    static func restore() {
        guard isApplied else { return }
        let saved = UserDefaults.standard.dictionary(forKey: savedKey) ?? [:]
        set(locationKey, saved["location"])
        set(screenshotLocationKey, saved["locationScreenshot"])
        set(recordingLocationKey, saved["locationRecording"])
        set(targetKey, saved["target"])
        set(screenshotTargetKey, saved["targetScreenshot"])
        set(recordingTargetKey, saved["targetRecording"])
        set(thumbnailKey, saved["thumbnail"])
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// Writes through cfprefsd, so the screenshot service sees it at once.
    /// A nil value removes the key and returns it to the macOS default.
    private static func set(_ key: CFString, _ value: Any?) {
        CFPreferencesSetAppValue(key, value as CFPropertyList?, domain)
        CFPreferencesAppSynchronize(domain)
    }

    // MARK: The queue

    /// Whether this file waits in Tendedero's own folder.
    static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }

    /// The captures waiting in the folder, oldest first: the order they
    /// joined the queue in.
    static func queuedFiles() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { ScreenshotWatcher.isImageURL($0) || isRecording($0) }
            .sorted { creationDate($0) < creationDate($1) }
    }

    private static func creationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    /// Trims the queue: every capture past the capacity takes the oldest one
    /// down, to the Trash, so nothing piles up anywhere. Called when a capture
    /// joins and once at launch, because captures keep arriving in the folder
    /// while the app is closed.
    ///
    /// Two are left alone. A photo the line is showing goes when the line
    /// takes its own oldest down, in the same instant, so it is not trashed
    /// twice. The newest capture is never the one taken down: it just joined.
    static func enforceQueue(keeping onLine: Set<String> = []) {
        let files = queuedFiles()
        let waiting = files.filter { !onLine.contains($0.standardizedFileURL.path) }
        var over = files.count - capacity
        guard over > 0 else { return }
        let fm = FileManager.default
        for url in waiting.dropLast() where over > 0 {
            over -= 1
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
                log.notice("Queue full: took down \(url.lastPathComponent, privacy: .public)")
            } catch {
                log.error("Could not take down \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Moves a capture that landed on the Desktop into the queue, so the
    /// Desktop never gets a pile of screenshots. Nil when it could not move.
    @discardableResult
    static func adopt(_ url: URL) -> URL? {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = url.lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        do {
            try fm.moveItem(at: url, to: target)
            return target
        } catch {
            log.error("Could not take in \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Screenshots that landed on the Desktop while the app was closed, from
    /// the last quit until now: they are taken into the queue at launch, so
    /// closing the app does not leave a pile on the Desktop.
    @discardableResult
    static func adoptDesktopSince(_ date: Date) -> Int {
        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: desktop, includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var moved = 0
        for url in urls where ScreenshotWatcher.isImageURL(url)
            && creationDate(url) > date
            && ScreenshotWatcher.isScreenCapture(url) {
            if adopt(url) != nil { moved += 1 }
        }
        return moved
    }
}
