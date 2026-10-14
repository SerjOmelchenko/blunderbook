//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// The app's only teaching, each shown once per install. The first time Games shows a game,
/// and again the first time it shows an analysed one, everything goes dark except one part of
/// that game's row, with one sentence beside it. The first tap on grey rings opens a short note
/// on on-device analysis out of the bottom analysis bar.
@MainActor
@Observable
final class FirstRunTips {
    enum Moment: String, CaseIterable {
        /// Games with a grey-ringed game in view: what the rings show, tapping them, the row.
        case gamesFirstOpen = "games_first_open"
        /// The first analysed game in view: its accuracy, and what tapping its rings does.
        case gamesFirstAnalysed = "games_first_analysed"
        /// The first tap on grey rings.
        case analysisNote = "analysis_note"
    }

    /// The parts of a Games row a tip can point at.
    enum Target: CaseIterable { case rings, figure, row }

    /// Which moment a Games row can be pointed at for.
    enum RowKind: Equatable {
        case grey, analysed, other

        init(_ entry: GameListEntry) {
            let isBusy = entry.isQueued || entry.analysisStatus == .pending || entry.analysisStatus == .running
            if isBusy { self = .other }
            else if entry.hasDeepReview, entry.accuracy != nil { self = .analysed }
            else if entry.analysisStatus == .failed { self = .other }
            else { self = .grey }
        }
    }

    struct Step {
        let target: Target
        let text: String
    }

    static func steps(for moment: Moment) -> [Step] {
        switch moment {
        case .gamesFirstOpen:
            return [Step(target: .rings, text: "Once a game is analysed, its three rings show your accuracy: this game, your last 30 days and your last 12 months."),
                    Step(target: .rings, text: "Tap the rings to analyse this game, right here on your phone."),
                    Step(target: .row, text: "Tap anywhere else on the row to open the game and play through it.")]
        case .gamesFirstAnalysed:
            return [Step(target: .figure, text: "Your accuracy in this game, out of 100."),
                    Step(target: .rings, text: "Tap the rings to see this game’s mistakes.")]
        case .analysisNote:
            return []
        }
    }

    private let preferences: PreferencesRepository
    private var seen: Set<Moment>
    /// The moment on screen, if any.
    private(set) var showing: Moment?
    private(set) var step = 0
    /// Where the Games moment on screen points, in global coordinates.
    private(set) var targetFrames: [Target: CGRect] = [:]

    private struct Row {
        var kind: RowKind
        /// When the row last changed kind: a game that has just been analysed settles first.
        var since: Date
        var frames: [Target: CGRect] = [:]
    }

    /// The Games rows laid out right now, while a Games moment is still to come.
    @ObservationIgnored private var rows: [String: Row] = [:]
    @ObservationIgnored private var targetGameKey: String?

    init(preferences: PreferencesRepository) {
        self.preferences = preferences
        #if DEBUG
        if DevelopmentSeed.resetsTips {
            Moment.allCases.forEach { preferences.set(PreferenceKey.tipSeen($0.rawValue), nil) }
        }
        #endif
        seen = Set(Moment.allCases.filter { preferences.string(PreferenceKey.tipSeen($0.rawValue)) == "1" })
        #if DEBUG
        if let preview = DevelopmentSeed.tipPreview, let moment = Moment(rawValue: preview.moment) {
            seen = Set(Moment.allCases).subtracting([moment])
            previewStep = preview.step
        }
        #endif
    }

    /// Development only: the step a previewed tip opens at.
    @ObservationIgnored private var previewStep = 0

    func hasSeen(_ moment: Moment) -> Bool { seen.contains(moment) }

    /// True while a Games moment is still to come, so rows report where they are.
    var isWatchingGames: Bool { !seen.contains(.gamesFirstOpen) || !seen.contains(.gamesFirstAnalysed) }

    // MARK: Rows

    func report(gameKey: String, target: Target, frame: CGRect, kind: RowKind) {
        guard isWatchingGames || showing != nil else { return }
        var row = rows[gameKey] ?? Row(kind: kind, since: Date())
        if row.kind != kind { row.kind = kind; row.since = Date() }
        row.frames[target] = frame
        rows[gameKey] = row
        // The list can still settle under a tip: the light follows the row.
        if gameKey == targetGameKey, showing != nil, targetFrames[target] != frame { targetFrames[target] = frame }
    }

    func forget(gameKey: String) { rows[gameKey] = nil }

    // MARK: Showing

