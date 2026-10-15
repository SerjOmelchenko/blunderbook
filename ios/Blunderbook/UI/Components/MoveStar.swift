//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// A move's grade as a glass star: tinted glass with a bright rim, like the app's glass controls.
/// Good and best moves are gold; an inaccuracy keeps half its gold, a mistake none, and a blunder
/// breaks in two. The engine's own move throws gold sparks as it lands and keeps one twinkling.
///
/// Drawn in a 24-point design box scaled to `size`; the sparks reach past it.
struct MoveStar: View {
    enum Style {
        /// Denser glass that holds on the light squares, arriving once with its motion.
        case board
        /// Lighter glass, drawn in its final state: the move strip, counts and chips.
        case inline
    }

    let grade: MoveGrade
    var size: CGFloat
    var style: Style = .inline
    /// One colour for the whole star, for a star on a coloured fill such as a selected chip.
    var tint: Color?
    /// Whether the engine's move throws its sparks; off where they would cover text.
    var bursts = true
    /// Waits this long before arriving, so the star follows the piece onto its square.
    var delay: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasLanded: Bool
    @State private var isSettled: Bool
    @State private var glint: CGFloat = 0
    @State private var burst: Double = 0
    @State private var isTwinkling = false
    @State private var wiggles = 0

    init(grade: MoveGrade, size: CGFloat, style: Style = .inline, tint: Color? = nil,
         bursts: Bool = true, delay: Double = 0) {
        self.grade = grade
        self.size = size
        self.style = style
        self.tint = tint
        self.bursts = bursts
        self.delay = delay
        _hasLanded = State(initialValue: style == .inline)
        _isSettled = State(initialValue: style == .inline)
    }

    private var unit: CGFloat { size / 24 }

    var body: some View {
        // Only a board star moves. The inline ones fill a whole move strip, so they stay plain
        // shapes with nothing to schedule.
        if style == .board {
            ZStack {
                if grade == .best, bursts {
                    SparkBurst(progress: burst, unit: unit, color: Self.gold)
                }
                star
                    .keyframeAnimator(initialValue: 0.0, trigger: wiggles) { content, angle in
                        content.rotationEffect(.degrees(angle))
                    } keyframes: { _ in
                        KeyframeTrack {
                            CubicKeyframe(-9, duration: 0.1)
                            CubicKeyframe(8, duration: 0.12)
                            CubicKeyframe(-4, duration: 0.12)
                            CubicKeyframe(0, duration: 0.14)
                        }
                    }
                    .scaleEffect(hasLanded ? 1 : 0.86)
                    .blur(radius: hasLanded ? 0 : size * 0.12)
                    .opacity(hasLanded ? 1 : 0)
                if grade == .best { twinkle.opacity(hasLanded ? 1 : 0) }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .task { await arrive() }
        } else {
            ZStack {
                star
                if grade == .best { twinkle }
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        }
    }

    /// The spark the engine's move keeps beside it.
    private var twinkle: some View {
        SparkleShape()
            .fill(tint ?? Self.gold)
            .frame(width: 6 * unit, height: 6 * unit)
            .rotationEffect(.degrees(isTwinkling ? 45 : 0))
            .scaleEffect(twinkleScale)
            .opacity(twinkleOpacity)
            .offset(x: 11 * unit, y: -13 * unit)
    }

    // MARK: Star

    @ViewBuilder
    private var star: some View {
        switch grade {
        case .best, .good:
            ZStack {
                StarOutline.star.fill(look.fill.opacity(look.opacity))
                rim(StarOutline.star)
                specular(StarOutline.specular)
                glintBand
            }
        case .inaccuracy:
            ZStack {
                StarOutline.star.fill(emptyFill)
                Rectangle()
                    .fill(look.fill.opacity(look.opacity))
                    .scaleEffect(x: isSettled ? 0.5 : 1, y: 1, anchor: .leading)
                    .mask(StarOutline.star)
                rim(StarOutline.star)
                specular(StarOutline.specular)
            }
        case .mistake:
            ZStack {
                StarOutline.star.fill(emptyFill)
                Rectangle()
                    .fill(look.fill.opacity(look.opacity))
                    .scaleEffect(isSettled ? 0.01 : 1)
                    .opacity(isSettled ? 0 : 1)
                    .mask(StarOutline.star)
                rim(StarOutline.star)
                specular(StarOutline.specular)
            }
        case .blunder:
            ZStack {
                ZStack {
                    StarOutline.leftHalf.fill(look.fill.opacity(look.opacity))
                    rim(StarOutline.leftHalf)
                    specular(StarOutline.leftSpecular)
                }
                .rotationEffect(.degrees(isSettled ? -12 : 0), anchor: UnitPoint(x: 11.4 / 24, y: 17.6 / 24))
                .offset(x: isSettled ? -1.4 * unit : 0, y: isSettled ? 0.8 * unit : 0)
                ZStack {
                    StarOutline.rightHalf.fill(look.fill.opacity(look.opacity))
                    rim(StarOutline.rightHalf)
                }
                .rotationEffect(.degrees(isSettled ? 12 : 0), anchor: UnitPoint(x: 12.6 / 24, y: 17.6 / 24))
                .offset(x: isSettled ? 1.4 * unit : 0, y: isSettled ? 0.8 * unit : 0)
            }
        }
    }

    private func rim(_ shape: StarOutline) -> some View {
        shape.stroke(look.rim, style: StrokeStyle(lineWidth: (style == .board ? 2 : 1.8) * unit, lineJoin: .round))
    }

    @ViewBuilder
    private func specular(_ line: StarOutline) -> some View {
        if tint == nil {
            line.stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: unit, lineCap: .round, lineJoin: .round))
        }
    }

