import SwiftUI

/// Typography and spacing in one place, so the look can be iterated on
/// (e.g. in Claude Design) without touching every view.
enum Theme {
    /// Comfortable reading measure for documents (proposals, Markdown files).
    static let docWidth: CGFloat = 720
    static let chatWidth: CGFloat = 740      // the conversation and its message box (about 90 characters a line)
    static let lineSpacing: CGFloat = 4
    static let blockSpacing: CGFloat = 12
    static let corner: CGFloat = 12
    static let composerHeight: CGFloat = 44     // the message box at one line, and the buttons beside it
    static let composerButton: CGFloat = 34

    enum Fonts {
        // Documents: New York headings over SF body text.
        static let docTitle = Font.system(.title, design: .serif).weight(.semibold)
        static let h1 = Font.system(.title2, design: .serif).weight(.semibold)
        static let h2 = Font.system(.title3, design: .serif).weight(.semibold)
        static let h3 = Font.headline
        static let body = Font.body
        static let meta = Font.subheadline
        static let caption = Font.caption
        static let small = Font.caption2         // badges and counts only
        static let code = Font.system(.footnote, design: .monospaced)
    }

    // MARK: colour (design pass 1: the icon's palette)

    /// Your Pencil marks and notes: the icon's orange. Only ever ink, never a
    /// button or a status, and never red (red means removed, or an error).
    static let ink = Color(light: "#F26B4A", dark: "#FF8A6B")
    /// PencilKit takes one colour and adapts it for dark mode itself.
    static let inkUIColor = UIColor(hex: "#F26B4A")
    /// A chat or plan that needs your decision: amber, so it doesn't read as ink.
    static let needsYou = Color(light: "#D99A00", dark: "#F5B82E")

    /// Code, from the icon: keywords purple, functions blue, types teal, strings green.
    enum Code {
        static let keyword = Color(light: "#9B4FC2", dark: "#C48ADE")
        static let function = Color(light: "#2F63D6", dark: "#78B2EC")
        static let type = Color(light: "#0F7C8C", dark: "#5CC8D6")
        static let string = Color(light: "#2E8A4E", dark: "#8FCF8F")
        static let number = Color(light: "#B0581A", dark: "#F0A868")
        static let comment = Color(light: "#8A93A1", dark: "#6F7A8B")
        static let property = Color(light: "#3B6E9E", dark: "#9CC4E4")
        static let attribute = Color(light: "#A0611F", dark: "#E0B07A")
    }

    // MARK: space: a 4 pt grid; round controls, 10 pt cards

    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16
        static let xl: CGFloat = 20, xxl: CGFloat = 24, xxxl: CGFloat = 32
    }
    static let cardCorner: CGFloat = 10

    static let fieldBackground = Color(uiColor: .secondarySystemBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    /// One colour in light mode, another in dark.
    init(light: String, dark: String) {
        let l = UIColor(hex: light), d = UIColor(hex: dark)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? d : l })
    }
}

/// Multi-line text input used everywhere you write to Claude: chat, comments,
/// review notes, new tasks. Placeholder, generous padding, optional dictation.
struct WritingField: View {
    let placeholder: String
    @Binding var text: String
    var minLines = 1
    var maxLines = 10
    var voice = true
    var voiceSize: CGFloat = 22
    var focus: FocusState<Bool>.Binding?

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            field
                .lineLimit(minLines...maxLines)
                .font(Theme.Fonts.body)
                .lineSpacing(2)
            if voice {
                VoiceButton(text: $text, size: voiceSize)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Color(uiColor: .separator).opacity(0.4)))
    }

    @ViewBuilder private var field: some View {
        if let focus {
            TextField(placeholder, text: $text, axis: .vertical).focused(focus)
        } else {
            TextField(placeholder, text: $text, axis: .vertical)
        }
    }
}

