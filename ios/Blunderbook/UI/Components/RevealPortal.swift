//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI
import UIKit

/// The way from a set of rings to its game, once the analysis lands with nobody touching the
/// screen: the game's row rings in Games, or the bottom bar's when the row is off screen. The
/// rings settle on the game's accuracies where they are, then you fly through them:
/// the game is already showing inside the smallest ring and fills the screen as the rings pass
/// you, while the list around them comes towards you out of focus and darkens.
///
/// How it is built: the screen is photographed the moment the rings stop (`Self.snapshot`), and
/// the photo stands in for the list from then on. The game is pushed underneath it at once, with
/// no transition of its own, and shows through a hole in the photo that grows with the rings;
/// `onFlight` scales the real game screen up from 0.55 behind that hole.
///
/// Reduce Motion: the photo fades away over the game instead.
struct RevealPortal: View {
    let reveal: AppModel.Reveal
    /// The photo covers the screen: open the game now, without a transition of its own.
    let onCovered: () -> Void
    /// The flight starts: scale the game up to full size over `flight`.
    let onFlight: () -> Void
    let onFinished: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshot: UIImage?
    /// When the photo went up and the rings began to settle.
    @State private var start: Date?
    /// When the flight through the rings began; until then the rings are settling.
    @State private var flightStart: Date?

