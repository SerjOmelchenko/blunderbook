//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import Foundation

/// Mutable chess position with make/unmake, used by both the rules layer and the search.
///
/// One implementation serves the whole app: the UI replays a game through the same generator
/// the engine searches with, so a line the user can step through is always a legal line.
///
/// Squares are stored as `Int8`: `0` empty, positive white, negative black, magnitude equal to
/// `PieceKind.rawValue`.
final class ChessBoard {
    private(set) var squares: ContiguousArray<Int8>
    private(set) var sideToMove: PieceColor
    private(set) var castlingRights: CastlingRights
    /// Target square of a possible en passant capture, or -1.
    private(set) var enPassantSquare: Int
    private(set) var halfmoveClock: Int
    private(set) var fullmoveNumber: Int
    private(set) var whiteKingSquare: Int
    private(set) var blackKingSquare: Int
    private(set) var zobrist: UInt64

    /// Position keys for every ply reached so far, including the current one.
    private(set) var repetitionKeys: [UInt64]
    /// The FEN this board was loaded from, before any move was made.
    private(set) var initialFEN: String = ChessBoard.startFEN
    private var undoStack: [Undo] = []

    private struct Undo {
        var isNull: Bool = false
        var move: Move
        var capturedPiece: Int8
        var capturedSquare: Int
        var castlingRights: CastlingRights
        var enPassantSquare: Int
        var halfmoveClock: Int
        var fullmoveNumber: Int
        var whiteKingSquare: Int
        var blackKingSquare: Int
        var zobrist: UInt64
    }

    static let startFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    // MARK: - Construction

    init() {
        squares = ContiguousArray(repeating: 0, count: 64)
        sideToMove = .white
        castlingRights = .all
        enPassantSquare = -1
        halfmoveClock = 0
        fullmoveNumber = 1
        whiteKingSquare = 4
        blackKingSquare = 60
        zobrist = 0
        repetitionKeys = []
        setStartPosition()
    }

    convenience init?(fen: String) {
        self.init()
        guard loadFEN(fen) else { return nil }
    }

    func copy() -> ChessBoard {
        let board = ChessBoard()
        board.squares = squares
        board.sideToMove = sideToMove
        board.castlingRights = castlingRights
        board.enPassantSquare = enPassantSquare
        board.halfmoveClock = halfmoveClock
        board.fullmoveNumber = fullmoveNumber
        board.whiteKingSquare = whiteKingSquare
        board.blackKingSquare = blackKingSquare
        board.zobrist = zobrist
        board.repetitionKeys = repetitionKeys
        board.initialFEN = initialFEN
        board.undoStack = undoStack
        return board
    }

    private func setStartPosition() {
        _ = loadFEN(ChessBoard.startFEN)
    }

    // MARK: - FEN

    @discardableResult
    func loadFEN(_ fen: String) -> Bool {
        let fields = fen.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard fields.count >= 2 else { return false }

        var newSquares = ContiguousArray<Int8>(repeating: 0, count: 64)
        var rank = 7
        var file = 0
        for character in fields[0] {
            if character == "/" {
                guard file == 8 else { return false }
                rank -= 1
                file = 0
                guard rank >= 0 else { return false }
            } else if let digit = character.wholeNumberValue, (1...8).contains(digit) {
                file += digit
                guard file <= 8 else { return false }
            } else if let kind = PieceKind.fromLetter(character) {
                guard file < 8 else { return false }
                let isWhite = character.isUppercase
                newSquares[Square.make(file: file, rank: rank)] = Int8(kind.rawValue) * (isWhite ? 1 : -1)
                file += 1
            } else {
                return false
            }
        }
        guard rank == 0, file == 8 else { return false }

        guard let side = fields[1].first, side == "w" || side == "b" else { return false }
        var rights: CastlingRights = []
        if fields.count > 2 {
            for character in fields[2] {
                switch character {
                case "K": rights.insert(.whiteKing)
                case "Q": rights.insert(.whiteQueen)
                case "k": rights.insert(.blackKing)
                case "q": rights.insert(.blackQueen)
                case "-": break
                default: return false
                }
            }
        }

        squares = newSquares
        sideToMove = side == "w" ? .white : .black
        castlingRights = rights
        enPassantSquare = fields.count > 3 ? (Square.parse(fields[3]) ?? -1) : -1
        halfmoveClock = fields.count > 4 ? (Int(fields[4]) ?? 0) : 0
        fullmoveNumber = fields.count > 5 ? (Int(fields[5]) ?? 1) : 1
        whiteKingSquare = -1
        blackKingSquare = -1
        for square in 0..<64 {
            if squares[square] == Int8(PieceKind.king.rawValue) { whiteKingSquare = square }
            if squares[square] == -Int8(PieceKind.king.rawValue) { blackKingSquare = square }
        }
        guard whiteKingSquare >= 0, blackKingSquare >= 0 else { return false }
        undoStack.removeAll()
        initialFEN = fen
        zobrist = computeZobrist()
        repetitionKeys = [zobrist]
        return true
    }

