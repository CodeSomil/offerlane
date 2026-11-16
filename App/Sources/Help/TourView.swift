import SwiftUI
import OfferlaneCore

/// A five-card product tour over the main window. Skippable (Esc), replayable from Help → Take the Tour.
struct TourStop {
    let screen: SidebarItem?
    let symbol: String
    let title: String
    let text: String

    static let all: [TourStop] = [
        .init(screen: .find, symbol: "magnifyingglass", title: "Find jobs",
              text: "Click Find Jobs (⌘F). Offerlane searches free job sites and company career sites and gives each role a score out of 100."),
        .init(screen: .find, symbol: "hand.thumbsup", title: "Approve what's worth it",
              text: "Approve the roles you like and decline the rest. Offerlane tailors your resume for each approved role in the background."),
        .init(screen: .review, symbol: "checklist", title: "Review every change",
              text: "Tailored resumes wait here. You see every change before anything is sent, then Offerlane fills in the application and stops before Submit."),
        .init(screen: .applications, symbol: "rectangle.3.group", title: "Track applications",
              text: "Everything you've applied to, on one board. Connect your email and replies from employers move cards along by themselves."),
        .init(screen: nil, symbol: "lifepreserver", title: "Help is close by",
              text: "The status at the bottom of the sidebar shows if anything needs fixing. Help → Offerlane Help (⌘?) answers common questions."),
    ]
}

struct TourOverlay: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let i = app.tourStep, i < TourStop.all.count {
            let stop = TourStop.all[i]
            let last = i == TourStop.all.count - 1
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack {
                    Image(systemName: stop.symbol).font(.title2).foregroundStyle(DS.Palette.accent).accessibilityHidden(true)
                    Text(stop.title).font(DS.Font.title).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Text("\(i + 1) of \(TourStop.all.count)").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                Text(stop.text).font(DS.Font.body).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Skip Tour") { app.endTour() }.buttonStyle(.dsSecondary).keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("tour.skip")
                    Spacer()
                    if i > 0 { Button("Back") { app.moveTour(by: -1) }.buttonStyle(.dsSecondary).accessibilityIdentifier("tour.back") }
                    Button(last ? "Done" : "Next") { last ? app.endTour() : app.moveTour(by: 1) }
                        .buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction).accessibilityIdentifier("tour.next")
                }
            }
            .padding(DS.Space.l)
            .frame(width: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.l))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.l).strokeBorder(DS.Palette.accent.opacity(0.5)))
            .shadow(radius: 18, y: 6)
            .padding(DS.Space.xl)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
            .accessibilityIdentifier("tour.card")
            .transition(DS.Motion.reduced ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            .id(i)
        }
    }
}

extension AppModel {
    private var tourKey: String { "tourSeen." + (account?.id ?? "local") }

    /// Shown once per profile after first setup. UI tests opt in with OFFERLANE_TOUR=1.
    func startTourIfNeeded() {
        if Self.isUITest && TestHooks.env["OFFERLANE_TOUR"] != "1" { return }
        guard !UserDefaults.standard.bool(forKey: tourKey) else { return }
        startTour()
    }

    func startTour() {
        guard settings.onboarded else { return }
        reviewing = nil
        withDSAnimation { tourStep = 0; if let s = TourStop.all[0].screen { selection = s } }
    }

    func moveTour(by delta: Int) {
        guard let i = tourStep else { return }
        let next = max(0, min(TourStop.all.count - 1, i + delta))
        withDSAnimation { tourStep = next; if let s = TourStop.all[next].screen { selection = s } }
    }

    func endTour() {
        UserDefaults.standard.set(true, forKey: tourKey)
        withDSAnimation { tourStep = nil }
    }
}
