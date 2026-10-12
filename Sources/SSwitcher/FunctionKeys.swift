import AppKit
import IOKit
import IOKit.hidsystem
import SwitcherCore

/// What the top row sends without fn. The base mode is the system preference
/// (System Settings → Keyboard), written together with the live IOHIDSystem
/// parameter. Application rules change only the live parameter while the
/// application is frontmost, so the preference always holds the base mode.
final class FunctionKeyController: NSObject {
    var onChange: (() -> Void)?
    private(set) var policy: FunctionKeyPolicy
    private(set) var lastError: String?
    private let hotKey = FunctionKeyHotKey()
    private let hud = StatusHUD()
    private static let rulesKey = "functionKeyApplications"
    private static let preferenceKey = "com.apple.keyboard.fnState" as CFString

    override init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.rulesKey) as? [String: Int] ?? [:]
        policy = FunctionKeyPolicy(base: Self.preference, applications: stored.compactMapValues(FunctionKeyMode.init(rawValue:)))
        super.init()
        hotKey.onPress = { [weak self] in self?.shortcutPressed() }
    }

    func start() {
        hotKey.start()
        frontmostChanged()
    }

    /// Reapplies after an application switch. A change made in System
    /// Settings reaches the preference, which is reread as the base first.
    func frontmostChanged(_ app: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        policy.base = Self.preference
        apply(policy.mode(for: Self.bundleID(app)))
    }

    /// Leaves the live mode equal to the preference when SSwitcher quits.
    func restoreBase() {
        hotKey.stop()
        apply(Self.preference)
    }

    var statusDescription: String {
        let live = Self.live.map(Self.title) ?? "не прочитан"
        let rules = policy.applications.isEmpty ? "" : "; свой режим у программ: \(policy.applications.count)"
        let shortcut = hotKey.isRegistered ? "⌃⌥⌘F работает" : "⌃⌥⌘F не зарегистрировано"
        return "Верхний ряд: \(live) (везде: \(Self.title(policy.base))\(rules)); \(shortcut)" + (lastError.map { "; \($0)" } ?? "")
    }

    // MARK: Menu

    func menuItems(frontmost app: NSRunningApplication?) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let main = item("F1–F12 без fn", action: #selector(toggleBase))
        main.state = policy.base == .standard ? .on : .off
        main.keyEquivalent = "f"
        main.keyEquivalentModifierMask = [.control, .option, .command]
        main.toolTip = "Включено: F1–F12 работают сами, яркость и звук — с fn. Выключено: наоборот. ⌃⌥⌘F переключает режим в текущей программе"
        items.append(main)
        if let id = Self.bundleID(app) {
            let name = Self.name(of: id, fallback: app?.localizedName)
            let parent = item("Для «\(name)»: \(policy.rule(for: id).map(Self.title) ?? "как везде")")
            let submenu = NSMenu()
            let rule = policy.rule(for: id)
            for (title, mode) in [("Как везде", nil), ("F1–F12 без fn", FunctionKeyMode.standard), ("Яркость и звук без fn", .media)] {
                let choice = item(title, action: #selector(chooseRule(_:)))
                choice.representedObject = RuleChoice(bundleID: id, mode: mode)
                choice.state = rule == mode ? .on : .off
                submenu.addItem(choice)
            }
            parent.submenu = submenu
            items.append(parent)
        }
        if !policy.applications.isEmpty {
            let parent = item("Свой режим у программ: \(policy.applications.count)")
            let submenu = NSMenu()
            let rules = policy.applications.map { (id: $0.key, name: Self.name(of: $0.key), mode: $0.value) }
            for (id, name, mode) in rules.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
                let row = item("\(name): \(Self.title(mode))", action: #selector(chooseRule(_:)))
                row.representedObject = RuleChoice(bundleID: id, mode: nil)
                row.toolTip = "Нажмите, чтобы программа снова работала как везде"
                submenu.addItem(row)
            }
            submenu.addItem(.separator())
            submenu.addItem(item("Нажмите программу, чтобы убрать её режим"))
            parent.submenu = submenu
            items.append(parent)
        }
        if !hotKey.isRegistered { items.append(item("⌃⌥⌘F занято другой программой")) }
        if let lastError { items.append(item(lastError)) }
        return items
    }

    private final class RuleChoice: NSObject {
        let bundleID: String, mode: FunctionKeyMode?
        init(bundleID: String, mode: FunctionKeyMode?) { self.bundleID = bundleID; self.mode = mode }
    }

    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        return item
    }

    @objc private func toggleBase() {
        policy.base = Self.preference.toggled
        if Self.setPreference(policy.base) { frontmostChanged() }
        else { lastError = "Не удалось сохранить режим верхнего ряда" }
        onChange?()
    }

    @objc private func chooseRule(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? RuleChoice else { return }
        policy.setRule(choice.mode, for: choice.bundleID)
        saveRules()
        frontmostChanged()
        onChange?()
    }

    private func shortcutPressed() {
        let app = NSWorkspace.shared.frontmostApplication
        let id = Self.bundleID(app)
        policy.base = Self.preference
        let baseChanged = policy.toggle(for: id)
        if baseChanged { _ = Self.setPreference(policy.base) } else { saveRules() }
        apply(policy.mode(for: id))
        let mode = policy.mode(for: id)
        if lastError == nil, Self.live == mode {
            let scope = baseChanged ? "везде" : "в «\(Self.name(of: id ?? "", fallback: app?.localizedName))»"
            hud.show(Self.title(mode), detail: scope)
        } else {
            hud.show("Верхний ряд не переключился", detail: "Подробности в меню SSwitcher")
        }
        onChange?()
    }

    private func saveRules() {
        UserDefaults.standard.set(policy.applications.mapValues(\.rawValue), forKey: Self.rulesKey)
    }

    private func apply(_ mode: FunctionKeyMode) {
        if Self.live == mode { lastError = nil; return }
        lastError = Self.setLive(mode) ? nil : "Не удалось переключить верхний ряд"
    }

    // MARK: System

    private static func title(_ mode: FunctionKeyMode) -> String {
        mode == .standard ? "F1–F12 без fn" : "Яркость и звук без fn"
    }

    /// Only ordinary Dock applications get rules. SSwitcher itself and system
    /// agents such as loginwindow (frontmost while the screen is locked) use
    /// the base mode.
    private static func bundleID(_ app: NSRunningApplication?) -> String? {
        guard let app, app.activationPolicy == .regular, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return nil }
        return id
    }

    private static func name(of bundleID: String, fallback: String? = nil) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return fallback ?? bundleID
    }

    /// Missing preference means the macOS default: media keys.
    private static var preference: FunctionKeyMode {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let value = CFPreferencesCopyAppValue(preferenceKey, kCFPreferencesAnyApplication) as? Bool ?? false
        return value ? .standard : .media
    }

    private static func setPreference(_ mode: FunctionKeyMode) -> Bool {
        CFPreferencesSetValue(preferenceKey, (mode == .standard) as CFBoolean, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    private static var live: FunctionKeyMode? {
        withParameterConnection { connection in
            var value: Unmanaged<CFTypeRef>?
            guard IOHIDCopyCFTypeParameter(connection, kIOHIDFKeyModeKey as CFString, &value) == KERN_SUCCESS,
                  let number = value?.takeRetainedValue() as? NSNumber else { return nil }
            return FunctionKeyMode(rawValue: number.intValue)
        } ?? nil
    }

    private static func setLive(_ mode: FunctionKeyMode) -> Bool {
        withParameterConnection { connection in
            IOHIDSetCFTypeParameter(connection, kIOHIDFKeyModeKey as CFString, mode.rawValue as CFNumber) == KERN_SUCCESS
        } ?? false
    }

    private static func withParameterConnection<T>(_ body: (io_connect_t) -> T) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connection) }
        return body(connection)
    }
}