    /// A band of light that crosses the glass once as the star lands.
    @ViewBuilder
    private var glintBand: some View {
        if style == .board {
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.85), .white.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: 6 * unit, height: 32 * unit)
                .rotationEffect(.degrees(18))
                .offset(x: (-24 + 48 * glint) * unit)
                .mask(StarOutline.star)
        }
    }

    // MARK: Colour

    private struct Look {
        var fill: Color
        var opacity: Double
        var rim: Color
    }

    static let gold = Palette.fixed(0xFFD60A)

    private var look: Look {
        if let tint { return Look(fill: tint, opacity: 0.5, rim: tint) }
        let board = style == .board
        switch grade {
        case .best:
            return Look(fill: board ? Palette.fixed(0xFFC800) : Self.gold, opacity: board ? 0.82 : 0.7,
                        rim: Palette.fixed(0xFFF2B0))
        case .good:
            return Look(fill: board ? Palette.fixed(0xFFC800) : Self.gold, opacity: board ? 0.72 : 0.55,
                        rim: board ? Palette.fixed(0xFFF2B0) : Palette.fixed(0xFFE680))
        case .inaccuracy:
            return Look(fill: board ? Palette.fixed(0xFFC800) : Self.gold, opacity: board ? 0.85 : 0.7,
                        rim: Palette.fixed(0xFFE680))
        case .mistake:
            return Look(fill: Palette.mistake, opacity: 0.8, rim: Palette.fixed(0xFFB3A8))
        case .blunder:
            return Look(fill: Palette.blunder, opacity: board ? 0.8 : 0.7,
                        rim: board ? Palette.fixed(0xFFC2BC) : Palette.fixed(0xFFADA6))
        }
    }

    /// The glass behind what an error has lost: dark on the board, a faint tint elsewhere.
    private var emptyFill: Color {
        if let tint { return tint.opacity(0.12) }
        return style == .board ? Palette.fixed(0x1C1C1E).opacity(0.62) : look.fill.opacity(0.1)
    }

    private var twinkleScale: CGFloat {
        guard style == .board, !reduceMotion else { return 0.8 }
        return isTwinkling ? 1 : 0.35
    }

    private var twinkleOpacity: Double {
        guard style == .board, !reduceMotion else { return 1 }
        return isTwinkling ? 1 : 0.2
    }

    // MARK: Motion

    private func arrive() async {
        guard style == .board else { return }
        guard !reduceMotion else {
            hasLanded = true
            isSettled = true
            return
        }
        try? await Task.sleep(for: .seconds(delay))
        withAnimation(.smooth(duration: 0.35)) { hasLanded = true }
        if grade == .best || grade == .good {
            withAnimation(.easeInOut(duration: 0.9).delay(0.3)) { glint = 1 }
        }
        if grade == .best, bursts {
            withAnimation(.easeOut(duration: 0.9).delay(0.1)) { burst = 1 }
        }
        switch grade {
        case .inaccuracy, .mistake:
            withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.55).delay(0.3)) { isSettled = true }
        case .blunder:
            withAnimation(.spring(response: 0.45, dampingFraction: 0.55).delay(0.35)) { isSettled = true }
        case .best, .good:
            isSettled = true
        }
        if grade == .mistake {
            try? await Task.sleep(for: .seconds(0.85))
            wiggles += 1
        }
        if grade == .best {
            try? await Task.sleep(for: .seconds(0.6))
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { isTwinkling = true }
        }
    }
}

