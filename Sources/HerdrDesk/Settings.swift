import HerdrKit
import SwiftUI
import SwiftTerm

enum AppSettings { static let allowInputKey = "allowInput" }

/// One tab of Settings as a grouped form, like a pane of System Settings. Each row says what it does in a secondary line
/// under its title. The tabs and the rows each holds: `SettingsTab` (HerdrKit). Shown beside the tab list (SettingsSplit).
struct SettingsView: View {
    var tab: SettingsTab = .general
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
    /// The Settings page: fills its column and scrolls, so a long page (Remote access) never runs off the screen.
    /// Snapshots keep the full height at a fixed width.
    var scrolls = false

    var body: some View {
        Form {
            switch tab {
            case .general: general
            case .agents: agents
            case .remote: if let remote { RemoteAccessSection(hub: remote) }
            case .updates: updates
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

    @ViewBuilder private var general: some View {
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
            .settingsControl(.window)
        }
        Section("Reading") {
            Picker(selection: $readingSize) {
                ForEach(ReadingSize.allCases) { Text($0.label).tag($0.rawValue) }
            } label: {
                Text("Text size")
                Text("⌘= larger, ⌘− smaller, ⌘0 reset")
            }
            .pickerStyle(.segmented)
            .settingsControl(.textSize)
            Picker(selection: $readingWidth) {
                ForEach(ReadingWidth.allCases) { Text($0.label).tag($0.rawValue) }
            } label: {
                Text("Width")
                Text(widthNote)
            }
            .pickerStyle(.segmented)
            .settingsControl(.readingWidth)
        }
    }

    @ViewBuilder private var agents: some View {
        Section {
            Toggle(isOn: $allowInput) {
                Text("Allow sending input to agents")
                Text("Typing, Allow and Deny, new tab, close tab and split.")
            }
            .settingsControl(.allowInput)
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
        // The question hook serves the phone: shown while Remote access is on, as before.
        if let remote, remote.enabled {
            Section("Claude Code") {
                ClaudeHookRow(setup: remote.claudeHook).settingsControl(.claudeQuestions)
            }
        }
    }

    @ViewBuilder private var updates: some View {
        Section("Updates") {
            if AppUpdater.shared.updater != nil {
                Toggle(isOn: Binding(get: { AppUpdater.shared.automaticallyChecks },
                                     set: { AppUpdater.shared.automaticallyChecks = $0 })) {
                    Text("Check for updates automatically")
                    Text("Once a day. Flockbook asks before it installs an update.")
                }
                .settingsControl(.autoUpdate)
            }
            LabeledContent {
                if AppUpdater.shared.updater != nil {
                    Button("Check Now") { AppUpdater.shared.checkForUpdates() }.disabled(!AppUpdater.shared.canCheck)
                }
            } label: {
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                if let last = AppUpdater.shared.updater?.lastUpdateCheckDate {
                    Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                } else if AppUpdater.shared.updater == nil {
                    // A build from source or a check run: Sparkle is off (UpdaterGate), so the tab says why it has no switch.
                    Text("This build does not update itself.")
                }
            }
            .settingsControl(.version)
        }
    }

    private var widthNote: String {
        switch ReadingWidth(rawValue: readingWidth) ?? .medium {
        case .full: "The text fills the window."
        case let w: "Text column up to \(Int(w.points)) pt."
        }
    }
}

/// Settings: the tab list on the left, the chosen tab's form on the right, like System Settings. Opens on the tab
/// chosen last (`SettingsTab.key`). `fixed`: snapshots show that tab and leave the remembered one alone. `list` false: the
/// form alone (the page while the window's sidebar holds the tabs); `back`: a Back row above the tabs.
struct SettingsSplit: View {
    @AppStorage(SettingsTab.key, store: AppDefaults.store) private var stored = SettingsTab.general.rawValue
    var fixed: SettingsTab? = nil
    var remote: RemoteHub? = nil
    var scrolls = false
    var reduceTransparency: Bool? = nil
    var list = true
    var back: (() -> Void)? = nil
    /// Widest the form gets; wider columns centre it.
    static let column: CGFloat = 640
    static let listWidth: CGFloat = 196
    @State private var width: CGFloat = 0

    private var tab: SettingsTab { fixed ?? SettingsTab(stored: stored) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if list {
                SettingsTabList(selection: Binding(get: { tab }, set: { if fixed == nil { stored = $0.rawValue } }), back: back)
                    .frame(width: Self.listWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .probe { SettingsProbe.pageList = $0 }
                    .onDisappear { SettingsProbe.pageList = .zero }
                Divider()
            }
            SettingsView(tab: tab, reduceTransparency: reduceTransparency, remote: remote, scrolls: scrolls)
                .contentMargins(.horizontal, scrolls ? max(0, (width - Self.column) / 2) : 0, for: .scrollContent)
                .frame(maxWidth: scrolls ? .infinity : nil, maxHeight: scrolls ? .infinity : nil, alignment: .top)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .probe { SettingsProbe.content = $0 }
                .id(tab)
        }
        .frame(minHeight: scrolls ? nil : 420, alignment: .top)
    }
}

/// The tabs as the window sidebar draws them (`SettingsSidebar`): the line symbol and the name, the chosen row on a light
/// grey fill. Shown in the page only while the window sidebar is hidden.
struct SettingsTabList: View {
    @Binding var selection: SettingsTab
    var back: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let back {
                Button(action: back) {
                    SidebarLine(title: "Back", symbol: "chevron.left").padding(.horizontal, 8).frame(height: 30)
                }
                .buttonStyle(.plain)
                .help("Back (Esc)")
                .probe { SettingsProbe.back = $0 }
                .onDisappear { SettingsProbe.back = .zero }
                .padding(.bottom, 6)
            }
            Text("Settings").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(SettingsTab.allCases) { t in
                let on = t == selection
                Button { selection = t } label: {
                    SidebarLine(title: t.title, symbol: t.symbol)
                        .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                .probe { SettingsProbe.tabs[t] = $0 }
            }
        }
        .padding(.horizontal, 10).padding(.top, 12)
    }
}

/// Settings as a page of the main window (the sidebar's foot row, ⌘,): the form fills the detail column, and the window's
/// sidebar holds Back and the tabs (`SettingsSidebar`). With the sidebar hidden the page brings that list itself. The form
/// scrolls, so the wheel works over its side margins too, and its rows keep a readable column in the middle. Esc goes back.
struct SettingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let own = model.sidebarVisibility == .detailOnly
        SettingsSplit(remote: model.remote, scrolls: true, list: own, back: own ? { model.closeSettings() } : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Button("Back") { model.closeSettings() }.keyboardShortcut(.cancelAction).hidden() }
            .probe { SettingsProbe.page = $0 }
            .onDisappear { SettingsProbe.page = .zero }
    }
}

