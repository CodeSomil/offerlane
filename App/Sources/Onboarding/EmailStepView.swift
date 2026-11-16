import SwiftUI
import OfferlaneCore

struct EmailStepView: View {
    @Bindable var model: OnboardingModel
    var showsHeader = true
    @Environment(\.openURL) private var openURL
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader {
                StepHeader(title: "Track replies by email", subtitle: "Optional. Offerlane reads recent mail from employers to update each application (interview, assessment, offer, rejection) and to finish career-site sign-ups. It only reads; it never sends or deletes.")
            }
            Toggle("Track application replies from my inbox", isOn: $model.email.enabled).toggleStyle(.switch)
                .accessibilityIdentifier("email.enabled")
            if model.email.enabled, let app = model.app, app.gmailAvailable, app.account != nil {
                GmailCard(model: model)
            }
            if model.email.enabled && !model.email.gmail {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Provider", selection: Binding(get: { model.email.preset }, set: { model.applyPreset($0) })) {
                            ForEach(MailPreset.all) { Text($0.name).tag($0.key) }
                        }.pickerStyle(.segmented)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                            if model.email.preset == "custom" { FieldRow(label: "IMAP server", text: $model.email.host, prompt: "imap.example.com") }
                            FieldRow(label: "Email address", text: $model.email.user, prompt: "you@gmail.com")
                            FieldRow(label: "App password", text: $model.emailPassword, prompt: "16-character app password", secure: true)
                        }
                        HStack {
                            if let p = MailPreset.all.first(where: { $0.key == model.email.preset }), !p.help.isEmpty {
                                Button("How to get an app password") { openURL(URL(string: p.help)!) }.buttonStyle(.link)
                            }
                            Spacer()
                            Button("Test Connection") { model.testEmail() }
                                .disabled(model.email.user.isEmpty || model.emailPassword.isEmpty || model.email.host.isEmpty || model.emailTesting)
                        }
                        if model.emailTesting { StatusLine(kind: .working, text: "Connecting…") }
                        if let r = model.emailResult { StatusLine(kind: .ok, text: r) }
                        if let e = model.emailError { ErrorRow(text: e, action: "Try Again") { model.testEmail() } }
                        Text("The password is stored in your Mac's Keychain. Use an app password, not your normal one.").font(.caption).foregroundStyle(DS.Palette.textSecondary)
                    }.padding(8)
                }
            }
        }
    }
}

struct NotificationsStepView: View {
    @Bindable var model: OnboardingModel
    var showsHeader = true
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if showsHeader {
                StepHeader(title: "Notifications", subtitle: "Offerlane tells you when there's something to approve, a resume to review, or a form ready for you to submit.")
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("Mac notifications", systemImage: "bell.badge").font(.headline)
                        Spacer()
                        Button("Allow Notifications") { model.requestNotifications() }
                    }
                    if let s = model.notificationStatus { StatusLine(kind: s.hasPrefix("Notifications are on") ? .ok : .info, text: s) }
                }.padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $model.notify.ntfy) { Label("Also send to my phone (ntfy)", systemImage: "iphone").font(.headline) }.toggleStyle(.switch)
                    if model.notify.ntfy {
                        HStack(alignment: .top, spacing: 18) {
                            if let img = QRCode.image(Ntfy.url(topic: model.notify.ntfyTopic).absoluteString) {
                                Image(nsImage: img).interpolation(.none).resizable().frame(width: 150, height: 150)
                                    .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 8))
                                    .accessibilityLabel("QR code for your private notification topic")
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("1. Install the free ntfy app on your phone.\n2. Scan this code (or subscribe to the topic below).\n3. Click Send Test.")
                                Text(model.notify.ntfyTopic).font(.body.monospaced()).textSelection(.enabled)
                                Text("The topic is a private random name. Messages contain only short status text, never your resume.").font(.caption).foregroundStyle(DS.Palette.textSecondary)
                                HStack { Button("Send Test") { model.sendNtfyTest() }; if let r = model.ntfyTestResult { StatusLine(kind: r.hasPrefix("Sent") ? .ok : .error, text: r) } }
                            }
                        }
                    }
                }.padding(8)
            }
        }
        .task { model.refreshNotificationStatus() }
    }
}

/// Gmail API preview (Google Testing mode, invited testers only). IMAP below stays the default.
struct GmailCard: View {
    @Bindable var model: OnboardingModel
    var body: some View {
        if let app = model.app {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "envelope.badge.shield.half.filled").foregroundStyle(DS.Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) { Text("Connect Gmail").font(.headline); Pill(text: "Preview", tint: DS.Palette.info) }
                            Text(app.gmailLinked && model.email.gmail ? "Connected. Offerlane reads replies from employers (read-only), no app password needed."
                                 : "Sign in with Google instead of using an app password. Read-only. For invited testers while Offerlane awaits Google's review; access lasts 7 days at a time.")
                                .font(.caption).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if app.gmailLinked && model.email.gmail {
                            Button("Use IMAP Instead") { app.disconnectGmail(); model.email.gmail = false }.accessibilityIdentifier("gmail.disconnect")
                        } else {
                            Button("Connect Gmail") { app.connectGmail() }.buttonStyle(.dsPrimary).disabled(app.authBusy).accessibilityIdentifier("gmail.connect")
                        }
                    }
                    if app.authBusy, let m = app.authMessage, m.contains("Gmail") { StatusLine(kind: .working, text: m) }
                    if let e = app.authError { StatusLine(kind: .error, text: e) }
                }.padding(8)
            }
            .onChange(of: app.settings.email.gmail) { _, on in model.email.gmail = on }
        }
    }
}
