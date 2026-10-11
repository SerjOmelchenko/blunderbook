//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// MARK: - W12a Mistakes preview

/// What the locked Mistakes tab opens on the free plan: what the tab does, then the tab itself
/// running on sample games, so every part of it can be tried — narrowing by kind, solving a
/// mistake as a puzzle, exploring from the position. Nothing here is saved; solving a sample
/// only ticks it until the sheet closes.
struct MistakesPreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.showPaywall) private var showPaywall
    @State private var path: [Route] = []
    @State private var selectedKind: MistakeCategory?
    @State private var solved: Set<String> = SampleMistakes.initiallySolved

    private var all: [MistakeOccurrence] { SampleMistakes.occurrences(solved: solved) }
    private var shown: [MistakeOccurrence] {
        guard let selectedKind else { return all }
        return all.filter { $0.kinds.contains(selectedKind) }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    features
                    HStack(spacing: 8) {
                        Text("Try it on sample games").eyebrowStyle()
                        Spacer(minLength: 0)
                        Badge(text: "Sample", tone: Palette.brass)
                    }
                    .padding(.top, 4)
                    MistakesContent(breakdown: SampleMistakes.breakdown,
                                    backlog: SampleMistakes.backlog(of: all),
                                    accuracy: SampleMistakes.accuracy,
                                    mistakes: shown,
                                    selectedKind: $selectedKind.animation(.smooth(duration: 0.2)))
                }
                .padding(Layout.gutter)
                .padding(.bottom, 12)
            }
            .screenBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) { unlockBar }
            .navigationTitle("Mistakes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .navigationDestination(for: Route.self, destination: destination)
        }
        // Subscribing from here goes straight to the real tab.
        .onChange(of: model.isMistakesLocked) { _, isLocked in
            guard !isLocked else { return }
            model.selectedTab = .mistakes
            dismiss()
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Premium", systemImage: "lock.fill")
                .eyebrowStyle()
            Text("Every mistake,\nready to solve.")
                .font(.display(.title))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Below is the tab on sample games. Tap around: it works the same way with yours.")
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var features: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                feature("list.bullet.rectangle", "Every error in one list",
                        "From all your analysed games, newest first.")
                feature("scope", "What went wrong",
                        "Hanging piece, allowed fork, missed mate. Tap one to filter.")
                feature("puzzlepiece", "Solve it as a puzzle",
                        "Find a better move; the engine checks it.")
            }
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.brass)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Pinned under the list, never over it.
    private var unlockBar: some View {
        VStack(spacing: 6) {
            Button(unlockTitle) { showPaywall() }
                .buttonStyle(PrimaryButtonStyle())
            Text(unlockCaption)
                .font(.caption)
                .foregroundStyle(Palette.inkTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Palette.background)
    }

    private var unlockTitle: String {
        if let length = model.entitlement.freeTrialLength { return "Start \(length) free trial" }
        return "Unlock with Premium"
    }

    private var unlockCaption: String {
        guard model.entitlement.product != nil else { return "Includes deeper reviews, bulk analysis and more players." }
        let price = model.entitlement.priceDescription
        if model.entitlement.freeTrial != nil { return "Then \(price). Includes deeper reviews, bulk analysis and more players." }
        return "\(price). Includes deeper reviews, bulk analysis and more players."
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .mistakeDrill(let occurrence):
            MistakeDrillScreen(occurrence: occurrence) { solvedOne in
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { _ = solved.insert(solvedOne.id) }
            }
        case .explore(let start):
            ExploreScreen(start: start)
        default:
            EmptyView()
        }
    }
}

// MARK: - Sample games

/// Mistakes from short, well-known games, for the preview. Each position is real and each move
/// legal (checked by `SampleMistakesTests`), so the puzzles play exactly like real ones.
enum SampleMistakes {
    struct Sample {
        var gameKey: String
        var ply: Int
        var fen: String
        var played: String
        var san: String
        var best: String
        var bestSAN: String
        var score: EngineScore
        var severity: Severity
        var phase: GamePhase
        var kinds: [MistakeCategory]
        var opponent: String
        var daysAgo: Double
        var explanation: String
    }

