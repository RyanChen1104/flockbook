import SwiftUI

enum AppSettings { static let allowInputKey = "allowInput" }

/// One grouped pane, like the Settings of Notes or Reminders: four settings do not fill toolbar tabs.
/// Each row says what it does in a secondary line under its title; the window is fixed-size.
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
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var widthNote: String {
        switch ReadingWidth(rawValue: readingWidth) ?? .medium {
        case .full: "The text fills the window."
        case let w: "Text column up to \(Int(w.points)) pt."
        }
    }
}
