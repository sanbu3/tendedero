import Foundation

/// Watches the iCloud Drive folder that the "Sync iPhone screenshots" shortcut
/// saves captures into, and hangs every new image on the line.
///
/// The Mac side is one toggle: turning it on creates the folder if needed and
/// starts watching; the phone side is a Shortcuts automation ("When screenshot
/// is taken" → save to iCloud Drive/Tendedero) set up once, as described in
/// `docs/CLI-AND-PHONE.md`. Files arrive through iCloud, so they are external
/// files: taking one down leaves it in the folder, and the line prunes entries
/// whose file has not (yet) synced down.
enum PhoneSync {
    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Tendedero` — the path
    /// iOS saves to when a shortcut targets iCloud Drive/Tendedero. (The
    /// container directory is `com~apple~CloudDocs` on macOS.)
    static let folder: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "Library/Mobile Documents/com~apple~CloudDocs/Tendedero", isDirectory: true)
    }()

    /// The Shortcuts app has its own iCloud container, and a shortcut that
    /// saves "to iCloud Drive" with a relative path lands in
    /// `…/iCloud~is~workflow~my~workflows/Documents/iCloud Drive`. Watched too,
    /// so both save styles work.
    static let shortcutsFallbackFolder: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/iCloud Drive",
            isDirectory: true)
    }()

    /// Every folder the phone side may reach, primary first.
    static var folders: [URL] { [folder, shortcutsFallbackFolder] }

    /// The user's choice, kept across launches. Starting the watcher itself is
    /// AppDelegate's job, so the toggle and the watching stay together there.
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "phoneSyncEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "phoneSyncEnabled") }
    }

    /// True when any of the watched containers exists (iCloud Drive signed
    /// in). Without it the toggle still works but cannot see anything.
    static var driveAvailable: Bool {
        var isDir: ObjCBool = false
        return folders.contains {
            FileManager.default.fileExists(
                atPath: $0.deletingLastPathComponent().path, isDirectory: &isDir)
                && isDir.boolValue
        }
    }
}
