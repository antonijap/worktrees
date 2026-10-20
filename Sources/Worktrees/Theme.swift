import AppKit
import SwiftUI

/// Colour tokens, in both light and dark mode. The app aims at WCAG AA: text at least 4.5:1
/// on anything it sits on. Most pairs go further (text and muted reach 7:1 on the page
/// backgrounds); the code colours and the control fills are held to AA. Check new pairs
/// before adding them.
enum Theme {
    // Backgrounds
    static let background = dynamic(0xFFFFFF, 0x141519)
    static let sidebar = dynamic(0xFFFFFF, 0x1B1C21)
    static let surface = dynamic(0xFFFFFF, 0x1F2026)
    static let hover = dynamic(0xF3F3F6, 0x282930)
    /// Selected worktree: the one the detail column is about.
    static let selected = dynamic(0xECEEF4, 0x2B2D37)
    /// Selected folder: quieter, so the worktree selection stays the focus.
    static let sidebarSelected = dynamic(0xECECF0, 0x24252B)
    static let border = dynamic(0xEAEAEE, 0x2A2B31)
    /// Small bordered controls (pills) that sit on a hovered or tinted row: a step darker
    /// than `hover` so they stand out from it, and a step more under the pointer. Text 13:1
    /// and muted 7:1 on both in light; text 9.5:1 and muted 6.1:1 in dark.
    static let control = dynamic(0xE6E7EC, 0x34353E)
    static let controlHover = dynamic(0xDCDDE3, 0x3D3E48)

    // Text and status
    static let text = dynamic(0x15161C, 0xF3F3F6)
    static let muted = dynamic(0x41424D, 0xC4C5D0)
    static let accent = dynamic(0x1A3FA8, 0xAFC4FF)
    static let success = dynamic(0x064F27, 0x63E6A0)
    static let danger = dynamic(0x8A0F17, 0xFFAEAE)
    static let warning = dynamic(0x6A4100, 0xFFC46B)
    static let merged = dynamic(0x5427A6, 0xD8C4FF)
    // Solid badge fills. Each reaches 3:1 against every background (non-text contrast),
    // and the symbol drawn on it (onStatus) reaches 4.5:1 against the fill.
    static let badgeGreen = dynamic(0x15803D, 0x4ADE80)
    static let badgeYellow = dynamic(0xA16207, 0xFACC15)
    static let badgeRed = dynamic(0xB91C1C, 0xF87171)
    static let badgeOrange = dynamic(0xC2410C, 0xFB923C)
    static let badgePurple = dynamic(0x7E22CE, 0xC084FC)
    static let badgeGray = dynamic(0x52525B, 0xA1A1AA)

    /// Glyphs drawn on top of a status fill.
    static let onStatus = dynamic(0xFFFFFF, 0x141519)

    // Diff lines: soft tints under normal text, a shade deeper in the line-number gutter.
    // Text 15:1 or better on both in light, 11:1 in dark; gutter numbers 7:1 or better.
    static let diffAdded = dynamic(0xE6F4EA, 0x1E3A2A)
    static let diffRemoved = dynamic(0xFBE9E7, 0x3E2225)
    static let diffAddedGutter = dynamic(0xD3EDD9, 0x25513A)
    static let diffRemovedGutter = dynamic(0xF7D6D2, 0x55292E)
    /// Line numbers in the gutter: the muted grey in light, a touch lighter in dark.
    static let diffGutterText = dynamic(0x41424D, 0xE4E5EC)

