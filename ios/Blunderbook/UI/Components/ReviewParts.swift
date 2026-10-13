//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// The rows of the game review (W09) that say more than the board: who is playing and how they
// stand, what a move did, the game's shape, and its summary. Every row keeps one height whatever
// it shows, so the board above never resizes.

// MARK: - Player row

/// One player beside the board: name and rating, the material they are up, their accuracy (the
/// tracked player only) and their clock. Every item sits on one centre line; the material takes
/// the width that is left and never pushes the name.
struct ReviewPlayerRow: View {
    let side: GameSide
    let color: PieceColor
    /// The kinds this side has more of, most valuable first.
    var material: [PieceKind] = []
    var lead = 0
    var accuracy: Double?
    var clock: TimeInterval?
    var isOnMove = false
    /// Under this the clock turns amber; under a third of it, red.
    var lowTime: TimeInterval = 60
    /// The game's result for this side, shown in place of the clock once the game is over.
    var result: String?

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(color == .white ? Palette.pieceLight : Palette.pieceDark)
                .overlay(Circle().strokeBorder(color == .white ? .clear : Palette.inkSecondary, lineWidth: 1.5))
                .frame(width: 10, height: 10)
                .padding(.trailing, 9)
            Text(side.username)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(2)
            if let rating = side.rating {
                Text(verbatim: "\(rating)")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkTertiary)
                    .monospacedDigit()
                    .padding(.leading, 7)
                    .layoutPriority(1)
            }
            materialView
                .padding(.leading, 8)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if let accuracy {
                HStack(spacing: 5) {
                    AccuracyRing(value: accuracy, style: .inline)
                    Text(Format.accuracy(accuracy))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.brand)
                }
                .padding(.leading, 8)
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Accuracy \(Format.accuracy(accuracy))")
            }
            clockPill
                .padding(.leading, 10)
        }
        .frame(height: Self.height)
        .animation(.smooth(duration: 0.3), value: material)
        .animation(.smooth(duration: 0.3), value: result)
    }

    /// The pieces give way first when the row is short; the "+n" always shows.
    @ViewBuilder
    private var materialView: some View {
        HStack(spacing: 3) {
            HStack(spacing: 2) {
                ForEach(Array(groups.enumerated()), id: \.element.kind) { _, group in
                    HStack(spacing: group.kind == .pawn ? -12 : -13) {
                        ForEach(0..<group.count, id: \.self) { _ in
                            Image(Piece(color: .white, kind: group.kind).artworkName)
                                .resizable()
                                .frame(width: group.kind == .pawn ? 23 : 25, height: group.kind == .pawn ? 23 : 25)
                                .shadow(color: Palette.background, radius: 0, x: -1)
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                        }
                    }
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .frame(minWidth: 0, alignment: .leading)
            .clipped()
            .layoutPriority(-1)
            if lead > 0 {
                Text(verbatim: "+\(lead)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText(value: Double(lead)))
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lead > 0 ? "Up \(lead) in material" : "Level material")
    }

    private var groups: [(kind: PieceKind, count: Int)] {
        [PieceKind.queen, .rook, .bishop, .knight, .pawn].compactMap { kind in
            let count = material.filter { $0 == kind }.count
            return count > 0 ? (kind, count) : nil
        }
    }

    @ViewBuilder
    private var clockPill: some View {
        if let result {
            Text(result)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else if let clock {
            let isCritical = clock < lowTime / 3
            let isLow = clock < lowTime
            Text(verbatim: GameClock.format(clock))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(isCritical ? Palette.blunder : isLow ? Palette.brand
                                 : isOnMove ? Palette.ink : Palette.inkTertiary)
                .padding(.horizontal, 9)
                .frame(minWidth: 52, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(isOnMove ? 0.13 : 0.05)))
                .overlay {
                    if isCritical {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Palette.blunder.opacity(0.5), lineWidth: 1)
                            .phaseAnimator([0.45, 1.0]) { content, opacity in content.opacity(isOnMove ? opacity : 0.45) }
                                animation: { _ in .easeInOut(duration: 0.7) }
                    }
                }
                .animation(.smooth(duration: 0.3), value: isOnMove)
                .animation(.smooth(duration: 0.3), value: isLow)
                .accessibilityLabel("Clock \(GameClock.format(clock))")
        }
    }
}

// MARK: - Verdict panel

/// What the lines panel says about a move worth stopping at, instead of the live lines.
enum ReviewVerdict: Equatable {
    /// The tracked player's error: what to play instead, and how the opponent punishes it.
    case error(Severity, kind: String?, spent: TimeInterval?, missedChance: Bool, repeatCount: Int?,
               best: LineSummary, punish: LineSummary)
    /// The opponent's error: the chance it gave. The live lines show how to take it.
    case chance(Severity, kind: String?)
    /// The tracked player took the opponent's error.
    case punished(kind: String?, clockLeft: TimeInterval?)

    struct LineSummary: Equatable {
        var score: EngineScore
        var notation: String
    }
}

/// The lines panel on a key move: a verdict row, then two rows of lines. Always as tall as the
/// live lines, so the board above never resizes.
struct VerdictPanel: View {
    let verdict: ReviewVerdict
    var liveLines: [EngineLine] = []
    var isCalculating = false
    var openRepeat: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            verdictRow
                .transition(.move(edge: .leading).combined(with: .opacity))
            switch verdict {
            case .error(_, _, _, _, _, let best, let punish):
                labelled("Best", tint: Palette.brand, line: best)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                labelled("Punish", tint: Palette.blunder, line: punish)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            case .chance, .punished:
                ForEach(0..<2, id: \.self) { index in
                    if index < liveLines.count {
                        EngineLineRow(score: liveLines[index].score, notation: liveLines[index].notation, rank: index)
                    } else {
                        EngineLineRow(score: .centipawns(0), notation: "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6")
                            .redacted(reason: .placeholder)
                    }
                }
                .opacity(isCalculating && !liveLines.isEmpty ? 0.5 : 1)
            }
        }
        .frame(height: EngineLinesPanel.height, alignment: .top)
        .animation(.easeOut(duration: 0.2), value: liveLines)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var verdictRow: some View {
        HStack(spacing: 6) {
            switch verdict {
            case .error(let severity, let kind, let spent, let missed, let repeatCount, _, _):
                VerdictBadge(text: severity.marker, color: severity.color)
                Text(severity.label).fontWeight(.bold).foregroundStyle(severity.color)
                if let kind { dot; Text(kind).foregroundStyle(Palette.ink) }
                if let spent { dot; spentLabel(spent) }
                Spacer(minLength: 4)
                if let repeatCount {
                    Button(action: openRepeat) {
                        HStack(spacing: 2) {
                            Text("\(Self.ordinal(repeatCount)) in 30 days")
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.brand)
                        .frame(minHeight: Layout.minimumTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Self.ordinal(repeatCount)) \(kind ?? "error") in 30 days")
                    .accessibilityHint("Opens Mistakes narrowed to this kind")
                } else if missed {
                    HStack(spacing: 4) {
                        Circle().strokeBorder(Palette.brand, style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.6]))
                            .frame(width: 10, height: 10)
                        Text("Missed chance")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.brand)
                }
            case .chance(let severity, let kind):
                VerdictBadge(text: severity.marker, color: severity.color, isHollow: true)
                Text("Their \(severity.label.lowercased())").fontWeight(.bold).foregroundStyle(severity.color)
                if let kind { dot; Text(kind).foregroundStyle(Palette.ink) }
                Spacer(minLength: 4)
                Text("Your chance").font(.caption.weight(.semibold)).foregroundStyle(Palette.best)
            case .punished(let kind, let clockLeft):
                VerdictBadge(symbol: "checkmark", color: Palette.best)
                Text("Punished").fontWeight(.bold).foregroundStyle(Palette.best)
                if let kind { dot; Text(kind).foregroundStyle(Palette.ink) }
                Spacer(minLength: 4)
                if let clockLeft {
                    Text("\(GameClock.format(clockLeft)) left").font(.caption).foregroundStyle(Palette.inkSecondary)
                }
            }
        }
        .font(.footnote)
        .lineLimit(1)
        .frame(height: 26)
        .accessibilityElement(children: .combine)
    }

    private var dot: some View { Text("·").foregroundStyle(Palette.inkTertiary) }

    /// Under five seconds is fast: a flash and the time in the mistake colour.
    @ViewBuilder
    private func spentLabel(_ spent: TimeInterval) -> some View {
        if spent <= 5 {
            HStack(spacing: 2) {
                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                Text(GameClock.formatSpent(spent)).monospacedDigit()
            }
            .foregroundStyle(Palette.mistake)
            .accessibilityLabel("played in \(GameClock.formatSpent(spent))")
        } else {
            Text(spent >= 60 ? "thought \(GameClock.formatSpent(spent))" : GameClock.formatSpent(spent))
                .monospacedDigit()
                .foregroundStyle(spent >= 60 ? Palette.brand : Palette.inkSecondary)
        }
    }

    private func labelled(_ label: String, tint: Color, line: ReviewVerdict.LineSummary) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(tint).frame(width: 3, height: 16)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.inkTertiary)
                .frame(width: 38, alignment: .leading)
            EngineLineRow(score: line.score, notation: line.notation)
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(line.score.accessibleText), \(line.notation)")
    }

    static func ordinal(_ value: Int) -> String {
        let suffix: String
        switch (value % 10, value % 100) {
        case (1, let t) where t != 11: suffix = "st"
        case (2, let t) where t != 12: suffix = "nd"
        case (3, let t) where t != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(value)\(suffix)"
    }
}

