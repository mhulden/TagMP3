import Foundation
import CryptoKit
import AppKit
import ImageIO
import UniformTypeIdentifiers
import TagMP3FileSystem
import TagMP3Metadata
import TagMP3Model
import TagMP3Transformations

@MainActor
final class AppEnvironment: ObservableObject {
    let productName = "tagmp3"
    @Published private(set) var importedURLs: [URL] = []
    /// The folders/files that introduced the current workspace. These preserve
    /// the source folder name for filename-to-tag parsing (for example,
    /// `{album}/{track:02} - {title}`).
    @Published private(set) var importRoots: [URL] = []
    @Published private(set) var snapshots: [TrackSnapshot] = []
    @Published private(set) var displayOrder: [TrackID] = []
    @Published private(set) var scanErrors: [String] = []
    @Published private(set) var failedFileURLs: Set<URL> = []
    @Published private(set) var scanStatus = "No files opened"
    @Published private(set) var pendingPatches: [TrackID: TagPatch] = [:]
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var externallyChangedTrackIDs: Set<TrackID> = []
    @Published var showingImportChangesPrompt = false
    @Published private(set) var recentLocations: [URL] = UserDefaults.standard.stringArray(forKey: "recentLocations")?.compactMap(URL.init(fileURLWithPath:)) ?? []
    private var undoStack: [[TrackID: TagPatch]] = []
    private var redoStack: [[TrackID: TagPatch]] = []
    private var lastEditedField: (TrackID, FieldKey)?
    private var pendingImportURLs: [URL]?
    private var pendingImportReplacesWorkspace = false

    private func recordPendingState() {
        undoStack.append(pendingPatches)
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undoStagedEdit() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(pendingPatches)
        pendingPatches = previous
        lastEditedField = nil
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redoStagedEdit() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(pendingPatches)
        pendingPatches = next
        lastEditedField = nil
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    func proposedFilename(for snapshot: TrackSnapshot, template: String) -> String {
        let result = (try? PathTemplate(template).render(snapshot: snapshot)) ?? snapshot.url.deletingPathExtension().lastPathComponent
        let fileExtension = snapshot.url.pathExtension
        return result.lowercased().hasSuffix(".\(fileExtension.lowercased())") ? result : "\(result).\(fileExtension)"
    }

    func applyRenames(_ pairs: [(source: URL, destination: URL)]) {
        let destinations = Set(pairs.map { $0.destination.standardizedFileURL })
        guard destinations.count == pairs.count,
              pairs.allSatisfy({ !$0.destination.standardizedFileURL.path.isEmpty }) else {
            scanErrors.append("Rename cancelled: destinations must be unique and valid.")
            return
        }
        let existing = Set(pairs.map { $0.source.standardizedFileURL })
        if pairs.contains(where: { FileManager.default.fileExists(atPath: $0.destination.path) && $0.source.standardizedFileURL != $0.destination.standardizedFileURL && !existing.contains($0.destination.standardizedFileURL) }) {
            scanErrors.append("Rename cancelled: one or more destination filenames already exist.")
            return
        }
        var temporary: [(source: URL, temporary: URL, destination: URL)] = []
        do {
            for pair in pairs where pair.source.standardizedFileURL != pair.destination.standardizedFileURL {
                let temp = pair.source.deletingLastPathComponent().appendingPathComponent(".tagmp3-rename-\(UUID().uuidString).\(pair.source.pathExtension)")
                try FileManager.default.moveItem(at: pair.source, to: temp)
                temporary.append((pair.source, temp, pair.destination))
            }
            for item in temporary {
                try FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: item.temporary, to: item.destination)
            }
            let renamed = Dictionary(uniqueKeysWithValues: pairs.map { ($0.source.standardizedFileURL, $0.destination.standardizedFileURL) })
            importedURLs = importedURLs.map { renamed[$0.standardizedFileURL] ?? $0 }
            snapshots = snapshots.map { snapshot in
                guard let destination = renamed[snapshot.url.standardizedFileURL] else { return snapshot }
                return TrackSnapshot(
                    id: snapshot.id,
                    url: destination,
                    fingerprint: snapshot.fingerprint,
                    fields: snapshot.fields,
                    artwork: snapshot.artwork,
                    audioProperties: snapshot.audioProperties,
                    warnings: snapshot.warnings
                )
            }
            scanStatus = "Renamed"
        } catch {
            for item in temporary where FileManager.default.fileExists(atPath: item.temporary.path) {
                try? FileManager.default.moveItem(at: item.temporary, to: item.source)
            }
            scanErrors.append("Rename failed: \(error.localizedDescription)")
            scanStatus = "Rename failed"
        }
    }

