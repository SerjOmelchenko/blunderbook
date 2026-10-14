//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// MARK: - Rings

/// The Mistakes tab's three rings, drawn like the accuracy rings: solved outside, solved at the
/// first try in the middle, today's due puzzles done inside, with the check once all is clear.
/// They spin as the tab opens and settle on their values; when the values change, as after a
/// session, they spin briefly and settle again.
struct MistakeRings: View {
    let solved: Double
    let firstTry: Double
    let dueCleared: Double
    let isClear: Bool
    var diameter: CGFloat = 64

    @State private var phase: AccuracyRings.Phase = .busy

    private var values: AccuracyRings.Phase {
        .values(game: solved * 100, days30: firstTry * 100, months12: dueCleared * 100, solved: isClear)
    }

    var body: some View {
        AccuracyRings(phase: phase, diameter: diameter)
            .task(id: values) {
                if phase != .busy { phase = .busy }
                try? await Task.sleep(for: .milliseconds(520))
                phase = values
            }
            .accessibilityElement()
            .accessibilityLabel("\(Int((solved * 100).rounded())) percent solved, \(Int((firstTry * 100).rounded())) percent at the first try")
    }
}

// MARK: - Training

/// The top of the tab: the rings, what they mean, and the session button.
struct TrainingHeader: View {
    let book: MistakeBook
    let start: ([MistakeOccurrence]) -> Void

    var body: some View {
        let pick = book.trainingPick()
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    MistakeRings(solved: book.solvedShare, firstTry: book.firstTry ?? 0,
                                 dueCleared: book.dueCleared, isClear: book.isAllClear)
                    VStack(alignment: .leading, spacing: 6) {
                        legend(ring: 0, value: Format.percent(book.solvedShare * 100), label: "solved",
                               detail: "\(book.solved) of \(book.errors)")
                        legend(ring: 1, value: book.firstTry.map { Format.percent($0 * 100) } ?? "\u{2014}",
                               label: "first try", detail: nil)
                        legend(ring: 2, value: book.dueToday.formatted(), label: "due today",
                               detail: book.reviewedToday > 0 ? "\(book.reviewedToday) done" : nil)
                    }
                    Spacer(minLength: 0)
                }
                if !pick.isEmpty {
                    TrainButton(count: pick.count, caption: book.trainingCaption) { start(pick) }
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
        }
    }

    private func legend(ring: Int, value: String, label: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(AccuracyRings.colors[ring]).frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText())
            Text(label)
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
            }
        }
        .animation(.smooth(duration: 0.5), value: value)
        .accessibilityElement(children: .combine)
    }
}

/// The amber button that starts a session: "Solve 5", and what is in it.
struct TrainButton: View {
    let count: Int
    let caption: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.footnote.weight(.bold))
                Text("Solve \(count)")
                    .font(.body.weight(.semibold))
                    .contentTransition(.numericText(value: Double(count)))
                Spacer(minLength: 8)
                Text(caption)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.onBrand.opacity(0.7))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Palette.onBrand.opacity(0.7))
            }
            .foregroundStyle(Palette.onBrand)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.brand))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Solve \(count) mistakes, \(caption)")
    }
}

/// A button that gives a little under the finger.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.smooth(duration: 0.18), value: configuration.isPressed)
    }
}

// MARK: - All clear

/// In the header's place once every puzzle is solved and none is due: full rings, the check, and
/// when the next ones come back. A hairline of amber runs once along the top as it appears.
struct AllClearPanel: View {
    let title: String
    let message: String
    @State private var sweep: CGFloat = -0.3
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Panel(padding: 18) {
            HStack(spacing: 16) {
                MistakeRings(solved: 1, firstTry: 1, dueCleared: 1, isClear: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 6)
                Spacer(minLength: 0)
            }
        }
        .overlay(alignment: .top) {
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, Palette.brand.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.35, height: 1)
                    .offset(x: proxy.size.width * sweep)
            }
            .frame(height: 1)
            .padding(.horizontal, Layout.cardRadius)
            .allowsHitTesting(false)
        }
        .task {
            withAnimation(.smooth(duration: 0.5).delay(0.9)) { shown = true }
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .milliseconds(1_200))
            withAnimation(.easeInOut(duration: 1.4)) { sweep = 1 }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Biggest leak