    // Code in the diff panel. Light in the spirit of GitHub Light, dark of GitHub Dark. These
    // aim at WCAG AA rather than the 7:1 above, so they can read as distinct hues: each reaches
    // 5.3:1 or better on all three line backgrounds (context, added, removed) in its mode,
    // comments included.
    static let codeText = text
    static let codeKeyword = dynamic(0xB3202A, 0xFF8B83)
    static let codeString = dynamic(0x0A3069, 0xA5D6FF)
    static let codeComment = dynamic(0x59616B, 0xA4ADB8)
    static let codeNumber = dynamic(0x0550AE, 0x86C6FF)
    static let codeType = dynamic(0x8A3700, 0xFFB070)
    static let codeFunction = dynamic(0x6639BA, 0xD7B2FF)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Height of the top bars in every column. 32pt centres their controls on the traffic lights (16pt down).
let barHeight: CGFloat = 32
/// Side of an IconButton's square.
let iconButtonSize: CGFloat = 26
/// Gap between buttons in a top bar: the 26pt buttons leave 3pt above and below in the bar.
let barButtonGap: CGFloat = 3

/// Small bordered button for the top bars.
struct BarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BarButton(configuration: configuration)
    }

    private struct BarButton: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(
                    configuration.isPressed ? Theme.selected : hovering ? Theme.hover : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// System, light or dark, for the whole app: set on NSApp so the dynamic colours above, the
/// Settings window, sheets and alerts all follow it. Snapshots set their own and never read it.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearance"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    @MainActor static var current: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    @MainActor static func apply(_ appearance: Appearance) {
        NSApplication.shared.appearance = appearance.nsAppearance
    }

    @MainActor static func apply() { apply(current) }
}

/// The three durations the app moves at. Everything animated goes through `.motion`, which
/// drops to the Reduce Motion fallback (a short fade, or nothing) on its own.
enum Motion {
    /// Small state changes: a count, a chevron, a crossfade.
    static let quick = Animation.easeOut(duration: 0.15)
    /// Panels and columns showing or hiding.
    static let standard = Animation.easeInOut(duration: 0.18)
    /// Rows moving in a list.
    static let list = Animation.spring(response: 0.32, dampingFraction: 0.9)
    /// What a fade-only change gets under Reduce Motion.
    static let fade = Animation.easeOut(duration: 0.12)

    /// Makes a change with every animation off, whatever an ancestor asks for: for opening
    /// and closing things in a list, which should land in the same frame.
    static func instantly(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let reduced: Animation?
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? reduced : animation, value: value)
    }
}

private struct MotionTransition: ViewModifier {
    let full: AnyTransition
    let reduced: AnyTransition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? reduced : full)
    }
}

extension View {
    /// Animates changes of `value`; under Reduce Motion uses `reduced` instead (nothing by
    /// default, `Motion.fade` for changes that are only a fade).
    func motion<V: Equatable>(_ animation: Animation?, value: V, reduced: Animation? = nil) -> some View {
        modifier(MotionModifier(animation: animation, reduced: reduced, value: value))
    }

    /// A transition that is only a fade under Reduce Motion.
    func motionTransition(_ full: AnyTransition, reduced: AnyTransition = .opacity) -> some View {
        modifier(MotionTransition(full: full, reduced: reduced))
    }
}

/// A number that ticks to its new value (digits roll in the direction of change). Under
/// Reduce Motion it crossfades instead. Styling comes from the caller.
struct TickerText: View {
    let text: String
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ text: String, value: Double) { self.text = text; self.value = value }
    init(_ count: Int) { self.init("\(count)", value: Double(count)) }

    var body: some View {
        Text(verbatim: text)
            .contentTransition(reduceMotion ? .opacity : .numericText(value: value))
            .motion(Motion.quick, value: value, reduced: Motion.fade)
    }
}

/// Borderless icon button. With `busy` the icon turns until the work is done and the
/// label reads `busyLabel` meanwhile.
struct IconButton: View {
    let icon: IconName
    let label: String
    var shortcut: String? = nil
    var busy = false
    var busyLabel = "Working"
    /// Flips the icon left to right, for the mirror of a directional glyph.
    var mirrored = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SpinningIcon(name: icon, size: 14, spinning: busy)
                .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                .foregroundStyle(hovering ? Theme.text : Theme.muted)
                .frame(width: iconButtonSize, height: iconButtonSize)
                .background(hovering || Snapshot.reveal ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(busy ? busyLabel : shortcut.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(busy ? busyLabel : label)
    }
}

/// An icon that turns while `spinning` and then slows to rest on a half turn (the arrows look
/// the same every 180 degrees). The angle is worked out from the time, spin and stop alike, and
/// read on each frame of a TimelineView, so nothing re-arms itself: the timeline pauses when
/// at rest or off screen, and a restart mid-stop carries on from the angle on screen. Under
/// Reduce Motion it never turns: a small progress indicator takes its place while busy.
struct SpinningIcon: View {
    let name: IconName
    var size: CGFloat = 16
    let spinning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the current spin began; nil while stopping or at rest.
    @State private var start: Date?
    /// The slow-down after a spin, while it runs.
    @State private var stop: Stop?
    /// The angle at rest, and where a spin starts from.
    @State private var rest: Double = 0
    @State private var onScreen = false

