import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import TagMP3Model
import TagMP3Transformations
import TagMP3Providers

@MainActor
private final class AudioPreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentURL: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var volume: Float = 0.8 {
        didSet { player?.volume = volume }
    }
    @Published private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(url: URL) {
        if currentURL != url {
            load(url: url)
        }
        guard player != nil else { return }
        if isPlaying { pause() } else { play() }
    }

    func stopIfChanging(to url: URL?) {
        guard currentURL != url else { return }
        stop()
    }

    func seek(to value: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(duration, value))
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        currentURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        errorMessage = nil
    }

    private func load(url: URL) {
        stop()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.volume = volume
            newPlayer.prepareToPlay()
            player = newPlayer
            currentURL = url
            duration = newPlayer.duration
            errorMessage = nil
        } catch {
            errorMessage = "Could not play this file: \(error.localizedDescription)"
        }
    }

    private func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
        }
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = self.duration
            self.timer?.invalidate()
            self.timer = nil
        }
    }

    deinit { timer?.invalidate() }
}

private struct PreviewPlayerControl: View {
    @ObservedObject var player: AudioPreviewPlayer
    let snapshot: TrackSnapshot?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                guard let snapshot else { return }
                player.toggle(url: snapshot.url)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(snapshot == nil)
            .help(snapshot == nil ? "Select a track to preview" : (player.isPlaying ? "Pause preview" : "Play selected track"))
            .keyboardShortcut(.space, modifiers: [])

            Slider(value: Binding(
                get: { player.currentTime },
                set: { player.seek(to: $0) }
            ), in: 0...max(player.duration, 0.01))
            .frame(width: 120)
            .disabled(player.duration == 0)
            .accessibilityLabel("Preview position")

            Text(timeString(player.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 42, alignment: .trailing)

            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { Double(player.volume) },
                set: { player.volume = Float($0) }
            ), in: 0...1)
            .frame(width: 64)
            .accessibilityLabel("Preview volume")

            if let errorMessage = player.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(errorMessage)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Audio preview")
    }

    private func timeString(_ time: TimeInterval) -> String {
        guard time.isFinite else { return "0:00" }
        return "\(Int(time) / 60):\(String(format: "%02d", Int(time) % 60))"
    }
}

private struct TrackFilter {
    enum ParseError: Error { case message(String) }
    enum Operator { case contains, equals, notEquals, present, absent, greater, less, regex }
    struct Term {
        let key: FieldKey?
        let operation: Operator
        let value: String
        let negated: Bool
    }

    let groups: [[Term]]

    static func parse(_ input: String) -> Result<Self, ParseError> {
        let rawGroups = input.components(separatedBy: " OR ")
        var groups: [[Term]] = []
        for rawGroup in rawGroups {
            let tokens = rawGroup.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard !tokens.isEmpty else { return .failure(.message("Filter needs a value")) }
            var terms: [Term] = []
            for token in tokens {
                let negated = token.hasPrefix("NOT ")
                let expression = negated ? String(token.dropFirst(4)) : token
                guard let term = parseTerm(expression, negated: negated) else {
                    return .failure(.message("Invalid filter: \(token)"))
                }
                terms.append(term)
            }
            groups.append(terms)
        }
        return .success(Self(groups: groups))
    }

