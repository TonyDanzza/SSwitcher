import AppKit
import CoreGraphics
import SwitcherCore

extension NSScreen {
    /// The CoreGraphics display this screen shows.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Displays for the Settings pane: their sizes, switching with public
/// CoreGraphics calls, and the HiDPI override file. Writing or removing the
/// file is the only privileged step; macOS asks for the administrator
/// password and applies it after a restart.
final class DisplayController: ObservableObject {
    struct Size: Hashable {
        let width: Int, height: Int
        let hiDPI: Bool
    }

    struct Display: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        let isBuiltin: Bool
        let vendor: UInt32, model: UInt32
        let nativeWidth: Int, nativeHeight: Int
        let sizes: [Size]
        let current: Size?
        let hasHiDPI: Bool
        let overrideExists: Bool
        var overridePath: String { DisplayOverride.directory + "/" + DisplayOverride.relativePath(vendor: vendor, model: model) }
    }

    @Published private(set) var displays: [Display] = []
    @Published private(set) var lastMessage: String?
    /// Override files changed in this session; they apply after a restart.
    @Published private(set) var pendingRestart = Set<String>()
    /// The administrator prompt is open or its command is running.
    @Published private(set) var isChangingOverride = false
    private static let supportFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SSwitcher/DisplayOverrides")

