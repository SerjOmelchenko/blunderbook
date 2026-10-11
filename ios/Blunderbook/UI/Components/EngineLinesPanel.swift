//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// The engine's live lines for the position on the board, three compact rows. Always three rows
/// tall, so a finished game or a warm phone never resizes the board above it.
struct EngineLinesPanel: View {
    let lines: LiveLinesModel
    /// Heat stops the engine (§7), so the lines stop too.
    var isTooHot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isTooHot {
                message("Engine lines pause while the phone is too warm.")
            } else if lines.lines.isEmpty && !lines.isCalculating {
                message("No moves from here: the game is over.")
            } else if lines.lines.isEmpty {
                ForEach(0..<LiveLinesModel.lineCount, id: \.self) { _ in
                    EngineLineRow(score: .centipawns(0), notation: "1. e4 e5 2. Nf3 Nc6 3. Bb5 a6")
                        .redacted(reason: .placeholder)
                }
            } else {
                ForEach(lines.lines) { line in
                    EngineLineRow(score: line.score, notation: line.notation, rank: line.rank)
                }
            }
        }
        .frame(height: Self.height, alignment: .top)
        .opacity(lines.isCalculating && !lines.lines.isEmpty ? 0.5 : 1)
        .animation(.easeOut(duration: 0.18), value: lines.isCalculating)
        .animation(.easeOut(duration: 0.2), value: lines.lines)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Engine lines")
    }

    static let height = CGFloat(LiveLinesModel.lineCount) * 26 + CGFloat(LiveLinesModel.lineCount - 1) * 2

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Palette.inkSecondary)
            .frame(minHeight: 26)
    }
}

/// One engine line: its colour mark (matching its arrow on the board), its score and its moves.
struct EngineLineRow: View {
    let score: EngineScore
    let notation: String
    var rank: Int?

    var body: some View {
        let whiteAhead = score.sortValue >= 0
        HStack(spacing: 8) {
            Capsule()
                .fill(rank.map(LineArrowStyle.color(rank:)) ?? .clear)
                .frame(width: 3, height: 16)
            Text(verbatim: score.displayText)
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(score.sortValue)))
                .foregroundStyle(whiteAhead ? Palette.pieceDark : Palette.ink)
                .frame(width: 46, height: 19)
                .background(Capsule().fill(whiteAhead ? Palette.pieceLight : Color.white.opacity(0.12)))
            Text(verbatim: notation)
                .font(.footnote)
                .foregroundStyle(Palette.ink.opacity(0.88))
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(score.accessibleText): \(notation)")
    }
}