    func matches(_ snapshot: TrackSnapshot, value: (TrackSnapshot, FieldKey) -> String) -> Bool {
        groups.contains { group in
            group.allSatisfy { term in
                let candidate: String
                if let key = term.key {
                    candidate = value(snapshot, key)
                } else {
                    candidate = [snapshot.url.lastPathComponent, snapshot.url.deletingLastPathComponent().path]
                        .joined(separator: " ")
                }
                let result: Bool
                switch term.operation {
                case .contains: result = candidate.localizedCaseInsensitiveContains(term.value)
                case .equals: result = candidate.compare(term.value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                case .notEquals: result = candidate.compare(term.value, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame
                case .present: result = !candidate.isEmpty
                case .absent: result = candidate.isEmpty
                case .greater: result = (Double(candidate) ?? 0) > (Double(term.value) ?? 0)
                case .less: result = (Double(candidate) ?? 0) < (Double(term.value) ?? 0)
                case .regex:
                    result = candidate.range(of: term.value, options: .regularExpression) != nil
                }
                return term.negated ? !result : result
            }
        }
    }

    private static func parseTerm(_ expression: String, negated: Bool) -> Term? {
        let fields: [String: FieldKey] = [
            "title": .title, "artist": .artist, "album": .album,
            "albumartist": .albumArtist, "track": .trackNumber,
            "disc": .discNumber, "date": .date, "year": .date,
            "genre": .genre, "comment": .comment, "composer": .composer
        ]
        if let separator = expression.firstIndex(of: "?") {
            guard separator == expression.index(before: expression.endIndex),
                  let key = fields[String(expression[..<separator]).lowercased()] else { return nil }
            return Term(key: key, operation: .present, value: "", negated: negated)
        }
        if let separator = expression.firstIndex(of: "!") {
            guard separator == expression.index(before: expression.endIndex),
                  let key = fields[String(expression[..<separator]).lowercased()] else { return nil }
            return Term(key: key, operation: .absent, value: "", negated: negated)
        }
        for symbol in ["!=", ">", "<", "=", ":", "~"] {
            guard let range = expression.range(of: symbol) else { continue }
            let fieldName = String(expression[..<range.lowerBound]).lowercased()
            let value = String(expression[range.upperBound...])
            guard !value.isEmpty, let key = fields[fieldName] else { return nil }
            let operation: Operator = switch symbol {
            case "!=": .notEquals
            case ">": .greater
            case "<": .less
            case "=": .equals
            case "~": .regex
            default: .contains
            }
            return Term(key: key, operation: operation, value: value, negated: negated)
        }
        return Term(key: nil, operation: .contains, value: expression, negated: negated)
    }
}

struct ContentView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var selectedTrackIDs: Set<TrackID> = []
    @StateObject private var previewPlayer = AudioPreviewPlayer()
    @State private var showingRenameSheet = false
    @State private var showingTransformSheet = false
    @State private var showingParseNamesSheet = false
    @State private var showingLookupSheet = false

    var body: some View {
        NavigationSplitView {
            List {
                Button {
                    environment.openFolder()
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                }
                .buttonStyle(.plain)
                Button {
                    environment.openFiles()
                } label: {
                    Label("Open Files…", systemImage: "doc")
                }
                .buttonStyle(.plain)
                Button {
                    environment.openPlaylist()
                } label: {
                    Label("Open Playlist…", systemImage: "music.note.list")
                }
                .buttonStyle(.plain)
                Label("Current Workspace", systemImage: "music.note.list")
                if !environment.recentLocations.isEmpty {
                    Section("Recent Locations") {
                        ForEach(environment.recentLocations, id: \.self) { location in
                            Button {
                                environment.openRecent(location)
                            } label: {
                                Label(location.lastPathComponent, systemImage: "clock")
                            }
                            .buttonStyle(.plain)
                            .help(location.path)
                        }
                    }
                } else {
                    Label("Recent Locations", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Sources")
            .accessibilityLabel("Music sources")
        } detail: {
            HSplitView {
                TrackTablePlaceholder(selection: $selectedTrackIDs)
                InspectorPlaceholder(snapshots: selectedSnapshots)
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .principal) {
                PreviewPlayerControl(player: previewPlayer, snapshot: selectedSnapshots.count == 1 ? selectedSnapshots.first : nil)
            }
            ToolbarItem {
                Button("Number Tracks") {
                    environment.autoNumber(environment.snapshotsInDisplayOrder(selectedSnapshots))
                }
                .disabled(selectedSnapshots.isEmpty)
                .help("Stage sequential track numbers in table order")
            }
            ToolbarItem {
                Button("Rename Files…") { showingRenameSheet = true }
                    .disabled(selectedSnapshots.isEmpty)
            }
            ToolbarItem {
                Button("Parse Names…") { showingParseNamesSheet = true }
                    .disabled(selectedSnapshots.isEmpty)
            }
            ToolbarItem {
                Button("Transform…") { showingTransformSheet = true }
                .disabled(selectedSnapshots.isEmpty)
            }
            ToolbarItem {
                Button("Lookup…") { showingLookupSheet = true }
                    .disabled(selectedSnapshots.isEmpty)
            }
            ToolbarItem {
                Menu("Export…") {
                    Button("Export CSV…") { environment.exportMetadata(asJSON: false) }
                    Button("Export JSON…") { environment.exportMetadata(asJSON: true) }
                    Divider()
                    Button("Export M3U Playlist…") { environment.exportPlaylist(asUTF8: false) }
                    Button("Export M3U8 Playlist…") { environment.exportPlaylist(asUTF8: true) }
                }
                .disabled(environment.snapshots.isEmpty)
            }
        }
        .sheet(isPresented: $showingRenameSheet) {
            RenameSheet(snapshots: selectedSnapshots)
                .environmentObject(environment)
        }
        .sheet(isPresented: $showingParseNamesSheet) {
            ParseNamesSheet(snapshots: selectedSnapshots)
                .environmentObject(environment)
        }
        .sheet(isPresented: $showingTransformSheet) {
            TransformSheet(snapshots: selectedSnapshots)
                .environmentObject(environment)
        }
        .sheet(isPresented: $showingLookupSheet) {
            LookupSheet(snapshots: environment.snapshotsInDisplayOrder(selectedSnapshots))
                .environmentObject(environment)
        }
        .confirmationDialog(
            "Save staged changes before importing more files?",
            isPresented: $environment.showingImportChangesPrompt,
            titleVisibility: .visible
        ) {
            Button("Save Changes and Continue") {
                environment.saveChangesAndImport()
            }
            Button("Discard Changes and Continue", role: .destructive) {
                environment.discardChangesAndImport()
            }
            Button("Cancel", role: .cancel) {
                environment.cancelPendingImport()
            }
        } message: {
            Text("Your staged edits will remain unsaved unless you save them now.")
        }
        .onChange(of: selectedTrackIDs) { _ in
            let selectedURL = selectedSnapshots.count == 1 ? selectedSnapshots.first?.url : nil
            previewPlayer.stopIfChanging(to: selectedURL)
        }
    }

    private var selectedSnapshots: [TrackSnapshot] {
        environment.snapshots.filter { selectedTrackIDs.contains($0.id) }
    }
}

private struct LookupSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let snapshots: [TrackSnapshot]

    private let provider = MusicBrainzProvider(
        application: ProviderApplication(
            name: "tagmp3",
            version: "0.1",
            contactURL: URL(string: "https://github.com/tagmp3/tagmp3")!
        )
    )
    private let fields: [(String, FieldKey)] = [
        ("Title", .title), ("Artist", .artist), ("Album", .album),
        ("Album Artist", .albumArtist), ("Track", .trackNumber), ("Date", .date)
    ]
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var results: [ReleaseCandidate] = []
    @State private var details: ReleaseDetails?
    @State private var artwork: [ProviderArtwork] = []
    @State private var selectedArtworkID: String?
    @State private var includeArtwork = true
    @State private var selectedFields: Set<FieldKey> = [.title, .artist, .album, .albumArtist, .trackNumber, .date]
    @State private var status = "Enter search criteria."
    @State private var isBusy = false

    private var remoteTracks: [ProviderTrack] { details?.media.flatMap(\.tracks) ?? [] }
    private var selectedArtwork: ProviderArtwork? { artwork.first { $0.id == selectedArtworkID } }
    private var alignmentWarning: String? {
        let numbers = snapshots.compactMap { filenameTrackNumber(from: $0.url) }
        let duplicateNumbers = Set(numbers).count != numbers.count
        let unmatchedCount = snapshots.indices.filter { index in
            matchedRemoteTrack(for: snapshots[index], fallbackIndex: index) == nil
        }.count
        let mismatchCount = snapshots.indices.filter { index in
            guard let remote = matchedRemoteTrack(for: snapshots[index], fallbackIndex: index),
                  let filenameTitle = filenameTitle(from: snapshots[index].url) else { return false }
            return normalizedTrackTitle(filenameTitle) != normalizedTrackTitle(remote.title)
        }.count
        if duplicateNumbers {
            return "Some filename track numbers are duplicated, so the alignment may be ambiguous. Review the matches before staging."
        }
        if unmatchedCount > 0 {
            return "\(unmatchedCount) track(s) could not be matched confidently. Review the alignment before staging."
        }
        if mismatchCount > 0 {
            return "\(mismatchCount) track(s) have filename titles that do not match the proposed release tracks. Review the alignment before staging."
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            Text("Online Lookup").font(.title2.weight(.semibold))
            Text("Search MusicBrainz, review the match, and stage only the fields you select. Nothing is saved automatically.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Album", text: $album)
                TextField("Artist", text: $artist)
                TextField("Title", text: $title)
                Button("Search") { search() }
                    .disabled(isBusy || [title, artist, album].allSatisfy(\.isEmpty))
            }

            if !results.isEmpty {
                Text("Releases").font(.headline)
                List(results) { candidate in
                    Button { load(candidate) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.title)
                            Text(candidate.artists.map(\.name).joined(separator: ", ") + (candidate.date.map { " • \($0)" } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(candidate.id == details?.candidate.id ? Color.accentColor.opacity(0.15) : nil)
                }
                .frame(minHeight: 100, maxHeight: 180)
            }

            if let details {
                Divider()
                Text("Review \(details.candidate.title)").font(.headline)
                Text("Writing selected fields from the matched release. Local edits remain staged until Save.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Fields").font(.subheadline.weight(.semibold))
                        ForEach(fields, id: \.1) { label, key in
                            Toggle(label, isOn: Binding(
                                get: { selectedFields.contains(key) },
                                set: { enabled in
                                    if enabled { selectedFields.insert(key) } else { selectedFields.remove(key) }
                                }
                            ))
                        }
                        Toggle("Artwork", isOn: $includeArtwork)
                            .disabled(selectedArtwork == nil)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Track alignment").font(.subheadline.weight(.semibold))
                        ForEach(Array(zip(snapshots.indices, snapshots)), id: \.1.id) { index, snapshot in
                            let remote = matchedRemoteTrack(for: snapshot, fallbackIndex: index)
                            HStack {
                                Text(snapshot.url.lastPathComponent).font(.caption).lineLimit(1)
                                Image(systemName: "arrow.right")
                                Text(remote?.title ?? "No match").font(.caption).lineLimit(1)
                                if alignmentMismatch(for: snapshot, remote: remote) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange)
                                        .help("The filename title does not match the proposed release track.")
                                }
                            }
                        }
                    }
                }

                if !artwork.isEmpty {
                    Text("Artwork").font(.subheadline.weight(.semibold))
                    HStack {
                        ForEach(artwork) { image in
                            Button { selectedArtworkID = image.id } label: {
                                AsyncImage(url: image.thumbnailURL ?? image.url) { phase in
                                    if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) }
                                    else { Color.secondary.opacity(0.15) }
                                }
                                .frame(width: 72, height: 72)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(image.id == selectedArtworkID ? Color.accentColor : .clear, lineWidth: 3))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(includeArtwork ? "Selected artwork will be staged." : "Artwork will not be changed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(status).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Stage Lookup") { stage() }
                    .disabled(isBusy || details == nil || remoteTracks.isEmpty || (selectedFields.isEmpty && (!includeArtwork || selectedArtwork == nil)))
            }
            }
        }
        .padding()
        .frame(width: 760, height: 650)
        .onAppear {
            guard let first = snapshots.first else { return }
            title = first.fields[.title]?.values.first ?? ""
            artist = first.fields[.artist]?.values.first ?? ""
            album = first.fields[.album]?.values.first ?? ""
        }
    }