    /// Starts the next Games moment if a row for it sits wholly inside `visible`. Grey rings are
    /// only pointed at while they can be tapped.
    func startIfReady(in visible: CGRect, greyRingsTappable: Bool) -> Bool {
        guard showing == nil else { return false }
        let now = Date()
        for moment in [Moment.gamesFirstOpen, .gamesFirstAnalysed] where !seen.contains(moment) {
            if moment == .gamesFirstOpen, !greyRingsTappable { continue }
            let kind: RowKind = moment == .gamesFirstOpen ? .grey : .analysed
            let candidates = rows.filter { _, row in
                row.kind == kind && now.timeIntervalSince(row.since) >= 2
                    && Target.allCases.allSatisfy { row.frames[$0].map(visible.contains) ?? false }
            }
            guard let top = candidates.min(by: { ($0.value.frames[.row]?.minY ?? 0) < ($1.value.frames[.row]?.minY ?? 0) })
            else { continue }
            targetGameKey = top.key
            targetFrames = top.value.frames
            step = min(previewStep, Self.steps(for: moment).count - 1)
            showing = moment
            return true
        }
        return false
    }

    /// Opens the note on on-device analysis, the first time grey rings are tapped.
    func showAnalysisNoteIfFirst() {
        guard showing == nil, !seen.contains(.analysisNote) else { return }
        showing = .analysisNote
    }

    func advance() {
        guard let showing else { return }
        if step + 1 < Self.steps(for: showing).count { step += 1 } else { finish() }
    }

    /// Takes a Games moment off screen without counting it as seen: the list it points into has
    /// gone (a game opened, another tab, a sheet). It shows again next time.
    func withdrawGamesMoment() {
        guard let showing, showing != .analysisNote else { return }
        self.showing = nil
        targetGameKey = nil
        targetFrames = [:]
    }

    /// Ends the moment on screen for good, whether it was read through or skipped.
    func finish() {
        guard let showing else { return }
        seen.insert(showing)
        preferences.set(PreferenceKey.tipSeen(showing.rawValue), "1")
        self.showing = nil
        targetGameKey = nil
        if !isWatchingGames { rows = [:] }
    }
}

extension View {
    /// Reports where this part of a Games row is, for the first-run tips.
    func tipTarget(_ target: FirstRunTips.Target, of entry: GameListEntry) -> some View {
        modifier(TipTargetReporter(target: target, gameKey: entry.game.gameKey, kind: FirstRunTips.RowKind(entry)))
    }
}

private struct TipTargetReporter: ViewModifier {
    let target: FirstRunTips.Target
    let gameKey: String
    let kind: FirstRunTips.RowKind

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                model.tips.report(gameKey: gameKey, target: target, frame: frame, kind: kind)
            }
            .onDisappear { model.tips.forget(gameKey: gameKey) }
    }
}

// MARK: - Overlay

/// Whatever tip is showing, over the whole app.
struct FirstRunTipsOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.tips.showing {
            case .analysisNote?:
                AnalysisNote()
            case let moment?:
                Spotlight(moment: moment)
                    .transition(.opacity)
            case nil:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.tips.showing)
    }
}

/// Everything dark but one part of a row, with one sentence beside it. A tap anywhere moves on.
private struct Spotlight: View {
    let moment: FirstRunTips.Moment

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bubbleHeight: CGFloat = 0

    /// Kept clear at the bottom for the tab bar and the analysis bar.
    private static let bottomReserve: CGFloat = 150

    var body: some View {
        GeometryReader { proxy in
            let steps = FirstRunTips.steps(for: moment)
            let index = min(model.tips.step, steps.count - 1)
            let step = steps[index]
            let hole = holeRect(for: step.target, origin: proxy.frame(in: .global).origin, width: proxy.size.width)
            let radius = step.target == .rings ? hole.height / 2 : 16
            let below = hole.maxY + 14 + bubbleHeight < proxy.size.height - Self.bottomReserve

            ZStack(alignment: .topLeading) {
                SpotlightShape(hole: hole, radius: radius, includesSurround: true)
                    .fill(Color.black.opacity(0.74), style: FillStyle(eoFill: true))
                SpotlightShape(hole: hole, radius: radius, includesSurround: false)
                    .stroke(Palette.brand.opacity(0.45), lineWidth: 1)
                bubble(step: step, index: index, count: steps.count, below: below,
                       arrowX: min(max(hole.midX - 16 - 7, 14), proxy.size.width - 32 - 28))
                    .frame(width: proxy.size.width - 32)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bubbleHeight = $0 }
                    .offset(x: 16, y: below ? hole.maxY + 14 : hole.minY - 14 - bubbleHeight)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: index)
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: hole)
            .contentShape(Rectangle())
            .onTapGesture { model.tips.advance() }
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
    }

    /// The lit area around the target: a circle round the rings, a band across the row.
    private func holeRect(for target: FirstRunTips.Target, origin: CGPoint, width: CGFloat) -> CGRect {
        guard let frame = model.tips.targetFrames[target]?.offsetBy(dx: -origin.x, dy: -origin.y) else { return .zero }
        switch target {
        case .rings:
            let side = max(frame.width, frame.height) + 12
            return CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
        case .figure:
            return frame.insetBy(dx: -10, dy: -10)
        case .row:
            return CGRect(x: 8, y: frame.minY - 2, width: frame.maxX - 8 + 4, height: frame.height + 4)
        }
    }

    private func bubble(step: FirstRunTips.Step, index: Int, count: Int, below: Bool, arrowX: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.text)
                .font(.body)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(index)
                .transition(.opacity)
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    ForEach(0..<count, id: \.self) { dot in
                        Circle()
                            .fill(dot == index ? Palette.brand : Color.white.opacity(0.22))
                            .frame(width: 5, height: 5)
                    }
                }
                Text("Tap anywhere")
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                Spacer(minLength: 0)
                Button("Skip") { model.tips.finish() }
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(minHeight: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(alignment: below ? .topLeading : .bottomLeading) {
            // The point toward the lit part.
            Rectangle()
                .fill(Palette.surfaceRaised)
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(45))
                .offset(x: arrowX, y: below ? -7 : 7)
        }
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(step.text)
        .accessibilityHint(index + 1 < count ? "Double-tap for the next tip" : "Double-tap to close")
        .accessibilityAction { model.tips.advance() }
        .accessibilityAction(named: "Skip") { model.tips.finish() }
    }
}

