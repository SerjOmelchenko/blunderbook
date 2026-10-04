import SwiftUI
import UniformTypeIdentifiers

// MARK: - W18 Settings

struct SettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group("Players") {
                        ForEach(Array(model.trackedPlayers.enumerated()), id: \.element.id) { index, player in
                            if index > 0 { Hairline().padding(.leading, 16) }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(player.displayUsername)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Palette.ink)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Text(player.status.label)
                                        .font(.caption)
                                        .foregroundStyle(player.status.needsAttention ? Palette.loss : Palette.inkTertiary)
                                }
                                Text(playerSummary(for: player))
                                    .font(.caption)
                                    .foregroundStyle(Palette.inkSecondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .frame(minHeight: Layout.minimumTarget)
                        }
                    }

                    group("Plan") {
                        NavigationLink { SubscriptionScreen() } label: {
                            DetailRow(title: "Subscription") {
                                Text(model.entitlement.state.title)
                                    .font(.footnote)
                                    .foregroundStyle(Palette.inkSecondary)
                            }
                            .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                    }

                    group("Your data") {
                        NavigationLink { BackupScreen() } label: {
                            DetailRow(title: "Backup and restore",
                                      subtitle: "Export everything, or merge a backup back in")
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        Hairline().padding(.leading, 16)
                        NavigationLink { StorageScreen() } label: {
                            DetailRow(title: "Storage and data",
                                      subtitle: "Usage per player, and scoped deletion")
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                    }

                    group("About") {
                        NavigationLink { HowAnalysisWorksScreen() } label: {
                            DetailRow(title: "How analysis works",
                                      subtitle: "Thresholds, evidence policy and limitations")
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                        Hairline().padding(.leading, 16)
                        NavigationLink { AboutScreen() } label: {
                            DetailRow(title: "About and licences",
                                      subtitle: "Build, source, privacy and terms")
                                .padding(.horizontal, 16)
                        }
                        .buttonStyle(.plain)
                    }

                    Panel {
                        VStack(spacing: 0) {
                            versionRow("Version", "\(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
                            Hairline()
                            versionRow("Analysis policy", AnalysisPolicy.identifier)
                            Hairline()
                            versionRow("Engine", AnalysisPolicy.activeProvenance.engineVersion)
                        }
                    }

                    Text("There is no app account, no cloud sync and no analysis-quality setting. Everything here happens on this device.")
                        .font(.caption)
                        .foregroundStyle(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(Layout.gutter)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func playerSummary(for player: TrackedPlayer) -> String {
        let count = (try? model.games.totalGameCount(playerID: player.id)) ?? 0
        return "\(count.formatted()) game\(count == 1 ? "" : "s") downloaded"
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).eyebrowStyle().padding(.leading, 4)
            Panel(padding: 0) {
                VStack(spacing: 0) { content() }
            }
        }
    }

    private func versionRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.footnote).foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 16)
    }
}

// MARK: - W19–W22 Backup, export and import

struct BackupScreen: View {
    var body: some View { BackupSheet(startInImport: false).embeddedInSettings() }
}

private extension View {
    /// The backup flow is used both from Welcome (as a sheet) and from Settings (pushed).
    func embeddedInSettings() -> some View {
        navigationBarTitleDisplayMode(.inline)
    }
}

