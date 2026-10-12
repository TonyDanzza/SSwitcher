import AppKit
import IOKit
import IOKit.hidsystem
import SwitcherCore

/// What the top row sends without fn. The base mode is the system preference
/// (System Settings → Keyboard), written together with the live IOHIDSystem
/// parameter. Application rules change only the live parameter while the
/// application is frontmost, so the preference always holds the base mode.
final class FunctionKeyController: NSObject, ObservableObject {
    var onChange: (() -> Void)?
    @Published private(set) var policy: FunctionKeyPolicy
    @Published private(set) var lastError: String?
    private let hotKey = GlobalHotKey(signature: 0x5353464E) // SSFN
    private static let rulesKey = "functionKeyApplications"
    private static let preferenceKey = "com.apple.keyboard.fnState" as CFString

    override init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.rulesKey) as? [String: Int] ?? [:]
        policy = FunctionKeyPolicy(base: Self.preference, applications: stored.compactMapValues(FunctionKeyMode.init(rawValue:)))
        super.init()
        hotKey.onPress = { [weak self] in self?.shortcutPressed() }
    }

    var shortcut: KeyShortcut? { hotKey.shortcut }
    var isShortcutBlocked: Bool { hotKey.isBlocked }

    func start(shortcut: KeyShortcut?) {
        hotKey.start(shortcut)
        frontmostChanged()
    }

    /// nil removes the shortcut (also while Settings records a new one).
    func setShortcut(_ shortcut: KeyShortcut?) {
        hotKey.start(shortcut)
        objectWillChange.send()
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
        let shortcut: String
        if let value = hotKey.shortcut { shortcut = KeyNames.string(value) + (hotKey.isRegistered ? " работает" : " не зарегистрировано") }
        else { shortcut = "сочетание не задано" }
        return "Верхний ряд: \(live) (везде: \(Self.title(policy.base))\(rules)); \(shortcut)" + (lastError.map { "; \($0)" } ?? "")
    }

    // MARK: Settings

    var baseMode: FunctionKeyMode {
        get { policy.base }
        set { setBase(newValue) }
    }

    /// Rules sorted by application name, for the Settings table.
    var rules: [(id: String, name: String, mode: FunctionKeyMode)] {
        policy.applications.map { (id: $0.key, name: AppIdentity.name(of: $0.key), mode: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setRule(_ mode: FunctionKeyMode?, for bundleID: String) {
        policy.setRule(mode, for: bundleID)
        saveRules()
        frontmostChanged()
        onChange?()
    }

    private func setBase(_ mode: FunctionKeyMode) {
        policy.base = mode
        if Self.setPreference(mode) { frontmostChanged() }
        else { lastError = "Не удалось сохранить режим верхнего ряда" }
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
            let scope = baseChanged ? "везде" : "в «\(AppIdentity.name(of: id ?? "", fallback: app?.localizedName))»"
            StatusHUD.shared.show(Self.title(mode), detail: scope)
        } else {
            StatusHUD.shared.show("Верхний ряд не переключился", detail: "Подробности в настройках SSwitcher", force: true)
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

    static func title(_ mode: FunctionKeyMode) -> String {
        mode == .standard ? "F1–F12 без fn" : "Яркость и звук без fn"
    }

    /// Only ordinary Dock applications get rules. SSwitcher itself and system
    /// agents such as loginwindow (frontmost while the screen is locked) use
    /// the base mode.
    static func bundleID(_ app: NSRunningApplication?) -> String? {
        guard let app, app.activationPolicy == .regular, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return nil }
        return id
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
