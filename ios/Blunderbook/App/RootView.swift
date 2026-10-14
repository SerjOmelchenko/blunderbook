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
    /// A game as it is: opening it never starts an analysis.
    case gameReview(gameKey: String, ply: Int?)
    case mistakeDrill(MistakeOccurrence)
    /// Several mistakes drilled one after another, then the session's result.
    case training([MistakeOccurrence])
    case explore(ExploreStart)
    case queue
    case howAnalysisWorks
    case about

    /// The name usage events give this screen. Never the game or mistake it shows.
    var screenName: String {
        switch self {
        case .gameReview: return "Game review"
        case .mistakeDrill: return "Mistake drill"
        case .training: return "Training"
        case .explore: return "Explore"
        case .queue: return "Queue"
        case .howAnalysisWorks: return "How analysis works"
        case .about: return "About"
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsPlayers = false
    @State private var showsSettings = false
    @State private var showsFilters = false
    @State private var showsPaywall = false
    @State private var showsMistakesPreview = false
    /// The free-trial offer, once leaving a game has made it due, and once it is up.
    @State private var dueTrialOffer: TrialOffer?
    @State private var trialOffer: TrialOffer?
    @State private var paths: [RootTab: [Route]] = [:]
    /// The game's scale behind the hole in the list while you fly through a row's rings
    /// (`RevealPortal`); 1 the rest of the time.
    @State private var revealScale: CGFloat = 1
    @State private var rootFrame: CGRect = .zero
    /// Development only: a screen opened straight from launch to inspect it.
    @State private var debugScreen: DebugScreen?

    var body: some View {
        @Bindable var model = model

        Group {
            if model.trackedPlayers.isEmpty || model.isOnboarding {
                WelcomeScreen()
                    .tracksScreen("Welcome")
            } else {
                TabView(selection: tabSelection) {
                    ForEach(RootTab.allCases) { tab in
                        NavigationStack(path: binding(for: tab)) {
                            content(for: tab)
                                .tracksScreen(tab.title)
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
                .scaleEffect(revealScale, anchor: revealAnchor)
                .modifier(QueueAccessoryModifier(isShowing: isAnalysisBarShowing || isBarHeldForReveal))
                .onChange(of: isReviewingGame, initial: true) { _, onScreen in model.isGameOnScreen = onScreen }
                .onChange(of: model.coordinator.counts) { _, _ in model.revealIfLanded() }
                .onChange(of: model.selectedTab) { _, _ in model.persistSelection() }
                .onChange(of: paths[.games]?.isEmpty ?? true, initial: true) { _, isEmpty in
                    model.isGamesListShowing = isEmpty
                }
                .onChange(of: paths) { old, new in checkForTrialOffer(old: old, new: new) }
                .onChange(of: model.pendingRoute) { _, route in
                    guard let route else { return }
                    model.pendingRoute = nil
                    paths[model.selectedTab, default: []].append(route)
                }
                // A subscription that lapsed while Mistakes was open leaves it.
                .onChange(of: model.isMistakesLocked, initial: true) { _, isLocked in
                    if isLocked, model.selectedTab == .mistakes { model.selectedTab = .analytics }
                }
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rootFrame = $0 }
        .overlay { FirstRunTipsOverlay() }
        .task(id: tipsWatchKey) { await watchForTips() }
        .task(id: dueTrialOffer?.id) { await presentTrialOfferWhenClear() }
        // A Games tip only makes sense over the Games list: if the list goes, so does the tip.
        .onChange(of: isGamesListInView) { _, inView in
            if !inView { model.tips.withdrawGamesMoment() }
        }
        .overlay {
            if let reveal = model.reveal {
                RevealPortal(reveal: reveal) {
                    openRevealedGame(reveal)
                } onFlight: {
                    withAnimation(.timingCurve(0.33, 1, 0.68, 1, duration: RevealPortal.flight)) { revealScale = 1 }
                } onFinished: {
                    revealScale = 1
                    model.reveal = nil
                }
            }
        }
        .background(TouchActivityMonitor { model.lastTouchAt = Date() })
        .task { applyDevelopmentRoute() }
        .sheet(isPresented: $showsPlayers) { PlayersSheet().hostsPaywall().tracksScreen("Players") }
        .sheet(isPresented: $showsSettings) { SettingsSheet().hostsPaywall().tracksScreen("Settings") }
        .sheet(isPresented: $showsFilters) {
            FiltersSheet(showsDates: model.selectedTab != .games).tracksScreen("Filters")
        }
        .sheet(isPresented: $showsMistakesPreview) { MistakesPreviewSheet().hostsPaywall().tracksScreen("Mistakes preview") }
        .sheet(item: $trialOffer) { offer in TrialOfferSheet(offer: offer).tracksScreen("Trial offer") }
        .sheet(item: $debugScreen) { screen in debugView(screen) }
        .hostsPaywall(isPresented: $showsPaywall)
        .environment(\.showFilters, ShowFiltersAction { showsFilters = true })
        .environment(\.openMistakes, OpenMistakesAction { openMistakes(gameKey: $0, kind: $1) })
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

    /// With `gameKey`, Mistakes opens at its list narrowed to that game; with `kind`, at every
    /// game's errors of that kind.
    private func openMistakes(gameKey: String? = nil, kind: MistakeCategory? = nil) {
        if model.isMistakesLocked { showsMistakesPreview = true; return }
        if let gameKey {
            model.mistakesGameKey = gameKey
            paths[.mistakes] = []
        }
        if let kind {
            model.mistakesGameKey = nil
            model.mistakesKind = kind
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
        case .gameReview, .mistakeDrill, .training, .explore: return true
        default: return false
        }
    }

    /// Under the photo of the screen, so the push has no slide of its own. The game opens on the
    /// tab that was showing and waits small behind the hole until the flight scales it up.
    private func openRevealedGame(_ reveal: AppModel.Reveal) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.reveal?.isCovered = true
            paths[reveal.tab, default: []].append(.gameReview(gameKey: reveal.gameKey, ply: nil))
            if !reduceMotion { revealScale = RevealPortal.gameStartScale }
        }
    }

    // MARK: First-run tips

    private var isPresentingSheet: Bool {
        showsPlayers || showsSettings || showsFilters || showsMistakesPreview || showsPaywall || trialOffer != nil
            || debugScreen != nil
    }

    /// Games is the tab on screen, showing its list with nothing over it.
    private var isGamesListInView: Bool {
        model.selectedTab == .games && (paths[.games]?.isEmpty ?? true) && !isPresentingSheet && model.reveal == nil
    }

    private var tipsWatchKey: String {
        "\(isGamesListInView)|\(model.tips.showing?.rawValue ?? "")"
    }

    /// Starts a Games tip once its row sits in full view and nothing else is going on: no
    /// sheet, no flight into a game, and no finger on the screen for a moment.
    private func watchForTips() async {
        guard isGamesListInView, model.tips.showing == nil, model.tips.isWatchingGames else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(0.5))
            guard isGamesListInView,
                  Date().timeIntervalSince(model.lastTouchAt) >= 0.8,
                  UIApplication.shared.applicationState == .active,
                  !AppModel.isPresentingSheet,
                  let area = visibleListArea else { continue }
            if model.tips.startIfReady(in: area, greyRingsTappable: model.canAnalyse && !model.isAnalysingAGame) { return }
        }
    }

    // MARK: Free-trial offer

    /// Coming back from a game to a tab's first screen may make the free-trial offer due
    /// (`AppModel.trialOffer(afterLeaving:)` decides).
    private func checkForTrialOffer(old: [RootTab: [Route]], new: [RootTab: [Route]]) {
        guard dueTrialOffer == nil, trialOffer == nil else { return }
        for (tab, path) in old where !path.isEmpty && (new[tab] ?? []).isEmpty {
            let gameKey = path.reversed().lazy.compactMap { route -> String? in
                if case .gameReview(let key, _) = route { return key }
                return nil
            }.first
            guard let gameKey else { continue }
            Task { dueTrialOffer = await model.trialOffer(afterLeaving: gameKey) }
            return
        }
    }

    /// Brings the due offer up once nothing else is going on: no game, sheet, flight or tip on
    /// screen, and no finger on it for a moment. On Games, the tip on the analysed row goes
    /// first, so it gets a few seconds to start. Apple is asked about the trial last; without
    /// it the offer is dropped until the next game.
    private func presentTrialOfferWhenClear() async {
        var clearSince: Date?
        while !Task.isCancelled, let offer = dueTrialOffer {
            try? await Task.sleep(for: .seconds(0.5))
            let isClear = (paths[model.selectedTab]?.isEmpty ?? true) && !isPresentingSheet
                && !AppModel.isPresentingSheet && model.reveal == nil && model.tips.showing == nil
                && Date().timeIntervalSince(model.lastTouchAt) >= 0.8
                && UIApplication.shared.applicationState == .active
            guard isClear else { clearSince = nil; continue }
            let since = clearSince ?? Date()
            clearSince = since
            if model.selectedTab == .games, !model.tips.hasSeen(.gamesFirstAnalysed),
               Date().timeIntervalSince(since) < 3 { continue }
            guard await model.trialIsOnOffer() else { dueTrialOffer = nil; return }
            model.markTrialOfferShown()
            trialOffer = offer
            dueTrialOffer = nil
            return
        }
    }

    /// The part of the screen between the navigation bar and the tab bar (and the analysis bar
    /// above it), in global coordinates.
    private var visibleListArea: CGRect? {
        guard let window = AppModel.keyWindow else { return nil }
        let insets = window.safeAreaInsets
        let top = insets.top + 52
        let bottom = insets.bottom + 60 + (isAnalysisBarShowing ? 60 : 0)
        return CGRect(x: 0, y: top, width: window.bounds.width, height: window.bounds.height - top - bottom)
    }

    /// The bottom bar shows while a game waits or is analysed, except over a game.
    private var isAnalysisBarShowing: Bool { hasQueuedWork && !isReviewingGame }

    /// The flight leaves from the bar's rings: the bar stays up, full, until the photo of the
    /// screen covers it, and goes before the game shows through.
    private var isBarHeldForReveal: Bool {
        guard let reveal = model.reveal else { return false }
        return reveal.fromBar && !reveal.isCovered
    }

    /// The rings being flown through, as a point in the root view.
    private var revealAnchor: UnitPoint {
        guard let origin = model.reveal?.origin, rootFrame.width > 0, rootFrame.height > 0 else { return .center }
        return UnitPoint(x: (origin.x - rootFrame.minX) / rootFrame.width, y: (origin.y - rootFrame.minY) / rootFrame.height)
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
        if DevelopmentSeed.resetsTrialOffer { model.preferences.set(PreferenceKey.trialOfferShown, nil) }
        if let tab = DevelopmentSeed.startupTab { model.selectedTab = tab }
        if let route = DevelopmentSeed.startupRoute { paths[model.selectedTab] = [route] }
        if DevelopmentSeed.leavesGame {
            Task {
                try? await Task.sleep(for: .seconds(3))
                paths[model.selectedTab] = []
            }
        }
        if DevelopmentSeed.opensExplore, case .gameReview(let key, let ply)? = DevelopmentSeed.startupRoute {
            let review = GameReviewModel()
            review.load(app: model, gameKey: key, initialPly: ply)
            if let start = review.exploreStart { paths[model.selectedTab, default: []].append(.explore(start)) }
        }
        if let key = DevelopmentSeed.queuedGame {
            Task {
                try? await Task.sleep(for: .seconds(3))
                model.analyseThenOpen(gameKey: key)
                if DevelopmentSeed.tipPreview?.moment == FirstRunTips.Moment.analysisNote.rawValue {
                    model.tips.showAnalysisNoteIfFirst()
                }
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

    private func destination(_ route: Route) -> some View {
        routeView(route).tracksScreen(route.screenName)
    }

    @ViewBuilder
    private func routeView(_ route: Route) -> some View {
        switch route {
        case .gameReview(let key, let ply): GameReviewScreen(gameKey: key, initialPly: ply)
        case .mistakeDrill(let occurrence): MistakeDrillScreen(occurrence: occurrence)
        case .training(let queue): MistakeDrillScreen(queue: queue)
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

/// Shows the analysis above the tab bar while a game waits or is analysed, the way iOS 26 shows
/// an ongoing activity. Older systems reach the queue from a toolbar button instead.
struct QueueAccessoryModifier: ViewModifier {
    let isShowing: Bool

    static var isAvailable: Bool {
        if #available(iOS 26.1, *) { return true }
        return false
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content
                .tabViewBottomAccessory(isEnabled: isShowing) {
                    QueueAccessory()
                }
        } else {
            content
        }
    }
}

/// The game being analysed, as a bar that fills with amber from 0 to 100 %: the three spinning
/// rings of the Games rows, then "Analysing" and about how long is left. Not a control: it
/// opens nothing. If the analysed game's row is off screen when the analysis lands, you fly
/// through these rings into the game instead (`AppModel.revealIfLanded`).
struct QueueAccessory: View {
    /// False for the copy at the foot of the first-analysis note, which sits over the real bar.
    var reportsFrames = true

    @Environment(AppModel.self) private var model

    private var coordinator: AnalysisCoordinator { model.coordinator }
    private var isRevealing: Bool { model.reveal?.fromBar == true }
    /// The analysis is done: the flight leaves from here, or the note's copy outlived the bar.
    private var hasLanded: Bool { isRevealing || (!reportsFrames && !model.isAnalysingAGame) }
    /// Full once the analysis has landed.
    private var fraction: Double { hasLanded ? 1 : coordinator.currentFraction }

    private var title: String {
        if hasLanded { return "Analysed" }
        if coordinator.isPausedByUser { return "Paused" }
        if let blocker = coordinator.primaryBlocker { return blocker.title }
        if coordinator.currentGameKey == nil { return "Waiting" }
        return coordinator.isPacing ? "Analysing, cooling" : "Analysing"
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = timeLeft(at: context.date)
            HStack(spacing: 12) {
                AccuracyRings(phase: .busy)
                    .scaleEffect(Self.ringScale)
                    .frame(width: 40 * Self.ringScale, height: 40 * Self.ringScale)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        if reportsFrames { model.barRingsFrame = $0 }
                    }
                    // The flight carries these rings away; the bar's own copy steps aside.
                    .opacity(hasLanded ? 0 : 1)
                (Text(title).fontWeight(.semibold)
                    + Text(left.map { "  \($0)" } ?? "").foregroundStyle(Palette.inkSecondary))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.subheadline)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                if reportsFrames { model.barFrame = $0 }
            }
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    Palette.brand.opacity(0.32)
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                        .animation(.easeOut(duration: 0.4), value: fraction)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, left, "\(Int((fraction * 100).rounded())) percent"].compactMap { $0 }.joined(separator: ", "))
        }
    }

    /// The rings at the size the bar shows them; the flight starts from this size too.
    static let ringScale: CGFloat = 0.65

    /// About how long the game has left, from how fast it has gone so far. Nothing until there is
    /// enough to go on, or while it is paused or held back.
    private func timeLeft(at date: Date) -> String? {
        guard !hasLanded, !coordinator.isPausedByUser, coordinator.primaryBlocker == nil,
              let key = coordinator.currentGameKey,
              let started = coordinator.activeGames[key]?.startedAt else { return nil }
        let done = coordinator.currentFraction
        let elapsed = date.timeIntervalSince(started)
        guard done >= 0.04, elapsed >= 1 else { return "estimating time left" }
        let seconds = elapsed * (1 - done) / done
        if seconds < 5 { return "a few seconds left" }
        if seconds < 60 { return "about \(Int((seconds / 5).rounded()) * 5) s left" }
        return "about \(Int((seconds / 60).rounded())) min left"
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
            .sheet(isPresented: $isPresented) { PaywallScreen().tracksScreen("Paywall") }
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
    /// Reports a usage event each time this screen comes into view.
    func tracksScreen(_ name: String) -> some View {
        onAppear { UsageAnalytics.shared.track(.screen(name)) }
    }

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
    let action: (String?, MistakeCategory?) -> Void
    /// Opens Mistakes; with `gameKey`, narrowed to that game; with `kind`, to that kind of mistake.
    func callAsFunction(gameKey: String? = nil, kind: MistakeCategory? = nil) { action(gameKey, kind) }
}

private struct OpenMistakesKey: EnvironmentKey {
    static let defaultValue = OpenMistakesAction { _, _ in }
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
