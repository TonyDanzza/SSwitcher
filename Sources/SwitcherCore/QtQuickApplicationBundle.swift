import Foundation

/// Package evidence permits a read-only Qt accessibility preparation, never
/// text editing. The focused editor still needs every ordinary AX guard.
public enum QtQuickApplicationBundle {
    public static func recognizes(_ bundleURL: URL?) -> Bool {
        guard let bundleURL,
              Bundle(url: bundleURL)?.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else { return false }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        return ["QtGui", "QtQuick"].allSatisfy { name in
            let framework = frameworks.appendingPathComponent("\(name).framework", isDirectory: true)
            guard (try? framework.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let bundle = Bundle(url: framework),
                  bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "FMWK",
                  bundle.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String == "org.qt-project.\(name)",
                  bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == name,
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  version.hasPrefix("6.") else { return false }
            return (try? framework.appendingPathComponent(name).resolvingSymlinksInPath()
                .resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}