    var fen: String {
        var text = ""
        for rank in stride(from: 7, through: 0, by: -1) {
            var run = 0
            for file in 0..<8 {
                let value = squares[Square.make(file: file, rank: rank)]
                if value == 0 {
                    run += 1
                } else {
                    if run > 0 { text += String(run); run = 0 }
                    text.append(piece(at: Square.make(file: file, rank: rank))!.fenCharacter)
                }
            }
            if run > 0 { text += String(run) }
            if rank > 0 { text += "/" }
        }
        text += " \(sideToMove == .white ? "w" : "b")"
        text += " \(castlingRights.fenText)"
        text += " \(enPassantSquare >= 0 ? Square.name(enPassantSquare) : "-")"
        text += " \(halfmoveClock) \(fullmoveNumber)"
        return text
    }

    // MARK: - Reading the board

    func piece(at square: Int) -> Piece? {
        let value = squares[square]
        guard value != 0 else { return nil }
        let kind = PieceKind(rawValue: Int(abs(value)))!
        return Piece(color: value > 0 ? .white : .black, kind: kind)
    }

    /// Immutable snapshot for rendering.
    var snapshot: [Piece?] { (0..<64).map { piece(at: $0) } }

    func kingSquare(of color: PieceColor) -> Int { color == .white ? whiteKingSquare : blackKingSquare }

    var isInCheck: Bool { isAttacked(kingSquare(of: sideToMove), by: sideToMove.opposite) }

    func isInCheck(_ color: PieceColor) -> Bool { isAttacked(kingSquare(of: color), by: color.opposite) }

    // MARK: - Attack detection

    func isAttacked(_ square: Int, by color: PieceColor) -> Bool {
        let sign = color.sign

        // Pawns: a pawn of `color` attacks `square` from the squares that a pawn of the
        // opposite colour standing on `square` would attack.
        for origin in ChessTables.pawnAttacks[color.opposite.rawValue][square] where squares[origin] == sign * Int8(PieceKind.pawn.rawValue) {
            return true
        }
        for origin in ChessTables.knightTargets[square] where squares[origin] == sign * Int8(PieceKind.knight.rawValue) {
            return true
        }
        for origin in ChessTables.kingTargets[square] where squares[origin] == sign * Int8(PieceKind.king.rawValue) {
            return true
        }
        for direction in ChessTables.rookDirections {
            for candidate in ChessTables.rays[direction][square] {
                let value = squares[candidate]
                if value == 0 { continue }
                if value * sign > 0 {
                    let kind = abs(value)
                    if kind == Int8(PieceKind.rook.rawValue) || kind == Int8(PieceKind.queen.rawValue) { return true }
                }
                break
            }
        }
        for direction in ChessTables.bishopDirections {
            for candidate in ChessTables.rays[direction][square] {
                let value = squares[candidate]
                if value == 0 { continue }
                if value * sign > 0 {
                    let kind = abs(value)
                    if kind == Int8(PieceKind.bishop.rawValue) || kind == Int8(PieceKind.queen.rawValue) { return true }
                }
                break
            }
        }
        return false
    }

