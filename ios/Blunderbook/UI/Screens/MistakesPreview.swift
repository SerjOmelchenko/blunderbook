//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
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
    @State private var focus: MistakeFocus?
    @State private var solved: Set<String> = SampleMistakes.initiallySolved
    @State private var isPurchasing = false
    @State private var purchaseOutcome: PurchaseOutcome?

    private var book: MistakeBook { MistakeBook(occurrences: SampleMistakes.occurrences(solved: solved)) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    intro
                    features
                    HStack(spacing: 8) {
                        Text("Try it on sample games").eyebrowStyle()
                        Spacer(minLength: 0)
                        Badge(text: "Sample", tone: Palette.brass)
                    }
                    .padding(.top, 4)
                    MistakesContent(book: book,
                                    selectedKind: $selectedKind.animation(.smooth(duration: 0.2)),
                                    focus: $focus.animation(.smooth(duration: 0.2)),
                                    navigate: { path.append($0) })
                }
                .padding(Layout.gutter)
                .padding(.bottom, 12)
            }
            .task { await DevelopmentScroll.apply(reader) }
            }
            .screenBackground()
            .safeAreaInset(edge: .bottom, spacing: 0) { unlockBar }
            .navigationTitle("Mistakes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .navigationDestination(for: Route.self, destination: destination)
        }
        .task { await model.entitlement.refreshTrialEligibility() }
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
                        "Find a better move; the engine checks it. Hints if you need them.")
                feature("arrow.triangle.2.circlepath", "Until it sticks",
                        "Solved ones come back after 3, 10 and 30 days.")
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

    /// Pinned under the list, never over it. While the account can still have the free trial,
    /// starting it goes straight to Apple's sheet and Subscribe opens the plan to read first;
    /// Apple gives the trial to either, so they never buy different things. With the trial
    /// used, Subscribe buys the plan directly.
    private var unlockBar: some View {
        VStack(spacing: 8) {
            // Backing out of Apple's sheet needs no note.
            if let purchaseOutcome, purchaseOutcome != .purchased, purchaseOutcome != .cancelled {
                PurchaseOutcomeBanner(outcome: purchaseOutcome)
            }
            if let length = model.entitlement.freeTrialLength {
                Button { Task { await purchase() } } label: { purchaseLabel("Start \(length) free trial") }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isPurchasing)
                Button("Subscribe") { showPaywall() }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isPurchasing)
            } else if model.entitlement.product != nil {
                Button { Task { await purchase() } } label: {
                    purchaseLabel("Subscribe \u{00B7} \(model.entitlement.priceDescription)")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isPurchasing)
            } else {
                // The App Store has not answered: the plan screen says why and can retry.
                Button("Unlock with Premium") { showPaywall() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            PlanTermsNote()
        }
        .padding(.horizontal, Layout.gutter)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Palette.background)
        .animation(.smooth(duration: 0.2), value: purchaseOutcome)
    }

    @ViewBuilder
    private func purchaseLabel(_ title: String) -> some View {
        if isPurchasing { ProgressView().tint(Palette.onBrand) } else { Text(title) }
    }

    /// Success needs nothing here: the tab unlocks and the sheet hands over to it.
    private func purchase() async {
        isPurchasing = true
        purchaseOutcome = nil
        purchaseOutcome = await model.purchasePremium()
        isPurchasing = false
    }

    private func tick(_ solvedOne: MistakeOccurrence) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { _ = solved.insert(solvedOne.id) }
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .mistakeDrill(let occurrence):
            MistakeDrillScreen(occurrence: occurrence, onSampleSolved: tick)
        case .training(let queue):
            MistakeDrillScreen(queue: queue, onSampleSolved: tick)
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
        /// How long the move took, and the clock after it, in a 5-minute game.
        var spent: TimeInterval
        var remaining: TimeInterval
        var opening: String
        var scoreAfter: EngineScore
    }

    static let samples: [Sample] = [
        Sample(gameKey: "sample-backrank", ply: 48, fen: "6k1/5ppp/8/8/8/8/1q3PPP/3R2K1 w - - 0 25",
               played: "h2h3", san: "h3", best: "d1d8", bestSAN: "Rd8#", score: .mate(1),
               severity: .blunder, phase: .endgame, kinds: [.pattern(.missedMate)],
               opponent: "tempo_tina", daysAgo: 1,
               explanation: "Rd8 was mate on the back rank.",
               spent: 3, remaining: 41, opening: "Queen's Gambit Declined", scoreAfter: .centipawns(-480)),
        Sample(gameKey: "sample-ng5", ply: 4, fen: "rnbqkbnr/ppp2ppp/3p4/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 0 3",
               played: "f3g5", san: "Ng5", best: "d2d4", bestSAN: "d4", score: .centipawns(40),
               severity: .blunder, phase: .opening, kinds: [.pattern(.undefendedPiece)],
               opponent: "gambit_gus", daysAgo: 2,
               explanation: "The knight on g5 is undefended, and the queen takes it.",
               spent: 2, remaining: 288, opening: "Philidor Defense", scoreAfter: .centipawns(-310)),
        Sample(gameKey: "sample-nxe5", ply: 5, fen: "r1bqkbnr/pppp1ppp/2n5/4N3/4P3/8/PPPP1PPP/RNBQKB1R b KQkq - 0 3",
               played: "g8f6", san: "Nf6", best: "c6e5", bestSAN: "Nxe5", score: .centipawns(-250),
               severity: .blunder, phase: .opening, kinds: [.pattern(.missedCapture)],
               opponent: "rookie_rook", daysAgo: 3,
               explanation: "The knight on e5 was free to take.",
               spent: 6, remaining: 276, opening: "Petrov Defense", scoreAfter: .centipawns(-110)),
        Sample(gameKey: "sample-friedliver", ply: 7, fen: "r1bqkb1r/pppp1ppp/2n2n2/4p1N1/2B1P3/8/PPPP1PPP/RNBQK2R b KQkq - 5 4",
               played: "h7h6", san: "h6", best: "d7d5", bestSAN: "d5", score: .centipawns(30),
               severity: .mistake, phase: .opening, kinds: [.pattern(.allowedFork)],
               opponent: "endgame_ed", daysAgo: 5,
               explanation: "Nxf7 forks the queen and the rook.",
               spent: 48, remaining: 201, opening: "Italian Game Two Knights Defense", scoreAfter: .centipawns(-160)),
        Sample(gameKey: "sample-scholar", ply: 5, fen: "r1bqkbnr/pppp1ppp/2n5/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR b KQkq - 3 3",
               played: "g8f6", san: "Nf6", best: "d8e7", bestSAN: "Qe7", score: .centipawns(-20),
               severity: .blunder, phase: .opening, kinds: [.pattern(.allowedMate)],
               opponent: "pawnstorm_ana", daysAgo: 7,
               explanation: "Qxf7 is mate.",
               spent: 1, remaining: 292, opening: "Italian Game", scoreAfter: .mate(-1)),
        Sample(gameKey: "sample-najdorf", ply: 8, fen: "rnbqkb1r/pp2pppp/3p1n2/8/3NP3/8/PPP2PPP/RNBQKB1R w KQkq - 1 5",
               played: "f1d3", san: "Bd3", best: "b1c3", bestSAN: "Nc3", score: .centipawns(40),
               severity: .inaccuracy, phase: .opening, kinds: [.outcome(.evaluationLoss)],
               opponent: "tempo_tina", daysAgo: 9,
               explanation: "Nc3 defends e4 and develops a piece.",
               spent: 21, remaining: 240, opening: "Sicilian Defense Najdorf Variation", scoreAfter: .centipawns(-30)),
    ]

    /// One is already solved, to show what that looks like.
    static let initiallySolved: Set<String> = ["sample-nxe5#5"]

    static func occurrences(solved: Set<String>, now: Date = Date()) -> [MistakeOccurrence] {
        samples.map { sample -> MistakeOccurrence in
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
                                     kinds: sample.kinds,
                                     loss: sample.severity == .blunder ? 30 : sample.severity == .mistake ? 14 : 7,
                                     scoreAfter: sample.scoreAfter.normalizedToWhite(mover: color),
                                     bestLineUCI: [sample.best],
                                     clock: MistakeClock(spent: sample.spent, remaining: sample.remaining, lowTime: 30, base: 300),
                                     openingName: sample.opening,
                                     // A solved sample comes back in three days, as a first clean solve would.
                                     review: solved.contains("\(sample.gameKey)#\(sample.ply)")
                                        ? MistakeReview(drills: 1, streak: 1, firstResult: "clean", lastResult: .clean,
                                                        lastAt: now, dueAt: now.addingTimeInterval(3 * 86_400))
                                        : nil)
        }
    }

    /// Counted the way the real backlog is: patterns first, then consequences, most frequent first.
    static func backlog(of occurrences: [MistakeOccurrence]) -> MistakeBacklog {
        MistakeBacklog(counting: occurrences)
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