/// What goes wrong most, how it has moved over the last 30 days, and every kind as one bar that
/// narrows the list when tapped.
struct LeakPanel: View {
    let book: MistakeBook
    @Binding var selectedKind: MistakeCategory?
    let showsTrend: Bool

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                if book.leak == nil {
                    Text("Kinds of mistake").eyebrowStyle()
                }
                if let leak = book.leak {
                    Text("Biggest leak").eyebrowStyle()
                    HStack(alignment: .firstTextBaseline) {
                        Text(leak.category.title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                            .contentTransition(.opacity)
                            .id(leak.category.id)
                            .transition(.opacity.combined(with: .offset(y: 4)))
                        Spacer(minLength: 8)
                        Text(Format.percent(leak.share * 100))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(Palette.brand)
                            .contentTransition(.numericText(value: leak.share))
                    }
                    trendLine(leak)
                }
                KindBar(kinds: book.backlog.kinds, selected: $selectedKind)
                    .padding(.top, 2)
            }
            .animation(.smooth(duration: 0.4), value: book.leak)
        }
    }

    @ViewBuilder
    private func trendLine(_ leak: MistakeBook.Leak) -> some View {
        HStack(spacing: 6) {
            if showsTrend, let trend = leak.trend, trend.previous > 0, trend.delta != 0 {
                Image(systemName: trend.delta < 0 ? "arrow.down.right" : "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(trend.delta < 0 ? Palette.improved : Palette.declined)
                    .transition(.scale.combined(with: .opacity))
            }
            Text(trendText(leak))
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(2)
        }
    }

    private func trendText(_ leak: MistakeBook.Leak) -> String {
        let errors = "\(leak.count) of \(book.errors) error\(book.errors == 1 ? "" : "s")"
        guard showsTrend, let trend = leak.trend else { return errors }
        if trend.previous == 0 { return "\(errors) \u{00B7} \(trend.recent) in the last 30 days" }
        if trend.delta == 0 { return "\(trend.recent) in the last 30 days, as in the 30 before" }
        return "\(trend.recent) in the last 30 days, \(trend.delta < 0 ? "down" : "up") from \(trend.previous)"
    }
}

/// Every kind as a share of one bar, patterns in amber and consequences in grey. Tapping a
/// segment narrows the list to it; the others dim. The segments grow in, one after another.
struct KindBar: View {
    let kinds: [MistakeKindCount]
    @Binding var selected: MistakeCategory?
    @State private var grown = false

