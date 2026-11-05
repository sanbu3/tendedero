import SwiftUI

/// One place for everything that is not worth a line in the menu bar: where
/// screenshots go, how the line behaves, the shortcuts, and the odds and
/// ends. The menu bar keeps the actions you reach for every day.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?

    func show(for app: AppDelegate) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L("Tendedero Settings")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(app: app))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// Bumped after a change that other rows must see.
@MainActor
final class SettingsState: ObservableObject {
    func touch() { objectWillChange.send() }
}

@MainActor
struct SettingsView: View {
    let app: AppDelegate
    @StateObject private var state = SettingsState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                screenshots
                line
                shortcuts
                general
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 460, height: 580)
        .onAppear { state.touch() }
    }

    // MARK: Screenshots

    private var screenshots: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L("Screenshots"))
            row(L("Handle screenshots"), L("They skip the Desktop and hang at once")) {
                Toggle("", isOn: Binding(get: { Inbox.isEnabled },
                                         set: { app.settingsSetInbox($0); state.touch() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            row(L("Hang copied images"), L("Pictures copied anywhere hang on the line")) {
                Toggle("", isOn: Binding(get: { ClipboardWatcher.isEnabled },
                                         set: { app.settingsSetClipboard($0); state.touch() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            row(L("Sync iPhone screenshots"), L("From the shortcut in iCloud Drive/Tendedero")) {
                Toggle("", isOn: Binding(get: { PhoneSync.isEnabled },
                                         set: { app.settingsSetPhone($0); state.touch() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Also watch folders"))
                ForEach(AppDelegate.settingsExtraFolders, id: \.self) { folder in
                    HStack(spacing: 8) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(FileManager.default.displayName(atPath: folder.path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(L("Reveal")) { NSWorkspace.shared.open(folder) }
                            .buttonStyle(.link)
                        Button(L("Remove")) {
                            app.settingsRemoveFolder(folder)
                            state.touch()
                        }
                        .buttonStyle(.link)
                    }
                    .font(.callout)
                }
                HStack(spacing: 10) {
                    Button(L("Add Folder…")) {
                        app.settingsAddFolder()
                        state.touch()
                    }
                    .disabled(AppDelegate.settingsExtraFolders.count >= AppDelegate.settingsMaxExtraFolders)
                    Button(L("Open screenshots folder")) { app.settingsOpenScreenshotsFolder() }
                        .buttonStyle(.link)
                    Spacer()
                }
                .font(.callout)
            }
            .padding(.top, 2)
        }
    }

    // MARK: The line

    private var line: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L("The line"))
            row(L("When the pointer rests at the top center")) {
                Toggle("", isOn: Binding(get: { AppDelegate.opensFromTopCenter },
                                         set: { AppDelegate.opensFromTopCenter = $0; state.touch() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            row(L("When something new hangs"), L("It shows itself for a moment")) {
                Toggle("", isOn: Binding(get: { AppDelegate.peeksAtNew },
                                         set: { AppDelegate.peeksAtNew = $0; state.touch() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            row(L("Over full screen apps")) {
                Toggle("", isOn: Binding(get: { FullScreen.showLineOver },
                                         set: { FullScreen.showLineOver = $0; app.settingsRefresh(); state.touch() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            row(L("Sounds")) {
                Toggle("", isOn: Binding(get: { app.settingsLine.soundOn },
                                         set: { app.settingsLine.soundOn = $0; state.touch() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            row(L("Click copies"), L("When off, a click previews and a double click copies")) {
                Toggle("", isOn: Binding(get: { app.settingsLine.clickCopies },
                                         set: { app.settingsLine.clickCopies = $0; state.touch() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            row(L("Keep on line")) {
                Picker("", selection: Binding(
                    get: { Line.keepOnLine ?? 0 },
                    set: { app.settingsSetKeep($0 == 0 ? nil : $0); state.touch() })) {
                    Text(L("As many as fit")).tag(0)
                    ForEach(Line.keepChoices, id: \.self) { n in
                        Text(String(format: L("%d photos"), n)).tag(n)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
            row(L("Size")) {
                Picker("", selection: Binding(
                    get: { Layout.size },
                    set: { app.settingsSetSize($0); state.touch() })) {
                    Text(L("Small")).tag(Layout.Size.small)
                    Text(L("Medium")).tag(Layout.Size.medium)
                    Text(L("Large")).tag(Layout.Size.large)
                }
                .labelsHidden()
                .frame(width: 170)
            }
            row(L("Hold to make it a file")) {
                Picker("", selection: Binding(
                    get: { Held.holdDelay },
                    set: { Held.holdDelay = $0; state.touch() })) {
                    ForEach(Held.holdChoices, id: \.self) { seconds in
                        Text(String(format: L("%.1f s"), seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
                .frame(width: 170)
            }
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L("Shortcuts"))
            row(L("Show the line"), Shortcut.current?.display ?? L("None")) {
                Button(L("Change…")) {
                    app.settingsChangeShortcut(.showLine)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { state.touch() }
                }
            }
            row(L("Delete hovered photo"), Shortcut.deleteHovered?.display ?? L("None")) {
                Button(L("Change…")) {
                    app.settingsChangeShortcut(.deleteHovered)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { state.touch() }
                }
            }
        }
    }

    // MARK: General

    private var general: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L("General"))
            row(L("Open at login")) {
                Toggle("", isOn: Binding(get: { AppDelegate.settingsLaunchAtLogin() },
                                         set: { _ in AppDelegate.settingsToggleLaunchAtLogin(); state.touch() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            row(L("Version"), Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") {
                Button(L("Check for Updates…")) {
                    NSWorkspace.shared.open(AppDelegate.settingsUpdatesURL)
                }
                .buttonStyle(.link)
            }
        }
    }

    // MARK: Pieces

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.bottom, 2)
    }

    private func row<Control: View>(_ title: String, _ note: String? = nil,
                                    @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            control()
        }
    }
}
