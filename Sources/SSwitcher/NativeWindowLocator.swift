import ApplicationServices
import AppKit
import Foundation
import SwitcherCore

/// Bounded geometry of the MAX window that owns a transaction. Reads only the
/// window's position and size; no menu, title or text.
enum NativeWindowLocator {
    static func windowNumber(_ window: AXUIElement, pid: pid_t) -> Int? {
        guard let bounds = windowBounds(window, pid: pid),
              let entries = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let matches = entries.compactMap { entry -> Int? in
            guard (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let dictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dictionary),
                  abs(rect.minX - bounds.minX) <= 2, abs(rect.minY - bounds.minY) <= 2,
                  abs(rect.width - bounds.width) <= 2, abs(rect.height - bounds.height) <= 2,
                  let number = entry[kCGWindowNumber as String] as? NSNumber, number.intValue > 0 else { return nil }
            return number.intValue
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func windowBounds(_ window: AXUIElement, pid: pid_t) -> CGRect? {
        let deadline = ReadinessDeadline(start: ProcessInfo.processInfo.systemUptime, timeout: 0.2)
        func value(_ attribute: String) -> CFTypeRef? {
            var owner: pid_t = 0
            guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime),
                  AXUIElementGetPid(window, &owner) == .success, owner == pid else { return nil }
            let remaining = deadline.expiresAt - ProcessInfo.processInfo.systemUptime
            guard remaining > 0, AXUIElementSetMessagingTimeout(window, Float(min(0.08, remaining))) == .success else { return nil }
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(window, attribute as CFString, &raw)
            guard !deadline.expired(at: ProcessInfo.processInfo.systemUptime), error == .success,
                  AccessibilityValue.error(raw) == nil else { return nil }
            return AccessibilityValue.usable(raw)
        }
        guard let rawPoint = value(kAXPositionAttribute), let rawSize = value(kAXSizeAttribute),
              CFGetTypeID(rawPoint) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((rawPoint as! AXValue), .cgPoint, &origin),
              AXValueGetValue((rawSize as! AXValue), .cgSize, &size),
              !deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { return nil }
        let bounds = CGRect(origin: origin, size: size)
        return WindowTransferPlan.valid(bounds) ? bounds : nil
    }
}
