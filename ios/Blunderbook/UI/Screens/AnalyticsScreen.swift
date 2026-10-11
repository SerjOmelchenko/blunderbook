//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI
import Charts

struct AnalyticsSnapshot {
    var coverage = AnalyticsCoverage()
    var outcomes = OutcomeCounts()
    var rating: [RatingPoint] = []
    var bestRating: Int?
    var totalDownloaded = 0
    /// The newest game of the time class, for "Analyse latest game".
    var latestGame: GameListEntry?
    /// Today's games of the time class, and those still without an in-depth analysis.
    var todayGames = 0
    var todayToAnalyse: [String] = []
}

@MainActor
@Observable
final class AnalyticsModel {
    private(set) var snapshot = AnalyticsSnapshot()
    private(set) var isLoading = false
    private var token = 0

    func load(_ app: AppModel) async {
        guard let player = app.selectedPlayer else { snapshot = AnalyticsSnapshot(); return }
        token += 1
        let current = token
        isLoading = true
        let statistics = app.statistics
        let games = app.games
        let filters = app.filters
        let scope = app.scope
        let analyses = app.analyses

        let result = await Task.detached(priority: .userInitiated) { () -> AnalyticsSnapshot in
            var snapshot = AnalyticsSnapshot()
            snapshot.coverage = (try? statistics.coverage(playerID: player.id, filters: filters, scope: scope)) ?? AnalyticsCoverage()
            snapshot.outcomes = (try? statistics.outcomes(playerID: player.id, filters: filters, scope: scope)) ?? OutcomeCounts()
            snapshot.rating = (try? statistics.ratingSeries(playerID: player.id, filters: filters, scope: scope)) ?? []
            snapshot.bestRating = (try? statistics.bestRating(playerID: player.id, filters: filters, scope: scope)) ?? nil
            snapshot.totalDownloaded = (try? games.totalGameCount(playerID: player.id)) ?? 0

            var latestFilters = GameFilters.default
            latestFilters.timeClass = filters.timeClass
            latestFilters.dateRange = .allTime
            snapshot.latestGame = ((try? games.page(playerID: player.id, filters: latestFilters,
                                                     scope: .allDownloaded, limit: 1)) ?? []).first
            let today = (try? games.eligibleKeys(playerID: player.id, scope: .allDownloaded,
                                                 timeClass: filters.timeClass,
                                                 since: Calendar.current.startOfDay(for: Date()))) ?? []
            snapshot.todayGames = today.count
            snapshot.todayToAnalyse = (try? analyses.withoutDeepReview(today)) ?? []
            return snapshot
        }.value

        guard current == token else { return }
        snapshot = result
        isLoading = false
    }
}

// MARK: - W05 Analytics

