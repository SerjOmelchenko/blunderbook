//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
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
    /// Drawn as a red arrow — a move the player got wrong, shown in the position it was played in.
    var mistakeMove: Move?
    /// Drawn as a red arrow that arrives with the move — the reply that punishes the move just
    /// played, in the position after it.
    var threatMove: Move?
    /// Squares ringed as the move lands: what a pattern is about, such as the pieces a fork hits.
    var targetRings: [Int] = []
    var ringColor: Color = Palette.blunder
    /// The piece picked up on a board that takes moves, and the squares it can go to.
    var selectedSquare: Int?
    var targetSquares: [Int] = []
    var checkSquare: Int?
    var evidenceSquares: [Int] = []
    /// A small mark in the corner of a square: a deep review's verdict on the move that landed there.
    var badge: SquareBadge?
    /// The first move of each live engine line, best first.
    var lineArrows: [Move] = []
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

struct SquareBadge: Equatable {
    var square: Int
    var text: String
    var color: Color
    /// An SF Symbol drawn instead of `text`, such as the book for a book move.
    var symbol: String?
}

/// How the pieces get from one position to the next: who slides where, who is taken, and who
/// appears (a promotion). Works for a jump of several moves as well as for one.
struct PieceTravels: Equatable {
    struct Travel: Equatable {
        var piece: Piece
        var from: Int
        var to: Int
    }

    var travels: [Travel] = []
    /// Pieces that leave the board, faded out where they stood.
    var vanished: [(piece: Piece, square: Int)] = []
    /// Pieces that arrive from nowhere, faded in.
    var appeared: [(piece: Piece, square: Int)] = []
    /// Squares whose piece is drawn by the animation rather than in place.
    var moving: Set<Int> = []

    init(from old: [Piece?], to new: [Piece?]) {
        var left: [Piece: [Int]] = [:]
        for square in 0..<64 {
            if let piece = old[square], new[square] != piece { left[piece, default: []].append(square) }
        }
        for square in 0..<64 {
            guard let piece = new[square], old[square] != piece else { continue }
            moving.insert(square)
            // The nearest square this kind of piece just left: castling moves both king and rook,
            // a capture leaves the captured piece behind to fade.
            let candidates = left[piece] ?? []
            if let nearest = candidates.min(by: { Self.distance($0, square) < Self.distance($1, square) }) {
                left[piece]?.removeAll { $0 == nearest }
                travels.append(Travel(piece: piece, from: nearest, to: square))
            } else {
                appeared.append((piece, square))
            }
        }
        for (piece, squares) in left {
            for square in squares { vanished.append((piece, square)) }
        }
    }

    private static func distance(_ a: Int, _ b: Int) -> Int {
        max(abs(Square.file(a) - Square.file(b)), abs(Square.rank(a) - Square.rank(b)))
    }

    static func == (lhs: PieceTravels, rhs: PieceTravels) -> Bool {
        lhs.travels == rhs.travels && lhs.moving == rhs.moving
    }
}

/// A quiet board: grey and sage squares, inset coordinates, solid pieces.
///
/// The whole board is one `Canvas`, which keeps a full position to a single view rather than a
/// hundred — the difference between a smooth move list and a stuttering one. When the position
/// changes, the pieces slide to their new squares, taken pieces fade, and the arrow and badge
/// arrive as the move lands.
struct BoardView: View {
    let presentation: BoardPresentation
    var showsCoordinates = true
    /// Zero for a board that runs edge to edge.
    var cornerRadius: CGFloat = 14
    var onSquareTap: ((Int) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the pieces are travelling from, while they travel.
    @State private var travels: PieceTravels?
    /// Animated towards `target`; how far it has come is how far the pieces have moved.
    @State private var step: Double = 0
    @State private var target: Double = 0

    static let moveAnimation = Animation.snappy(duration: 0.24)

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let square = side / 8

            AnimatedBoardCanvas(presentation: presentation,
                                travels: travels,
                                target: target,
                                step: step,
                                showsCoordinates: showsCoordinates)
            .overlay {
                LineArrowsLayer(moves: presentation.lineArrows, orientation: presentation.orientation, square: square)
            }
            .overlay {
                TargetRingsLayer(squares: presentation.targetRings, color: presentation.ringColor,
                                 orientation: presentation.orientation, square: square)
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
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let onSquareTap else { return }
                let file = Int(location.x / square)
                let rank = Int(location.y / square)
                guard (0..<8).contains(file), (0..<8).contains(rank) else { return }
                onSquareTap(BoardGeometry(orientation: presentation.orientation).square(row: rank, column: file))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: presentation.pieces) { old, new in
            guard !reduceMotion else { travels = nil; return }
            travels = PieceTravels(from: old, to: new)
            target += 1
            withAnimation(Self.moveAnimation) { step = target }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibleDescription)
    }
}