/// The round mark of a verdict, popping in as it arrives.
struct VerdictBadge: View {
    var text: String = ""
    var symbol: String?
    let color: Color
    var isHollow = false
    @State private var hasAppeared = false

    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .heavy)) }
            else { Text(text).font(.system(size: 10, weight: .heavy)) }
        }
        .foregroundStyle(isHollow ? color : Palette.onBrand)
        .frame(width: 20, height: 20)
        .background {
            if isHollow { Circle().strokeBorder(color, lineWidth: 1.5) } else { Circle().fill(color) }
        }
        .scaleEffect(hasAppeared ? 1 : 0.2)
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { hasAppeared = true } }
    }
}

// MARK: - Opening record

/// The player's record in this opening, beside its name: the score, and the games behind it once
/// opened (as it is on the move that leaves the book).
struct OpeningRecordChip: View {
    let record: OpeningRecord
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Text("You").foregroundStyle(Palette.inkSecondary)
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 20, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Palette.brand).frame(width: 20 * record.score / 100, height: 4)
                    }
                Text(verbatim: "\(Int(record.score.rounded()))%").monospacedDigit()
                if isOpen {
                    Text(verbatim: "\(record.games) games · \(record.wins)W \(record.draws)D \(record.losses)L")
                        .monospacedDigit()
                        .foregroundStyle(Palette.inkSecondary)
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Palette.ink)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(isOpen ? 0.12 : 0.08)))
            .fixedSize()
            .contentShape(Capsule().inset(by: -8))
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.4), value: isOpen)
        .accessibilityLabel("Your record in this opening: \(record.games) games, \(record.wins) wins, \(record.draws) draws, \(record.losses) losses")
    }
}