    /// Constant deceleration from spinning speed to zero over `distance` degrees.
    private struct Stop: Equatable {
        let from: Double
        let distance: Double
        let at: Date
        var duration: Double { 2 * distance / SpinningIcon.degreesPerSecond }
    }

    /// Half a turn every 0.4 seconds.
    private static let degreesPerSecond = 450.0

    var body: some View {
        Group {
            if reduceMotion && spinning {
                ProgressView().controlSize(.small).frame(width: size, height: size)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: (start == nil && stop == nil) || !onScreen)) { context in
                    Icon(name: name, size: size).rotationEffect(.degrees(angle(at: context.date)))
                }
                .onAppear { onScreen = true }
                .onDisappear { onScreen = false }
            }
        }
        .onChange(of: spinning && !reduceMotion, initial: true) { _, active in
            let now = Date.now
            if active {
                guard start == nil else { return }
                rest = angle(at: now).truncatingRemainder(dividingBy: 360)
                stop = nil
                start = now
            } else if start != nil {
                // Slow down over at least a quarter turn, to the next half turn after that.
                let current = angle(at: now)
                let target = ((current + 90) / 180).rounded(.up) * 180
                start = nil
                stop = Stop(from: current, distance: target - current, at: now)
            }
        }
        // Lands the stop once it has run, so the timeline can pause.
        .task(id: stop) {
            guard let stop else { return }
            try? await Task.sleep(for: .seconds(stop.duration))
            guard !Task.isCancelled, self.stop == stop else { return }
            rest = stop.from + stop.distance
            self.stop = nil
        }
    }

    private func angle(at date: Date) -> Double {
        if let start {
            return rest + max(0, date.timeIntervalSince(start)) * Self.degreesPerSecond
        }
        if let stop {
            let u = min(1, max(0, date.timeIntervalSince(stop.at) / stop.duration))
            return stop.from + stop.distance * (1 - (1 - u) * (1 - u))
        }
        return rest
    }
}

extension View {
    /// Flat bordered panel, the container used throughout.
    func panel() -> some View { modifier(Panel()) }

    /// 1px line along one edge.
    /// `shown: false` leaves it out, for a column that can end at the window's edge.
    func hairline(_ edge: Alignment, shown: Bool = true) -> some View { modifier(Hairline(edge: edge, shown: shown)) }
}

/// Borders are decorative at normal contrast; with Increase Contrast they switch to a 3:1+ colour.
private struct Panel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(contrast == .increased ? Theme.muted : Theme.border))
    }
}

private struct Hairline: ViewModifier {
    let edge: Alignment
    var shown = true
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let color = contrast == .increased ? Theme.muted : Theme.border
        content.overlay(alignment: edge) {
            if !shown {
                EmptyView()
            } else if edge == .leading || edge == .trailing {
                Rectangle().fill(color).frame(width: 1)
            } else {
                Rectangle().fill(color).frame(height: 1)
            }
        }
    }
}

/// 1px line between rows inside a panel.
struct RowDivider: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1) }
}

/// Left inset shared by every column, so text lines up across bars, rows and footers.
let columnInset: CGFloat = 14
/// Inset for page content (the detail column and sheets), a little deeper than the bars.
let contentInset: CGFloat = columnInset + 6
/// Room for the window's traffic lights at the top left.
let trafficLightInset: CGFloat = 78

