//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// Destinations pushed inside a root tab's navigation stack.
enum Route: Hashable {
    case gameReview(gameKey: String, ply: Int?)
    case mistakeDrill(MistakeOccurrence)
    case explore(ExploreStart)
    case queue
    case howAnalysisWorks
    case about
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showsPlayers = false
    @State private var showsSettings = false
    @State private var showsFilters = false
    @State private var showsPaywall = false
    @State private var showsMistakesPreview = false
    @State private var paths: [RootTab: [Route]] = [:]
    /// Development only: a screen opened straight from launch to inspect it.
    @State private var debugScreen: DebugScreen?

    var body: some View {
        @Bindable var model = model

        Group {
            if model.trackedPlayers.isEmpty || model.isOnboarding {
                WelcomeScreen()
            } else {
                TabView(selection: tabSelection) {
                    ForEach(RootTab.allCases) { tab in
                        NavigationStack(path: binding(for: tab)) {
                            content(for: tab)
                                .navigationTitle(tab.title)
                                // Analytics leads with its own hero; the lists lead with a large title.
                                .navigationBarTitleDisplayMode(tab == .analytics ? .inline : .large)
                                .toolbar { toolbar(for: tab) }
                                .navigationDestination(for: Route.self, destination: destination)
                                .screenBackground()
                        }
                        .tabItem { Label(tab.title, systemImage: symbol(for: tab)) }
                        .tag(tab)
                    }
                }
                .modifier(QueueAccessoryModifier(hasWork: hasQueuedWork && !isReviewingGame) { openQueue() })
                .onChange(of: model.selectedTab) { _, _ in model.persistSelection() }
                // A subscription that lapsed while Mistakes was open leaves it.
                .onChange(of: model.isMistakesLocked, initial: true) { _, isLocked in
                    if isLocked, model.selectedTab == .mistakes { model.selectedTab = .analytics }
                }
            }
        }
        .task { applyDevelopmentRoute() }
        .sheet(isPresented: $showsPlayers) { PlayersSheet().hostsPaywall() }
        .sheet(isPresented: $showsSettings) { SettingsSheet().hostsPaywall() }
        .sheet(isPresented: $showsFilters) { FiltersSheet(showsDates: model.selectedTab != .games) }
        .sheet(isPresented: $showsMistakesPreview) { MistakesPreviewSheet().hostsPaywall() }
        .sheet(item: $debugScreen) { screen in debugView(screen) }
        .hostsPaywall(isPresented: $showsPaywall)
        .environment(\.showFilters, ShowFiltersAction { showsFilters = true })
        .environment(\.openMistakes, OpenMistakesAction { openMistakes(gameKey: $0) })
    }

    /// The tab bar's selection. Tapping the locked Mistakes tab opens its preview and leaves the
    /// current tab where it is.
    private var tabSelection: Binding<RootTab> {
        Binding(get: { model.selectedTab }, set: { tab in
            if tab == .mistakes, model.isMistakesLocked {
                showsMistakesPreview = true
            } else {
                // The tab itself shows every game; only a game's rings narrow it.
                if tab == .mistakes { model.mistakesGameKey = nil }
                model.selectedTab = tab
            }
        })
    }

    /// With `gameKey`, Mistakes opens at its list narrowed to that game.
    private func openMistakes(gameKey: String? = nil) {
        if model.isMistakesLocked { showsMistakesPreview = true; return }
        if let gameKey {
            model.mistakesGameKey = gameKey
            paths[.mistakes] = []
        }
        model.selectedTab = .mistakes
    }

    /// Locked, Mistakes shows a lock with its own triangle as the badge, and stays unselected.
    private func symbol(for tab: RootTab) -> String {
        tab == .mistakes && model.isMistakesLocked ? "lock.trianglebadge.exclamationmark" : tab.symbol
    }

    private var hasQueuedWork: Bool {
        model.coordinator.counts.pending + model.coordinator.counts.running > 0
    }

    /// A game review shows its own analysis, and its controls sit where the accessory would.
    private var isReviewingGame: Bool {
        switch paths[model.selectedTab]?.last {
        case .gameReview, .mistakeDrill, .explore: return true
        default: return false
        }
    }

    private func openQueue() {
        var path = paths[model.selectedTab] ?? []
        guard path.last != .queue else { return }
        path.append(.queue)
        paths[model.selectedTab] = path
    }

    private func binding(for tab: RootTab) -> Binding<[Route]> {
        Binding(get: { paths[tab] ?? [] }, set: { paths[tab] = $0 })
    }

