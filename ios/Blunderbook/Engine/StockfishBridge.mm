//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.
//
//  This file links the app against Stockfish (GPLv3). Linking it makes the whole application a
//  work based on Stockfish, which is why the entire app is distributed under GPLv3.

#import "StockfishBridge.h"

#include <atomic>
#include <mutex>
#include <pthread/qos.h>
#include <sstream>
#include <string>
#include <vector>

#include "attacks.h"
#include "bitboard.h"
#include "engine.h"
#include "misc.h"
#include "position.h"
#include "score.h"
#include "search.h"
#include "uci.h"

using namespace Stockfish;

@implementation SFSearchOutcome

- (instancetype)initWithDepth:(NSInteger)depth
                        nodes:(NSUInteger)nodes
                       isMate:(BOOL)isMate
                   centipawns:(NSInteger)centipawns
                  mateInMoves:(NSInteger)mateInMoves
                   isTerminal:(BOOL)isTerminal
                     bestMove:(NSString *)bestMove
           principalVariation:(NSArray<NSString *> *)pv {
    if ((self = [super init])) {
        _depth = depth;
        _nodes = nodes;
        _isMate = isMate;
        _centipawns = centipawns;
        _mateInMoves = mateInMoves;
        _isTerminal = isTerminal;
        _bestMove = [bestMove copy];
        _principalVariation = [pv copy];
    }
    return self;
}

@end

namespace {

/// Everything the Stockfish callbacks write into during one search.
/// One principal variation as last reported for its MultiPV slot.
struct LineCapture {
    int         depth = 0;
    std::size_t nodes = 0;
    std::string score;
    std::string pv;
};

struct SearchCapture {
    int         depth = 0;
    std::size_t nodes = 0;
    std::string score;     // "cp N" or "mate N", as UCI formats it
    std::string pv;        // space-separated UCI moves
    std::string bestMove;
    bool        noMoves = false;
    /// Every MultiPV slot, best first. Slot 0 mirrors the fields above.
    std::vector<LineCapture> lines;
    /// Set for live-line searches only, which keep each slot's last exact report.
    bool multiLine = false;

    void reset() {
        depth = 0;
        nodes = 0;
        score.clear();
        pv.clear();
        bestMove.clear();
        noMoves = false;
        lines.clear();
        multiLine = false;
    }
};

void parseScore(const std::string &score, BOOL *isMate, NSInteger *centipawns, NSInteger *mateInMoves) {
    std::istringstream stream(score);
    std::string kind;
    long value = 0;
    stream >> kind >> value;
    *isMate = kind == "mate";
    *centipawns = *isMate ? 0 : value;
    *mateInMoves = *isMate ? value : 0;
}

/// Stockfish's static tables are global, so they are initialised exactly once per process.
/// Requested and observed quality of service for the search thread, shared with its callbacks.
struct SearchScheduling {
    std::atomic<qos_class_t> requested{QOS_CLASS_USER_INITIATED};
    std::atomic<qos_class_t> observed{QOS_CLASS_UNSPECIFIED};
};

/// Runs on Stockfish's own search thread. Stockfish creates that thread itself, so its first
/// progress report of each search is where it can be moved to the requested class. Depth 1 takes
/// microseconds, so practically the whole search runs at the new class.
void applyScheduling(SearchScheduling *scheduling) {
    const qos_class_t requested = scheduling->requested.load(std::memory_order_relaxed);
    if (qos_class_self() != requested) {
        pthread_set_qos_class_self_np(requested, 0);
    }
    scheduling->observed.store(qos_class_self(), std::memory_order_relaxed);
}

void ensureGlobalInitialisation() {
    static std::once_flag once;
    std::call_once(once, [] {
        Attacks::init();
        Position::init();
    });
}

std::vector<std::string> toStdStrings(NSArray<NSString *> *strings) {
    std::vector<std::string> result;
    result.reserve(strings.count);
    for (NSString *value in strings) {
        result.emplace_back(value.UTF8String);
    }
    return result;
}

NSArray<NSString *> *splitUCIMoves(const std::string &line) {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    std::istringstream stream(line);
    std::string token;
    while (stream >> token) {
        [result addObject:@(token.c_str())];
    }
    return result;
}

}  // namespace

@implementation StockfishBridge {
    std::unique_ptr<Engine> _engine;
    SearchCapture           _capture;
    SearchScheduling        _scheduling;
    std::mutex              _searchMutex;
    NSString               *_networkVersion;
    NSString               *_loadError;
}

