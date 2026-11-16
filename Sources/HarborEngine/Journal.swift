import Foundation
import HarborCore

struct JournalDelta: Codable {
    let runID: UUID
    let sequence: Int64
    let transfer: Transfer?
    let event: String?
    let destinationPath: String?
    let runFolderName: String?
}
/// Append small durable transitions rather than rewriting a 90,000-file manifest on every update.
/// Sequence numbers make snapshot compaction safe if the app stops between replacing the snapshot and its journal.
struct RunJournal {
    let folder: URL
    var snapshot: URL { folder.appendingPathComponent("pilot.json") }
    var changes: URL { folder.appendingPathComponent("pilot-changes.jsonl") }
    private let fm = FileManager.default
    func load() throws -> SavedRun? {
        guard fm.fileExists(atPath: snapshot.path) else {
            if fm.fileExists(atPath: changes.path) { throw HarborError.invalid("Transfer journal exists without its snapshot. History was preserved for review.") }
            return nil
        }
        guard (try snapshot.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 200_000_000 else { throw HarborError.invalid("Transfer snapshot exceeds its recovery limit.") }
        var saved = try JSONDecoder().decode(SavedRun.self, from: Data(contentsOf: snapshot))
        guard (saved.sequence ?? 0) >= 0, (saved.sequence ?? 0) < Int64.max - 1_000_000 else { throw HarborError.invalid("Invalid saved history sequence.") }
        guard fm.fileExists(atPath: changes.path) else { return saved }
        let size = try changes.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 100_000_000 else { throw HarborError.invalid("Transfer journal exceeds its recovery limit. History was preserved.") }
        let data = try Data(contentsOf: changes)
        // A crash may tear only the last append. Never ignore a malformed complete record.
        let complete = data.lastIndex(of: 10).map { data.prefix(through: $0) } ?? Data.SubSequence()
        var index: [UUID: Int] = [:]
        for (offset, transfer) in saved.transfers.enumerated() {
            guard index.updateValue(offset, forKey: transfer.id) == nil else { throw HarborError.invalid("Duplicate file identities in saved history.") }
        }
        let snapshotSequence = saved.sequence ?? 0
        var sequence = snapshotSequence
        for line in complete.split(separator: 10) {
            let delta = try JSONDecoder().decode(JournalDelta.self, from: Data(line))
            guard delta.runID == saved.runID, delta.sequence > snapshotSequence else { continue }
            guard delta.sequence == sequence + 1 else { throw HarborError.invalid("A transfer-history sequence is missing. History was preserved for review.") }
            if let t = delta.transfer {
                guard let i = index[t.id] else { throw HarborError.invalid("Journal entry refers to an unknown file.") }
                saved.transfers[i] = t
            }
            if let event = delta.event { saved.events.insert(event, at: 0); if saved.events.count > 500 { saved.events.removeLast(saved.events.count - 500) } }
            saved.destinationPath = delta.destinationPath; saved.runFolderName = delta.runFolderName
            sequence = delta.sequence
        }
        saved.sequence = sequence
        return saved
    }
    func writeSnapshot(_ saved: SavedRun) throws {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(saved).write(to: snapshot, options: .atomic)
        try protectAndSync(snapshot)
        try Data().write(to: changes, options: .atomic)
        try protectAndSync(changes)
    }
    func append(_ delta: JournalDelta) throws {
        let handle = try FileHandle(forWritingTo: changes)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var data = try JSONEncoder().encode(delta); data.append(10)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
    private func protectAndSync(_ file: URL) throws {
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }; try handle.synchronize()
    }
}
