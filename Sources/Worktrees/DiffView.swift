import AppKit
import SwiftUI

/// A file's changes under its row: hunks with a quiet @@ line, old and new line numbers in
/// a slim gutter, added lines on a soft green, removed on a soft red. Long lines scroll
/// sideways (a thin indicator shows while they move) or wrap with a hanging indent, tall
/// diffs scroll inside a 400pt box, and very long ones render 500 lines at a time. Code is
/// coloured by language, off the main thread, for the lines on show. In the spirit of Zed's
/// review pane.
struct DiffPanel: View {
    let diff: FileDiff?
    /// The file's path, for picking its language.
    let path: String
    /// Name of the editor the binary message points at.
    let editorName: String
    @State private var shownLines = DiffPanel.page
    /// The panel's width, so short lines paint their background all the way across while
    /// long ones run past it and scroll.
    @State private var width: CGFloat = 0
    /// Coloured runs by line id, for the diff version they were worked out for.
    @State private var colouring: Colouring?
    /// Wrap long lines: "on", "off", or "auto" (on when the longest line doesn't fit). One
    /// choice for every panel, kept between launches.
    @AppStorage(DiffPanel.wrapKey) private var wrapSetting = "auto"
    /// Sideways scroll position, read only by the indicator, so scrolling doesn't redraw rows.
    @State private var scroll = SidewaysScroll()
    @State private var wrapHovered = false
    /// What doesn't change with the width: the page on show, the gutter, the longest line.
    @State private var metrics = Metrics()
    /// The row at the top of the panel's scroll, kept across wrap changes.
    @State private var topRow: String?

    /// A row in the scrolling list: a hunk's @@ line (all but the first, which is the
    /// panel's fixed header) or a code line.
    private enum Row {
        case header(FileDiff.Hunk)
        case line(FileDiff.Line)
        var id: String {
            switch self {
            case .header(let hunk): "h\(hunk.id)"
            case .line(let line): "l\(line.id)"
            }
        }
    }

    /// Worked out once per diff version and page, not on every frame of a live resize.
    private final class Metrics {
        var key: ColouringKey?
        var visible: [FileDiff.Hunk] = []
        var rows: [Row] = []
        var gutter: CGFloat = 0
        var longest = 0
    }

    static let wrapKey = "diffWrap"
    /// Width of one character of the 12pt monospaced font, for wrapping by columns.
    static let charWidth: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()

    private struct Colouring {
        let version: UUID
        let spans: [Int: [TokenSpan]]
    }

    private struct ColouringKey: Equatable {
        let version: UUID?
        let shownLines: Int
    }

    static let page = 500
    static let maxHeight: CGFloat = 400

