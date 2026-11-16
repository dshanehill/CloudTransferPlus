import Foundation
import Darwin

public final class StopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.withLock { stopped = true } }
    public var isCancelled: Bool { lock.withLock { stopped } }
}
public struct MegaNode: Sendable {
    public let handle: String
    public let name: String
    public let size: Int64?
    public let isFile: Bool
}
/// Exact-byte `ls -l --show-handles --time-format=%s` output, not rounded `find -l` output.
public enum MegaMetadata {
    public static func row(_ text: String) throws -> MegaNode {
        let pattern = #"^([-dribx][^\s]{3})\s+(?:\d+|>999|-)\s+(\d+|-)\s+-?\d+\s+(H:[A-Za-z0-9_-]{8}) (.+)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { throw HarborError.invalid("MEGA's exact-byte metadata was not recognized. No size was guessed.") }
        let flags = ns.substring(with: m.range(at: 1))
        let name = ns.substring(with: m.range(at: 4))
        return MegaNode(handle: ns.substring(with: m.range(at: 3)), name: name, size: Int64(ns.substring(with: m.range(at: 2))), isFile: flags.hasPrefix("-"))
    }
    public static func single(_ output: String, handle: String) throws -> MegaNode {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { !$0.hasPrefix("FLAGS ") }
        guard lines.count == 1 else { throw HarborError.invalid("Expected one unwrapped MEGA metadata row. The source was not accepted.") }
        let node = try row(lines[0])
        guard node.handle == handle else { throw HarborError.invalid("MEGA returned a different source handle.") }
        return node
    }
    public static func inventory(_ output: String, root: String) throws -> MegaListing.Result {
        let root = try sourceRoot(root)
        var knownFolders: Set<String> = [root]
        var folder: String?
        var result = MegaListing.Result()
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.isEmpty || line.hasPrefix("FLAGS ") { continue }
            let looksLikeRow = line.utf8.count > 4 && [45, 100, 114, 105, 98, 120].contains(Int(line.utf8.first!)) && line.utf8.dropFirst(4).first == 32
            let headingLine = line.trimmingCharacters(in: .whitespaces)
            if headingLine.hasSuffix(":"), !looksLikeRow {
                var heading = String(headingLine.dropLast())
                if !heading.hasPrefix("/") { heading = "/" + heading }
                if heading.count > 1 && heading.hasSuffix("/") { heading.removeLast() }
                guard knownFolders.contains(heading) else { throw HarborError.invalid("Unexpected or wrapped folder heading. Inventory stopped without guessing paths.") }
                folder = heading
                continue
            }
            guard let folder else { throw HarborError.invalid("Missing MEGA folder heading. Choose a folder, not a file.") }
            let node = try row(line)
            guard node.name != ".client-output", !node.name.contains("/"), node.name != ".", node.name != ".." else { throw HarborError.invalid("Ambiguous MEGA name. Inventory stopped without guessing paths.") }
            let fullPath = (folder == "/" ? "" : folder) + "/" + node.name
            guard fullPath == root || root == "/" || fullPath.hasPrefix(root + "/") else { throw HarborError.invalid("Listing escaped the selected MEGA folder.") }
            if !node.isFile { knownFolders.insert(fullPath); continue }
            guard let size = node.size else { throw HarborError.invalid("A source file has no exact byte size.") }
            // Retain the full cloud-drive namespace so separately selected folder batches cannot collide.
            let entry = ManifestEntry(remoteHandle: node.handle, relativePath: String(fullPath.dropFirst()), expectedBytes: size)
            if let issue = Safety.validateEntry(entry) { result.excluded.append(issue) } else { result.entries.append(entry) }
        }
        guard !result.entries.isEmpty else { throw HarborError.invalid("No supported files were found in the selected folder.") }
        try Safety.validate(result.entries)
        return result
    }
    public static func sourceRoot(_ value: String) throws -> String {
        var root = value
        if root.count > 1 && root.hasSuffix("/") { root.removeLast() }
        guard root.hasPrefix("/"), !root.contains("\\"), !Safety.hasUnsafeCharacters(root), root == "/" || root.dropFirst().split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") && !$0.contains("*") && !$0.contains("?") }) else { throw HarborError.invalid("Choose one absolute MEGA folder path without patterns or control characters.") }
        return root
    }
}
public struct MegaTransfer: Sendable {
    public let tag: Int
    public let destination: URL
}
public enum OwnedTransfers {
    public static func parse(_ output: String) throws -> [MegaTransfer] {
        var rows: [MegaTransfer] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line == "TAG|DESTINYPATH" { continue }
            guard let separator = line.firstIndex(of: "|"), let tag = Int(line[..<separator].trimmingCharacters(in: .whitespaces)), tag >= 0 else { throw HarborError.invalid("Cannot identify MEGA transfer ownership. No unrelated transfers will be cancelled.") }
            let path = String(line[line.index(after: separator)...])
            guard path.hasPrefix("/"), !Safety.hasUnsafeCharacters(path) else { throw HarborError.invalid("MEGA transfer destination is ambiguous. Cancellation was not confirmed.") }
            rows.append(.init(tag: tag, destination: URL(fileURLWithPath: path)))
        }
        return rows
    }
    public static func owned(_ rows: [MegaTransfer], by folder: URL) -> [MegaTransfer] {
        let prefix = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return rows.filter { $0.destination.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(prefix) }
    }
}
public enum MegaFailure: LocalizedError {
    case cancellationUnconfirmed(String)
    public var errorDescription: String? { if case .cancellationUnconfirmed(let message) = self { return message }; return nil }
}
public struct MegaResult: Sendable { public let status: Int32; public let output: String; public let diagnostics: String }

