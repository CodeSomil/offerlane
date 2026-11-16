import SwiftUI
import OfferlaneCore

/// Full-window setup wizard: step indicator, content, Back / Next on every step.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let m = app.onboarding!
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.l) {
                Wordmark(size: 18)
                StepIndicator(model: m)
            }
            .padding(.horizontal, DS.Space.xl).padding(.vertical, 14)
            Divider()
            ScrollView {
                Group {
                    switch m.step {
                    case .ai: AIStepView(model: m)
                    case .resumes: ResumeStepView(model: m)
                    case .about: AboutStepView(model: m)
                    case .search: SearchStepView(model: m)
                    case .email: EmailStepView(model: m)
                    case .notifications: NotificationsStepView(model: m)
                    case .finish: FinishStepView(model: m)
                    }
                }
                .frame(maxWidth: 780)
                .padding(.horizontal, 32).padding(.vertical, 28)
                .frame(maxWidth: .infinity)
                .id(m.step)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: DS.Motion.reduced ? 0 : 12)), removal: .opacity))
            }
            .dsAnimation(value: m.step)
            Divider()
            HStack(spacing: 12) {
                Button("Back") { m.back() }
                    .buttonStyle(.ds(.secondary, .large))
                    .disabled(m.step == .ai)
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityIdentifier("onboarding.back")
                Spacer()
                if let hint = m.nextHint { Text(hint).font(.callout).foregroundStyle(DS.Palette.textSecondary) }
                if m.step.isOptional {
                    Button("Done") { m.done() }
                        .buttonStyle(.ds(.primary, .large))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!m.canGoNext)
                        .accessibilityIdentifier("onboarding.done")
                } else if m.step != .finish {
                    Button("Next") { m.next() }
                        .buttonStyle(.ds(.primary, .large))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!m.canGoNext)
                        .accessibilityIdentifier("onboarding.next")
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(.bar)
        }
    }
}

/// Sign in ✓ → Connect AI → Add resumes → Find jobs. Optional screens sit under "Find jobs".
private struct StepIndicator: View {
    let model: OnboardingModel
    var body: some View {
        let steps = OnboardingStep.main
        let currentIndex = steps.firstIndex(of: model.step) ?? steps.count - 1
        DSStepper(steps: [.init(id: "onboarding.step.signin", title: "Sign in", locked: true)]
                    + steps.map { .init(id: "onboarding.step.\($0.rawValue)", title: $0.title) },
                  current: currentIndex + 1) { i in model.go(to: steps[i - 1]) }
    }
}

/// Step 4: what Offerlane will do, drafted from the resume, with optional changes one click away.
private struct FinishStepView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            StepHeader(title: "Ready to find jobs", subtitle: "Offerlane set this up from your resume. Change anything now or later in Settings; nothing is applied for without your approval.")
            SectionCard(title: "What Offerlane will look for", symbol: "magnifyingglass") {
                if model.drafting {
                    StatusLine(kind: .working, text: "Picking job titles and companies from your resume…")
                    SkeletonList(rows: 2, label: "Drafting your search")
                } else if let e = model.draftError {
                    ErrorRow(text: e, action: "Try Again") { model.draftSearch() }
                } else {
                    let titles = model.search.titleInclude
                    Text(titles.isEmpty ? "No job titles yet." : titles.prefix(6).joined(separator: " · ") + (titles.count > 6 ? " and \(titles.count - 6) more" : ""))
                        .font(DS.Font.body).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("finish.titles")
                    HStack {
                        Text("\(model.search.companies.count) companies · roles scoring \(model.search.minScore)+ out of 100")
                            .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                        Spacer()
                        Button("Change…") { model.edit(.search) }.buttonStyle(.dsSecondary).accessibilityIdentifier("finish.editSearch")
                    }
                }
            }
            SectionCard(title: "Your details for applications", symbol: "person.text.rectangle") {
                let p = model.profile.personal
                let missing = model.profile.validationErrors
                Text([p.fullName, p.email, p.phone].filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty("Not filled in yet."))
                    .font(DS.Font.body)
                HStack {
                    if missing.isEmpty { StatusLine(kind: .ok, text: "Ready for applications.") }
                    else { StatusLine(kind: .info, text: "Needed before you apply (not to find jobs): \(missing.count == 1 ? "1 detail" : "\(missing.count) details").") }
                    Spacer()
                    Button("Change…") { model.edit(.about) }.buttonStyle(.dsSecondary).accessibilityIdentifier("finish.editAbout")
                }
            }
            SectionCard(title: "Optional", subtitle: "Skip these now; they're in Settings too.", symbol: "slider.horizontal.3") {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    optional("Track replies from employers", detail: model.email.enabled ? "On." : "Off. Connect your inbox to move applications along automatically.", step: .email, id: "finish.editEmail")
                    Divider()
                    optional("Notifications", detail: "On this Mac, and optionally on your phone.", step: .notifications, id: "finish.editNotifications")
                }
            }
            HStack(spacing: 12) {
                Spacer()
                Button("Not Now") { model.finish(findNow: false) }.buttonStyle(.ds(.secondary, .large)).accessibilityIdentifier("onboarding.notNow")
                Button("Find Jobs") { model.finish(findNow: true) }.buttonStyle(.ds(.primary, .large))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.searchReady)
                    .accessibilityIdentifier("onboarding.findNow")
            }
        }
    }

    private func optional(_ title: String, detail: String, step: OnboardingStep, id: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(DS.Font.headline)
                Text(detail).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            Spacer()
            Button("Set Up…") { model.edit(step) }.buttonStyle(.dsSecondary).accessibilityIdentifier(id)
        }
    }
}

private extension String { func ifEmpty(_ s: String) -> String { isEmpty ? s : self } }

/// Section heading used by every step.
struct StepHeader: View {
    let title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).font(.title3).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }
}

/// Green "done" / red "error" / grey "working" status line.
struct StatusLine: View {
    enum Kind { case ok, error, working, info }
    let kind: Kind, text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch kind {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Palette.offer).accessibilityLabel("Done:")
            case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DS.Palette.danger).accessibilityLabel("Problem:")
            case .working: ProgressRing(value: nil, size: 13, lineWidth: 2).accessibilityLabel("Working:")
            case .info: Image(systemName: "info.circle").foregroundStyle(DS.Palette.textSecondary).accessibilityHidden(true)
            }
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(.callout)
    }
}
