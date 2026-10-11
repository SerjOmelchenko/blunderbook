//  Blunderbook — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Blunderbook contributors
//
//  This program is free software: you can redistribute it and/or modify it under the terms of the
//  GNU General Public License as published by the Free Software Foundation, either version 3 of
//  the License, or (at your option) any later version. This program is distributed WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
//  PURPOSE. See the GNU General Public License (LICENSE) for more details.

import SwiftUI

// MARK: - W01 Welcome

struct WelcomeScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showsAddPlayer = false
    @State private var showsImport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\u{265E}")
                            .font(.system(size: 64))
                            .foregroundStyle(Palette.brand)
                            .accessibilityHidden(true)
                        Text("Find the moves\nthat matter.")
                            .font(.display(.largeTitle))
                            .foregroundStyle(Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Follow any public Chess.com or Lichess player. Every game is analysed by Stockfish on this device, move by move.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)

                    VStack(spacing: 10) {
                        Button("Add a player") {
                            model.isOnboarding = true
                            showsAddPlayer = true
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        Button("Import a backup") {
                            model.isOnboarding = true
                            showsImport = true
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }

                    Text("No password is needed and no account is created. This app is independent and not affiliated with Chess.com or Lichess.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let bootError = model.bootError {
                        InfoBanner(title: "The local database could not be opened",
                                   message: bootError, tone: .error)
                    }
                }
                .padding(Layout.gutter)
            }
            .screenBackground()
            .navigationTitle("Blunderbook")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsAddPlayer, onDismiss: finishOnboarding) { AddPlayerSheet() }
            .sheet(isPresented: $showsImport, onDismiss: finishOnboarding) { BackupSheet(startInImport: true) }
        }
    }

    /// Hands over to the main tabs once the sheet has closed, if a player now exists.
    private func finishOnboarding() {
        withAnimation(.smooth(duration: 0.35)) { model.isOnboarding = false }
    }
}

// MARK: - W02 Add player / W03 Importing history