    private func search() {
        isBusy = true
        status = "Searching MusicBrainz…"
        Task {
            do {
                results = try await provider.searchReleases(ReleaseSearchQuery(title: title.isEmpty ? nil : title, artist: artist.isEmpty ? nil : artist, album: album.isEmpty ? nil : album))
                status = results.isEmpty ? "No releases found." : "Select a release to review it."
            } catch { status = "Lookup failed: \(error.localizedDescription)" }
            isBusy = false
        }
    }

    private func load(_ candidate: ReleaseCandidate) {
        isBusy = true
        status = "Loading release and artwork…"
        Task {
            do {
                async let release = provider.releaseDetails(for: candidate.id)
                async let covers = provider.artwork(for: candidate.id)
                details = try await release
                artwork = (try? await covers) ?? []
                selectedArtworkID = artwork.first(where: { $0.front })?.id ?? artwork.first?.id
                includeArtwork = selectedArtworkID != nil
                status = "Review the match before staging it."
            } catch { status = "Could not load release: \(error.localizedDescription)" }
            isBusy = false
        }
    }

    private func stage() {
        guard let details else { return }
        var values: [TrackID: [FieldKey: FieldValues]] = [:]
        for (index, snapshot) in snapshots.enumerated() {
            guard let remote = matchedRemoteTrack(for: snapshot, fallbackIndex: index) else { continue }
            var fieldsForTrack: [FieldKey: FieldValues] = [:]
            if selectedFields.contains(.title) { fieldsForTrack[.title] = FieldValues(remote.title) }
            if selectedFields.contains(.artist) { fieldsForTrack[.artist] = FieldValues(remote.artists.map(\.name).joined(separator: ", ")) }
            if selectedFields.contains(.album) { fieldsForTrack[.album] = FieldValues(details.candidate.title) }
            if selectedFields.contains(.albumArtist) { fieldsForTrack[.albumArtist] = FieldValues(details.candidate.artists.map(\.name).joined(separator: ", ")) }
            if selectedFields.contains(.trackNumber) { fieldsForTrack[.trackNumber] = FieldValues(String(remote.position)) }
            if selectedFields.contains(.date), let date = details.candidate.date { fieldsForTrack[.date] = FieldValues(date) }
            values[snapshot.id] = fieldsForTrack
        }
        Task {
            var data: Data?
            var mimeType: String?
            if includeArtwork, let selectedArtwork {
                do {
                    let downloaded = try await downloadArtwork(selectedArtwork)
                    data = downloaded.data
                    mimeType = downloaded.mimeType
                } catch { status = "Fields are ready, but artwork could not be downloaded: \(error.localizedDescription)" }
            }
            environment.stageProviderImport(values, artworkData: data, artworkMimeType: mimeType, for: snapshots)
            dismiss()
        }
    }

    private func matchedRemoteTrack(for snapshot: TrackSnapshot, fallbackIndex: Int) -> ProviderTrack? {
        if let filenameTitle = filenameTitle(from: snapshot.url),
           let match = remoteTracks.first(where: { normalizedTrackTitle($0.title) == normalizedTrackTitle(filenameTitle) }) {
            return match
        }

        let filenameTrackNumber = filenameTrackNumber(from: snapshot.url)
        if let filenameTrackNumber,
           let match = remoteTracks.first(where: { $0.position == filenameTrackNumber }) {
            return match
        }

        let localTitle = environment.draftValue(for: snapshot, key: .title)
        if !localTitle.isEmpty {
            let comparableTitle = normalizedLookupText(localTitle)
            if let match = remoteTracks.first(where: { normalizedLookupText($0.title) == comparableTitle }) {
                return match
            }
        }

        let localTrackNumber = trackNumber(from: environment.draftValue(for: snapshot, key: .trackNumber))
        if let localTrackNumber,
           let match = remoteTracks.first(where: { $0.position == localTrackNumber }) {
            return match
        }

        guard remoteTracks.indices.contains(fallbackIndex) else { return nil }
        return remoteTracks[fallbackIndex]
    }

    private func trackNumber(from value: String) -> Int? {
        let firstComponent = value.split(separator: "/", maxSplits: 1).first.map(String.init) ?? value
        let number = firstComponent.prefix(while: { $0.isNumber })
        return Int(number)
    }

    private func filenameTrackNumber(from url: URL) -> Int? {
        let stem = url.deletingPathExtension().lastPathComponent
        for component in stem.split(separator: "-") {
            let candidate = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty,
                  candidate.allSatisfy({ $0.isNumber || $0 == "/" }) else { continue }
            if let number = trackNumber(from: candidate) { return number }
        }
        return nil
    }

