import SwiftUI
import OfferlaneCore

/// Interview prep: common questions for the role, a STAR story bank built only from resume bullets, and a mock interviewer.
struct InterviewView: View {
    @Environment(AppModel.self) private var app
    enum Tab: String, CaseIterable { case questions = "Questions", stories = "STAR Stories", practice = "Mock Interview" }
    @State private var tab = Tab.questions
    @State private var role = ""
    @State private var questions: [InterviewQuestion] = []
    @State private var prep = InterviewPrepState()
    @State private var bullets: [String: String] = [:]
    @State private var drafting = false
    @State private var note: String?
    @State private var question = ""
    @State private var answer = ""
    @State private var feedback: MockFeedback?
    @State private var asking = false

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Interview Prep", subtitle: "Practise for \(role.isEmpty ? "your next role" : role). Stories use only what your resume says.") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack {
                        TextField("Role", text: $role).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                            .onSubmit(loadQuestions).accessibilityLabel("Interview role").accessibilityIdentifier("interview.role")
                        Picker("Section", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420).accessibilityIdentifier("interview.tab")
                    }
                    privacy
                    switch tab {
                    case .questions: questionList
                    case .stories: storyBank
                    case .practice: practice
                    }
                }
                .padding(DS.Space.xl)
            }
        }
        .onAppear(perform: load)
        .onChange(of: prep) { save() }
    }

    private var privacy: some View {
        Group {
            if let ai = app.ai {
                Text("Drafting stories sends your resume bullets, and feedback sends your answer, to \(ai.client.displayName), the AI you connected.")
            } else {
                Text("No AI connected: stories start from your bullets and you fill them in. Mock feedback needs an AI (Connect AI in the sidebar).")
            }
        }
        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
    }

    private var questionList: some View {
        SectionCard(title: "Common questions", subtitle: "Typical for this kind of role; real interviews vary. Skill questions come from your collected postings.", symbol: "questionmark.bubble") {
            ForEach(questions) { q in
                HStack {
                    Pill(text: q.kind == "role" ? "Role" : q.kind == "skill" ? "Skill" : "Behavioral", tint: q.kind == "behavioral" ? .secondary : DS.Palette.accent)
                    Text(q.text).font(DS.Font.callout)
                    Spacer()
                    Button("Practise") { question = q.text; answer = ""; feedback = nil; tab = .practice }
                        .buttonStyle(.dsSecondary).accessibilityLabel("Practise: \(q.text)")
                }
            }
        }
    }

    private var storyBank: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack {
                Button(drafting ? "Drafting…" : prep.stories.isEmpty ? "Draft Stories From My Resume" : "Redraft Stories") { draft() }
                    .buttonStyle(.dsPrimary).disabled(drafting).accessibilityIdentifier("interview.draft")
                if drafting { ProgressView().controlSize(.small) }
            }
            if let note { Label(note, systemImage: "info.circle").font(DS.Font.callout).accessibilityIdentifier("interview.note") }
            if prep.stories.isEmpty && !drafting {
                EmptyState(title: "No stories yet", symbol: "text.book.closed", message: "Draft STAR stories from your resume, then edit them in your own words.") { EmptyView() }
            }
            ForEach($prep.stories) { $s in
                SectionCard(title: s.title, symbol: "star") {
                    ForEach([("Situation", $s.situation), ("Task", $s.task), ("Action", $s.action), ("Result", $s.result)], id: \.0) { label, text in
                        TextField(label, text: text, axis: .vertical).textFieldStyle(.roundedBorder).accessibilityLabel("\(label) for \(s.title)")
                    }
                    Text("From your resume: " + s.bulletIds.compactMap { bullets[$0] }.joined(separator: " · "))
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    ForEach(s.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(DS.Font.caption) }
                    HStack {
                        Spacer()
                        Button("Delete") { prep.stories.removeAll { $0.id == s.id } }.buttonStyle(.dsGhost).accessibilityLabel("Delete story \(s.title)")
                    }
                }
                .accessibilityElement(children: .contain).accessibilityIdentifier("interview.story")
            }
        }
    }

    private var practice: some View {
        SectionCard(title: "Mock interview", subtitle: "Answer out loud or in writing, then get feedback. Nothing is sent until you ask.", symbol: "person.wave.2") {
            Picker("Question", selection: $question) { ForEach(questions) { Text($0.text).tag($0.text) } }
                .accessibilityIdentifier("interview.question").onChange(of: question) { feedback = nil }
            TextEditor(text: $answer).font(DS.Font.callout).frame(minHeight: 140).scrollContentBackground(.hidden)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Your answer").accessibilityIdentifier("interview.answer")
            HStack {
                Button(asking ? "Thinking…" : "Get Feedback") { ask() }.buttonStyle(.dsPrimary)
                    .disabled(asking || app.ai == nil || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("interview.feedback")
                Button("Next Question") { next() }.buttonStyle(.dsSecondary)
                if let last = prep.practice.last { Text("Last score: \(last.score)/5 · \(prep.practice.count) practised").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
            }
            if let f = feedback {
                Pill(text: "\(f.score)/5", tint: DS.Palette.accent).accessibilityIdentifier("interview.score")
                ForEach(f.strengths, id: \.self) { Label($0, systemImage: "checkmark.circle").font(DS.Font.callout) }
                ForEach(f.improve, id: \.self) { Label($0, systemImage: "arrow.up.circle").font(DS.Font.callout) }
                if !f.followUp.isEmpty { Text("Follow-up: \(f.followUp)").font(DS.Font.callout).italic() }
            }
        }
    }

    private func load() {
        prep = (try? app.store.get(.interviewPrep)) ?? InterviewPrepState()
        let resume = (try? app.store.resume())?.content
        bullets = Dictionary((resume.map(InterviewPrep.bullets) ?? []).map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        if role.isEmpty {
            let state: SkillPlanState = (try? app.store.get(.skillPlan)) ?? SkillPlanState()
            role = state.goal ?? SkillPlanner.roles(state, app.search).first ?? resume?.experience.first?.title ?? ""
        }
        loadQuestions()
    }

    private func loadQuestions() {
        let report = role.isEmpty ? nil : try? SkillPlanner.report(store: app.store, role: role)
        questions = InterviewPrep.questions(role: role, report: report)
        if !questions.contains(where: { $0.text == question }) { question = questions.first?.text ?? "" }
    }

    private func draft() {
        guard let resume = (try? app.store.resume())?.content else { note = "Add a resume on the Resumes screen first, then draft stories."; return }
        drafting = true; note = nil
        Task {
            let r = await InterviewPrep.stories(resume: resume, ai: app.ai)
            prep.stories = r.stories
            note = r.note ?? (r.dropped > 0 ? "\(r.dropped) AI draft\(r.dropped == 1 ? "" : "s") left out: they added facts your resume doesn't have." : nil)
            drafting = false
        }
    }

    private func ask() {
        guard let ai = app.ai else { return }
        asking = true
        Task {
            do {
                let f = try await InterviewPrep.feedback(question: question, answer: answer, role: role, ai: ai)
                feedback = f
                prep.practice.append(.init(day: String(ISO8601DateFormatter().string(from: Date()).prefix(10)), question: question, score: f.score))
            } catch {
                app.toast = .error("Couldn't get feedback: \(error.plainMessage)", "Try Again") { ask() }
            }
            asking = false
        }
    }

    private func next() {
        let i = questions.firstIndex { $0.text == question } ?? -1
        question = questions.isEmpty ? "" : questions[(i + 1) % questions.count].text
        answer = ""; feedback = nil
    }

    private func save() {
        do { try app.store.set(.interviewPrep, prep) }
        catch { app.toast = .error("Couldn't save your interview prep: \(error.plainMessage). Free some disk space, then try again.", "Try Again") { save() } }
    }
}