/// The engine's best moves from the position on screen, one arrow per line. The best is the
/// boldest; each arrow fades in when its line arrives and out when the position changes.
private struct LineArrowsLayer: View {
    let moves: [Move]
    let orientation: PieceColor
    let square: CGFloat

    private struct Arrow: Identifiable {
        let rank: Int
        let move: Move
        var id: String { "\(rank)-\(move.uci)" }
    }

    var body: some View {
        let geometry = BoardGeometry(orientation: orientation)
        ZStack {
            // Drawn weakest first, so the best line's arrow sits on top where arrows cross.
            ForEach(moves.enumerated().map { Arrow(rank: $0.offset, move: $0.element) }.reversed()) { arrow in
                ArrowShape(start: geometry.centre(of: arrow.move.fromSquare, size: square),
                           end: geometry.centre(of: arrow.move.toSquare, size: square),
                           shaftWidth: square * Self.shaftWidth(rank: arrow.rank),
                           headLength: square * 0.38,
                           headWidth: square * 0.44)
                    .fill(LineArrowStyle.color(rank: arrow.rank))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: moves)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func shaftWidth(rank: Int) -> CGFloat { [0.17, 0.13, 0.11][min(rank, 2)] }
}

/// Rings around the squares a pattern is about. Each tightens onto its square as the move lands,
/// then breathes for a few seconds, so the eye finds it without the board flashing.
private struct TargetRingsLayer: View {
    let squares: [Int]
    let color: Color
    let orientation: PieceColor
    let square: CGFloat

    var body: some View {
        let geometry = BoardGeometry(orientation: orientation)
        ZStack(alignment: .topLeading) {
            ForEach(squares, id: \.self) { target in
                TargetRing(color: color, size: square)
                    .position(geometry.centre(of: target, size: square))
                    .id("\(target)-\(orientation)")
            }
        }
        .frame(width: square * 8, height: square * 8, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TargetRing: View {
    let color: Color
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasLanded = false
    @State private var breaths = 0

    var body: some View {
        Circle()
            .strokeBorder(color, lineWidth: max(2, size * 0.055))
            .shadow(color: color.opacity(0.7), radius: size * 0.12)
            .frame(width: size * 0.88, height: size * 0.88)
            .scaleEffect(hasLanded ? 1 : 1.45)
            .opacity(hasLanded ? 1 : 0)
            .phaseAnimator([1.0, 0.45], trigger: breaths) { content, opacity in
                content.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.85) }
            .task {
                // Lands with the move, then breathes three times.
                try? await Task.sleep(nanoseconds: 180_000_000)
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.45)) { hasLanded = true }
                guard !reduceMotion else { return }
                for _ in 0..<3 {
                    try? await Task.sleep(nanoseconds: 1_700_000_000)
                    breaths += 1
                }
            }
    }
}

/// How an engine line's arrow looks, shared with the line's row so the two read as a pair.
enum LineArrowStyle {
    static func color(rank: Int) -> Color { Palette.best.opacity([0.9, 0.5, 0.3][min(max(rank, 0), 2)]) }
}

/// A straight arrow as one closed outline, so a translucent fill has no darker seam.
struct ArrowShape: Shape {
    var start: CGPoint
    var end: CGPoint
    var shaftWidth: CGFloat
    var headLength: CGFloat
    var headWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = max(1, (dx * dx + dy * dy).squareRoot())
        let ux = dx / length, uy = dy / length
        // Perpendicular.
        let px = -uy, py = ux
        let neck = CGPoint(x: end.x - ux * headLength, y: end.y - uy * headLength)
        func offset(_ point: CGPoint, _ distance: CGFloat) -> CGPoint {
            CGPoint(x: point.x + px * distance, y: point.y + py * distance)
        }
        var path = Path()
        path.move(to: offset(start, shaftWidth / 2))
        path.addLine(to: offset(neck, shaftWidth / 2))
        path.addLine(to: offset(neck, headWidth / 2))
        path.addLine(to: end)
        path.addLine(to: offset(neck, -headWidth / 2))
        path.addLine(to: offset(neck, -shaftWidth / 2))
        path.addLine(to: offset(start, -shaftWidth / 2))
        path.closeSubpath()
        return path
    }
}

/// Square arithmetic for one orientation.
private struct BoardGeometry {
    let orientation: PieceColor

    /// Maps a visual row and column to a board square.
    func square(row: Int, column: Int) -> Int {
        orientation == .white
            ? Square.make(file: column, rank: 7 - row)
            : Square.make(file: 7 - column, rank: row)
    }

