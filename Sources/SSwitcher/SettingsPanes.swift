import AppKit
import SwiftUI
import SwitcherCore

/// Every pane is a grouped form, like System Settings: labels on the left,
/// controls on the right, one short explanation under a group.
struct SettingsPanes: View {
    static let width: CGFloat = 600
    /// Every pane shares the window size; a longer pane scrolls.
    static let height: CGFloat = 540
    let tab: SettingsTab
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: SettingsStatus
    @ObservedObject var functionKeys: FunctionKeyController
    @ObservedObject var displays: DisplayController
    @ObservedObject var mouse: MouseController
    let actions: SettingsActions

    var body: some View {
        Group {
            switch tab {
            case .general: general
            case .displays: displayPane
            case .layout: layout
            case .windows: windows
            case .keyboard: keyboard
            case .mouse: mousePane
            case .keepAwake: keepAwake
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        // Fills the pane; under the macOS 27 toolbar the form scrolls beneath the title.
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
    }

    /// Group explanations read left to right and wrap, as in System Settings.
    private func note(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A control's title with a wrapping caption under it.
    private func titled(_ title: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A recorder for one SSwitcher shortcut. `other` is the other shortcut
    /// it cannot share, read when a combination is checked.
    private func shortcutRow(_ title: String, _ shortcut: Binding<KeyShortcut?>,
                             besides other: KeyPath<AppSettings, KeyShortcut?>, _ otherName: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            ShortcutField(shortcut: shortcut,
                          validate: { ownConflict($0, besides: settings[keyPath: other], otherName) },
                          confirm: actions.confirmShortcut,
                          onRecordingChange: actions.recordingShortcut)
                .frame(width: 160, height: 24)
        }
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
            permissionSection
        }
    }

    // MARK: Разрешения

    private var permissionSection: some View {
            Section {
                permission("Универсальный доступ", "Читать слово у курсора, заменять текст и переносить окна.",
                           granted: status.accessibility, request: actions.requestAccessibility)
                permission("Мониторинг ввода", "Замечать двойное нажатие клавиши. Текст не сохраняется и никуда не отправляется.",
                           granted: status.inputMonitoring, request: actions.requestInputMonitoring)
                permission("Запись экрана", "Только для MAX: снимок окна на долю секунды прикрывает выделение слова. Можно не выдавать.",
                           granted: status.screenCapture, request: actions.requestScreenCapture)
            } header: {
                Text("Разрешения macOS")
            } footer: { note("Если SSwitcher нет в списке, добавьте его кнопкой «+» в Системных настройках. После выдачи разрешения macOS может попросить перезапустить программу.") }
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
            titled(title, detail)
        }
    }

    // MARK: Раскладка

    private var layout: some View {
        Form {
            Section {
                Toggle(isOn: $settings.conversionEnabled) {
                    titled("Исправлять раскладку текста",
                           "Набрали «ghbdtn» вместо «привет»? Дважды нажмите клавишу, и текст станет правильным: выделенный или слово перед курсором.")
                }
                Picker("Клавиша", selection: Binding(
                    get: { settings.triggerKey },
                    set: { trigger in
                        guard trigger != settings.triggerKey, actions.confirmTrigger(trigger) else { return }
                        settings.triggerKey = trigger
                    })) {
                    ForEach(TriggerKey.allCases, id: \.rawValue) { Text("\($0.symbol) \($0.name)").tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.conversionEnabled)
                Picker("Какая из двух", selection: $settings.triggerSide) {
                    Text("Любая").tag(TriggerSide.any)
                    Text("Левая").tag(TriggerSide.left)
                    Text("Правая").tag(TriggerSide.right)
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
            } footer: { note("Сейчас: \(settings.triggerPhrase.lowercased()). Перед сменой клавиши SSwitcher проверит, не занято ли её двойное нажатие в macOS или запущенных программах.") }
            Section {
                ApplicationRows(ids: settings.excludedApplications) { id in
                    settings.excludedApplications.removeAll { $0 == id }
                } trailing: { _ in EmptyView() }
                AddApplicationMenu(excluding: Set(settings.excludedApplications)) { id in
                    settings.excludedApplications.append(id)
                }
            } header: {
                Text("Не исправлять в программах")
            } footer: { note("В этих программах \(settings.triggerPhrase.lowercased()) ничего не делает. Подходит для игр, терминала и удалённого рабочего стола.") }
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
                        Text("+ стрелка").foregroundStyle(.secondary).fixedSize()
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

    /// Another SSwitcher shortcut, including window arrows, cannot be shared.
    private func ownConflict(_ shortcut: KeyShortcut, besides other: KeyShortcut?, _ name: String) -> String? {
        if shortcut == other { return "Занято \(name)" }
        if settings.windowMovementEnabled, WindowMoveDirection.allCases.contains(where: { $0.keyCode == shortcut.keyCode }), shortcut.modifiers == settings.windowModifiers {
            return "Занято переносом окон"
        }
        return nil
    }

    private func modifierBinding(_ modifier: KeyShortcut.Modifiers) -> Binding<Bool> {
        Binding(
            get: { settings.windowModifiers.contains(modifier) },
            set: { on in
                var value = settings.windowModifiers
                if on { value.insert(modifier) } else { value.remove(modifier) }
                guard value.hasShortcutModifier else { NSSound.beep(); return }
                if actions.confirmWindowModifiers(value) { settings.windowModifiers = value }
            })
    }

    // MARK: Дисплеи

    private var displayPane: some View {
        Form {
            ForEach(displays.displays) { display in
                Section {
                    LabeledContent("Разрешение монитора", value: display.nativeWidth > 0 ? "\(display.nativeWidth) × \(display.nativeHeight)" : "неизвестно")
                    if !display.isBuiltin { hiDPIRow(display) }
                    sizeRow(display)
                    if displays.pendingRestart.contains(display.overridePath) {
                        Text("Перезагрузите Mac, чтобы изменение вступило в силу.").foregroundStyle(.orange)
                    }
                } header: {
                    Text(display.name)
                }
            }
            if let message = displays.lastMessage {
                Section { Text(message).foregroundStyle(.secondary) }
            }
            let managed = displays.displays.filter { !$0.isBuiltin && $0.overrideExists }
            if !managed.isEmpty {
                Section {
                    ForEach(managed) { display in
                        LabeledContent("Файл-описание «\(display.name)»") {
                            Button("Удалить…") { displays.removeOverride(for: display) }
                                .disabled(displays.isChangingOverride)
                        }
                    }
                } header: {
                    Text("Дополнительно")
                } footer: { note("Файл-описание добавляет монитору размеры HiDPI. Удаляйте его, только если HiDPI для этого монитора не нужен совсем: после перезагрузки Mac переключатель HiDPI исчезнет. Копия файла сохраняется, а добавить его снова можно кнопкой «Добавить размеры HiDPI…».") }
            }
            Section {
                EmptyView()
            } footer: { note("В режиме HiDPI интерфейс рисуется в два раза подробнее и уменьшается до экрана, как на Retina: текст выглядит резче. Это делает сама macOS, поэтому SSwitcher ничего не держит запущенным и не нагружает видеокарту.") }
        }
    }

    /// A switch when the monitor offers HiDPI sizes, otherwise the way to add them.
    @ViewBuilder
    private func hiDPIRow(_ display: DisplayController.Display) -> some View {
        if display.hasHiDPI {
            Toggle(isOn: Binding(
                get: { display.current?.hiDPI == true },
                set: { on in on ? displays.makeCrisp(display) : displays.makeNative(display) })) {
                titled("HiDPI", "Текст и интерфейс резче, как на Retina")
            }
        } else if display.overrideExists {
            LabeledContent("HiDPI", value: "появится после перезагрузки Mac")
        } else {
            LabeledContent {
                Button("Добавить размеры HiDPI…") { displays.installOverride(for: display) }
                    .disabled(displays.isChangingOverride)
            } label: {
                titled("HiDPI", "macOS не предлагает HiDPI для этого монитора")
            }
        }
    }

    /// The sizes of the current kind (HiDPI or not) on a slider, smallest
    /// text on the right, like BetterDisplay's resolution slider.
    @ViewBuilder
    private func sizeRow(_ display: DisplayController.Display) -> some View {
        let hiDPI = display.isBuiltin || display.current?.hiDPI == true
        let sizes = display.sizes.filter { $0.hiDPI == hiDPI }.sorted { $0.width < $1.width }
        if sizes.count > 1 {
            SizeSlider(sizes: sizes, current: display.current) { displays.select($0, on: display) }
        } else if let current = display.current {
            LabeledContent("Размер интерфейса") { Text(verbatim: "\(current.width) × \(current.height)") }
        }
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
                shortcutRow("Переключать сочетанием", $settings.functionKeyShortcut,
                            besides: \.keepAwakeShortcut, "«Не засыпать»")
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

    // MARK: Мышь

    private var mousePane: some View {
        Form {
            if !status.accessibility {
                Section {
                    LabeledContent {
                        Button("Разрешить…", action: actions.requestAccessibility)
                    } label: {
                        titled("Нужен Универсальный доступ", "Без него SSwitcher не может менять прокрутку и кнопки мыши.")
                    }
                }
            }
            Section {
                Toggle(isOn: $settings.mouseWheelReversed) {
                    titled("Обратная прокрутка колеса",
                           "Колесо мыши крутит страницу в другую сторону. Трекпад и Magic Mouse прокручивают как прежде.")
                }
            }
            Section {
                if settings.mouseButtons.isEmpty && !mouse.isRecording {
                    Text("Кнопок пока нет").foregroundStyle(.secondary)
                }
                ForEach(settings.mouseButtons) { binding in
                    mouseButtonRow(binding)
                }
                if mouse.isRecording {
                    LabeledContent("Нажмите кнопку мыши…") {
                        Button("Отмена") { mouse.cancelRecording() }
                    }
                } else {
                    Button("Добавить кнопку…", action: recordMouseButton)
                        .disabled(!status.accessibility)
                }
            } header: {
                Text("Кнопки мыши")
            } footer: { note("Нажмите «Добавить кнопку…», а затем среднюю или боковую кнопку мыши, можно вместе с ⌘, ⌥, ⌃ или ⇧. Левая и правая кнопки не назначаются. «Назад» и «Вперёд» нажимают ⌘[ и ⌘]: так листают браузеры, Finder и большинство программ.") }
        }
    }

    private func mouseButtonRow(_ binding: MouseButtonBinding) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "computermouse").foregroundStyle(.secondary)
            Text(binding.title)
            Spacer()
            if case .shortcut(let keys) = binding.action {
                ShortcutField(shortcut: Binding(get: { keys }, set: { setMouseAction(.shortcut($0), for: binding.id) }),
                              anyKey: true, onRecordingChange: actions.recordingShortcut)
                    .frame(width: 130, height: 24)
            }
            Picker("Действие", selection: Binding(
                get: { binding.action.kind },
                set: { kind in if kind != binding.action.kind { setMouseAction(MouseAction(kind: kind), for: binding.id) } })) {
                ForEach(MouseAction.Kind.allCases, id: \.self) { Text(Self.title(of: $0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Button { settings.mouseButtons.removeAll { $0.id == binding.id } } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Убрать кнопку")
            .accessibilityLabel("Убрать: \(binding.title)")
        }
    }

    private func setMouseAction(_ action: MouseAction, for id: String) {
        guard let index = settings.mouseButtons.firstIndex(where: { $0.id == id }) else { return }
        settings.mouseButtons[index].action = action
    }

    /// A button already in the list keeps its action.
    private func recordMouseButton() {
        mouse.record { button, modifiers in
            guard !settings.mouseButtons.contains(where: { $0.matches(button: button, modifiers: modifiers) }),
                  let binding = MouseButtonBinding(button: button, modifiers: modifiers,
                                                   action: MouseButtonBinding.suggestedAction(for: button)) else { return }
            settings.mouseButtons.append(binding)
        }
    }

    private static func title(of kind: MouseAction.Kind) -> String {
        switch kind {
        case .back: "Назад"
        case .forward: "Вперёд"
        case .missionControl: "Mission Control"
        case .applicationWindows: "Окна программы"
        case .desktop: "Рабочий стол"
        case .spaceLeft: "Пространство слева"
        case .spaceRight: "Пространство справа"
        case .shortcut: "Сочетание клавиш"
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
                shortcutRow("Включать и выключать сочетанием", $settings.keepAwakeShortcut,
                            besides: \.functionKeyShortcut, "верхним рядом")
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
}

/// Steps through sizes while dragging and applies the size on release, so
/// the display switches once, not at every step.
private struct SizeSlider: View {
    let sizes: [DisplayController.Size]
    let current: DisplayController.Size?
    let apply: (DisplayController.Size) -> Void
    @State private var position: Double?

    private var currentIndex: Double {
        Double(sizes.firstIndex { $0 == current } ?? sizes.firstIndex { $0.width == current?.width } ?? 0)
    }

    var body: some View {
        let index = Int((position ?? currentIndex).rounded())
        let shown = sizes[min(max(index, 0), sizes.count - 1)]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Размер интерфейса")
                Spacer()
                Text(verbatim: "\(shown.width) × \(shown.height)").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { position ?? currentIndex }, set: { position = $0 }),
                   in: 0...Double(sizes.count - 1), step: 1) {
                Text("Размер интерфейса")
            } minimumValueLabel: {
                Text("Крупнее").font(.caption)
            } maximumValueLabel: {
                Text("Больше места").font(.caption)
            } onEditingChanged: { editing in
                guard !editing, let position else { return }
                let chosen = sizes[min(max(Int(position.rounded()), 0), sizes.count - 1)]
                self.position = nil
                if chosen != current { apply(chosen) }
            }
            .labelsHidden()
            .accessibilityValue(Text(verbatim: "\(shown.width) × \(shown.height)"))
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