    /// Squares occupied by `color` pieces that attack `square`.
    func attackers(of square: Int, by color: PieceColor) -> [Int] {
        var result: [Int] = []
        let sign = color.sign
        for origin in ChessTables.pawnAttacks[color.opposite.rawValue][square] where squares[origin] == sign * Int8(PieceKind.pawn.rawValue) {
            result.append(origin)
        }
        for origin in ChessTables.knightTargets[square] where squares[origin] == sign * Int8(PieceKind.knight.rawValue) {
            result.append(origin)
        }
        for origin in ChessTables.kingTargets[square] where squares[origin] == sign * Int8(PieceKind.king.rawValue) {
            result.append(origin)
        }
        for direction in 0..<8 {
            let isRookRay = ChessTables.rookDirections.contains(direction)
            for candidate in ChessTables.rays[direction][square] {
                let value = squares[candidate]
                if value == 0 { continue }
                if value * sign > 0 {
                    let kind = abs(value)
                    let matches = kind == Int8(PieceKind.queen.rawValue)
                        || (isRookRay && kind == Int8(PieceKind.rook.rawValue))
                        || (!isRookRay && kind == Int8(PieceKind.bishop.rawValue))
                    if matches { result.append(candidate) }
                }
                break
            }
        }
        return result
    }

    // MARK: - Move generation

    func legalMoves() -> [Move] {
        var buffer: [Move] = []
        buffer.reserveCapacity(48)
        generatePseudoLegalMoves(into: &buffer)
        return buffer.filter { isLegal($0) }
    }

    /// Whether a pseudo-legal move leaves the mover's king safe.
    func isLegal(_ move: Move) -> Bool {
        let mover = sideToMove
        makeMove(move)
        let safe = !isInCheck(mover)
        unmakeMove()
        return safe
    }

    /// Whether `move` is one of the legal moves in this position.
    func isLegalMove(_ move: Move) -> Bool {
        var buffer: [Move] = []
        generatePseudoLegalMoves(into: &buffer)
        guard buffer.contains(move) else { return false }
        return isLegal(move)
    }

    func generatePseudoLegalMoves(into buffer: inout [Move], capturesOnly: Bool = false) {
        buffer.removeAll(keepingCapacity: true)
        let sign = sideToMove.sign
        let pawnValue = Int8(PieceKind.pawn.rawValue)

        for origin in 0..<64 {
            let value = squares[origin]
            guard value != 0, value * sign > 0 else { continue }
            let kind = PieceKind(rawValue: Int(abs(value)))!

            switch kind {
            case .pawn:
                let forward = sideToMove == .white ? 8 : -8
                let startRank = sideToMove == .white ? 1 : 6
                let promotionRank = sideToMove == .white ? 7 : 0
                let oneStep = origin + forward
                if (0..<64).contains(oneStep), squares[oneStep] == 0 {
                    let promotes = Square.rank(oneStep) == promotionRank
                    if !capturesOnly || promotes {
                        appendPawnMove(from: origin, to: oneStep, promotionRank: promotionRank, into: &buffer)
                    }
                    if !capturesOnly, Square.rank(origin) == startRank, squares[oneStep + forward] == 0 {
                        buffer.append(Move(from: origin, to: oneStep + forward))
                    }
                }
                for target in ChessTables.pawnAttacks[sideToMove.rawValue][origin] {
                    let occupant = squares[target]
                    if occupant != 0, occupant * sign < 0 {
                        appendPawnMove(from: origin, to: target, promotionRank: promotionRank, into: &buffer)
                    } else if target == enPassantSquare, occupant == 0 {
                        buffer.append(Move(from: origin, to: target))
                    }
                }
                _ = pawnValue

            case .knight:
                for target in ChessTables.knightTargets[origin] {
                    let occupant = squares[target]
                    if occupant == 0 {
                        if !capturesOnly { buffer.append(Move(from: origin, to: target)) }
                    } else if occupant * sign < 0 {
                        buffer.append(Move(from: origin, to: target))
                    }
                }

            case .king:
                for target in ChessTables.kingTargets[origin] {
                    let occupant = squares[target]
                    if occupant == 0 {
                        if !capturesOnly { buffer.append(Move(from: origin, to: target)) }
                    } else if occupant * sign < 0 {
                        buffer.append(Move(from: origin, to: target))
                    }
                }
                if !capturesOnly { appendCastlingMoves(from: origin, into: &buffer) }

            case .bishop, .rook, .queen:
                let directions: Range<Int>
                switch kind {
                case .bishop: directions = ChessTables.bishopDirections
                case .rook: directions = ChessTables.rookDirections
                default: directions = 0..<8
                }
                for direction in directions {
                    for target in ChessTables.rays[direction][origin] {
                        let occupant = squares[target]
                        if occupant == 0 {
                            if !capturesOnly { buffer.append(Move(from: origin, to: target)) }
                        } else {
                            if occupant * sign < 0 { buffer.append(Move(from: origin, to: target)) }
                            break
                        }
                    }
                }
            }
        }
    }