    func centre(of square: Int, size: CGFloat) -> CGPoint {
        let file = Square.file(square)
        let rank = Square.rank(square)
        let column = orientation == .white ? file : 7 - file
        let row = orientation == .white ? 7 - rank : rank
        return CGPoint(x: (CGFloat(column) + 0.5) * size, y: (CGFloat(row) + 0.5) * size)
    }
}

/// Draws the board at one instant of a move animation. SwiftUI interpolates `step`, and the
/// canvas redraws for each frame.
private struct AnimatedBoardCanvas: View, Animatable {
    var presentation: BoardPresentation
    var travels: PieceTravels?
    var target: Double
    var step: Double
    var showsCoordinates: Bool

    var animatableData: Double {
        get { step }
        set { step = newValue }
    }

    /// 0 when the pieces leave, 1 when they have landed.
    private var progress: Double { travels == nil ? 1 : max(0, min(1, 1 - (target - step))) }
    private var geometry: BoardGeometry { BoardGeometry(orientation: presentation.orientation) }

    var body: some View {
        Canvas { context, size in
            draw(in: &context, square: size.width / 8)
        }
    }

    private func draw(in context: inout GraphicsContext, square size: CGFloat) {
        let highlight = presentation.lastMove
        let evidence = Set(presentation.evidenceSquares)

        for row in 0..<8 {
            for column in 0..<8 {
                let index = geometry.square(row: row, column: column)
                let rect = CGRect(x: CGFloat(column) * size, y: CGFloat(row) * size, width: size, height: size)
                let isLight = Square.isLight(index)
                context.fill(Path(rect), with: .color(isLight ? Palette.boardLight : Palette.boardDark))

                if let highlight, highlight.fromSquare == index || highlight.toSquare == index {
                    context.fill(Path(rect), with: .color(Palette.boardHighlight.opacity(isLight ? 0.45 : 0.40)))
                }
                if presentation.selectedSquare == index {
                    context.fill(Path(rect), with: .color(Palette.brand.opacity(0.45)))
                }
                if evidence.contains(index) {
                    context.stroke(Path(rect.insetBy(dx: 2, dy: 2)),
                                   with: .color(Palette.brass.opacity(progress)),
                                   lineWidth: 2.5)
                }
                if presentation.checkSquare == index {
                    let inset = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
                    context.fill(Path(ellipseIn: inset), with: .color(Palette.declined.opacity(0.32 * progress)))
                }

                if showsCoordinates {
                    drawCoordinate(in: &context, index: index, rect: rect, row: row, column: column, isLight: isLight, size: size)
                }
            }
        }

        drawPieces(in: &context, square: size)
        drawTargets(in: &context, square: size)

        // The verdict arrives once the move has landed.
        let arrival = max(0, (progress - 0.55) / 0.45)
        if let suggestion = presentation.suggestedMove {
            var faded = context
            faded.opacity = arrival
            drawArrow(in: &faded, move: suggestion, size: size, color: Palette.brand.opacity(0.72))
        }
        if let mistake = presentation.mistakeMove {
            drawArrow(in: &context, move: mistake, size: size, color: Palette.blunder.opacity(0.8))
        }
        if let threat = presentation.threatMove {
            // A beat after the better move, so the two read in order: what to play, what it cost.
            var faded = context
            faded.opacity = max(0, (arrival - 0.25) / 0.75)
            drawArrow(in: &faded, move: threat, size: size, color: Palette.blunder.opacity(0.82))
        }
        if let badge = presentation.badge {
            drawBadge(in: &context, badge: badge, size: size, arrival: arrival)
        }
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

        func draw(_ piece: Piece, at centre: CGPoint, opacity: Double = 1) {
            let name = piece.artworkName
            let artwork: GraphicsContext.ResolvedImage
            if let cached = resolved[name] {
                artwork = cached
            } else {
                artwork = context.resolve(Image(name))
                resolved[name] = artwork
            }
            var layer = context
            layer.opacity = opacity
            layer.draw(artwork, in: CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side))
        }

        let travels = progress < 1 ? self.travels : nil
        for index in 0..<64 {
            guard let piece = presentation.pieces[index], travels?.moving.contains(index) != true else { continue }
            draw(piece, at: geometry.centre(of: index, size: size))
        }
        guard let travels else { return }

        // Taken pieces fade under the piece that takes them; promotions fade in.
        for (piece, square) in travels.vanished {
            draw(piece, at: geometry.centre(of: square, size: size), opacity: 1 - progress)
        }
        for (piece, square) in travels.appeared {
            draw(piece, at: geometry.centre(of: square, size: size), opacity: progress)
        }
        for travel in travels.travels {
            let from = geometry.centre(of: travel.from, size: size)
            let to = geometry.centre(of: travel.to, size: size)
            draw(travel.piece, at: CGPoint(x: from.x + (to.x - from.x) * progress,
                                           y: from.y + (to.y - from.y) * progress))
        }
    }