    static let settle = 0.55
    static let flight = 0.9
    private static let stagger = 0.07
    /// The longest the rings wait, settled, for the game to appear behind the photo.
    private static let arrivalTimeout = 1.2
    private static let fadeOut = 0.3
    /// How small the game starts inside the hole, as `onFlight` scales it to full size.
    static let gameStartScale: CGFloat = 0.55

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let centre = CGPoint(x: reveal.origin.x - frame.minX, y: reveal.origin.y - frame.minY)
            if let snapshot, let start {
                TimelineView(.animation) { context in
                    if reduceMotion {
                        fade(snapshot, at: context.date, size: proxy.size)
                    } else {
                        scene(snapshot, at: context.date, start: start, centre: centre, size: proxy.size)
                    }
                }
            }
        }
        .ignoresSafeArea()
        // Nothing underneath takes a tap while the rings pass.
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityHidden(true)
        .task { await run() }
    }

    private func run() async {
        // One frame for the row to hide its rings, then photograph the screen without them.
        try? await Task.sleep(for: .milliseconds(30))
        guard let image = Self.snapshot() else {
            onCovered()
            onFinished()
            return
        }
        snapshot = image
        start = Date()
        onCovered()
        // Settle, and wait for the game to be on screen behind the photo.
        let settledAt = Date().addingTimeInterval(reduceMotion ? 0 : Self.settle)
        let deadline = Date().addingTimeInterval(Self.arrivalTimeout)
        while Date() < settledAt || (model.reveal?.hasArrived != true && Date() < deadline) {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(16))
        }
        try? await Task.sleep(for: .milliseconds(30))
        flightStart = Date()
        if !reduceMotion {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
            onFlight()
        }
        try? await Task.sleep(for: .seconds(reduceMotion ? Self.fadeOut : Self.flight))
        onFinished()
    }

    // MARK: Drawing

    private func scene(_ image: UIImage, at date: Date, start: Date, centre: CGPoint, size: CGSize) -> some View {
        let p = flightStart.map { clamp(date.timeIntervalSince($0) / Self.flight) } ?? 0
        let e = easeInOut(p)
        let scale = reveal.ringScale
        let innermost = Self.radius(ring: 2) * scale
        let zMax = (farthestCorner(from: centre, in: size) + 60) / innermost
        let zoom = flightStart == nil ? 1 : exp(log(zMax) * e)
        let width = 3.5 * scale * pow(zoom, 0.42)
        let hole = flightStart == nil ? 0 : max(0, innermost * zoom - width / 2 - 1)
        let anchor = UnitPoint(x: centre.x / max(1, size.width), y: centre.y / max(1, size.height))
        let settleTime = date.timeIntervalSince(start)

        return ZStack {
            // The list as it was, coming towards you out of focus, darkening around the hole.
            Image(uiImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
                .overlay(Color.black.opacity(0.55 * e))
                .scaleEffect(1 + 0.3 * e, anchor: anchor)
                .blur(radius: 7 * e)
                .mask {
                    HolePunch(centre: centre, radius: hole)
                        .fill(style: FillStyle(eoFill: true))
                }
            Canvas { context, _ in
                let alpha = 1 - smooth(0.55, 0.95, p)
                guard alpha > 0 else { return }
                for ring in 0..<3 {
                    let radius = Self.radius(ring: ring) * scale * zoom
                    let arc = settledArc(ring: ring, at: settleTime)
                    let circle = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                                        width: radius * 2, height: radius * 2))
                    context.stroke(circle, with: .color(.white.opacity(0.10 * alpha)), lineWidth: width)
                    guard arc.length > 0 else { continue }
                    var path = Path()
                    let startAngle = Angle.degrees(arc.angle - 90)
                    path.addArc(center: centre, radius: radius, startAngle: startAngle,
                                endAngle: startAngle + .degrees(arc.length * 360), clockwise: false)
                    context.stroke(path, with: .color(AccuracyRings.colors[ring].opacity(alpha)),
                                   style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func fade(_ image: UIImage, at date: Date, size: CGSize) -> some View {
        let p = flightStart.map { clamp(date.timeIntervalSince($0) / Self.fadeOut) } ?? 0
        return Image(uiImage: image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .opacity(1 - p)
    }

    /// The same three rings as the row's (`AccuracyRings`), at its 40-point size.
    private static func radius(ring: Int) -> CGFloat { (40 - 3.5 - CGFloat(ring) * 9.5) / 2 }

    /// One ring easing out of its spin onto the game's accuracy, the way `AccuracyRings`
    /// settles: it finishes the turn in the direction it was spinning and stops at the top.
    private func settledArc(ring: Int, at time: Double) -> (angle: Double, length: Double) {
        let target = ring < reveal.values.count ? reveal.values[ring] / 100 : 0
        let p = clamp((time - Double(ring) * Self.stagger) / (Self.settle - 2 * Self.stagger))
        let from = AccuracyRings.spinAngle(ring: ring, at: reveal.spunAt)
        let speed = AccuracyRings.speeds[ring]
        var delta = speed > 0 ? 360 - from : -from
        if abs(delta) < 90 { delta += speed > 0 ? 360 : -360 }
        let length = AccuracyRings.spinLength + (target - AccuracyRings.spinLength) * easeOutBack(p)
        return (from + delta * easeOut(p), min(0.995, max(0, length)))
    }

    /// The key window as it looks now, without the status bar.
    @MainActor
    static func snapshot() -> UIImage? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        return renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func farthestCorner(from point: CGPoint, in size: CGSize) -> CGFloat {
        let dx = max(point.x, size.width - point.x)
        let dy = max(point.y, size.height - point.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }
    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    private func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    private func easeOutBack(_ x: Double) -> Double {
        let overshoot = 1.4
        return 1 + (overshoot + 1) * pow(x - 1, 3) + overshoot * pow(x - 1, 2)
    }
}

/// The whole rectangle with a circle cut out of it, for an even-odd fill.
private struct HolePunch: Shape {
    var centre: CGPoint
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if radius > 0 {
            path.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                       width: radius * 2, height: radius * 2))
        }
        return path
    }
}

/// Notes when a finger goes down anywhere in the window, without taking part in any gesture:
/// its recognizer fails as soon as a touch begins, so it never delays, cancels or wins anything.
struct TouchActivityMonitor: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> MonitorView { MonitorView(onTouch: onTouch) }
    func updateUIView(_ view: MonitorView, context: Context) { view.onTouch = onTouch }

    final class MonitorView: UIView {
        var onTouch: () -> Void
        private var recognizer: TouchBeganRecognizer?

        init(onTouch: @escaping () -> Void) {
            self.onTouch = onTouch
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let recognizer {
                recognizer.view?.removeGestureRecognizer(recognizer)
                self.recognizer = nil
            }
            guard let window else { return }
            let recognizer = TouchBeganRecognizer { [weak self] in self?.onTouch() }
            window.addGestureRecognizer(recognizer)
            self.recognizer = recognizer
        }
    }
}

private final class TouchBeganRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let began: () -> Void

    init(began: @escaping () -> Void) {
        self.began = began
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        began()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
