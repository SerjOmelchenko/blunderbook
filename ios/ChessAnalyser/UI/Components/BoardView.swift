//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// Everything the board needs to draw one position.
struct BoardPresentation: Equatable {
    var pieces: [Piece?]
    var orientation: PieceColor = .white
    var lastMove: Move?
    /// Drawn as a translucent arrow — the move the engine preferred.
    var suggestedMove: Move?
    var checkSquare: Int?
    var evidenceSquares: [Int] = []
    var isHypothetical = false

    static let empty = BoardPresentation(pieces: [Piece?](repeating: nil, count: 64))

    static func from(board: ChessBoard,
                     orientation: PieceColor = .white,
                     lastMove: Move? = nil,
                     suggestedMove: Move? = nil,
                     evidenceSquares: [Int] = [],
                     isHypothetical: Bool = false) -> BoardPresentation {
        BoardPresentation(pieces: board.snapshot,
                          orientation: orientation,
                          lastMove: lastMove,
                          suggestedMove: suggestedMove,
                          checkSquare: board.isInCheck ? board.kingSquare(of: board.sideToMove) : nil,
                          evidenceSquares: evidenceSquares,
                          isHypothetical: isHypothetical)
    }

    /// Spoken description of the position, used as the board's accessibility label (§11).
    var accessibleDescription: String {
        var parts: [String] = ["Chess position, \(orientation.name) at the bottom."]
        for color in PieceColor.allCases {
            var byKind: [PieceKind: [String]] = [:]
            for square in 0..<64 {
                guard let piece = pieces[square], piece.color == color else { continue }
                byKind[piece.kind, default: []].append(Square.name(square))
            }
            let described = PieceKind.allCases.reversed().compactMap { kind -> String? in
                guard let squares = byKind[kind], !squares.isEmpty else { return nil }
                let name = String(describing: kind)
                return "\(name)\(squares.count > 1 ? "s" : "") on \(squares.joined(separator: ", "))"
            }
            if !described.isEmpty { parts.append("\(color.name): " + described.joined(separator: "; ") + ".") }
        }
        if let lastMove { parts.append("Last move \(Square.name(lastMove.fromSquare)) to \(Square.name(lastMove.toSquare)).") }
        return parts.joined(separator: " ")
    }
}

