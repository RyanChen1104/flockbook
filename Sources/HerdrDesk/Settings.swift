import SwiftUI

enum AppSettings { static let allowInputKey = "allowInput" }

/// One grouped pane, like the Settings of Notes or Reminders: four settings do not fill toolbar tabs.
/// Each row says what it does in a secondary line under its title. Shown as a page of the main window (SettingsPage).
struct SettingsView: View {
    @AppStorage(AppSettings.allowInputKey, store: AppDefaults.store) private var allowInput = true
    @AppStorage(WindowGlass.key, store: AppDefaults.store) private var glass = WindowGlass.full.rawValue
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    /// Snapshots only: stands in for the system's Reduce Transparency.
    var reduceTransparency: Bool? = nil
    private var reduce: Bool { reduceTransparency ?? systemReduce }
    @AppStorage(ReadingWidth.key, store: AppDefaults.store) private var readingWidth = ReadingWidth.medium.rawValue
    @AppStorage(ReadingSize.key, store: AppDefaults.store) private var readingSize = ReadingSize.m.rawValue
    private var readOnlyLaunch: Bool { CommandLine.arguments.contains("--read-only") }
    /// Nil: no Remote access section (snapshots of the other settings).
    var remote: RemoteHub? = nil
    /// The Settings page: fills the detail column and scrolls, so a long page (Remote access) never runs off the screen.
    /// Snapshots keep the full height at a fixed width.
    var scrolls = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker(selection: reduce ? .constant(WindowGlass.off.rawValue) : $glass) {
                    ForEach(WindowGlass.allCases) { Text($0.label).tag($0.rawValue) }
                } label: {
                    Text("Window")
                    Text(reduce ? "Opaque while Reduce Transparency is on in System Settings."
                                : "Glass lets the desktop show through, blurred.")
                }
                .pickerStyle(.segmented)
                .disabled(reduce)
                .probe { SettingsProbe.firstRow = $0 }
            }
            Section("Reading") {
                Picker(selection: $readingSize) {
                    ForEach(ReadingSize.allCases) { Text($0.label).tag($0.rawValue) }
                } label: {
                    Text("Text size")
                    Text("⌘= larger, ⌘− smaller, ⌘0 reset")
                }
                .pickerStyle(.segmented)
                Picker(selection: $readingWidth) {
                    ForEach(ReadingWidth.allCases) { Text($0.label).tag($0.rawValue) }
                } label: {
                    Text("Width")
                    Text(widthNote)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle(isOn: $allowInput) {
                    Text("Allow sending input to agents")
                    Text("Typing, Allow and Deny, new tab, close tab and split.")
                }
            } header: {
                Text("Input")
            } footer: {
                Label {
                    Text(readOnlyLaunch ? "Launched with --read-only: the app only reads, whatever this says."
                         : allowInput ? "Flockbook types into your agents' terminals. Turn this off to only read."
                                      : "Read only: typing, Allow and Deny, new tab, close tab and split are disabled.")
                } icon: {
                    Image(systemName: allowInput && !readOnlyLaunch ? "exclamationmark.triangle.fill" : "lock.fill")
                        .foregroundStyle(allowInput && !readOnlyLaunch ? .orange : .secondary)
                }
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let remote { RemoteAccessSection(hub: remote) }
            if let updates = AppUpdater.shared.updater {
                Section("Updates") {
                    Toggle(isOn: Binding(get: { AppUpdater.shared.automaticallyChecks },
                                         set: { AppUpdater.shared.automaticallyChecks = $0 })) {
                        Text("Check for updates automatically")
                        Text("Once a day. Flockbook asks before it installs an update.")
                    }
                    LabeledContent {
                        Button("Check Now") { AppUpdater.shared.checkForUpdates() }.disabled(!AppUpdater.shared.canCheck)
                    } label: {
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                        if let last = updates.lastUpdateCheckDate {
                            Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(!scrolls)
        // The window's surface shows through (Glass.swift); the grouped rows keep their own fill.
        .scrollContentBackground(.hidden)
        .frame(width: scrolls ? nil : 520)
        .frame(minHeight: scrolls ? 360 : nil, idealHeight: scrolls ? 640 : nil, maxHeight: scrolls ? .infinity : nil)
        .fixedSize(horizontal: false, vertical: !scrolls)
    }

    private var widthNote: String {
        switch ReadingWidth(rawValue: readingWidth) ?? .medium {
        case .full: "The text fills the window."
        case let w: "Text column up to \(Int(w.points)) pt."
        }
    }
}

/// Settings as a page of the main window (the sidebar's foot row, ⌘,): the whole detail column scrolls, so the wheel works
/// over the side margins too, and the rows keep a readable column in its middle.
struct SettingsPage: View {
    @Environment(AppModel.self) private var model
    @State private var width: CGFloat = 0
    /// Widest the grouped rows get.
    static let column: CGFloat = 640

    var body: some View {
        SettingsView(remote: model.remote, scrolls: true)
            .contentMargins(.horizontal, max(0, (width - Self.column) / 2), for: .scrollContent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .probe { SettingsProbe.page = $0 }
            .onDisappear { SettingsProbe.page = .zero }
    }
}