struct BackupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var startInImport = false

    @State private var exportURL: URL?
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportError: String?
    @State private var showsImporter = false
    @State private var staged: BackupService.StagedBackup?
    @State private var preview: BackupPreview?
    @State private var importError: String?
    @State private var importResult: ImportResult?
    @State private var isCommitting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let importResult {
                    importResultPanel(importResult)
                } else if let preview {
                    importPreviewPanel(preview)
                } else {
                    exportPanel
                    importPanel
                    contentsPanel
                }
            }
            .padding(Layout.gutter)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("Backup and restore")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showsImporter,
                      allowedContentTypes: [.data, .zip],
                      allowsMultipleSelection: false) { result in
            handleImportSelection(result)
        }
        .sheet(item: Binding(get: { exportURL.map(ShareItem.init) }, set: { _ in exportURL = nil })) { item in
            ShareSheet(url: item.url)
        }
        .onAppear { if startInImport { showsImporter = true } }
    }

    // MARK: Export

    private var exportPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "Create a backup",
                               subtitle: "A single .chessbackup file you keep yourself.")
                if isExporting {
                    CoverageBar(fraction: exportProgress)
                    Text("Writing from a consistent snapshot\u{2026}")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                } else {
                    Button("Export now") { Task { await runExport() } }
                        .buttonStyle(PrimaryButtonStyle())
                }
                if let exportError {
                    InfoBanner(title: "Export failed", message: exportError, tone: .error)
                }
                Text("Saving or sharing the file is handled by iOS. Returning from the share sheet is not proof that the file reached its destination.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runExport() async {
        isExporting = true
        exportError = nil
        exportProgress = 0
        let backup = model.backup
        let directory = FileManager.default.temporaryDirectory
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try backup.export(to: directory) { value in
                    Task { @MainActor in exportProgress = value }
                }
            }.value
            exportURL = url
        } catch {
            exportError = error.localizedDescription
        }
        isExporting = false
    }

    // MARK: Import

    private var importPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeading(title: "Restore from a backup",
                               subtitle: "Merges into what is already here; nothing is replaced.")
                Button("Choose a file") { showsImporter = true }
                    .buttonStyle(SecondaryButtonStyle())
                if let importError {
                    InfoBanner(title: "That backup could not be read", message: importError, tone: .error)
                }
            }
        }
    }

    private var contentsPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: "What a backup contains")
                bullet("Tracked players, downloaded games and their PGNs")
                bullet("Completed reviews with the engine and policy that produced them")
                Text("Not included").eyebrowStyle().padding(.top, 4)
                bullet("Queue progress and device timing samples")
                bullet("Subscription status — a file can never grant access")
                bullet("Engine assets and diagnostics")
                Text("Exported files contain player names and game data. Deleting the app can remove its database, so a backup is the controlled way to keep your reviews.")
                    .font(.caption)
                    .foregroundStyle(Palette.inkTertiary)
                    .padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("\u{2022}").foregroundStyle(Palette.brass)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(Palette.inkSecondary)
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let staged = try model.backup.stage(url: url)
                self.staged = staged
                preview = try model.backup.preview(staged)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            // A dismissed picker is not an error worth shouting about.
            if (error as NSError).code != NSUserCancelledError {
                importError = error.localizedDescription
            }
        }
    }

    private func importPreviewPanel(_ preview: BackupPreview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review this backup")
                .font(.display(.title2))
                .foregroundStyle(Palette.ink)

            Panel {
                VStack(spacing: 0) {
                    row("Created", Format.date(preview.manifest.createdAt))
                    Hairline()
                    row("New players", "\(preview.newPlayers.count)")
                    Hairline()
                    row("Already tracked", "\(preview.existingPlayers.count)")
                    Hairline()
                    row("New games", preview.newGames.formatted())
                    Hairline()
                    row("Duplicate games, skipped", preview.duplicateGames.formatted())
                    Hairline()
                    row("New reviews", preview.newAnalyses.formatted())
                    Hairline()
                    row("Existing reviews kept", preview.conflictingAnalyses.formatted())
                    Hairline()
                    row("Older-policy reviews", preview.olderPolicyAnalyses.formatted())
                }
            }

            if !preview.provisionalPlayers.isEmpty {
                InfoBanner(title: "Some players have no Chess.com ID",
                           message: "\(preview.provisionalPlayers.joined(separator: ", ")) will be added under a local identity and never merged on the username alone.",
                           tone: .warning)
            }

            VStack(spacing: 8) {
                Button(isCommitting ? "Importing\u{2026}" : "Import") { commit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isCommitting)
                Button("Choose another file") { self.preview = nil; staged = nil; showsImporter = true }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Cancel") { self.preview = nil; staged = nil }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func commit() {
        guard let staged else { return }
        isCommitting = true
        do {
            let result = try model.backup.commit(staged)
            importResult = result
            model.reloadPlayers()
            model.touch()
        } catch {
            importError = error.localizedDescription
            preview = nil
        }
        isCommitting = false
    }

    private func importResultPanel(_ result: ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import complete")
                .font(.display(.title2))
                .foregroundStyle(Palette.ink)
            Panel {
                VStack(spacing: 0) {
                    row("Players added", "\(result.playersAdded)")
                    Hairline()
                    row("Players merged", "\(result.playersMerged)")
                    Hairline()
                    row("Games added", result.gamesAdded.formatted())
                    Hairline()
                    row("Games already here", result.gamesSkipped.formatted())
                    Hairline()
                    row("Reviews added", result.analysesAdded.formatted())
                    Hairline()
                    row("Existing reviews kept", result.analysesKept.formatted())
                    Hairline()
                    row("Kept as history", result.historicalAnalyses.formatted())
                }
            }
            Button("Done") {
                importResult = nil
                staged = nil
                preview = nil
                dismiss()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.footnote).foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: 8)
            Text(value).font(.footnote.weight(.semibold)).foregroundStyle(Palette.ink).monospacedDigit()
        }
        .padding(.vertical, 9)
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - W23 Storage and data