    private func filenameTitle(from url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        let components = stem.split(separator: "-").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let numberIndex = components.firstIndex(where: { component in
            !component.isEmpty && component.allSatisfy { $0.isNumber || $0 == "/" }
        }) else { return nil }
        let title = components.dropFirst(numberIndex + 1).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func alignmentMismatch(for snapshot: TrackSnapshot, remote: ProviderTrack?) -> Bool {
        guard let remote,
              let filenameTitle = filenameTitle(from: snapshot.url) else { return remote == nil }
        return normalizedTrackTitle(filenameTitle) != normalizedTrackTitle(remote.title)
    }

    private func normalizedTrackTitle(_ value: String) -> String {
        var base = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var didRemoveAnnotation = true
        while didRemoveAnnotation {
            didRemoveAnnotation = false
            for closing in [")", "]"] {
                guard base.hasSuffix(closing),
                      let opening = base.lastIndex(of: closing == ")" ? "(" : "[") else { continue }
                base = String(base[..<opening]).trimmingCharacters(in: .whitespacesAndNewlines)
                didRemoveAnnotation = true
            }
        }
        return normalizedLookupText(base)
    }

    private func normalizedLookupText(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func downloadArtwork(_ artwork: ProviderArtwork) async throws -> (data: Data, mimeType: String) {
        var lastError: Error = URLError(.cannotDecodeContentData)
        let urls = [artwork.url, artwork.thumbnailURL].compactMap { $0 }

        for url in urls {
            do {
                var request = URLRequest(url: url)
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                guard NSImage(data: data) != nil else {
                    throw URLError(.cannotDecodeContentData)
                }

                let detectedMIMEType = response.mimeType?.hasPrefix("image/") == true
                    ? response.mimeType!
                    : "image/jpeg"
                return (data, detectedMIMEType)
            } catch {
                lastError = error
            }
        }

        throw lastError
    }
}

private struct TransformSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let snapshots: [TrackSnapshot]
    private let fields: [(String, FieldKey)] = [
        ("Title", .title), ("Artist", .artist), ("Album", .album),
        ("Album Artist", .albumArtist), ("Track", .trackNumber),
        ("Disc", .discNumber), ("Date", .date), ("Genre", .genre),
        ("Comment", .comment), ("Composer", .composer)
    ]
    @State private var operation = "copy"
    @State private var sourceKey: FieldKey = .title
    @State private var targetKey: FieldKey = .title
    @State private var find = ""
    @State private var replacement = ""

    private var previewRows: [(String, String, String)] {
        snapshots.map { snapshot in
            let oldValue = environment.draftValue(for: snapshot, key: targetKey)
            let newValue = environment.transformedValue(operation, sourceKey: sourceKey, targetKey: targetKey, find: find, replacement: replacement, for: snapshot) ?? oldValue
            return (snapshot.url.lastPathComponent, oldValue.isEmpty ? "—" : oldValue, newValue.isEmpty ? "—" : newValue)
        }
    }

    private var sourceName: String { fields.first { $0.1 == sourceKey }?.0 ?? sourceKey.rawValue }
    private var targetName: String { fields.first { $0.1 == targetKey }?.0 ?? targetKey.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transform Fields")
                .font(.title2.weight(.semibold))
            Text("Changes remain staged until you save the selected tracks.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Operation", selection: $operation) {
                Text("Copy field").tag("copy")
                Text("Replace text").tag("replace")
                Text("Trim whitespace").tag("trim")
                Text("Uppercase").tag("uppercase")
                Text("Lowercase").tag("lowercase")
                Text("Remove field").tag("remove")
            }
            Picker("Source field", selection: $sourceKey) {
                ForEach(fields, id: \.1) { Text($0.0).tag($0.1) }
            }
            .disabled(operation == "remove")
            Picker("Target field", selection: $targetKey) {
                ForEach(fields, id: \.1) { Text($0.0).tag($0.1) }
            }
            if operation == "replace" {
                TextField("Find", text: $find)
                    .textFieldStyle(.roundedBorder)
                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                if find.isEmpty {
                    Text("Enter text to find before previewing or staging a replacement.")
                        .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            Text("Preview")
                .font(.headline)
            Text("Writing \(targetName) from \(sourceName)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(previewRows, id: \.0) { filename, oldValue, newValue in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(filename)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(targetName): \(oldValue)  →  \(newValue)")
                                .font(.callout)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 80, maxHeight: 180)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Stage Transformation") {
                    environment.applyTransformation(operation, sourceKey: sourceKey, targetKey: targetKey, find: find, replacement: replacement, to: snapshots)
                    dismiss()
                }
                .disabled(operation == "replace" && find.isEmpty)
            }
        }
        .padding()
        .frame(width: 520, height: 520)
    }
}

private struct ParseNamesSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let snapshots: [TrackSnapshot]
    @State private var template = "{track:02} - {title}"
    @State private var selectedFields: Set<FieldKey> = [.title, .artist, .album, .albumArtist, .trackNumber, .discNumber]

    private let fields: [(String, FieldKey)] = [
        ("Title", .title), ("Artist", .artist), ("Album", .album),
        ("Album Artist", .albumArtist), ("Track", .trackNumber), ("Disc", .discNumber),
        ("Date", .date), ("Genre", .genre), ("Comment", .comment), ("Composer", .composer)
    ]

    private var templateError: PathTemplate.TemplateError? {
        do {
            _ = try PathTemplateMatcher(template)
            return nil
        } catch let error as PathTemplate.TemplateError {
            return error
        } catch {
            return .emptyTemplate
        }
    }

    private var parsed: [(snapshot: TrackSnapshot, fields: [FieldKey: FieldValues])] {
        guard let matcher = try? PathTemplateMatcher(template) else { return [] }
        return snapshots.compactMap { snapshot in
            guard let values = matcher.match(relativePath: relativePath(for: snapshot.url)) else { return nil }
            return (snapshot, values)
        }
    }

    private var rootURL: URL? {
        guard let first = snapshots.first else { return nil }
        let components = first.url.deletingLastPathComponent().standardizedFileURL.pathComponents
        let sharedCount = snapshots.dropFirst().reduce(components.count) { count, snapshot in
            let other = snapshot.url.deletingLastPathComponent().standardizedFileURL.pathComponents
            return min(count, zip(components, other).prefix { $0.0 == $0.1 }.count)
        }
        guard sharedCount > 0 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components.prefix(sharedCount))))
    }

    private func relativePath(for url: URL) -> String {
        if let sourcePath = environment.sourceRelativePath(for: url) {
            return sourcePath
        }
        guard let root = rootURL else { return url.lastPathComponent }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath.hasPrefix(rootPath + "/") ? String(filePath.dropFirst(rootPath.count + 1)) : url.lastPathComponent
    }

    private func displayValue(_ values: FieldValues?) -> String {
        values?.values.joined(separator: " • ") ?? "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Parse Names").font(.title2.weight(.semibold))
            Text("Infer metadata from each selected filename or folder path. Changes remain staged until saved.")
                .foregroundStyle(.secondary)
            TextField("Path template", text: $template)
                .textFieldStyle(.roundedBorder)
            Text("Example: {album}/{track:02} - {title} [ - {artist}]")
                .font(.caption).foregroundStyle(.secondary)

            Text("Fields to stage").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading) {
                ForEach(fields, id: \.1) { label, key in
                    Toggle(label, isOn: Binding(
                        get: { selectedFields.contains(key) },
                        set: { enabled in
                            if enabled { selectedFields.insert(key) } else { selectedFields.remove(key) }
                        }
                    ))
                }
            }

            Text("Preview").font(.headline)
            if let templateError {
                Text(templateError.localizedDescription).foregroundStyle(.red)
            } else if parsed.isEmpty {
                Text("No selected paths match this template.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(parsed, id: \.snapshot.id) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(relativePath(for: item.snapshot.url)).font(.caption).foregroundStyle(.secondary)
                                ForEach(fields.filter { selectedFields.contains($0.1) && item.fields[$0.1] != nil }, id: \.1) { label, key in
                                    Text("\(label): \(displayValue(item.snapshot.fields[key])) → \(displayValue(item.fields[key]))")
                                }
                            }
                            Divider()
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Stage Parsed Changes") {
                    let values = Dictionary(uniqueKeysWithValues: parsed.map { item in
                        (item.snapshot.id, item.fields.filter { selectedFields.contains($0.key) })
                    }.filter { !$0.1.isEmpty })
                    environment.stageParsedFields(values)
                    dismiss()
                }
                .disabled(templateError != nil || parsed.isEmpty || selectedFields.isEmpty)
            }
        }
        .padding()
        .frame(width: 680, height: 620)
    }
}