    /// Development-only deep link used to inspect a screen straight from launch.
    private func applyDevelopmentRoute() {
        #if DEBUG
        var filters = model.filters
        if let timeClass = DevelopmentSeed.startupTimeClass { filters.timeClass = timeClass }
        if let range = DevelopmentSeed.startupDateRange { filters.dateRange = range }
        if filters != model.filters { model.updateFilters(filters) }
        if let tab = DevelopmentSeed.startupTab { model.selectedTab = tab }
        if let route = DevelopmentSeed.startupRoute { paths[model.selectedTab] = [route] }
        if DevelopmentSeed.opensExplore, case .gameReview(let key, let ply)? = DevelopmentSeed.startupRoute {
            let review = GameReviewModel()
            review.load(app: model, gameKey: key, initialPly: ply)
            if let start = review.exploreStart { paths[model.selectedTab, default: []].append(.explore(start)) }
        }
        if let key = DevelopmentSeed.queuedGame {
            Task {
                try? await Task.sleep(for: .seconds(3))
                model.requestReview(gameKey: key, deep: true)
            }
        }
        if DevelopmentSeed.opensFirstMistake, let player = model.selectedPlayer,
           let first = (try? model.statistics.occurrences(playerID: player.id, filters: model.filters,
                                                           scope: model.scope, limit: 1))?.first {
            paths[model.selectedTab] = [.mistakeDrill(first)]
        }
        switch DevelopmentSeed.startupSheet {
        case "settings": showsSettings = true
        case "players": showsPlayers = true
        case "paywall": showsPaywall = true
        case "mistakes-preview": showsMistakesPreview = true
        case "filters": showsFilters = true
        case let name?: debugScreen = DebugScreen(rawValue: name)
        default: break
        }
        #endif
    }

    /// Screens that normally sit several taps deep, opened directly for inspection.
    enum DebugScreen: String, Identifiable {
        case addPlayer = "add-player", importing, subscription, backup, storage, relink, licence
        case reviewDepth = "review-depth"
        var id: String { rawValue }
    }

    @ViewBuilder
    private func debugView(_ screen: DebugScreen) -> some View {
        switch screen {
        case .addPlayer: AddPlayerSheet()
        case .importing:
            if let player = model.selectedPlayer {
                NavigationStack { ScrollView { ImportingHistoryView(player: player) {}.padding(Layout.gutter) }.screenBackground() }
            }
        case .subscription: NavigationStack { SubscriptionScreen() }
        case .backup: NavigationStack { BackupScreen() }
        case .storage: NavigationStack { StorageScreen() }
        case .relink:
            if let player = model.selectedPlayer { UpdateUsernameSheet(player: player) }
        case .licence: NavigationStack { LicenceTextScreen() }
        case .reviewDepth: NavigationStack { ReviewDepthScreen() }
        }
    }

    @ViewBuilder
    private func content(for tab: RootTab) -> some View {
        switch tab {
        case .analytics: AnalyticsScreen()
        case .games: GamesScreen()
        case .mistakes:
            // The tab bar never selects Mistakes while it is locked; this covers any other way in.
            if model.isMistakesLocked {
                EmptyState(symbol: "lock.fill", title: "Mistakes come with Premium",
                           message: "See what is here, on sample games.",
                           actionTitle: "Preview Mistakes") { showsMistakesPreview = true }
                    .padding(Layout.gutter)
            } else {
                MistakesScreen()
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .gameReview(let key, let ply): GameReviewScreen(gameKey: key, initialPly: ply)
        case .mistakeDrill(let occurrence): MistakeDrillScreen(occurrence: occurrence)
        case .explore(let start): ExploreScreen(start: start, mode: startupExploreMode)
        case .queue: QueueScreen()
        case .howAnalysisWorks: HowAnalysisWorksScreen()
        case .about: AboutScreen()
        }
    }

    /// Explore opens on both sides, except when a development launch asks otherwise.
    private var startupExploreMode: ExploreModel.Mode {
        #if DEBUG
        return DevelopmentSeed.startupExploreMode
        #else
        return .bothSides
        #endif
    }

    @ToolbarContentBuilder
    private func toolbar(for tab: RootTab) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showsPlayers = true
            } label: {
                Text(String(model.selectedPlayer?.displayUsername.prefix(1).uppercased() ?? "?"))
                    .font(.headline)
                    .frame(width: 30, height: 30)
            }
            .accessibilityLabel(model.selectedPlayer.map { "Tracked players. Currently \($0.displayUsername) on \($0.provider.displayName)" }
                                ?? "Tracked players. Currently none")
        }
        if tab != .analytics {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsFilters = true
                } label: {
                    Image(systemName: (tab == .games ? model.filters.activeCountIgnoringDates : model.filters.activeCount) > 0
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease")
                }
                .accessibilityLabel("Filters, \(model.filters.summary)")
            }
        }
        if !QueueAccessoryModifier.isAvailable, hasQueuedWork {
            ToolbarItem(placement: .topBarTrailing) {
                Button { openQueue() } label: { Image(systemName: "hourglass") }
                    .accessibilityLabel("Analysis queue")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showsSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }
}

/// Shows the analysis queue above the tab bar while there is work, the way iOS 26 shows an
/// ongoing activity. Older systems reach the queue from a toolbar button instead.
struct QueueAccessoryModifier: ViewModifier {
    let hasWork: Bool
    let open: () -> Void