    /// A dot on each square the selected piece can move to; a ring around a piece it can take.
    private func drawTargets(in context: inout GraphicsContext, square size: CGFloat) {
        for target in presentation.targetSquares {
            let centre = geometry.centre(of: target, size: size)
            if presentation.pieces[target] != nil {
                let radius = size * 0.46
                context.stroke(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                      width: radius * 2, height: radius * 2)),
                               with: .color(Color.black.opacity(0.28)), lineWidth: size * 0.08)
            } else {
                let radius = size * 0.15
                context.fill(Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                    width: radius * 2, height: radius * 2)),
                             with: .color(Color.black.opacity(0.28)))
            }
        }
    }

    private func drawArrow(in context: inout GraphicsContext, move: Move, size: CGFloat, color: Color) {
        let start = geometry.centre(of: move.fromSquare, size: size)
        let end = geometry.centre(of: move.toSquare, size: size)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = size * 0.34
        let shaftEnd = CGPoint(x: end.x - cos(angle) * headLength * 0.75,
                               y: end.y - sin(angle) * headLength * 0.75)

        var shaft = Path()
        shaft.move(to: start)
        shaft.addLine(to: shaftEnd)
        context.stroke(shaft,
                       with: .color(color),
                       style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round))

        var head = Path()
        head.move(to: end)
        head.addLine(to: CGPoint(x: end.x - cos(angle - .pi / 7) * headLength,
                                 y: end.y - sin(angle - .pi / 7) * headLength))
        head.addLine(to: CGPoint(x: end.x - cos(angle + .pi / 7) * headLength,
                                 y: end.y - sin(angle + .pi / 7) * headLength))
        head.closeSubpath()
        context.fill(head, with: .color(color))
    }

    /// A round mark over the top-right corner of the square, popping in as the move lands.
    private func drawBadge(in context: inout GraphicsContext, badge: SquareBadge, size: CGFloat, arrival: Double) {
        guard arrival > 0 else { return }
        let centre = geometry.centre(of: badge.square, size: size)
        // A slight overshoot, then settle.
        let scale = arrival < 0.7 ? arrival / 0.7 * 1.15 : 1.15 - (arrival - 0.7) / 0.3 * 0.15
        let radius = size * 0.2 * scale
        let point = CGPoint(x: centre.x + size * 0.36, y: centre.y - size * 0.36)
        let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        context.fill(circle, with: .color(badge.color))
        context.stroke(circle, with: .color(Color.black.opacity(0.35)), lineWidth: 1)
        let label = badge.symbol.map { Text(Image(systemName: $0)) } ?? Text(badge.text)
        let text = context.resolve(label
            .font(.system(size: max(7, size * (badge.symbol == nil ? 0.19 : 0.16) * scale), weight: .heavy))
            .foregroundStyle(Palette.onBrand))
        context.draw(text, at: point, anchor: .center)
    }
}

/// The evaluation as a thin horizontal line over the board: the colour of the side at the bottom
/// of the board fills from the left, so the line grows as that side gets better. The figure
/// beside it is Stockfish's, from White's point of view.
struct EvaluationLine: View {
    /// From White's point of view.
    let score: EngineScore
    var orientation: PieceColor = .white
    /// Dims the line while there is no evaluation yet.
    var isSettled = true

    private var whiteShare: Double { max(0.02, min(0.98, Scoring.winPercent(score) / 100)) }
    /// The share of the side at the bottom of the board, which fills from the left.
    private var leftShare: Double { orientation == .white ? whiteShare : 1 - whiteShare }

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: score.displayText)
                .font(.footnote.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Palette.ink)
                .contentTransition(.numericText(value: Double(score.sortValue)))
                .frame(width: 52, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(orientation == .white ? Palette.pieceDark : Palette.pieceLight)
                    Capsule()
                        .fill(orientation == .white ? Palette.pieceLight : Palette.pieceDark)
                        .frame(width: proxy.size.width * leftShare)
                    // Level, for reference.
                    Rectangle()
                        .fill(Palette.brand.opacity(0.8))
                        .frame(width: 1.5)
                        .offset(x: proxy.size.width / 2 - 0.75)
                }
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            .frame(height: 6)
        }
        .opacity(isSettled ? 1 : 0.5)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: score)
        .animation(.easeOut(duration: 0.2), value: isSettled)
        .accessibilityElement()
        .accessibilityLabel("Evaluation")
        .accessibilityValue(score.accessibleText)
    }
}