    private var total: Int { max(1, kinds.reduce(0) { $0 + $1.count }) }

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let available = proxy.size.width - spacing * CGFloat(max(0, kinds.count - 1))
            HStack(spacing: spacing) {
                ForEach(Array(kinds.enumerated()), id: \.element.id) { index, kind in
                    let width = max(5, available * CGFloat(kind.count) / CGFloat(total))
                    let isSelected = selected == kind.category
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { selected = isSelected ? nil : kind.category }
                    } label: {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(color(kind: kind, rank: index))
                            .frame(height: isSelected ? 14 : 10)
                            .opacity(selected == nil || isSelected ? 1 : 0.3)
                            .frame(width: grown ? width : 0, height: 28)
                            .animation(.smooth(duration: 0.7).delay(0.15 + Double(index) * 0.06), value: grown)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(kind.category.title), \(kind.count)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .frame(height: 28)
        .onAppear { grown = true }
    }

    private func color(kind: MistakeKindCount, rank: Int) -> Color {
        let step = Double(rank) * 0.12
        return kind.category.isPattern ? Palette.brand.opacity(max(0.4, 1 - step)) : Color.white.opacity(max(0.12, 0.3 - step / 3))
    }
}

/// The kinds as labels with their counts; the selection slides between them.
struct KindChipRow: View {
    let book: MistakeBook
    @Binding var selected: MistakeCategory?
    var showsTrend = true
    @Namespace private var selection

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip(id: "all", title: "All", count: book.errors, trend: nil, isSelected: selected == nil) { selected = nil }
                    ForEach(book.backlog.kinds) { kind in
                        chip(id: kind.id, title: kind.category.title, count: kind.count,
                             trend: showsTrend ? book.trends[kind.category] : nil,
                             isSelected: selected == kind.category) {
                            selected = selected == kind.category ? nil : kind.category
                        }
                    }
                }
                .padding(.horizontal, Layout.gutter)
            }
            .padding(.horizontal, -Layout.gutter)
            .onChange(of: selected) { _, kind in
                withAnimation(.smooth(duration: 0.35)) { reader.scrollTo(kind?.id ?? "all", anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kinds of mistake")
    }

    private func chip(id: String, title: String, count: Int, trend: MistakeBook.Trend?, isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.smooth(duration: 0.3)) { action() }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                Text(count.formatted())
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
                    .foregroundStyle(isSelected ? Palette.onBrand.opacity(0.7) : Palette.inkTertiary)
                if let trend, trend.previous > 0, trend.delta != 0 {
                    Image(systemName: trend.delta < 0 ? "arrow.down" : "arrow.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isSelected ? Palette.onBrand.opacity(0.7)
                                         : (trend.delta < 0 ? Palette.improved : Palette.declined))
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isSelected ? Palette.onBrand : Palette.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background {
                if isSelected {
                    Capsule().fill(Palette.brand).matchedGeometryEffect(id: "selected", in: selection)
                } else {
                    Capsule().fill(Color.white.opacity(0.07))
                }
            }
            .frame(minHeight: Layout.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Clock

/// How the clock stood when the errors were made: the one fact worth knowing, then rushed, time
/// trouble and long think, each a share that narrows the list when tapped.
struct ClockPanel: View {
    let time: MistakeBook.TimeProfile
    @Binding var focus: MistakeFocus?
    @State private var grown = false

    var body: some View {
        Panel(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Against the clock").eyebrowStyle()
                    Spacer(minLength: 8)
                    Text("\(time.timed) timed error\(time.timed == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
                if let headline = time.headline {
                    Text(headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                HStack(spacing: 8) {
                    ForEach(Array(TimeTrait.allCases.enumerated()), id: \.element) { index, trait in
                        cell(trait, delay: 0.2 + Double(index) * 0.08)
                    }
                }
            }
        }
        .onAppear { grown = true }
    }

    private func cell(_ trait: TimeTrait, delay: Double) -> some View {
        let isSelected = focus == .time(trait)
        let count = time.counts[trait] ?? 0
        return Button {
            withAnimation(.smooth(duration: 0.3)) { focus = isSelected ? nil : .time(trait) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: trait.symbol).font(.system(size: 10, weight: .bold))
                    Text(trait.title).lineLimit(1).minimumScaleFactor(0.8)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(isSelected ? Palette.brand : Palette.inkSecondary)
                Text(count.formatted())
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(count > 0 ? Palette.ink : Palette.inkTertiary)
                    .contentTransition(.numericText(value: Double(count)))
                Capsule()
                    .fill(Color.white.opacity(0.07))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().fill(Palette.brand)
                                .frame(width: grown ? proxy.size.width * time.share(trait) : 0)
                                .animation(.smooth(duration: 0.8).delay(delay), value: grown)
                        }
                    }
                Text(trait.caption)
                    .font(.caption2)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Palette.brandSoft : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.brand.opacity(isSelected ? 0.55 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle())
        .disabled(count == 0)
        .accessibilityLabel("\(trait.title): \(count) errors, \(trait.caption)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Openings

/// The openings where most errors fall in the first 20 moves, with where in them; tapping one
/// narrows the list to those errors.
struct HotSpotsPanel: View {
    let spots: [MistakeBook.HotSpot]
    let repeated: Int
    @Binding var focus: MistakeFocus?
    @State private var grown = false

    var body: some View {
        Panel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if !spots.isEmpty {
                    Text("Opening hot spots").eyebrowStyle()
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                    ForEach(Array(spots.enumerated()), id: \.element.id) { index, spot in
                        if index > 0 { Hairline().padding(.leading, 16) }
                        row(spot, index: index)
                    }
                }
                if repeated > 0 {
                    if !spots.isEmpty { Hairline() }
                    repeatsRow
                }
            }
        }
        .onAppear { grown = true }
    }

    private func row(_ spot: MistakeBook.HotSpot, index: Int) -> some View {
        let isSelected = focus == .opening(spot.name)
        let most = spots.map(\.count).max() ?? 1
        return Button {
            withAnimation(.smooth(duration: 0.3)) { focus = isSelected ? nil : .opening(spot.name) }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spot.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Palette.brand : Palette.ink)
                        .lineLimit(1)
                    Text("mostly \(spot.movesText)")
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                }
                Spacer(minLength: 8)
                Capsule()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 64, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Palette.brand.opacity(isSelected ? 1 : 0.7))
                            .frame(width: grown ? 64 * CGFloat(spot.count) / CGFloat(most) : 0, height: 4)
                            .animation(.smooth(duration: 0.8).delay(0.2 + Double(index) * 0.08), value: grown)
                    }
                Text(spot.count.formatted())
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .frame(minWidth: 22, alignment: .trailing)
                Image(systemName: isSelected ? "checkmark" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? Palette.brand : Palette.inkTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 14)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(spot.name): \(spot.count) errors, mostly \(spot.movesText)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var repeatsRow: some View {
        let isSelected = focus == .repeated
        return Button {
            withAnimation(.smooth(duration: 0.3)) { focus = isSelected ? nil : .repeated }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.on.square")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.brass)
                    .frame(width: 22)
                Text("\(repeated) position\(repeated == 1 ? "" : "s") you got wrong in more than one game")
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Palette.brand : Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark" : "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? Palette.brand : Palette.inkTertiary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 14)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Focus

/// The narrowing beside the kind, with a button that takes it off.
struct FocusPill: View {
    let focus: MistakeFocus
    let count: Int
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: focus.symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.brand)
                .padding(.leading, 14)
            Text(focus.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.brand)
                .lineLimit(1)
            Text(count.formatted())
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.brand.opacity(0.6))
            Spacer(minLength: 4)
            Button(action: clear) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Palette.brand)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Palette.brand.opacity(0.16)))
                    .frame(width: Layout.minimumTarget, height: Layout.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show every error")
        }
        .frame(minHeight: Layout.minimumTarget)
        .background(Capsule().fill(Palette.brandSoft))
        .overlay(Capsule().strokeBorder(Palette.brand.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - List

/// A week's heading, pinned while its errors scroll under it.
struct MistakeSectionHeader: View {
    let section: MistakeBook.Section

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.ink)
            Text(section.caption)
                .font(.footnote)
                .foregroundStyle(Palette.inkTertiary)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(Palette.background.opacity(0.96))
        .accessibilityAddTraits(.isHeader)
    }
}

/// One error: the position with the move played as a red arrow (and once solved, the better
/// move beside it), the move and its severity, its kind, what it cost, how long it took, and
/// where it stands in the repetition. A position missed in several games is stacked.
struct MistakeCard: View {
    let occurrence: MistakeOccurrence
    var showsState = true

    private var thumbnail: BoardPresentation {
        var presentation = BoardPresentation(pieces: ChessBoard(fen: occurrence.fenBefore)?.snapshot
                                                ?? BoardPresentation.empty.pieces,
                                             orientation: occurrence.color)
        presentation.mistakeMove = occurrence.move
        if occurrence.isSolved { presentation.suggestedMove = occurrence.bestMove }
        return presentation
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            board
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("\(occurrence.moveNumberLabel) \(occurrence.san)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    if let severity = occurrence.severity {
                        Badge(text: severity.label, tone: severity.color)
                    }
                    Spacer(minLength: 0)
                    if showsState { StateChip(state: occurrence.state()) }
                }
                if !occurrence.kinds.isEmpty {
                    MistakeKindLabels(kinds: occurrence.kinds)
                }
                HStack(spacing: 10) {
                    Text(occurrence.swingText)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                    if let spent = occurrence.clock?.spent {
                        SpentLabel(spent: spent, isRushed: occurrence.has(.rushed),
                                   isShort: occurrence.has(.timeTrouble))
                    }
                    if occurrence.isSolved, let best = occurrence.bestMoveSAN {
                        HStack(spacing: 3) {
                            Text("Best")
                                .foregroundStyle(Palette.inkTertiary)
                            Text(best)
                                .foregroundStyle(Palette.best)
                        }
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                if !occurrence.repeats.isEmpty {
                    Text(repeatText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.brass)
                        .lineLimit(1)
                }
                Text(context)
                    .font(.caption2)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: Layout.minimumTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(occurrence.isSolved ? "Solved" : "Not solved")
        .accessibilityHint("Opens the position to find a better move")
    }

    private var board: some View {
        let stacked = min(2, occurrence.repeats.count)
        return ZStack(alignment: .bottomTrailing) {
            ForEach(0..<stacked, id: \.self) { layer in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 0.5))
                    .frame(width: 72, height: 72)
                    .offset(x: CGFloat(stacked - layer) * 3, y: CGFloat(stacked - layer) * -3)
            }
            BoardView(presentation: thumbnail, showsCoordinates: false, cornerRadius: 8)
                .frame(width: 72, height: 72)
                .allowsHitTesting(false)
            if occurrence.isSolved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(Palette.best)
                    .background(Circle().fill(Palette.surface).padding(1))
                    .offset(x: 5, y: 5)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .padding(.top, CGFloat(stacked) * 3)
        .padding(.trailing, CGFloat(stacked) * 3)
        .accessibilityHidden(true)
    }

    private var repeatText: String {
        let games = Set(occurrence.repeats.map(\.gameKey) + [occurrence.gameKey]).count
        return occurrence.repeatsSameMove
            ? "You played \(occurrence.san) here in \(games) games"
            : "Same position, wrong in \(games) games"
    }

    private var context: String {
        var parts = ["vs \(occurrence.opponent)", Format.relative(occurrence.endTime), occurrence.phase.label]
        if let opening = OpeningFamily.name(occurrence.openingName), occurrence.phase == .opening { parts.append(opening) }
        return parts.joined(separator: " \u{00B7} ")
    }
}

/// How long a move took: a bolt when it was rushed, amber when short of time.
struct SpentLabel: View {
    let spent: TimeInterval
    var isRushed = false
    var isShort = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isRushed ? "bolt.fill" : (isShort ? "hourglass.bottomhalf.filled" : "clock"))
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isRushed || isShort ? Palette.brand : Palette.inkTertiary)
        .accessibilityLabel(spent < 1 ? "Played in under a second" : "Played in \(text)")
    }

    /// "<1s" rather than "0s" for a move made at once.
    private var text: String { spent < 1 ? "<1s" : GameClock.formatSpent(spent) }
}