    static var isAvailable: Bool {
        if #available(iOS 26.1, *) { return true }
        return false
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
                .tabViewBottomAccessory(isEnabled: hasWork) {
                    QueueAccessory(open: open)
                }
        } else {
            content
        }
    }
}

struct QueueAccessory: View {
    @Environment(AppModel.self) private var model
    let open: () -> Void

    private var coordinator: AnalysisCoordinator { model.coordinator }
    private var remaining: Int { coordinator.counts.pending + coordinator.counts.running }

    private var fraction: Double { coordinator.currentFraction }

    private var title: String {
        if coordinator.isPausedByUser { return "Paused" }
        if let blocker = coordinator.primaryBlocker { return blocker.title }
        if coordinator.currentGameKey == nil { return "Waiting" }
        return coordinator.isPacing ? "Analysing, cooling" : "Analysing"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.18), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: max(0.02, fraction))
                            .stroke(Palette.brand, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 22, height: 22)
                    Text(title).fontWeight(.semibold)
                        + Text("  \(remaining) left").foregroundStyle(Palette.inkSecondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Analysis queue: \(title), \(remaining) games left")

            if coordinator.isPausedByUser {
                Button { coordinator.resume() } label: { Image(systemName: "play.fill") }
                    .accessibilityLabel("Resume analysis")
            } else {
                Button { coordinator.pause() } label: { Image(systemName: "pause.fill") }
                    .accessibilityLabel("Pause analysis")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 16)
    }
}

// MARK: - Cross-screen actions

/// Presents the paywall over whatever shows it. Each sheet hosts its own, because a sheet can
/// only present from the topmost one: a request passed down to the root while a sheet is up
/// would never appear.
private struct PaywallHost: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) { PaywallScreen() }
            .environment(\.showPaywall, ShowPaywallAction { isPresented = true })
    }
}

private struct OwnPaywallHost: ViewModifier {
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content.modifier(PaywallHost(isPresented: $isPresented))
    }
}

extension View {
    /// Lets anything inside call `showPaywall()`; `isPresented` is for a caller that also opens it.
    func hostsPaywall(isPresented: Binding<Bool>) -> some View {
        modifier(PaywallHost(isPresented: isPresented))
    }

    /// For a sheet's root view, so the paywall opens above it.
    func hostsPaywall() -> some View {
        modifier(OwnPaywallHost())
    }
}

struct ShowPaywallAction {
    let action: () -> Void
    func callAsFunction() { action() }
}

struct ShowFiltersAction {
    let action: () -> Void
    func callAsFunction() { action() }
}

/// Switches to the Mistakes tab, or opens its preview while it is locked.
struct OpenMistakesAction {
    let action: (String?) -> Void
    /// Opens Mistakes; with `gameKey`, narrowed to that game.
    func callAsFunction(gameKey: String? = nil) { action(gameKey) }
}

private struct OpenMistakesKey: EnvironmentKey {
    static let defaultValue = OpenMistakesAction { _ in }
}

private struct ShowPaywallKey: EnvironmentKey {
    static let defaultValue = ShowPaywallAction {}
}

private struct ShowFiltersKey: EnvironmentKey {
    static let defaultValue = ShowFiltersAction {}
}

extension EnvironmentValues {
    var showPaywall: ShowPaywallAction {
        get { self[ShowPaywallKey.self] }
        set { self[ShowPaywallKey.self] = newValue }
    }
    var showFilters: ShowFiltersAction {
        get { self[ShowFiltersKey.self] }
        set { self[ShowFiltersKey.self] = newValue }
    }
    var openMistakes: OpenMistakesAction {
        get { self[OpenMistakesKey.self] }
        set { self[OpenMistakesKey.self] = newValue }
    }
}

/// Status line shown at the top of each root tab. Silent when there is nothing to say: who and
/// what is being shown lives in the toolbar and the screen's own controls.
struct PlayerContextHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isRefreshing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.selectedPlayer.map { "Checking \($0.provider.displayName) for new games" } ?? "Checking for new games")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            if let error = model.refreshError {
                InfoBanner(title: error.errorDescription ?? "Refresh failed",
                           message: error.recoverySuggestion,
                           tone: error == .offline ? .warning : .error,
                           actionTitle: "Try again") {
                    Task { await model.refreshSelectedPlayer() }
                }
            }
        }
    }
}

/// Development only: `-scroll-anchor center|bottom` opens every scroll view part-way down, so a
/// long screen can be inspected in full from launch.
struct DebugScrollAnchor: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-scroll-anchor"), index + 1 < arguments.count {
            let anchor: UnitPoint = arguments[index + 1] == "bottom" ? .bottom : .center
            if #available(iOS 18.0, *) {
                // Also after content arrives, for screens that load once they appear.
                content.defaultScrollAnchor(anchor).defaultScrollAnchor(anchor, for: .sizeChanges)
            } else {
                content.defaultScrollAnchor(anchor)
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
