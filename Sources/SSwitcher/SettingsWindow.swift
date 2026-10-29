import AppKit
import Combine
import ServiceManagement
import SwiftUI
import SwitcherCore

enum SettingsTab: Int, CaseIterable {
    case general, layout, windows, keepAwake, displays, keyboard, mouse

    /// Sidebar groups, separated by space as in System Settings: the app,
    /// what it does, the devices it adjusts.
    static let groups: [[SettingsTab]] = [[.general], [.layout, .windows, .keepAwake], [.displays, .keyboard, .mouse]]

    var title: String {
        switch self {
        case .general: return "Основные"
        case .layout: return "Раскладка"
        case .windows: return "Окна"
        case .displays: return "Дисплеи"
        case .keyboard: return "Клавиатура"
        case .mouse: return "Мышь"
        case .keepAwake: return "Не засыпать"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .layout: return "globe"
        case .windows: return "macwindow.on.rectangle"
        case .displays: return "display"
        case .keyboard: return "keyboard.fill"
        case .mouse: return "computermouse.fill"
        case .keepAwake: return "cup.and.saucer.fill"
        }
    }

    /// The icon tile colour. Hardware panes are grey, as in System Settings.
    var tint: Color {
        switch self {
        case .general, .keyboard, .mouse: return .gray
        case .layout: return .blue
        case .windows: return .indigo
        case .displays: return .cyan
        case .keepAwake: return .orange
        }
    }
}

/// What the panes show but do not own: permissions, displays, results.
/// The app refreshes it while the window is visible.
final class SettingsStatus: ObservableObject {
    struct Display: Equatable, Identifiable {
        let id: UInt32
        let name: String
        /// AppKit coordinates (origin at the bottom left of the main display).
        let frame: CGRect
        let isMain: Bool
    }

    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var screenCapture = false
    @Published var loginStatus: SMAppService.Status = .notRegistered
    @Published var loginChanging = false
    @Published var loginError: String?
    @Published var displays: [Display] = []
    @Published var availableDirections: Set<WindowMoveDirection> = []
    @Published var windowShortcutProblem: String?
    @Published var lastWindowResult = ""
    @Published var functionShortcutBlocked = false
    @Published var keepAwakeShortcutBlocked = false
    @Published var keepAwakeStatus = ""
    @Published var keepAwakeActive = false
    @Published var hasBattery = false
}

/// Calls from the panes back into the app.
struct SettingsActions {
    var requestAccessibility: () -> Void
    var requestInputMonitoring: () -> Void
    var requestScreenCapture: () -> Void
    var toggleLogin: () -> Void
    var openLoginSettings: () -> Void
    var stopKeepAwake: () -> Void
    /// While a shortcut field records, SSwitcher's own shortcuts are removed
    /// so pressing the current combination records it instead of acting.
    var recordingShortcut: (Bool) -> Void
    /// Each returns true when nothing else uses the choice or the user takes it anyway.
    var confirmShortcut: (KeyShortcut) -> Bool
    var confirmTrigger: (TriggerKey) -> Bool
    var confirmWindowModifiers: (KeyShortcut.Modifiers) -> Bool
}

/// The selected pane, shared by the sidebar and the window controller.
private final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab
    init(_ tab: SettingsTab) { self.tab = tab }
}