private struct RenameSheet: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    let snapshots: [TrackSnapshot]
    @State private var template = "{track:02} - {title}"
    @State private var organizeIntoFolders = false

    private var plan: PathOperationPlan? {
        try? PathOperationPlanner().plan(snapshots: snapshots, template: template, organizeIntoFolders: organizeIntoFolders)
    }
    private var pairs: [(snapshot: TrackSnapshot, name: String, similarity: Double, isLowConfidence: Bool)] {
        guard let plan else { return snapshots.map { ($0, "", 0, false) } }
        return zip(snapshots, plan.entries).map {
            ($0.0, $0.1.destination.path, $0.1.similarity, $0.1.isLowConfidence)
        }
    }
    private var templateError: PathTemplate.TemplateError? {
        do {
            _ = try PathTemplate(template)
            return nil
        } catch let error as PathTemplate.TemplateError {
            return error
        } catch {
            return .emptyTemplate
        }
    }
    private var valid: Bool {
        templateError == nil && plan?.isValid == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Files").font(.title2.weight(.semibold))
            TextField("Filename template", text: $template)
                .textFieldStyle(.roundedBorder)
            Toggle("Organize into template folders", isOn: $organizeIntoFolders)
            Text("Placeholders: {title}, {artist}, {album}, {albumArtist}, {track:02}, {disc:02}. Use [optional text] and {{escaped braces}}.")
                .font(.caption).foregroundStyle(.secondary)
            List(pairs, id: \.snapshot.id) { item in
                VStack(alignment: .leading) {
                    Text(item.snapshot.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    Text(item.name)
                    HStack(spacing: 5) {
                        Text("Filename overlap: \(Int((item.similarity * 100).rounded()))%")
                            .font(.caption2)
                            .foregroundStyle(item.isLowConfidence ? .orange : .secondary)
                        if item.isLowConfidence {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Low filename overlap warning")
                        }
                    }
                }
            }
            if let lowConfidence = plan?.entries.filter(\.isLowConfidence), !lowConfidence.isEmpty {
                Label("\(lowConfidence.count) rename(s) have low filename overlap. Review the preview carefully.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            if let templateError {
                Text(templateError.localizedDescription).foregroundStyle(.red).font(.caption)
            } else if let conflicts = plan?.conflicts, !conflicts.isEmpty {
                ForEach(conflicts, id: \.self) { conflict in
                    Text(conflict).foregroundStyle(.red).font(.caption)
                }
            } else if !valid {
                Text("No valid destinations were generated.").foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply Renames") {
                    let renamePairs = plan?.entries.map { (source: $0.source, destination: $0.destination) } ?? []
                    environment.applyRenames(renamePairs)
                    dismiss()
                }.disabled(!valid)
            }
        }
        .padding()
        .frame(width: 640, height: 460)
    }
}

private struct TrackTablePlaceholder: View {
    private enum SortMode: String, CaseIterable, Identifiable {
        case workspace = "Workspace order"
        case title = "Title"
        case artist = "Artist"
        case album = "Album"
        case track = "Track"
        case filename = "Filename"
        var id: Self { self }
    }

    @EnvironmentObject private var environment: AppEnvironment
    @Binding var selection: Set<TrackID>
    @State private var isDropTargeted = false
    @State private var filterText = ""
    @State private var sortMode: SortMode = .workspace
    @State private var sortAscending = true
    @State private var isReordering = false
    @AppStorage("tagmp3.savedFilters") private var savedFiltersData = "[]"

    private var savedFilters: [String] {
        guard let data = savedFiltersData.data(using: .utf8),
              let filters = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return filters
    }