enum Font13 {
    static let body = Font.system(size: 13)
    static let medium = Font.system(size: 13, weight: .medium)
    static let small = Font.system(size: 12)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let label = Font.system(size: 11, weight: .semibold)
    /// Page and sheet titles.
    static let title = Font.system(size: 18, weight: .semibold)
}

/// Copies text and tells the person it happened: a short tick, a VoiceOver announcement.
@MainActor
enum Clipboard {
    static func copy(_ text: String, label: String, store: Store) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Sounds.play(.tap)
        store.announce("Copied \(label)")
    }
}

/// Small copy button that appears on hover (or keyboard focus) and shows a check for a
/// moment after copying, crossfading both ways.
struct CopyButton: View {
    let text: String
    let label: String
    /// Whether the row it sits in is hovered; the button also shows itself while focused.
    var shown: Bool
    @Environment(Store.self) private var store
    @State private var copied = false
    @State private var reset: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        Button {
            Clipboard.copy(text, label: label, store: store)
            copied = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .milliseconds(1200))
                if !Task.isCancelled { copied = false }
            }
        } label: {
            // 13pt matches the body text it sits beside; the 22pt frame keeps a usable target
            // and leaves about 6pt between the glyph and the value when the row spacing is 2.
            ZStack {
                Icon(name: .copy, size: 13).foregroundStyle(Theme.muted).opacity(copied ? 0 : 1)
                Icon(name: .check, size: 13).foregroundStyle(Theme.success).opacity(copied ? 1 : 0)
            }
            .motion(Motion.quick, value: copied, reduced: Motion.fade)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .opacity(shown || copied || focused || Snapshot.reveal ? 1 : 0)
        .help("Copy \(label)")
        .accessibilityLabel(copied ? "Copied" : "Copy \(label)")
    }
}

/// A value that copies itself on click: one button around the text and a copy glyph, so the
/// glyph can't vanish when the pointer moves from the text onto it. Hover tints the whole
/// value and shows the glyph; a click copies and shows a check for a moment. VoiceOver reads
/// it as "Copy <label>". For values that are links, use CopyButton beside them instead.
struct CopyValue<Content: View>: View {
    let text: String
    let label: String
    @ViewBuilder let content: () -> Content
    @Environment(Store.self) private var store
    @State private var hovering = false
    @State private var copied = false
    @State private var reset: Task<Void, Never>?
    @FocusState private var focused: Bool

    init(_ text: String, label: String, @ViewBuilder content: @escaping () -> Content) {
        self.text = text; self.label = label; self.content = content
    }

    var body: some View {
        Button {
            Clipboard.copy(text, label: label, store: store)
            copied = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .milliseconds(1200))
                if !Task.isCancelled { copied = false }
            }
        } label: {
            HStack(spacing: 4) {
                content()
                ZStack {
                    Icon(name: .copy, size: 13).foregroundStyle(Theme.muted).opacity(copied ? 0 : 1)
                    Icon(name: .check, size: 13).foregroundStyle(Theme.success).opacity(copied ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                .opacity(hovering || copied || focused ? 1 : 0)
                .motion(Motion.quick, value: copied, reduced: Motion.fade)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 4))
            // The tint reaches 4pt past the text; the text itself stays where it was.
            .padding(.horizontal, -4)
            .padding(.vertical, -2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
        .help("Copy \(label)")
        .accessibilityLabel(copied ? "Copied" : "Copy \(label)")
    }
}

/// Text that opens a URL: underlined on hover, pointer cursor, reachable by keyboard.
struct LinkText: View {
    let text: String
    let url: URL
    let label: String
    var font: Font = Font13.body
    var color: Color = Theme.accent
    @State private var hovering = false

    var body: some View {
        Button {
            Sounds.play(.open)
            Open.url(url)
        } label: {
            Text(verbatim: text)
                .font(font)
                .foregroundStyle(color)
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .onHover { over in
            hovering = over
            // set, not push/pop: a view that vanishes under the pointer never sends hover-out,
            // and an unbalanced pop would restore the wrong cursor.
            (over ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .onDisappear { if hovering { NSCursor.arrow.set() } }
        .help(label)
        .accessibilityLabel(text)
        .accessibilityHint(label)
    }
}
