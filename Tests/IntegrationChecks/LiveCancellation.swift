import Foundation
import HarborCore

@main struct ProviderCheck {
    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let entry = try JSONDecoder().decode(ManifestEntry.self, from: Data(contentsOf: root.appendingPathComponent("live-cancellation-entry.json")))
        guard Safety.validateEntry(entry) == nil else { throw HarborError.invalid("Invalid source") }
        let folder = root.appendingPathComponent("Live cancellation check/Staging/" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let client = MegaClient(binaries: URL(fileURLWithPath: "/Applications/MEGAcmd.app/Contents/MacOS"), scratch: root.appendingPathComponent("Live cancellation check/Command scratch"))
        guard Safety.hasRoom(available: try SystemSpace().available(at: folder), size: entry.expectedBytes) else { throw HarborError.invalid("Insufficient reserve") }
        let before = try await client.metadata(entry.remoteHandle)
        guard before.isFile && before.size == entry.expectedBytes else { throw HarborError.invalid("Source changed") }
        let stop = StopSignal()
        let task = Task { try await client.download(handle: entry.remoteHandle, into: folder, expectedBytes: entry.expectedBytes, stop: stop) }
        let args = ["transfers", "--only-downloads", "--output-cols=TAG,DESTINYPATH", "--col-separator=|", "--path-display-size=16384", "--limit=100000"]
        var observed = false
        do {
        for _ in 0..<150 {
            let response = try await client.execute(args)
            if response.status == 0, !OwnedTransfers.owned(try OwnedTransfers.parse(response.output), by: folder).isEmpty { observed = true; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        } catch {
            stop.cancel()
            _ = try? await task.value
            throw error
        }
        stop.cancel()
        var cancelled = false
        var outcome = ""
        do { try await task.value; outcome = "Completed before cancellation could be tested" }
        catch { outcome = error.localizedDescription; cancelled = observed && outcome.contains("active downloads were cancelled") }
        let response = try await client.execute(args)
        let remaining = OwnedTransfers.owned(try OwnedTransfers.parse(response.output), by: folder).count
        let after = try await client.metadata(entry.remoteHandle)
        let originalUnchanged = after.handle == before.handle && after.size == before.size && after.isFile
        let report: [String: Any] = ["ownedTransferObserved":observed,"cancellationConfirmed":cancelled,"ownedActiveAfterStop":remaining,"sourceMetadataUnchanged":originalUnchanged,"sourceExpectedBytes":entry.expectedBytes,"outcome":outcome]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        try data.write(to: root.appendingPathComponent("live-cancellation-result.json"))
        print(String(decoding:data,as:UTF8.self))
        guard cancelled && remaining == 0 && originalUnchanged else { throw HarborError.invalid("Live cancellation check was inconclusive; retained evidence") }
    }
}