    private func appendPawnMove(from origin: Int, to target: Int, promotionRank: Int, into buffer: inout [Move]) {
        if Square.rank(target) == promotionRank {
            for kind in [PieceKind.queen, .rook, .bishop, .knight] {
                buffer.append(Move(from: origin, to: target, promotion: kind))
            }
        } else {
            buffer.append(Move(from: origin, to: target))
        }
    }

    private func appendCastlingMoves(from origin: Int, into buffer: inout [Move]) {
        let opponent = sideToMove.opposite
        guard !isAttacked(origin, by: opponent) else { return }
        let homeRank = sideToMove == .white ? 0 : 7
        guard origin == Square.make(file: 4, rank: homeRank) else { return }
        let kingSide: CastlingRights = sideToMove == .white ? .whiteKing : .blackKing
        let queenSide: CastlingRights = sideToMove == .white ? .whiteQueen : .blackQueen
        let rookValue = sideToMove.sign * Int8(PieceKind.rook.rawValue)

        if castlingRights.contains(kingSide),
           squares[Square.make(file: 7, rank: homeRank)] == rookValue,
           squares[Square.make(file: 5, rank: homeRank)] == 0,
           squares[Square.make(file: 6, rank: homeRank)] == 0,
           !isAttacked(Square.make(file: 5, rank: homeRank), by: opponent) {
            buffer.append(Move(from: origin, to: Square.make(file: 6, rank: homeRank)))
        }
        if castlingRights.contains(queenSide),
           squares[Square.make(file: 0, rank: homeRank)] == rookValue,
           squares[Square.make(file: 1, rank: homeRank)] == 0,
           squares[Square.make(file: 2, rank: homeRank)] == 0,
           squares[Square.make(file: 3, rank: homeRank)] == 0,
           !isAttacked(Square.make(file: 3, rank: homeRank), by: opponent) {
            buffer.append(Move(from: origin, to: Square.make(file: 2, rank: homeRank)))
        }
    }

    // MARK: - Move classification helpers

    func isCapture(_ move: Move) -> Bool {
        if squares[move.toSquare] != 0 { return true }
        return isEnPassant(move)
    }

    func isEnPassant(_ move: Move) -> Bool {
        guard abs(squares[move.fromSquare]) == Int8(PieceKind.pawn.rawValue) else { return false }
        return move.toSquare == enPassantSquare && squares[move.toSquare] == 0
    }

    func isCastling(_ move: Move) -> Bool {
        guard abs(squares[move.fromSquare]) == Int8(PieceKind.king.rawValue) else { return false }
        return abs(Square.file(move.toSquare) - Square.file(move.fromSquare)) == 2
    }

    // MARK: - Make and unmake

    private func updateRookCastlingRights(_ square: Int) {
        switch square {
        case 0: castlingRights.subtract(.whiteQueen)
        case 7: castlingRights.subtract(.whiteKing)
        case 56: castlingRights.subtract(.blackQueen)
        case 63: castlingRights.subtract(.blackKing)
        default: break
        }
    }