+ (NSString *)engineVersion {
    // engine_info() carries the version and build; keep only the leading version token.
    std::string info = engine_version_info();
    std::istringstream stream(info);
    std::string first, second;
    stream >> first >> second;
    return [NSString stringWithFormat:@"stockfish-%s", second.empty() ? first.c_str() : second.c_str()];
}

- (instancetype)initWithNetworkPath:(NSString *)networkPath
                        hashSizeMiB:(NSUInteger)hashSizeMiB {
    if (!(self = [super init])) {
        return nil;
    }

    ensureGlobalInitialisation();

    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:networkPath]) {
        _loadError = @"The bundled Stockfish network is missing from the app.";
        return self;
    }

    _engine = std::make_unique<Engine>();
    Engine &engine = *_engine;

    // The handlers are stored inside the engine and outlive this initialiser — the verify one is
    // called again later during lazy network replication — so they capture owned values, never
    // references to locals.
    SearchCapture *capture = &_capture;
    SearchScheduling *scheduling = &_scheduling;
    auto verifyError = std::make_shared<std::string>();

    engine.set_on_update_full([capture, scheduling](const Engine::InfoFull &info) {
        applyScheduling(scheduling);
        const std::size_t slot = info.multiPV > 0 ? info.multiPV - 1 : 0;
        if (capture->lines.size() <= slot) {
            capture->lines.resize(slot + 1);
        }
        LineCapture &line = capture->lines[slot];
        // A search stopped by its node budget part-way through a depth reports bounded, often
        // truncated lines. Live lines keep the last exact one instead.
        const bool keepPrevious = capture->multiLine && !info.bound.empty() && !line.pv.empty();
        if (!keepPrevious) {
            line.depth = info.depth;
            line.nodes = info.nodes;
            line.score = UCIEngine::format_score(info.score);
            line.pv    = std::string(info.pv);
        }
        // The best line is what a single-line search has always reported; stored analysis
        // depends on this staying exactly as it was.
        if (slot == 0) {
            capture->depth = info.depth;
            capture->nodes = info.nodes;
            capture->score = UCIEngine::format_score(info.score);
            capture->pv    = std::string(info.pv);
        }
    });
    // A position with no legal moves reports here instead. Without a handler installed,
    // std::function throws bad_function_call and takes the process down.
    engine.set_on_update_no_moves([capture, scheduling](const Engine::InfoShort &info) {
        applyScheduling(scheduling);
        capture->depth   = info.depth;
        capture->score   = UCIEngine::format_score(info.score);
        capture->noMoves = true;
    });
    engine.set_on_bestmove([capture](std::string_view best, std::string_view) {
        capture->bestMove = std::string(best);
    });
    engine.set_on_iter([](const Engine::InfoIter &) {});
    // Called as every search starts; like the others it must have a handler.
    engine.set_on_start([] {});
    engine.set_on_verify_network([verifyError](std::string_view message) {
        // Stockfish reports both success and failure here; only failures start with "ERROR".
        if (message.rfind("ERROR", 0) == 0) {
            *verifyError = std::string(message);
        }
    });

    auto setOption = [&engine](const std::string &name, const std::string &value) {
        std::istringstream stream("name " + name + " value " + value);
        engine.get_options().setoption(stream);
    };
    // §5: one thread, the policy's hash size, single PV, full strength, no ponder, Chess960 off.
    setOption("Threads", "1");
    setOption("Hash", std::to_string(hashSizeMiB));
    setOption("MultiPV", "1");
    setOption("Ponder", "false");
    setOption("UCI_Chess960", "false");
    setOption("UCI_LimitStrength", "false");
    setOption("Skill Level", "20");
    // Setting the option loads the network, and verify_network() compares the loaded file against
    // it, so it carries the absolute path in the bundle.
    setOption("EvalFile", networkPath.UTF8String);
    engine.verify_network();

    if (!verifyError->empty()) {
        _loadError = @(verifyError->c_str());
        _engine.reset();
        return self;
    }

    _networkVersion = networkPath.lastPathComponent.stringByDeletingPathExtension;
    return self;
}

- (SFSearchPriority)searchPriority {
    switch (_scheduling.requested.load()) {
        case QOS_CLASS_BACKGROUND: return SFSearchPriorityBackground;
        case QOS_CLASS_UTILITY: return SFSearchPriorityUtility;
        default: return SFSearchPriorityInteractive;
    }
}

- (void)setSearchPriority:(SFSearchPriority)priority {
    switch (priority) {
        case SFSearchPriorityBackground: _scheduling.requested.store(QOS_CLASS_BACKGROUND); break;
        case SFSearchPriorityUtility: _scheduling.requested.store(QOS_CLASS_UTILITY); break;
        default: _scheduling.requested.store(QOS_CLASS_USER_INITIATED); break;
    }
}

