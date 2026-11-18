import AppKit
import MeetingCardCore

/// A one-time notice, card-shaped (card width, surface, insets, title and body type, and the card's two
/// buttons): before captions or saved transcripts first turn on (a sheet on the Settings window; turning the
/// feature on waits for the answer and "Not Now" leaves it off; CoachCopy's draft strings, marked as a draft
/// until copy review), and before the ask-back cue first runs (a window of its own; final copy).
@MainActor
final class CoachNotice: NSObject {
    struct Content {
        var title: String
        var body: String
        var confirm: String
        var secondary: String
        /// The secondary button answers Escape too.
        var secondaryIsCancel: Bool
        var isDraft: Bool

        static let transcript = Content(title: CoachCopy.noticeTitle, body: CoachCopy.noticeBody, confirm: CoachCopy.noticeConfirm,
                                        secondary: CoachCopy.noticeCancel, secondaryIsCancel: true, isDraft: CoachCopy.transcriptCopyIsDraft)
        static let selfPivot = Content(title: CoachSelfPivot.Copy.noticeTitle, body: CoachSelfPivot.Copy.noticeBody,
                                       confirm: CoachSelfPivot.Copy.noticeConfirm, secondary: CoachSelfPivot.Copy.noticeOpenSettings,
                                       secondaryIsCancel: false, isDraft: false)
    }

    let window: NSWindow
    let content: Content
    private let onChoice: (Bool) -> Void
    private var buttons: [CardButton] = []

    /// `onChoice(true)` for the confirm button, false for the secondary one.
    init(content: Content = .transcript, onChoice: @escaping (Bool) -> Void) {
        self.content = content
        self.onChoice = onChoice
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Theme.Notice.width, height: Theme.Metrics.cardHeight),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        build()
    }

    func present(on parent: NSWindow) {
        parent.beginSheet(window) { _ in }
    }

    /// A window of its own, centred and in front (the ask-back notice can be due with no Settings window).
    func presentAlone() {
        window.level = .floating
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private var style: CardStyle { Theme.style(dark: CoachTranscript.isDark(window.effectiveAppearance)) }

    private func wrapping(_ s: String, _ font: Theme.FontSpec, _ role: CardStyle.Text, width: CGFloat) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = Theme.font(font)
        f.textColor = CoachTranscript.color(role)
        f.isSelectable = false
        f.preferredMaxLayoutWidth = width
        let h = f.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 0
        f.frame = NSRect(x: 0, y: 0, width: width, height: h.rounded(.up))
        return f
    }

    private func button(_ title: String, _ role: CardButton.Role, _ action: Selector) -> CardButton {
        let n = Theme.Notice.self
        let b = CardButton(frame: .zero)
        b.role = role
        b.style = { [weak self] in self?.style ?? .for(dark: false) }
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = Theme.cg(n.buttonRadius)
        b.layer?.cornerCurve = .continuous
        let fg: NSColor = role == .ignore ? CoachTranscript.color(.primary) : CoachTranscript.color { $0.primaryText }
        b.attributedTitle = Card.attr(title, Theme.font(n.buttonFont), fg)
        let w = (b.attributedTitle.size().width + 2 * Theme.cg(n.buttonPadding)).rounded(.up)
        b.frame = NSRect(x: 0, y: 0, width: w, height: Theme.cg(n.buttonHeight))
        b.target = self
        b.action = action
        b.applyFill()
        buttons.append(b)
        return b
    }

    /// Top-down: draft marker, title, body, then the buttons at the right (unflipped coordinates,
    /// so the total height is worked out first).
    private func build() {
        let n = Theme.Notice.self
        let width = Theme.cg(n.width)
        let inner = width - 2 * Theme.cg(n.padding.h)
        var texts: [(NSTextField, Double)] = []
        if content.isDraft {
            texts.append((wrapping(CoachCopy.noticeDraftMarker, n.draftFont, n.draft, width: inner), n.spacing))
        }
        texts.append((wrapping(content.title, n.titleFont, .primary, width: inner), n.spacing))
        texts.append((wrapping(content.body, n.bodyFont, n.body, width: inner), n.padding.v))
        let pad = Theme.cg(n.padding.v), buttonH = Theme.cg(n.buttonHeight)
        let height = pad + texts.reduce(CGFloat(0)) { $0 + $1.0.frame.height + Theme.cg($1.1) } + buttonH + pad
        let root = NoticeView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        var top = height - pad
        for (field, gap) in texts {
            field.setFrameOrigin(NSPoint(x: Theme.cg(n.padding.h), y: top - field.frame.height))
            root.addSubview(field)
            top -= field.frame.height + Theme.cg(gap)
        }
        let confirmButton = button(content.confirm, .join, #selector(CoachNotice.confirm(_:)))
        confirmButton.keyEquivalent = "\r"
        let cancelButton = button(content.secondary, .ignore, #selector(CoachNotice.cancel(_:)))
        if content.secondaryIsCancel { cancelButton.keyEquivalent = "\u{1b}" }
        var x = width - Theme.cg(n.padding.h)
        for b in [confirmButton, cancelButton] {
            x -= b.frame.width
            b.setFrameOrigin(NSPoint(x: x, y: pad))
            root.addSubview(b)
            x -= Theme.cg(n.buttonGap)
        }
        root.onAppearance = { [weak self] in self?.applyChrome() }
        // Size the window first: setting contentView resizes the view to the window's content size.
        window.setContentSize(root.frame.size)
        window.contentView = root
        applyChrome()
    }

    private func applyChrome() {
        let fill = Theme.ns(Theme.Notice.surface(style: style))
        window.backgroundColor = fill
        window.contentView?.layer?.backgroundColor = fill.cgColor
        buttons.forEach { $0.applyFill() }
    }

    @objc private func confirm(_ sender: Any?) { finish(true) }
    @objc private func cancel(_ sender: Any?) { finish(false) }

    private func finish(_ ok: Bool) {
        close()
        onChoice(ok)
    }

    /// Takes the notice down without an answer.
    func close() {
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
    }

    final class NoticeView: NSView {
        var onAppearance: (() -> Void)?
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            onAppearance?()
        }
    }
}