    func makeMove(_ move: Move) {
        let origin = move.fromSquare
        let target = move.toSquare
        let moving = squares[origin]
        let movingKind = PieceKind(rawValue: Int(abs(moving)))!
        let color = sideToMove

        var capturedSquare = target
        if movingKind == .pawn, target == enPassantSquare, squares[target] == 0 {
            capturedSquare = color == .white ? target - 8 : target + 8
        }
        let captured = squares[capturedSquare]

        undoStack.append(Undo(move: move,
                              capturedPiece: captured,
                              capturedSquare: capturedSquare,
                              castlingRights: castlingRights,
                              enPassantSquare: enPassantSquare,
                              halfmoveClock: halfmoveClock,
                              fullmoveNumber: fullmoveNumber,
                              whiteKingSquare: whiteKingSquare,
                              blackKingSquare: blackKingSquare,
                              zobrist: zobrist))

        if captured != 0 { squares[capturedSquare] = 0 }
        squares[origin] = 0
        if let promotion = move.promotion {
            squares[target] = color.sign * Int8(promotion.rawValue)
        } else {
            squares[target] = moving
        }

        if movingKind == .king {
            if color == .white { whiteKingSquare = target } else { blackKingSquare = target }
            if abs(Square.file(target) - Square.file(origin)) == 2 {
                let homeRank = Square.rank(origin)
                let isKingSide = Square.file(target) == 6
                let rookFrom = Square.make(file: isKingSide ? 7 : 0, rank: homeRank)
                let rookTo = Square.make(file: isKingSide ? 5 : 3, rank: homeRank)
                squares[rookTo] = squares[rookFrom]
                squares[rookFrom] = 0
            }
        }

        // Castling rights are lost when a king or rook leaves, or a rook square is captured on.
        if movingKind == .king {
            castlingRights.subtract(color == .white ? [.whiteKing, .whiteQueen] : [.blackKing, .blackQueen])
        }
        updateRookCastlingRights(origin)
        updateRookCastlingRights(target)

        if movingKind == .pawn, abs(target - origin) == 16 {
            enPassantSquare = (origin + target) / 2
        } else {
            enPassantSquare = -1
        }

        if movingKind == .pawn || captured != 0 {
            halfmoveClock = 0
        } else {
            halfmoveClock += 1
        }
        if color == .black { fullmoveNumber += 1 }
        sideToMove = color.opposite
        zobrist = computeZobrist()
        repetitionKeys.append(zobrist)
    }

    func unmakeMove() {
        guard let undo = undoStack.popLast() else { return }
        repetitionKeys.removeLast()
        if undo.isNull {
            castlingRights = undo.castlingRights
            enPassantSquare = undo.enPassantSquare
            halfmoveClock = undo.halfmoveClock
            fullmoveNumber = undo.fullmoveNumber
            zobrist = undo.zobrist
            sideToMove = sideToMove.opposite
            return
        }

        let origin = undo.move.fromSquare
        let target = undo.move.toSquare
        let color = sideToMove.opposite

        var moved = squares[target]
        if undo.move.promotion != nil {
            moved = color.sign * Int8(PieceKind.pawn.rawValue)
        }
        squares[origin] = moved
        squares[target] = 0
        if undo.capturedPiece != 0 { squares[undo.capturedSquare] = undo.capturedPiece }

        if abs(moved) == Int8(PieceKind.king.rawValue), abs(Square.file(target) - Square.file(origin)) == 2 {
            let homeRank = Square.rank(origin)
            let isKingSide = Square.file(target) == 6
            let rookFrom = Square.make(file: isKingSide ? 7 : 0, rank: homeRank)
            let rookTo = Square.make(file: isKingSide ? 5 : 3, rank: homeRank)
            squares[rookFrom] = squares[rookTo]
            squares[rookTo] = 0
        }

        castlingRights = undo.castlingRights
        enPassantSquare = undo.enPassantSquare
        halfmoveClock = undo.halfmoveClock
        fullmoveNumber = undo.fullmoveNumber
        whiteKingSquare = undo.whiteKingSquare
        blackKingSquare = undo.blackKingSquare
        zobrist = undo.zobrist
        sideToMove = color
    }

    /// Passes the move to the opponent without changing the board. Used by null-move pruning.
    func makeNullMove() {
        undoStack.append(Undo(isNull: true,
                              move: Move(from: 0, to: 0),
                              capturedPiece: 0,
                              capturedSquare: 0,
                              castlingRights: castlingRights,
                              enPassantSquare: enPassantSquare,
                              halfmoveClock: halfmoveClock,
                              fullmoveNumber: fullmoveNumber,
                              whiteKingSquare: whiteKingSquare,
                              blackKingSquare: blackKingSquare,
                              zobrist: zobrist))
        enPassantSquare = -1
        halfmoveClock += 1
        if sideToMove == .black { fullmoveNumber += 1 }
        sideToMove = sideToMove.opposite
        zobrist = computeZobrist()
        repetitionKeys.append(zobrist)
    }

    /// Moves played since `initialFEN`, in order. An engine needs the real history — not just a
    /// FEN — to see repetitions and the halfmove clock correctly (§5).
    var playedMoves: [Move] {
        undoStack.compactMap { $0.isNull ? nil : $0.move }
    }