/// Eight sparks thrown out from the star's centre: they flash in, fly out and fade.
private struct SparkBurst: View, Animatable {
    var progress: Double
    let unit: CGFloat
    let color: Color

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let opacity = progress <= 0 || progress >= 1 ? 0 : (progress < 0.15 ? progress / 0.15 : 1 - (progress - 0.15) / 0.85)
        let travel = 18 * unit * CGFloat(1 - pow(1 - progress, 3))
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                let angle = Double(index) * .pi / 4 - .pi / 2
                Group {
                    if index.isMultiple(of: 2) {
                        SparkleShape().fill(color).frame(width: 4.8 * unit, height: 4.8 * unit)
                    } else {
                        Circle().fill(color).frame(width: 2 * unit, height: 2 * unit)
                    }
                }
                .scaleEffect(1 - 0.6 * progress)
                .offset(x: CGFloat(cos(angle)) * travel, y: CGFloat(sin(angle)) * travel - 0.5 * unit)
            }
        }
        .opacity(opacity)
    }
}

/// A four-pointed sparkle with curved sides.
struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let pinch = min(rect.width, rect.height) * 0.08
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: c.y), control: CGPoint(x: c.x + pinch, y: c.y - pinch))
        path.addQuadCurve(to: CGPoint(x: c.x, y: rect.maxY), control: CGPoint(x: c.x + pinch, y: c.y + pinch))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: c.y), control: CGPoint(x: c.x - pinch, y: c.y + pinch))
        path.addQuadCurve(to: CGPoint(x: c.x, y: rect.minY), control: CGPoint(x: c.x - pinch, y: c.y - pinch))
        path.closeSubpath()
        return path
    }
}

/// The star and its pieces, as points in a 24-point box scaled to whatever rect they fill.
struct StarOutline: Shape {
    let points: [CGPoint]
    var isClosed = true

    static let star = StarOutline(points: points([12, 2.5, 14.9, 8.6, 21.5, 9.4, 16.6, 14, 17.9, 20.6,
                                                  12, 17.3, 6.1, 20.6, 7.4, 14, 2.5, 9.4, 9.1, 8.6]))
    static let leftHalf = StarOutline(points: points([11.4, 3.3, 9.1, 8.6, 2.5, 9.4, 7.4, 14, 6.1, 20.6, 11.4, 17.6]))
    static let rightHalf = StarOutline(points: points([12.6, 3.3, 14.9, 8.6, 21.5, 9.4, 16.6, 14, 17.9, 20.6, 12.6, 17.6]))
    /// The bright edge along the upper left, where the light catches the glass.
    static let specular = StarOutline(points: points([3.6, 9.6, 9.4, 8.9, 12, 3.4]), isClosed: false)
    static let leftSpecular = StarOutline(points: points([3.6, 9.6, 9.4, 8.9, 11, 4.6]), isClosed: false)

    /// x, y pairs.
    private static func points(_ values: [CGFloat]) -> [CGPoint] {
        stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
    }

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let origin = CGPoint(x: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
        var path = Path()
        path.addLines(points.map { CGPoint(x: origin.x + $0.x * scale, y: origin.y + $0.y * scale) })
        if isClosed { path.closeSubpath() }
        return path
    }
}
