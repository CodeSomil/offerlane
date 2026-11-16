import SwiftUI
import LocalAuthentication
import OfferlaneCore

/// Welcome: Continue with Google (primary) or email + password (local-only profile).
struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    enum Mode { case choose, create, signIn }
    @State private var mode: Mode = .choose
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var touchID = false
    @State private var confirmErase = false
    @FocusState private var focus: Field?
    enum Field { case name, email, password, confirm }

    var body: some View {
        HStack(spacing: 0) {
            brandPanel.frame(width: 380)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    switch mode {
                    case .choose: choose
                    case .create: createForm
                    case .signIn: signInForm
                    }
                    if app.authBusy, let m = app.authMessage {
                        HStack(spacing: DS.Space.s) {
                            ProgressRing(value: nil)
                            Text(m).font(DS.Font.callout)
                            Spacer()
                            Button("Cancel") { app.cancelAuth() }.buttonStyle(.dsGhost).keyboardShortcut(.cancelAction)
                        }
                        .accessibilityIdentifier("auth.busy")
                    }
                    if let e = app.authError {
                        StatusLine(kind: .error, text: e).accessibilityIdentifier("auth.error")
                    }
                }
                .frame(maxWidth: 420, alignment: .leading)
                .padding(DS.Space.xxl)
                .frame(maxWidth: .infinity, minHeight: 560)
            }
            .background(DS.Palette.canvas)
        }
        .onAppear {
            if mode == .choose, let last = app.accounts.accounts.filter({ $0.kind == .password }).max(by: { ($0.lastSignIn ?? "") < ($1.lastSignIn ?? "") }) {
                email = last.email; mode = .signIn
            }
        }
        .onChange(of: mode) { app.authError = nil; password = ""; confirm = "" }
        .confirmationDialog("Erase this profile and start again?", isPresented: $confirmErase) {
            Button("Erase Profile", role: .destructive) { app.eraseProfile(email: email); password = ""; mode = .create }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Offerlane has no server, so a forgotten password can't be reset by email. Erasing removes this profile and everything in it from this Mac: resumes, roles, applications and saved career-site passwords. Other profiles aren't touched.")
        }
    }

    // MARK: panels

    private var brandPanel: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [DS.Palette.brandBlue, Color(hex: 0x3730A3), DS.Palette.brandNight], startPoint: .topLeading, endPoint: .bottomTrailing)
            LaneMotif().frame(width: 300, height: 320).padding(.bottom, 96)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).opacity(0.55)
                .colorScheme(.dark)
            VStack(alignment: .leading, spacing: DS.Space.m) {
                LogoMark(size: 64)
                Text("Offerlane").font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                Text(Brand.tagline).font(.title3).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Label("Everything stays on this Mac. There's no Offerlane server.", systemImage: "lock.shield")
                    .font(DS.Font.callout).foregroundStyle(.white.opacity(0.85))
            }
            .padding(DS.Space.xxl)
        }
    }

    private var choose: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Welcome").font(DS.Font.display)
            Text("Sign in to keep your resumes, roles and applications in your own profile. You'll stay signed in until you sign out.")
                .foregroundStyle(DS.Palette.textSecondary)
            Button { app.signInWithGoogle() } label: {
                HStack { Image(systemName: "g.circle.fill"); Text("Continue with Google") }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.ds(.primary, .large))
            .disabled(!app.googleSignInReady || app.authBusy)
            .accessibilityIdentifier("auth.google")
            if !app.googleSignInReady {
                Text("Google sign-in isn't set up in this copy of Offerlane yet. Use email and password instead.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            } else {
                Text("Offerlane only asks Google for your name and email address.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            HStack { Rectangle().fill(DS.Palette.hairline).frame(height: 1); Text("or").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary); Rectangle().fill(DS.Palette.hairline).frame(height: 1) }
            Button { mode = .create } label: { Text("Use email and password").frame(maxWidth: .infinity) }
                .buttonStyle(.ds(.secondary, .large)).accessibilityIdentifier("auth.useEmail")
            if app.accounts.accounts.contains(where: { $0.kind == .password }) {
                Button("I already have a profile on this Mac") { mode = .signIn }.buttonStyle(.link)
            }
        }
    }

    private var createForm: some View {
        let problem = PasswordStrength.problem(password)
        let mismatch = !confirm.isEmpty && confirm != password
        let canCreate = !name.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@") && problem == nil && confirm == password && !app.authBusy
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            backButton
            Text("Create your profile").font(DS.Font.display)
            Text("Your profile and password stay on this Mac.").foregroundStyle(DS.Palette.textSecondary)
            labeled("Your name") { TextField("Alex Morgan", text: $name).focused($focus, equals: .name).accessibilityIdentifier("auth.name") }
            labeled("Email") { TextField("you@example.com", text: $email).textContentType(.emailAddress).focused($focus, equals: .email).accessibilityIdentifier("auth.email") }
            labeled("Password") {
                SecureField("At least \(PasswordStrength.minimumLength) characters", text: $password).textContentType(.newPassword)
                    .focused($focus, equals: .password).accessibilityIdentifier("auth.password")
            }
            if !password.isEmpty { StrengthMeter(password: password) }
            labeled("Confirm password") {
                SecureField("Type it again", text: $confirm).textContentType(.newPassword).focused($focus, equals: .confirm).accessibilityIdentifier("auth.confirm")
            }
            if mismatch { Text("The passwords don't match.").font(DS.Font.caption).foregroundStyle(DS.Palette.danger) }
            if TouchID.available {
                Toggle("Unlock with Touch ID when Offerlane opens", isOn: $touchID).toggleStyle(.switch)
            }
            Button { app.createProfile(name: name.trimmingCharacters(in: .whitespaces), email: email, password: password, touchID: touchID) } label: {
                Text("Create Profile").frame(maxWidth: .infinity)
            }
            .buttonStyle(.ds(.primary, .large)).keyboardShortcut(.defaultAction).disabled(!canCreate)
            .accessibilityIdentifier("auth.create")
            Button("I already have a profile on this Mac") { mode = .signIn }.buttonStyle(.link)
        }
        .onAppear { focus = .name }
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            backButton
            Text("Sign in").font(DS.Font.display)
            labeled("Email") { TextField("you@example.com", text: $email).textContentType(.emailAddress).focused($focus, equals: .email).accessibilityIdentifier("auth.email") }
            labeled("Password") {
                SecureField("Password", text: $password).textContentType(.password).focused($focus, equals: .password)
                    .onSubmit { if !password.isEmpty { app.signIn(email: email, password: password) } }
                    .accessibilityIdentifier("auth.password")
            }
            Button { app.signIn(email: email, password: password) } label: { Text("Sign In").frame(maxWidth: .infinity) }
                .buttonStyle(.ds(.primary, .large)).keyboardShortcut(.defaultAction)
                .disabled(email.isEmpty || password.isEmpty || app.authBusy)
                .accessibilityIdentifier("auth.signIn")
            HStack {
                Button("Forgot password?") { confirmErase = true }.buttonStyle(.link).disabled(email.isEmpty)
                Spacer()
                Button("Create a new profile") { mode = .create }.buttonStyle(.link)
            }
        }
        .onAppear { focus = email.isEmpty ? .email : .password }
    }

    private var backButton: some View {
        Button { mode = .choose } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.dsGhost)
            .keyboardShortcut("[", modifiers: .command)
    }

    private func labeled<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label).font(DS.Font.callout.weight(.medium))
            c().textFieldStyle(.roundedBorder).controlSize(.large)
        }
    }
}

