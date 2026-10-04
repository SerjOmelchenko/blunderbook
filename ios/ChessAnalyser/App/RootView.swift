//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
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
    case mistakeCategory(MistakeCategory)
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
    @State private var paths: [RootTab: [Route]] = [:]
    /// Development only: a screen opened straight from launch to inspect it.
    @State private var debugScreen: DebugScreen?

    var body: some View {
        @Bindable var model = model

        Group {
            if model.trackedPlayers.isEmpty {
                WelcomeScreen()
            } else {
                TabView(selection: $model.selectedTab) {
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
                        .tabItem { Label(tab.title, systemImage: tab.symbol) }
                        .tag(tab)
                    }
                }
                .modifier(QueueAccessoryModifier(hasWork: hasQueuedWork) { openQueue() })
                .onChange(of: model.selectedTab) { _, _ in model.persistSelection() }
            }
        }
        .task { applyDevelopmentRoute() }
        .sheet(isPresented: $showsPlayers) { PlayersSheet() }
        .sheet(isPresented: $showsSettings) { SettingsSheet() }
        .sheet(isPresented: $showsFilters) { FiltersSheet() }
        .sheet(isPresented: $showsPaywall) { PaywallScreen() }
        .sheet(item: $debugScreen) { screen in debugView(screen) }
        .environment(\.showPaywall, ShowPaywallAction { showsPaywall = true })
        .environment(\.showFilters, ShowFiltersAction { showsFilters = true })
    }

    private var hasQueuedWork: Bool {
        model.coordinator.counts.pending + model.coordinator.counts.running > 0
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
        switch DevelopmentSeed.startupSheet {
        case "settings": showsSettings = true
        case "players": showsPlayers = true
        case "paywall": showsPaywall = true
        case "filters": showsFilters = true
        case let name?: debugScreen = DebugScreen(rawValue: name)
        default: break
        }
        #endif
    }

    /// Screens that normally sit several taps deep, opened directly for inspection.
    enum DebugScreen: String, Identifiable {
        case addPlayer = "add-player", importing, subscription, backup, storage, relink, licence
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
        }
    }

    @ViewBuilder
    private func content(for tab: RootTab) -> some View {
        switch tab {
        case .analytics: AnalyticsScreen()
        case .games: GamesScreen()
        case .mistakes: MistakesScreen()
        }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .gameReview(let key, let ply): GameReviewScreen(gameKey: key, initialPly: ply)
        case .mistakeCategory(let category): MistakeCategoryScreen(category: category)
        case .queue: QueueScreen()
        case .howAnalysisWorks: HowAnalysisWorksScreen()
        case .about: AboutScreen()
        }
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
            .accessibilityLabel("Tracked players. Currently \(model.selectedPlayer?.displayUsername ?? "none")")
        }
        if tab != .analytics {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showsFilters = true
                } label: {
                    Image(systemName: model.filters.activeCount > 0
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

struct ShowPaywallAction {
    let action: () -> Void
    func callAsFunction() { action() }
}

struct ShowFiltersAction {
    let action: () -> Void
    func callAsFunction() { action() }
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
                    Text("Checking Chess.com for new games")
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