struct StorageScreen: View {
    @Environment(AppModel.self) private var model
    @State private var usage: [(player: TrackedPlayer, games: Int, reviews: Int)] = []
    @State private var confirmation: Confirmation?

    struct Confirmation: Identifiable {
        enum Kind { case clearAnalyses(TrackedPlayer), removePlayer(TrackedPlayer), clearAll }
        let kind: Kind
        var id: String {
            switch kind {
            case .clearAnalyses(let player): return "clear-\(player.id)"
            case .removePlayer(let player): return "remove-\(player.id)"
            case .clearAll: return "all"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeading(title: "On this device")
                        HStack {
                            Text("Database").font(.footnote).foregroundStyle(Palette.inkSecondary)
                            Spacer()
                            Text(Format.bytes(model.database.fileSizeBytes))
                                .font(.footnote.weight(.semibold)).monospacedDigit()
                        }
                        HStack {
                            Text("Free space").font(.footnote).foregroundStyle(Palette.inkSecondary)
                            Spacer()
                            Text(Format.bytes(model.conditions.freeDiskBytes))
                                .font(.footnote.weight(.semibold)).monospacedDigit()
                        }
                        if model.conditions.blockers.contains(.storage) {
                            InfoBanner(title: "Storage is low",
                                       message: "Downloads and analysis are paused below 500 MB and resume above 750 MB. Nothing is deleted for you.",
                                       tone: .warning)
                        }
                    }
                }

                Panel(padding: 0) {
                    VStack(spacing: 0) {
                        SectionHeading(title: "By player")
                            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 4)
                        ForEach(Array(usage.enumerated()), id: \.element.player.id) { index, entry in
                            if index > 0 { Hairline().padding(.leading, 16) }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(entry.player.displayUsername)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text("\(entry.games) games · \(entry.reviews) reviews")
                                        .font(.caption)
                                        .foregroundStyle(Palette.inkSecondary)
                                        .monospacedDigit()
                                }
                                HStack(spacing: 8) {
                                    Button("Clear reviews") { confirmation = Confirmation(kind: .clearAnalyses(entry.player)) }
                                        .buttonStyle(SecondaryButtonStyle())
                                    Button("Remove player") { confirmation = Confirmation(kind: .removePlayer(entry.player)) }
                                        .buttonStyle(DestructiveButtonStyle())
                                }
                            }
                            .padding(16)
                        }
                    }
                }

                InfoBanner(title: "Export before deleting",
                           message: "A backup is the only way to get a deleted review back.",
                           tone: .info)

                Panel {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeading(title: "Everything", subtitle: "Cancels current work and deletes all local profiles, games and reviews.")
                        Button("Delete all local data") { confirmation = Confirmation(kind: .clearAll) }
                            .buttonStyle(DestructiveButtonStyle())
                        Text("This does not cancel an Apple subscription and does not touch backup files you have already exported.")
                            .font(.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Layout.gutter)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("Storage and data")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .alert(item: $confirmation) { confirmation in
            switch confirmation.kind {
            case .clearAnalyses(let player):
                return Alert(title: Text("Clear reviews for \(player.displayUsername)?"),
                             message: Text("Deletes the saved analyses and checkpoints for this player's games. The games themselves are kept, and reviews shared with another tracked player are protected."),
                             primaryButton: .destructive(Text("Clear reviews")) {
                                 _ = try? model.analyses.deleteAnalyses(playerID: player.id)
                                 load(); model.touch()
                             },
                             secondaryButton: .cancel())
            case .removePlayer(let player):
                return Alert(title: Text("Remove \(player.displayUsername)?"),
                             message: Text("Deletes the local profile, its game memberships, its queue items and any games no other tracked player references. Your subscription is unaffected."),
                             primaryButton: .destructive(Text("Remove")) {
                                 try? model.removePlayer(player)
                                 load()
                             },
                             secondaryButton: .cancel())
            case .clearAll:
                return Alert(title: Text("Delete all local data?"),
                             message: Text("Every tracked player, downloaded game and saved review on this device is deleted. Exported backups and your Apple subscription are not affected."),
                             primaryButton: .destructive(Text("Delete everything")) {
                                 try? model.coordinator.cancelAll()
                                 for player in model.trackedPlayers { try? model.removePlayer(player) }
                                 load(); model.touch()
                             },
                             secondaryButton: .cancel())
            }
        }
    }

    private func load() {
        usage = model.trackedPlayers.map { player in
            let games = (try? model.games.totalGameCount(playerID: player.id)) ?? 0
            let reviews = ((try? model.database.queryOne("""
                SELECT COUNT(*) AS value FROM analyses a
                JOIN player_games pg ON pg.game_key = a.game_key
                WHERE pg.player_id = ? AND a.status = 'complete';
                """, [player.id.sqlValue])) ?? nil)?.int("value") ?? 0
            return (player, games, reviews)
        }
    }
}

