import Foundation
import TagMP3Model

public struct DiscoveryOptions: Sendable, Equatable {
    public var recursive: Bool
    public var supportedExtensions: Set<String>
    public var followSymlinks: Bool

    public init(recursive: Bool = true, supportedExtensions: Set<String> = ["mp3"], followSymlinks: Bool = false) {
        self.recursive = recursive
        self.supportedExtensions = Set(supportedExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        self.followSymlinks = followSymlinks
    }
}

public enum DiscoveryEvent: Sendable, Equatable {
    case file(URL)
    case error(ScanError)
    case finished
}

public struct ScanError: Error, Equatable, Sendable {
    public let url: URL
    public let message: String

    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

public struct FileDiscovery: Sendable {
    public init() {}

    public func events(for root: URL, options: DiscoveryOptions = .init()) -> AsyncStream<DiscoveryEvent> {
        AsyncStream { continuation in
            let task = Task {
                defer {
                    continuation.yield(.finished)
                    continuation.finish()
                }

                let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .isReadableKey]
                let enumerator: FileManager.DirectoryEnumerator?
                enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])

                guard let enumerator else {
                    continuation.yield(.error(ScanError(url: root, message: "The folder could not be enumerated.")))
                    return
                }

                for case let url as URL in enumerator {
                    if Task.isCancelled { return }
                    do {
                        let values = try url.resourceValues(forKeys: Set(keys))
                        if values.isDirectory == true {
                            if !options.recursive { enumerator.skipDescendants() }
                            continue
                        }
                        if values.isPackage == true { continue }
                        if values.isSymbolicLink == true && !options.followSymlinks {
                            enumerator.skipDescendants()
                            continue
                        }
                        guard values.isReadable != false,
                              options.supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
                        continuation.yield(.file(url))
                    } catch {
                        continuation.yield(.error(ScanError(url: url, message: error.localizedDescription)))
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
