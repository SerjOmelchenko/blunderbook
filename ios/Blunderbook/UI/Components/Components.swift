//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Serhii Omelchenko
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// MARK: - Containers

/// A quiet grouping on the ground: slightly lifted, no border, no shadow. Most content needs no
/// container at all — rows split by hairlines — so this is for the few places a group must hold.
struct Panel<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Layout.cardRadius, style: .continuous)
                    .fill(Palette.surface)
            )
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.brand)
                    .frame(minHeight: Layout.minimumTarget)
            }
        }
    }
}

// MARK: - Buttons

/// The one filled action on a screen: an amber capsule.
struct PrimaryButtonStyle: ButtonStyle {
    var tone: Color = Palette.brand
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(tone == Palette.brand ? Palette.onBrand : Color.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(Capsule().fill(tone.opacity(configuration.isPressed ? 0.82 : 1)))
            .contentShape(Capsule())
    }
}

/// Every other action: a glass capsule.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .glassSurface(in: Capsule(), interactive: true)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.loss)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(Capsule().fill(Palette.loss.opacity(configuration.isPressed ? 0.20 : 0.12)))
            .contentShape(Capsule())
    }
}

// MARK: - Small pieces

/// A button title with a lock when the action needs Premium, so that is clear before the tap.
struct PremiumLabel: View {
    let title: String
    var locked: Bool

    init(_ title: String, locked: Bool) {
        self.title = title
        self.locked = locked
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if locked {
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .accessibilityLabel("Premium")
            }
        }
    }
}

struct Badge: View {
    let text: String
    var tone: Color = Palette.inkSecondary
    var filled = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            // Every tone is light on this ground, so a filled badge takes dark text.
            .foregroundStyle(filled ? Palette.onBrand : tone)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? tone : tone.opacity(0.14))
            )
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Figures side by side with no boxes, stacked instead when the text size makes that unreadable.
struct StatTileRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ViewBuilder var content: Content

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) { content }
        } else {
            HStack(alignment: .top, spacing: 12) { content }
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A plain figure with its label underneath. With `ring`, an accuracy from 0 to 100 is drawn as
/// an `AccuracyRing` before the figure.
struct StatTile: View {
    let label: String
    let value: String
    var caption: String?
    var tone: Color = Palette.ink
    var ring: Double?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let ring {
                    AccuracyRing(value: ring, style: .figure)
                }
                Text(value)
                    .font(.title.weight(.semibold))
                    .foregroundStyle(tone)
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            }
            Text(label)
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(Palette.inkTertiary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

enum BannerTone {
    case info, warning, error, success

    var accent: Color {
        switch self {
        case .info: return Palette.inkSecondary
        case .warning: return Palette.brass
        case .error: return Palette.loss
        case .success: return Palette.win
        }
    }

    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        case .success: return "checkmark.seal"
        }
    }
}

/// A notice that sits on the ground: tinted icon, one line of weight, the rest quiet.
struct InfoBanner: View {
    let title: String
    var message: String?
    var tone: BannerTone = .info
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: tone.symbol)
                .font(.body)
                .foregroundStyle(tone.accent)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tone == .info ? Palette.brand : tone.accent)
                        .frame(minHeight: 36)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface)
        )
    }
}

/// Selector used for time class, segments and facets.
struct ChipRow<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item

    var body: some View {
        GlassSegmented(items: items, title: title, selection: $selection)
    }
}

struct CoverageBar: View {
    let fraction: Double
    var tone: Color = Palette.brand

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(tone)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

struct EmptyState: View {
    var symbol = "square.grid.3x3"
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.inkTertiary)
                .padding(.bottom, 4)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SecondaryButtonStyle())
                    .padding(.top, 8)
                    .frame(maxWidth: 240)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }
}

/// A row that reads as one tappable line: title, supporting text, trailing detail, chevron.
struct DetailRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var showsChevron = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
            }
            Spacer(minLength: 6)
            trailing
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.vertical, 12)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

extension DetailRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, showsChevron: Bool = true) {
        self.init(title: title, subtitle: subtitle, showsChevron: showsChevron) { EmptyView() }
    }
}

struct Hairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 1 / max(1, displayScale))
    }
}

/// Screen background used by every root screen.
struct ScreenBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Palette.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .modifier(DebugScrollAnchor())
    }
}

extension View {
    func screenBackground() -> some View { modifier(ScreenBackground()) }
}

// MARK: - Formatting

enum Format {
    static func accuracy(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    static func rate(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    static func percent(_ value: Double?, decimals: Int = 0) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(decimals)f%%", value)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded())) sec" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min" }
        let hours = seconds / 3600
        return String(format: "%.1f hours", hours)
    }

    static func durationRange(_ range: ClosedRange<TimeInterval>) -> String {
        "\(duration(range.lowerBound)) – \(duration(range.upperBound))"
    }

    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

// MARK: - Section separation

/// Heading that splits a screen into distinct regions of *provenance*.
///
/// Analytics shows two kinds of number that must never be mistaken for each other: figures read
/// straight from Chess.com, which cover every downloaded game, and figures derived from on-device
/// analysis, which only cover what has actually been analysed. This is the seam between them.
struct ProvenanceHeader: View {
    let kicker: String
    let title: String
    var message: String? = nil
    var symbol: String
    var tone: Color = Palette.inkSecondary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(kicker, systemImage: symbol)
                .font(.footnote.weight(.medium))
                .foregroundStyle(tone)
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(Palette.ink)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
    }
}

/// The analysis-derived region. Its own header marks the seam; no stripe or tint is needed.
struct DerivedDataGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Selector for a longer list of presets, such as the date range.
struct WrappingChipRow<Item: Hashable & Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item

    var body: some View {
        GlassSegmented(items: items, title: title, selection: $selection)
    }
}
