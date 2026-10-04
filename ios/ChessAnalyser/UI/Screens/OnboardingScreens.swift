//  Chess Analyser — analyse public Chess.com games on your own device.
//  Copyright (C) 2026 Chess Analyser contributors
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
                        Text("Follow any public Chess.com player. Every game is analysed on this device, and every mistake comes with the line that proves it.")
                            .font(.subheadline)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)

                    VStack(spacing: 10) {
                        Button("Add a player") { showsAddPlayer = true }
                            .buttonStyle(PrimaryButtonStyle())
                        Button("Import a backup") { showsImport = true }
                            .buttonStyle(SecondaryButtonStyle())
                    }

                    Text("No Chess.com password is needed and no account is created. This app is independent and not affiliated with Chess.com.")
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
            .navigationTitle("Chess Analyser")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showsAddPlayer) { AddPlayerSheet() }
            .sheet(isPresented: $showsImport) { BackupSheet(startInImport: true) }
        }
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
        Text("Search for a Chess.com account")
            .font(.display(.title, weight: .regular))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 6) {
            Text("Chess.com username").eyebrowStyle()
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
            InfoBanner(title: error.errorDescription ?? "Lookup failed",
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
                                 ? "No Chess.com player ID was returned"
                                 : "Chess.com player ID verified")
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
        guard ChessComClient.normalize(username: username) != nil else {
            validationMessage = "Enter a username, without a URL or path."
            return
        }
        stage = .resolving
        do {
            let profile = try await model.sync.resolveProfile(username: username)
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
            validationMessage = "The free plan tracks up to \(FreePlan.maxPlayers) players. Remove one, or subscribe to track more."
        } catch {
            validationMessage = "That player could not be saved."
        }
    }
}

/// W03. Shows what has arrived so far and lets the person leave without losing the download.
struct ImportingHistoryView: View {
    @Environment(AppModel.self) private var model
    let player: TrackedPlayer
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Downloading\n\(player.displayUsername)'s games")
                .font(.display(.title2))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)

            Panel {
                VStack(alignment: .leading, spacing: 12) {
                    let progress = model.refreshProgress
                    CoverageBar(fraction: fraction(progress))
                    HStack {
                        Text(progress.map { "\($0.monthsCompleted) of \($0.monthsTotal) months" } ?? "Starting\u{2026}")
                            .font(.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                        Spacer()
                        Text("\(progress?.gamesStored ?? 0) games")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.ink)
                            .monospacedDigit()
                    }
                    if let month = model.refreshProgress?.currentMonthLabel {
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
                    Task { await model.refreshSelectedPlayer() }
                }
            }

            InfoBanner(title: "You can leave this screen",
                       message: "Downloaded games are kept. Chess.com caches its archives, so the newest games can take a few minutes to appear.",
                       tone: .info)

            Button("Open available games") { onDone() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .task {
            await model.refreshSelectedPlayer()
        }
    }

    private func fraction(_ progress: RefreshProgress?) -> Double {
        guard let progress, progress.monthsTotal > 0 else { return 0.04 }
        return Double(progress.monthsCompleted) / Double(progress.monthsTotal)
    }
}

// MARK: - W04 Tracked players

struct PlayersSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
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

                    if model.canAddPlayer {
                        Button("Add another player") { showsAdd = true }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        InfoBanner(title: "Free plan tracks \(FreePlan.maxPlayers) players",
                                   message: "Remove a player to add a different one, or subscribe to track as many as you like. Each player keeps its own analyses.",
                                   tone: .warning)
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
                Button("Update username") { relinking = player }
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
        var parts: [String] = [player.status.label]
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