- (NSInteger)lastSearchQoSClass {
    return static_cast<NSInteger>(_scheduling.observed.load());
}

- (NSString *)networkVersion {
    return _networkVersion ?: @"unavailable";
}

- (NSString *)loadError {
    return _loadError;
}

- (void)clearMemory {
    std::lock_guard<std::mutex> lock(_searchMutex);
    if (_engine) {
        _engine->search_clear();
    }
}

- (nullable SFSearchOutcome *)searchFromFEN:(NSString *)fen
                                      moves:(NSArray<NSString *> *)uciMoves
                                 nodeBudget:(NSUInteger)nodeBudget
                              clearingFirst:(BOOL)clearingFirst {
    std::lock_guard<std::mutex> lock(_searchMutex);
    if (!_engine) {
        return nil;
    }
    Engine &engine = *_engine;

    // A cleared search depends only on the position and the budget. A search that keeps the
    // memory also depends on everything searched since the last clear (§5).
    if (clearingFirst) {
        engine.search_clear();
    }
    _capture.reset();

    engine.set_position(fen.UTF8String, toStdStrings(uciMoves));

    Search::LimitsType limits;
    limits.nodes = static_cast<std::uint64_t>(nodeBudget);
    engine.go(limits);
    engine.wait_for_search_finished();

    BOOL isMate = NO;
    NSInteger centipawns = 0;
    NSInteger mateInMoves = 0;
    {
        std::istringstream stream(_capture.score);
        std::string kind;
        long value = 0;
        stream >> kind >> value;
        if (kind == "mate") {
            isMate = YES;
            mateInMoves = value;
        } else {
            centipawns = value;
        }
    }

    const bool hasBestMove = !_capture.bestMove.empty() && _capture.bestMove != "(none)";
    NSArray<NSString *> *pv = splitUCIMoves(_capture.pv);
    if (pv.count == 0 && hasBestMove) {
        pv = @[ @(_capture.bestMove.c_str()) ];
    }

    return [[SFSearchOutcome alloc] initWithDepth:_capture.depth
                                            nodes:_capture.nodes
                                           isMate:isMate
                                       centipawns:centipawns
                                      mateInMoves:mateInMoves
                                       isTerminal:_capture.noMoves || !hasBestMove
                                         bestMove:hasBestMove ? @(_capture.bestMove.c_str()) : nil
                               principalVariation:pv];
}

- (NSArray<SFSearchOutcome *> *)searchLinesFromFEN:(NSString *)fen
                                            moves:(NSArray<NSString *> *)uciMoves
                                       nodeBudget:(NSUInteger)nodeBudget
                                        lineCount:(NSUInteger)lineCount {
    std::lock_guard<std::mutex> lock(_searchMutex);
    if (!_engine) {
        return @[];
    }
    Engine &engine = *_engine;
    auto setMultiPV = [&engine](NSUInteger count) {
        std::istringstream stream("name MultiPV value " + std::to_string(count));
        engine.get_options().setoption(stream);
    };

    engine.search_clear();
    _capture.reset();
    _capture.multiLine = true;
    setMultiPV(MAX(1, lineCount));
    engine.set_position(fen.UTF8String, toStdStrings(uciMoves));

    Search::LimitsType limits;
    limits.nodes = static_cast<std::uint64_t>(nodeBudget);
    engine.go(limits);
    engine.wait_for_search_finished();
    // Stored analysis is single-line (§5); never leave the engine in another mode.
    setMultiPV(1);

    NSMutableArray<SFSearchOutcome *> *result = [NSMutableArray array];
    if (_capture.noMoves) {
        return result;
    }
    for (const LineCapture &line : _capture.lines) {
        NSArray<NSString *> *pv = splitUCIMoves(line.pv);
        if (pv.count == 0) {
            continue;
        }
        BOOL isMate = NO;
        NSInteger centipawns = 0, mateInMoves = 0;
        parseScore(line.score, &isMate, &centipawns, &mateInMoves);
        [result addObject:[[SFSearchOutcome alloc] initWithDepth:line.depth
                                                           nodes:line.nodes
                                                          isMate:isMate
                                                      centipawns:centipawns
                                                     mateInMoves:mateInMoves
                                                      isTerminal:NO
                                                        bestMove:pv.firstObject
                                              principalVariation:pv]];
    }
    return result;
}

- (void)stop {
    if (_engine) {
        _engine->stop();
    }
}

@end
