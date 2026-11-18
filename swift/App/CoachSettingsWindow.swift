import AppKit
import ListenMoreCore
import ListenMoreMac
import MeetingCardCore

/// Call coach Settings: a standard titled window with grouped rows (the approved mock). Opened by
/// reopening the app (Finder / Spotlight / `open -a`) or from the coach status item. The first
/// open shows the three onboarding screens, which are the card itself: a borderless, clear,
/// shadowless window whose only surface is the card-shaped group (no window plate behind it).
@MainActor
final class CoachSettingsWindow: NSObject, NSWindowDelegate {
    let coach: CoachController
    private(set) var window: NSWindow
    private var screen = 0
    private var showingOnboarding: Bool
    private let toggle = NSSwitch()
    private let startButton = NSButton(title: CoachCopy.startNow, target: nil, action: nil)
    private let toggleError = CoachSettingsWindow.text("", font: Theme.Settings.helperFont, color: CoachSettingsWindow.color(.critical))
    private let gptNote = CoachSettingsWindow.text(CoachCopy.gptOffNoKey, font: Theme.Settings.helperFont, color: CoachSettingsWindow.color(.secondary))
    private let noMicNote = CoachSettingsWindow.text(CoachCardCopy.NoMicNotice.settingsNote, font: Theme.Settings.helperFont,
                                                     color: CoachSettingsWindow.color(.secondary))
    private let permissionNote = CoachSettingsWindow.text(CoachCopy.permissionDenied, font: Theme.Settings.helperFont, color: CoachSettingsWindow.color(.critical))
    private let keyField = NSSecureTextField()
    private let keyStatus = CoachSettingsWindow.text("", font: Theme.Settings.helperFont, color: CoachSettingsWindow.color(.critical))
    private let anyAppBox = NSButton(checkboxWithTitle: CoachCopy.anyApp, target: nil, action: nil)
    private let callControlsSwitch = NSSwitch()
    private let callControlsNote = CoachSettingsWindow.text("", font: Theme.CallControls.explainerFont,
                                                            color: CoachSettingsWindow.color(Theme.CallControls.explainerText))
    private let requestAccessButton = NSButton(title: CoachCopy.requestAccess, target: nil, action: nil)
    private var appsStack = NSStackView()
    private let judgePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let judgeHelp = CoachSettingsWindow.text("", font: Theme.Settings.helperFont, color: CoachSettingsWindow.color(.secondary))
    private let typeSafeKeyField = NSSecureTextField()
    private var typeSafeKeyRow = NSStackView()
    private let typeSafeNote = CoachSettingsWindow.text(CoachCopy.typeSafeKeyMissing, font: Theme.Settings.helperFont,
                                                        color: CoachSettingsWindow.color(.secondary))
    private let judgeStoppedNote = CoachSettingsWindow.text("", font: Theme.Settings.helperFont, color: CoachSettingsWindow.color(.critical))
    private let root = NSStackView()
    private let document = NSView()
    private let scroll = NSScrollView()
    private var rootWidth: NSLayoutConstraint!
    /// CI screenshots only: a shorter visible frame, to show the groups scrolling.
    private let visibleHeightOverride: Double?
    private let captionsToggle = NSSwitch()
    private let savingToggle = NSSwitch()
    private let transcriptNote = CoachSettingsWindow.text(CoachCopy.transcriptNeedsKey, font: Theme.Settings.helperFont,
                                                          color: CoachSettingsWindow.color(.secondary))
    private let folderPath = NSTextField(labelWithString: "")
    private let chooseFolderButton = NSButton(title: CoachCopy.chooseFolder, target: nil, action: nil)
    /// The same saving indicator as on screen during the call (the Kit's caption view).
    /// The saving indicator, as the card shows it (Theme.Captions; the card's secondary control).
    private let savingHolder = SavingPill(label: CoachCopy.savingNow)
    private let transcriptStatus = CoachSettingsWindow.text("", font: Theme.Settings.helperFont, color: CoachSettingsWindow.color(.secondary))
    private let deleteButton = NSButton(title: CoachCopy.deleteTranscript, target: nil, action: nil)
    private let youField = NSTextField()
    private let themField = NSTextField()
    private let costLabel = CoachSettingsWindow.text("", font: Theme.Captions.costFont, color: CoachSettingsWindow.color(Theme.Captions.cost))
    private var notice: CoachNotice?
    /// Snapshots: the Captions and transcript group on its own.
    private(set) var transcriptGroupView: NSView?

