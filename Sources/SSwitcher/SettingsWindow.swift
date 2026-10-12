import AppKit
import ServiceManagement
import SwiftUI
import SwitcherCore

enum SettingsTab: Int, CaseIterable {
    case general, layout, windows, displays, keyboard, mouse, keepAwake, check

    var title: String {
        switch self {
        case .general: return "Основные"
        case .layout: return "Раскладка"
        case .windows: return "Окна"
        case .displays: return "Дисплеи"
        case .keyboard: return "Клавиатура"
        case .mouse: return "Мышь"
        case .keepAwake: return "Не засыпать"
        case .check: return "Проверка"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .layout: return "character.cursor.ibeam"
        case .windows: return "macwindow.on.rectangle"
        case .displays: return "display"
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .keepAwake: return "cup.and.saucer"
        case .check: return "stethoscope"
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
    @Published var lastAttempt = ""
    @Published var lastResult = ""
    @Published var diagnostics = ""
}

/// Calls from the panes back into the app.
struct SettingsActions {
    var requestAccessibility: () -> Void
    var requestInputMonitoring: () -> Void
    var requestScreenCapture: () -> Void
    var toggleLogin: () -> Void
    var openLoginSettings: () -> Void
    var openTestWindow: () -> Void
    var copyReport: () -> Void
    var stopKeepAwake: () -> Void
    /// While a shortcut field records, SSwitcher's own shortcuts are removed
    /// so pressing the current combination records it instead of acting.
    var recordingShortcut: (Bool) -> Void
    /// Each returns true when nothing else uses the choice or the user takes it anyway.
    var confirmShortcut: (KeyShortcut) -> Bool
    var confirmTrigger: (TriggerKey) -> Bool
    var confirmWindowModifiers: (KeyShortcut.Modifiers) -> Bool
}

private final class SettingsTabsController: NSTabViewController {
    var onSelect: ((SettingsTab) -> Void)?

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let item = tabViewItem, let tab = SettingsTab(rawValue: tabView.indexOfTabViewItem(item)) else { return }
        view.window?.title = tab.title
        onSelect?(tab)
    }
}

/// A standard macOS settings window: a toolbar of panes, the window title
/// following the selected pane, the last pane remembered.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onVisibilityChange: ((Bool) -> Void)?
    var onTabChange: ((SettingsTab) -> Void)?
    private let tabs = SettingsTabsController()
    /// Stored by name: the integer index of earlier builds shifted when tabs were reordered.
    private static let tabKey = "settingsPane"

    init(settings: AppSettings, status: SettingsStatus, functionKeys: FunctionKeyController, displays: DisplayController,
         mouse: MouseController,
         actions: SettingsActions) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsPanes.width, height: SettingsPanes.height),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        super.init(window: window)
        window.delegate = self
        tabs.tabStyle = .toolbar
        // One size for every pane and an instant switch, as in System
        // Settings: resizing the window per pane made the content jump.
        tabs.transitionOptions = []
        for tab in SettingsTab.allCases {
            let pane = SettingsPanes(tab: tab, settings: settings, status: status, functionKeys: functionKeys,
                                     displays: displays, mouse: mouse, actions: actions)
            let host = NSHostingController(rootView: pane)
            host.title = tab.title
            host.sizingOptions = []
            host.preferredContentSize = NSSize(width: SettingsPanes.width, height: SettingsPanes.height)
            let item = NSTabViewItem(viewController: host)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        window.contentViewController = tabs
        tabs.onSelect = { [weak self] tab in
            UserDefaults.standard.set("\(tab)", forKey: Self.tabKey)
            self?.onTabChange?(tab)
        }
        let stored = UserDefaults.standard.string(forKey: Self.tabKey)
        let saved = SettingsTab.allCases.first { "\($0)" == stored } ?? .general
        tabs.selectedTabViewItemIndex = saved.rawValue
        window.title = saved.title
        window.setFrameAutosaveName("SSwitcherSettingsWindow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isVisible: Bool { window?.isVisible == true }
    var selectedTab: SettingsTab? { SettingsTab(rawValue: tabs.selectedTabViewItemIndex) }

    func show(_ tab: SettingsTab? = nil) {
        if let tab { tabs.selectedTabViewItemIndex = tab.rawValue }
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
