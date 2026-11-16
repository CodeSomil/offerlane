import AppKit
import OfferlaneAPI
import OfferlaneCore
import SwiftUI

/// The sync engine's wire, on the generated API client.
struct HTTPSyncRemote: SyncRemote {
    let http: SyncHTTP
    func me() async throws -> String { try await http.me() }
    func get(_ kind: String) async throws -> SyncBlob? {
        try await http.get(kind).map { SyncBlob(version: $0.version, keyId: $0.keyId, ciphertext: $0.ciphertext) }
    }
    func put(_ kind: String, expected: Int?, keyId: String, ciphertext: Data) async throws -> SyncPut {
        switch try await http.put(kind, expected: expected, keyId: keyId, ciphertext: ciphertext) {
        case .ok(let v): .ok(version: v)
        case .conflict: .conflict
        }
    }
}

/// Sync on the Mac (v4 P4.4): sign in to the Offerlane cloud, set up or unlock the account key, Sync now.
/// The server only ever gets ciphertext (docs/v4/SYNC_CRYPTO.md); signed out, nothing leaves this Mac.
@MainActor @Observable
final class CloudSync {
    enum Phase: Equatable { case signedOut, checking, newAccount, needsKey, otherAccount, ready(last: String?), showKey(String) }
    var phase: Phase = .signedOut
    var busy = false
    var error: String?
    let config = CloudConfig.load()
    static let sessionAccount = "cloud-session"

    func session(_ kc: Keychain) -> CloudSession? {
        kc.get(account: Self.sessionAccount).flatMap { try? JSONDecoder().decode(CloudSession.self, from: Data($0.utf8)) }.flatMap { $0.isValid ? $0 : nil }
    }
    func engine(_ app: AppModel) -> SyncEngine? {
        guard let s = session(app.keychain) else { return nil }
        let token = s.token
        let client = Client.offerlane(serverURL: config.api, token: { token })
        return SyncEngine(remote: HTTPSyncRemote(http: SyncHTTP(client: client)), local: StoreSyncLocal(store: app.store), keys: app.keychain)
    }

    func check(_ app: AppModel) async {
        guard let e = engine(app) else { phase = .signedOut; return }
        if case .showKey = phase { return }
        await run { phase = .checking; phase = Self.phase(try await e.setup()) }
    }
    static func phase(_ s: SyncEngine.Setup) -> Phase {
        switch s {
        case .ready(let last): .ready(last: last)
        case .newAccount: .newAccount
        case .needsKey: .needsKey
        case .otherAccount: .otherAccount
        }
    }

    func signIn(_ app: AppModel) async {
        await run {
            let s = try await CloudSignIn(config: config) { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }.signIn()
            try app.keychain.set(String(decoding: try JSONEncoder().encode(s), as: UTF8.self), account: Self.sessionAccount)
        }
        await check(app)
    }
    func signOut(_ app: AppModel) {
        app.keychain.delete(account: Self.sessionAccount)
        phase = .signedOut; error = nil
    }
    func create(_ app: AppModel) async {
        guard let e = engine(app) else { return signOut(app) }
        await run { phase = .showKey(try await e.createKeyring()) }
    }
    func restore(_ app: AppModel, key: String) async {
        guard let e = engine(app) else { return signOut(app) }
        await run { try await e.restoreKeyring(key) }
        await check(app)
    }
    func syncNow(_ app: AppModel) async {
        guard let e = engine(app) else { return signOut(app) }
        await run {
            let r = try await e.syncNow()
            if r.pulled > 0 { app.refresh() }
            app.toast = Toast(message: r.pulled + r.pushed == 0 ? "Everything is already in sync." : "Synced: \(r.pulled) updated here, \(r.pushed) sent.")
        }
        await check(app)
    }
    func turnOff(_ app: AppModel) async {
        guard let e = engine(app) else { return signOut(app) }
        await run { try e.forget() }
        await check(app)
    }

