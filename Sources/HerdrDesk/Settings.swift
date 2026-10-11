import SwiftUI

enum AppSettings { static let allowInputKey = "allowInput" }

struct SettingsView: View {
    @AppStorage(AppSettings.allowInputKey, store: AppDefaults.store) private var allowInput = true
    @AppStorage(WindowGlass.key, store: AppDefaults.store) private var glass = WindowGlass.full.rawValue
    @Environment(\.accessibilityReduceTransparency) private var systemReduce
    /// Snapshots only: stands in for the system's Reduce Transparency.
    var reduceTransparency: Bool? = nil
    private var reduce: Bool { reduceTransparency ?? systemReduce }
    @AppStorage(ReadingWidth.key, store: AppDefaults.store) private var readingWidth = ReadingWidth.medium.rawValue
    @AppStorage(ReadingSize.key, store: AppDefaults.store) private var readingSize = ReadingSize.m.rawValue
    var body: some View {
        Form {
            Section {
                Picker("Window", selection: $glass) {
                    ForEach(WindowGlass.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .disabled(reduce)
            } header: {
                Text("Appearance")
            } footer: {
                Text(reduce ? "Reduce Transparency is on in System Settings, so the window stays opaque."
                            : "Glass lets the desktop show through the whole window, blurred. Opaque shows none.")
            }
            Section {
                Picker("Text size", selection: $readingSize) {
                    ForEach(ReadingSize.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Width", selection: $readingWidth) {
                    ForEach(ReadingWidth.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Reading")
            } footer: {
                Text("Narrow 600 pt, Medium 760 pt, Wide 920 pt; Full fills the window. Text size also: ⌘= larger, ⌘- smaller, ⌘0 reset.")
            }
            Section {
                Toggle("Allow sending input to agents", isOn: $allowInput)
            } header: {
                Text("Input")
            } footer: {
                Text("When off, the app only reads: typing, Allow/Deny, new tab, close tab and split are disabled. Launching with --read-only forces this off.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
