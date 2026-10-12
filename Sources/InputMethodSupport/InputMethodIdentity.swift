import Carbon
import Foundation

/// Shared identifiers and metadata only. No client text crosses this boundary.
public enum InputMethodIdentity {
    public static let utilityBundleID = "com.tonydanzza.SSwitcher"
    public static let bundleID = "com.tonydanzza.inputmethod.SSwitcher"
    public static let connectionName = "SSwitcherInputConnection"
    public static let installedName = "SSwitcher Input.app"
    public static let controllerClass = "SSwitcherInputController"
    public static let reportKey = "LastNativeInputDiagnostic"
    public static let requestName = Notification.Name(bundleID + ".ConvertText")
    public static let resetName = Notification.Name(bundleID + ".ResetGesture")
    public static let resultName = Notification.Name(bundleID + ".ResultChanged")
    public static let preferenceName = Notification.Name(bundleID + ".PreferenceChanged")
    public static let requestLifetime: Double = 1
    public static let readBudget: Double = 0.6
    public static let acknowledgementBudget: Double = 0.35

    public enum Mode: String, CaseIterable {
        case english = "com.tonydanzza.inputmethod.SSwitcher.English"
        case russian = "com.tonydanzza.inputmethod.SSwitcher.Russian"
        public var language: String { self == .english ? "en" : "ru" }
        fileprivate var keyboardPreference: String { self == .english ? "NativeEnglishKeyboardSourceID" : "NativeRussianKeyboardSourceID" }
    }

    public enum Reason: String {
        case waiting, converted, unverified, ignored, paused, secureInput, inactiveSession, sessionChanged, timedOut
        case modeUnconfirmed, passwordMode, restrictedMode
        case keyboardUnavailable, unicodeUnsupported, documentAccessUnsupported
        case invalidSelection, invalidMarkedRange, compositionActive
        case contextClipped, invalidUTF16, rangeChanged
        case documentUnavailable, documentTooLarge, documentChanged, mappingUnavailable, unchangedText

        public var message: String {
            switch self {
            case .waiting: return "Нативный источник: ожидает двойной Shift"
            case .converted: return "Текст заменён — подтверждено нативным клиентом"
            case .unverified: return "Результат нативной замены не подтверждён; проверьте текст и выделите его заново"
            case .ignored: return "Курсор должен стоять в конце слова"
            case .unchangedText: return "Нет символов для преобразования раскладки"
            case .paused: return "Нативный источник: преобразование на паузе"
            case .secureInput: return "Нативный источник: защищённый ввод — чтение отключено"
            case .modeUnconfirmed: return "Нативный источник: режим клиента не подтверждён — чтение отключено"
            case .passwordMode: return "Нативный источник: режим пароля — чтение отключено"
            case .restrictedMode: return "Нативный источник: режим не разрешает чтение"
            case .compositionActive: return "Нативный источник: завершите текущий ввод"
            case .contextClipped: return "Нативный источник: приложение не предоставило полный документ"
            case .keyboardUnavailable: return "Нативный источник: системная раскладка недоступна"
            case .mappingUnavailable: return "Нативный источник: преобразование раскладок недоступно"
            case .documentTooLarge: return "Нативный источник: документ слишком большой для безопасной замены"
            case .documentUnavailable: return "Нативный источник: полный документ недоступен"
            case .timedOut: return "Нативный источник: время подготовки истекло"
            case .documentChanged: return "Нативный источник: документ изменился — замена отменена"
            case .sessionChanged, .rangeChanged: return "Нативный источник: поле или ввод изменились"
            default: return "Нативный источник: безопасная замена не поддерживается"
            }
        }
    }

    public static func string(_ property: CFString, of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, property) else { return nil }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? String
    }

    public static func boolean(_ property: CFString, of source: TISInputSource) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, property) else { return false }
        return (Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? NSNumber)?.boolValue == true
    }

    public enum SourceList {
        case sources([TISInputSource])
        case unavailable
        case countOutOfBounds
        case invalidEntry
    }

    /// TIS documents a CFArray of TISInputSourceRefs, not Objective-C objects
    /// that must pass a Swift conditional collection bridge. Retain the refs
    /// while the array is alive and keep native enumeration explicitly bounded.
    public static func sourceList(filter: CFDictionary, includeAllInstalled: Bool, limit: Int) -> SourceList {
        guard let array = TISCreateInputSourceList(filter, includeAllInstalled)?.takeRetainedValue() else { return .unavailable }
        let count = CFArrayGetCount(array)
        guard limit > 0, count >= 0, count <= limit else { return .countOutOfBounds }
        var sources: [TISInputSource] = []
        sources.reserveCapacity(count)
        for index in 0..<count {
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return .invalidEntry }
            sources.append(Unmanaged<TISInputSource>.fromOpaque(pointer).takeUnretainedValue())
        }
        return .sources(sources)
    }

    public static var currentMode: Mode? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              string(kTISPropertyBundleID, of: source) == bundleID,
              string(kTISPropertyInputSourceType, of: source) == kTISTypeKeyboardInputMode as String,
              let id = string(kTISPropertyInputSourceID, of: source) else { return nil }
        return Mode(rawValue: id)
    }

    /// Synchronize this one application domain before cross-process reads.
    public static func preference(_ key: String, domain: String) -> CFPropertyList? {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }

    public static var isPaused: Bool {
        (preference("paused", domain: utilityBundleID) as? NSNumber)?.boolValue == true
    }

    private static func languages(_ source: TISInputSource) -> [String] {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return [] }
        return Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue() as? [String] ?? []
    }

    private static func supports(_ mode: Mode, source: TISInputSource) -> Bool {
        languages(source).contains { $0 == mode.language || $0.hasPrefix(mode.language + "-") }
    }


    public static func systemKeyboardSource(for mode: Mode) -> TISInputSource? {
        let filter = [kTISPropertyInputSourceType: kTISTypeKeyboardLayout as Any,
                      kTISPropertyInputSourceIsEnabled: true] as CFDictionary
        guard case .sources(let list) = sourceList(filter: filter, includeAllInstalled: false, limit: 256) else { return nil }
        let ids = list.filter { supports(mode, source: $0) }.compactMap { string(kTISPropertyInputSourceID, of: $0) }.sorted()
        let preferred = preference(mode.keyboardPreference, domain: utilityBundleID) as? String
        let defaults = mode == .english ? ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] : ["com.apple.keylayout.Russian", "com.apple.keylayout.Russian-PC"]
        let id = preferred.flatMap { ids.contains($0) ? $0 : nil } ?? defaults.first(where: ids.contains) ?? ids.first
        return list.first { string(kTISPropertyInputSourceID, of: $0) == id && supports(mode, source: $0) }
    }

    public static func systemKeyboardID(for mode: Mode) -> String? {
        systemKeyboardSource(for: mode).flatMap { string(kTISPropertyInputSourceID, of: $0) }
    }
}
