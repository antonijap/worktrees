import AppKit
import SwiftUI

/// The first-launch window: Welcome, Folders, GitHub, All set.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.step {
                case .welcome: WelcomeStep()
                case .folders: FoldersStep(model: model)
                case .github: GitHubStep(model: model)
                case .ready: ReadyStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, 28)

            footer
        }
        .frame(width: 680, height: 520)
        .background(Theme.background)
        .onChange(of: model.step) {
            Sounds.play(.tap)
            AccessibilityNotification.Announcement("Step \(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count), \(model.step.name)").post()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(OnboardingModel.Step.allCases, id: \.self) { step in
                    Capsule()
                        .fill(step == model.step ? Theme.accent : Theme.control)
                        .frame(width: step == model.step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
            .motion(Motion.quick, value: model.step)
            Spacer()
            if model.step != .welcome {
                Button("Back") { model.back() }
                    .keyboardShortcut(.cancelAction)
            }
            if model.step == .github, github == nil || !isReady {
                Button("Skip for Now") { model.next() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.muted)
            }
            Button(primaryTitle) {
                if model.step == .ready { finish() } else { model.next() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canContinue)
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .frame(height: 64)
        .hairline(.top)
    }

    private var github: GitHubSetup? { model.github }
    private var isReady: Bool { if case .ready = model.github { true } else { false } }

    private var primaryTitle: String {
        switch model.step {
        case .welcome: "Get Started"
        case .ready: "Open Worktrees"
        default: "Continue"
        }
    }
}

/// The 3D app icon, swaying slowly. Still when Reduce Motion is on.
struct TiltingIcon: View {
    var size: CGFloat = 168
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    /// In the app bundle, copied there by bundle.sh. A bare build reads it from the source tree.
    private static let image: NSImage = {
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/icon-3d.png")
        let url = Bundle.main.url(forResource: "icon-3d", withExtension: "png") ?? dev
        return NSImage(contentsOf: url) ?? NSApplication.shared.applicationIconImage ?? NSImage()
    }()

    var body: some View {
        // Snapshots draw it at rest, so pictures don't depend on the clock.
        // Also rests while the window is in the background, so it costs nothing unseen.
        let still = reduceMotion || Snapshot.isOn
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || activeState == .inactive)) { context in
            let t = still ? 0 : context.date.timeIntervalSinceReferenceDate
            let icon = Image(nsImage: Self.image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
            // At rest the icon is drawn flat: a 3D transform, even of zero degrees, puts it in a
            // layer that snapshots can't place.
            if still {
                icon
            } else {
                icon
                    .rotation3DEffect(.degrees(sin(t * 0.45) * 9), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                    .rotation3DEffect(.degrees(cos(t * 0.3) * 4), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            }
        }
        // A TimelineView takes all the room it is offered; the icon keeps its own size.
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct StepTitle: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Font13.heading)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(Font13.body).foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            TiltingIcon()
            Text("Every worktree, in one place")
                .font(Font13.hero)
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Text("See what's done, and clear it away.")
                .font(Font13.lead)
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }
}

private struct FoldersStep: View {
    @Bindable var model: OnboardingModel
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepTitle(title: "Where do your projects live?", subtitle: "Tick the folders that hold your repos.")
            if model.gitStatus != .ready {
                let license = model.gitStatus == .licenseNotAccepted
                let broken = model.gitStatus == .broken
                VStack(spacing: 0) {
                    StatusRow(icon: .alert, tint: Theme.warning,
                              title: license ? "Git needs the Xcode license accepted" : broken ? "Git won't run" : "Git isn't installed",
                              detail: broken ? "Worktrees needs it to read your repos. Try this in a terminal to see why." : "Worktrees needs it to read your repos. Run this, then continue.",
                              command: license ? GitCheck.licenseCommand : broken ? "git --version" : GitCheck.installCommand, copied: $copied)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .panel()
            }
            VStack(spacing: 0) {
                if model.finding && model.suggestions.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking in your home folder…").font(Font13.body).foregroundStyle(Theme.muted)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .hairline(.bottom)
                } else if model.suggestions.isEmpty {
                    Text("No project folders found in your home folder. Choose the one you use.")
                        .font(Font13.body)
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .hairline(.bottom)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.suggestions) { suggestion in
                            SuggestionRow(suggestion: suggestion) { model.toggle(suggestion) }
                        }
                    }
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let urls = FolderPicker.choose() { Task { await model.add(urls) } }
                } label: {
                    HStack(spacing: 12) {
                        Icon(name: .plus, size: 14)
                        Text("Choose Another Folder…").font(Font13.medium)
                        Spacer()
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .panel()
            Text("Agent worktrees are found wherever they live.")
                .font(Font13.small)
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 48)
    }
}

private struct SuggestionRow: View {
    let suggestion: FolderSuggestion
    let toggle: () -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { suggestion.picked }, set: { _ in toggle() })) {
            HStack(spacing: 10) {
                Icon(name: .folder, size: 14).foregroundStyle(Theme.muted)
                Text(verbatim: suggestion.url.path.abbreviatingHome)
                    .font(Font13.medium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(suggestion.repoCount) repo\(suggestion.repoCount == 1 ? "" : "s")")
                    .font(Font13.small)
                    .foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hairline(.bottom)
        .accessibilityLabel("\(suggestion.url.path.abbreviatingHome), \(suggestion.repoCount) repo\(suggestion.repoCount == 1 ? "" : "s")")
    }
}

private struct GitHubStep: View {
    @Bindable var model: OnboardingModel
    /// The command last copied; the tick is shown on that one only.
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StepTitle(title: "Show pull requests and checks", subtitle: "Optional. Uses the gh tool you already have.")
            VStack(spacing: 0) {
                switch model.github {
                case nil:
                    StatusRow(icon: nil, tint: Theme.muted, title: "Checking for gh…")
                case .notInstalled:
                    StatusRow(icon: .alert, tint: Theme.warning, title: "gh isn't installed", detail: "Install it, then check again.", command: "brew install gh", copied: $copied)
                case .signedOut(let path):
                    StatusRow(icon: .check, tint: Theme.success, title: "gh is installed", detail: path.abbreviatingHome)
                    StatusRow(icon: .alert, tint: Theme.warning, title: "Not signed in yet", detail: "Run this, then check again.", command: "gh auth login", copied: $copied)
                case .ready(let path, let login):
                    StatusRow(icon: .check, tint: Theme.success, title: "gh is installed", detail: path.abbreviatingHome)
                    StatusRow(icon: .check, tint: Theme.success, title: login.map { "Signed in as \($0)" } ?? "Signed in")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .panel()
            .onChange(of: model.github) { copied = nil }
            HStack {
                Spacer()
                Button {
                    model.checkGitHub()
                } label: {
                    Label { Text("Check Again") } icon: { Icon(name: .refreshCw, size: 12) }
                }
                .controlSize(.small)
                .disabled(model.checkingGitHub)
            }
        }
        .padding(.horizontal, 48)
    }
}

private struct StatusRow: View {
    let icon: IconName?
    let tint: Color
    let title: String
    var detail: String?
    var command: String?
    var copied: Binding<String?>?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon { Icon(name: icon, size: 16).foregroundStyle(tint) } else { ProgressView().controlSize(.small) }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Font13.medium).foregroundStyle(Theme.text)
                if let detail { Text(verbatim: detail).font(Font13.small).foregroundStyle(Theme.muted) }
                if let command, let copied {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied.wrappedValue = command
                    } label: {
                        HStack(spacing: 10) {
                            Text(verbatim: command).font(Font13.mono).foregroundStyle(Theme.text)
                            Icon(name: copied.wrappedValue == command ? .check : .copy, size: 12)
                                .foregroundStyle(copied.wrappedValue == command ? Theme.success : Theme.muted)
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 8)
                        .padding(.vertical, 6)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied.wrappedValue == command ? "Copied \(command)" : "Copy \(command)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .hairline(.bottom)
    }
}