    func refresh() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return }
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, String)? in
            screen.displayID.map { ($0, screen.localizedName) }
        }, uniquingKeysWith: { first, _ in first })
        let value = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }.map { id in
            Self.describe(id, name: names[id] ?? "Дисплей")
        }
        if value != displays { displays = value }
    }

    private static func describe(_ id: CGDirectDisplayID, name: String) -> Display {
        let modes = DisplayModes.all(id)
        // The panel's own pixels: the largest unscaled mode.
        let native = modes.filter { !$0.hiDPI }.max { $0.width * $0.height < $1.width * $1.height }
        let all = modes.map { Size(width: $0.width, height: $0.height, hiDPI: $0.hiDPI) }
        // HiDPI sizes, plus the panel's own resolution. Low-resolution
        // stretched modes are listed only when there is no HiDPI at all.
        // Down to half the panel; a Retina panel also gets its larger-text
        // sizes down to 1024 points wide, as System Settings lists them.
        let half = CGDisplayIsBuiltin(id) != 0 ? min(1024, (native?.width ?? 0) / 2) : (native?.width ?? 0) / 2
        // Only the panel's proportions: 4:3 modes on a 16:9 panel are stretched.
        let aspect = native.map { Double($0.width) / Double($0.height) }
        func fits(_ size: Size) -> Bool {
            guard let aspect else { return true }
            return abs(Double(size.width) / Double(size.height) - aspect) / aspect < 0.02
        }
        var sizes = all.filter { $0.hiDPI && $0.width >= half && fits($0) }
        // A Retina panel's unscaled mode makes everything tiny; System Settings
        // does not offer it either.
        let builtin = CGDisplayIsBuiltin(id) != 0
        if let native, !builtin || sizes.isEmpty { sizes.append(Size(width: native.width, height: native.height, hiDPI: false)) }
        // Without HiDPI an external monitor still offers its smaller sizes.
        if !builtin { sizes += all.filter { !$0.hiDPI && $0.width >= half && fits($0) } }
        if sizes.count <= 1 { sizes += all.filter { !$0.hiDPI && $0.width >= 1024 } }
        let current = CGDisplayCopyDisplayMode(id).map { Size(width: $0.width, height: $0.height, hiDPI: $0.pixelWidth > $0.width) }
        if let current { sizes.append(current) }
        sizes = sizes.reduce(into: [Size]()) { unique, size in if !unique.contains(size) { unique.append(size) } }
        sizes.sort { $0.width != $1.width ? $0.width > $1.width : ($0.height != $1.height ? $0.height > $1.height : $0.hiDPI) }
        let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id)
        let path = DisplayOverride.directory + "/" + DisplayOverride.relativePath(vendor: vendor, model: model)
        return Display(id: id, name: name, isBuiltin: CGDisplayIsBuiltin(id) != 0, vendor: vendor, model: model,
                       nativeWidth: native?.width ?? 0, nativeHeight: native?.height ?? 0,
                       sizes: sizes, current: current, hasHiDPI: sizes.contains(where: \.hiDPI),
                       overrideExists: FileManager.default.fileExists(atPath: path))
    }

    /// Picks the mode for `size`, keeping the current refresh rate when the
    /// size offers it, and makes it the display's saved setting.
    func select(_ size: Size, on display: Display) {
        let currentRate = CGDisplayCopyDisplayMode(display.id)?.refreshRate ?? 0
        let candidates = DisplayModes.all(display.id).filter {
            $0.width == size.width && $0.height == size.height && $0.hiDPI == size.hiDPI
        }
        guard let entry = candidates.first(where: { abs($0.refreshRate - currentRate) < 0.5 })
                ?? candidates.max(by: { $0.refreshRate < $1.refreshRate }) else { return }
        lastMessage = DisplayModes.apply(entry, to: display.id) ? nil : "macOS не переключила размер экрана"
        refresh()
    }

    /// The HiDPI version of the size in use, or the HiDPI size closest to it.
    func crispSize(for display: Display) -> Size? {
        let crisp = display.sizes.filter(\.hiDPI)
        guard let current = display.current else { return crisp.first }
        return crisp.first { $0.width == current.width && $0.height == current.height }
            ?? crisp.min { abs($0.width - current.width) < abs($1.width - current.width) }
    }

    func makeCrisp(_ display: Display) {
        if let size = crispSize(for: display) { select(size, on: display) }
    }

    /// The panel's own resolution without HiDPI.
    func makeNative(_ display: Display) {
        guard display.nativeWidth > 0 else { return }
        select(Size(width: display.nativeWidth, height: display.nativeHeight, hiDPI: false), on: display)
    }

    // MARK: Override file

    func installOverride(for display: Display) {
        guard display.nativeWidth > 0 else { lastMessage = "Не удалось узнать разрешение монитора"; return }
        let sizes = DisplayOverride.scaledSizes(nativeWidth: display.nativeWidth, nativeHeight: display.nativeHeight)
        let alert = NSAlert()
        alert.messageText = "Добавить размеры HiDPI для «\(display.name)»?"
        alert.informativeText = """
            SSwitcher добавит в системную папку файл-описание этого монитора с \(sizes.count) размерами HiDPI, \
            от \(sizes.first.map { "\($0.width) × \($0.height)" } ?? "") до \(sizes.last.map { "\($0.width) × \($0.height)" } ?? "").

            macOS попросит пароль администратора. Размеры появятся после перезагрузки Mac. \
            Убрать файл можно здесь же.
            """
        alert.addButton(withTitle: "Включить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let data = try DisplayOverride.plist(vendor: display.vendor, model: display.model, sizes: sizes)
            let staging = Self.supportFolder.appendingPathComponent("staging")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let file = staging.appendingPathComponent("DisplayProductID-\(String(display.model, radix: 16))")
            try data.write(to: file, options: .atomic)
            let target = display.overridePath, folder = (target as NSString).deletingLastPathComponent
            let q = DisplayOverride.shellQuoted
            let command = "/bin/mkdir -p \(q(folder)) && /bin/cp \(q(file.path)) \(q(target)) && " +
                "/usr/sbin/chown root:wheel \(q(target)) && /bin/chmod 644 \(q(target))"
            runPrivileged(command) { [weak self] done in
                try? FileManager.default.removeItem(at: file)
                guard let self else { return }
                if done {
                    self.pendingRestart.insert(target)
                    self.lastMessage = "Файл добавлен. Перезагрузите Mac, чтобы появились размеры HiDPI."
                }
                self.refresh()
            }
        } catch {
            lastMessage = "Не удалось подготовить файл: \(error.localizedDescription)"
            refresh()
        }
    }

    /// Keeps a copy in Application Support before deleting, so another
    /// tool's working file (one-key-hidpi, BetterDisplay) can be restored.
    func removeOverride(for display: Display) {
        let alert = NSAlert()
        alert.messageText = "Убрать размеры HiDPI для «\(display.name)»?"
        alert.informativeText = "Файл-описание монитора будет удалён из системной папки; копия останется в папке SSwitcher. После перезагрузки Mac останутся только обычные размеры этого монитора. Добавить их снова можно кнопкой «Добавить размеры HiDPI…»."
        alert.addButton(withTitle: "Убрать")
        alert.addButton(withTitle: "Отмена")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let target = display.overridePath
        let backupRoot = Self.supportFolder.appendingPathComponent("removed-" + UUID().uuidString)
        let removal: DisplayOverrideRemoval
        do {
            removal = try DisplayOverrideRemoval(target: target, backupDirectory: backupRoot)
        } catch {
            lastMessage = "Не удалось сохранить копии файлов, удаление не начато: \(error.localizedDescription)"
            return
        }
        runPrivileged(removal.command) { [weak self] done in
            guard let self else { return }
            if done {
                self.pendingRestart.insert(target)
                self.lastMessage = "Файлы убраны, копии сохранены. Перезагрузите Mac."
            }
            // Keep backups even if deletion failed partway through.
            self.refresh()
        }
    }

    /// macOS's own administrator prompt, run by osascript so the main run
    /// loop (event tap, shortcuts, timers) keeps going while it is open.
    /// A cancelled prompt is not an error. `completion` runs on main.
    private func runPrivileged(_ command: String, completion: @escaping (Bool) -> Void) {
        guard !isChangingOverride else { return }
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let done = process.terminationStatus == 0
            DispatchQueue.main.async {
                self?.isChangingOverride = false
                if !done, !message.contains("(-128)") {
                    self?.lastMessage = "Не удалось изменить системную папку: \(message.isEmpty ? "ошибка" : message)"
                }
                completion(done)
            }
        }
        do {
            try process.run()
            isChangingOverride = true
        } catch {
            lastMessage = "Не удалось запросить пароль администратора: \(error.localizedDescription)"
            completion(false)
        }
    }
}