private struct SettingsSidebar: View {
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        List(selection: Binding(get: { selection.tab }, set: { if let tab = $0 { selection.tab = tab } })) {
            ForEach(SettingsTab.groups, id: \.self) { group in
                Section {
                    ForEach(group, id: \.self) { tab in
                        Label { Text(tab.title) } icon: { PaneIcon(tab: tab) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The selected pane, rebuilt on every switch so it opens scrolled to the top.
private struct SettingsContent: View {
    @ObservedObject var selection: SettingsSelection
    let pane: (SettingsTab) -> SettingsPanes

    var body: some View {
        pane(selection.tab).id(selection.tab)
    }
}

/// A white glyph on a coloured rounded square, like System Settings icons.
private struct PaneIcon: View {
    let tab: SettingsTab
    @Environment(\.sidebarRowSize) private var rowSize

    /// The tile follows the sidebar icon size chosen in System Settings → Appearance.
    private var side: CGFloat {
        switch rowSize {
        case .small: return 16
        case .large: return 24
        default: return 20
        }
    }

    var body: some View {
        // Every glyph is fitted into the same box, so wide (keyboard) and tall
        // (mouse) symbols keep an even margin to the tile edge, as Apple's do.
        Image(systemName: tab.symbol)
            .resizable()
            .scaledToFit()
            .fontWeight(.semibold)
            .frame(width: side * 0.64, height: side * 0.64)
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(tab.tint.gradient, in: RoundedRectangle(cornerRadius: side * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }
}

/// A macOS settings window like System Settings: panes in a sidebar on the
/// left, the window title following the selected pane, the last pane remembered.
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    var onVisibilityChange: ((Bool) -> Void)?
    var onTabChange: ((SettingsTab) -> Void)?
    private let selection: SettingsSelection
    private var selectionWatch: AnyCancellable?
    /// Stored by name: the integer index of earlier builds shifted when tabs were reordered.
    private static let tabKey = "settingsPane"
    private static let sidebarWidth: CGFloat = 215
    /// The unified toolbar the panes sit under.
    private static let toolbarHeight: CGFloat = 52

    init(settings: AppSettings, status: SettingsStatus, functionKeys: FunctionKeyController, displays: DisplayController,
         mouse: MouseController,
         actions: SettingsActions) {
        let stored = UserDefaults.standard.string(forKey: Self.tabKey)
        let saved = SettingsTab.allCases.first { "\($0)" == stored } ?? .general
        selection = SettingsSelection(saved)
        let size = NSSize(width: Self.sidebarWidth + SettingsPanes.width, height: Self.toolbarHeight + SettingsPanes.height)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        let toolbar = NSToolbar(identifier: "SSwitcherSettings")
        toolbar.delegate = self
        window.toolbar = toolbar

        // One size for every pane and an instant switch, as in System
        // Settings: resizing the window per pane made the content jump.
        // One hosting view for all panes, so each form scrolls under the toolbar.
        let content = NSHostingController(rootView: SettingsContent(selection: selection) { tab in
            SettingsPanes(tab: tab, settings: settings, status: status, functionKeys: functionKeys,
                          displays: displays, mouse: mouse, actions: actions)
        })
        content.sizingOptions = []

        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: SettingsSidebar(selection: selection)))
        sidebar.canCollapse = false
        sidebar.minimumThickness = Self.sidebarWidth
        sidebar.maximumThickness = Self.sidebarWidth
        let split = NSSplitViewController()
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        window.contentViewController = split
        window.setContentSize(size)
        window.title = saved.title
        // A new name: frames saved for the narrower toolbar window would cut the panes.
        window.setFrameAutosaveName("SSwitcherSettingsSidebarWindow")

        selectionWatch = selection.$tab.removeDuplicates().dropFirst().sink { [weak self] tab in
            guard let self else { return }
            self.window?.title = tab.title
            UserDefaults.standard.set("\(tab)", forKey: Self.tabKey)
            onTabChange?(tab)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isVisible: Bool { window?.isVisible == true }

    func show(_ tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window?.isVisible != true { window?.center() }
        onVisibilityChange?(true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
        onVisibilityChange?(false)
    }

    // The separator keeps the title over the pane, to the right of the sidebar.
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebarTrackingSeparator] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebarTrackingSeparator] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }
}

/// The app menu, Edit and Window menus, shown while Settings put SSwitcher in
/// the Dock. Edit commands also make Copy and Paste work in text fields.
enum AppMainMenu {
    static func install(target: AnyObject, settings: Selector, about: Selector) {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "SSwitcher")
        let aboutItem = app.addItem(withTitle: "О программе SSwitcher", action: about, keyEquivalent: "")
        aboutItem.target = target
        app.addItem(.separator())
        let settingsItem = app.addItem(withTitle: "Настройки…", action: settings, keyEquivalent: ",")
        settingsItem.target = target
        app.addItem(.separator())
        app.addItem(withTitle: "Скрыть SSwitcher", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Завершить SSwitcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Правка")
        for (title, action, key) in [("Отменить", "undo:", "z"), ("Повторить", "redo:", "Z"), ("", "", ""),
                                     ("Вырезать", "cut:", "x"), ("Скопировать", "copy:", "c"),
                                     ("Вставить", "paste:", "v"), ("Выделить всё", "selectAll:", "a")] {
            if title.isEmpty { edit.addItem(.separator()); continue }
            edit.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Окно")
        window.addItem(withTitle: "Свернуть", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Закрыть", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }
}
