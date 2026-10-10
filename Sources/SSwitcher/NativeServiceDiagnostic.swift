import AppKit
import Carbon
import SwitcherCore

/// AppKit Services provider. Diagnostics are zero-write; the existing two-way
/// selector may commit only a word owned by the current MAX gesture. Selected
/// conversion is separately granted by a MAX gesture or explicit arm.
final class NativeServiceDiagnostic: NSObject {
    private final class Grant {
        let deadline: ReadinessDeadline
        let readback: NativeSelectionServiceProof.Readback?
        init(readback: NativeSelectionServiceProof.Readback?) {
            self.readback = readback
            let now = ProcessInfo.processInfo.systemUptime
            deadline = ReadinessDeadline(start: now, timeout: min(60, readback.map { max(0, $0.deadline.expiresAt - now) } ?? 60))
        }
    }
    private let selectionProof = NativeSelectionServiceProof()
    var conversionStatus: String { selectionProof.status }
    var isConverting: Bool { selectionProof.isConverting }
    func convertAtCursor(valid: @escaping () -> Bool,
                         completion: @escaping (NativeServiceDispatchState.Outcome, TISInputSource?) -> Void) {
        cancelDiagnostic()
        selectionProof.convertAtCursor(valid: valid, completion: completion)
    }

    /// Explicit finite MAX diagnostic, scoped to the built-in display.
    /// Normal conversion runs only for an actual gesture in the focused app.
    func withWordScopeForDiagnostics(_ trigger: () -> Void) {
        UserDefaults.standard.set(["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "stage": "entered"], forKey: "NativeWordDiagnosticReport")
        guard Thread.isMainThread, let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "ru.oneme.desktop", !IsSecureEventInputEnabled() else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, 0.12)
        var raw: CFTypeRef?
        let reply = AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &raw)
        guard let window = AccessibilityElementReply(error: reply, value: raw).element else {
            UserDefaults.standard.set(["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "stage": "focusedWindowUnavailable", "AXError": reply.rawValue], forKey: "NativeWordDiagnosticReport")
            return
        }
        guard NativeServiceMenuResolver.builtInWindowBounds(window, pid: app.processIdentifier, report: { report in
            var value = report
            value["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            UserDefaults.standard.set(value, forKey: "NativeWordDiagnosticReport")
        }) != nil else { return }
        UserDefaults.standard.set(["build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "stage": "trigger"], forKey: "NativeWordDiagnosticReport")
        trigger()
    }

    func cancelConversion() {
        selectionProof.cancelAutomatic()
    }
    private var generation: Grant?
    private var generationNumber = 0
    private var waitingForReadback = false
    private var grant: Grant?
    private var expiry: DispatchWorkItem?
    private(set) var status = "Проверка службы MAX: не запускалась; замена не выполняется"

    func arm() {
        guard Thread.isMainThread else { return }
        cancelDiagnostic()
        selectionProof.cancelArm()
        generationNumber += 1
        let number = generationNumber
        if selectionProof.hasExpectedResponse {
            waitingForReadback = true
            record(["stage": "waitingForMAX", "callCount": 0])
            status = "Проверка ответа: перейдите в исходное окно MAX до окончания минуты"
            selectionProof.takeReadback { [weak self] readback, reason in
                guard let self, self.generationNumber == number, self.waitingForReadback else { return }
                self.waitingForReadback = false
                guard let readback else {
                    self.record(["stage": "readbackArmRejected", "reason": reason ?? "axWindow", "callCount": 0])
                    self.status = "Проверка службы MAX: исходное окно не подтверждено или время истекло"
                    return
                }
                self.installGrant(readback: readback, number: number)
            }
            return
        }
        installGrant(readback: nil, number: number)
    }

    private func installGrant(readback: NativeSelectionServiceProof.Readback?, number: Int) {
        let request = Grant(readback: readback)
        generation = request; grant = request
        record(["stage": "armed", "callCount": 0])
        status = "Проверка службы MAX: выберите выделенный тестовый текст и службу SSwitcher в течение минуты"
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.generationNumber == number, self.generation != nil else { return }
            self.generation = nil; self.grant = nil; self.expiry = nil
            self.record(["stage": "expired", "callCount": 0])
            self.status = "Проверка службы MAX: время ожидания истекло"
        }
        expiry = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, request.deadline.expiresAt - ProcessInfo.processInfo.systemUptime), execute: timeout)
    }

    func cancel() {
        guard Thread.isMainThread else { return }
        cancelDiagnostic()
        selectionProof.cancel()
    }

    func armConversion() {
        guard Thread.isMainThread else { return }
        cancelDiagnostic()
        selectionProof.arm()
    }

    private func cancelDiagnostic() {
        guard Thread.isMainThread, generation != nil || waitingForReadback else { return }
        waitingForReadback = false
        generation = nil; grant = nil
        generationNumber += 1
        expiry?.cancel(); expiry = nil
        record(["stage": "cancelled", "callCount": 0])
        status = "Проверка службы MAX отменена"
    }

    @objc(checkNativeSelection:userData:error:)
    func checkNativeSelection(_ pasteboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let error else { return }
        error.pointee = "SSwitcher: проверка завершена, текст не изменён" as NSString
        // The gesture-owned commit consumes this exact native packet once.
        // It owns response cleanup itself; readonly requests below always
        // leave no return formats, even when their diagnostic succeeds.
        if selectionProof.convertWordPacketIfRequested(pasteboard, error: error) { return }
        defer { NativeServicePacket.discardReturnValue(pasteboard) }
        guard Thread.isMainThread else { return }
        // A two-way declaration keeps MAX active. Never leave the sent text
        // as a return value: Qt could insert it again and collapse selection.
        // Clear formats, not an empty string (which would delete selection).
        if selectionProof.receiveWordPacket(pasteboard) {
            // A successful read is not a failed service. Returning an error
            // can interrupt the requestor's queued Services/navigation.
            // No return formats means Qt has no text to commit.
            if NativeServicePacket.discardReturnValue(pasteboard) { error.pointee = nil }
            return
        }
        guard let request = grant, generation === request else { return }
        grant = nil
        expiry?.cancel(); expiry = nil
        var report: [String: Any] = ["stage": "requestReceived", "callCount": 1, "hasErrorPointer": true]
        func finish(_ stage: String) {
            guard generation === request else { return }
            generation = nil
            report["stage"] = stage
            record(report)
            if stage == "packetRead", let matches = report["matchesExpectedResponse"] as? Bool {
                status = matches ? "Проверка службы MAX: выделенный текст совпадает с ответом" :
                    "Проверка службы MAX: выделенный текст не совпадает с ответом"
            } else {
                status = stage == "packetRead" ? "Проверка службы MAX завершена: пакет получен, текст не изменён" :
                    "Проверка службы MAX завершена: пакет не принят, текст не изменён"
            }
        }
        guard !request.deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { finish("expired"); return }

        let name = pasteboard.name
        // Non-general is transport separation, not authenticated service origin.
        report["nonGeneralBoard"] = name != .general
        guard ![NSPasteboard.Name.general, .find, .font, .ruler, .drag].contains(name) else {
            finish("standardBoardRejected"); return
        }
        let securePassed = !IsSecureEventInputEnabled()
        report["secureGuardPassed"] = securePassed
        guard securePassed else { finish("secureInput"); return }
        let foregroundPassed = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "ru.oneme.desktop"
        report["foregroundMAX"] = foregroundPassed
        report["foregroundOwn"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        report["providerActive"] = NSApp.isActive
        guard foregroundPassed else { finish("foregroundRejected"); return }
        guard !request.deadline.expired(at: ProcessInfo.processInfo.systemUptime) else { finish("expired"); return }
        if let readback = request.readback, !selectionProof.readbackContextMatches(readback) {
            finish("readbackContextRejected"); return
        }
        let hasType = pasteboard.availableType(from: [.string]) == .string
        report["hasString"] = false
        guard hasType, let text = pasteboard.string(forType: .string) else { finish("stringUnavailable"); return }
        report["hasString"] = true
        report["matchesEnglishFixture"] = text.utf16.elementsEqual("ghbdtn".utf16)
        report["matchesRussianFixture"] = text.utf16.elementsEqual("привет".utf16)
        report["matchesSpaceFixture"] = text.utf16.elementsEqual(" ".utf16)
        report["matchesRussianWithSpaceFixture"] = text.utf16.elementsEqual("привет ".utf16)
        report["lastTokenMatchesEnglishFixture"] = NativeWordCandidatePlan(prefix: text)?.matches("ghbdtn") == true
        report["lastTokenMatchesRussianFixture"] = NativeWordCandidatePlan(prefix: text)?.matches("привет") == true
        // Bound accepted payload work without retaining/reporting its length.
        // The native pasteboard getter itself supplies the selected packet.
        let limit = request.readback == nil ? 4096 : NativeServicePayload.utf16Limit
        guard !text.isEmpty, text.utf16.prefix(limit + 1).count <= limit else { finish("payloadRejected"); return }
        guard !request.deadline.expired(at: ProcessInfo.processInfo.systemUptime), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "ru.oneme.desktop" else {
            finish("contextChanged"); return
        }
        let conversion = InputSources.prepare(text)
        report["mappingAvailable"] = conversion != nil
        report["wouldConversionChange"] = conversion.map { !text.utf16.elementsEqual($0.text.utf16) } ?? false
        guard !request.deadline.expired(at: ProcessInfo.processInfo.systemUptime), !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "ru.oneme.desktop" else {
            finish("contextChanged"); return
        }
        if let readback = request.readback {
            guard selectionProof.readbackContextMatches(readback) else { finish("readbackContextChanged"); return }
            report["readbackWindowProvenAtArm"] = true
            report["matchesExpectedResponse"] = readback.matches(text)
        }
        finish("packetRead")
        error.pointee = nil
        // No return data, source selection, AX, events or clipboard fallback.
    }

    @objc(convertNativeSelection:userData:error:)
    func convertNativeSelection(_ pasteboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        selectionProof.convert(pasteboard, error: error)
    }

    @objc(checkNativeEditable:userData:error:)
    func checkNativeEditable(_ pasteboard: NSPasteboard, userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        selectionProof.probeEditable(pasteboard, error: error)
    }

    private func record(_ report: [String: Any]) {
        var value = report
        value["version"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        value["build"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        UserDefaults.standard.set(value, forKey: "NativeServiceDiagnosticReport")
    }

    deinit { expiry?.cancel() }
}