/// The darkened screen with a rounded hole in it, or with `includesSurround` false the hole's
/// outline alone. Animates from one hole to the next.
private struct SpotlightShape: Shape {
    var hole: CGRect
    var radius: CGFloat
    let includesSurround: Bool

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(AnimatablePair(hole.width, hole.height), radius)) }
        set {
            hole = CGRect(x: newValue.first.first, y: newValue.first.second,
                          width: newValue.second.first.first, height: newValue.second.first.second)
            radius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = includesSurround ? Path(rect.insetBy(dx: -2, dy: -2)) : Path()
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return path
    }
}

// MARK: - The note on on-device analysis

/// The bottom analysis bar opening upward into two short points, folding back into the bar on
/// "Got it". The analysis is already running underneath.
private struct AnalysisNote: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bar: CGRect?
    @State private var isOpen = false
    @State private var bodyHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let origin = proxy.frame(in: .global).origin
            let anchor = (bar ?? fallbackBar(in: proxy.size)).offsetBy(dx: bar == nil ? 0 : -origin.x, dy: bar == nil ? 0 : -origin.y)

            ZStack(alignment: .topLeading) {
                // Holds the screen still while the note is up.
                Color.black.opacity(isOpen ? 0.42 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                if bar != nil || isOpen {
                    card(barHeight: anchor.height)
                        .frame(width: anchor.width)
                        .offset(x: anchor.minX, y: anchor.maxY - bodyHeight - anchor.height)
                }
            }
        }
        .ignoresSafeArea()
        .task { await open() }
    }

    private func card(barHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                NotePoint(symbol: "lock.iphone",
                          title: "Analysed on your phone",
                          text: "Every game is analysed right here, not on a server. It’s a little slower than chess websites, but your games are never uploaded, and you can analyse the ones you’ve loaded even offline.")
                Hairline()
                NotePoint(symbol: "thermometer.medium",
                          title: "Your phone may feel warm",
                          text: "Deep chess analysis is demanding, and we didn’t cut corners on quality. Warmth is normal: the app slows itself down before your phone gets too hot. Analyse one game, go through it, then start the next.")
                Button("Got it", action: close)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 14)
            .opacity(isOpen ? 1 : 0)
            .offset(y: isOpen ? 0 : 10)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { bodyHeight = $0 }
            Hairline()
            QueueAccessory(reportsFrames: false)
                .frame(height: barHeight)
        }
        .background(Palette.surfaceRaised)
        .mask(alignment: .bottom) {
            RoundedRectangle(cornerRadius: isOpen ? Layout.cardRadius + 2 : barHeight / 2, style: .continuous)
                .frame(height: isOpen ? bodyHeight + barHeight : barHeight)
        }
        .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 30, y: -10)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// Waits for the bar to come up under the rings just tapped, then opens out of it.
    private func open() async {
        var waited = 0
        while !(model.isAnalysingAGame && model.barFrame != nil), waited < 20 {
            try? await Task.sleep(for: .seconds(0.1))
            waited += 1
        }
        try? await Task.sleep(for: .seconds(0.35))
        bar = model.barFrame
        try? await Task.sleep(for: .seconds(0.05))
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.6)) { isOpen = true }
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func close() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .smooth(duration: 0.5)) { isOpen = false }
        Task {
            try? await Task.sleep(for: .seconds(0.5))
            model.tips.finish()
        }
    }

    /// Where the bar would be on a system without the tab bar accessory: just above the tab bar.
    private func fallbackBar(in size: CGSize) -> CGRect {
        let bottom = AppModel.keyWindow?.safeAreaInsets.bottom ?? 34
        return CGRect(x: 16, y: size.height - bottom - 49 - 8 - 48, width: size.width - 32, height: 48)
    }
}

private struct NotePoint: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Palette.brand)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Palette.ink.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 10)
    }
}
