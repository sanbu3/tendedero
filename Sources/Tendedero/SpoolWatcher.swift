import Foundation

/// Watches the spool folder where the `tendedero` CLI drops pointer files.
/// A pointer is a small text file named `*.tendedero` whose body is the
/// absolute path of the image or recording to hang. The original file never
/// moves: it hangs as an external file, so taking it down leaves it where it
/// was. The pointer is deleted once it has been read, whether or not the
/// target still exists (a gone file is silently dropped).
///
/// Images dropped into the spool folder directly also hang, as external files.
final class SpoolWatcher {
    /// `~/Library/Application Support/<identity>/Spool`
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(AppIdentity.supportFolderName)/Spool", isDirectory: true)
    }()

    static let pointerExtension = "tendedero"

    private let onPath: (URL) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    private var stopped = false

    init(onPath: @escaping (URL) -> Void) {
        self.onPath = onPath
    }

    /// Creates the folder if needed and starts watching. The folder is opened
    /// off the main thread, mirroring `ScreenshotWatcher.start()`.
    func start() {
        stopped = false
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fd = open(Self.folder.path, O_EVTONLY)
            DispatchQueue.main.async { self.watch(fd) }
        }
    }

    func stop() {
        stopped = true
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
    }

    private func watch(_ fd: Int32) {
        guard !stopped else {
            if fd >= 0 { close(fd) }
            return
        }
        guard fd >= 0 else {
            NSLog("Tendedero: cannot watch spool \(Self.folder.path)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleScan() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        drain()
    }

    private func scheduleScan() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.drain() }
        pending = work
        // The CLI writes the pointer in one go, but a tiny delay absorbs
        // partial writes and bursts of several files.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Reads every pointer and image currently in the spool. Pointers are
    /// deleted as they are read; direct images stay where they are, so the
    /// scan is deduplicated by what `Line.hang` accepts.
    private func drain() {
        guard !stopped else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in urls {
            if url.pathExtension.lowercased() == Self.pointerExtension {
                let body = (try? String(contentsOf: url, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? FileManager.default.removeItem(at: url)
                guard !body.isEmpty else { continue }
                let target = URL(fileURLWithPath: (body as NSString).expandingTildeInPath)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                onPath(target)
            } else if ScreenshotWatcher.isImageURL(url) {
                onPath(url)
            }
        }
    }
}