/// Live password strength bar with a plain-English label.
struct StrengthMeter: View {
    let password: String
    var body: some View {
        let score = PasswordStrength.score(password), problem = PasswordStrength.problem(password)
        let tint = score >= 3 ? DS.Palette.offer : score == 2 ? DS.Palette.info : DS.Palette.warning
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(i < max(1, score) ? tint : Color.secondary.opacity(0.2)).frame(height: 5)
                }
            }
            Text(problem.map { "\(PasswordStrength.label(score)). \($0)" } ?? PasswordStrength.label(score))
                .font(DS.Font.caption).foregroundStyle(problem == nil ? Color.secondary : DS.Palette.warning)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Password strength: \(PasswordStrength.label(score))")
        .accessibilityIdentifier("auth.strength")
        .dsAnimation(DS.Motion.quick, value: score)
    }
}

/// "We found your existing data": shown once, to the first profile, before anything moves.
struct ClaimDataView: View {
    @Environment(AppModel.self) private var app
    let account: LocalAccount
    var body: some View {
        VStack(spacing: DS.Space.l) {
            LogoMark(size: 72)
            Text("Bring in your existing data?").font(DS.Font.display)
            Text("Offerlane found resumes, roles and applications from before profiles existed on this Mac. You can move them into \(account.name.isEmpty ? account.email : account.name)'s profile. A backup copy is saved first, so nothing can be lost.")
                .multilineTextAlignment(.center).foregroundStyle(DS.Palette.textSecondary).frame(maxWidth: 520)
            HStack(spacing: DS.Space.m) {
                Button("Start Fresh") { app.resolveLegacy(claim: false) }.buttonStyle(.ds(.secondary, .large)).accessibilityIdentifier("claim.fresh")
                Button("Use My Existing Data") { app.resolveLegacy(claim: true) }.buttonStyle(.ds(.primary, .large))
                    .keyboardShortcut(.defaultAction).accessibilityIdentifier("claim.use")
            }
            .disabled(app.authBusy)
            if app.authBusy, let m = app.authMessage { HStack { ProgressRing(value: nil); Text(m) } }
            if let e = app.authError { StatusLine(kind: .error, text: e) }
            Text("Start Fresh leaves the old data where it is; it won't be offered again.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.canvas)
    }
}

/// Profile locked behind Touch ID.
struct LockView: View {
    @Environment(AppModel.self) private var app
    let account: LocalAccount
    var body: some View {
        VStack(spacing: DS.Space.l) {
            LogoMark(size: 72)
            Text("Welcome back\(account.name.isEmpty ? "" : ", \(account.name.split(separator: " ").first.map(String.init) ?? "")")").font(DS.Font.display)
            Text("Unlock your profile to continue.").foregroundStyle(DS.Palette.textSecondary)
            Button { app.unlock() } label: { Label("Unlock with Touch ID", systemImage: "touchid") }
                .buttonStyle(.ds(.primary, .large)).keyboardShortcut(.defaultAction).disabled(app.authBusy)
            if let e = app.authError { StatusLine(kind: .error, text: e) }
            Button("Sign out instead") { app.signOut() }.buttonStyle(.link)
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.canvas)
        .onAppear { app.unlock() }
    }
}

enum TouchID {
    static var available: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }
}