struct AnalyticsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.showPaywall) private var showPaywall
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var analytics = AnalyticsModel()
    @State private var showsRatingData = false
    /// Where a finger is on the rating chart, while it is there.
    @State private var selectedRatingDate: Date?
    @State private var showsBulkPreparation = false
    /// How many of today's games were just queued, to say so on the button.
    @State private var queuedToday: Int?

    private var snapshot: AnalyticsSnapshot { analytics.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero

                VStack(alignment: .leading, spacing: 22) {
                    PlayerContextHeader()
                    headlineFigures

                    // Everything in here is derived from on-device analysis, which only covers
                    // what has actually been analysed.
                    DerivedDataGroup {
                        ProvenanceHeader(kicker: "On-device analysis",
                                         title: "Analysis",
                                         symbol: "cpu",
                                         tone: Palette.brand)
                        quickAnalysis
                        coverageSection
                    }
                }
                .padding(.horizontal, Layout.contentInset)
            }
            .padding(.bottom, 40)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Time class", selection: Binding(
                    get: { model.filters.timeClass },
                    set: { var filters = model.filters; filters.timeClass = $0; model.updateFilters(filters) }
                )) {
                    ForEach(model.timeClasses) { Text($0.pickerLabel).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
        }
        .refreshable { await model.refreshSelectedPlayer() }
        .task(id: taskKey) {
            await analytics.load(model)
            #if DEBUG
            // `-select-rating-day`: show the chart's day callout without a finger on it.
            if ProcessInfo.processInfo.arguments.contains("-select-rating-day"), snapshot.rating.count > 2 {
                selectedRatingDate = snapshot.rating[snapshot.rating.count * 2 / 3].date
            }
            #endif
        }
        .sheet(isPresented: $showsRatingData) {
            RatingDataSheet(points: snapshot.rating, timeClass: model.filters.timeClass)
        }
        .sheet(isPresented: $showsBulkPreparation) { BulkPreparationSheet().hostsPaywall() }
        .task {
            #if DEBUG
            if DevelopmentSeed.opensBulkPreparation { showsBulkPreparation = true }
            #endif
        }
    }

    private var taskKey: String {
        "\(model.selectedPlayer?.id.uuidString ?? "")|\(model.filters)|\(model.scope.rawValue)|\(model.dataVersion)"
    }

    // MARK: Hero

    /// One figure the screen leads with, over the chart that explains it.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                dateRangeMenu
                // Ratings are identifiers, not quantities: never grouped ("1.462").
                Text(verbatim: snapshot.rating.last.map { String($0.rating) } ?? "—")
                    .font(.hero)
                    .foregroundStyle(Palette.ink)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .accessibilityLabel("Current \(model.filters.timeClass.label) rating \(snapshot.rating.last.map { "\($0.rating)" } ?? "unknown")")
                if let delta = ratingDelta {
                    Text(verbatim: "\(delta >= 0 ? "+" : "−")\(abs(delta)) · best \(snapshot.bestRating.map(String.init) ?? "—")")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(delta >= 0 ? Palette.brand : Palette.inkSecondary)
                        .monospacedDigit()
                } else {
                    Text(snapshot.rating.isEmpty
                         ? "No rated \(model.filters.timeClass.label.lowercased()) games in this view"
                         : "Only one rated game in this view")
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .padding(.horizontal, Layout.contentInset)
            .padding(.top, 12)

            if snapshot.rating.count > 1 {
                ratingChart
                    .padding(.top, 8)
            } else {
                Spacer().frame(height: 24)
            }

            // The results of the games in view, straight from the downloaded games. The bar runs
            // edge to edge like the chart above it; its text keeps the content inset.
            outcomeSection
                .padding(.top, 14)
                .padding(.bottom, 6)
        }
    }

    private var dateRangeMenu: some View {
        Menu {
            Picker("Dates", selection: Binding(
                get: { model.filters.dateRange },
                set: { var filters = model.filters; filters.dateRange = $0; model.updateFilters(filters) }
            )) {
                ForEach(DateRange.displayOrder) { Text($0.longLabel).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text("\(model.filters.timeClass.label) · \(model.filters.dateRange.longLabel.lowercased())")
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .font(.subheadline)
            .foregroundStyle(Palette.inkSecondary)
            .frame(minHeight: Layout.minimumTarget)
        }
        .accessibilityLabel("Date range, \(model.filters.dateRange.longLabel)")
    }

    private var ratingDelta: Int? {
        guard snapshot.rating.count > 1, let first = snapshot.rating.first, let last = snapshot.rating.last else { return nil }
        return last.rating - first.rating
    }

    /// Edge to edge, no axes: the figures above carry the numbers, the chart carries the shape.
    /// Touching and dragging along it shows each day's rating where the finger is.
    private var ratingChart: some View {
        let domain = ratingDomain
        let day = selectedRatingDate.flatMap { RatingDay.at($0, in: snapshot.rating) }
        return Chart {
            ForEach(snapshot.rating) { point in
                AreaMark(x: .value("Date", point.date),
                         yStart: .value("Floor", domain.lowerBound),
                         yEnd: .value("Rating", Double(point.rating)))
                    .foregroundStyle(Palette.brand.opacity(0.16))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Date", point.date), y: .value("Rating", Double(point.rating)))
                    .foregroundStyle(Palette.brand)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let day {
                RuleMark(x: .value("Selected", day.lastGame))
                    .foregroundStyle(Palette.ink.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        RatingDayCallout(day: day)
                    }
                PointMark(x: .value("Selected", day.lastGame), y: .value("Rating", Double(day.rating)))
                    .foregroundStyle(Palette.brand)
                    .symbolSize(70)
            }
        }
        .chartYScale(domain: domain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartPlotStyle { $0.padding(.zero) }
        .chartXSelection(value: $selectedRatingDate)
        .frame(height: 190)
        .sensoryFeedback(.selection, trigger: day?.start)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating chart")
        .accessibilityValue(ratingSummary)
        .accessibilityAction(named: "Show data") { showsRatingData = true }
    }

    /// Ratings sit in a narrow band, so the axis is fitted to the data with a little headroom
    /// rather than anchored at zero.
    private var ratingDomain: ClosedRange<Double> {
        let values = snapshot.rating.map { Double($0.rating) }
        guard let low = values.min(), let high = values.max() else { return 0...100 }
        let padding = max(20, (high - low) * 0.25)
        return (low - padding)...(high + padding)
    }

    private var ratingSummary: String {
        guard let first = snapshot.rating.first, let last = snapshot.rating.last else {
            return "No rated games"
        }
        return "From \(first.rating) on \(Format.date(first.date)) to \(last.rating) on \(Format.date(last.date)), across \(snapshot.rating.count) rated games."
    }

    // MARK: Figures

    /// The record and the engine's verdict in one place. Engine figures show a dash, never a
    /// zero, until something in the view has been analysed (§6).
    private var headlineFigures: some View {
        let figures: [(label: String, value: String)] = [
            ("Win rate", snapshot.outcomes.decided > 0
                ? Format.percent(snapshot.outcomes.percentage(snapshot.outcomes.win)) : "—"),
            ("Games", snapshot.outcomes.total.formatted()),
            ("Analysed", snapshot.coverage.analysedGames.formatted()),
        ]
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .topLeading),
                            count: dynamicTypeSize.isAccessibilitySize ? 1 : 3)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(figures, id: \.label) { figure in
                StatTile(label: figure.label, value: figure.value)
            }
        }
        .padding(.top, 8)
    }

    // MARK: Record

    @ViewBuilder
    private var outcomeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.outcomes.total > 0 {
                outcomeBar
            } else {
                Text("No games match the current filters.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, Layout.contentInset)
            }
            if snapshot.outcomes.unknown > 0 {
                Text("\(snapshot.outcomes.unknown) games have an unrecognised result. They count in the total but not the percentages.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Layout.contentInset)
            }
        }
    }

    private var outcomeBar: some View {
        let counts = snapshot.outcomes
        let parts = [(counts.win, Palette.win), (counts.draw, Palette.draw),
                     (counts.loss, Palette.loss), (counts.unknown, Palette.inkTertiary.opacity(0.5))]
            .filter { $0.0 > 0 }
        let gap: CGFloat = 2
        return VStack(alignment: .leading, spacing: 10) {
            GeometryReader { proxy in
                // Only the segments that exist get a gap, so together they fill the width exactly.
                let available = proxy.size.width - gap * CGFloat(max(0, parts.count - 1))
                HStack(spacing: gap) {
                    ForEach(parts.indices, id: \.self) { index in
                        segment(width: available, count: parts[index].0, tone: parts[index].1)
                    }
                }
            }
            .frame(height: 6)

            HStack(spacing: 16) {
                legend("Won", counts.win, Palette.win)
                legend("Drawn", counts.draw, Palette.draw)
                legend("Lost", counts.loss, Palette.loss)
                if counts.unknown > 0 { legend("Unknown", counts.unknown, Palette.inkTertiary) }
            }
            .padding(.horizontal, Layout.contentInset)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Results: \(counts.win) won, \(counts.draw) drawn, \(counts.loss) lost, \(counts.unknown) unknown. Percentages use the \(counts.decided) games with a known result.")
    }

    private func segment(width: CGFloat, count: Int, tone: Color) -> some View {
        let total = max(1, snapshot.outcomes.total)
        return Rectangle()
            .fill(tone)
            .frame(width: max(count > 0 ? 3 : 0, width * CGFloat(count) / CGFloat(total)))
    }

    private func legend(_ title: String, _ count: Int, _ tone: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tone).frame(width: 7, height: 7)
            Text("\(title) \(count)")
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .monospacedDigit()
        }
    }

    // MARK: Analysis

    /// The quick ways in, one row each: the game just played, everything played today, and the
    /// previous hundred games.
    @ViewBuilder
    private var quickAnalysis: some View {
        VStack(spacing: 10) {
            if let latest = snapshot.latestGame {
                NavigationLink(value: Route.gameReview(gameKey: latest.game.gameKey, ply: nil)) {
                    analyseRow(symbol: "bolt.fill", title: "Analyse latest game") {
                        HStack(spacing: 4) {
                            Text(latest.outcome.label)
                                .foregroundStyle(latest.outcome.color)
                                .fontWeight(.semibold)
                            Text("vs \(latest.opponent.username) · \(Format.relative(latest.game.endTime))")
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } trailing: {
                        if latest.hasDeepReview, let accuracy = latest.accuracy {
                            AccuracyRing(value: accuracy)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the game and analyses it in depth")
            }
            todayRow
            previousHundredRow
        }
    }

    /// Queues an in-depth analysis of every game of the time class played today that has none.
    private var todayRow: some View {
        let toAnalyse = snapshot.todayToAnalyse
        let timeClass = model.filters.timeClass.label.lowercased()
        let detail: String
        if let queuedToday {
            detail = "Analysing \(queuedToday) game\(queuedToday == 1 ? "" : "s")"
        } else if snapshot.todayGames == 0 {
            detail = "No \(timeClass) games today"
        } else if toAnalyse.isEmpty {
            detail = "All \(snapshot.todayGames) analysed"
        } else {
            detail = "\(toAnalyse.count) of \(snapshot.todayGames) to analyse"
        }
        return Button {
            if model.requestReviews(gameKeys: toAnalyse) == nil {
                withAnimation(.smooth(duration: 0.3)) { queuedToday = toAnalyse.count }
            }
        } label: {
            analyseRow(symbol: "sun.max.fill", title: "Analyse all today's games") {
                Text(detail).contentTransition(.opacity)
            } trailing: {
                if queuedToday != nil || (snapshot.todayGames > 0 && toAnalyse.isEmpty) {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.improved)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(queuedToday != nil || toAnalyse.isEmpty || !model.canAnalyse)
        .onChange(of: snapshot.todayToAnalyse) { _, _ in queuedToday = nil }
    }

    /// Bulk takes the most recent games without an in-depth review of the time class being viewed, across the
    /// player's whole window rather than just the date range; the preparation sheet it opens
    /// spells out what will be queued. Premium, so locked rows say so.
    private var previousHundredRow: some View {
        let plan = model.bulkPlan()
        let timeClass = model.filters.timeClass.label.lowercased()
        return Button {
            showsBulkPreparation = true
        } label: {
            analyseRow(symbol: "square.stack.3d.up.fill", title: "Analyse previous \(AppModel.bulkBatchSize) games") {
                Text(plan.eligible.isEmpty
                     ? "Every \(timeClass) game has an in-depth review"
                     : "\(plan.eligible.count) \(timeClass) game\(plan.eligible.count == 1 ? "" : "s") to review in depth")
            } trailing: {
                if !model.canAnalyseInBulk {
                    Label("Premium", systemImage: "lock.fill")
                        .labelStyle(.iconOnly)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Palette.brass)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(plan.eligible.isEmpty || !model.canAnalyse)
    }

    /// One row of the quick analysis list: an icon, what it does, and a line of detail.
    private func analyseRow<Detail: View, Trailing: View>(symbol: String,
                                                          title: String,
                                                          @ViewBuilder detail: () -> Detail,
                                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        AnalyseRow(symbol: symbol, title: title, detail: detail(), trailing: trailing())
    }

    private var coverageSection: some View {
        let coverage = snapshot.coverage
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Coverage")
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Spacer()
                Text(Format.percent(coverage.fraction * 100, decimals: 1))
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                    .monospacedDigit()
            }
            CoverageBar(fraction: coverage.fraction)
            Text(coverage.summary)
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)

            if coverage.failedGames > 0 || coverage.incompleteGames > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    if coverage.incompleteGames > 0 {
                        Text("\(coverage.incompleteGames) in progress")
                    }
                    if coverage.failedGames > 0 {
                        Text("\(coverage.failedGames) failed")
                    }
                }
                .font(.caption)
                .foregroundStyle(Palette.inkTertiary)
            }

            if !coverage.hasAnalysis {
                Text("Nothing analysed in this view yet.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }
}

// MARK: - Rating by day

/// One point of the rating chart — a day, or a week over long ranges — as shown while a finger is
/// on the chart.
struct RatingDay: Equatable {
    var start: Date
    var period: RatingPeriod
    /// When the period's last rated game finished; the chart marks this point.
    var lastGame: Date
    /// Rating after the period's last game.
    var rating: Int
    /// Change from the previous point. Nil for the first point shown, which has nothing earlier
    /// in view to compare with.
    var change: Int?
    var games: Int

    /// The chart point nearest to `date`.
    static func at(_ date: Date, in points: [RatingPoint], calendar: Calendar = .current) -> RatingDay? {
        guard let index = points.indices.min(by: {
            abs(points[$0].date.timeIntervalSince(date)) < abs(points[$1].date.timeIntervalSince(date))
        }) else { return nil }
        let point = points[index]
        let previous = index > 0 ? points[index - 1] : nil
        return RatingDay(start: RatingSeries.start(of: point.date, period: point.period, calendar: calendar),
                         period: point.period,
                         lastGame: point.date,
                         rating: point.rating,
                         change: previous.map { point.rating - $0.rating },
                         games: point.games)
    }
}

/// The glass label that follows a finger along the rating chart.
private struct RatingDayCallout: View {
    let day: RatingDay

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Group {
                if day.period == .week {
                    Text("Week of \(day.start.formatted(.dateTime.day().month(.abbreviated).year()))")
                } else {
                    Text(day.start, format: .dateTime.day().month(.abbreviated).year())
                }
            }
            .font(.caption)
            .foregroundStyle(Palette.inkSecondary)
            // Ratings are identifiers, not quantities: never grouped.
            Text(verbatim: String(day.rating))
                .font(.title3.weight(.bold))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
            Text(verbatim: summary)
                .font(.caption.weight(.semibold))
                .foregroundStyle((day.change ?? 0) >= 0 ? Palette.brand : Palette.loss)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var summary: String {
        let games = "\(day.games) game\(day.games == 1 ? "" : "s")"
        guard let change = day.change else { return games }
        return "\(change >= 0 ? "+" : "−")\(abs(change)) · \(games)"
    }
}

// MARK: - Accessible chart alternative

struct RatingDataSheet: View {
    @Environment(\.dismiss) private var dismiss
    let points: [RatingPoint]
    let timeClass: TimeClass

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(points.reversed()) { point in
                        HStack {
                            Text(Format.date(point.date))
                                .font(.footnote)
                                .foregroundStyle(Palette.inkSecondary)
                            Spacer()
                            Text(verbatim: "\(point.rating)")
                                .font(.footnote.weight(.semibold))
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("\(timeClass.label) · rated games only")
                } footer: {
                    Text("This is the same data the chart draws, in a form VoiceOver and large text can read comfortably.")
                }
            }
            .navigationTitle("Rating data")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

/// A row of the Analytics quick-analysis list. Dims, rather than hides, when there is nothing
/// for it to do, so the list keeps its shape.
private struct AnalyseRow<Detail: View, Trailing: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    let symbol: String
    let title: String
    let detail: Detail
    let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isEnabled ? Palette.onBrand : Palette.inkSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(isEnabled ? Palette.brand : Color.white.opacity(0.1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                detail
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
            Spacer(minLength: 8)
            trailing
            if isEnabled {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: Layout.minimumTarget)
        .glassSurface(in: RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous), interactive: true)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
