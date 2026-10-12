import AppKit
import SwiftUI
import SwitcherCore

/// Every pane is a grouped form, like System Settings: labels on the left,
/// controls on the right, one short explanation under a group.
struct SettingsPanes: View {
    static let width: CGFloat = 600
    let tab: SettingsTab
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: SettingsStatus
    @ObservedObject var functionKeys: FunctionKeyController
    let actions: SettingsActions

    var body: some View {
        Group {
            switch tab {
            case .general: general
            case .permissions: permissions
            case .layout: layout
            case .windows: windows
            case .keyboard: keyboard
            case .keepAwake: keepAwake
            case .check: check
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .frame(width: Self.width, height: tab.height)
    }

    /// Group explanations read left to right and wrap, as in System Settings.
    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Основные

    private var general: some View {
        Form {
            Section {
                Toggle("Запускать при входе в macOS", isOn: Binding(
                    get: { status.loginStatus == .enabled || status.loginStatus == .requiresApproval },
                    set: { _ in actions.toggleLogin() }))
                    .disabled(status.loginChanging)
                if status.loginStatus == .requiresApproval {
                    LabeledContent("macOS ждёт подтверждения") {
                        Button("Открыть настройки входа…", action: actions.openLoginSettings)
                    }
                }
                if let error = status.loginError { Text(error).foregroundStyle(.red) }
            }
            Section {
                Toggle("Показывать подсказки на экране", isOn: $settings.showNotices)
                Toggle("Звук, если замена не удалась", isOn: $settings.beepOnFailure)
            } footer: { note("Подсказка появляется на секунду под строкой меню, когда сочетание клавиш меняет режим.") }
        }
    }

    // MARK: Разрешения

    private var permissions: some View {
        Form {
            Section {
                permission("Универсальный доступ", "Читать слово у курсора, заменять текст и переносить окна.",
                           granted: status.accessibility, request: actions.requestAccessibility)
                permission("Мониторинг ввода", "Замечать двойной Shift. Текст не сохраняется и никуда не отправляется.",
                           granted: status.inputMonitoring, request: actions.requestInputMonitoring)
                permission("Запись экрана", "Только для плавной замены: снимок поля на долю секунды. Можно не выдавать.",
                           granted: status.screenCapture, request: actions.requestScreenCapture)
            } footer: { note("Если SSwitcher нет в списке, добавьте его кнопкой «+» в Системных настройках. После выдачи разрешения macOS может попросить перезапустить программу.") }
        }
    }

    private func permission(_ title: String, _ detail: String, granted: Bool, request: @escaping () -> Void) -> some View {
        LabeledContent {
            if granted {
                Label {
                    Text("Разрешено").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Button("Разрешить…", action: request)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Раскладка

    private var layout: some View {
        Form {
            Section {
                Toggle(isOn: $settings.conversionEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Исправлять по двойному Shift")
                        Text("Выделенный текст или слово, если курсор стоит сразу после него.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Какой Shift", selection: $settings.doubleShiftKeys) {
                    Text("Любой").tag(DoubleShiftKeys.any)
                    Text("Левый").tag(DoubleShiftKeys.left)
                    Text("Правый").tag(DoubleShiftKeys.right)
                }
                .pickerStyle(.segmented)
                .disabled(!settings.conversionEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Slider(value: $settings.doubleShiftInterval, in: AppSettings.intervalRange, step: 0.05) {
                        Text("Скорость нажатий")
                    } minimumValueLabel: {
                        Text("Быстро").font(.caption)
                    } maximumValueLabel: {
                        Text("Медленно").font(.caption)
                    }
                    Text("Оба нажатия должны уложиться в \(Int((settings.doubleShiftInterval * 1000).rounded())) мс.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .disabled(!settings.conversionEnabled)
            }
            Section {
                Toggle("Плавная замена", isOn: $settings.smoothReplacement)
                if settings.smoothReplacement && !status.screenCapture {
                    LabeledContent("Нужна запись экрана") {
                        Button("Разрешить…", action: actions.requestScreenCapture)
                    }
                }
            } footer: { note("Старый текст плавно сменяется новым. Работает в редакторах, которые сообщают положение текста.") }
            Section {
                ApplicationRows(ids: settings.excludedApplications) { id in
                    settings.excludedApplications.removeAll { $0 == id }
                } trailing: { _ in EmptyView() }
                AddApplicationMenu(excluding: Set(settings.excludedApplications)) { id in
                    settings.excludedApplications.append(id)
                }
            } header: {
                Text("Не исправлять в программах")
            } footer: { note("В этих программах двойной Shift ничего не делает. Подходит для игр, терминала и удалённого рабочего стола.") }
        }
    }

    // MARK: Окна

    private var windows: some View {
        Form {
            Section {
                Toggle("Переносить окна между дисплеями", isOn: $settings.windowMovementEnabled)
                LabeledContent("Клавиши") {
                    HStack(spacing: 4) {
                        ForEach([(KeyShortcut.Modifiers.control, "⌃", "Control"), (.option, "⌥", "Option"),
                                 (.shift, "⇧", "Shift"), (.command, "⌘", "Command")], id: \.1) { modifier, symbol, name in
                            Toggle(symbol, isOn: modifierBinding(modifier))
                                .toggleStyle(.button)
                                .accessibilityLabel(name)
                        }
                        Text("+ стрелка").foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.windowMovementEnabled)
            } footer: { note("Нужна хотя бы одна из клавиш ⌃, ⌥ или ⌘. Окно переезжает на дисплей в сторону стрелки.") }
            Section {
                Picker("Стрелки", selection: Binding(
                    get: { settings.windowDirectionsManual },
                    set: { manual in
                        if manual && !settings.windowDirectionsManual && !status.availableDirections.isEmpty {
                            settings.windowDirections = status.availableDirections
                        }
                        settings.windowDirectionsManual = manual
                    })) {
                    Text("По расположению дисплеев").tag(false)
                    Text("Выбрать вручную").tag(true)
                }
                .pickerStyle(.radioGroup)
                if settings.windowDirectionsManual {
                    LabeledContent("Работают") {
                        HStack(spacing: 4) {
                            ForEach(WindowMoveDirection.allCases, id: \.rawValue) { direction in
                                Toggle(WindowShortcutDirections.arrow(direction), isOn: Binding(
                                    get: { settings.windowDirections.contains(direction) },
                                    set: { on in
                                        if on { settings.windowDirections.insert(direction) }
                                        else { settings.windowDirections.remove(direction) }
                                    }))
                                    .toggleStyle(.button)
                            }
                        }
                    }
                }
                DisplayMap(displays: status.displays)
                Text(directionsSummary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let problem = status.windowShortcutProblem { Text(problem).foregroundStyle(.red) }
            }
            .disabled(!settings.windowMovementEnabled)
            if !status.lastWindowResult.isEmpty {
                Section {
                    LabeledContent("Последний перенос") {
                        Text(status.lastWindowResult).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private var directionsSummary: String {
        let mods = settings.windowModifiers.symbols
        if status.displays.count < 2 { return "Сейчас дисплей один. Перенос заработает, когда подключите второй." }
        let active = settings.windowDirectionsManual ? settings.windowDirections : status.availableDirections
        if active.isEmpty { return "Ни одна стрелка не выбрана: перенос выключен." }
        let free = Set(WindowMoveDirection.allCases).subtracting(active)
        let freeText = free.isEmpty ? "" : " \(mods)\(WindowShortcutDirections.arrows(free)) выделяют текст как обычно."
        return "Работают \(mods)\(WindowShortcutDirections.arrows(active)).\(freeText)"
    }

    private func modifierBinding(_ modifier: KeyShortcut.Modifiers) -> Binding<Bool> {
        Binding(
            get: { settings.windowModifiers.contains(modifier) },
            set: { on in
                var value = settings.windowModifiers
                if on { value.insert(modifier) } else { value.remove(modifier) }
                if value.hasShortcutModifier { settings.windowModifiers = value } else { NSSound.beep() }
            })
    }

    // MARK: Клавиатура

    private var keyboard: some View {
        Form {
            Section {
                Picker("Верхний ряд без fn", selection: Binding(get: { functionKeys.baseMode }, set: { functionKeys.baseMode = $0 })) {
                    Text("F1–F12").tag(FunctionKeyMode.standard)
                    Text("Яркость и звук").tag(FunctionKeyMode.media)
                }
                .pickerStyle(.radioGroup)
                HStack {
                    Text("Переключать сочетанием")
                    Spacer()
                    ShortcutField(shortcut: $settings.functionKeyShortcut,
                                  validate: { $0 == settings.keepAwakeShortcut ? "Занято «Не засыпать»" : nil },
                                  onRecordingChange: actions.recordingShortcut)
                        .frame(width: 160, height: 24)
                }
                if status.functionShortcutBlocked {
                    Text("Это сочетание заняла другая программа. Выберите другое.").foregroundStyle(.red)
                }
                if let error = functionKeys.lastError { Text(error).foregroundStyle(.red) }
            } footer: { note("Та же настройка, что в «Системные настройки → Клавиатура». Кнопка fn по-прежнему меняет раскладку. Сочетание меняет режим в текущей программе: если у неё свой режим, меняется только он.") }
            Section {
                ApplicationRows(ids: functionKeys.rules.map(\.id)) { id in
                    functionKeys.setRule(nil, for: id)
                } trailing: { id in
                    Picker("Режим", selection: Binding(
                        get: { functionKeys.policy.rule(for: id) ?? .standard },
                        set: { functionKeys.setRule($0, for: id) })) {
                        Text("F1–F12").tag(FunctionKeyMode.standard)
                        Text("Яркость и звук").tag(FunctionKeyMode.media)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                AddApplicationMenu(excluding: Set(functionKeys.rules.map(\.id))) { id in
                    functionKeys.setRule(functionKeys.baseMode.toggled, for: id)
                }
            } header: {
                Text("Свой режим в программах")
            } footer: { note("Пока программа активна, действует её режим. При переходе в другую программу возвращается общий.") }
        }
    }

    // MARK: Не засыпать

    private var keepAwake: some View {
        Form {
            Section {
                Picker("Не давать засыпать", selection: $settings.keepAwakeSystemOnly) {
                    Text("Экрану и Mac").tag(false)
                    Text("Только Mac, экран может погаснуть").tag(true)
                }
                .pickerStyle(.radioGroup)
                if status.keepAwakeActive {
                    LabeledContent(status.keepAwakeStatus) {
                        Button("Выключить", action: actions.stopKeepAwake)
                    }
                }
            } footer: { note("Изменение действует со следующего включения. Закрытую крышку режим не удерживает: без монитора и зарядки Mac всё равно уснёт.") }
            Section {
                HStack {
                    Text("Включать и выключать сочетанием")
                    Spacer()
                    ShortcutField(shortcut: $settings.keepAwakeShortcut,
                                  validate: { $0 == settings.functionKeyShortcut ? "Занято верхним рядом" : nil },
                                  onRecordingChange: actions.recordingShortcut)
                        .frame(width: 160, height: 24)
                }
                Picker("Включать на", selection: $settings.keepAwakeShortcutMinutes) {
                    ForEach(KeepAwakeDuration.presets, id: \.self) { Text(KeepAwakeDuration.title(minutes: $0)).tag($0) }
                    Text("Пока не выключу").tag(0)
                }
                .disabled(settings.keepAwakeShortcut == nil)
                if status.keepAwakeShortcutBlocked {
                    Text("Это сочетание заняла другая программа. Выберите другое.").foregroundStyle(.red)
                }
            } footer: { note("Нажмите поле и затем сочетание. Delete убирает сочетание, Esc отменяет запись.") }
            if status.hasBattery {
                Section {
                    LabeledContent("Выключать при заряде ниже") {
                        HStack(spacing: 6) {
                            Text("\(settings.keepAwakeBatteryPercent)%").monospacedDigit()
                            Stepper("Порог заряда", value: $settings.keepAwakeBatteryPercent,
                                    in: KeepAwakeBatteryRule.percentRange, step: 5)
                                .labelsHidden()
                        }
                    }
                    Toggle("Выключать, когда Mac отключили от зарядки", isOn: $settings.keepAwakeStopOnUnplug)
                } header: {
                    Text("Батарея")
                }
            }
        }
    }

    // MARK: Проверка

    private var check: some View {
        Form {
            Section {
                LabeledContent("Последний двойной Shift", value: status.lastAttempt)
                LabeledContent("Результат") {
                    Text(status.lastResult).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                HStack {
                    Button("Открыть тестовое окно…", action: actions.openTestWindow)
                    Spacer()
                    Button("Скопировать отчёт", action: actions.copyReport)
                }
            } footer: { note("В тестовом окне поставьте курсор после ghbdtn и дважды нажмите Shift: должно получиться «привет». Отчёт не содержит набранного текста.") }
            Section {
                DisclosureGroup("Подробности") {
                    ScrollView {
                        Text(status.diagnostics)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                }
            }
        }
    }
}

/// Icon, name and a remove button per application, as in System Settings lists.
private struct ApplicationRows<Trailing: View>: View {
    let ids: [String]
    let remove: (String) -> Void
    @ViewBuilder let trailing: (String) -> Trailing

    var body: some View {
        if ids.isEmpty {
            Text("Программ пока нет").foregroundStyle(.secondary)
        }
        ForEach(ids, id: \.self) { id in
            HStack(spacing: 8) {
                Image(nsImage: AppIdentity.icon(of: id)).resizable().frame(width: 20, height: 20)
                Text(AppIdentity.name(of: id))
                Spacer()
                trailing(id)
                Button { remove(id) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .help("Убрать из списка")
                    .accessibilityLabel("Убрать \(AppIdentity.name(of: id))")
            }
        }
    }
}

/// Running applications first, then any application from the Applications folder.
private struct AddApplicationMenu: View {
    let excluding: Set<String>
    let add: (String) -> Void

    var body: some View {
        Menu {
            let running = AppIdentity.runningApplications(excluding: excluding)
            if !running.isEmpty {
                Section("Запущенные") {
                    ForEach(running, id: \.id) { app in Button(app.name) { add(app.id) } }
                }
            }
            Button("Другая программа…") {
                if let id = AppIdentity.chooseApplication(), !excluding.contains(id), id != Bundle.main.bundleIdentifier { add(id) }
            }
        } label: {
            Label("Добавить программу", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// The display arrangement in miniature, like System Settings → Displays.
private struct DisplayMap: View {
    let displays: [SettingsStatus.Display]

    var body: some View {
        GeometryReader { proxy in
            let bounds = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
            let scale = bounds.isNull ? 1 : min((proxy.size.width - 8) / bounds.width, (proxy.size.height - 8) / bounds.height)
            let offsetX = (proxy.size.width - bounds.width * scale) / 2
            let offsetY = (proxy.size.height - bounds.height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(displays) { display in
                    let rect = CGRect(x: offsetX + (display.frame.minX - bounds.minX) * scale,
                                      y: offsetY + (bounds.maxY - display.frame.maxY) * scale,
                                      width: display.frame.width * scale, height: display.frame.height * scale)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(display.isMain ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1))
                        .overlay(alignment: .top) {
                            if display.isMain {
                                Rectangle().fill(Color.accentColor.opacity(0.35)).frame(height: 3)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .overlay(Text(display.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding(4))
                        .frame(width: max(rect.width - 2, 1), height: max(rect.height - 2, 1))
                        .offset(x: rect.minX + 1, y: rect.minY + 1)
                }
            }
        }
        .frame(height: 120)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displays.count < 2 ? "Один дисплей" : "Дисплеи: " + displays.map(\.name).joined(separator: ", "))
    }
}