// MARK: - Evaluation graph

/// One mark on the evaluation graph.
struct GraphMarker: Identifiable, Equatable {
    enum Kind: Equatable {
        case playerError(Severity)
        case opponentError(Severity)
        /// A ring around the tracked player's error that let an opponent's error go.
        case missedChance
        case punished
    }
    /// The position after the move, 1 for White's first move.
    var ply: Int
    var kind: Kind
    var id: String { "\(ply)-\(kind)" }
}

/// One move's time, drawn as a tick under the graph.
struct GraphTick: Equatable {
    var ply: Int
    var spent: TimeInterval
    var tint: Color
}

/// The game's evaluation as a slim line over a shaded area, with the phases as bands, marks on
/// the moves worth stopping at, and the tracked player's time per move as ticks underneath.
/// Drag along it to move through the game.
struct EvaluationGraph: View {
    /// White's win percentage at each scored position, 0 being the start. A review still running
    /// may have gaps; the line bridges them.
    let points: [(ply: Int, win: Double)]
    /// The game's length in moves: the graph's width.
    let plyCount: Int
    var markers: [GraphMarker] = []
    /// The first position of each phase reached, in order.
    var phases: [(phase: GamePhase, ply: Int)] = []
    var showsPhaseLabels = false
    var ticks: [GraphTick] = []
    /// The position from which the tracked player was short of time.
    var lowTimeFrom: Int?
    let selectedPly: Int
    var onScrub: (Int) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal: CGFloat = 0

