//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

/// Owns the app model so it exists before launch finishes. A background-task launch never
/// connects a scene, and its handler still needs the queue (§7).
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor lazy var model = AppModel()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated {
            let background = BackgroundAnalysisController.shared
            background.attach(model: model)
            // Launch handlers must be registered before this method returns.
            background.registerLaunchHandlers()
        }
        return true
    }
}

@main
struct BlunderbookApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appDelegate.model)
                .tint(Palette.brand)
                // Night Board is a dark design; it is not offered in light.
                .preferredColorScheme(.dark)
                .task { appDelegate.model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            let model = appDelegate.model
            switch phase {
            case .active:
                BackgroundAnalysisController.shared.sceneDidBecomeActive()
                model.conditions.update()
                // Refresh on foreground; duplicate refreshes coalesce inside the model (§4).
                Task { await model.refreshSelectedPlayer() }
            case .background:
                model.persistSelection()
                BackgroundAnalysisController.shared.sceneDidEnterBackground()
            default:
                break
            }
        }
    }
}