    var body: some View {
        // Exactly the width it is offered: wide content never widens the panel (which once
        // left it as wide as its longest line after the window narrowed, centred in its row
        // with the code cut off on the left).
        OfferedWidth {
        VStack(alignment: .leading, spacing: 0) {
            // Measures the width the panel is given. A flexible empty strip always takes the
            // offered width, so wide content can't feed back into the measure (which once kept
            // the panel as wide as its longest line after the window narrowed, cutting the
            // code off on the left).
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)
                .background(GeometryReader { g in Color.clear.preference(key: PanelWidth.self, value: g.size.width) })
                .onPreferenceChange(PanelWidth.self) { new in
                    if new != width { width = new }
                }
            switch diff?.body {
            case nil:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading the changes").font(Font13.small).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
            case .binary:
                note("Binary file, open in \(editorName)")
            case .tooLarge:
                note("Too big to show here, open in \(editorName)")
            case .empty:
                note("No line changes")
            case .folder:
                note("A folder git doesn't track yet")
            case .symlink(let target):
                note("Link to \(target)")
            case .failed:
                note("Couldn't read the changes")
            case .text(let hunks):
                // Nothing until the width is known, so lines don't lay out once at a guess.
                if width > 0 { text(hunks, version: diff?.version) } else { Color.clear.frame(height: 24) }
            }
        }
        }
        .clipped()
        .background(Theme.background, in: Rectangle())
        .task(id: ColouringKey(version: diff?.version, shownLines: shownLines)) { await colour() }
    }

    /// Works out colours for the lines on show, off the main thread. Pages already done come
    /// straight from the cache.
    private func colour() async {
        guard let diff, case .text(let hunks) = diff.body else { return }
        let language = CodeLanguage(path: path)
        guard language != .plain else { return }
        let page = FileDiff.page(hunks, budget: shownLines)
        let version = diff.version
        // Nonisolated async: runs on the global executor, and sees this task's cancellation.
        let spans = await SyntaxCache.shared.highlight(version: version, language: language, hunks: page, fullHunks: hunks)
        guard !Task.isCancelled else { return }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { colouring = Colouring(version: version, spans: spans) }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(Font13.small)
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 12)
            .frame(height: 28)
    }

    private func text(_ hunks: [FileDiff.Hunk], version: UUID?) -> some View {
        let total = hunks.reduce(0) { $0 + $1.lines.count }
        // Hunks and lines up to the budget; the rest waits behind Show more.
        let key = ColouringKey(version: version, shownLines: shownLines)
        if metrics.key != key {
            metrics.key = key
            metrics.visible = FileDiff.page(hunks, budget: shownLines)
            metrics.rows = metrics.visible.enumerated().flatMap { index, hunk in
                (index == 0 ? [] : [Row.header(hunk)]) + hunk.lines.map(Row.line)
            }
            metrics.gutter = CGFloat(String(hunks.flatMap(\.lines).compactMap { max($0.oldNumber ?? 0, $0.newNumber ?? 0) }.max() ?? 0).count) * 8 + 8
            metrics.longest = metrics.visible.lazy.flatMap(\.lines).map { Self.columnCount($0.text) }.max() ?? 0
        }
        let visible = metrics.visible
        // Colours for this version: the latest page worked out, or what the cache already
        // holds (a panel reopened on a file it has coloured before shows them at once).
        let spans: [Int: [TokenSpan]] = colouring.flatMap { $0.version == version ? $0.spans : nil }
            ?? version.flatMap { SyntaxCache.shared.spans(for: $0) } ?? [:]
        let hidden = total - visible.reduce(0) { $0 + $1.lines.count }
        let gutter = metrics.gutter
        // Columns the code gets: the panel less the gutter, the marker and the paddings.
        let columns = max(20, Int((width - 8 - gutter * 2 - 4 - 6 - 12 - 12) / Self.charWidth))
        let longest = metrics.longest
        let wouldWrap = longest > columns
        // Anything but an explicit on or off follows the panel.
        let wrap = wrapSetting == "on" || (wrapSetting != "off" && wouldWrap)
        // Unwrapped, every row paints its background as wide as the longest line, which a
        // lazy stack would not work out on its own (it only measures the rows it has made).
        let lineWidth = wrap ? width : max(width, 8 + gutter * 2 + 4 + 6 + 12 + CGFloat(longest) * Self.charWidth + 12)

        return VStack(alignment: .leading, spacing: 0) {
            // The first @@ row is the panel's header: it stays put and carries the Wrap toggle.
            if let first = visible.first {
                hunkHeader(first, wrap: true, toggle: longest > 0 ? (on: wrap, auto: wouldWrap) : nil)
            }
            // Both axes either way: changing them would make a new scroll view and lose the
            // position. Wrapped, the content is exactly as wide as the panel, so there is
            // nothing to scroll sideways.
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // The lines select as text; numbers and markers stay out of a selection.
                    // One flat list of rows with ids, so the scroll position can hold on to the
                    // row at the top when wrapping changes every row's height.
                    ForEach(metrics.rows, id: \.id) { item in
                        switch item {
                        case .header(let hunk):
                            hunkHeader(hunk, wrap: wrap, minWidth: lineWidth)
                        case .line(let line):
                            row(line, gutter: gutter, spans: spans[line.id], wrapColumns: wrap ? columns : nil, minWidth: lineWidth)
                        }
                    }
                }
                .scrollTargetLayout()
                .frame(width: wrap ? width : nil, alignment: .leading)
                .frame(minWidth: lineWidth, alignment: .leading)
                .background {
                    if !wrap { ScrollObserver(scroll: scroll) }
                }
            }
            .scrollPosition(id: $topRow, anchor: .top)
            .scrollIndicators(.never)
            .textSelection(.enabled)
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .bottomLeading) {
                if !wrap { SidewaysIndicator(scroll: scroll, width: width) }
            }
            // The same scroll view either way, so crossing the wrap point (a resize on auto, or
            // the toggle) keeps the panel where it was scrolled to.
            if hidden > 0 {
                RowDivider()
                Button {
                    shownLines += Self.page
                } label: {
                    Text(verbatim: "Show \(hidden) more lines")
                        .font(Font13.small.weight(.medium))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(hidden) more lines")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changes, \(total) lines")
    }

    /// A small bordered toggle at the end of the panel's header. A choice that matches what
    /// the panel would pick anyway goes back to following the panel.
    private func wrapToggle(on: Bool, auto: Bool) -> some View {
        Button {
            wrapSetting = !on == auto ? "auto" : on ? "off" : "on"
        } label: {
            Text("Wrap")
                .font(on ? Font13.small.weight(.medium) : Font13.small)
                .foregroundStyle(on || wrapHovered ? Theme.text : Theme.muted)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(wrapHovered ? Theme.controlHover : Theme.control, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { wrapHovered = $0 }
        .help(on ? "Long lines wrap. Click to scroll them sideways instead" : "Click to wrap long lines")
        .accessibilityLabel("Wrap long lines")
        .accessibilityValue(on ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }

    private func hunkHeader(_ hunk: FileDiff.Hunk, wrap: Bool, minWidth: CGFloat? = nil, toggle: (on: Bool, auto: Bool)? = nil) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "@@")
                .foregroundStyle(Theme.muted)
            Text(verbatim: "-\(hunk.oldStart) +\(hunk.newStart)")
                .foregroundStyle(Theme.muted)
            if !hunk.context.isEmpty {
                Text(verbatim: hunk.context)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            if let toggle {
                Spacer(minLength: 8)
                wrapToggle(on: toggle.on, auto: toggle.auto).fixedSize()
            }
        }
        .font(Font13.mono)
        .padding(.horizontal, 12)
        .fixedSize(horizontal: !wrap, vertical: false)
        // Wrapped (and the fixed header) fill the offered width; unwrapped, inside the
        // sideways scroll, as wide as the longest line.
        .frame(minWidth: wrap ? nil : minWidth, maxWidth: wrap ? .infinity : nil, minHeight: 24, alignment: .leading)
        // Plain rectangles: inside a rounded panel a background would otherwise round its ends.
        .background(Theme.surface, in: Rectangle())
        // With the toggle in it, the row's parts stay apart so the toggle can be reached.
        .accessibilityElement(children: toggle == nil ? .combine : .contain)
    }

    /// One line. With `wrapColumns` it breaks into visual lines at whitespace, continuation
    /// lines indented under the code; the numbers stay on the first.
    private func row(_ line: FileDiff.Line, gutter: CGFloat, spans: [TokenSpan]?, wrapColumns: Int?, minWidth: CGFloat) -> some View {
        let background: Color = switch line.kind {
        case .added: Theme.diffAdded
        case .removed: Theme.diffRemoved
        case .context: .clear
        }
        let gutterTint: Color = switch line.kind {
        case .added: Theme.diffAddedGutter
        case .removed: Theme.diffRemovedGutter
        case .context: .clear
        }
        let marker = switch line.kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        }
        return HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 4) {
                Text(verbatim: line.oldNumber.map(String.init) ?? "")
                    .frame(width: gutter, alignment: .trailing)
                Text(verbatim: line.newNumber.map(String.init) ?? "")
                    .frame(width: gutter, alignment: .trailing)
            }
            .foregroundStyle(Theme.diffGutterText)
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .frame(minHeight: 20)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(gutterTint, in: Rectangle())
            .textSelection(.disabled)
            Text(verbatim: marker)
                .foregroundStyle(Theme.muted)
                .frame(width: 12, height: 20)
                .textSelection(.disabled)
            Group {
                if let wrapColumns, line.text.utf8.count <= Syntax.maxLineBytes, Self.columnCount(line.text) > wrapColumns {
                    let laid = Self.expandingTabs(code(line.text, spans: spans), line.text)
                    let pieces = Self.wrap(laid.widths, spaces: laid.spaces, columns: wrapColumns)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(Self.slices(laid.text, pieces.ranges).enumerated()), id: \.offset) { index, piece in
                            Text(piece)
                                .frame(minHeight: 20)
                                .padding(.leading, index == 0 ? 0 : CGFloat(pieces.hang) * Self.charWidth)
                        }
                    }
                } else {
                    Text(code(line.text, spans: spans)).frame(minHeight: 20)
                }
            }
            .foregroundStyle(Theme.codeText)
            .padding(.trailing, 12)
        }
        .font(Font13.mono)
        // Wrapped, a piece that still overflows (a glyph wider than measured) goes onto
        // another line rather than being cut off.
        .lineLimit(wrapColumns == nil ? 1 : nil)
        .fixedSize(horizontal: wrapColumns == nil, vertical: false)
        .frame(minWidth: wrapColumns == nil ? minWidth : nil, maxWidth: wrapColumns == nil ? nil : .infinity, minHeight: 20, alignment: .leading)
        .background(background, in: Rectangle())
        // A wrapped line is several pieces of text, which select apart; this copies it whole.
        .contextMenu {
            Button("Copy Line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(line.text, forType: .string)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(line))
    }

    /// The line as text, with coloured runs where the tokenizer found any. Built from plain
    /// strings, so nothing in the file is read as markup.
    private func code(_ text: String, spans: [TokenSpan]?) -> AttributedString {
        guard !text.isEmpty else { return AttributedString(" ") }
        guard let spans, !spans.isEmpty else { return AttributedString(text) }
        let bytes = Array(text.utf8)
        var out = AttributedString()
        var position = 0
        func plain(_ end: Int) {
            if end > position { out += AttributedString(String(decoding: bytes[position..<end], as: UTF8.self)) }
        }
        for span in spans {
            let start = Int(span.start), end = min(Int(span.end), bytes.count)
            guard start >= position, start < end else { continue }
            plain(start)
            var run = AttributedString(String(decoding: bytes[start..<end], as: UTF8.self))
            run.foregroundColor = Self.colour(span.kind)
            out += run
            position = end
        }
        plain(bytes.count)
        return out
    }

    /// Columns a character takes in the monospaced font: one for ASCII, measured for the rest
    /// (wide CJK characters and most emoji take two).
    @MainActor static func columns(of c: Character) -> Int {
        if c.isASCII { return 1 }
        if let known = measured[c] { return known }
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let w = (String(c) as NSString).size(withAttributes: [.font: font]).width
        let n = max(1, Int((w / charWidth - 0.1).rounded(.up)))
        if measured.count < 4096 { measured[c] = n }
        return n
    }

    @MainActor private static var measured: [Character: Int] = [:]

    /// Columns a line takes, with tabs to the next stop of four.
    @MainActor static func columnCount(_ text: String) -> Int {
        var col = 0
        for c in text { col += c == "\t" ? 4 - col % 4 : columns(of: c) }
        return col
    }

    /// The line with each tab turned into the spaces up to the next stop of four, colours
    /// kept, with each character's width in columns and whether it is a space. Display only.
    @MainActor static func expandingTabs(_ attributed: AttributedString, _ text: String) -> (text: AttributedString, widths: [Int], spaces: [Bool]) {
        var out = AttributedString()
        var widths: [Int] = []
        var spaces: [Bool] = []
        var col = 0
        for run in attributed.runs {
            let piece = String(attributed[run.range].characters)
            var buffer = ""
            for c in piece {
                if c == "\t" {
                    let n = 4 - col % 4
                    buffer += String(repeating: " ", count: n)
                    widths += Array(repeating: 1, count: n)
                    spaces += Array(repeating: true, count: n)
                    col += n
                } else {
                    let w = columns(of: c)
                    buffer.append(c)
                    widths.append(w)
                    spaces.append(c == " ")
                    col += w
                }
            }
            var part = AttributedString(buffer)
            part.foregroundColor = run.foregroundColor
            out += part
        }
        return (out, widths, spaces)
    }

    /// Visual lines at `columns` wide, as character ranges, breaking after the last space that
    /// fits past the line's indent (mid-word only when a word is longer than a line).
    /// Continuation lines are `hang` columns narrower: the line's own indent plus two, at most
    /// half the width. A line of nothing but spaces stays one line, and trailing spaces never
    /// make a line of their own.
    static func wrap(_ widths: [Int], spaces: [Bool], columns: Int) -> (ranges: [Range<Int>], hang: Int) {
        let count = widths.count
        var indentEnd = 0, indent = 0
        while indentEnd < count, spaces[indentEnd] { indent += widths[indentEnd]; indentEnd += 1 }
        guard indentEnd < count else { return ([0..<count], 0) }
        let hang = min(indent + 2, columns / 2)
        var ranges: [Range<Int>] = []
        var start = 0
        while start < count {
            let budget = ranges.isEmpty ? columns : columns - hang
            var used = 0, end = start, lastBreak: Int?
            while end < count, used + widths[end] <= budget {
                used += widths[end]
                if spaces[end], end >= indentEnd { lastBreak = end + 1 }
                end += 1
            }
            if end < count, let lastBreak, lastBreak > start { end = lastBreak }
            if end == start { end = start + 1 }
            // Only spaces left: they stay at the end of this line.
            if !spaces[end...].contains(false) { end = count }
            ranges.append(start..<end)
            start = end
        }
        return (ranges, hang)
    }

    /// The pieces of an attributed line for consecutive character ranges, colours kept, in
    /// one walk along it.
    static func slices(_ text: AttributedString, _ ranges: [Range<Int>]) -> [AttributedString] {
        let chars = text.characters
        var index = chars.startIndex
        var position = 0
        var out: [AttributedString] = []
        for range in ranges {
            let lower = chars.index(index, offsetBy: range.lowerBound - position)
            let upper = chars.index(lower, offsetBy: range.count)
            out.append(AttributedString(text[lower..<upper]))
            index = upper
            position = range.upperBound
        }
        return out
    }

    private static func colour(_ kind: TokenKind) -> Color {
        switch kind {
        case .keyword: Theme.codeKeyword
        case .string: Theme.codeString
        case .comment: Theme.codeComment
        case .number: Theme.codeNumber
        case .type: Theme.codeType
        case .function: Theme.codeFunction
        }
    }

    private func accessibilityText(_ line: FileDiff.Line) -> String {
        switch line.kind {
        case .added: "Added line \(line.newNumber ?? 0): \(line.text)"
        case .removed: "Removed line \(line.oldNumber ?? 0): \(line.text)"
        case .context: "Line \(line.newNumber ?? 0): \(line.text)"
        }
    }
}