    static let lineHeight: CGFloat = 34
    static let tickHeight: CGFloat = 12

    var hasTicks: Bool { !ticks.isEmpty }
    var height: CGFloat { Self.lineHeight + (hasTicks ? Self.tickHeight + 3 : 0) }

    private var lastPly: Int { max(1, plyCount) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let x: (Int) -> CGFloat = { CGFloat($0) / CGFloat(lastPly) * width }
            let y: (Double) -> CGFloat = { 2 + (1 - CGFloat($0) / 100) * (Self.lineHeight - 4) }
            let curve = points.map { CGPoint(x: x($0.ply), y: y($0.win)) }
            let wins = Dictionary(points.map { ($0.ply, $0.win) }, uniquingKeysWith: { first, _ in first })
            ZStack(alignment: .topLeading) {
                bands(width: width, x: x)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y(50)))
                    path.addLine(to: CGPoint(x: width, y: y(50)))
                }
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                MonotonePath(points: curve, closingAt: y(50))
                    .fill(Color.white.opacity(0.08))
                    .opacity(Double(reveal))
                MonotonePath(points: curve)
                    .trim(from: 0, to: reveal)
                    .stroke(Palette.ink.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                ForEach(markers) { marker in
                    GraphMarkerView(kind: marker.kind, delay: reduceMotion ? 0 : 0.15 + 1.1 * Double(marker.ply) / Double(lastPly))
                        .position(x: x(marker.ply), y: y(wins[marker.ply] ?? 50))
                }
                if hasTicks { tickRow(width: width, x: x) }
                Capsule()
                    .fill(Palette.brand)
                    .frame(width: 2, height: Self.lineHeight + 2)
                    .offset(x: x(min(selectedPly, lastPly)) - 1, y: -1)
                    .animation(.smooth(duration: 0.3), value: selectedPly)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let fraction = max(0, min(1, value.location.x / max(1, width)))
                onScrub(Int((fraction * CGFloat(lastPly)).rounded()))
            })
        }
        .frame(height: height)
        .onAppear {
            if reduceMotion { reveal = 1 } else { withAnimation(.timingCurve(0.45, 0.05, 0.25, 1, duration: 1.3)) { reveal = 1 } }
        }
    }

    private func bands(width: CGFloat, x: @escaping (Int) -> CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(phases.enumerated()), id: \.offset) { index, item in
                let start = index == 0 ? 0 : x(item.ply)
                let end = index + 1 < phases.count ? x(phases[index + 1].ply) : width
                Rectangle()
                    .fill(Color.white.opacity(index % 2 == 1 ? 0.045 : 0.018))
                    .frame(width: max(0, end - start), height: Self.lineHeight)
                    .overlay(alignment: .leading) {
                        if index > 0 {
                            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        Text(item.phase.label.uppercased())
                            .font(.system(size: 7.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Palette.inkTertiary)
                            .padding(.leading, 3)
                            .padding(.top, 1)
                            .opacity(showsPhaseLabels ? 1 : 0)
                    }
                    .offset(x: start)
            }
        }
        .animation(.smooth(duration: 0.4), value: showsPhaseLabels)
    }

    private func tickRow(width: CGFloat, x: @escaping (Int) -> CGFloat) -> some View {
        let top = Self.lineHeight + 3
        return ZStack(alignment: .topLeading) {
            if let lowTimeFrom {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Palette.blunder.opacity(0.13))
                    .frame(width: max(0, width - x(lowTimeFrom - 1)), height: Self.tickHeight)
                    .offset(x: x(lowTimeFrom - 1), y: top)
            }
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: width, height: 0.5)
                .offset(y: top + Self.tickHeight - 0.5)
            ForEach(ticks, id: \.ply) { tick in
                let height = 1 + min(tick.spent, 120) / 120 * (Self.tickHeight - 2)
                RoundedRectangle(cornerRadius: 0.6)
                    .fill(tick.tint)
                    .frame(width: 2, height: height)
                    .offset(x: x(tick.ply) - 1, y: top + Self.tickHeight - height)
                    .opacity(Double(reveal))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct GraphMarkerView: View {
    let kind: GraphMarker.Kind
    let delay: Double
    @State private var hasAppeared = false

    var body: some View {
        Group {
            switch kind {
            case .playerError(let severity):
                Circle().fill(severity.color).frame(width: 6.6, height: 6.6)
            case .opponentError(let severity):
                Circle().fill(Palette.background).frame(width: 4.8, height: 4.8)
                    .overlay(Circle().strokeBorder(severity.color, lineWidth: 1.3))
            case .missedChance:
                Circle().strokeBorder(Palette.brand, style: StrokeStyle(lineWidth: 1.2, dash: [2, 1.7]))
                    .frame(width: 13, height: 13)
            case .punished:
                Circle().fill(Palette.best).frame(width: 6, height: 6)
            }
        }
        .scaleEffect(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55).delay(delay)) { hasAppeared = true }
        }
    }
}