/// New, Due, In 3 days or Learned.
struct StateChip: View {
    let state: MistakeState

    var body: some View {
        Text(state.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tone)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
            .fixedSize()
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.3), value: state)
    }

    private var tone: Color {
        switch state {
        case .new: return Palette.inkSecondary
        case .due: return Palette.onBrand
        case .learning: return Palette.inkTertiary
        case .learned: return Palette.best
        }
    }

    private var fill: Color {
        switch state {
        case .due: return Palette.brand
        case .learned: return Palette.best.opacity(0.12)
        default: return .clear
        }
    }

    private var stroke: Color {
        switch state {
        case .new, .learning: return Palette.hairline
        default: return .clear
        }
    }
}

/// What kind of mistake a move was. A pattern the board demonstrates is marked as a tactic; a
/// consequence, for a move no pattern explains, is quieter.
struct MistakeKindLabels: View {
    let kinds: [MistakeCategory]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(kinds) { kind in
                HStack(spacing: 3) {
                    Image(systemName: kind.isPattern ? "scope" : "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(kind.title)
                        .lineLimit(1)
                }
                .font(.caption.weight(kind.isPattern ? .semibold : .regular))
                .foregroundStyle(kind.isPattern ? Palette.brass : Palette.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Swipe

/// One action behind a `SwipeRow`.
struct SwipeAction: Identifiable {
    var title: String
    var symbol: String
    var tint: Color
    var run: () -> Void
    var id: String { title }
}

/// A row that slides left to show actions behind it. The drag only takes over once it is
/// clearly sideways, so the list still scrolls under a finger moving up or down.
struct SwipeRow<Content: View>: View {
    let actions: [SwipeAction]
    @ViewBuilder var content: Content

    @State private var offset: CGFloat = 0
    @State private var isOpen = false
    @State private var isHorizontal: Bool?
    private let actionWidth: CGFloat = 78

    private var revealWidth: CGFloat { actionWidth * CGFloat(actions.count) }

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                ForEach(actions) { action in
                    Button {
                        close()
                        action.run()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: action.symbol).font(.body.weight(.semibold))
                            Text(action.title).font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(action.tint)
                        .frame(width: actionWidth)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .opacity(min(1, Double(-offset / max(1, revealWidth)) * 1.4))
            .scaleEffect(0.9 + 0.1 * min(1, -offset / max(1, revealWidth)), anchor: .trailing)

            content
                .background(Palette.surface)
                .offset(x: offset)
                .overlay {
                    // While open, a tap anywhere on the row closes it instead of opening it.
                    if isOpen {
                        Color.clear.contentShape(Rectangle()).onTapGesture { close() }
                            .offset(x: offset)
                    }
                }
        }
        .clipped()
        .simultaneousGesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in
                    if isHorizontal == nil {
                        isHorizontal = abs(value.translation.width) > abs(value.translation.height) * 1.4
                    }
                    guard isHorizontal == true else { return }
                    let base = isOpen ? -revealWidth : 0
                    let proposed = base + value.translation.width
                    // Past the actions it gives, like a rubber band; it never goes right.
                    offset = proposed < -revealWidth
                        ? -revealWidth + (proposed + revealWidth) * 0.25
                        : min(0, proposed)
                }
                .onEnded { value in
                    defer { isHorizontal = nil }
                    guard isHorizontal == true else { return }
                    let base = isOpen ? -revealWidth : 0
                    let projected = base + value.predictedEndTranslation.width
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        isOpen = projected < -revealWidth / 2
                        offset = isOpen ? -revealWidth : 0
                    }
                }
        )
        .accessibilityActions {
            ForEach(actions) { action in
                Button(action.title, action: action.run)
            }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isOpen = false
            offset = 0
        }
    }
}

/// Each card rises into place a beat after the one above it when the list is drawn afresh.
struct RiseIn: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                if index > 10 { shown = true; return }
                withAnimation(.smooth(duration: 0.45).delay(Double(index) * 0.045)) { shown = true }
            }
    }
}

/// "Ignored 14…Nxe4 · Undo", under the list for a few seconds after a mistake is ignored.
struct UndoBar: View {
    let text: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo", action: undo)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.brand)
                .frame(minHeight: Layout.minimumTarget)
        }
        .padding(.horizontal, 18)
        .background(Capsule().fill(Palette.surfaceRaised))
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 0.5))
        .padding(.horizontal, Layout.gutter)
        .padding(.bottom, 8)
    }
}