/// The chat's message box. With a keyboard, Return sends and Shift+Return
/// (or Option+Return) starts a new line, as in Claude Code; the on-screen
/// keyboard's return key adds a line (the send button sends). Grows with the
/// text up to `maxLines`.
struct ComposerField<Trailing: View>: View {
    let placeholder: String
    @Binding var text: String
    var maxLines = 8
    @Binding var focused: Bool
    let onSubmit: () -> Void
    var onEscape: (() -> Bool)? = nil
    /// Buttons inside the box at the end of the last line (voice, send), each `Theme.composerButton` square.
    @ViewBuilder var trailing: () -> Trailing

    /// One line of text and the buttons beside it share a centre line.
    private static var inset: CGFloat { (Theme.composerHeight - UIFont.preferredFont(forTextStyle: .body).lineHeight) / 2 }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ComposerTextView(text: $text, maxLines: maxLines, focused: $focused, onSubmit: onSubmit, onEscape: onEscape)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).font(Theme.Fonts.body).foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, Trailing.self == EmptyView.self ? 14 : 0)
                .padding(.vertical, Self.inset)
            trailing()
                .padding(.trailing, (Theme.composerHeight - Theme.composerButton) / 2)
                .padding(.vertical, (Theme.composerHeight - Theme.composerButton) / 2)
        }
        .frame(minHeight: Theme.composerHeight)
        .background(Theme.fieldBackground, in: RoundedRectangle(cornerRadius: Theme.composerHeight / 2))
        .overlay(RoundedRectangle(cornerRadius: Theme.composerHeight / 2).stroke(Color(uiColor: .separator).opacity(0.4)))
    }
}

extension ComposerField where Trailing == EmptyView {
    init(placeholder: String, text: Binding<String>, maxLines: Int = 8, focused: Binding<Bool>,
         onSubmit: @escaping () -> Void, onEscape: (() -> Bool)? = nil) {
        self.init(placeholder: placeholder, text: text, maxLines: maxLines, focused: focused,
                  onSubmit: onSubmit, onEscape: onEscape, trailing: { EmptyView() })
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let maxLines: Int
    @Binding var focused: Bool
    let onSubmit: () -> Void
    let onEscape: (() -> Bool)?

    func makeUIView(context: Context) -> KeyTextView {
        let v = KeyTextView()
        v.delegate = context.coordinator
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.isScrollEnabled = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: KeyTextView, context: Context) {
        context.coordinator.parent = self
        if v.text != text { v.text = text }
        v.onSubmit = onSubmit
        v.onEscape = onEscape
        if focused, !v.isFirstResponder { DispatchQueue.main.async { v.becomeFirstResponder() } }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: KeyTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        let line = v.font?.lineHeight ?? 20
        let fits = v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fits, line), line * CGFloat(maxLines))
        let scroll = fits > height + 1
        if v.isScrollEnabled != scroll { DispatchQueue.main.async { v.isScrollEnabled = scroll } }
        return CGSize(width: width, height: ceil(height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        init(parent: ComposerTextView) { self.parent = parent }

        func textViewDidChange(_ v: UITextView) {
            parent.text = v.text
            v.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ v: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ v: UITextView) { if parent.focused { parent.focused = false } }
    }

    final class KeyTextView: UITextView {
        var onSubmit: (() -> Void)?
        var onEscape: (() -> Bool)?

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            for p in presses {
                guard let key = p.key else { continue }
                if key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter {
                    if markedTextRange != nil { break }            // finishing a composed character
                    if key.modifierFlags.contains(.shift) || key.modifierFlags.contains(.alternate) {
                        insertText("\n")
                    } else if key.modifierFlags.isEmpty {
                        onSubmit?()
                    } else {
                        break                                       // ⌘Return etc.: the app's shortcuts
                    }
                    return
                }
                if key.keyCode == .keyboardEscape, onEscape?() == true { return }
            }
            super.pressesBegan(presses, with: event)
        }
    }
}
