import Foundation

/// Preserve both files before issuing any privileged deletion. Backups are
/// retained on failure too: the command may have removed only one file.
public struct DisplayOverrideRemoval {
    public let command: String

    public init(target: String, backupDirectory: URL) throws {
        let manager = FileManager.default
        let paths = [target, target + ".icns"]
        try manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        for path in paths {
            // attributesOfItem also detects a dangling symlink.
            do {
                _ = try manager.attributesOfItem(atPath: path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            }
            try manager.copyItem(atPath: path,
                                 toPath: backupDirectory.appendingPathComponent((path as NSString).lastPathComponent).path)
        }
        let quoted = paths.map(DisplayOverride.shellQuoted)
        let absent = quoted.map { "[ ! -e \($0) ] && [ ! -L \($0) ]" }.joined(separator: " && ")
        // Do not remove the parent directory: it may hold other tools' files.
        command = "/bin/rm -f " + quoted.joined(separator: " ") + " && " + absent
    }
}