// MARK: - W26 How analysis works

struct HowAnalysisWorksScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("How analysis\nworks here.")
                    .font(.display(.largeTitle))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                section("One quality profile",
                        "Every game is analysed the same way, at \(AnalysisPolicy.standardNodes.formatted()) nodes per position. When a move looks like an error, both surrounding positions are re-searched at \(AnalysisPolicy.confirmationNodes.formatted()) nodes before it is labelled.")

                section("From evaluation to loss",
                        "Each evaluation becomes an index between 0 and 100 with W(cp) = 100 / (1 + e^(\u{2212}0.00368208 × cp)). A move's loss is how many of those points it gave away, never less than zero.")

                thresholds

                section("Accuracy",
                        "A move with no loss scores 100. Otherwise accuracy = clamp(103.1668 × e^(\u{2212}0.04354 × loss) \u{2212} 3.1669, 0, 100). A colour's game accuracy is the plain arithmetic mean of its move accuracies. This is this app's own aggregation and is not comparable to any other site's score.")

                section("Evidence, not guesses",
                        "A pattern is only attached when a line on the board demonstrates it. If a line does not resolve inside 12 plies, or compensation is unclear, the app says the evaluation dropped and shows the line — it does not invent a cause.")

                section("What the free plan covers",
                        "Any game you open can be analysed, free, as often as you like. Analysing all of a player's games in one go needs Premium. Every review you run is kept for good.")

                section("What it cannot tell you",
                        "Nothing here infers intent, nerves, disconnection or cheating. A recorded result is never substituted for an evaluation: a win on time is not checkmate. In an already-decided position accuracy can be very high, because there is little left to lose.")

                Panel {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Versions").eyebrowStyle()
                        Text("Policy \(AnalysisPolicy.identifier)")
                        Text("Engine \(AnalysisPolicy.activeProvenance.engineVersion)")
                        Text("Evaluation \(AnalysisPolicy.activeProvenance.evaluationVersion)")
                        Text("Scoring \(AnalysisPolicy.scoringIdentifier) · Tagger \(AnalysisPolicy.taggerIdentifier)")
                    }
                    .font(.caption)
                    .foregroundStyle(Palette.inkSecondary)
                }
            }
            .padding(Layout.gutter)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("How analysis works")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.display(.headline, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var thresholds: some View {
        Panel {
            VStack(spacing: 0) {
                thresholdRow("Under 5 points", "No label", Palette.inkTertiary)
                Hairline()
                thresholdRow("5 to 10", "Inaccuracy", Palette.inaccuracy)
                Hairline()
                thresholdRow("10 to 20", "Mistake", Palette.mistake)
                Hairline()
                thresholdRow("20 or more", "Blunder", Palette.blunder)
            }
        }
    }

    private func thresholdRow(_ range: String, _ label: String, _ tone: Color) -> some View {
        HStack {
            Text(range).font(.footnote).foregroundStyle(Palette.inkSecondary)
            Spacer()
            Badge(text: label, tone: tone, filled: label != "No label")
        }
        .padding(.vertical, 9)
    }
}