extension View {
    /// Marks a Settings row: checks find each control's frame (and so its tab) in `SettingsProbe.controls`.
    func settingsControl(_ c: SettingsControl) -> some View {
        probe { SettingsProbe.controls[c] = $0 }
            .onDisappear { SettingsProbe.controls[c] = nil }
    }
}

/// Keys while Settings shows go to Settings, not to the hidden screen under it: opening it takes the window's first
/// responder (the composer, say) away and keeps it; Back gives that same responder its focus again. While it shows, a
/// typing view that takes the focus anyway (a fresh session focuses its composer, a focused pane its terminal, Tab walks
/// the key views) loses it again at once: keys typed there would go to an agent no one sees.
struct SettingsFocus: NSViewRepresentable {
    let open: Bool
    final class Coordinator { weak var saved: NSResponder?; var open = false; var watch: NSKeyValueObservation? }
    static func typing(_ r: NSResponder?) -> Bool { r is NSText || r is TerminalView }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        guard open != c.open else { return }
        c.open = open
        guard let win = view.window else { return }
        if open {
            c.saved = win.firstResponder === win ? nil : win.firstResponder
            win.makeFirstResponder(nil)
            c.watch = win.observe(\.firstResponder, options: [.new]) { [weak c] win, _ in
                MainActor.assumeIsolated {
                    guard Self.typing(win.firstResponder) else { return }
                    // Not inside the responder change; and not after Back, which gives the focus back on purpose.
                    DispatchQueue.main.async { [weak win, weak c] in
                        if let win, c?.open == true, Self.typing(win.firstResponder) { win.makeFirstResponder(nil) }
                    }
                }
            }
            return
        }
        c.watch?.invalidate(); c.watch = nil
        if let saved = c.saved {
            c.saved = nil
            // After this update: the screen under Settings is enabled again first.
            DispatchQueue.main.async { [weak win, weak saved] in
                guard let win, let saved, (saved as? NSView)?.window === win else { return }
                win.makeFirstResponder(saved)
            }
        }
    }
}