private struct ReadyStep: View {
    @Bindable var model: OnboardingModel
    @AppStorage(Prefs.Key.menuBarIcon) private var menuBarIcon = false
    @AppStorage(Prefs.Key.notifyChecksFailed) private var notifyChecks = false
    @State private var loginOn = LoginItem.isOn
    @State private var loginProblem: String?
    @State private var notifyProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Circle().fill(Theme.selected).frame(width: 36, height: 36)
                    .overlay(Icon(name: .check, size: 18).foregroundStyle(Theme.success))
                    .accessibilityHidden(true)
                Text("All set").font(Font13.heading).foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                if model.store.isBusy { ProgressView().controlSize(.small) }
            }
            // Numbers only once the scan and GitHub are done, so they never read as final early.
            let stats = model.stats
            let busy = model.store.isBusy
            HStack(spacing: 12) {
                Stat(value: busy ? nil : stats.repos, label: "repos")
                Stat(value: busy ? nil : stats.worktrees, label: "worktrees")
                Stat(value: busy ? nil : stats.attention, label: "need attention", tint: stats.attention > 0 ? Theme.warning : Theme.text)
                Stat(value: busy ? nil : stats.tidy, label: "ready to tidy")
            }
            Text("Optional extras, also in Settings.").font(Font13.body).foregroundStyle(Theme.muted)
            VStack(spacing: 0) {
                ExtraRow(title: "Show in menu bar", note: "With the count that needs attention.", isOn: $menuBarIcon)
                ExtraRow(title: "Open at login", note: loginProblem, isOn: Binding(get: { loginOn }, set: { on in
                    loginProblem = LoginItem.set(on)
                    loginOn = LoginItem.isOn
                }))
                ExtraRow(title: "Notify when checks fail",
                         note: Notifier.available ? notifyProblem : "Needs the installed app.",
                         isOn: Binding(get: { notifyChecks }, set: { on in
                    notifyChecks = on
                    notifyProblem = nil
                    guard on else { return }
                    Task {
                        // Asked for: off again if macOS says no, so the switch tells the truth.
                        if !(await Notifier.requestPermission()) {
                            notifyChecks = false
                            notifyProblem = "Notifications are off in System Settings."
                        }
                    }
                }))
                .disabled(!Notifier.available)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .panel()
        }
        .padding(.horizontal, 48)
    }
}

private struct Stat: View {
    /// nil while still counting.
    let value: Int?
    let label: String
    var tint: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let value {
                TickerText(value).font(Font13.hero).foregroundStyle(tint)
            } else {
                Text("…").font(Font13.hero).foregroundStyle(Theme.muted).accessibilityLabel("counting")
            }
            Text(label).font(Font13.small).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .panel()
        .accessibilityElement(children: .combine)
    }
}

private struct ExtraRow: View {
    let title: String
    var note: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Font13.medium).foregroundStyle(Theme.text)
                if let note { Text(note).font(Font13.small).foregroundStyle(Theme.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hairline(.bottom)
    }
}
