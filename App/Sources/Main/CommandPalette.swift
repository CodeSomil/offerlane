import SwiftUI
import OfferlaneCore

/// ⌘K: jump to a screen, run an action, or find a role by title or company.
struct CommandPalette: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    struct Item: Identifiable {
        let id: String, title: String, subtitle: String, symbol: String
        let run: () -> Void
    }

    private var items: [Item] {
        let screens = SidebarItem.allCases.map { s in
            Item(id: "go.\(s.rawValue)", title: s.title, subtitle: "Screen", symbol: s.symbol) { app.navigate(to: s) }
        }
        let actions = [
            Item(id: "action.find", title: "Find Jobs", subtitle: "Action", symbol: "sparkle.magnifyingglass") { app.findJobs() },
            Item(id: "action.inbox", title: "Check Inbox", subtitle: "Action", symbol: "tray") { app.checkInbox() },
            Item(id: "action.setup", title: "Setup Center", subtitle: "Action", symbol: "stethoscope") { app.showSetupCenter = true },
        ]
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let commands = (screens + actions).filter { q.isEmpty || $0.title.lowercased().contains(q) }
        guard !q.isEmpty else { return commands }
        let roles = app.data.jobs
            .filter { "\($0.title) \($0.company)".lowercased().contains(q) }
            .prefix(8)
            .map { job in
                Item(id: "role.\(job.id)", title: job.title, subtitle: job.company, symbol: "briefcase") { open(job) }
            }
        return commands + roles
    }

    /// A tailored resume opens its review; any other role shows on its screen, filtered to it.
    private func open(_ job: Job) {
        if job.status == .review { app.navigate(to: .review); app.reviewing = job.id; return }
        let screen: SidebarItem = job.status == .found ? .find
            : (AppModel.reviewStatuses + [.tailoring]).contains(job.status) ? .review : .applications
        app.navigate(to: screen); app.searchText = job.title
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Palette.textSecondary).accessibilityHidden(true)
                TextField("Go to a screen, run an action, or find a role", text: $query)
                    .textFieldStyle(.plain).font(.title3)
                    .focused($focused)
                    .accessibilityIdentifier("palette.query")
                    .onSubmit { run(list) }
                    .onChange(of: query) { index = 0 }
                    .onKeyPress(.downArrow) { index = min(index + 1, max(list.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
            }
            .padding(DS.Space.l)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                            row(item, selected: i == index).id(item.id)
                                .onTapGesture { index = i; run(list) }
                        }
                    }
                    .padding(DS.Space.s)
                }
                .onChange(of: index) { if list.indices.contains(index) { proxy.scrollTo(list[index].id) } }
            }
            .overlay { if list.isEmpty { Text("Nothing matches “\(query)”.").foregroundStyle(DS.Palette.textSecondary) } }
        }
        .frame(width: 560, height: 380)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: item.symbol).frame(width: 20).accessibilityHidden(true)
            Text(item.title).lineLimit(1)
            Spacer()
            Text(item.subtitle).font(.callout).foregroundStyle(selected ? .white : DS.Palette.textSecondary).lineLimit(1)
        }
        .foregroundStyle(selected ? .white : DS.Palette.textPrimary)
        .padding(.horizontal, DS.Space.m).padding(.vertical, DS.Space.s)
        .background(selected ? DS.Palette.accent : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.s))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("palette.\(item.id)")
    }

    private func run(_ list: [Item]) {
        guard list.indices.contains(index) else { return }
        let item = list[index]
        dismiss()
        item.run()
    }
}

/// Toolbar bell: this session's toasts, newest first. An unread dot shows until it's opened.
struct NotificationsButton: View {
    @Environment(AppModel.self) private var app
    @State private var open = false

    var body: some View {
        Button { open.toggle(); app.unreadNotices = 0 } label: {
            Image(systemName: app.unreadNotices > 0 ? "bell.badge" : "bell")
        }
        .help("Notifications")
        .accessibilityLabel(app.unreadNotices > 0 ? "Notifications, \(app.unreadNotices) new" : "Notifications")
        .accessibilityIdentifier("notifications")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Notifications").font(DS.Font.title).padding(DS.Space.l)
                Divider()
                if app.notices.isEmpty {
                    Text("Nothing yet. Updates from Find Jobs, the inbox and your actions show here.")
                        .foregroundStyle(DS.Palette.textSecondary).padding(DS.Space.l)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            ForEach(app.notices) { n in
                                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                                    Image(systemName: n.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                        .foregroundStyle(n.isError ? DS.Palette.warning : DS.Palette.offer).accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(n.message).fixedSize(horizontal: false, vertical: true)
                                        Text(n.date, style: .time).font(.caption).foregroundStyle(DS.Palette.textSecondary)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("notice")
                            }
                        }
                        .padding(DS.Space.l)
                    }
                }
            }
            .frame(width: 360).frame(maxHeight: 420)
        }
    }
}
