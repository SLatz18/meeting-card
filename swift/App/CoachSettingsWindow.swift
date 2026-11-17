import AppKit
import ListenMoreCore
import MeetingCardCore

/// Call coach Settings: a standard titled window with grouped rows (the approved mock). Opened by
/// reopening the app (Finder / Spotlight / `open -a`) or from the coach status item. The first
/// open shows the three onboarding screens.
@MainActor
final class CoachSettingsWindow: NSObject, NSWindowDelegate {
    let coach: CoachController
    let window: NSWindow
    private var screen = 0
    private var showingOnboarding: Bool
    private let toggle = NSSwitch()
    private let startButton = NSButton(title: CoachCopy.startNow, target: nil, action: nil)
    private let toggleError = CoachSettingsWindow.text("", font: Theme.Settings.helperFont, color: .systemRed)
    private let permissionNote = CoachSettingsWindow.text(CoachCopy.permissionDenied, font: Theme.Settings.helperFont, color: .systemRed)
    private let keyField = NSSecureTextField()
    private let keyStatus = CoachSettingsWindow.text("", font: Theme.Settings.helperFont, color: .systemRed)
    private let anyAppBox = NSButton(checkboxWithTitle: CoachCopy.anyApp, target: nil, action: nil)
    private var appsStack = NSStackView()

