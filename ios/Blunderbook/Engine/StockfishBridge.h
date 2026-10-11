//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.
//
//  Objective-C surface over Stockfish's C++ Engine API. The header is deliberately free of any
//  C++ so it can be imported from Swift through the bridging header; all C++ lives in the .mm.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One completed root search.
@interface SFSearchOutcome : NSObject

/// Depth of the last completed iteration.
@property (nonatomic, readonly) NSInteger depth;
/// Nodes actually searched.
@property (nonatomic, readonly) NSUInteger nodes;
/// True when the score is a mate distance rather than a centipawn value.
@property (nonatomic, readonly) BOOL isMate;
/// Centipawns from the side to move's point of view. Valid when `isMate` is NO.
@property (nonatomic, readonly) NSInteger centipawns;
/// Mate distance in *moves*, positive when the side to move delivers it. Valid when `isMate` is YES.
@property (nonatomic, readonly) NSInteger mateInMoves;
/// True when the position has no legal moves, so the search returned without one.
@property (nonatomic, readonly) BOOL isTerminal;
/// Best move in UCI form, or nil for a terminal position.
@property (nonatomic, readonly, nullable) NSString *bestMove;
/// Principal variation in UCI form, best move first.
@property (nonatomic, readonly) NSArray<NSString *> *principalVariation;

@end

/// Serial wrapper around a single `Stockfish::Engine`.
///
/// One instance owns one engine, one transposition table and the network, which engines in the
/// same process share (the `shm.h` patch, NOTICE.md).
/// `-searchFromFEN:…` is synchronous and serialised; `-stop` may be called from any thread.
/// How urgently a search should run. Only the scheduling changes, never the result: searches are
/// bounded by nodes, not time.
typedef NS_ENUM(NSInteger, SFSearchPriority) {
    /// User-initiated quality of service: the performance cores, full speed.
    SFSearchPriorityInteractive = 0,
    /// Utility quality of service.
    SFSearchPriorityUtility = 1,
    /// Background quality of service, which keeps the search on the efficiency cores: several
    /// times slower per engine and far cooler per node.
    SFSearchPriorityBackground = 2,
};

@interface StockfishBridge : NSObject

/// Applied to Stockfish's search thread for every following search. Safe from any thread.
@property (atomic) SFSearchPriority searchPriority;
/// The quality-of-service class the last search actually ran at, as the search thread reported
/// it. For verification only.
@property (atomic, readonly) NSInteger lastSearchQoSClass;

/// Stockfish's own version string, recorded with every stored analysis.
@property (class, nonatomic, readonly) NSString *engineVersion;
/// Identifier of the loaded network, recorded with every stored analysis.
@property (nonatomic, readonly) NSString *networkVersion;
/// Set when the network could not be loaded. The engine must not be used in that case.
@property (nonatomic, readonly, nullable) NSString *loadError;

/// Loads the bundled network. Returns an instance whose `loadError` is set on failure rather
/// than trapping, so the app can report it and fall back.
- (instancetype)initWithNetworkPath:(NSString *)networkPath
                        hashSizeMiB:(NSUInteger)hashSizeMiB NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Runs one independent root search. The hash and history are cleared first, so the same
/// position and node budget always produce the same result.
/// Forgets everything earlier searches learned: hash, histories and search state.
- (void)clearMemory;

/// Searches one position. With `clearingFirst` NO the hash and histories from earlier searches
/// stay, so searches of one game inform each other; the result then depends on what was searched
/// before, which the caller keeps reproducible by always searching in the same order.
- (nullable SFSearchOutcome *)searchFromFEN:(NSString *)fen
                                      moves:(NSArray<NSString *> *)uciMoves
                                 nodeBudget:(NSUInteger)nodeBudget
                              clearingFirst:(BOOL)clearingFirst;

/// Searches for the best `lineCount` distinct lines (MultiPV), best first. Used only for the live
/// lines shown while reviewing a game, never for stored analysis, which is always single-line.
- (NSArray<SFSearchOutcome *> *)searchLinesFromFEN:(NSString *)fen
                                            moves:(NSArray<NSString *> *)uciMoves
                                       nodeBudget:(NSUInteger)nodeBudget
                                        lineCount:(NSUInteger)lineCount;

/// Asks the running search to stop. Safe from any thread.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