    private func run(_ f: () async throws -> Void) async {
        busy = true; error = nil
        defer { busy = false }
        do { try await f() } catch {
            self.error = error.plainMessage
            if case .checking = phase { phase = .signedOut }
        }
    }
}

struct SyncSection: View {
    @Environment(AppModel.self) private var app
    @State private var sync = CloudSync()
    @State private var key = ""

    var body: some View {
        SectionCard(title: "Sync", subtitle: "Encrypted on this Mac before it leaves. Offerlane's servers can't read it.", symbol: "arrow.triangle.2.circlepath") {
            VStack(alignment: .leading, spacing: 10) {
                content
                if let e = sync.error {
                    Text(e).font(DS.Font.callout).foregroundStyle(DS.Palette.danger).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("sync.error")
                }
            }
            .disabled(sync.busy)
        }
        .task { await sync.check(app) }
    }

    @ViewBuilder private var content: some View {
        switch sync.phase {
        case .signedOut:
            note("Sign in to sync your profile, resume and applications with Offerlane on the web and on Windows.")
            Button("Sign In to Sync…") { Task { await sync.signIn(app) } }.buttonStyle(.dsPrimary).accessibilityIdentifier("sync.signIn")
        case .checking:
            ProgressView().controlSize(.small)
        case .newAccount:
            note("Turning sync on makes a recovery key. You need it to open your synced data on another device.")
            HStack {
                Button("Turn On Sync") { Task { await sync.create(app) } }.buttonStyle(.dsPrimary).accessibilityIdentifier("sync.create")
                signOut
            }
        case .needsKey:
            note("This account already syncs from another device. Enter the recovery key you saved when you turned sync on.")
            HStack {
                TextField("Recovery key", text: $key).textFieldStyle(.roundedBorder).frame(maxWidth: 320).accessibilityIdentifier("sync.key")
                Button("Unlock") { Task { await sync.restore(app, key: key); key = "" } }.buttonStyle(.dsPrimary).disabled(key.isEmpty)
                    .accessibilityIdentifier("sync.restore")
            }
            signOut
        case .otherAccount:
            note("This Mac syncs with a different account. Turn sync off here to use this one.")
            HStack { turnOff; signOut }
        case .showKey(let rk):
            Text("Your recovery key").font(DS.Font.headline)
            Text(rk).font(.system(.title3, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("sync.recoveryKey")
            note("Write it down or print it, and keep it somewhere safe. It's shown only once. If you lose every device and this key, your synced data can't be recovered, by you or by us.")
            HStack {
                Button("Copy") {
                    // Concealed: clipboard managers and Universal Clipboard history skip it (nspasteboard.org convention).
                    let pb = NSPasteboard.general; pb.clearContents()
                    pb.setString(rk, forType: .string); pb.setString("", forType: .init("org.nspasteboard.ConcealedType"))
                }.buttonStyle(.dsSecondary)
                Button("I've Saved It") { sync.phase = .checking; Task { await sync.check(app) } }.buttonStyle(.dsPrimary).accessibilityIdentifier("sync.saved")
            }
        case .ready(let last):
            note(last.map { "Last synced \(Self.when($0))." } ?? "Not synced from this Mac yet.")
            HStack {
                Button("Sync Now") { Task { await sync.syncNow(app) } }.buttonStyle(.dsPrimary).accessibilityIdentifier("sync.now")
                turnOff
                signOut
            }
        }
    }

    private var signOut: some View {
        Button("Sign Out of Sync") { sync.signOut(app) }.buttonStyle(.dsSecondary).accessibilityIdentifier("sync.signOut")
    }
    private var turnOff: some View {
        Button("Turn Off Sync on This Mac") { Task { await sync.turnOff(app) } }.buttonStyle(.dsSecondary).accessibilityIdentifier("sync.turnOff")
    }
    private func note(_ s: String) -> some View {
        Text(s).font(DS.Font.callout).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
    }
    static func when(_ iso: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso).map { $0.formatted(date: .abbreviated, time: .shortened) } ?? iso
    }
}