    /// `onboardingScreen` forces that onboarding screen (CI screenshots).
    init(coach: CoachController, onboardingScreen: Int? = nil) {
        self.coach = coach
        showingOnboarding = onboardingScreen != nil || !coach.onboarded
        screen = onboardingScreen ?? 0
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.Settings.width, height: 420),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "MeetingCard"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = .windowBackgroundColor
        build()
    }

    func present() {
        update()
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: building blocks

    static let groupPadding = NSSize(width: 18, height: 14)
    static let outerWidth = CGFloat(Theme.Settings.width - 2 * Theme.Settings.inset)
    static let innerWidth = outerWidth - 2 * groupPadding.width

    static func text(_ s: String, font: Theme.FontSpec, color: NSColor = .labelColor, maxWidth: CGFloat = innerWidth) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = Theme.font(font)
        f.preferredMaxLayoutWidth = maxWidth
        f.textColor = color
        f.isSelectable = false
        return f
    }

    /// Rounded `controlBackgroundColor` group whose height follows its stack (constraints, unlike an
    /// NSBox content view).
    final class Group: NSView {
        let stack: NSStackView
        init(_ views: [NSView]) {
            stack = NSStackView(views: views)
            super.init(frame: .zero)
            wantsLayer = true
            applyFill()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            let p = CoachSettingsWindow.groupPadding
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: p.width),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -p.width),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: p.height),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -p.height),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyFill()
        }

        private func applyFill() {
            layer?.cornerRadius = CGFloat(Theme.Settings.groupRadius)
            layer?.cornerCurve = .continuous
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            }
        }
    }

    static func group(_ views: [NSView]) -> Group { Group(views) }

    static func row(_ left: NSView, _ right: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let r = NSStackView(views: [left, spacer, right])
        r.orientation = .horizontal
        r.alignment = .centerY
        return r
    }

    private func pin(_ inner: NSView, in group: Group) {
        inner.widthAnchor.constraint(equalTo: group.stack.widthAnchor).isActive = true
    }

    // MARK: content

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 20, left: CGFloat(Theme.Settings.inset), bottom: 24, right: CGFloat(Theme.Settings.inset))
        let width = Self.outerWidth
        let views = showingOnboarding ? onboardingViews() : settingsViews()
        for v in views {
            root.addArrangedSubview(v)
            v.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        window.contentView = root
        update()
    }

    private func fitWindow() {
        guard let root = window.contentView else { return }
        root.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: CGFloat(Theme.Settings.width), height: root.fittingSize.height))
    }

    private func onboardingViews() -> [NSView] {
        let s = CoachCopy.onboarding[screen]
        let glyph = NSImageView(image: NSImage(systemSymbolName: Theme.Coach.symbol, accessibilityDescription: CoachCopy.toggle)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium)) ?? NSImage())
        let title = Self.text(s.title, font: Theme.Fonts.title)
        let body = Self.text(s.body, font: Theme.Fonts.body, color: .secondaryLabelColor)
        let primary = NSButton(title: s.primary, target: self, action: #selector(onboardingPrimary(_:)))
        primary.keyEquivalent = "\r"
        var buttons: [NSView] = []
        if let secondary = s.secondary { buttons.append(NSButton(title: secondary, target: self, action: #selector(onboardingNotNow(_:)))) }
        buttons.append(primary)
        let buttonRow = NSStackView(views: buttons)
        let dots = Self.text("\(screen + 1) of \(CoachCopy.onboarding.count)", font: Theme.Settings.helperFont, color: .tertiaryLabelColor)
        let box = Self.group([glyph, title, body, Self.row(dots, buttonRow)])
        for v in [title, body] { pin(v, in: box) }
        if let r = box.stack.arrangedSubviews.last { pin(r, in: box) }
        return [box]
    }

    @objc private func onboardingPrimary(_ sender: Any?) {
        if screen < CoachCopy.onboarding.count - 1 {
            screen += 1
        } else {
            coach.markOnboarded()
            showingOnboarding = false
        }
        build()
        if !showingOnboarding { window.makeFirstResponder(keyField) }
    }

    @objc private func onboardingNotNow(_ sender: Any?) {
        coach.markOnboarded()
        showingOnboarding = false
        build()
        window.close()
    }

    private func settingsViews() -> [NSView] {
        let section = Self.text(CoachCopy.section, font: Theme.Settings.sectionFont, color: .secondaryLabelColor,
                                maxWidth: Self.outerWidth)

        toggle.target = self
        toggle.action = #selector(toggled(_:))
        toggle.setAccessibilityLabel(CoachCopy.toggle)
        startButton.target = self
        startButton.action = #selector(startNow(_:))
        startButton.bezelStyle = .rounded
        startButton.controlSize = .small
        let toggleRow = Self.row(Self.text(CoachCopy.toggle, font: Theme.Settings.rowFont), toggle)
        let help = Self.text(CoachCopy.toggleHelp, font: Theme.Settings.helperFont, color: .secondaryLabelColor)
        let g1 = Self.group([toggleRow, help, toggleError, permissionNote, startButton])
        for v in [toggleRow, help, toggleError, permissionNote] { pin(v, in: g1) }

        keyField.placeholderString = coach.hasKey ? CoachCopy.keySavedPlaceholder : CoachCopy.keyPlaceholder
        keyField.font = Theme.font(Theme.Fonts.body)
        keyField.target = self
        keyField.action = #selector(keyEntered(_:))
        keyField.setAccessibilityLabel(CoachCopy.keyLabel)
        let lock = NSImageView(image: NSImage(systemSymbolName: "lock", accessibilityDescription: nil) ?? NSImage())
        lock.contentTintColor = .secondaryLabelColor
        let keyRow = NSStackView(views: [keyField, lock])
        keyRow.orientation = .horizontal
        let keyHelp = Self.text(CoachCopy.keyHelp, font: Theme.Settings.helperFont, color: .secondaryLabelColor)
        let g2 = Self.group([Self.text(CoachCopy.keyLabel, font: Theme.Settings.rowFont), keyRow, keyHelp, keyStatus])
        for v in [keyRow, keyHelp, keyStatus] { pin(v, in: g2) }

        let add = NSButton(title: CoachCopy.add, target: self, action: #selector(addApp(_:)))
        add.bezelStyle = .rounded
        let header = Self.row(Self.text(CoachCopy.allowedApps, font: Theme.Settings.rowFont), add)
        appsStack = NSStackView()
        appsStack.orientation = .vertical
        appsStack.alignment = .leading
        appsStack.spacing = 8
        anyAppBox.target = self
        anyAppBox.action = #selector(anyAppToggled(_:))
        anyAppBox.font = Theme.font(Theme.Settings.helperFont)
        let g3 = Self.group([header, appsStack, anyAppBox])
        for v in [header, appsStack] { pin(v, in: g3) }
        rebuildApps()

        let privacy = Self.text(CoachCopy.privacy + " " + CoachCopy.pausedPrivacy, font: Theme.Settings.helperFont,
                                color: .secondaryLabelColor, maxWidth: Self.outerWidth)
        return [section, g1, g2, g3, privacy]
    }

    private func appName(_ bundleId: String) -> String {
        if let t = coach.config.captureTargets.first(where: { $0.bundleId == bundleId }) { return t.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleId
    }

    private func rebuildApps() {
        appsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, id) in coach.effectiveAllowlist.enumerated() {
            let name = Self.text(appName(id), font: Theme.Settings.rowFont)
            let detail = Self.text(id, font: Theme.Settings.helperFont, color: .secondaryLabelColor)
            let labels = NSStackView(views: [name, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 1
            let minus = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: CoachCopy.remove) ?? NSImage(),
                                 target: self, action: #selector(removeApp(_:)))
            minus.isBordered = false
            minus.tag = i
            minus.setAccessibilityLabel("\(CoachCopy.remove) \(appName(id))")
            let r = Self.row(labels, minus)
            appsStack.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: appsStack.widthAnchor).isActive = true
        }
    }

    // MARK: state

    func update() {
        defer { fitWindow() }
        guard !showingOnboarding else { return }
        toggle.state = coach.enabled ? .on : .off
        startButton.isHidden = !(coach.enabled && (coach.indicator == .hidden || coach.indicator == .on))
        permissionNote.isHidden = !(coach.enabled && coach.service?.captureProblem == true)
        anyAppBox.state = coach.anyApp ? .on : .off
        toggleError.stringValue = message(coach.keyProblem) ?? ""
        toggleError.isHidden = toggleError.stringValue.isEmpty
        keyStatus.isHidden = keyStatus.stringValue.isEmpty
    }

    private func message(_ k: KeyCheck?) -> String? {
        switch k {
        case nil, .ok?: nil
        case .empty?: CoachCopy.keyEmpty
        case .rejected?: CoachCopy.keyRejected
        case .unreachable?: CoachCopy.keyUnreachable
        }
    }

    // MARK: actions

    @objc private func toggled(_ sender: NSSwitch) {
        coach.setEnabled(sender.state == .on) { [weak self] _ in self?.update() }
        update()
    }

    @objc private func startNow(_ sender: Any?) { coach.startClicked(sender) }

    @objc private func keyEntered(_ sender: NSSecureTextField) {
        let text = sender.stringValue
        sender.stringValue = ""
        coach.saveKey(text) { [weak self] check in
            guard let self else { return }
            self.keyStatus.stringValue = self.message(check) ?? ""
            self.keyField.placeholderString = self.coach.hasKey ? CoachCopy.keySavedPlaceholder : CoachCopy.keyPlaceholder
            self.update()
        }
    }

    @objc private func anyAppToggled(_ sender: NSButton) { coach.setAnyApp(sender.state == .on) }

    @objc private func addApp(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
            var list = self.coach.effectiveAllowlist
            if !list.contains(id) { list.append(id) }
            self.coach.setAllowlist(list)
            self.rebuildApps()
            self.build()
        }
    }

    @objc private func removeApp(_ sender: NSButton) {
        var list = coach.effectiveAllowlist
        guard list.indices.contains(sender.tag) else { return }
        list.remove(at: sender.tag)
        coach.setAllowlist(list)
        rebuildApps()
        build()
    }
}