/// A smooth line through the points that never overshoots them (monotone cubic, as Swift Charts
/// draws `.monotone`). With `closingAt`, the area between it and that height.
struct MonotonePath: Shape {
    let points: [CGPoint]
    var closingAt: CGFloat?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let n = points.count
        var slopes = [CGFloat](repeating: 0, count: n - 1), tangents = [CGFloat](repeating: 0, count: n)
        for i in 0..<(n - 1) {
            let dx = points[i + 1].x - points[i].x
            slopes[i] = dx == 0 ? 0 : (points[i + 1].y - points[i].y) / dx
        }
        tangents[0] = slopes[0]; tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) { tangents[i] = slopes[i - 1] * slopes[i] <= 0 ? 0 : (slopes[i - 1] + slopes[i]) / 2 }
        for i in 0..<(n - 1) {
            if slopes[i] == 0 { tangents[i] = 0; tangents[i + 1] = 0; continue }
            let a = tangents[i] / slopes[i], b = tangents[i + 1] / slopes[i], s = a * a + b * b
            if s > 9 { let k = 3 / s.squareRoot(); tangents[i] = k * a * slopes[i]; tangents[i + 1] = k * b * slopes[i] }
        }
        path.move(to: points[0])
        for i in 0..<(n - 1) {
            let h = (points[i + 1].x - points[i].x) / 3
            path.addCurve(to: points[i + 1],
                          control1: CGPoint(x: points[i].x + h, y: points[i].y + tangents[i] * h),
                          control2: CGPoint(x: points[i + 1].x - h, y: points[i + 1].y - tangents[i + 1] * h))
        }
        if let closingAt {
            path.addLine(to: CGPoint(x: points[n - 1].x, y: closingAt))
            path.addLine(to: CGPoint(x: points[0].x, y: closingAt))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Summary

/// What the summary card shows; the review screen fills it from the saved review.
struct ReviewSummary: Equatable {
    struct Side: Equatable {
        var name: String
        var accuracy: Double?
        var errors: [Severity: Int]
        var isPlayer: Bool
    }
    struct Fact: Equatable, Identifiable {
        var label: String
        var value: String
        /// Where tapping it goes.
        var ply: Int?
        var id: String { label }
    }
    var result: String
    var player: Side
    var opponent: Side
    var phases: [(phase: GamePhase, player: Double?, opponent: Double?)]
    var facts: [Fact]

    static func == (lhs: ReviewSummary, rhs: ReviewSummary) -> Bool {
        lhs.result == rhs.result && lhs.player == rhs.player && lhs.opponent == rhs.opponent && lhs.facts == rhs.facts
            && lhs.phases.map(\.phase) == rhs.phases.map(\.phase)
    }
}

/// The game in one card, in the board's place once you step past the last move: both
/// accuracies, each side's errors, accuracy by phase, and facts that jump to their move.
struct SummaryCard: View {
    let summary: ReviewSummary
    var jump: (Int) -> Void = { _ in }
    @State private var hasAppeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Summary")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.inkTertiary)
                Spacer()
                Text(summary.result)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.ink)
            }
            HStack(alignment: .top) {
                side(summary.player, tint: Palette.brand)
                Text("vs").font(.caption).foregroundStyle(Palette.inkTertiary).padding(.top, 28)
                side(summary.opponent, tint: Palette.inkSecondary)
            }
            phaseTable
            VStack(spacing: 0) {
                ForEach(Array(summary.facts.enumerated()), id: \.element.id) { index, fact in
                    factRow(fact)
                        .opacity(hasAppeared ? 1 : 0)
                        .offset(y: hasAppeared ? 0 : 6)
                        .animation(.smooth(duration: 0.4).delay(0.45 + Double(index) * 0.08), value: hasAppeared)
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .onAppear { hasAppeared = true }
    }

    private func side(_ side: ReviewSummary.Side, tint: Color) -> some View {
        VStack(spacing: 6) {
            SummaryRing(value: side.accuracy, tint: tint, isShown: hasAppeared)
            Text(side.isPlayer ? "You" : side.name)
                .font(.caption)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
            HStack(spacing: 5) {
                ForEach([Severity.inaccuracy, .mistake, .blunder], id: \.self) { severity in
                    let count = side.errors[severity] ?? 0
                    Text(verbatim: "\(severity.marker) \(count)")
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(count > 0 ? severity.color : Palette.inkTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var phaseTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(Array(summary.phases.enumerated()), id: \.offset) { index, row in
                GridRow {
                    Text(row.phase.label).font(.caption).foregroundStyle(Palette.inkSecondary)
                        .frame(width: 78, alignment: .leading)
                    bar(row.player, tint: Palette.brand, delay: 0.3 + Double(index) * 0.07)
                    figure(row.player, tint: Palette.ink)
                    bar(row.opponent, tint: Palette.inkSecondary, delay: 0.34 + Double(index) * 0.07)
                    figure(row.opponent, tint: Palette.inkSecondary)
                }
            }
        }
    }

    private func bar(_ value: Double?, tint: Color, delay: Double) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.07))
            .frame(height: 5)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule().fill(tint)
                        .frame(width: hasAppeared ? proxy.size.width * CGFloat((value ?? 0) / 100) : 0)
                        .animation(.smooth(duration: 0.8).delay(delay), value: hasAppeared)
                }
            }
            .frame(maxWidth: .infinity)
    }

    private func figure(_ value: Double?, tint: Color) -> some View {
        Text(value.map { "\(Int($0.rounded()))" } ?? "—")
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(tint)
            .frame(width: 26, alignment: .trailing)
    }

    private func factRow(_ fact: ReviewSummary.Fact) -> some View {
        Button {
            if let ply = fact.ply { jump(ply) }
        } label: {
            HStack(spacing: 10) {
                Text(fact.label).foregroundStyle(Palette.inkSecondary).frame(width: 104, alignment: .leading)
                Text(fact.value).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if fact.ply != nil {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Palette.inkTertiary)
                }
            }
            .font(.footnote)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(fact.ply != nil)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
        .accessibilityLabel("\(fact.label): \(fact.value)")
    }
}

/// A large accuracy ring whose arc sweeps in and whose figure counts up as the summary opens.
private struct SummaryRing: View {
    let value: Double?
    let tint: Color
    let isShown: Bool

    var body: some View {
        let shown = isShown ? (value ?? 0) : 0
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 5)
            Circle()
                .trim(from: 0, to: shown / 100)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(value.map { _ in String(format: "%.1f", shown) } ?? "—")
                .font(.headline.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText(value: shown))
        }
        .frame(width: 64, height: 64)
        .padding(2.5)
        .animation(.smooth(duration: 1.2), value: isShown)
    }
}
