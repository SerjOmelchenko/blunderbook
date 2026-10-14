//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// A game's accuracy as three nested amber arcs, the same rings as the app icon: this game
/// outside, the 30 days up to it in the middle, the 12 months up to it inside. A green check in
/// the centre says every mistake from the game is solved.
///
/// Before a review the rings are grey and empty. While the game waits or is analysed, short arcs
/// spin; when the result lands they settle into place one after another, then stop. A view that
/// first appears with values draws them still, so scrolling past finished games costs nothing.
struct AccuracyRings: View {
    enum Phase: Equatable {
        /// No review yet: grey, empty rings.
        case inactive
        /// Waiting or being analysed.
        case busy
        /// Accuracies from 0 to 100; the longer windows are nil until they have a game.
        case values(game: Double, days30: Double?, months12: Double?, solved: Bool)
    }

    let phase: Phase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric private var diameter: CGFloat

    /// - Parameter diameter: 40 in a Games row; the Mistakes tab draws them larger.
    init(phase: Phase, diameter: CGFloat = 40) {
        self.phase = phase
        _diameter = ScaledMetric(wrappedValue: diameter, relativeTo: .subheadline)
    }
    @State private var settle: Settle?

    /// When a spin ended and where each ring was pointing at that moment.
    private struct Settle {
        var start: Date
        var from: [Double]
    }

    /// One clock for every spinning ring on screen, so rows that spin together stay in step.
    private static let epoch = Date()
    /// Degrees per second, outside in; the middle ring turns the other way. Shared with
    /// `RevealPortal`, which picks the arcs up where they are.
    static let speeds: [Double] = [330, -250, 410]
    static let spinLength = 0.26
    private static let settleDuration = 0.9
    private static let settleStagger = 0.12
    /// When the check starts to appear, and how long it takes.
    private static let checkDelay = 1.14
    private static let checkDuration = 0.26
    private static var settleTotal: Double { checkDelay + checkDuration }

    /// Amber stepped down in lightness, outside in, close enough to stay visible at row size.
    static let colors = [Palette.brand, Palette.fixed(0xD9A043), Palette.fixed(0xB9893F)]

    var body: some View {
        TimelineView(.animation(paused: !isMoving)) { context in
            rings(at: context.date)
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: phase) { old, new in
            guard old == .busy, case .values = new, !reduceMotion else { return }
            let now = Date()
            settle = Settle(start: now, from: (0..<3).map { spinAngle(ring: $0, at: now) })
            Task {
                try? await Task.sleep(for: .seconds(Self.settleTotal + 0.05))
                settle = nil
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : nil, value: phase)
    }

    private var isMoving: Bool { phase == .busy || settle != nil }

    // MARK: Drawing

    private func rings(at date: Date) -> some View {
        let scale = diameter / 40
        let lineWidth = 3.5 * scale
        return ZStack {
            ForEach(0..<3, id: \.self) { ring in
                let size = (40 - 3.5 - Double(ring) * 9.5) * scale
                let arc = arc(ring: ring, at: date)
                Circle()
                    .stroke(Color.white.opacity(phase == .inactive ? 0.16 : 0.10), lineWidth: lineWidth)
                    .frame(width: size, height: size)
                Circle()
                    .trim(from: 0, to: arc.length)
                    .stroke(Self.colors[ring], style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(arc.angle - 90))
                    .frame(width: size, height: size)
                    .opacity(arc.opacity)
            }
            check(at: date)
                .stroke(Palette.best, style: StrokeStyle(lineWidth: 2.2 * scale, lineCap: .round, lineJoin: .round))
                .frame(width: diameter, height: diameter)
                .scaleEffect(checkScale(at: date))
                .opacity(checkOpacity(at: date))
        }
    }

    private func check(at date: Date) -> Path {
        let scale = diameter / 40
        var path = Path()
        path.move(to: CGPoint(x: 16.6 * scale, y: 20.2 * scale))
        path.addLine(to: CGPoint(x: 19 * scale, y: 22.6 * scale))
        path.addLine(to: CGPoint(x: 23.6 * scale, y: 17.6 * scale))
        return path
    }

    /// Where one ring points and how much of it is drawn, in degrees from the top and 0...1.
    private func arc(ring: Int, at date: Date) -> (angle: Double, length: Double, opacity: Double) {
        switch phase {
        case .inactive:
            return (0, 0, 1)
        case .busy:
            if reduceMotion {
                // No spin: the arcs rest at staggered angles and breathe instead.
                let pulse = 0.55 + 0.45 * (0.5 + 0.5 * sin(date.timeIntervalSince(Self.epoch) * 3))
                return (Double(ring) * 120, Self.spinLength, pulse)
            }
            return (spinAngle(ring: ring, at: date), Self.spinLength, 1)
        case .values:
            let target = value(ring: ring) / 100
            guard let settle else { return (0, target, 1) }
            let progress = clamp((date.timeIntervalSince(settle.start) - Double(ring) * Self.settleStagger)
                                 / Self.settleDuration)
            let from = settle.from[ring]
            let speed = Self.speeds[ring]
            // Finish the turn in the direction of travel; a ring almost at the top takes one more.
            var delta = speed > 0 ? 360 - from : -from
            if abs(delta) < 90 { delta += speed > 0 ? 360 : -360 }
            let angle = from + delta * easeOut(progress)
            let length = Self.spinLength + (target - Self.spinLength) * easeOutBack(progress)
            return (angle, min(0.995, max(0, length)), 1)
        }
    }

    private func value(ring: Int) -> Double {
        guard case .values(let game, let days30, let months12, _) = phase else { return 0 }
        return [game, days30 ?? 0, months12 ?? 0][ring]
    }

    private func spinAngle(ring: Int, at date: Date) -> Double { Self.spinAngle(ring: ring, at: date) }

    /// Where a spinning ring points at `date`, in degrees from the top.
    static func spinAngle(ring: Int, at date: Date) -> Double {
        let degrees = speeds[ring] * date.timeIntervalSince(epoch)
        return (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    private var isSolved: Bool {
        if case .values(_, _, _, let solved) = phase { return solved }
        return false
    }

    private func checkProgress(at date: Date) -> Double {
        guard isSolved else { return 0 }
        guard let settle else { return 1 }
        return clamp((date.timeIntervalSince(settle.start) - Self.checkDelay) / Self.checkDuration)
    }

    private func checkOpacity(at date: Date) -> Double { checkProgress(at: date) }

    private func checkScale(at date: Date) -> Double {
        let progress = checkProgress(at: date)
        return 0.4 + 0.6 * easeOutBack(progress)
    }

    private func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private func easeOutBack(_ x: Double) -> Double {
        let overshoot = 1.4
        return 1 + (overshoot + 1) * pow(x - 1, 3) + overshoot * pow(x - 1, 2)
    }
}
