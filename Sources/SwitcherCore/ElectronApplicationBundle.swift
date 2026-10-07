import Foundation

/// Packaging evidence only enables Electron's accessibility preparation. It
/// never establishes an editable field or changes the selection/focus guards.
public enum ElectronApplicationBundle {
    public static func recognizes(_ bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        if isDirectory(frameworks.appendingPathComponent("Electron Framework.framework")) { return true }

        // Electron permits a branded framework name. Its documented ASAR
        // integrity metadata, archive and actual framework provide independent
        // package evidence without trusting the application's display name.
        guard let info = dictionary(contents.appendingPathComponent("Info.plist")),
              info["CFBundlePackageType"] as? String == "APPL",
              let integrity = info["ElectronAsarIntegrity"] as? [String: Any],
              let archive = integrity["Resources/app.asar"] as? [String: Any],
              archive["algorithm"] as? String == "SHA256",
              let hash = archive["hash"] as? String, hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              isRegularFile(contents.appendingPathComponent("Resources/app.asar")),
              let children = try? FileManager.default.contentsOfDirectory(at: frameworks, includingPropertiesForKeys: nil) else { return false }
        return children.contains { framework in
            guard framework.pathExtension == "framework", isDirectory(framework),
                  let info = dictionary(framework.appendingPathComponent("Resources/Info.plist")),
                  info["CFBundlePackageType"] as? String == "FMWK",
                  let executable = info["CFBundleExecutable"] as? String,
                  !executable.isEmpty, executable != ".", executable != "..",
                  !executable.contains("/"), !executable.contains("\0") else { return false }
            return isRegularFile(framework.appendingPathComponent(executable))
        }
    }

    private static func dictionary(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        return value as? [String: Any]
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