/// Where a diff panel is scrolled sideways, and whether its indicator is showing. A class, so
/// only the indicator redraws as it changes.
@MainActor
@Observable
final class SidewaysScroll {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    /// The width of the scroll view's window onto the content.
    var viewport: CGFloat = 0
    var visible = false
    @ObservationIgnored private var seen = false
    @ObservationIgnored private var hide: Task<Void, Never>?

    /// A new scroll view to watch (after the wrap toggle): its first report is not a move.
    func restart() {
        seen = false
        hide?.cancel()
        visible = false
    }

    func update(offset: CGFloat, content: CGFloat, viewport: CGFloat) {
        let moved = seen && abs(offset - self.offset) > 0.5
        seen = true
        if self.content != content { self.content = content }
        if self.viewport != viewport { self.viewport = viewport }
        guard moved else {
            if self.offset != offset { self.offset = offset }
            return
        }
        self.offset = offset
        visible = true
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.visible = false
        }
    }
}

/// Watches the scroll view it sits in (its clip view's bounds) and reports the sideways
/// offset and the content's width. AppKit tells it when the bounds move, so nothing polls.
private struct ScrollObserver: NSViewRepresentable {
    let scroll: SidewaysScroll

    func makeNSView(context: Context) -> Probe { Probe(scroll: scroll) }
    func updateNSView(_ view: Probe, context: Context) { view.scroll = scroll }

