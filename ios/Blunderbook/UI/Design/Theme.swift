//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// The app's visual language, "Night Board": a near-black ground, one amber accent, and the
/// system face throughout, with tabular figures wherever a number matters.
///
/// Content sits directly on the ground — rows split by hairlines rather than boxed in cards — and
/// Liquid Glass is reserved for the controls that float above it (see `Glass.swift`). The design
/// is dark by nature, so the app runs in dark appearance and every colour here is a single value.
enum Palette {
    static func fixed(_ hex: UInt32) -> Color { Color(UIColor(hex: hex)) }

    // Surfaces
    static let background = fixed(0x0E0F0E)
    static let surface = fixed(0x18191A)
    static let surfaceSunken = fixed(0x141514)
    static let surfaceRaised = fixed(0x222325)
    static let line = fixed(0x232423)
    static let hairline = fixed(0x2E2F2E)

    // Text
    static let ink = fixed(0xF2F2F2)
    static let inkSecondary = fixed(0x9A9AA0)
    static let inkTertiary = fixed(0x7C7C82)

    // Accent. Text on an accent fill uses `onBrand`: amber is too light for white text.
    static let brand = fixed(0xF5B546)
    static let brandDeep = fixed(0xD9962A)
    static let brandSoft = fixed(0x2A2214)
    static let onBrand = fixed(0x1A1305)
    static let brass = fixed(0xE0A43A)
    static let brassSoft = fixed(0x2A2214)

    // Board
    static let boardLight = fixed(0xC8CBC4)
    static let boardDark = fixed(0x6B7A70)
    static let boardFrame = fixed(0x3A3B3A)
    static let boardHighlight = fixed(0xD9C27A)
    static let pieceLight = fixed(0xFFFFFF)
    static let pieceDark = fixed(0x141414)

    // Meaning — each also differs in lightness, and is always paired with text.
    static let win = fixed(0x7ED9A0)
    static let draw = fixed(0xAEAEB2)
    static let loss = fixed(0xFF8A7A)
    static let improved = fixed(0x7ED9A0)
    static let declined = fixed(0xFF6B5E)
    static let inaccuracy = fixed(0xE8CF6A)
    static let mistake = fixed(0xF59E5B)
    static let blunder = fixed(0xFF6B5E)
    static let best = fixed(0x7ED9A0)
    /// Known opening theory: a book move.
    static let book = fixed(0xC9A27A)
}

extension Severity {
    var color: Color {
        switch self {
        case .inaccuracy: return Palette.inaccuracy
        case .mistake: return Palette.mistake
        case .blunder: return Palette.blunder
        }
    }
}

extension EvalTrend {
    var color: Color {
        switch self {
        case .improved: return Palette.improved
        case .declined: return Palette.declined
        case .level: return Palette.draw
        }
    }
}

extension GameOutcome {
    var color: Color {
        switch self {
        case .win: return Palette.win
        case .draw: return Palette.draw
        case .loss: return Palette.loss
        case .unknown: return Palette.inkTertiary
        }
    }
}

extension Font {
    /// The system face, scaled by Dynamic Type. Used for headings and any large figure.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .semibold) -> Font {
        .system(style).weight(weight)
    }

    /// The single oversized figure a screen leads with, such as the current rating.
    static var hero: Font { .system(size: 72, weight: .bold).monospacedDigit() }

    static var eyebrow: Font { .system(.footnote).weight(.regular) }
    static var numeral: Font { .system(.title2).weight(.semibold).monospacedDigit() }
}

extension View {
    /// Quiet label above a section or figure. Sentence case: capitals read as shouting here.
    func eyebrowStyle() -> some View {
        font(.eyebrow)
            .foregroundStyle(Palette.inkSecondary)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

enum Layout {
    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 22
    static let gutter: CGFloat = 16
    /// Inset for content that sits directly on the ground, aligned with list rows.
    static let contentInset: CGFloat = 24
    static let tightGutter: CGFloat = 12
    /// Minimum tappable size (§11).
    static let minimumTarget: CGFloat = 44
}