/// Every command is bounded. Downloads are cancelled in the service by destination ownership, never globally.
public final class MegaClient: @unchecked Sendable {
    public let binaries: URL
    private let scratch: URL
    private let disk: any SpaceAccess
    public init(binaries: URL, scratch: URL, disk: any SpaceAccess = SystemSpace()) { self.binaries = binaries; self.scratch = scratch; self.disk = disk }
    private func process(_ arguments: [String], output: FileHandle, error: FileHandle) -> Process {
        let p = Process(); p.executableURL = binaries.appendingPathComponent("mega-exec"); p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = binaries.path + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["COLUMNS"] = "16384"; env["LC_ALL"] = "C"
        p.environment = env; p.standardInput = FileHandle.nullDevice; p.standardOutput = output; p.standardError = error
        return p
    }
    private func terminate(_ p: Process) {
        if p.isRunning { p.terminate() }
        let until = Date().addingTimeInterval(1)
        while p.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) }
        // Do not block indefinitely on an unresponsive client.
    }
    private func capture(_ args: [String], timeout: TimeInterval, stop: StopSignal? = nil) throws -> MegaResult {
        let fm = FileManager.default
        let dir = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let outURL = dir.appendingPathComponent("stdout"), errURL = dir.appendingPathComponent("stderr")
        fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]); fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        if stop?.isCancelled == true { throw HarborError.invalid("Operation cancelled before starting.") }
        let p = process(args, output: out, error: err)
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if stop?.isCancelled == true || Date() > deadline { terminate(p); throw HarborError.invalid("MEGA command cancelled or timed out. No result was accepted.") }
            let count = (try? outURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let errors = (try? errURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if count > 128_000_000 || errors > 1_000_000 { terminate(p); throw HarborError.invalid("MEGA command output exceeded its safety limit.") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if stop?.isCancelled == true { throw HarborError.invalid("MEGA command was cancelled; its result was not accepted.") }
        guard ((try? outURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) <= 128_000_000,
              ((try? errURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max) <= 1_000_000 else { throw HarborError.invalid("MEGA output exceeded its safety limit.") }
        return .init(status: p.terminationStatus, output: try String(contentsOf: outURL, encoding: .utf8), diagnostics: try String(contentsOf: errURL, encoding: .utf8))
    }
    /// Last meaningful line of MEGAcmd's output, trimmed for display.
    public static func summary(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("FLAGS") }
        return String((lines.last ?? "").prefix(200))
    }
    public func execute(_ arguments: [String], timeout: TimeInterval = 30, stop: StopSignal? = nil) async throws -> MegaResult {
        try await Task.detached(priority: .utility) { try self.capture(arguments, timeout: timeout, stop: stop) }.value
    }
    public func metadata(_ handle: String, stop: StopSignal? = nil) async throws -> MegaNode {
        guard handle.range(of: Safety.handlePattern, options: .regularExpression) != nil else { throw HarborError.invalid("Invalid MEGA source handle.") }
        // MEGAcmd sometimes answers a busy moment with status 1; ask again a few seconds later before failing (0.8.5).
        var result = try await execute(["ls", "-l", "--show-handles", "--time-format=%s", handle], stop: stop)
        for wait in [3.0, 8.0] where result.status != 0 && stop?.isCancelled != true {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            result = try await execute(["ls", "-l", "--show-handles", "--time-format=%s", handle], stop: stop)
        }
        guard result.status == 0 else {
            // 0.8.6: keep MEGA's own words so the real cause is visible in the app and the log.
            let said = MegaClient.summary(result.diagnostics + " " + result.output)
            throw HarborError.invalid("MEGA could not read source metadata (\(result.status))\(said.isEmpty ? "" : ": \(said)"). Check sign-in and source availability.")
        }
        return try MegaMetadata.single(result.output, handle: handle)
    }
    private func activeSync() throws -> [MegaTransfer] {
        let result = try capture(["transfers", "--only-downloads", "--output-cols=TAG,DESTINYPATH", "--col-separator=|", "--path-display-size=16384", "--limit=100000"], timeout: 10)
        guard result.status == 0 else { throw HarborError.invalid("Could not read MEGA transfer ownership. Cancellation is unconfirmed.") }
        return try OwnedTransfers.parse(result.output)
    }
    private func cancelOwnedSync(_ folder: URL, requireObservedTransfer: Bool = false) throws {
        var emptyChecks = 0
        var observed = false
        for _ in 0..<12 {
            let owned = OwnedTransfers.owned(try activeSync(), by: folder)
            if owned.isEmpty { emptyChecks += 1; if emptyChecks >= 3 && (!requireObservedTransfer || observed) { return } }
            else {
                emptyChecks = 0; observed = true
                for transfer in owned {
                    // Only a tag proven to point within this app's private staging folder is permitted.
                    let result = try capture(["transfers", "-c", String(transfer.tag)], timeout: 10)
                    if result.status != 0 {
                        let stillOwned = OwnedTransfers.owned(try activeSync(), by: folder)
                        guard !stillOwned.contains(where: { $0.tag == transfer.tag }) else { throw HarborError.invalid("MEGA did not confirm cancellation of this app's transfer.") }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw HarborError.invalid("MEGA may still be writing into this app's staging folder. Queue paused; do not clear partial files.")
    }
    public func cancelOwned(in folder: URL) async throws {
        try await Task.detached(priority: .utility) { try self.cancelOwnedSync(folder) }.value
    }
    public func download(handle: String, into slot: URL, expectedBytes: Int64, stop: StopSignal, reserve: Int64 = Safety.reserve, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let node = try await metadata(handle, stop: stop)
        guard node.isFile, node.size == expectedBytes else { throw HarborError.invalid("Source is a folder or its exact size changed. No download was started.") }
        guard node.name != ".client-output", !node.name.contains("/"), !Safety.hasUnsafeCharacters(node.name) else { throw HarborError.invalid("Source filename is not supported.") }
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard !stop.isCancelled else { throw HarborError.invalid("Download cancelled before starting.") }
            let logURL = slot.appendingPathComponent(".client-output")
            fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let log = try FileHandle(forWritingTo: logURL); defer { try? log.close(); try? fm.removeItem(at: logURL) }
            _ = try self.activeSync() // Validate ownership-query support before a download can start.
            let p = self.process(["get", handle, slot.path], output: log, error: log)
            try p.run()
            let deadline = Date().addingTimeInterval(Safety.downloadTimeout(for: expectedBytes))
            var failure: String?
            var lastReport = Date.distantPast
            while p.isRunning {
                if stop.isCancelled { failure = "Download stopped by request." }
                else if Date() > deadline { failure = "Download exceeded its time limit." }
                else {
                    let available = try? self.disk.available(at: slot)
                    if available == nil || (available ?? 0) < reserve { failure = "Disk reserve reached or free space could not be read." }
                    let size = Self.bytes(in: slot, excluding: logURL)
                    if size > expectedBytes + 1_000_000 { failure = "Download exceeded the source's exact byte size." }
                    if let progress, Date().timeIntervalSince(lastReport) >= 0.5 { lastReport = Date(); progress(min(size, expectedBytes)) }
                    if ((try? logURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 1_000_000 { failure = "Download diagnostics exceeded their size limit." }
                }
                if failure != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            // Cancellation is checked after exit too: terminating the client is never proof that the service stopped.
            if stop.isCancelled { failure = "Download stopped by request." }
            if failure != nil || (p.isRunning == false && p.terminationStatus != 0) {
                self.terminate(p)
                do { try self.cancelOwnedSync(slot, requireObservedTransfer: true) }
                catch { throw MegaFailure.cancellationUnconfirmed("\(failure ?? "Download client failed.") Cancellation could not be confirmed: \(error.localizedDescription)") }
                let said = MegaClient.summary((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
                throw HarborError.invalid("\(failure ?? "Download client failed (\(p.terminationStatus))")\(said.isEmpty ? "" : " MEGA said: \(said)") This app's active downloads were cancelled; partial data retained.")
            }
        }.value
    }
    private static func bytes(in folder: URL, excluding excluded: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var size: Int64 = 0
        for case let url as URL in files where url != excluded {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true { size += Int64(values.fileSize ?? 0) }
        }
        return size
    }
}

public struct RemoteFolder: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let path: String
}
public enum MegaFolders {
    /// Nonrecursive exact metadata: only folders become selectable; file contents are never fetched.
    public static func parse(_ output: String, parent: String) throws -> [RemoteFolder] {
        let parent = try MegaMetadata.sourceRoot(parent)
        var result: [RemoteFolder] = []
        var handles = Set<String>()
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("FLAGS ") { continue }
            let heading = line.trimmingCharacters(in: .whitespaces)
            if heading == parent + ":" || heading == String(parent.dropFirst()) + ":" { continue }
            let node = try MegaMetadata.row(line)
            guard !node.name.contains("/"), node.name != ".", node.name != "..", !Safety.hasUnsafeCharacters(node.name) else { throw HarborError.invalid("MEGA returned an ambiguous folder listing. No source was selected.") }
            if node.isFile { continue }
            guard line.first == "d" else { continue }
            let path = (parent == "/" ? "" : parent) + "/" + node.name
            _ = try MegaMetadata.sourceRoot(path)
            guard handles.insert(node.handle).inserted else { throw HarborError.invalid("Duplicate folder identity in MEGA's response.") }
            result.append(RemoteFolder(id: node.handle, name: node.name, path: path))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
extension MegaClient {
    public func folders(in path: String, handle: String? = nil) async throws -> [RemoteFolder] {
        let path = try MegaMetadata.sourceRoot(path)
        if let handle, handle.range(of: Safety.handlePattern, options: .regularExpression) == nil { throw HarborError.invalid("Invalid MEGA folder identity.") }
        let result = try await execute(["ls", "-l", "--show-handles", "--time-format=%s", handle ?? path])
        guard result.status == 0 else { throw HarborError.invalid("MEGA could not open this folder. Check that the official MEGA client is signed in.") }
        return try MegaFolders.parse(result.output, parent: path)
    }
}