    final class Probe: NSView {
        var scroll: SidewaysScroll
        private var observer: NSObjectProtocol?

        init(scroll: SidewaysScroll) {
            self.scroll = scroll
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        /// Never the target of a click or a scroll: those belong to the scroll view.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            scroll.restart()
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            guard let scrollView = enclosingScrollView else { return }
            let content = scrollView.documentView?.frame.width ?? 0
            scroll.update(offset: scrollView.contentView.bounds.origin.x, content: content, viewport: scrollView.contentView.bounds.width)
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

/// A thin bar along a diff panel's bottom edge, only while it scrolls sideways.
private struct SidewaysIndicator: View {
    let scroll: SidewaysScroll
    let width: CGFloat

    var body: some View {
        let content = max(scroll.content, 1)
        let viewport = scroll.viewport > 0 ? scroll.viewport : width
        let bar = max(24, width * min(1, viewport / content))
        let travel = max(0, content - viewport)
        let x = travel > 0 ? (width - bar) * min(1, max(0, scroll.offset / travel)) : 0
        Capsule()
            .fill(Theme.muted)
            .frame(width: bar, height: 3)
            .offset(x: x, y: -2)
            .opacity(scroll.visible && travel > 0 ? 1 : 0)
            .motion(Motion.quick, value: scroll.visible, reduced: Motion.fade)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The width a diff panel is offered.
private struct PanelWidth: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Lays its content out at exactly the offered width (and its own height for that width),
/// whatever the content would like. A plain flexible frame grows to a wider child instead.
private struct OfferedWidth: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? child.sizeThatFits(.unspecified).width
        let height = child.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
