import AppKit

/// Services use a dedicated OS packet, independent of every shared pasteboard.
/// A rejected or read-only response must contain no formats: keeping the sent
/// string can cause the requestor to insert it again despite a service error.
public enum NativeServicePacket {
    public static func isDedicated(_ name: NSPasteboard.Name) -> Bool {
        ![NSPasteboard.Name.general, .find, .font, .ruler, .drag].contains(name)
    }

    @discardableResult
    public static func discardReturnValue(_ packet: NSPasteboard) -> Bool {
        guard isDedicated(packet.name) else { return false }
        packet.clearContents()
        return true
    }
}
