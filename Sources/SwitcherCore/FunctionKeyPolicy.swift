/// What the top row sends without fn. Raw values match IOHIDSystem's
/// `HIDFKeyMode` parameter and the `com.apple.keyboard.fnState` preference.
public enum FunctionKeyMode: Int, Equatable, Sendable {
    case media = 0, standard = 1
    public var toggled: Self { self == .media ? .standard : .media }
}

/// The system preference is the base mode. An application with its own rule
/// overrides it while frontmost. A toggle changes whichever of the two applies
/// to the frontmost application, so the shortcut always flips what the user has.
public struct FunctionKeyPolicy: Equatable {
    public var base: FunctionKeyMode
    public private(set) var applications: [String: FunctionKeyMode]

    public init(base: FunctionKeyMode, applications: [String: FunctionKeyMode] = [:]) {
        self.base = base
        self.applications = applications
    }

    public func rule(for bundleID: String?) -> FunctionKeyMode? { bundleID.flatMap { applications[$0] } }
    public func mode(for bundleID: String?) -> FunctionKeyMode { rule(for: bundleID) ?? base }

    /// Returns true when the base mode (the system preference) changed.
    @discardableResult
    public mutating func toggle(for bundleID: String?) -> Bool {
        if let bundleID, let rule = applications[bundleID] {
            applications[bundleID] = rule.toggled
            return false
        }
        base = base.toggled
        return true
    }

    /// `nil` returns the application to the base mode.
    public mutating func setRule(_ mode: FunctionKeyMode?, for bundleID: String) {
        applications[bundleID] = mode
    }
}
