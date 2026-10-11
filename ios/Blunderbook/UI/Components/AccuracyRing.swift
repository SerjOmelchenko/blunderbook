//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// A game's accuracy as an amber arc on a faint track, filled clockwise from the top. The same
/// ring as the app icon.
struct AccuracyRing: View {
    enum Style {
        /// The whole-number figure inside the ring, for the trailing edge of a row. Read out as
        /// "Accuracy 87.3".
        case badge
        /// A small ring with no figure, beside text that already gives the number, where a
        /// badge would make the line taller. Hidden from VoiceOver, since the text says it.
        case inline
        /// As `inline`, sized to sit beside a large figure such as a stat tile's.
        case figure
    }

    let value: Double
    var style: Style = .badge
    @ScaledMetric(relativeTo: .subheadline) private var badgeDiameter: CGFloat = 36
    @ScaledMetric(relativeTo: .caption) private var inlineDiameter: CGFloat = 14
    @ScaledMetric(relativeTo: .title) private var figureDiameter: CGFloat = 24

    var body: some View {
        switch style {
        case .badge:
            ring(diameter: badgeDiameter, lineWidth: badgeDiameter * 0.1)
                .overlay {
                    Text("\(figure)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.ink)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                        .padding(badgeDiameter * 0.15)
                }
                .accessibilityElement()
                .accessibilityLabel("Accuracy \(Format.accuracy(value))")
        case .inline:
            ring(diameter: inlineDiameter, lineWidth: inlineDiameter * 0.2)
                .accessibilityHidden(true)
        case .figure:
            ring(diameter: figureDiameter, lineWidth: figureDiameter * 0.16)
                .accessibilityHidden(true)
        }
    }

    private func ring(diameter: CGFloat, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, value / 100)))
                .stroke(Palette.brand, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .frame(width: diameter, height: diameter)
    }

    /// Rounded, except that only a perfect game shows 100: 99.6 would otherwise read as flawless.
    private var figure: Int {
        value >= 100 ? 100 : min(99, Int(value.rounded()))
    }
}
