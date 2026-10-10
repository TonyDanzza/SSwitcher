import AppKit
import Carbon
import InputMethodKit
import InputMethodSupport
import os

/// Purpose-built installer entry. It never starts IMK, selects a source, reads
/// an application client or operates on anything outside this installed bundle.
private func registerInstalledInputMethod() -> Int32 {
    let bundle = Bundle.main
    let expected = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Input Methods", isDirectory: true)
        .appendingPathComponent(InputMethodIdentity.installedName, isDirectory: true)
        .standardizedFileURL
    guard bundle.bundleIdentifier == InputMethodIdentity.bundleID,
          bundle.bundleURL.standardizedFileURL == expected,
          bundle.bundleURL.resolvingSymlinksInPath() == expected else {
        fputs("Registration requires ~/Library/Input Methods/SSwitcher Input.app\n", stderr)
        return EXIT_FAILURE
    }
    let status = TISRegisterInputSource(bundle.bundleURL as CFURL)
    guard status == noErr else {
        fputs("Own input-method registration failed (\(status))\n", stderr)
        return EXIT_FAILURE
    }
    let filter = [kTISPropertyBundleID: InputMethodIdentity.bundleID] as CFDictionary
    let list: [TISInputSource]
    switch InputMethodIdentity.sourceList(filter: filter, includeAllInstalled: true, limit: 64) {
    case .sources(let sources): list = sources
    case .unavailable:
        fputs("listUnavailable ownBundleID=\(InputMethodIdentity.bundleID) reason=nilArray\n", stderr)
        return EXIT_FAILURE
    case .countOutOfBounds:
        fputs("listUnavailable ownBundleID=\(InputMethodIdentity.bundleID) reason=countOutOfBounds\n", stderr)
        return EXIT_FAILURE
    case .invalidEntry:
        fputs("listUnavailable ownBundleID=\(InputMethodIdentity.bundleID) reason=invalidEntry\n", stderr)
        return EXIT_FAILURE
    }
    // Fixed type/value categories only; never dump the catalogue or a raw
    // property. This helper is confined to the own-bundle installer entry.
    func valueCategory(_ property: CFString, of source: TISInputSource) -> String {
        guard let pointer = TISGetInputSourceProperty(source, property) else { return "absent" }
        let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
        let type = CFGetTypeID(value)
        if type == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)) ? "CFBooleanTrue" : "CFBooleanFalse"
        }
        if type == CFStringGetTypeID() { return "CFString" }
        if type == CFNumberGetTypeID() { return "CFNumber" }
        if type == CFArrayGetTypeID() { return "CFArray" }
        if type == CFDictionaryGetTypeID() { return "CFDictionary" }
        if type == CFNullGetTypeID() { return "CFNull" }
        return "other"
    }
    func matching(id: String, type: CFString) -> TISInputSource? {
        list.first {
            InputMethodIdentity.string(kTISPropertyBundleID, of: $0) == InputMethodIdentity.bundleID &&
                InputMethodIdentity.string(kTISPropertyInputSourceID, of: $0) == id &&
                InputMethodIdentity.string(kTISPropertyInputSourceType, of: $0) == type as String
        }
    }
    guard let parent = matching(id: InputMethodIdentity.bundleID, type: kTISTypeKeyboardInputMethodModeEnabled),
          let english = matching(id: InputMethodIdentity.Mode.english.rawValue, type: kTISTypeKeyboardInputMode),
          let russian = matching(id: InputMethodIdentity.Mode.russian.rawValue, type: kTISTypeKeyboardInputMode) else {
        fputs("Own parent/two modes were not registered\n", stderr)
        return EXIT_FAILURE
    }
    let ownSources: [(String, CFString, TISInputSource)] = [
        (InputMethodIdentity.bundleID, kTISTypeKeyboardInputMethodModeEnabled, parent),
        (InputMethodIdentity.Mode.english.rawValue, kTISTypeKeyboardInputMode, english),
        (InputMethodIdentity.Mode.russian.rawValue, kTISTypeKeyboardInputMode, russian)
    ]
    for (id, type, source) in ownSources {
        if InputMethodIdentity.boolean(kTISPropertyInputSourceIsEnabled, of: source) { continue }
        guard InputMethodIdentity.boolean(kTISPropertyInputSourceIsEnableCapable, of: source) else {
            let enabled = valueCategory(kTISPropertyInputSourceIsEnabled, of: source)
            let capable = valueCategory(kTISPropertyInputSourceIsEnableCapable, of: source)
            fputs("ownSourceNotEnableCapable ownID=\(id) ownType=\(type) enabledValue=\(enabled) enableCapableValue=\(capable)\n", stderr)
            return EXIT_FAILURE
        }
        let status = TISEnableInputSource(source)
        guard status == noErr else {
            fputs("Own input-source enable failed (\(status))\n", stderr)
            return EXIT_FAILURE
        }
    }
    print("Registered SSwitcher English and SSwitcher Русский; no input source was selected.")
    return EXIT_SUCCESS
}

private func startupFailure(_ stage: String) -> Never {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unavailable"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unavailable"
    Logger(subsystem: InputMethodIdentity.bundleID, category: "Startup")
        .error("stage=\(stage, privacy: .public) ownBundleID=\(InputMethodIdentity.bundleID, privacy: .public) version=\(version, privacy: .public) build=\(build, privacy: .public)")
    exit(EXIT_FAILURE)
}

let launchArguments = CommandLine.arguments.dropFirst()
if launchArguments == ["--register"] { exit(registerInstalledInputMethod()) }
guard !launchArguments.contains(where: { $0.hasPrefix("--register") }) else { startupFailure("invalidRegistrationArguments") }
// Cocoa/LaunchServices may supply normal application arguments. They never
// authorize registration and must not prevent this input method from starting.
guard Bundle.main.bundleIdentifier == InputMethodIdentity.bundleID,
      NSStringFromClass(SSwitcherInputController.self) == InputMethodIdentity.controllerClass,
      Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String == InputMethodIdentity.connectionName,
      Bundle.main.object(forInfoDictionaryKey: "InputMethodServerControllerClass") as? String == InputMethodIdentity.controllerClass else { startupFailure("bundleConfigurationUnavailable") }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard let server = IMKServer(name: InputMethodIdentity.connectionName, bundleIdentifier: InputMethodIdentity.bundleID) else { startupFailure("serverUnavailable") }
withExtendedLifetime(server) { app.run() }
