import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import SwitcherCore

/// Keeps the display, and so the Mac, awake with one power assertion (or only
/// the Mac, when Settings say the display may sleep). A timed
/// assertion carries its own timeout, so macOS releases it on time even if
/// SSwitcher stops; the timer here only clears the menu and the icon mark.
/// Nothing is restored after a relaunch.
final class KeepAwakeController: NSObject {
    var onChange: (() -> Void)?
    private var assertion = IOPMAssertionID(0)
    private(set) var endDate: Date?
    private var minutes: Int?
    private(set) var lastResult: String?
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var wasOnBattery = false
    private let hotKey = GlobalHotKey(signature: 0x53534B41) // SSKA
    private let settings = AppSettings.shared
    private static let customKey = "keepAwakeCustomMinutes"

    var isActive: Bool { assertion != 0 }
    var isShortcutBlocked: Bool { hotKey.isBlocked }

    override init() {
        super.init()
        hotKey.onPress = { [weak self] in self?.shortcutPressed() }
    }

    /// nil removes the shortcut (also while Settings records a new one).
    func setShortcut(_ shortcut: KeyShortcut?) { hotKey.start(shortcut) }

    private func shortcutPressed() {
        if isActive {
            stop()
            StatusHUD.shared.show("Не засыпать выключено", detail: "Mac снова засыпает как обычно")
            return
        }
        let minutes = settings.keepAwakeShortcutMinutes
        start(minutes: minutes > 0 ? minutes : nil)
        if isActive {
            StatusHUD.shared.show("Не засыпать", detail: minutes > 0 ? KeepAwakeDuration.title(minutes: minutes) : "пока не выключите")
        } else {
            StatusHUD.shared.show("Не засыпать не включилось", detail: lastResult ?? "", force: true)
        }
    }