/// A quiet board: grey and sage squares, inset coordinates, solid pieces.
///
/// The whole board is one `Canvas`, which keeps a full position to a single view rather than a
/// hundred — the difference between a smooth move list and a stuttering one.
struct BoardView: View {
    let presentation: BoardPresentation
    var showsCoordinates = true
    /// Zero for a board that runs edge to edge.
    var cornerRadius: CGFloat = 14
    var onSquareTap: ((Int) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let square = side / 8

            Canvas { context, _ in
                draw(in: &context, square: square)
            }
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Palette.boardLight)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                // A hypothetical line is outlined so it is never mistaken for the game itself.
                if presentation.isHypothetical {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Palette.brand, lineWidth: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                if presentation.isHypothetical {
                    Text("Line")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Palette.onBrand)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Palette.brand))
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let onSquareTap else { return }
                let file = Int(location.x / square)
                let rank = Int(location.y / square)
                guard (0..<8).contains(file), (0..<8).contains(rank) else { return }
                onSquareTap(squareIndex(row: rank, column: file))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibleDescription)
    }

    /// Maps a visual row and column to a board square, honouring the orientation.
    private func squareIndex(row: Int, column: Int) -> Int {
        presentation.orientation == .white
            ? Square.make(file: column, rank: 7 - row)
            : Square.make(file: 7 - column, rank: row)
    }

    private func point(for square: Int, size: CGFloat) -> CGPoint {
        let file = Square.file(square)
        let rank = Square.rank(square)
        let column = presentation.orientation == .white ? file : 7 - file
        let row = presentation.orientation == .white ? 7 - rank : rank
        return CGPoint(x: (CGFloat(column) + 0.5) * size, y: (CGFloat(row) + 0.5) * size)
    }

    private func draw(in context: inout GraphicsContext, square size: CGFloat) {
        let highlight = presentation.lastMove
        let evidence = Set(presentation.evidenceSquares)

        for row in 0..<8 {
            for column in 0..<8 {
                let index = squareIndex(row: row, column: column)
                let rect = CGRect(x: CGFloat(column) * size, y: CGFloat(row) * size, width: size, height: size)
                let isLight = Square.isLight(index)
                context.fill(Path(rect), with: .color(isLight ? Palette.boardLight : Palette.boardDark))

                if let highlight, highlight.fromSquare == index || highlight.toSquare == index {
                    context.fill(Path(rect), with: .color(Palette.boardHighlight.opacity(isLight ? 0.45 : 0.40)))
                }
                if evidence.contains(index) {
                    context.stroke(Path(rect.insetBy(dx: 2, dy: 2)),
                                   with: .color(Palette.brass),
                                   lineWidth: 2.5)
                }
                if presentation.checkSquare == index {
                    let inset = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
                    context.fill(Path(ellipseIn: inset), with: .color(Palette.blunder.opacity(0.32)))
                }

                if showsCoordinates {
                    drawCoordinate(in: &context, index: index, rect: rect, row: row, column: column, isLight: isLight, size: size)
                }
            }
        }

        if let suggestion = presentation.suggestedMove {
            drawArrow(in: &context, move: suggestion, size: size)
        }

        drawPieces(in: &context, square: size)
    }

    private func drawCoordinate(in context: inout GraphicsContext, index: Int, rect: CGRect,
                                row: Int, column: Int, isLight: Bool, size: CGFloat) {
        let tint = isLight ? Palette.boardDark : Palette.boardLight
        let font = Font.system(size: max(7, size * 0.19), weight: .semibold)

        if row == 7 {
            let file = Character(UnicodeScalar(UInt8(97 + Square.file(index))))
            var text = context.resolve(Text(String(file)).font(font).foregroundStyle(tint))
            text.shading = .color(tint)
            context.draw(text, at: CGPoint(x: rect.maxX - size * 0.14, y: rect.maxY - size * 0.12), anchor: .center)
        }
        if column == 0 {
            var text = context.resolve(Text("\(Square.rank(index) + 1)").font(font).foregroundStyle(tint))
            text.shading = .color(tint)
            context.draw(text, at: CGPoint(x: rect.minX + size * 0.14, y: rect.minY + size * 0.13), anchor: .center)
        }
    }

    private func drawPieces(in context: inout GraphicsContext, square size: CGFloat) {
        // Resolving is per-context and not free, so each distinct piece is resolved once and
        // reused across every square it occupies rather than once per square.
        var resolved: [String: GraphicsContext.ResolvedImage] = [:]
        let side = size * 0.88

        for index in 0..<64 {
            guard let piece = presentation.pieces[index] else { continue }
            let name = piece.artworkName
            let artwork: GraphicsContext.ResolvedImage
            if let cached = resolved[name] {
                artwork = cached
            } else {
                artwork = context.resolve(Image(name))
                resolved[name] = artwork
            }
            let centre = point(for: index, size: size)
            context.draw(artwork, in: CGRect(x: centre.x - side / 2,
                                             y: centre.y - side / 2,
                                             width: side,
                                             height: side))
        }
    }

    private func drawArrow(in context: inout GraphicsContext, move: Move, size: CGFloat) {
        let start = point(for: move.fromSquare, size: size)
        let end = point(for: move.toSquare, size: size)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = size * 0.34
        let shaftEnd = CGPoint(x: end.x - cos(angle) * headLength * 0.75,
                               y: end.y - sin(angle) * headLength * 0.75)

        var shaft = Path()
        shaft.move(to: start)
        shaft.addLine(to: shaftEnd)
        context.stroke(shaft,
                       with: .color(Palette.brand.opacity(0.72)),
                       style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round))

        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - cos(angle - .pi / 7) * headLength,
                                 y: end.y - sin(angle - .pi / 7) * headLength))
        head.addLine(to: CGPoint(x: end.x - cos(angle + .pi / 7) * headLength,
                                 y: end.y - sin(angle + .pi / 7) * headLength))
        head.closeSubpath()
        context.fill(head, with: .color(Palette.brand.opacity(0.72)))
    }
}

/// Vertical evaluation bar beside the board: White's share fills from White's side, so it moves
/// with every step through the game. The figure sits at the end of whoever is better.
struct EvaluationBar: View {
    /// From White's point of view.
    let score: EngineScore
    var orientation: PieceColor = .white

    private var whiteShare: Double { max(0.03, min(0.97, Scoring.winPercent(score) / 100)) }
    private var whiteAhead: Bool { score.sortValue >= 0 }
    /// White's side of the bar is at the bottom when White is at the bottom of the board.
    private var whiteAtBottom: Bool { orientation == .white }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: whiteAtBottom ? .bottom : .top) {
                Rectangle().fill(Palette.pieceDark)
                Rectangle()
                    .fill(Palette.pieceLight)
                    .frame(height: proxy.size.height * whiteShare)
            }
            .overlay(alignment: whiteAhead == whiteAtBottom ? .bottom : .top) {
                Text(verbatim: label)
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(whiteAhead ? Palette.pieceDark : Palette.pieceLight)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.vertical, 4)
            }
        }
        .frame(width: 20)
        .animation(.easeOut(duration: 0.25), value: score)
        .accessibilityElement()
        .accessibilityLabel("Evaluation")
        .accessibilityValue(score.accessibleText)
    }

    /// Compact: one decimal, no sign — the colour of its end already says who is better.
    private var label: String {
        switch score {
        case .centipawns(let value): return String(format: "%.1f", abs(Double(value)) / 100)
        case .mate(let moves): return "M\(abs(moves))"
        case .checkmate: return "#"
        }
    }
}