    func hasNonPawnMaterial(_ color: PieceColor) -> Bool {
        let sign = color.sign
        for square in 0..<64 {
            let value = squares[square]
            guard value != 0, value * sign > 0 else { continue }
            let kind = abs(value)
            if kind != Int8(PieceKind.pawn.rawValue) && kind != Int8(PieceKind.king.rawValue) { return true }
        }
        return false
    }

    // MARK: - Hashing and repetition

    private func computeZobrist() -> UInt64 {
        var key: UInt64 = 0
        let keys = Zobrist.table
        for square in 0..<64 {
            let value = squares[square]
            guard value != 0 else { continue }
            let kind = PieceKind(rawValue: Int(abs(value)))!
            let color: PieceColor = value > 0 ? .white : .black
            key ^= keys.pieces[Zobrist.index(color: color, kind: kind)][square]
        }
        if sideToMove == .black { key ^= keys.blackToMove }
        key ^= keys.castling[Int(castlingRights.rawValue)]
        if enPassantSquare >= 0 { key ^= keys.enPassantFile[Square.file(enPassantSquare)] }
        return key
    }

    /// How many times the current position has occurred in the reversible window.
    func repetitionCount() -> Int {
        guard repetitionKeys.count > 1 else { return 1 }
        let current = repetitionKeys[repetitionKeys.count - 1]
        var count = 1
        var index = repetitionKeys.count - 3
        let limit = max(0, repetitionKeys.count - 1 - halfmoveClock)
        while index >= limit {
            if repetitionKeys[index] == current { count += 1 }
            index -= 2
        }
        return count
    }

    /// Seeds the repetition window with keys from earlier plies, so a position lifted out of a
    /// game keeps its full history (a FEN alone cannot express repetition).
    func seedRepetitionHistory(_ keys: [UInt64]) {
        repetitionKeys = keys + [zobrist]
    }

    // MARK: - Terminal states

    var hasLegalMove: Bool {
        var buffer: [Move] = []
        generatePseudoLegalMoves(into: &buffer)
        return buffer.contains { isLegal($0) }
    }

    /// Automatic terminal state, if the position is over by rule.
    func terminalState() -> GameTerminal? {
        if !hasLegalMove {
            return isInCheck ? .checkmate : .stalemate
        }
        if hasInsufficientMaterial() { return .insufficientMaterial }
        if halfmoveClock >= 150 { return .seventyFiveMoveRule }
        if repetitionCount() >= 5 { return .fivefoldRepetition }
        return nil
    }

    /// Draw detection used inside the search (claimable rules count immediately there).
    func isSearchDraw() -> Bool {
        if halfmoveClock >= 100 { return true }
        if hasInsufficientMaterial() { return true }
        return repetitionCount() >= 2
    }

    func hasInsufficientMaterial() -> Bool {
        var whiteMinors: [(kind: PieceKind, square: Int)] = []
        var blackMinors: [(kind: PieceKind, square: Int)] = []
        for square in 0..<64 {
            let value = squares[square]
            guard value != 0 else { continue }
            let kind = PieceKind(rawValue: Int(abs(value)))!
            switch kind {
            case .king:
                continue
            case .bishop, .knight:
                if value > 0 { whiteMinors.append((kind, square)) } else { blackMinors.append((kind, square)) }
            default:
                return false
            }
        }
        let total = whiteMinors.count + blackMinors.count
        if total == 0 { return true }
        if total == 1 { return true }
        if whiteMinors.count == 1, blackMinors.count == 1,
           whiteMinors[0].kind == .bishop, blackMinors[0].kind == .bishop {
            return Square.isLight(whiteMinors[0].square) == Square.isLight(blackMinors[0].square)
        }
        return false
    }

    /// Total §5 phase weight across both sides (minor 1, rook 2, queen 4).
    func phaseMaterialWeight() -> Int {
        var total = 0
        for square in 0..<64 {
            let value = squares[square]
            guard value != 0 else { continue }
            total += PieceKind(rawValue: Int(abs(value)))!.phaseWeight
        }
        return total
    }

    /// Material balance in pawn units from White's point of view.
    func materialBalance() -> Int {
        var total = 0
        for square in 0..<64 {
            let value = squares[square]
            guard value != 0 else { continue }
            let kind = PieceKind(rawValue: Int(abs(value)))!
            total += (value > 0 ? 1 : -1) * kind.materialValue
        }
        return total
    }
}
