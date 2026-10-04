//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// Liquid Glass, used the way Apple's guidance asks: only for controls that float above content —
/// selectors, the review scrubber, toolbar and tab bar — never for the content itself.
///
/// iOS 26 and later get the system material. Earlier versions get a translucent material with a
/// hairline edge, which reads the same way without pretending to be glass.
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 0.5))
        }
    }
}

/// Groups neighbouring glass so the shapes blend as one piece of material on iOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A capsule control made of glass: filters, secondary actions, selectors.
struct GlassCapsuleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? Palette.onBrand : Palette.ink)
            .padding(.horizontal, 16)
            .frame(minHeight: Layout.minimumTarget)
            .background {
                if prominent {
                    Capsule().fill(Palette.brand.opacity(configuration.isPressed ? 0.82 : 1))
                }
            }
            .glassSurface(in: Capsule(), interactive: true)
            .opacity(configuration.isPressed && !prominent ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// A segmented selector on a glass capsule: the selection is a brighter pill inside it.
struct GlassSegmented<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item
    var accessibilityName = "Selection"

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                let isSelected = selection == item
                Button {
                    selection = item
                } label: {
                    Text(title(item))
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Palette.ink : Palette.inkSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.16) : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .glassSurface(in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityName)
    }
}