    /// `onboardingScreen` forces that onboarding screen (CI screenshots).
    init(coach: CoachController, onboardingScreen: Int? = nil, visibleHeightOverride: Double? = nil) {
        self.coach = coach
        self.visibleHeightOverride = visibleHeightOverride
        showingOnboarding = onboardingScreen != nil || !coach.onboarded
        screen = onboardingScreen ?? 0
        window = Self.makeWindow(onboarding: showingOnboarding)
        super.init()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        root.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(root)
        rootWidth = root.widthAnchor.constraint(equalToConstant: CGFloat(windowWidth))
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: document.topAnchor),
            root.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rootWidth,
        ])
        adopt(window)
        build()
    }

    /// Onboarding's window: key-capable while borderless, so Return (the primary button) and Esc
    /// (close) work; dragged by its background.
    final class CardWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
        override func cancelOperation(_ sender: Any?) { close() }
    }

    static func makeWindow(onboarding: Bool) -> NSWindow {
        let rect = NSRect(x: 0, y: 0, width: Theme.Settings.groupWidth, height: Theme.Metrics.cardHeight)
        guard !onboarding else {
            let w = CardWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = CardStyle.Material.shadow
            w.isMovableByWindowBackground = true
            return w
        }
        let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "MeetingCard"
        w.backgroundColor = .windowBackgroundColor
        return w
    }

    private func adopt(_ w: NSWindow) {
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = scroll
    }

    /// Onboarding: the group alone, card width. Settings: the groups inset in a titled window.
    private var windowWidth: Double { showingOnboarding ? Theme.Settings.groupWidth : Theme.Settings.width }

    /// Moves the content into the window kind the current mode needs (onboarding ending swaps the
    /// card window for the titled Settings window). Returns true if it swapped a visible window.
    private func useWindowForMode() -> Bool {
        guard (window is CardWindow) != showingOnboarding else { return false }
        let old = window
        let wasVisible = old.isVisible
        window = Self.makeWindow(onboarding: showingOnboarding)
        adopt(window)
        old.delegate = nil
        old.orderOut(nil)
        return wasVisible
    }

    /// Snapshots: the groups' stack (layer render can't draw the scroll view upright) and the
    /// height of it the window shows, from the top.
    var snapshotContent: (view: NSView, visibleHeight: CGFloat) { (root, scroll.contentView.bounds.height) }
    /// The Call coach switch reads on (CI's Start Coach check, `UISnapshots.startToggleCheck`).
    var coachSwitchOn: Bool { toggle.state == .on }

    func present() {
        window.center()
        update()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        updateCallControls()
        fitWindow()
    }

    // MARK: building blocks

    static let groupPadding = NSSize(width: Theme.Settings.groupPadding.h, height: Theme.Settings.groupPadding.v)
    static let outerWidth = CGFloat(Theme.Settings.groupWidth)
    static let innerWidth = outerWidth - 2 * groupPadding.width

    /// A CardStyle text role in the current appearance.
    static func color(_ t: CardStyle.Text) -> NSColor { Theme.text(t, Theme.style(dark: Theme.isDark)) }

    static func text(_ s: String, font: Theme.FontSpec, color: NSColor? = nil, maxWidth: CGFloat = innerWidth) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = Theme.font(font)
        f.preferredMaxLayoutWidth = maxWidth
        f.textColor = color ?? Self.color(.primary)
        f.isSelectable = false
        return f
    }

    /// A card-shaped group (card fill and radius, the card's text insets) whose height follows its
    /// stack (constraints, unlike an NSBox content view).
    final class Group: NSView {
        let stack: NSStackView
        init(_ views: [NSView]) {
            stack = NSStackView(views: views)
            super.init(frame: .zero)
            wantsLayer = true
            applyFill()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = CGFloat(Theme.Settings.groupSpacing)
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
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            layer?.backgroundColor = Theme.ns(Theme.Settings.groupFill(style: Theme.style(dark: dark))).cgColor
        }
    }

    /// The saving indicator in AppKit: Ignore fill, hairline and control radius and height, a
    /// critical-red dot and the label, all from Theme.Captions (the card's CaptionSavingIndicator).
    final class SavingPill: NSView {
        private let dot = NSView()
        init(label: String) {
            super.init(frame: .zero)
            let c = Theme.Captions.self
            wantsLayer = true
            dot.wantsLayer = true
            let text = NSTextField(labelWithString: label)
            text.font = Theme.font(c.indicatorFont)
            text.textColor = CoachTranscript.color(c.savingLabel)
            let stack = NSStackView(views: [dot, text])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = Theme.cg(c.indicatorGap)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: Theme.cg(c.dotDiameter)),
                dot.heightAnchor.constraint(equalToConstant: Theme.cg(c.dotDiameter)),
                heightAnchor.constraint(equalToConstant: Theme.cg(c.indicatorHeight)),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.cg(c.indicatorPadding)),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.cg(c.indicatorPadding)),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(label)
            applyChrome()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyChrome()
        }

        private func applyChrome() {
            let c = Theme.Captions.self
            let style = Theme.style(dark: CoachTranscript.isDark(effectiveAppearance))
            layer?.cornerRadius = Theme.cg(c.indicatorRadius)
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = Theme.ns(c.indicatorFill(style: style).over(style.surface)).cgColor
            layer?.borderWidth = Theme.cg(c.hairlineWidth)
            layer?.borderColor = Theme.ns(c.hairline(style: style)).cgColor
            dot.layer?.cornerRadius = Theme.cg(c.dotDiameter / 2)
            var red = Theme.ns(c.dot(style: style)).cgColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                red = CardStyle.dynamic(c.dotColor) { base, _ in base }.cgColor
            }
            dot.layer?.backgroundColor = red
        }
    }

    static func group(_ views: [NSView]) -> Group { Group(views) }

    /// The card's button (as the Ignore button: fill, hairline, hover and pressed states).
    static func cardButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let st = Theme.Settings.self
        let b = CardButton(frame: .zero)
        b.role = .ignore
        b.style = { Theme.style(dark: Theme.isDark) }
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = Theme.cg(st.buttonRadius)
        b.layer?.cornerCurve = .continuous
        b.attributedTitle = Card.attr(title, Theme.font(st.buttonFont), color(.primary))
        b.target = target
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        let w = b.attributedTitle.size().width.rounded(.up) + 2 * CGFloat(st.buttonPadding)
        NSLayoutConstraint.activate([
            b.heightAnchor.constraint(equalToConstant: CGFloat(st.buttonHeight)),
            b.widthAnchor.constraint(equalToConstant: w),
        ])
        b.applyFill()
        return b
    }

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
        let swappedVisible = useWindowForMode()
        rootWidth.constant = CGFloat(windowWidth)
        root.arrangedSubviews.forEach { $0.removeFromSuperview() }
        root.orientation = .vertical
        root.alignment = .leading
        let inset = showingOnboarding ? 0 : CGFloat(Theme.Settings.inset)
        root.spacing = inset
        root.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        let width = Self.outerWidth
        let views = showingOnboarding ? onboardingViews() : settingsViews()
        for v in views {
            root.addArrangedSubview(v)
            v.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        update()
        if swappedVisible {
            window.center()
            update()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Card-width window sized to its groups, but never past the screen's visible frame: taller
    /// content scrolls inside the window instead.
    private func fitWindow() {
        root.layoutSubtreeIfNeeded()
        let w = windowWidth, fitting = Double(root.fittingSize.height)
        document.frame = NSRect(x: 0, y: 0, width: w, height: fitting)
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let chrome = Double(window.frameRect(forContentRect: .zero).height)
        let h = Theme.Settings.contentHeight(fitting: fitting, visibleHeight: visibleHeightOverride ?? Double(visible.height),
                                             chrome: chrome).height
        window.setContentSize(NSSize(width: w, height: h))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, fitting - h)))
        scroll.reflectScrolledClipView(scroll.contentView)
        let f = window.frame
        let o = Theme.Settings.clamp(origin: (Double(f.minX), Double(f.minY)), size: (Double(f.width), Double(f.height)),
                                     visible: (Double(visible.minX), Double(visible.minY), Double(visible.width), Double(visible.height)))
        if !visible.isEmpty { window.setFrameOrigin(NSPoint(x: o.x, y: o.y)) }
    }

    private func onboardingViews() -> [NSView] {
        let s = CoachCopy.onboarding[screen]
        let glyph = NSImageView(image: Theme.symbol(Theme.Coach.symbol, Theme.FontSpec(Theme.Settings.glyphSize, Theme.Coach.glyphFont.weight),
                                                    label: CoachCopy.toggle) ?? NSImage())
        glyph.contentTintColor = Self.color(.accent)
        let title = Self.text(s.title, font: Theme.Settings.headingFont)
        let body = Self.text(s.body, font: Theme.Settings.itemFont, color: Self.color(.secondary))
        let primary = Self.cardButton(s.primary, target: self, action: #selector(onboardingPrimary(_:)))
        primary.keyEquivalent = "\r"
        var buttons: [NSView] = []
        if let secondary = s.secondary { buttons.append(NSButton(title: secondary, target: self, action: #selector(onboardingNotNow(_:)))) }
        buttons.append(primary)
        let buttonRow = NSStackView(views: buttons)
        let dots = Self.text("\(screen + 1) of \(CoachCopy.onboarding.count)", font: Theme.Settings.helperFont, color: Self.color(.tertiary))
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
        let section = Self.text(CoachCopy.section, font: Theme.Settings.headingFont, maxWidth: Self.outerWidth)

        toggle.target = self
        toggle.action = #selector(toggled(_:))
        toggle.setAccessibilityLabel(CoachCopy.toggle)
        startButton.target = self
        startButton.action = #selector(startNow(_:))
        startButton.bezelStyle = .rounded
        startButton.controlSize = .small
        let toggleRow = Self.row(Self.text(CoachCopy.toggle, font: Theme.Settings.rowFont), toggle)
        let help = Self.text(CoachCopy.toggleHelp, font: Theme.Settings.helperFont, color: Self.color(.secondary))
        let g1 = Self.group([toggleRow, help, noMicNote, gptNote, toggleError, permissionNote, startButton])
        for v in [toggleRow, help, noMicNote, gptNote, toggleError, permissionNote] { pin(v, in: g1) }

        callControlsSwitch.target = self
        callControlsSwitch.action = #selector(callControlsToggled(_:))
        callControlsSwitch.setAccessibilityLabel(CoachCopy.callControlsToggle)
        requestAccessButton.target = self
        requestAccessButton.action = #selector(requestAccess(_:))
        requestAccessButton.bezelStyle = startButton.bezelStyle
        requestAccessButton.controlSize = startButton.controlSize
        let callControlsRow = Self.row(Self.text(CoachCopy.callControlsToggle, font: Theme.CallControls.rowFont), callControlsSwitch)
        let callControlsHelp = Self.text(CoachCopy.callControlsHelp, font: Theme.CallControls.helperFont,
                                         color: Self.color(Theme.CallControls.helperText))
        let gControls = Self.group([callControlsRow, callControlsHelp, callControlsNote, requestAccessButton])
        for v in [callControlsRow, callControlsHelp, callControlsNote] { pin(v, in: gControls) }

        keyField.placeholderString = coach.hasKey ? CoachCopy.keySavedPlaceholder : CoachCopy.keyPlaceholder
        keyField.font = Theme.font(Theme.Settings.itemFont)
        keyField.target = self
        keyField.action = #selector(keyEntered(_:))
        keyField.setAccessibilityLabel(CoachCopy.keyLabel)
        let lock = NSImageView(image: Theme.symbol("lock", Theme.Settings.itemFont) ?? NSImage())
        lock.contentTintColor = Self.color(.secondary)
        let keyRow = NSStackView(views: [keyField, lock])
        keyRow.orientation = .horizontal
        let keyHelp = Self.text(CoachCopy.keyHelp, font: Theme.Settings.helperFont, color: Self.color(.secondary))
        let g2 = Self.group([Self.text(CoachCopy.keyLabel, font: Theme.Settings.rowFont), keyRow, keyHelp, keyStatus])
        for v in [keyRow, keyHelp, keyStatus] { pin(v, in: g2) }

        let gJudge = judgeGroup()

        let add = NSButton(title: CoachCopy.add, target: self, action: #selector(addApp(_:)))
        add.bezelStyle = .rounded
        let header = Self.row(Self.text(CoachCopy.allowedApps, font: Theme.Settings.rowFont), add)
        appsStack = NSStackView()
        appsStack.orientation = .vertical
        appsStack.alignment = .leading
        appsStack.spacing = CGFloat(Theme.Settings.groupSpacing)
        anyAppBox.target = self
        anyAppBox.action = #selector(anyAppToggled(_:))
        anyAppBox.font = Theme.font(Theme.Settings.helperFont)
        let g3 = Self.group([header, appsStack, anyAppBox])
        for v in [header, appsStack] { pin(v, in: g3) }
        rebuildApps()

        let privacy = Self.text(CoachCopy.privacy + " " + CoachCopy.pausedPrivacy, font: Theme.Settings.helperFont,
                                color: Self.color(.secondary), maxWidth: Self.outerWidth)
        return [section, g1, gControls, g2, gJudge, g3, transcriptGroup(), privacy, feedbackGroup()]
    }

    /// Last, so everything above it lays out exactly as before.
    private func feedbackGroup() -> Group {
        let send = NSButton(title: FeedbackCopy.settingsButton, target: self, action: #selector(sendFeedback(_:)))
        send.bezelStyle = .rounded
        let row = Self.row(Self.text(FeedbackCopy.settingsLabel, font: Theme.Settings.rowFont), send)
        let help = Self.text(FeedbackCopy.settingsHelp, font: Theme.Settings.helperFont, color: Self.color(Theme.Settings.helperText))
        let g = Self.group([row, help])
        for v in [row, help] { pin(v, in: g) }
        return g
    }

    static func judgeTitle(_ kind: JudgeProviderKind) -> String {
        switch kind {
        case .gpt: CoachCopy.judgeGpt
        case .typesafe: CoachCopy.judgeTypeSafe
        }
    }

    static func judgeHelpText(_ kind: JudgeProviderKind) -> String {
        switch kind {
        case .gpt: CoachCopy.judgeHelpGpt
        case .typesafe: CoachCopy.judgeHelpTypeSafe
        }
    }

    /// Cue judge: the provider picker, what it sends where, and (TypeSafe only) its key.
    private func judgeGroup() -> Group {
        judgePopup.removeAllItems()
        judgePopup.addItems(withTitles: JudgeProviderKind.allCases.map { Self.judgeTitle($0) })
        judgePopup.font = Theme.font(Theme.Settings.itemFont)
        judgePopup.target = self
        judgePopup.action = #selector(judgePicked(_:))
        judgePopup.setAccessibilityLabel(CoachCopy.judgeLabel)
        let judgeRow = Self.row(Self.text(CoachCopy.judgeLabel, font: Theme.Settings.rowFont), judgePopup)

        typeSafeKeyField.font = Theme.font(Theme.Settings.itemFont)
        typeSafeKeyField.target = self
        typeSafeKeyField.action = #selector(typeSafeKeyEntered(_:))
        typeSafeKeyField.setAccessibilityLabel(CoachCopy.typeSafeKeyLabel)
        let lock = NSImageView(image: Theme.symbol("lock", Theme.Settings.itemFont) ?? NSImage())
        lock.contentTintColor = Self.color(.secondary)
        typeSafeKeyRow = NSStackView(views: [typeSafeKeyField, lock])
        typeSafeKeyRow.orientation = .horizontal
        let g = Self.group([judgeRow, judgeHelp, typeSafeKeyRow, typeSafeNote, judgeStoppedNote])
        for v in [judgeRow, judgeHelp, typeSafeKeyRow, typeSafeNote, judgeStoppedNote] { pin(v, in: g) }
        return g
    }

    private func updateJudge() {
        let kind = coach.judgeProvider
        judgePopup.selectItem(at: JudgeProviderKind.allCases.firstIndex(of: kind) ?? 0)
        judgeHelp.stringValue = Self.judgeHelpText(kind)
        let typeSafe: Bool
        switch kind {
        case .gpt: typeSafe = false
        case .typesafe: typeSafe = true
        }
        typeSafeKeyRow.isHidden = !typeSafe
        typeSafeKeyField.placeholderString = coach.typeSafeKeyStored ? CoachCopy.typeSafeKeySavedPlaceholder : CoachCopy.typeSafeKeyPlaceholder
        typeSafeNote.isHidden = !(typeSafe && !coach.typeSafeKeyStored)
        let stopped = typeSafe ? coach.judgeStopped : nil
        judgeStoppedNote.stringValue = stopped.map(CoachCopy.judgeStopped) ?? ""
        judgeStoppedNote.isHidden = stopped == nil
    }

    /// Captions and saved transcripts: two opt-in switches, the folder, the saving indicator and
    /// delete action, this call's speaker names and the cost meter's line.
    private func transcriptGroup() -> Group {
        captionsToggle.target = self
        captionsToggle.action = #selector(captionsToggled(_:))
        captionsToggle.setAccessibilityLabel(CoachCopy.captionsToggle)
        savingToggle.target = self
        savingToggle.action = #selector(savingToggled(_:))
        savingToggle.setAccessibilityLabel(CoachCopy.saveToggle)
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseFolder(_:))
        chooseFolderButton.bezelStyle = .rounded
        chooseFolderButton.controlSize = .small
        deleteButton.target = self
        deleteButton.action = #selector(deleteTranscript(_:))
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        // The path is one line, cut in the middle; the buttons beside it and the status keep their size.
        folderPath.font = Theme.font(Theme.Settings.helperFont)
        folderPath.textColor = Self.color(.secondary)
        folderPath.lineBreakMode = .byTruncatingMiddle
        folderPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        transcriptStatus.preferredMaxLayoutWidth = Self.innerWidth / 2
        for (field, speaker) in [(youField, Speaker.me), (themField, Speaker.others)] {
            field.placeholderString = CoachTranscript.speakerLabels.label(speaker)
            field.font = Theme.font(Theme.Settings.itemFont)
            field.target = self
            field.action = #selector(speakerNamed(_:))
            field.setAccessibilityLabel("\(CoachCopy.speakerNames): \(CoachTranscript.speakerLabels.label(speaker))")
        }

        let heading = Self.text(CoachCopy.transcriptSection, font: Theme.Settings.rowFont)
        let captionsRow = Self.row(Self.text(CoachCopy.captionsToggle, font: Theme.Settings.itemFont), captionsToggle)
        let captionsHelp = Self.text(CoachCopy.captionsHelp, font: Theme.Settings.helperFont, color: Self.color(.secondary))
        let savingRow = Self.row(Self.text(CoachCopy.saveToggle, font: Theme.Settings.itemFont), savingToggle)
        let savingHelp = Self.text(CoachCopy.saveHelp, font: Theme.Settings.helperFont, color: Self.color(.secondary))
        let folderLabels = NSStackView(views: [Self.text(CoachCopy.folderLabel, font: Theme.Settings.itemFont), folderPath])
        folderLabels.orientation = .vertical
        folderLabels.alignment = .leading
        folderLabels.spacing = 0
        let folderRow = Self.row(folderLabels, chooseFolderButton)
        let statusRow = Self.row(transcriptStatus, deleteButton)
        let names = NSStackView(views: [youField, themField])
        names.orientation = .horizontal
        names.distribution = .fillEqually
        names.spacing = CGFloat(Theme.Settings.groupSpacing)
        let namesHelp = Self.text(CoachCopy.speakerNamesHelp, font: Theme.Settings.helperFont, color: Self.color(.secondary))
        let views: [NSView] = [heading, transcriptNote, captionsRow, captionsHelp, savingRow, savingHelp, folderRow, savingHolder,
                               statusRow, Self.text(CoachCopy.speakerNames, font: Theme.Settings.itemFont), names, namesHelp, costLabel]
        let g = Self.group(views)
        for v in views where v !== heading && v !== savingHolder { pin(v, in: g) }
        transcriptGroupView = g
        return g
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
            let name = Self.text(appName(id), font: Theme.Settings.itemFont)
            let detail = Self.text(id, font: Theme.Settings.helperFont, color: Self.color(.secondary))
            let labels = NSStackView(views: [name, detail])
            labels.orientation = .vertical
            labels.alignment = .leading
            labels.spacing = 0
            let minus = NSButton(image: Theme.symbol("minus.circle", Theme.Settings.itemFont, label: CoachCopy.remove) ?? NSImage(),
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
        gptNote.isHidden = !(coach.enabled && !coach.keyStored)
        noMicNote.isHidden = !(window.isVisible && NoMicNotice.showsSettingsNote(builtInMicPresent: CoreAudioRoutes().snapshot().builtInInput != nil))
        toggleError.stringValue = coach.enabled ? toggleMessage(coach) ?? "" : ""
        toggleError.isHidden = toggleError.stringValue.isEmpty
        keyStatus.isHidden = keyStatus.stringValue.isEmpty
        updateCallControls()
        updateJudge()
        updateTranscript()
    }

    /// The toggle, and while it's on, what it still needs (checked, never asked; the Request access
    /// button asks). Checked only while the window is up.
    private func updateCallControls() {
        callControlsSwitch.state = coach.callControlsOn ? .on : .off
        let needs = window.isVisible ? coach.callControlsNeeds() : CoachController.CallControlsNeeds()
        let note = [CoachCopy.callControlsNeeds(accessibility: needs.accessibility, automation: needs.automation),
                    needs.diaUnsupported ? CoachCopy.callControlsDiaUnsupported : nil].compactMap { $0 }.joined(separator: " ")
        callControlsNote.stringValue = note
        callControlsNote.isHidden = note.isEmpty
        requestAccessButton.isHidden = !(needs.accessibility || !needs.automation.isEmpty)
    }

    private func updateTranscript() {
        let t = coach.transcript
        let usable = coach.transcriptKeyUsable
        captionsToggle.state = t.captionsOn ? .on : .off
        savingToggle.state = t.savingOn ? .on : .off
        captionsToggle.isEnabled = usable
        savingToggle.isEnabled = usable
        transcriptNote.isHidden = usable
        folderPath.stringValue = (t.folder.path as NSString).abbreviatingWithTildeInPath
        let rec = t.live.recorder
        savingHolder.isHidden = !rec.isSaving
        switch rec.state {
        case .saving: transcriptStatus.stringValue = ""
        case .saved: transcriptStatus.stringValue = rec.lastURL == nil ? "" : CoachCopy.savedLast
        case .deleted: transcriptStatus.stringValue = CoachCopy.transcriptDeleted
        case .failed: transcriptStatus.stringValue = CoachCopy.saveFailed
        case .off: transcriptStatus.stringValue = rec.lastURL == nil ? "" : CoachCopy.savedLast
        }
        transcriptStatus.isHidden = transcriptStatus.stringValue.isEmpty
        deleteButton.isHidden = !t.canDelete
        let inCall = t.live.inCall
        for (field, speaker) in [(youField, Speaker.me), (themField, Speaker.others)] {
            field.isEnabled = inCall
            if !inCall { field.stringValue = "" }
            field.placeholderString = t.live.labels.label(speaker)
        }
        costLabel.stringValue = t.costLine()
        costLabel.isHidden = !usable
    }

    /// Under the toggle: problems with the stored key. A missing key is the GPT note, not an error.
    private func toggleMessage(_ coach: CoachController) -> String? {
        if coach.keyGate.rejected { return CoachCopy.storedKeyRejected }
        return coach.keyProblem == .unreachable ? CoachCopy.keyUnreachable : nil
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

    @objc private func callControlsToggled(_ sender: NSSwitch) {
        coach.setCallControls(sender.state == .on)
        update()
    }

    @objc private func requestAccess(_ sender: Any?) {
        coach.requestCallControlsAccess()
        update()
    }

    @objc private func sendFeedback(_ sender: Any?) { coach.feedbackClicked(sender) }

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

    @objc private func judgePicked(_ sender: NSPopUpButton) {
        let all = JudgeProviderKind.allCases
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        coach.setJudgeProvider(all[sender.indexOfSelectedItem])
        update()
    }

    @objc private func typeSafeKeyEntered(_ sender: NSSecureTextField) {
        let text = sender.stringValue
        sender.stringValue = ""
        coach.saveTypeSafeKey(text)
        update()
    }

    @objc private func captionsToggled(_ sender: NSSwitch) {
        withNotice(turningOn: sender.state == .on) { [weak self] on in
            guard let self else { return }
            self.coach.transcript.setCaptions(on, keyUsable: self.coach.transcriptKeyUsable)
            self.update()
        }
    }

    @objc private func savingToggled(_ sender: NSSwitch) {
        withNotice(turningOn: sender.state == .on) { [weak self] on in
            guard let self else { return }
            self.coach.transcript.setSaving(on, keyUsable: self.coach.transcriptKeyUsable)
            self.update()
        }
    }

    /// The first time captions or saving turn on, the notice sheet asks first; "Not Now" leaves it off.
    private func withNotice(turningOn: Bool, apply: @escaping (Bool) -> Void) {
        guard turningOn, !coach.transcript.noticeSeen else { return apply(turningOn) }
        let sheet = CoachNotice { [weak self] ok in
            if ok { self?.coach.transcript.markNoticeSeen() }
            self?.notice = nil
            apply(ok)
        }
        notice = sheet
        sheet.present(on: window)
    }

    @objc private func chooseFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = coach.transcript.folder
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.coach.transcript.setFolder(url, keyUsable: self.coach.transcriptKeyUsable)
            self.update()
        }
    }

    @objc private func deleteTranscript(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = CoachCopy.deleteConfirmTitle
        alert.informativeText = CoachCopy.deleteConfirmBody
        alert.addButton(withTitle: CoachCopy.delete).hasDestructiveAction = true
        alert.addButton(withTitle: CoachCopy.cancel)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.coach.transcript.deleteTranscript()
            self?.update()
        }
    }

    @objc private func speakerNamed(_ sender: NSTextField) {
        coach.transcript.rename(sender === youField ? .me : .others, to: sender.stringValue)
        update()
    }

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