    func importURLs(_ urls: [URL]) {
        guard pendingPatches.isEmpty else {
            pendingImportURLs = urls
            pendingImportReplacesWorkspace = false
            showingImportChangesPrompt = true
            return
        }
        startImport(urls)
    }

    func replaceWorkspace(with urls: [URL]) {
        guard pendingPatches.isEmpty else {
            pendingImportURLs = urls
            pendingImportReplacesWorkspace = true
            showingImportChangesPrompt = true
            return
        }
        clearWorkspace()
        startImport(urls)
    }

    private func clearWorkspace() {
        importedURLs.removeAll()
        importRoots.removeAll()
        snapshots.removeAll()
        displayOrder.removeAll()
        scanErrors.removeAll()
        failedFileURLs.removeAll()
        pendingPatches.removeAll()
        externallyChangedTrackIDs.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        canUndo = false
        canRedo = false
        lastEditedField = nil
        scanStatus = "No files opened"
    }

    private func startImport(_ urls: [URL]) {
        let directories = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let files = urls.filter { !directories.contains($0) }
        importRoots.append(contentsOf: (directories + files.map { $0.deletingLastPathComponent() }).map { $0.standardizedFileURL }.filter { !importRoots.contains($0) })
        if !directories.isEmpty {
            recentLocations = (directories + recentLocations.filter { !directories.contains($0) }).prefix(10).map { $0 }
            UserDefaults.standard.set(recentLocations.map(\.path), forKey: "recentLocations")
        }
        Task { @MainActor in
            var files: [URL] = []
            for url in urls {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    for await event in FileDiscovery().events(
                        for: url,
                        options: DiscoveryOptions(supportedExtensions: Self.supportedAudioExtensions)
                    ) {
                        if case .file(let file) = event { files.append(file) }
                    }
                } else {
                    files.append(url)
                }
            }
            scan(files)
        }
    }

    func sourceRelativePath(for url: URL) -> String? {
        let fileURL = url.standardizedFileURL
        let matchingRoot = importRoots
            .map(\.standardizedFileURL)
            .filter { fileURL.path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }
        guard let matchingRoot else { return nil }
        let base = matchingRoot.deletingLastPathComponent()
        let basePath = base.path
        guard fileURL.path.hasPrefix(basePath + "/") else { return nil }
        return String(fileURL.path.dropFirst(basePath.count + 1))
    }

    func cancelPendingImport() {
        pendingImportURLs = nil
        pendingImportReplacesWorkspace = false
        showingImportChangesPrompt = false
    }

    func discardChangesAndImport() {
        guard let urls = pendingImportURLs else {
            cancelPendingImport()
            return
        }
        let replacesWorkspace = pendingImportReplacesWorkspace
        pendingPatches.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        canUndo = false
        canRedo = false
        lastEditedField = nil
        pendingImportURLs = nil
        pendingImportReplacesWorkspace = false
        showingImportChangesPrompt = false
        if replacesWorkspace { clearWorkspace() }
        startImport(urls)
    }

    func saveChangesAndImport() {
        guard let urls = pendingImportURLs else {
            cancelPendingImport()
            return
        }
        let replacesWorkspace = pendingImportReplacesWorkspace
        pendingImportURLs = nil
        pendingImportReplacesWorkspace = false
        showingImportChangesPrompt = false
        save(snapshots) { [weak self] succeeded in
            guard let self else { return }
            if succeeded {
                if replacesWorkspace { self.clearWorkspace() }
                self.startImport(urls)
            } else {
                self.pendingImportURLs = urls
                self.pendingImportReplacesWorkspace = replacesWorkspace
                self.showingImportChangesPrompt = true
            }
        }
    }

    func openRecent(_ url: URL) {
        replaceWorkspace(with: [url])
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing supported audio files"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        replaceWorkspace(with: [url])
    }

    func openFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.supportedAudioTypes
        panel.message = "Choose supported audio files"
        guard panel.runModal() == .OK else { return }
        replaceWorkspace(with: panel.urls)
    }

    func openPlaylist() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "m3u"),
            UTType(filenameExtension: "m3u8")
        ].compactMap { $0 }
        panel.message = "Choose an M3U playlist"
        guard panel.runModal() == .OK, let playlistURL = panel.url else { return }

        do {
            let data = try Data(contentsOf: playlistURL)
            let text = String(decoding: data, as: UTF8.self)
            let urls = text.split(whereSeparator: \.isNewline).compactMap { line -> URL? in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty, !value.hasPrefix("#") else { return nil }
                let decoded = value.removingPercentEncoding ?? value
                if decoded.hasPrefix("/") {
                    return URL(fileURLWithPath: decoded).standardizedFileURL
                }
                return URL(fileURLWithPath: decoded, relativeTo: playlistURL.deletingLastPathComponent()).standardizedFileURL
            }.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else {
                scanErrors.append("Playlist contains no readable audio files.")
                return
            }
            replaceWorkspace(with: urls)
        } catch {
            scanErrors.append("Playlist could not be opened: \(error.localizedDescription)")
        }
    }

    func dismissScanError(_ message: String) {
        if let failedURL = failedFileURLs.first(where: { message.hasPrefix("\($0.lastPathComponent):") }) {
            failedFileURLs.remove(failedURL)
            importedURLs.removeAll { $0.standardizedFileURL == failedURL }
        }
        scanErrors.removeAll { $0 == message }
        if scanErrors.isEmpty { scanStatus = "Scan complete" }
    }

    func removeFromWorkspace(_ ids: Set<TrackID>) {
        guard !ids.isEmpty else { return }
        let removedURLs = Set(snapshots.filter { ids.contains($0.id) }.map(\.url.standardizedFileURL))
        snapshots.removeAll { ids.contains($0.id) }
        displayOrder.removeAll { ids.contains($0) }
        pendingPatches = pendingPatches.filter { !ids.contains($0.key) }
        externallyChangedTrackIDs.subtract(ids)
        importedURLs.removeAll { removedURLs.contains($0.standardizedFileURL) }
        scanStatus = "Removed from workspace"
    }

    private func scan(_ urls: [URL]) {
        let supported = urls.filter { Self.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
        let existing = Set(importedURLs)
        let newURLs = supported.filter { !existing.contains($0) }
        importedURLs.append(contentsOf: newURLs)
        guard !newURLs.isEmpty else { return }
        scanStatus = "Scanning…"

        let reader = TagLibMetadataReader()
        Task { @MainActor in
            for url in newURLs {
                do {
                    let snapshot = try await Task.detached {
                        try await reader.readSnapshot(at: url)
                    }.value
                    snapshots.append(snapshot)
                    displayOrder.append(snapshot.id)
                } catch {
                    failedFileURLs.insert(url.standardizedFileURL)
                    scanErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            scanStatus = scanErrors.isEmpty ? "Scan complete" : "Scan complete with errors"
        }
    }

    private static let supportedAudioExtensions: Set<String> = [
        "mp3", "flac", "ogg", "oga", "opus", "m4a", "mp4", "alac",
        "wav", "aiff", "aif", "ape", "wv", "dsf"
    ]
    private static let supportedAudioTypes = supportedAudioExtensions.compactMap { UTType(filenameExtension: $0) }

    func draftValue(for snapshot: TrackSnapshot, key: FieldKey) -> String {
        if case .set(let values) = pendingPatches[snapshot.id]?.fields[key] {
            return values.values.joined(separator: ", ")
        }
        if case .remove = pendingPatches[snapshot.id]?.fields[key] { return "" }
        return snapshot.fields[key]?.values.joined(separator: ", ") ?? ""
    }

    func setDisplayOrder(_ ids: [TrackID]) {
        let knownIDs = Set(snapshots.map(\.id))
        displayOrder = ids.filter { knownIDs.contains($0) }
            + snapshots.map(\.id).filter { !ids.contains($0) }
    }

    func snapshotsInDisplayOrder(_ snapshots: [TrackSnapshot]) -> [TrackSnapshot] {
        let positions = Dictionary(uniqueKeysWithValues: displayOrder.enumerated().map { ($1, $0) })
        return snapshots.sorted { lhs, rhs in
            (positions[lhs.id] ?? Int.max) < (positions[rhs.id] ?? Int.max)
        }
    }

    func exportMetadata(asJSON: Bool) {
        let orderedSnapshots = snapshotsInDisplayOrder(snapshots)
        guard !orderedSnapshots.isEmpty else { return }
        let commonFieldOrder: [FieldKey] = [
            .title, .artist, .album, .albumArtist, .trackNumber, .discNumber,
            .date, .genre, .comment, .composer
        ]
        let allFieldKeys = Set(orderedSnapshots.flatMap { $0.fields.keys })
            .union(pendingPatches.values.flatMap { $0.fields.keys })
        let fieldKeys = commonFieldOrder.filter { allFieldKeys.contains($0) }
            + allFieldKeys.subtracting(commonFieldOrder).sorted { $0.rawValue < $1.rawValue }
        let columns = ["FILENAME", "PATH"] + fieldKeys.map(\.rawValue)
        let rows = orderedSnapshots.map { snapshot -> [String: String] in
            var row = [
                "FILENAME": snapshot.url.lastPathComponent,
                "PATH": snapshot.url.deletingLastPathComponent().path
            ]
            for key in fieldKeys {
                if let operation = pendingPatches[snapshot.id]?.fields[key] {
                    switch operation {
                    case .keep:
                        row[key.rawValue] = snapshot.fields[key]?.values.joined(separator: " • ") ?? ""
                    case .set(let values):
                        row[key.rawValue] = values.values.joined(separator: " • ")
                    case .remove:
                        row[key.rawValue] = ""
                    }
                } else {
                    row[key.rawValue] = snapshot.fields[key]?.values.joined(separator: " • ") ?? ""
                }
            }
            return row
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [asJSON ? .json : .commaSeparatedText]
        panel.nameFieldStringValue = asJSON ? "tagmp3-export.json" : "tagmp3-export.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            if asJSON {
                data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted])
            } else {
                let lines = [columns.map(csvEscaped).joined(separator: ",")] + rows.map { row in
                    columns.map { csvEscaped(row[$0] ?? "") }.joined(separator: ",")
                }
                data = lines.joined(separator: "\n").data(using: .utf8) ?? Data()
            }
            try data.write(to: url, options: .atomic)
            scanStatus = "Exported metadata"
        } catch {
            scanErrors.append("Metadata export failed: \(error.localizedDescription)")
        }
    }

    func exportPlaylist(asUTF8: Bool) {
        let orderedSnapshots = snapshotsInDisplayOrder(snapshots)
        guard !orderedSnapshots.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: asUTF8 ? "m3u8" : "m3u")].compactMap { $0 }
        panel.nameFieldStringValue = asUTF8 ? "tagmp3-playlist.m3u8" : "tagmp3-playlist.m3u"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let baseDirectory = url.deletingLastPathComponent()
        let lines = orderedSnapshots.map { snapshot -> String in
            let fileURL = snapshot.url.standardizedFileURL
            let basePath = baseDirectory.standardizedFileURL.path
            if fileURL.path == basePath || fileURL.path.hasPrefix(basePath + "/") {
                return String(fileURL.path.dropFirst(basePath.count + 1))
            }
            return fileURL.path
        }
        let header = asUTF8 ? "#EXTM3U\n" : "#EXTM3U\n"
        let data = (header + lines.joined(separator: "\n") + "\n").data(using: asUTF8 ? .utf8 : .utf8) ?? Data()
        do {
            try data.write(to: url, options: .atomic)
            scanStatus = "Exported playlist"
        } catch {
            scanErrors.append("Playlist export failed: \(error.localizedDescription)")
        }
    }

    private func csvEscaped(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    func stageValue(_ value: String, for snapshot: TrackSnapshot, key: FieldKey) {
        stageValue(value, for: snapshot, key: key, recordsUndo: true)
    }

    private func stageValue(_ value: String, for snapshot: TrackSnapshot, key: FieldKey, recordsUndo: Bool) {
        let field = (snapshot.id, key)
        if recordsUndo && (lastEditedField == nil || lastEditedField!.0 != field.0 || lastEditedField!.1 != field.1) {
            recordPendingState()
        }
        lastEditedField = field
        var patch = pendingPatches[snapshot.id] ?? .empty
        let originalValues = snapshot.fields[key]?.values ?? []
        // Keep the live edit exactly as entered. Trimming here makes a
        // trailing space disappear from the TextField binding immediately,
        // which makes it impossible to type the next word (for example,
        // "Song Name"). Whitespace cleanup, when desired, belongs in an
        // explicit transformation rather than the keystroke path.
        let operation: FieldOperation = value.isEmpty ? .remove : .set(FieldValues(value))

        // Returning a field to its scanned value is a no-op, so do not leave a
        // dirty patch behind just because the user briefly edited the field.
        if (value.isEmpty && originalValues.isEmpty) ||
            (!value.isEmpty && originalValues == [value]) {
            patch.fields.removeValue(forKey: key)
        } else {
            patch.fields[key] = operation
        }

        if patch == .empty {
            pendingPatches.removeValue(forKey: snapshot.id)
        } else {
            pendingPatches[snapshot.id] = patch
        }
    }

    func stageOperation(_ operation: FieldOperation, for snapshots: [TrackSnapshot], key: FieldKey) {
        recordPendingState()
        lastEditedField = nil
        for snapshot in snapshots {
            var patch = pendingPatches[snapshot.id] ?? .empty
            let normalizedOperation: FieldOperation? = {
                switch operation {
                case .keep:
                    return nil
                case .set(let values):
                    let trimmed = values.values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if trimmed.allSatisfy(\.isEmpty) {
                        return snapshot.fields[key]?.values.isEmpty ?? true ? nil : .remove
                    }
                    return snapshot.fields[key]?.values == trimmed ? nil : .set(FieldValues(trimmed))
                case .remove:
                    return snapshot.fields[key]?.values.isEmpty ?? true ? nil : .remove
                }
            }()

            if let normalizedOperation {
                patch.fields[key] = normalizedOperation
            } else {
                patch.fields.removeValue(forKey: key)
            }
            if patch == .empty {
                pendingPatches.removeValue(forKey: snapshot.id)
            } else {
                pendingPatches[snapshot.id] = patch
            }
        }
    }

    func stageParsedFields(_ parsed: [TrackID: [FieldKey: FieldValues]]) {
        guard !parsed.isEmpty else { return }
        recordPendingState()
        lastEditedField = nil
        for snapshot in snapshots where parsed[snapshot.id] != nil {
            for (key, values) in parsed[snapshot.id] ?? [:] {
                stageValue(values.values.first ?? "", for: snapshot, key: key, recordsUndo: false)
            }
        }
    }

    func applyTransformation(
        _ operation: String,
        sourceKey: FieldKey,
        targetKey: FieldKey,
        find: String,
        replacement: String,
        to snapshots: [TrackSnapshot]
    ) {
        recordPendingState()
        lastEditedField = nil
        for snapshot in snapshots {
            let result = transformedValue(operation, sourceKey: sourceKey, targetKey: targetKey, find: find, replacement: replacement, for: snapshot)
            if let result { stageValue(result, for: snapshot, key: targetKey, recordsUndo: false) }
        }
    }

    func transformedValue(
        _ operation: String,
        sourceKey: FieldKey,
        targetKey: FieldKey,
        find: String,
        replacement: String,
        for snapshot: TrackSnapshot
    ) -> String? {
        let source = draftValue(for: snapshot, key: sourceKey)
        switch operation {
        case "copy": return source
        case "replace":
            guard !find.isEmpty else { return nil }
            return source.replacingOccurrences(of: find, with: replacement)
        case "trim": return source.trimmingCharacters(in: .whitespacesAndNewlines)
        case "uppercase": return source.uppercased()
        case "lowercase": return source.lowercased()
        case "remove": return ""
        default: return nil
        }
    }

    func autoNumber(_ snapshots: [TrackSnapshot], start: Int = 1, padding: Int = 2) {
        let width = max(1, padding)
        for (offset, snapshot) in snapshots.enumerated() {
            let number = String(format: "%0*d", width, start + offset)
            stageValue(number, for: snapshot, key: .trackNumber)
        }
    }

    func stageArtwork(data: Data, mimeType: String, for snapshot: TrackSnapshot) {
        stageArtwork(data: data, mimeType: mimeType, for: [snapshot])
    }

    func stageArtwork(data: Data, mimeType: String, for snapshots: [TrackSnapshot]) {
        recordPendingState()
        lastEditedField = nil
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let descriptor = ArtworkDescriptor(
            digest: digest,
            mimeType: mimeType,
            byteCount: data.count,
            pixelWidth: artworkDimensions(for: data).width,
            pixelHeight: artworkDimensions(for: data).height,
            pictureType: .frontCover,
            encodedData: data
        )
        for snapshot in snapshots {
            var patch = pendingPatches[snapshot.id] ?? .empty
            patch.artwork = .replace([descriptor])
            pendingPatches[snapshot.id] = patch
        }
    }

    func stageArtworkBatch(_ artworkByTrack: [TrackID: (Data, String)]) {
        guard !artworkByTrack.isEmpty else { return }
        recordPendingState()
        lastEditedField = nil
        for (trackID, payload) in artworkByTrack {
            let (data, mimeType) = payload
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let dimensions = artworkDimensions(for: data)
            let descriptor = ArtworkDescriptor(
                digest: digest,
                mimeType: mimeType,
                byteCount: data.count,
                pixelWidth: dimensions.width,
                pixelHeight: dimensions.height,
                pictureType: .frontCover,
                encodedData: data
            )
            var patch = pendingPatches[trackID] ?? .empty
            patch.artwork = .replace([descriptor])
            pendingPatches[trackID] = patch
        }
    }

    func stageProviderImport(_ values: [TrackID: [FieldKey: FieldValues]], artworkData: Data? = nil, artworkMimeType: String? = nil, for snapshots: [TrackSnapshot]) {
        guard !values.isEmpty || artworkData != nil else { return }
        recordPendingState()
        lastEditedField = nil
        for snapshot in snapshots {
            for (key, fieldValues) in values[snapshot.id] ?? [:] {
                stageValue(fieldValues.values.first ?? "", for: snapshot, key: key, recordsUndo: false)
            }
        }
        guard let artworkData, let artworkMimeType else { return }
        let digest = SHA256.hash(data: artworkData).map { String(format: "%02x", $0) }.joined()
        let dimensions = artworkDimensions(for: artworkData)
        let descriptor = ArtworkDescriptor(
            digest: digest,
            mimeType: artworkMimeType,
            byteCount: artworkData.count,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            pictureType: .frontCover,
            encodedData: artworkData
        )
        for snapshot in snapshots {
            var patch = pendingPatches[snapshot.id] ?? .empty
            patch.artwork = .replace([descriptor])
            pendingPatches[snapshot.id] = patch
        }
    }

    func removeArtwork(for snapshots: [TrackSnapshot]) {
        recordPendingState()
        lastEditedField = nil
        for snapshot in snapshots {
            var patch = pendingPatches[snapshot.id] ?? .empty
            patch.artwork = .remove
            pendingPatches[snapshot.id] = patch
        }
    }

    private func artworkDimensions(for data: Data) -> (width: Int?, height: Int?) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (nil, nil)
        }
        return (
            properties[kCGImagePropertyPixelWidth] as? Int,
            properties[kCGImagePropertyPixelHeight] as? Int
        )
    }

    func removeArtwork(for snapshot: TrackSnapshot) {
        removeArtwork(for: [snapshot])
    }

    func save(_ snapshots: [TrackSnapshot], completion: ((Bool) -> Void)? = nil) {
        let dirtySnapshots = snapshots.filter { pendingPatches[$0.id] != nil }
        guard !dirtySnapshots.isEmpty else {
            completion?(true)
            return
        }
        scanStatus = "Saving…"
        Task { @MainActor in
            var failed = false
            for snapshot in dirtySnapshots {
                guard let patch = pendingPatches[snapshot.id], patch != .empty else { continue }
                let writer = TagLibMetadataWriter()
                let reader = TagLibMetadataReader(idProvider: { _ in snapshot.id })
                do {
                    _ = try await Task.detached { try await writer.write(patch, to: snapshot) }.value
                    let refreshed = try await Task.detached { try await reader.readSnapshot(at: snapshot.url) }.value
                    if let index = self.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                        self.snapshots[index] = refreshed
                    }
                    self.pendingPatches.removeValue(forKey: snapshot.id)
                } catch {
                    failed = true
                    if let metadataError = error as? MetadataError,
                       metadataError == .fingerprintMismatch {
                        self.externallyChangedTrackIDs.insert(snapshot.id)
                    }
                    self.scanErrors.append("\(snapshot.url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            self.undoStack.removeAll()
            self.redoStack.removeAll()
            self.canUndo = false
            self.canRedo = false
            self.lastEditedField = nil
            self.scanStatus = failed ? "Save completed with errors" : "Saved"
            completion?(!failed)
        }
    }

    func save(_ snapshot: TrackSnapshot) {
        save([snapshot])
    }

    func reloadExternallyChangedFiles() {
        let targets = snapshots.filter { externallyChangedTrackIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        scanStatus = "Reloading…"
        Task { @MainActor in
            var failed = false
            for snapshot in targets {
                do {
                    let reader = TagLibMetadataReader(idProvider: { _ in snapshot.id })
                    let refreshed = try await Task.detached {
                        try await reader.readSnapshot(at: snapshot.url)
                    }.value
                    if let index = self.snapshots.firstIndex(where: { $0.id == snapshot.id }) {
                        self.snapshots[index] = TrackSnapshot(
                            id: snapshot.id,
                            url: refreshed.url,
                            fingerprint: refreshed.fingerprint,
                            fields: refreshed.fields,
                            artwork: refreshed.artwork,
                            audioProperties: refreshed.audioProperties,
                            warnings: refreshed.warnings
                        )
                    }
                    self.pendingPatches.removeValue(forKey: snapshot.id)
                    self.externallyChangedTrackIDs.remove(snapshot.id)
                    self.scanErrors.removeAll { $0.hasPrefix("\(snapshot.url.lastPathComponent):") }
                } catch {
                    failed = true
                    self.scanErrors.append("\(snapshot.url.lastPathComponent): Reload failed: \(error.localizedDescription)")
                }
            }
            self.undoStack.removeAll()
            self.redoStack.removeAll()
            self.canUndo = false
            self.canRedo = false
            self.lastEditedField = nil
            self.scanStatus = failed ? "Reload completed with errors" : "Reloaded external changes"
        }
    }

    func discard(_ snapshots: [TrackSnapshot]) {
        recordPendingState()
        lastEditedField = nil
        for snapshot in snapshots {
            pendingPatches.removeValue(forKey: snapshot.id)
        }
        scanStatus = "Changes discarded"
    }

    func discard(_ snapshot: TrackSnapshot) {
        discard([snapshot])
    }
}