    private var visibleSnapshots: [TrackSnapshot] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceSnapshots = environment.snapshotsInDisplayOrder(environment.snapshots)
        let filter = query.isEmpty ? nil : try? TrackFilter.parse(query).get()
        let filtered = workspaceSnapshots.filter { snapshot in
            guard !query.isEmpty else { return true }
            return filter?.matches(snapshot) { track, key in
                environment.draftValue(for: track, key: key)
            } ?? false
        }
        let sorted: [TrackSnapshot]
        switch sortMode {
        case .workspace: sorted = filtered
        case .title: sorted = stableSorted(filtered, ascending: sortAscending) { title(for: $0).localizedStandardCompare(title(for: $1)) }
        case .artist: sorted = stableSorted(filtered, ascending: sortAscending) { field(.artist, $0).localizedStandardCompare(field(.artist, $1)) }
        case .album: sorted = stableSorted(filtered, ascending: sortAscending) { field(.album, $0).localizedStandardCompare(field(.album, $1)) }
        case .track: sorted = stableSorted(filtered, ascending: sortAscending) { trackNumberComparison($0, $1) }
        case .filename: sorted = stableSorted(filtered, ascending: sortAscending) { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) }
        }
        return sorted
    }

    private var filterError: String? {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        if case .failure(.message(let message)) = TrackFilter.parse(query) { return message }
        return nil
    }

    private func field(_ key: FieldKey, _ snapshot: TrackSnapshot) -> String {
        environment.draftValue(for: snapshot, key: key)
    }

    private func title(for snapshot: TrackSnapshot) -> String {
        field(.title, snapshot).isEmpty ? snapshot.url.lastPathComponent : field(.title, snapshot)
    }

    private func trackNumber(for snapshot: TrackSnapshot) -> Int? {
        let value = field(.trackNumber, snapshot)
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? ""
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func trackNumberComparison(_ lhs: TrackSnapshot, _ rhs: TrackSnapshot) -> ComparisonResult {
        switch (trackNumber(for: lhs), trackNumber(for: rhs)) {
        case let (left?, right?):
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
            return .orderedSame
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        }
    }

    private func stableSorted(
        _ snapshots: [TrackSnapshot],
        ascending: Bool,
        by comparison: (TrackSnapshot, TrackSnapshot) -> ComparisonResult
    ) -> [TrackSnapshot] {
        snapshots.enumerated().sorted { lhs, rhs in
            let result = comparison(lhs.element, rhs.element)
            if result == .orderedSame { return lhs.offset < rhs.offset }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }.map(\.element)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tracks")
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(environment.importedURLs.isEmpty ? "No files opened" : "\(visibleSnapshots.count) of \(environment.importedURLs.count) file(s)")
                    .foregroundStyle(.secondary)
                Picker("Sort", selection: $sortMode) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .frame(width: 150)
                .accessibilityLabel("Sort tracks")
                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
                .help(sortAscending ? "Ascending" : "Descending")
                Button(isReordering ? "Done" : "Reorder") {
                    isReordering.toggle()
                }
                .disabled(sortMode != .workspace)
                .help("Drag tracks to change workspace order")
                Menu("Filters") {
                    Button("Save Current Filter") { saveCurrentFilter() }
                        .disabled(filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || filterError != nil)
                    if !savedFilters.isEmpty {
                        Divider()
                        ForEach(savedFilters, id: \.self) { filter in
                            Button(filter) { filterText = filter }
                        }
                        Divider()
                        Button("Clear Saved Filters", role: .destructive) {
                            savedFiltersData = "[]"
                        }
                    }
                }
                .help("Save and reuse filter expressions")
            }
            .padding()
            if let message = filterError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            Divider()
            if !environment.externallyChangedTrackIDs.isEmpty {
                HStack {
                    Label("Files changed outside tagmp3", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Reload Changed Files") {
                        environment.reloadExternallyChangedFiles()
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                Divider()
            }
            if environment.snapshots.isEmpty && environment.importedURLs.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("No Tracks")
                        .font(.headline)
                    Text("Open a folder or drop audio files here to begin.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("empty-track-workspace")
            } else {
                List(selection: $selection) {
                    ForEach(visibleSnapshots, id: \.id) { snapshot in
                        TrackRow(snapshot: snapshot)
                            .contextMenu {
                                Button("Copy Artwork to Other Selected Tracks") {
                                    copyArtwork(from: snapshot)
                                }
                                .disabled(effectiveArtwork(for: snapshot)?.encodedData == nil || copyTargets(for: snapshot).isEmpty)
                                Divider()
                                Button("Remove from Workspace", role: .destructive) {
                                    let ids = selection.isEmpty ? [snapshot.id] : selection
                                    environment.removeFromWorkspace(ids)
                                    selection.subtract(ids)
                                }
                            }
                    }
                    .onMove(perform: move)
                    ForEach(environment.scanErrors, id: \.self) { message in
                        HStack(alignment: .top) {
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Dismiss") {
                                environment.dismissScanError(message)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .onDeleteCommand {
                    environment.removeFromWorkspace(selection)
                    selection.removeAll()
                }
                .overlay(alignment: .bottomLeading) {
                    Text(environment.scanStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let url = object as? URL else { return }
                    Task { @MainActor in
                        environment.importURLs([url])
                    }
                }
            }
            return true
        }
        .searchable(text: $filterText, placement: .toolbar, prompt: "Filter tracks")
        .onChange(of: sortMode) { newMode in
            if newMode != .workspace { isReordering = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tagMP3SelectAllTracks)) { _ in
            selection = Set(visibleSnapshots.map(\.id))
        }
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard sortMode == .workspace else { return }
        let visibleIDs = visibleSnapshots.map(\.id)
        var reorderedVisibleIDs = visibleIDs
        reorderedVisibleIDs.move(fromOffsets: source, toOffset: destination)
        var replacementIndex = 0
        let visibleSet = Set(visibleIDs)
        let allIDs = environment.snapshotsInDisplayOrder(environment.snapshots).map(\.id)
        let reorderedAllIDs = allIDs.map { id in
            guard visibleSet.contains(id) else { return id }
            defer { replacementIndex += 1 }
            return reorderedVisibleIDs[replacementIndex]
        }
        environment.setDisplayOrder(reorderedAllIDs)
    }

    private func saveCurrentFilter() {
        let filter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filter.isEmpty, filterError == nil else { return }
        var filters = savedFilters
        if !filters.contains(filter) { filters.append(filter) }
        if let data = try? JSONEncoder().encode(filters), let encoded = String(data: data, encoding: .utf8) {
            savedFiltersData = encoded
        }
    }

    private func effectiveArtwork(for snapshot: TrackSnapshot) -> ArtworkDescriptor? {
        switch environment.pendingPatches[snapshot.id]?.artwork {
        case .replace(let values): values.first
        case .remove: nil
        default: snapshot.artwork.first
        }
    }

    private func copyTargets(for source: TrackSnapshot) -> [TrackSnapshot] {
        let targetIDs = selection.isEmpty
            ? Set(environment.snapshots.map(\.id))
            : selection
        return environment.snapshots.filter { targetIDs.contains($0.id) && $0.id != source.id }
    }

    private func copyArtwork(from source: TrackSnapshot) {
        guard let artwork = effectiveArtwork(for: source),
              let data = artwork.encodedData else { return }
        environment.stageArtwork(
            data: data,
            mimeType: artwork.mimeType,
            for: copyTargets(for: source)
        )
    }
}

private struct TrackRow: View {
    @EnvironmentObject private var environment: AppEnvironment
    let snapshot: TrackSnapshot

    private var isDirty: Bool { environment.pendingPatches[snapshot.id] != nil }
    private var title: String {
        let value = environment.draftValue(for: snapshot, key: .title)
        return value.isEmpty ? snapshot.url.deletingPathExtension().lastPathComponent : value
    }

    private var artwork: ArtworkDescriptor? {
        switch environment.pendingPatches[snapshot.id]?.artwork {
        case .replace(let values): values.first
        case .remove: nil
        default: snapshot.artwork.first
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if isDirty {
                Image(systemName: "pencil")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Unsaved changes")
            }
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
            if let artwork, let data = artwork.encodedData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .accessibilityLabel("Has artwork")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text([environment.draftValue(for: snapshot, key: .artist), environment.draftValue(for: snapshot, key: .album)]
                    .filter { !$0.isEmpty }
                    .joined(separator: " — "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(snapshot.url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snapshot.url.lastPathComponent)
    }
}

private struct InspectorPlaceholder: View {
    let snapshots: [TrackSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Inspector")
                .font(.title2.weight(.semibold))
            if snapshots.count == 1, let snapshot = snapshots.first {
                InspectorContent(snapshot: snapshot)
            } else if snapshots.count > 1 {
                BatchInspector(snapshots: snapshots)
            } else {
                Text("Select a track to inspect its metadata.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.25))
        .accessibilityIdentifier("inspector-placeholder")
    }
}

private struct BatchInspector: View {
    @EnvironmentObject private var environment: AppEnvironment
    let snapshots: [TrackSnapshot]
    @State private var showingArtworkImporter = false
    @State private var showingArtworkRemovalConfirmation = false
    @State private var showingArtworkResize = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Editing \(snapshots.count) tracks")
                    .font(.headline)
                Text("Each field has an explicit batch operation. Mixed values are never written as display text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                BatchFieldEditor(label: "Title", key: .title, snapshots: snapshots)
                BatchFieldEditor(label: "Artist", key: .artist, snapshots: snapshots)
                BatchFieldEditor(label: "Album", key: .album, snapshots: snapshots)
                BatchFieldEditor(label: "Album Artist", key: .albumArtist, snapshots: snapshots)
                BatchFieldEditor(label: "Track", key: .trackNumber, snapshots: snapshots)
                BatchFieldEditor(label: "Disc", key: .discNumber, snapshots: snapshots)
                BatchFieldEditor(label: "Date", key: .date, snapshots: snapshots)
                BatchFieldEditor(label: "Genre", key: .genre, snapshots: snapshots)
                BatchFieldEditor(label: "Comment", key: .comment, snapshots: snapshots)
                BatchFieldEditor(label: "Composer", key: .composer, snapshots: snapshots)
                Divider()
                Text("Artwork")
                    .font(.headline)
                Text("Artwork operations apply to all selected tracks and remain staged until saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Apply Cover to All…") { showingArtworkImporter = true }
                    Button("Paste to All") { pasteArtworkToAll() }
                    Button("Resize Artwork for Selected…") { showingArtworkResize = true }
                        .disabled(!hasResizableArtwork)
                    Button("Remove from All", role: .destructive) {
                        showingArtworkRemovalConfirmation = true
                    }
                }
                HStack {
                    Button("Save Selected Changes") { environment.save(snapshots) }
                        .disabled(!snapshots.contains { environment.pendingPatches[$0.id] != nil })
                    Button("Discard Changes", role: .destructive) { environment.discard(snapshots) }
                        .disabled(!snapshots.contains { environment.pendingPatches[$0.id] != nil })
                }
            }
        }
        .fileImporter(
            isPresented: $showingArtworkImporter,
            allowedContentTypes: [.jpeg, .png],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first,
                  let data = try? Data(contentsOf: url) else { return }
            let mimeType = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
            environment.stageArtwork(data: data, mimeType: mimeType, for: snapshots)
        }
        .confirmationDialog(
            "Remove artwork from all selected tracks?",
            isPresented: $showingArtworkRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Artwork", role: .destructive) {
                environment.removeArtwork(for: snapshots)
            }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showingArtworkResize) {
            ArtworkResizeSheet { mode in
                var resized: [TrackID: (Data, String)] = [:]
                for snapshot in snapshots {
                    guard let artwork = effectiveArtwork(for: snapshot),
                          let data = artwork.encodedData,
                          let output = resizeArtwork(data: data, mode: mode) else { continue }
                    resized[snapshot.id] = (output, "image/jpeg")
                }
                environment.stageArtworkBatch(resized)
                showingArtworkResize = false
            }
        }
        .accessibilityIdentifier("batch-track-inspector")
    }

    private var hasResizableArtwork: Bool {
        snapshots.contains { snapshot in
            effectiveArtwork(for: snapshot)?.encodedData != nil
        }
    }

    private func effectiveArtwork(for snapshot: TrackSnapshot) -> ArtworkDescriptor? {
        switch environment.pendingPatches[snapshot.id]?.artwork {
        case .replace(let values): values.first
        case .remove: nil
        default: snapshot.artwork.first
        }
    }

    private func pasteArtworkToAll() {
        guard let clipboardArtwork = clipboardArtworkData() else { return }
        environment.stageArtwork(data: clipboardArtwork.data, mimeType: clipboardArtwork.mimeType, for: snapshots)
    }
}

private struct BatchFieldEditor: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case keep = "Leave unchanged"
        case set = "Set for all"
        case remove = "Remove from all"
        var id: Self { self }
    }

    @EnvironmentObject private var environment: AppEnvironment
    let label: String
    let key: FieldKey
    let snapshots: [TrackSnapshot]
    @State private var mode: Mode = .keep
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold))
            Picker("Operation", selection: $mode) {
                ForEach(Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .labelsHidden()
            .onChange(of: mode) { newMode in apply(newMode) }
            if mode == .set {
                TextField("Value for all selected tracks", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: value) { _ in
                        environment.stageOperation(.set(FieldValues(value)), for: snapshots, key: key)
                    }
            }
        }
    }

    private func apply(_ newMode: Mode) {
        switch newMode {
        case .keep: environment.stageOperation(.keep, for: snapshots, key: key)
        case .set: environment.stageOperation(.set(FieldValues(value)), for: snapshots, key: key)
        case .remove: environment.stageOperation(.remove, for: snapshots, key: key)
        }
    }
}

private struct InspectorContent: View {
    @EnvironmentObject private var environment: AppEnvironment
    let snapshot: TrackSnapshot
    @State private var showingArtworkImporter = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(snapshot.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                if environment.pendingPatches[snapshot.id] != nil {
                    Label("Unsaved changes", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Group {
                    InspectorEditor(label: "Title", key: .title, snapshot: snapshot)
                    InspectorEditor(label: "Artist", key: .artist, snapshot: snapshot)
                    InspectorEditor(label: "Album", key: .album, snapshot: snapshot)
                    InspectorEditor(label: "Album Artist", key: .albumArtist, snapshot: snapshot)
                    InspectorEditor(label: "Track", key: .trackNumber, snapshot: snapshot)
                    InspectorEditor(label: "Disc", key: .discNumber, snapshot: snapshot)
                    InspectorEditor(label: "Date", key: .date, snapshot: snapshot)
                    InspectorEditor(label: "Genre", key: .genre, snapshot: snapshot)
                    InspectorEditor(label: "Comment", key: .comment, snapshot: snapshot)
                    InspectorEditor(label: "Composer", key: .composer, snapshot: snapshot)
                }
                HStack {
                    Button("Save Changes") { environment.save(snapshot) }
                        .disabled(environment.pendingPatches[snapshot.id] == nil)
                    Button("Discard", role: .destructive) { environment.discard(snapshot) }
                        .disabled(environment.pendingPatches[snapshot.id] == nil)
                }
                ArtworkEditor(snapshot: snapshot, showingImporter: $showingArtworkImporter)
                Divider()
                if !snapshot.fields.isEmpty {
                    Text("Additional Fields")
                        .font(.headline)
                    let standardKeys: Set<FieldKey> = [
                        .title, .artist, .album, .albumArtist, .trackNumber,
                        .discNumber, .date, .genre, .comment, .composer
                    ]
                    ForEach(snapshot.fields.keys.filter { !standardKeys.contains($0) }.sorted { $0.rawValue < $1.rawValue }, id: \.self) { key in
                        InspectorEditor(label: key.rawValue, key: key, snapshot: snapshot)
                    }
                    Divider()
                }
                if let audio = snapshot.audioProperties {
                    Text("Technical")
                        .font(.headline)
                    InspectorField(label: "Codec", value: audio.codec ?? "—")
                    InspectorField(label: "Duration", value: formattedDuration(audio.durationMilliseconds))
                    InspectorField(label: "Bitrate", value: audio.bitrate.map { "\($0) kbps" } ?? "—")
                    InspectorField(label: "Sample Rate", value: audio.sampleRate.map(String.init) ?? "—")
                    InspectorField(label: "Channels", value: audio.channels.map(String.init) ?? "—")
                    InspectorField(label: "Bits per Sample", value: audio.bitsPerSample.map(String.init) ?? "—")
                }
                if !snapshot.artwork.isEmpty {
                    Text("Artwork: \(snapshot.artwork.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fileImporter(
            isPresented: $showingArtworkImporter,
            allowedContentTypes: [.jpeg, .png],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                let mimeType = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                environment.stageArtwork(data: data, mimeType: mimeType, for: snapshot)
            } catch {
                // The importer is intentionally non-modal; the existing scan/status
                // area remains the place for operation reporting in this slice.
            }
        }
        .accessibilityIdentifier("track-inspector")
    }

}

private func formattedDuration(_ milliseconds: Int) -> String {
    let totalSeconds = max(0, milliseconds / 1000)
    return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
}

private struct ArtworkEditor: View {
    @EnvironmentObject private var environment: AppEnvironment
    let snapshot: TrackSnapshot
    @Binding var showingImporter: Bool
    @State private var isDropTargeted = false
    @State private var showingArtworkPreview = false
    @State private var showingArtworkResize = false

    private var artworks: [ArtworkDescriptor] {
        switch environment.pendingPatches[snapshot.id]?.artwork {
        case .replace(let values): values
        case .remove: []
        default: snapshot.artwork
        }
    }

    private var artwork: ArtworkDescriptor? {
        artworks.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Artwork")
                .font(.headline)
            HStack(alignment: .top, spacing: 10) {
                if let artwork, let data = artwork.encodedData, let image = NSImage(data: data) {
                    Button { showingArtworkPreview = true } label: {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View front cover larger")
                    .onDrag { artworkProvider(data: data, mimeType: artwork.mimeType) }
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.secondary.opacity(0.15))
                        .frame(width: 84, height: 84)
                        .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                        .accessibilityLabel("No front cover")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button(artwork == nil ? "Add…" : "Replace…") { showingImporter = true }
                    Button("Paste") { pasteArtwork() }
                    if artwork != nil {
                        Button("Remove", role: .destructive) { environment.removeArtwork(for: snapshot) }
                    }
                    if let artwork, let data = artwork.encodedData {
                        Button("Export…") { exportArtwork(data: data, mimeType: artwork.mimeType) }
                        Button("Resize…") { showingArtworkResize = true }
                    }
                    if let artwork {
                        let dimensions = artwork.pixelWidth.flatMap { width in
                            artwork.pixelHeight.map { "\(width) × \($0), " }
                        } ?? ""
                        let role = artwork.pictureType == .frontCover ? "Front cover" : artwork.pictureType == .backCover ? "Back cover" : "Other"
                        Text("\(dimensions)\(artwork.mimeType), \(artwork.byteCount) bytes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(artwork.description.isEmpty ? role : "\(role) · \(artwork.description)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if artworks.count > 1 {
                Text("Embedded images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(artworks.enumerated()), id: \.offset) { index, item in
                            if let data = item.encodedData, let image = NSImage(data: data) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 48, height: 48)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(alignment: .bottomTrailing) {
                                        Text("\(index + 1)")
                                            .font(.caption2.weight(.semibold))
                                            .padding(2)
                                            .background(.black.opacity(0.65))
                                            .foregroundStyle(.white)
                                    }
                                    .accessibilityLabel("Embedded image \(index + 1)")
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showingArtworkPreview) {
            if let artwork, let data = artwork.encodedData, let image = NSImage(data: data) {
                ArtworkPreviewSheet(image: image, artwork: artwork)
            }
        }
        .sheet(isPresented: $showingArtworkResize) {
            if let artwork, let data = artwork.encodedData {
                ArtworkResizeSheet { mode in
                    guard let resized = resizeArtwork(data: data, mode: mode) else { return }
                    environment.stageArtwork(data: resized, mimeType: "image/jpeg", for: snapshot)
                    showingArtworkResize = false
                }
            }
        }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                guard let provider = providers.first else { return false }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                        guard let data else { return }
                        let mimeType = data.first == 0x89 ? "image/png" : "image/jpeg"
                        Task { @MainActor in
                            environment.stageArtwork(data: data, mimeType: mimeType, for: snapshot)
                        }
                    }
                    return true
                }
                provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let url = object as? URL,
                          let data = try? Data(contentsOf: url) else { return }
                    let mimeType = url.pathExtension.lowercased() == "png" ? "image/png" : "image/jpeg"
                    Task { @MainActor in
                        environment.stageArtwork(data: data, mimeType: mimeType, for: snapshot)
                    }
                }
                return true
            }
    }

    private func exportArtwork(data: Data, mimeType: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [mimeType == "image/png" ? .png : .jpeg]
        panel.nameFieldStringValue = mimeType == "image/png" ? "cover.png" : "cover.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            // Export is a user-initiated best-effort operation; no file is changed
            // when the write fails or the panel is cancelled.
        }
    }

    private func pasteArtwork() {
        guard let clipboardArtwork = clipboardArtworkData() else { return }
        environment.stageArtwork(data: clipboardArtwork.data, mimeType: clipboardArtwork.mimeType, for: snapshot)
    }

    private func artworkProvider(data: Data, mimeType: String) -> NSItemProvider {
        let fileExtension = mimeType == "image/png" ? "png" : "jpg"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tagmp3-cover-\(UUID().uuidString).\(fileExtension)")
        if (try? data.write(to: url, options: .atomic)) != nil,
           let provider = NSItemProvider(contentsOf: url) {
            return provider
        }
        return NSItemProvider()
    }
}

private func clipboardArtworkData() -> (data: Data, mimeType: String)? {
    let pasteboard = NSPasteboard.general
    let pngType = NSPasteboard.PasteboardType("public.png")
    let jpegType = NSPasteboard.PasteboardType("public.jpeg")
    let tiffType = NSPasteboard.PasteboardType("public.tiff")

    if let data = pasteboard.data(forType: pngType), NSImage(data: data) != nil {
        return (data, "image/png")
    }
    if let data = pasteboard.data(forType: jpegType), NSImage(data: data) != nil {
        return (data, "image/jpeg")
    }
    guard let tiffData = pasteboard.data(forType: tiffType),
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        return nil
    }
    return (pngData, "image/png")
}

private struct ArtworkPreviewSheet: View {
    let image: NSImage
    let artwork: ArtworkDescriptor
    @Environment(\.dismiss) private var dismiss

    private var metadataText: String {
        let width = artwork.pixelWidth.map(String.init) ?? "?"
        let height = artwork.pixelHeight.map(String.init) ?? "?"
        return "\(width) × \(height), \(artwork.mimeType), \(artwork.byteCount) bytes"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 720, maxHeight: 720)
                .accessibilityLabel("Artwork preview")
            Text(metadataText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Close") { dismiss() }
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 420)
    }
}

