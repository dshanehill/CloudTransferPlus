import Foundation

public enum TransferStage: String, Codable, CaseIterable, Sendable {
    case queued, downloading, downloaded, copying, awaitingUpload, uploaded, released, needsReview, skipped, excluded
    public var label: String {
        switch self {
        case .queued: "Queued"
        case .downloading: "Downloading"
        case .downloaded: "Downloaded"
        case .copying: "Copying to iCloud"
        case .awaitingUpload: "Awaiting iCloud"
        case .uploaded: "Upload reported"
        case .released: "Release requested"
        case .needsReview: "Needs review"
        case .skipped: "Deferred"
        case .excluded: "Excluded"
        }
    }
    /// Stages in which the app still owns work for the file. A run cannot be archived while any file is in one of these.
    public var isActive: Bool { [.queued, .downloading, .downloaded, .copying, .awaitingUpload].contains(self) }
}

public struct ManifestEntry: Codable, Equatable, Sendable {
    public let remoteHandle: String
    public let relativePath: String
    public let expectedBytes: Int64
    public init(remoteHandle: String, relativePath: String, expectedBytes: Int64) {
        self.remoteHandle = remoteHandle; self.relativePath = relativePath; self.expectedBytes = expectedBytes
    }
}

public struct Transfer: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var entry: ManifestEntry
    public var stage: TransferStage = .queued
    public var sha256: String? = nil
    public var note: String = "Original remains in MEGA."
    public var updated: Date = Date()
    /// Automatic attempts so far; kept in history so a restart does not reset the count (0.8.6).
    public var attempts: Int? = nil
    public init(entry: ManifestEntry) { self.entry = entry }
}

public enum HarborError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

public enum Safety {
    public static let reserve: Int64 = 50_000_000_000
    /// Largest single file. With the 50 GB reserve, a 25 GB file needs 101 GB free before it starts.
    public static let maximumPilotFile: Int64 = 25_000_000_000
    public static let handlePattern = "^H:[A-Za-z0-9_-]{8}$"
    /// Preserve legitimate Unicode format marks; reject characters that break record framing or paths.
    public static func hasUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .surrogate, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }


    public static func validateEntry(_ e: ManifestEntry) -> String? {
        let parts = e.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !e.relativePath.isEmpty, !e.relativePath.hasPrefix("/"), !e.relativePath.contains("\\"),
              !hasUnsafeCharacters(e.relativePath),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") && $0.utf8.count <= 255 }),
              e.relativePath.utf8.count < 1000 else { return "Invalid path: \(e.relativePath)" }
        guard e.expectedBytes >= 0, e.expectedBytes <= maximumPilotFile else { return "File is larger than 25 GB or has an invalid size: \(e.relativePath)" }
        guard e.remoteHandle.range(of: handlePattern, options: .regularExpression) != nil else { return "Invalid MEGA handle for \(e.relativePath)" }
        return nil
    }

    public static func validate(_ entries: [ManifestEntry]) throws {
        guard !entries.isEmpty, entries.count <= 100_000 else { throw HarborError.invalid("Manifest must contain 1–100,000 files.") }
        var paths = Set<String>(), handles = Set<String>()
        for e in entries {
            if let problem = validateEntry(e) { throw HarborError.invalid(problem + ". Nothing was imported.") }
            let key = e.relativePath.precomposedStringWithCanonicalMapping.lowercased()
            guard paths.insert(key).inserted, handles.insert(e.remoteHandle).inserted else { throw HarborError.invalid("Duplicate path or MEGA handle (\(e.relativePath)). Nothing was imported.") }
        }
        // A file cannot also be another file's parent directory.
        for path in paths {
            var parts = path.split(separator: "/").map(String.init)
            while parts.count > 1 { parts.removeLast(); if paths.contains(parts.joined(separator: "/")) { throw HarborError.invalid("A file conflicts with a parent folder.") } }
        }
    }

    /// Reserve + the staged download + room for the iCloud copy (an APFS clone usually needs no extra space) + 1 GB slack.
    public static func requiredSpace(for size: Int64) -> Int64 { reserve + 2 * size + 1_000_000_000 }
    public static func hasRoom(available: Int64, size: Int64) -> Bool {
        size >= 0 && size <= maximumPilotFile && available >= requiredSpace(for: size)
    }

    /// Generous upper bound for one download: 30 minutes plus time at 250 KB/s.
    public static func downloadTimeout(for size: Int64) -> TimeInterval { 1_800 + Double(max(size, 0)) / 250_000 }

    public static func destination(root: URL, relativePath: String) throws -> URL {
        // Foundation may not resolve an intermediate symlink if the final file
        // does not exist yet. Inspect every existing component explicitly.
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw HarborError.invalid("Run folder is a symbolic link.") }
        var component = root
        for part in relativePath.split(separator: "/") {
            component.appendPathComponent(String(part))
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw HarborError.invalid("Symbolic links inside the run folder are not supported.")
            }
        }
        let result = root.appendingPathComponent(relativePath).standardizedFileURL
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard result.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot) else { throw HarborError.invalid("Destination escapes the selected folder.") }
        return result
    }
}

/// Builds a manifest from the output of: mega-find <folder> --type=f -l --show-handles
/// The parser is deliberately strict: if any line is not understood, the whole listing is rejected
/// rather than guessing, so an unexpected MEGAcmd output format can never produce a wrong manifest.
public enum MegaListing {
    public struct Result: Sendable {
        public var entries: [ManifestEntry] = []
        /// Files left out because they exceed the per-file limit or have names this app cannot write safely.
        public var excluded: [String] = []
    }

    public static func parse(_ output: String, root: String) throws -> Result {
        try MegaMetadata.inventory(output, root: root)
    }
}