struct AddPlayerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable {
        case entry
        case resolving
        case resolved(ProviderProfile)
        case importing(TrackedPlayer)
    }

    @State private var provider: Provider = .chessCom
    @State private var username = ""
    @State private var stage: Stage = .entry
    @State private var error: ProviderError?
    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch stage {
                    case .entry, .resolving, .resolved:
                        entryContent
                    case .importing(let player):
                        ImportingHistoryView(player: player) { dismiss() }
                    }
                }
                .padding(Layout.gutter)
            }
            .screenBackground()
            .navigationTitle(isImporting ? "Importing history" : "Add player")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isImporting ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    private var isImporting: Bool {
        if case .importing = stage { return true }
        return false
    }

    @ViewBuilder
    private var entryContent: some View {
        Text("Search for a \(provider.displayName) account")
            .font(.display(.title, weight: .regular))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)

        // Each site's accounts are tracked separately; a player on both is added twice.
        Picker("Site", selection: $provider) {
            ForEach(Provider.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .disabled(stage == .resolving)
        .onChange(of: provider) {
            error = nil
            validationMessage = nil
            stage = .entry
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("\(provider.displayName) username").eyebrowStyle()
            TextField("e.g. hikaru", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await resolve() } }
                .padding(.horizontal, 12)
                .frame(minHeight: Layout.minimumTarget)
                .background(
                    RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous)
                        .fill(Palette.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous)
                        .strokeBorder(Palette.hairline, lineWidth: 1)
                )
        }

        if let validationMessage {
            InfoBanner(title: validationMessage, tone: .error)
        }
        if let error {
            InfoBanner(title: error == .playerNotFound
                       ? "No \(provider.displayName) player has that name."
                       : error.errorDescription ?? "Lookup failed",
                       message: error.recoverySuggestion,
                       tone: error == .offline ? .warning : .error)
        }

        if case .resolved(let profile) = stage {
            Panel {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text(String(profile.username.prefix(2)).uppercased())
                            .font(.display(.headline))
                            .foregroundStyle(Palette.onBrand)
                            .frame(width: 42, height: 42)
                            .background(Circle().fill(Palette.brand))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.username)
                                .font(.headline)
                                .foregroundStyle(Palette.ink)
                            Text(profile.providerID == nil
                                 ? "No \(profile.provider.displayName) player ID was returned"
                                 : "\(profile.provider.displayName) player ID verified")
                                .font(.caption)
                                .foregroundStyle(Palette.inkSecondary)
                        }
                    }
                    if let name = profile.name {
                        Text(name).font(.footnote).foregroundStyle(Palette.inkSecondary)
                    }
                    if profile.providerID == nil {
                        Text("This profile will be tracked under a local identity only. It will never be merged with another player on the username alone.")
                            .font(.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Button("Track this player") { track(profile) }
                .buttonStyle(PrimaryButtonStyle())
        } else {
            Button {
                Task { await resolve() }
            } label: {
                if case .resolving = stage {
                    HStack(spacing: 8) { ProgressView().tint(.white); Text("Looking up\u{2026}") }
                } else {
                    Text("Find player")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(stage == .resolving)
        }

        Text("Tracking someone does not notify them.")
            .font(.caption)
            .foregroundStyle(Palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func resolve() async {
        error = nil
        validationMessage = nil
        guard provider.normalize(username: username) != nil else {
            validationMessage = "Enter a username, without a URL or path."
            return
        }
        stage = .resolving
        do {
            let profile = try await model.sync.resolveProfile(username: username, provider: provider)
            stage = .resolved(profile)
        } catch let providerError as ProviderError {
            error = providerError
            stage = .entry
        } catch {
            self.error = .malformedResponse
            stage = .entry
        }
    }

    private func track(_ profile: ProviderProfile) {
        do {
            let player = try model.addPlayer(profile: profile)
            model.reloadPlayers()
            stage = .importing(player)
        } catch PlayerLimitError.freeLimitReached {
            validationMessage = "The free plan tracks \(FreePlan.playersDescription). Remove one, or subscribe to track more."
        } catch {
            validationMessage = "That player could not be saved."
        }
    }
}

/// W03. Shows what has arrived so far and lets the person leave without losing the download.
/// When the download finishes it says so, then closes by itself.
struct ImportingHistoryView: View {
    @Environment(AppModel.self) private var model
    let player: TrackedPlayer
    var onDone: () -> Void

    /// Games stored once the download has finished; nil while it runs.
    @State private var finishedCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(finishedCount == nil
                 ? "Downloading\n\(player.displayUsername)'s games"
                 : "\(player.displayUsername)'s games\nare ready")
                .font(.display(.title2))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)

            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    let progress = model.refreshProgress
                    CoverageBar(fraction: finishedCount != nil ? 1 : fraction(progress))
                    HStack {
                        Text(statusText(progress))
                            .font(.footnote)
                            .foregroundStyle(finishedCount != nil ? Palette.improved : Palette.inkSecondary)
                        Spacer()
                        Text("\((finishedCount ?? progress?.gamesStored ?? 0).formatted()) games")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    if finishedCount == nil, let month = progress?.currentMonthLabel {
                        Text("Reading \(month)")
                            .font(.caption)
                            .foregroundStyle(Palette.inkTertiary)
                    }
                }
            }

            if let error = model.refreshError {
                InfoBanner(title: error.errorDescription ?? "Download failed",
                           message: error.recoverySuggestion,
                           tone: error == .offline ? .warning : .error,
                           actionTitle: "Retry") {
                    Task { await runImport() }
                }
            }

            if finishedCount == nil {
                InfoBanner(title: "You can leave this screen",
                           message: player.provider == .chessCom
                               ? "Downloaded games are kept. Chess.com caches its archives, so the newest games can take a few minutes to appear."
                               : "Downloaded games are kept. Lichess sends about 20 games a second, so a long history takes a few minutes.",
                           tone: .info)
            }

            Button(finishedCount == nil ? "Open available games" : "Open games") { onDone() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .animation(.smooth(duration: 0.3), value: finishedCount)
        .task { await runImport() }
    }

    private func statusText(_ progress: RefreshProgress?) -> String {
        if finishedCount != nil { return "Done" }
        if let progress, progress.monthsTotal > 0 {
            return "\(progress.monthsCompleted) of \(progress.monthsTotal) months"
        }
        if let progress, progress.gamesExpected > 0 {
            return "About \(progress.gamesExpected.formatted()) to download"
        }
        return "Starting\u{2026}"
    }

    /// Downloads, then shows the result for a moment and closes. A failure stays on screen with
    /// Retry; leaving the screen ends only the wait, never the download.
    private func runImport() async {
        await model.refreshSelectedPlayer()
        guard !Task.isCancelled, model.refreshError == nil else { return }
        finishedCount = (try? model.games.totalGameCount(playerID: player.id)) ?? 0
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled else { return }
        onDone()
    }

    private func fraction(_ progress: RefreshProgress?) -> Double {
        guard let progress else { return 0.04 }
        if progress.monthsTotal > 0 {
            return Double(progress.monthsCompleted) / Double(progress.monthsTotal)
        }
        if progress.gamesExpected > 0 {
            // The profile's count includes games that are not downloaded, such as variants.
            return max(0.04, min(0.97, Double(progress.gamesStored) / Double(progress.gamesExpected)))
        }
        return 0.04
    }
}

// MARK: - W04 Tracked players

struct PlayersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.showPaywall) private var showPaywall
    @State private var showsAdd = false
    @State private var pendingRemoval: TrackedPlayer?
    @State private var relinking: TrackedPlayer?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Tracked players")
                        .font(.display(.title2))
                        .foregroundStyle(Palette.ink)
                    Text("Each player keeps its own downloaded history and reviews.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)

                    Panel(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(model.trackedPlayers.enumerated()), id: \.element.id) { index, player in
                                if index > 0 { Hairline().padding(.leading, 16) }
                                playerRow(player)
                            }
                        }
                    }

                    VStack(spacing: 8) {
                        Button {
                            if model.canAddPlayer { showsAdd = true } else { showPaywall() }
                        } label: {
                            PremiumLabel("Add another player", locked: !model.canAddPlayer)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        if !model.canAddPlayer {
                            Text("The free plan tracks \(FreePlan.playersDescription). Premium tracks as many as you like, on Chess.com and Lichess.")
                                .font(.caption)
                                .foregroundStyle(Palette.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(Layout.gutter)
            }
            .screenBackground()
            .navigationTitle("Players")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showsAdd) { AddPlayerSheet() }
            .sheet(item: $relinking) { player in UpdateUsernameSheet(player: player) }
            .alert("Remove \(pendingRemoval?.displayUsername ?? "")?",
                   isPresented: Binding(get: { pendingRemoval != nil },
                                        set: { if !$0 { pendingRemoval = nil } })) {
                Button("Remove", role: .destructive) {
                    if let player = pendingRemoval { try? model.removePlayer(player) }
                    pendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("This deletes the local profile, its downloaded games and its saved reviews. Games shared with another tracked player are kept. Your subscription is not affected.")
            }
        }
    }

    private func playerRow(_ player: TrackedPlayer) -> some View {
        let isSelected = player.id == model.selectedPlayer?.id
        return HStack(spacing: 12) {
            Button {
                model.selectPlayer(player)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    Text(player.initials)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.white : Palette.brand)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(isSelected ? Palette.brand : Palette.brandSoft))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.displayUsername)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(statusText(player))
                            .font(.caption)
                            .foregroundStyle(player.status.needsAttention ? Palette.loss : Palette.inkSecondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Palette.brand)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                if player.provider.allowsRenames {
                    Button("Update username") { relinking = player }
                }
                Button("Remove player", role: .destructive) { pendingRemoval = player }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("More options for \(player.displayUsername)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: Layout.minimumTarget + 10)
    }

    private func statusText(_ player: TrackedPlayer) -> String {
        var parts: [String] = [player.provider.displayName, player.status.label]
        if let checked = player.lastSuccessfulRefresh {
            parts.append("last checked \(Format.relative(checked))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - W27 Update username

struct UpdateUsernameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let player: TrackedPlayer

    @State private var newUsername = ""
    @State private var isWorking = false
    @State private var message: (String, BannerTone)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Update username")
                        .font(.display(.title2))
                        .foregroundStyle(Palette.ink)
                    Text("If \(player.displayUsername) changed their Chess.com name, enter the new one. The profile is relinked only when it resolves to the same Chess.com player ID — a different ID is a different player and is tracked separately.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("New username").eyebrowStyle()
                        TextField("username", text: $newUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12)
                            .frame(minHeight: Layout.minimumTarget)
                            .background(RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous).fill(Palette.surface))
                            .overlay(RoundedRectangle(cornerRadius: Layout.controlRadius, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
                    }

                    if let message {
                        InfoBanner(title: message.0, tone: message.1)
                    }

                    Button(isWorking ? "Checking\u{2026}" : "Check and relink") {
                        Task { await relink() }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isWorking || newUsername.isEmpty)
                }
                .padding(Layout.gutter)
            }
            .screenBackground()
            .navigationTitle("Update username")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
    }

    private func relink() async {
        isWorking = true
        defer { isWorking = false }
        switch await model.relink(player: player, to: newUsername) {
        case .relinked:
            message = ("Relinked. The saved history and reviews were kept.", .success)
        case .mismatch(let name):
            message = ("\(name) resolves to a different Chess.com player ID, so it cannot be merged. Add it as a separate player instead.", .error)
        case .notFound:
            message = ("That username did not resolve. Your saved data is unchanged.", .error)
        }
    }
}
