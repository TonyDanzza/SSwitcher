/// How a double Shift converts text in MAX, whose composer has no usable
/// Accessibility text. Decided from the typed-word memory and whether an
/// editor selection can exist; the caller still checks every guard.
public enum MaxConversionRoute: Equatable {
    /// A freshly typed word: delete exactly its characters and type the
    /// converted text. No selection, Services or clipboard.
    case retype(word: String, boundedStart: Bool)
    /// No selection can exist: one Services request for the word before the
    /// caret, without the selection and boundary probes.
    case directService
    /// A selection may exist: the full Services transaction.
    case fullService

    public static let bundleID = "ru.oneme.desktop"

    public static func decide(candidate: TypedWordTracker.Candidate, selectionKnownEmpty: Bool) -> Self {
        if case .word(let word, let boundedStart) = candidate { return .retype(word: word, boundedStart: boundedStart) }
        return service(selectionKnownEmpty: selectionKnownEmpty)
    }

    /// The Services route, also used when retyping refuses before any key.
    /// A typed word after a space may have been autocorrected, so the editor's
    /// own text is read instead.
    public static func service(selectionKnownEmpty: Bool) -> Self {
        selectionKnownEmpty ? .directService : .fullService
    }

    /// The snapshot that hides native selection can start at the second Shift
    /// release only for a request that is known to need it.
    public var startsEarlyShield: Bool { self == .directService }
}