// MARK: - W25 About and licences

struct AboutScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\u{265E}")
                        .font(.system(size: 40))
                        .foregroundStyle(Palette.brand)
                    Text("Chess Analyser")
                        .font(.display(.title2))
                        .foregroundStyle(Palette.ink)
                    Text("Version \(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }

                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeading(title: "Licence")
                        Text("This application is free software, distributed under the GNU General Public License, version 3 or later. That covers the whole combined application — interface, analysis pipeline and tagging logic — because it links Stockfish directly.")
                            .font(.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("You are entitled to the complete corresponding source for this build, and you may modify and redistribute it under the same licence.")
                            .font(.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        NavigationLink { LicenceTextScreen() } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                Text("Read the full GPLv3 text")
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Palette.brand)
                            .frame(minHeight: Layout.minimumTarget, alignment: .leading)
                        }
                    }
                }

                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeading(title: "Stockfish")
                        Text("Position evaluation is done by Stockfish, also free software under GPLv3.")
                            .font(.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 0) {
                            attributionRow("Version", "Stockfish 18 (tag sf_18)")
                            Hairline()
                            attributionRow("Commit", "cb3d4ee9b47d")
                            Hairline()
                            attributionRow("Networks", "nn-c288c895ea92 · nn-37f18f62d772")
                            Hairline()
                            attributionRow("Modified", "No")
                        }
                        Text("Copyright © 2004–2026 The Stockfish developers. Its sources are vendored unmodified and included in this app's corresponding source.")
                            .font(.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("Stockfish project", destination: URL(string: "https://github.com/official-stockfish/Stockfish")!)
                            .font(.footnote.weight(.semibold))
                    }
                }

                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeading(title: "Board artwork")
                        Text("The pieces are the cburnett set, drawn for Wikipedia and used by Lichess. GPLv2 or later, which this app uses under version 3.")
                            .font(.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(spacing: 0) {
                            attributionRow("Set", "cburnett")
                            Hairline()
                            attributionRow("Artist", "Colin M.L. Burnett")
                            Hairline()
                            attributionRow("Licence", "GPLv2 or later")
                            Hairline()
                            attributionRow("Modified", "No")
                        }
                        Text("The twelve SVGs are included unmodified in this app's corresponding source. The board itself is drawn by the app.")
                            .font(.caption)
                            .foregroundStyle(Palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("Piece set source", destination: URL(string: "https://github.com/lichess-org/lila/tree/master/public/piece/cburnett")!)
                            .font(.footnote.weight(.semibold))
                    }
                }

                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeading(title: "Privacy")
                        Text("Games come directly from Chess.com's public API. No account is created and no password is ever requested. Purchases go through Apple. There is no third-party analytics or tracking in this app, and no data is uploaded anywhere. Exported backups contain player names and game data, so treat them as personal files.")
                            .font(.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Panel {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeading(title: "Not affiliated")
                        Text("This is an independent application. It is not affiliated with, endorsed by, or sponsored by Chess.com.")
                            .font(.footnote)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("The links below are development placeholders. A released build must point at the real corresponding source, privacy policy and terms.")
                    .font(.caption)
                    .foregroundStyle(Palette.brass)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    Link("Source code", destination: URL(string: "https://example.com/source")!)
                    Link("Privacy policy", destination: URL(string: "https://example.com/privacy")!)
                    Link("Terms", destination: URL(string: "https://example.com/terms")!)
                    Link("Chess.com Published-Data API", destination: URL(string: "https://www.chess.com/news/view/published-data-api")!)
                }
                .font(.footnote.weight(.medium))
            }
            .padding(Layout.gutter)
            .padding(.bottom, 24)
        }
        .screenBackground()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func attributionRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption).foregroundStyle(Palette.inkSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 7)
    }
}


// MARK: - Full licence text

/// GPLv3 §4 and §5 require recipients to receive a copy of the licence, so the text ships in the
/// bundle and is readable without a network connection.
struct LicenceTextScreen: View {
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "The licence file is missing from this build." : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Layout.gutter)
        }
        .screenBackground()
        .navigationTitle("GPLv3")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let url = Bundle.main.url(forResource: "GPLv3", withExtension: "txt"),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
            text = contents
        }
    }
}
