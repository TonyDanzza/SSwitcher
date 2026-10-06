import Foundation

/// Bulk Select All requires coherent proof that the original selection covered
/// the entire document. Repeated fragments never widen a partial selection.
public enum CanvasSelectionPlan: Equatable {
    case entireDocument
    case characters(Int)

    public init(selection: AccessibilitySelectionPlan, replacementText: String) {
        self = selection.isEntireDocument ? .entireDocument : .characters(replacementText.count)
    }
}
