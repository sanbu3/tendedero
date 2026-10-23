import Foundation

/// The app's identity, kept in one place so a development build can live
/// beside the official Tendedero without sharing preferences, screenshot
/// folders or the same window identity.
///
/// The build script sets the development bundle identifier ending in `.dev`.
/// Everything the official app owns keeps its original name and path.
enum AppIdentity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "app.tendedero.Tendedero"
    static let isDevelopment = bundleID.hasSuffix(".dev")
    static let supportFolderName = isDevelopment ? "Tendedero Dev" : "Tendedero"
    static let displayName = isDevelopment ? "Tendedero Dev" : "Tendedero"
}