    static let samples: [Sample] = [
        Sample(gameKey: "sample-backrank", ply: 48, fen: "6k1/5ppp/8/8/8/8/1q3PPP/3R2K1 w - - 0 25",
               played: "h2h3", san: "h3", best: "d1d8", bestSAN: "Rd8#", score: .mate(1),
               severity: .blunder, phase: .endgame, kinds: [.pattern(.missedMate)],
               opponent: "tempo_tina", daysAgo: 1,
               explanation: "Rd8 was mate on the back rank."),
        Sample(gameKey: "sample-ng5", ply: 4, fen: "rnbqkbnr/ppp2ppp/3p4/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 0 3",
               played: "f3g5", san: "Ng5", best: "d2d4", bestSAN: "d4", score: .centipawns(40),
               severity: .blunder, phase: .opening, kinds: [.pattern(.undefendedPiece)],
               opponent: "gambit_gus", daysAgo: 2,
               explanation: "The knight on g5 is undefended, and the queen takes it."),
        Sample(gameKey: "sample-nxe5", ply: 5, fen: "r1bqkbnr/pppp1ppp/2n5/4N3/4P3/8/PPPP1PPP/RNBQKB1R b KQkq - 0 3",
               played: "g8f6", san: "Nf6", best: "c6e5", bestSAN: "Nxe5", score: .centipawns(-250),
               severity: .blunder, phase: .opening, kinds: [.pattern(.missedCapture)],
               opponent: "rookie_rook", daysAgo: 3,
               explanation: "The knight on e5 was free to take."),
        Sample(gameKey: "sample-friedliver", ply: 7, fen: "r1bqkb1r/pppp1ppp/2n2n2/4p1N1/2B1P3/8/PPPP1PPP/RNBQK2R b KQkq - 5 4",
               played: "h7h6", san: "h6", best: "d7d5", bestSAN: "d5", score: .centipawns(30),
               severity: .mistake, phase: .opening, kinds: [.pattern(.allowedFork)],
               opponent: "endgame_ed", daysAgo: 5,
               explanation: "Nxf7 forks the queen and the rook."),
        Sample(gameKey: "sample-scholar", ply: 5, fen: "r1bqkbnr/pppp1ppp/2n5/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 3 3",
               played: "g8f6", san: "Nf6", best: "d8e7", bestSAN: "Qe7", score: .centipawns(-20),
               severity: .blunder, phase: .opening, kinds: [.pattern(.allowedMate)],
               opponent: "pawnstorm_ana", daysAgo: 7,
               explanation: "Qxf7 is mate."),
        Sample(gameKey: "sample-najdorf", ply: 8, fen: "rnbqkb1r/pp2pppp/3p1n2/8/3NP3/8/PPP2PPP/RNBQKB1R w KQkq - 1 5",
               played: "f1d3", san: "Bd3", best: "b1c3", bestSAN: "Nc3", score: .centipawns(40),
               severity: .inaccuracy, phase: .opening, kinds: [.outcome(.evaluationLoss)],
               opponent: "tempo_tina", daysAgo: 9,
               explanation: "Nc3 defends e4 and develops a piece."),
    ]

    /// One is already solved, to show what that looks like.
    static let initiallySolved: Set<String> = ["sample-nxe5#5"]

    static func occurrences(solved: Set<String>, now: Date = Date()) -> [MistakeOccurrence] {
        samples.map { sample in
            let color: PieceColor = sample.fen.split(separator: " ").dropFirst().first == "w" ? .white : .black
            let moveNumber = Int(sample.fen.split(separator: " ").last ?? "") ?? 1
            return MistakeOccurrence(gameKey: sample.gameKey, ply: sample.ply, san: sample.san,
                                     moveNumberLabel: color == .white ? "\(moveNumber)." : "\(moveNumber)\u{2026}",
                                     severity: sample.severity, phase: sample.phase,
                                     explanation: sample.explanation, opponent: sample.opponent,
                                     endTime: now.addingTimeInterval(-sample.daysAgo * 86_400), color: color,
                                     fenBefore: sample.fen, uci: sample.played, scoreBefore: sample.score,
                                     bestMoveUCI: sample.best, bestMoveSAN: sample.bestSAN,
                                     solvedAt: solved.contains("\(sample.gameKey)#\(sample.ply)") ? now : nil,
                                     kinds: sample.kinds)
        }
    }

    /// Counted the way the real backlog is: patterns first, then consequences, most frequent first.
    static func backlog(of occurrences: [MistakeOccurrence]) -> MistakeBacklog {
        var counts: [MistakeCategory: (count: Int, solved: Int)] = [:]
        var order: [MistakeCategory] = []
        for occurrence in occurrences {
            for kind in occurrence.kinds {
                if counts[kind] == nil { order.append(kind) }
                counts[kind, default: (0, 0)].count += 1
                if occurrence.isSolved { counts[kind, default: (0, 0)].solved += 1 }
            }
        }
        let kinds = order.enumerated().sorted { lhs, rhs in
            if lhs.element.isPattern != rhs.element.isPattern { return lhs.element.isPattern }
            let left = counts[lhs.element]!.count, right = counts[rhs.element]!.count
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map { MistakeKindCount(category: $0.element, count: counts[$0.element]!.count, solved: counts[$0.element]!.solved) }
        return MistakeBacklog(errors: occurrences.count, solved: occurrences.filter(\.isSolved).count, kinds: kinds)
    }

    static var breakdown: ErrorBreakdown {
        let severities = samples.map(\.severity)
        return ErrorBreakdown(inaccuracies: severities.filter { $0 == .inaccuracy }.count,
                              mistakes: severities.filter { $0 == .mistake }.count,
                              blunders: severities.filter { $0 == .blunder }.count,
                              analysedMoves: 112,
                              games: samples.count)
    }

    static let accuracy: Double? = 81.4
}
