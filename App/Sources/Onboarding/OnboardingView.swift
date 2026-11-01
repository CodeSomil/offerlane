import SwiftUI
import OfferlaneCore

/// Full-window setup wizard: step indicator, content, Back / Next on every step.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let m = app.onboarding!
        VStack(spacing: 0) {
            StepIndicator(model: m)
                .padding(.horizontal, 24).padding(.vertical, 14)
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
            }
            Divider()
            HStack(spacing: 12) {
                Button("Back") { m.back() }
                    .disabled(m.step == .ai)
                    .keyboardShortcut("[", modifiers: .command)
                    .accessibilityIdentifier("onboarding.back")
                Spacer()
                if let hint = m.nextHint { Text(hint).font(.callout).foregroundStyle(.secondary) }
                if m.step != .finish {
                    Button("Next") { m.next() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!m.canGoNext)
                        .accessibilityIdentifier("onboarding.next")
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(.bar)
        }
    }
}

private struct StepIndicator: View {
    let model: OnboardingModel
    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases) { s in
                let done = s.rawValue < model.step.rawValue, current = s == model.step
                Button { model.go(to: s) } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(current ? Color.accentColor : done ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15))
                            if done { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(Color.accentColor) }
                            else { Text("\(s.rawValue + 1)").font(.caption.bold()).foregroundStyle(current ? .white : .secondary) }
                        }
                        .frame(width: 22, height: 22)
                        Text(s.title).font(.callout.weight(current ? .semibold : .regular)).foregroundStyle(current ? .primary : .secondary)
                            .lineLimit(1).fixedSize()
                    }
                }
                .buttonStyle(.plain)
                .disabled(s.rawValue > model.step.rawValue)
                .accessibilityLabel("Step \(s.rawValue + 1), \(s.title)\(current ? ", current" : done ? ", done" : "")")
                if s != .finish { Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1).frame(minWidth: 8, maxWidth: 40) }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FinishStepView: View {
    let model: OnboardingModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 54)).foregroundStyle(.green)
            Text("You're all set").font(.largeTitle.bold())
            Text("Offerlane checks your companies' career sites, scores each role, and waits for your approval before it tailors or applies to anything.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 480)
            Text("Find jobs now?").font(.title3.weight(.semibold)).padding(.top, 8)
            HStack(spacing: 12) {
                Button("Not now") { model.finish(findNow: false) }.controlSize(.large).accessibilityIdentifier("onboarding.notNow")
                Button("Find Jobs") { model.finish(findNow: true) }.buttonStyle(.borderedProminent).controlSize(.large)
                    .accessibilityIdentifier("onboarding.findNow")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

/// Section heading used by every step.
struct StepHeader: View {
    let title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.largeTitle.bold())
            Text(subtitle).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .working: ProgressView().controlSize(.small)
            case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(.callout)
    }
}