private enum ArtworkResizeMode {
    case jpeg
    case longestEdge
    case squareFit
}

private struct ArtworkResizeSheet: View {
    let apply: (ArtworkResizeMode) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resize Artwork").font(.title2.weight(.semibold))
            Text("The converted or resized image is staged as a new JPEG. The original remains available through Undo until you save.")
                .foregroundStyle(.secondary)
            Button("Convert to JPEG") {
                apply(.jpeg)
                dismiss()
            }
            Button("Resize Longest Edge to 600 px") {
                apply(.longestEdge)
                dismiss()
            }
            Button("Fit to 600 × 600") {
                apply(.squareFit)
                dismiss()
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

private func resizeArtwork(data: Data, mode: ArtworkResizeMode) -> Data? {
    guard let image = NSImage(data: data),
          let representation = image.representations.first(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 }) else {
        return nil
    }

    let sourceWidth = CGFloat(representation.pixelsWide)
    let sourceHeight = CGFloat(representation.pixelsHigh)
    let targetCanvas = 600
    let scale: CGFloat
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat
    switch mode {
    case .jpeg:
        scale = 1
        canvasWidth = sourceWidth
        canvasHeight = sourceHeight
    case .longestEdge:
        scale = CGFloat(targetCanvas) / max(sourceWidth, sourceHeight)
        canvasWidth = max(1, round(sourceWidth * scale))
        canvasHeight = max(1, round(sourceHeight * scale))
    case .squareFit:
        scale = min(CGFloat(targetCanvas) / sourceWidth, CGFloat(targetCanvas) / sourceHeight)
        canvasWidth = CGFloat(targetCanvas)
        canvasHeight = CGFloat(targetCanvas)
    }

    let pixelWidth = max(1, Int(canvasWidth.rounded()))
    let pixelHeight = max(1, Int(canvasHeight.rounded()))
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelWidth,
        pixelsHigh: pixelHeight,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight).fill()
    let drawWidth = round(sourceWidth * scale)
    let drawHeight = round(sourceHeight * scale)
    let drawRect = NSRect(
        x: (canvasWidth - drawWidth) / 2,
        y: (canvasHeight - drawHeight) / 2,
        width: drawWidth,
        height: drawHeight
    )
    image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return bitmap.representation(
        using: NSBitmapImageRep.FileType.jpeg,
        properties: [NSBitmapImageRep.PropertyKey.compressionFactor: NSNumber(value: 0.92)]
    )
}

private struct InspectorEditor: View {
    @EnvironmentObject private var environment: AppEnvironment
    let label: String
    let key: FieldKey
    let snapshot: TrackSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: Binding(
                get: { environment.draftValue(for: snapshot, key: key) },
                set: { environment.stageValue($0, for: snapshot, key: key) }
            ))
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(label)
        }
    }
}

private struct InspectorField: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label, value: value)
    }
}

#Preview {
    ContentView()
}
