import Foundation

/// tendedero — hang files on the running Tendedero line from the terminal.
///
/// It writes pointer files (`.tendedero`, containing an absolute path) into
/// the app's spool folder. The app watches the spool, hangs the referenced
/// file as an external file — taking it down never deletes the original —
/// and removes the pointer. The file itself never moves or is copied, so
/// this works for any size and stays purely local.
///
/// Usage:
///   tendedero hang FILE...          hang one or more files
///   tendedero hang --dir DIR        hang every image in a folder (non-recursive)
///   tendedero list                  print the spool folder path
///
/// Pointers referencing the official Tendedero (not this dev build) can be
/// written with --app official.

let args = CommandLine.arguments.dropFirst()
var appFolder = "Tendedero Dev"
var index = args.startIndex
var positional: [String] = []
var mode = ""
var dirMode = false

while index < args.endIndex {
    let a = args[index]
    switch a {
    case "hang", "list":
        if mode.isEmpty { mode = a } else { fail("only one command per run") }
    case "--dir":
        dirMode = true
    case "--app":
        index += 1
        guard index < args.endIndex else { fail("--app needs a value: official|dev") }
        appFolder = args[index] == "official" ? "Tendedero" : "Tendedero Dev"
    case "-h", "--help":
        print(helpText)
        exit(0)
    default:
        positional.append(a)
    }
    index += 1
}

guard !mode.isEmpty else {
    fputs(helpText + "\n", stderr)
    exit(2)
}

let fm = FileManager.default
let spool = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("\(appFolder)/Spool", isDirectory: true)

switch mode {
case "list":
    print(spool.path)
    exit(0)
default:
    break
}

guard !positional.isEmpty else { fail("hang needs at least one file or, with --dir, a folder") }

try fm.createDirectory(at: spool, withIntermediateDirectories: true)

var targets: [URL] = []
for raw in positional {
    let path = NSString(string: raw).expandingTildeInPath
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
        fputs("tendedero: no such file: \(url.path)\n", stderr)
        continue
    }
    if isDir.boolValue || dirMode {
        let folder = isDir.boolValue ? url : URL(fileURLWithPath: path)
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        targets.append(contentsOf: urls.filter(ScreenshotExtensions.isImage))
    } else {
        targets.append(url)
    }
}

var hung = 0
for (i, target) in targets.enumerated() {
    // Unique pointer name: two runs in the same millisecond must not collide.
    let pointer = spool.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000))-\(i)-\(UUID().uuidString.prefix(8)).tendedero")
    do {
        try target.path.write(to: pointer, atomically: true, encoding: .utf8)
        hung += 1
    } catch {
        fputs("tendedero: cannot write pointer: \(error.localizedDescription)\n", stderr)
    }
}
print("\(hung) file\(hung == 1 ? "" : "s") sent to \(appFolder)")
exit(hung == 0 && !targets.isEmpty ? 1 : 0)

func fail(_ message: String) -> Never {
    fputs("tendedero: \(message)\n", stderr)
    exit(2)
}

let helpText = """
    tendedero — hang files on the running Tendedero line.

    Usage:
      tendedero hang FILE...       hang one or more files
      tendedero hang --dir DIR     hang every image directly inside DIR
      tendedero list               print the spool folder path

    Options:
      --app official|dev           which Tendedero to target (default: dev)
      -h, --help                   show this help
    """

enum ScreenshotExtensions {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "webp"]
    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }
}