    func start(minutes: Int?) {
        release()
        let battery = Self.battery
        guard KeepAwakeBatteryRule.allows(onBattery: battery.onBattery, percent: battery.percent, minimum: settings.keepAwakeBatteryPercent) else {
            lastResult = "Не включено: заряд ниже \(settings.keepAwakeBatteryPercent)%, подключите зарядку"
            onChange?()
            return
        }
        var properties: [String: Any] = [
            kIOPMAssertionTypeKey: settings.keepAwakeSystemOnly
                ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
            kIOPMAssertionNameKey: settings.keepAwakeSystemOnly ? "SSwitcher: keep Mac awake" : "SSwitcher: keep display awake"
        ]
        if let minutes {
            properties[kIOPMAssertionTimeoutKey] = minutes * 60
            properties[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionRelease
        }
        var identifier = IOPMAssertionID(0)
        guard IOPMAssertionCreateWithProperties(properties as CFDictionary, &identifier) == kIOReturnSuccess, identifier != 0 else {
            lastResult = "macOS не разрешила держать экран включённым"
            onChange?()
            return
        }
        assertion = identifier
        self.minutes = minutes
        lastResult = nil
        if let minutes {
            let end = Date().addingTimeInterval(Double(minutes) * 60)
            endDate = end
            let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in self?.expireIfDue() }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            // Timers do not count time asleep; a wake past the end clears it.
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.expireIfDue() }
        }
        wasOnBattery = battery.onBattery
        watchBattery()
        onChange?()
    }

    func stop(result: String? = nil) {
        release()
        lastResult = result
        onChange?()
    }

    var statusDescription: String {
        guard isActive else { return "Не засыпать: выключено" + (lastResult.map { "; \($0)" } ?? "") }
        guard let endDate else { return "Не засыпать: пока не выключат" }
        return "Не засыпать: до \(Self.clock(endDate)), осталось \(KeepAwakeDuration.remaining(seconds: endDate.timeIntervalSinceNow))"
    }

    var iconDescription: String? {
        guard isActive else { return nil }
        return endDate.map { "не засыпать до \(Self.clock($0))" } ?? "не засыпать, пока не выключат"
    }

    // MARK: Menu

    func menuItems() -> [NSMenuItem] {
        let title: String
        if !isActive { title = "Не засыпать" }
        else if let endDate { title = "Не засыпать: ещё \(KeepAwakeDuration.remaining(seconds: endDate.timeIntervalSinceNow))" }
        else { title = "Не засыпать: пока не выключу" }
        let parent = item(title)
        parent.state = isActive ? .on : .off
        let submenu = NSMenu()
        if isActive {
            submenu.addItem(item(endDate.map { "До \(Self.clock($0))" } ?? "Пока не выключите"))
            submenu.addItem(item("Выключить", action: #selector(turnOff)))
            submenu.addItem(.separator())
        }
        let battery = Self.battery
        let allowed = KeepAwakeBatteryRule.allows(onBattery: battery.onBattery, percent: battery.percent, minimum: settings.keepAwakeBatteryPercent)
        var choices = KeepAwakeDuration.presets
        let custom = UserDefaults.standard.integer(forKey: Self.customKey)
        if custom > 0, !choices.contains(custom) { choices.append(custom) }
        for minutes in choices.sorted() {
            let row = item(KeepAwakeDuration.title(minutes: minutes), action: allowed ? #selector(choose(_:)) : nil)
            row.tag = minutes
            row.state = isActive && self.minutes == minutes ? .on : .off
            submenu.addItem(row)
        }
        let forever = item("Пока не выключу", action: allowed ? #selector(choose(_:)) : nil)
        forever.state = isActive && minutes == nil ? .on : .off
        submenu.addItem(forever)
        submenu.addItem(item("Своё время…", action: allowed ? #selector(chooseCustom) : nil))
        if !allowed || lastResult != nil { submenu.addItem(.separator()) }
        if !allowed { submenu.addItem(item("Заряд ниже \(settings.keepAwakeBatteryPercent)%: подключите зарядку")) }
        if let lastResult { submenu.addItem(item(lastResult)) }
        parent.submenu = submenu
        return [parent]
    }

    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) { start(minutes: sender.tag > 0 ? sender.tag : nil) }
    @objc private func turnOff() { stop() }

    @objc private func chooseCustom() {
        let previous = NSWorkspace.shared.frontmostApplication
        let stored = UserDefaults.standard.integer(forKey: Self.customKey)
        var text = stored > 0 ? KeepAwakeDuration.title(minutes: stored) : ""
        var message = "Например: 45, 1:30 или 2 ч 15 мин. Не больше 24 часов."
        NSApp.activate(ignoringOtherApps: true)
        defer { if previous?.bundleIdentifier != Bundle.main.bundleIdentifier { previous?.activate() } }
        while true {
            let alert = NSAlert()
            alert.messageText = "Сколько не засыпать?"
            alert.informativeText = message
            let field = NSTextField(string: text)
            field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            field.placeholderString = "1 ч 30 мин"
            alert.accessoryView = field
            alert.addButton(withTitle: "Включить")
            alert.addButton(withTitle: "Отмена")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            text = field.stringValue
            if let minutes = KeepAwakeDuration.parse(text) {
                UserDefaults.standard.set(minutes, forKey: Self.customKey)
                start(minutes: minutes)
                return
            }
            message = "Не получилось понять «\(text)». Напишите, например, 45, 1:30 или 2 ч 15 мин. Не больше 24 часов."
        }
    }

    // MARK: Lifetime

    private func expireIfDue() {
        guard isActive, let endDate, endDate.timeIntervalSinceNow <= 1 else { return }
        stop()
    }

    private func release() {
        if assertion != 0 { IOPMAssertionRelease(assertion) }
        assertion = 0
        timer?.invalidate(); timer = nil
        endDate = nil; minutes = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
    }

    /// Power-source notices arrive on charge and adapter changes, only while active.
    private func watchBattery() {
        guard powerSource == nil, Self.battery.percent != nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<KeepAwakeController>.fromOpaque(context).takeUnretainedValue().powerChanged()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    private func powerChanged() {
        let battery = Self.battery
        let unplugged = battery.onBattery && !wasOnBattery
        wasOnBattery = battery.onBattery
        guard isActive else { return }
        if unplugged && settings.keepAwakeStopOnUnplug {
            stop(result: "Выключено: Mac отключили от зарядки")
        } else if !KeepAwakeBatteryRule.allows(onBattery: battery.onBattery, percent: battery.percent, minimum: settings.keepAwakeBatteryPercent) {
            stop(result: "Выключено: заряд ниже \(settings.keepAwakeBatteryPercent)% от батареи")
        }
    }

    var hasBattery: Bool { Self.battery.percent != nil }

    private static var battery: (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, nil) }
        let onBattery = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? == kIOPMBatteryPowerKey
        guard let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (onBattery, nil) }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return (onBattery, current * 100 / maximum)
        }
        return (onBattery, nil)
    }

    private static func clock(_ date: Date) -> String {
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        return Calendar.current.isDateInToday(date) ? time : "\(time) завтра"
    }

    deinit { release(); hotKey.stop() }
}
