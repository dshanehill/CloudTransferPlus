import Foundation
import HarborCore
import HarborEngine

@MainActor final class FakeCloud: CloudAccess {
    var observation: CloudStatus = .uploaded
    var evicted: [URL] = []
    var rejectEviction = false
    var uploading = false
    func status(of url: URL) -> CloudStatus { observation }
    func isUploading(_ url: URL) -> Bool { uploading }
    func evict(_ url: URL) throws {
        if rejectEviction { throw HarborError.invalid("Simulated eviction failure") }
        evicted.append(url)
    }
}
actor GatedHasher: FileHashing {
    var started = false
    var continuation: CheckedContinuation<String, Never>?
    let checksum: String
    init(_ checksum: String) { self.checksum = checksum }
    func digest(_ url: URL) async throws -> String {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: checksum); continuation = nil }
}
struct FixtureSpace: SpaceAccess {
    func available(at url: URL) throws -> Int64 { 200_000_000_000 }
}
struct LowSpace: SpaceAccess {
    func available(at url: URL) throws -> Int64 { 5_000_000_000 }
}
@main struct EngineChecks {
    @MainActor static var count = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError("FAIL: \(message)") }
        count += 1
        FileHandle.standardError.write(Data("PASS \(count): \(message)\n".utf8))
    }
    static func waitFor(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<500 { if await predicate() { return }; try await Task.sleep(nanoseconds: 20_000_000) }
        throw HarborError.invalid("Timed out waiting for a test condition.")
    }
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--inventory-file" {
            let text = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
            let result = try MegaMetadata.inventory(text, root: "/")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let manifestBytes = try encoder.encode(result.entries).count
            print("Exact inventory bytes: \(result.entries.reduce(Int64(0)) { $0 + $1.expectedBytes }); generated manifest bytes: \(manifestBytes)")
            print("Read-only real inventory parsed: \(result.entries.count) supported files; \(result.excluded.count) excluded. Private names withheld.")
            return
        }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("CloudTransferChecks-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        func fixture(_ mode: String) throws -> (URL, MegaClient) {
            let bin = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try fm.copyItem(at: Bundle.module.url(forResource: "FakeMega", withExtension: "py")!, to: bin.appendingPathComponent("mega-exec"))
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: bin.appendingPathComponent("mega-exec").path)
            try mode.write(to: bin.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
            return (bin, MegaClient(binaries: bin, scratch: bin.appendingPathComponent("scratch"), disk: FixtureSpace()))
        }
        func calls(_ bin: URL) -> [[String]] {
            guard let text = try? String(contentsOf: bin.appendingPathComponent("calls.jsonl"), encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        }
        func slot(_ bin: URL) throws -> URL {
            let url = bin.appendingPathComponent("staging/slot", isDirectory: true)
            try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
        }
        func uploaded() -> Transfer {
            var t = Transfer(entry: .init(remoteHandle: "H:ABCDEFGH", relativePath: "Photos/sample.bin", expectedBytes: 32)); t.stage = .uploaded; return t
        }
        func store(_ cloud: FakeCloud, hasher: any FileHashing = SHA256Hasher(), disk: any SpaceAccess = FixtureSpace()) -> TransferStore {
            let support = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let prefs = UserDefaults(suiteName: "CloudTransferChecks-\(UUID().uuidString)")!
            let store = TransferStore(supportURL: support, preferences: prefs, cloud: cloud, hasher: hasher, disk: disk, uploadErrorGrace: 0, startInDemo: true, autoDetectMEGA: false, startMonitor: false)
            store.demo = false; store.transfers = []; store.events = []; store.destination = support.appendingPathComponent("fake-cloud"); return store
        }
        func putFile(_ store: TransferStore, _ t: Transfer) async throws -> Transfer {
            let file = try Safety.destination(root: store.runRoot!, relativePath: t.entry.relativePath)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 120, count: 32).write(to: file)
            var updated = t; updated.sha256 = try await TransferStore.digest(file); return updated
        }
        // Pass 1: source metadata, ownership, cancellation and storage guards.
        do {
            let (bin, client) = try fixture("success"); let folder = try slot(bin)
            try await client.download(handle: "H:ABCDEFGH", into: folder, expectedBytes: 32, stop: StopSignal())
            check(fm.fileExists(atPath: folder.appendingPathComponent("sample.bin").path), "verified-source download produces exactly one fixture file")
            check(calls(bin).contains(where: { $0.first == "ls" && $0.contains("--time-format=%s") }), "exact metadata precedes download")
        }
        for mode in ["folder", "changed"] {
            let (bin, client) = try fixture(mode); let folder = try slot(bin)
            do { try await client.download(handle: "H:ABCDEFGH", into: folder, expectedBytes: 32, stop: StopSignal()); fatalError("Invalid source accepted") } catch {}
            check(!calls(bin).contains(where: { $0.first == "get" }), "folder/changed metadata blocked before download")
        }
        for mode in ["hang", "exit-before-loop", "low-space", "cancel-fails"] {
            FileHandle.standardError.write(Data("Testing cancellation mode \(mode)\n".utf8))
            let (bin, client) = try fixture(mode); let folder = try slot(bin); let stop = StopSignal()
            let task = Task { try await client.download(handle: "H:ABCDEFGH", into: folder, expectedBytes: 32, stop: stop, reserve: mode == "low-space" ? Int64.max : Safety.reserve) }
            if mode != "low-space" { try await waitFor { fm.fileExists(atPath: bin.appendingPathComponent("get-started").path) } }
            if ["hang", "cancel-fails"].contains(mode) { stop.cancel() }
            var unconfirmed = false
            do { try await task.value; fatalError("Stopped fixture unexpectedly succeeded") } catch { unconfirmed = error is MegaFailure }
            let cancellations = calls(bin).filter { $0.contains("-c") }
            let polled = calls(bin).filter { $0.first == "transfers" && !$0.contains("-c") }.count
            check((!cancellations.isEmpty || (mode == "low-space" && polled >= 4)) && cancellations.allSatisfy { $0 == ["transfers", "-c", "42"] }, "cancel only owned tag, or confirm no owned transfer registered")
            check(!calls(bin).contains(where: { $0.contains("-a") }), "never issue global cancellation")
            check(unconfirmed == (mode == "cancel-fails" || (mode == "low-space" && cancellations.isEmpty)), "unconfirmed cancellation is a typed blocking failure")
        }
        do {
            let (_, client) = try fixture("success"); let began = Date()
            do { _ = try await client.execute(["unresponsive-command"], timeout: 0.1); fatalError("Timeout not enforced") } catch {}
            check(Date().timeIntervalSince(began) < 3, "SIGTERM-resistant client is bounded and escalated")
        }
        // Pass 2: missing files, automatic-release revocation and cloud-error recovery.
        do {
            let cloud = FakeCloud(); let engine = store(cloud); var t = uploaded(); t.sha256 = String(repeating: "0", count: 64); engine.transfers = [t]
            let released = await engine.releaseOne(t)
            check(!released && engine.transfers[0].stage == .needsReview && engine.completed == 0, "missing file never returns to Uploaded")
            check(cloud.evicted.isEmpty, "missing file cannot be evicted")
        }
        do {
            let cloud = FakeCloud(); let engine = store(cloud); let t = try await putFile(engine, uploaded()); engine.transfers = [t]
            engine.autoRelease = true; engine.refreshUploads(); engine.setAutoRelease(false)
            try await Task.sleep(nanoseconds: 150_000_000)
            check(cloud.evicted.isEmpty, "turning off automatic release before its task starts prevents eviction")
        }
        do {
            let cloud = FakeCloud(); let gate = GatedHasher(String(repeating: "a", count: 64)); let engine = store(cloud, hasher: gate)
            var t = try await putFile(engine, uploaded()); t.sha256 = String(repeating: "a", count: 64); engine.transfers = [t]
            engine.autoRelease = true; engine.refreshUploads()
            try await waitFor { await gate.started }
            engine.setAutoRelease(false); await gate.finish()
            try await Task.sleep(nanoseconds: 100_000_000)
            check(cloud.evicted.isEmpty, "turning off automatic release while checksum is pending prevents eviction")
        }
        do {
            let cloud = FakeCloud(); cloud.observation = .failed("Account requires attention")
            let engine = store(cloud); var t = try await putFile(engine, uploaded()); t.stage = .awaitingUpload; engine.transfers = [t]
            engine.refreshUploads()
            check(engine.transfers[0].stage == .needsReview, "persistent cloud errors become actionable review items")
            engine.skip(engine.transfers[0])
            check(engine.transfers[0].stage == .skipped && !engine.hasActiveFiles && engine.completed == 0, "deferred upload unblocks run without claiming backup")
            let retainedPath = try Safety.destination(root: engine.runRoot!, relativePath: t.entry.relativePath).path
            check(fm.fileExists(atPath: retainedPath), "deferring retains local copy")
        }
        do {
            let cloud = FakeCloud(); cloud.rejectEviction = true
            let engine = store(cloud); let t = try await putFile(engine, uploaded()); engine.transfers = [t]
            _ = await engine.releaseOne(t)
            check(engine.transfers[0].stage == .needsReview && cloud.evicted.isEmpty, "eviction error does not assert cloud survival")
        }
        // 0.9.2: releasing must work when the disk is low; it is what frees space.
        do {
            let cloud = FakeCloud(); let engine = store(cloud, disk: LowSpace()); let t = try await putFile(engine, uploaded()); engine.transfers = [t]
            let released = await engine.releaseOne(t)
            check(released && cloud.evicted.count == 1 && engine.transfers[0].stage == .released, "release frees space even when less than the 50 GB reserve is free (0.9.2)")
        }
        // Pass 3: full local copy flow, pre-existing destinations, journal failures and restart.
        do {
            let cloud = FakeCloud(); let engine = store(cloud); let (bin, _) = try fixture("success"); engine.binaryFolder = bin
            var t = uploaded(); t.stage = .queued; engine.transfers = [t]
            try await engine.transfer(t)
            check(engine.transfers[0].stage == .awaitingUpload && engine.transfers[0].sha256 != nil, "download and copied local bytes match before awaiting upload")
            engine.refreshUploads(); check(engine.transfers[0].stage == .uploaded, "provider status promotes only matching local copy")
            let released = await engine.releaseOne(engine.transfers[0]); check(released && cloud.evicted.count == 1, "authorized fixture release uses provider adapter")
            let before = calls(bin).filter { $0.first == "get" }.count
            do { try await engine.transfer(t); fatalError("Existing target was overwritten") } catch {}
            check(calls(bin).filter { $0.first == "get" }.count == before, "existing destination is rejected before another download")
        }
        do {
            let cloud = FakeCloud(); let engine = store(cloud); var t = uploaded(); t.stage = .copying; engine.transfers = [t]; engine.persist()
            let restored = TransferStore(supportURL: engine.support, preferences: engine.preferences, cloud: cloud, startInDemo: true, autoDetectMEGA: false, startMonitor: false); restored.openWorkspace()
            check(restored.transfers.first?.stage == .needsReview, "interrupted copy restores to review")
            check(restored.runID == engine.runID, "restart preserves run identity")
        }
        do {
            let cloud = FakeCloud(); let engine = store(cloud); engine.persist()
            let restored = TransferStore(supportURL: engine.support, preferences: engine.preferences, cloud: cloud, startInDemo: true, autoDetectMEGA: false, startMonitor: false); restored.openWorkspace()
            check(restored.error == nil && restored.transfers.isEmpty, "empty run restores without validation failure")
        }
        do {
            let cloud = FakeCloud(); let blocked = base.appendingPathComponent("not-a-directory"); try Data([1]).write(to: blocked)
            let engine = TransferStore(supportURL: blocked, cloud: cloud, startInDemo: true, autoDetectMEGA: false, startMonitor: false); engine.demo = false; engine.persist()
            check(engine.stateWriteFailed, "journal failure is a blocking state")
            let released = await engine.releaseOne(uploaded()); check(!released && cloud.evicted.isEmpty, "journal failure prevents release")
        }
        do {
            let cloud = FakeCloud(); cloud.observation = .uploadedOnlineOnly
            let gate = GatedHasher(String(repeating: "0", count: 64)); let engine = store(cloud, hasher: gate)
            var t = uploaded(); t.sha256 = String(repeating: "0", count: 64); engine.transfers = [t]
            let result = await engine.releaseOne(t)
            let hashed = await gate.started
            check(result && !hashed && cloud.evicted.isEmpty, "already-online-only files are never hydrated just to release them")
        }
        do {
            let cloud = FakeCloud(); let engine = store(cloud); var t = uploaded(); t.stage = .queued; engine.transfers = [t]; engine.persist()
            engine.update(t.id, .downloading, "Fixture transition")
            let journal = engine.support.appendingPathComponent("pilot-changes.jsonl")
            let handle = try FileHandle(forWritingTo: journal); try handle.seekToEnd(); try handle.write(contentsOf: Data("{partial".utf8)); try handle.close()
            let restored = TransferStore(supportURL: engine.support, preferences: engine.preferences, cloud: cloud, startInDemo: true, autoDetectMEGA: false, startMonitor: false); restored.openWorkspace()
            check(restored.transfers.first?.stage == .needsReview && restored.error == nil, "torn final journal append recovers last complete transition")
            check(restored.events.contains(where: { $0.contains("Fixture transition") }) == false, "file notes are not mistaken for activity events")
        }
        do {
            let cloud = FakeCloud(); let engine = store(cloud); engine.persist()
            let snapshot = try Data(contentsOf: engine.stateURL)
            let journal = engine.support.appendingPathComponent("pilot-changes.jsonl")
            let handle = try FileHandle(forWritingTo: journal); try handle.seekToEnd(); try handle.write(contentsOf: Data("not-json\n".utf8)); try handle.close()
            let restored = TransferStore(supportURL: engine.support, preferences: engine.preferences, cloud: cloud, startInDemo: true, autoDetectMEGA: false, startMonitor: false); restored.openWorkspace()
            check(restored.stateWriteFailed && restored.error != nil, "corrupt complete journal record fails closed")
            let after = try Data(contentsOf: engine.stateURL)
            check(after == snapshot, "corrupt history is never replaced by an empty run")
        }
        do {
            let cloud = FakeCloud(); let engine = store(cloud); engine.persist()
            let first = TransferStore(supportURL: engine.support, preferences: engine.preferences, cloud: cloud, startInDemo: true, autoDetectMEGA: false, startMonitor: false); first.openWorkspace()
            let snapshot = try Data(contentsOf: engine.stateURL)
            let second = TransferStore(supportURL: engine.support, preferences: engine.preferences, cloud: cloud, startInDemo: true, autoDetectMEGA: false, startMonitor: false); second.openWorkspace()
            check(second.error != nil && second.demo, "a second pilot cannot acquire the active history lock")
            let after = try Data(contentsOf: engine.stateURL)
            check(after == snapshot, "a locked-out instance cannot rewrite another pilot's history")
        }
        do {
            let cloud = FakeCloud(); let engine = store(cloud)
            engine.running = true; engine.autoRelease = true; engine.stopNow()
            check(engine.stopSignal.isCancelled && engine.autoRelease && engine.pauseRequested, "Stop now halts releases in progress and stops future downloads, keeping the user's release setting (0.8.7)")
        }
        do {
            let cloud = FakeCloud(); let engine = store(cloud)
            engine.transfers = (0..<100_000).map { i in Transfer(entry: .init(remoteHandle: "H:" + String(format: "%08d", i), relativePath: "Synthetic/file-\(i).bin", expectedBytes: 0)) }
            engine.persist()
            let snapshot = try Data(contentsOf: engine.stateURL)
            for i in 0..<20 { engine.update(engine.transfers[99_999].id, .needsReview, "Synthetic update \(i)") }
            let unchanged = try Data(contentsOf: engine.stateURL)
            check(unchanged == snapshot, "100,000-file run appends transitions without rewriting the full snapshot")
            let journalSize = try engine.support.appendingPathComponent("pilot-changes.jsonl").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            check(journalSize < 30_000, "large-run incremental journal stays bounded for small transitions")
            let restored = TransferStore(supportURL: engine.support, preferences: engine.preferences, cloud: cloud, startInDemo: true, autoDetectMEGA: false, startMonitor: false); restored.openWorkspace()
            check(restored.transfers.count == 100_000 && restored.transfers.last?.note == "Synthetic update 19", "100,000-file history replays to the latest durable state")
        }
        do {
            let cloud = FakeCloud(); cloud.observation = .failed("Temporary server connection")
            let support = base.appendingPathComponent(UUID().uuidString)
            final class Clock { var time = Date(timeIntervalSince1970: 1000) }
            let clock = Clock()
            let engine = TransferStore(supportURL: support, cloud: cloud, uploadErrorGrace: 60, now: { clock.time }, startInDemo: true, autoDetectMEGA: false, startMonitor: false)
            check(engine.freeSpaceKnown && engine.freeBytes > 0, "new isolated workspace reads capacity before its directories exist")
            engine.demo = false; engine.destination = support.appendingPathComponent("fake-cloud")
            var t = uploaded(); t.stage = .awaitingUpload; engine.transfers = [t]
            engine.refreshUploads()
            check(engine.transfers[0].stage == .awaitingUpload && engine.completed == 0, "brief upload error is monitored without falsely claiming completion")
            cloud.observation = .uploaded; clock.time = clock.time.addingTimeInterval(5); engine.refreshUploads()
            check(engine.transfers[0].stage == .uploaded, "transient error automatically recovers only after positive Apple upload status")
            cloud.observation = .failed("Persistent connection problem"); engine.refreshUploads()
            clock.time = clock.time.addingTimeInterval(61); engine.refreshUploads()
            check(engine.transfers[0].stage == .needsReview && engine.completed == 0, "persistent error still becomes actionable after the bounded grace period")
        }
        do {
            let (bin, client) = try fixture("browse")
            let roots = try await client.folders(in: "/")
            check(roots.map(\.name) == ["Documents", "Photos"], "folder browser returns sorted directories only")
            let children = try await client.folders(in: "/Photos", handle: "H:PHOTOS00")
            check(children.first?.path == "/Photos/Trips", "folder browser opens nested folders")
            check(calls(bin).contains(where: { $0.last == "H:PHOTOS00" }), "browsing pins the selected folder handle rather than an ambiguous name")
            check(!calls(bin).contains(where: { $0.first == "get" }), "browsing never downloads file contents")
            let cloud = FakeCloud(); let engine = store(cloud); engine.binaryFolder = bin
            engine.prepareSourceFolder("/Photos", handle: "H:PHOTOS00")
            try await waitFor { !engine.busy }
            check(engine.transfers.count == 1 && engine.transfers[0].stage == .queued && engine.selectedSourcePath == "/Photos", "choosing a folder prepares its backup list inside the app")
            check(!engine.capacityConfirmed && !calls(bin).contains(where: { $0.first == "get" }), "source selection requires a fresh capacity acknowledgment and explicit start")
            let previousID = engine.runID; engine.prepareSourceFolder("/Other")
            check(engine.runID == previousID && engine.transfers.count == 1 && engine.error != nil, "source selection cannot replace a pending run")
            engine.capacityConfirmed = true
            let restored = TransferStore(supportURL: engine.support, preferences: engine.preferences, cloud: cloud, startInDemo: true, autoDetectMEGA: false, startMonitor: false); restored.openWorkspace()
            check(restored.selectedSourcePath == "/Photos", "selected source folder survives a restart")
            check(restored.capacityConfirmed, "storage confirmation survives a restart for the same run and source (0.6)")
            check(restored.destination == nil, "a saved destination outside iCloud Drive is never restored (0.6)")
            check(restored.startRequirements.contains { $0.contains("iCloud destination") } && !restored.startRequirements.contains { $0.contains("iCloud storage") }, "after restart only the genuinely missing step is listed (0.6)")
            check(TransferStore.samePath("/tmp/a/../b", "/tmp/b"), "destination paths are compared after normalising (0.6)")
            check(ProgressTiming.rate(bytes: 1_000, seconds: 10, files: 5) == nil && ProgressTiming.rate(bytes: 1_000, seconds: 60, files: 1) == nil, "no time estimate before 30 s and 2 files of real evidence (0.7)")
            let r = ProgressTiming.rate(bytes: 10_000_000_000, seconds: 3_600, files: 50)!
            check(ProgressTiming.remaining(bytes: 2_000_000_000_000, rate: r, spoken: true).contains("days"), "2 TB at 10 GB/h is spoken in days and hours (0.7)")
            let samples: [(bytes: Int64, seconds: Double)] = [(1_000_000, 3), (11_000_000, 4), (101_000_000, 13)]
            let est = ProgressTiming.estimate(samples: samples, sumFileSeconds: 20, wallSeconds: 10, files: 10, bytes: 0)!
            check(abs(est - 14.5) < 0.6, "time estimate counts per-file overhead and divides by measured parallelism (0.8)")
        }
        do {
            let cloud = FakeCloud(); let support = base.appendingPathComponent(UUID().uuidString)
            let live = TransferStore(supportURL: support, cloud: cloud, autoDetectMEGA: false, startMonitor: false)
            check(!live.demo && live.transfersEnabled && live.transfers.isEmpty && live.tab == "Connections", "normal startup opens a real empty transfer workspace without environment flags")
            check(!live.running && !live.autoRelease && !live.capacityConfirmed, "live startup never starts a transfer or enables automatic local release")
            let prefsOn = UserDefaults(suiteName: "CloudTransferChecks-\(UUID().uuidString)")!
            let app = TransferStore(supportURL: base.appendingPathComponent(UUID().uuidString), preferences: prefsOn, cloud: cloud, startInDemo: true, autoDetectMEGA: false, startMonitor: false, autoReleaseByDefault: true)
            check(app.autoRelease, "the app starts with automatic release on by default (0.8.7)")
            app.demo = false; app.setAutoRelease(false)
            let reopened = TransferStore(supportURL: base.appendingPathComponent(UUID().uuidString), preferences: prefsOn, cloud: cloud, startInDemo: true, autoDetectMEGA: false, startMonitor: false, autoReleaseByDefault: true)
            check(!reopened.autoRelease, "turning automatic release off is remembered (0.8.7)")
            check(FileManager.default.fileExists(atPath: live.stateURL.path), "normal startup creates durable real-workspace history")
        }
        // Exercise the same controller actions used by the native buttons with isolated providers.
        do {
            let (bin, _) = try fixture("controlled"); let cloud = FakeCloud(); let engine = store(cloud)
            engine.binaryFolder = bin
            engine.transfers = [
                Transfer(entry: .init(remoteHandle: "H:ABCDEFGH", relativePath: "first.bin", expectedBytes: 32)),
                Transfer(entry: .init(remoteHandle: "H:ABCDEFGI", relativePath: "second.bin", expectedBytes: 32))
            ]
            engine.startTransfers()
            check(!engine.running && engine.error?.contains("iCloud has room") == true && !fm.fileExists(atPath: bin.appendingPathComponent("get-started").path), "Start explains missing capacity confirmation without downloading")
            engine.error = nil; engine.capacityConfirmed = true; engine.startTransfers()
            try await waitFor { fm.fileExists(atPath: bin.appendingPathComponent("get-started").path) }
            engine.pauseAfterFile()
            check(engine.pauseRequested && engine.controlStatus.contains("Pausing") && !engine.stopSignal.isCancelled, "Pause acknowledges immediately without cancelling the current file")
            try Data().write(to: bin.appendingPathComponent("allow-get"))
            try await waitFor { !engine.running }
            check(engine.transfers[0].stage == .awaitingUpload && engine.transfers[1].stage == .queued, "Pause completes the current file and leaves the next file queued")
            check(calls(bin).filter { $0.first == "get" }.count == 1 && engine.controlStatus.contains("Paused"), "Pause starts no second download and shows retained progress")
            engine.startTransfers(); try await waitFor { !engine.running }
            check(engine.transfers.allSatisfy { $0.stage == .awaitingUpload } && calls(bin).filter { $0.first == "get" }.count == 2, "Resume processes only the remaining queued file")
        }
        // 0.8.5: failing files are retried automatically, then set aside; the queue runs to the end and never stops.
        do {
            let (bin, _) = try fixture("changed"); let cloud = FakeCloud(); let engine = store(cloud)
            engine.binaryFolder = bin; engine.capacityConfirmed = true; engine.retryDelay = 0; engine.cooldownSeconds = 0; engine.maxAttempts = 4
            engine.transfers = ["H:FAILS001", "H:FAILS002", "H:FAILS003", "H:FAILS004"].enumerated().map { i, h in Transfer(entry: .init(remoteHandle: h, relativePath: "f\(i).bin", expectedBytes: 32)) }
            engine.startTransfers()
            try await waitFor { !engine.running }
            check(engine.transfers.allSatisfy { $0.stage == .needsReview } && !engine.pauseRequested, "every failing file was tried and set aside; the queue was not stopped (0.8.5)")
            check(calls(bin).filter { $0.first == "ls" }.count == 4 * engine.maxAttempts && calls(bin).filter { $0.first == "get" }.isEmpty, "each failing file is tried the full number of times automatically and never downloads a changed source (0.8.6)")
            check(engine.reviewItems.count == 4 && TransferStore.automaticAttempts == 20 && engine.events.contains { $0.contains("Other files continue") }, "set-aside files are listed for review with a clear log line (0.8.5)")
            let lsBefore = calls(bin).filter { $0.first == "ls" }.count
            engine.startTransfers(); try await waitFor { !engine.running }
            check(calls(bin).filter { $0.first == "ls" }.count == lsBefore && engine.reviewItems.count == 4, "a file that used all its attempts is not requeued on the next Start (0.8.6)")
        }
        // 0.8.9: quiet retries never set a file aside, and files set aside earlier are rechecked automatically.
        do {
            let (bin, _) = try fixture("changed"); let cloud = FakeCloud(); let engine = store(cloud)
            engine.binaryFolder = bin; engine.capacityConfirmed = true; engine.retryDelay = 0; engine.cooldownSeconds = 0; engine.maxAttempts = 2
            engine.quietRetries = true; engine.longRetryDelay = 0
            engine.transfers = ["H:FAILS001", "H:FAILS002"].enumerated().map { i, h in Transfer(entry: .init(remoteHandle: h, relativePath: "q\(i).bin", expectedBytes: 32)) }
            engine.update(engine.transfers[1].id, .needsReview, "Set aside after 20 automatic attempts: old version")
            engine.startTransfers()
            try await waitFor { calls(bin).filter { $0.first == "ls" }.count >= 12 }
            check(engine.running && engine.reviewCount == 0, "quiet retries keep going past the attempt limit and never flag a file (0.8.9)")
            check(engine.transfers[1].stage == .queued || (engine.transfers[1].attempts ?? 0) > 0, "a file set aside by an earlier version is rechecked and queued automatically (0.8.9)")
            engine.pauseAfterFile(); try await waitFor { !engine.running }
            check(engine.reviewCount == 0, "pausing quiet retries leaves files queued, not flagged (0.8.9)")
        }
        // 0.8: several files run side by side, never more than the limit, each file exactly once.
        do {
            let (bin, _) = try fixture("controlled"); let cloud = FakeCloud()
            let support = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let prefs = UserDefaults(suiteName: "CloudTransferChecks-\(UUID().uuidString)")!
            let engine = TransferStore(supportURL: support, preferences: prefs, cloud: cloud, disk: FixtureSpace(), uploadErrorGrace: 0, startInDemo: true, autoDetectMEGA: false, startMonitor: false, parallel: .fixed(3))
            engine.demo = false; engine.transfers = []; engine.events = []; engine.destination = support.appendingPathComponent("fake-cloud")
            engine.binaryFolder = bin; engine.capacityConfirmed = true
            engine.transfers = ["H:PARALL01", "H:PARALL02", "H:PARALL03", "H:PARALL04"].enumerated().map { i, h in Transfer(entry: .init(remoteHandle: h, relativePath: "p\(i).bin", expectedBytes: 32)) }
            engine.startTransfers()
            try await waitFor { engine.activeFiles.count == 3 }
            check(engine.transfers[3].stage == .queued && engine.controlStatus.contains("3 files"), "parallel workers run 3 files at once and hold the 4th (0.8)")
            check(engine.currentBatch?.number == 1 && engine.currentBatch?.files == 4, "batch progress reports batch 1 of the run (0.8)")
            try Data().write(to: bin.appendingPathComponent("allow-get"))
            try await waitFor { !engine.running }
            check(engine.transfers.allSatisfy { $0.stage == .awaitingUpload } && calls(bin).filter { $0.first == "get" }.count == 4 && engine.peakParallel == 3, "parallel run copies every file exactly once without exceeding the limit (0.8)")
            check(engine.activeFiles.isEmpty && engine.currentBatch == nil && engine.percentText == "100%", "progress clears active files and reaches 100% (0.8)")
            // 0.9.1: Turbo lifts the limit above the normal policy, and is remembered.
            do {
                let (tbin, _) = try fixture("controlled")
                let tsupport = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
                let tprefs = UserDefaults(suiteName: "CloudTransferChecks-\(UUID().uuidString)")!
                let turbo = TransferStore(supportURL: tsupport, preferences: tprefs, cloud: FakeCloud(), disk: FixtureSpace(), uploadErrorGrace: 0, startInDemo: true, autoDetectMEGA: false, startMonitor: false, parallel: .fixed(3))
                turbo.demo = false; turbo.transfers = []; turbo.events = []; turbo.destination = tsupport.appendingPathComponent("fake-cloud")
                turbo.binaryFolder = tbin; turbo.capacityConfirmed = true; turbo.turbo = true
                turbo.transfers = ["H:TURBO001", "H:TURBO002", "H:TURBO003", "H:TURBO004"].enumerated().map { i, h in Transfer(entry: .init(remoteHandle: h, relativePath: "t\(i).bin", expectedBytes: 32)) }
                turbo.startTransfers()
                try await waitFor { turbo.activeFiles.count == 4 }
                check(turbo.workerLimit == TransferStore.turboWorkers && tprefs.bool(forKey: "turbo"), "Turbo runs more files than the normal limit and is remembered (0.9.1)")
                try Data().write(to: tbin.appendingPathComponent("allow-get"))
                try await waitFor { !turbo.running }
                check(turbo.transfers.allSatisfy { $0.stage == .awaitingUpload } && turbo.peakParallel == 4, "Turbo copies every file exactly once (0.9.1)")
                turbo.turbo = false
                check(!tprefs.bool(forKey: "turbo"), "turning Turbo off is remembered (0.9.1)")
            }
            check(TransferStore.isSystemJunk("Archive/Disk/$RECYCLE.BIN/S-1/$RX.iso") && TransferStore.isSystemJunk("D/System Volume Information/x") && !TransferStore.isSystemJunk("Photos/recycle bin tips.txt"), "Recycle Bin and system folders are recognised; ordinary names are not (0.8.1)")
            engine.transfers.append(Transfer(entry: .init(remoteHandle: "H:JUNK0001", relativePath: "$RECYCLE.BIN/old.iso", expectedBytes: 1_000)))
            let before = engine.totalBytes; engine.excludeSystemJunk(announceResult: false)
            try await waitFor { !engine.busy }
            check(engine.transfers.last?.stage == .excluded && engine.totalBytes == before - 1_000 && engine.queuedCount == 0, "excluded files leave the queue and the totals (0.8.1)")
            cloud.observation = .waiting; cloud.uploading = true; engine.refreshUploads()
            check(engine.uploadingNow.count == 4 && engine.awaitingUploadFiles == 4 && engine.uploadRate == nil, "files macOS is sending appear under Uploading now; no speed claimed without evidence (0.8.2)")
            cloud.observation = .uploaded; cloud.uploading = false; engine.refreshUploads()
            check(engine.uploadingNow.isEmpty && engine.uploadPercentText == "100%", "uploaded files leave Uploading now and upload reaches 100% (0.8.2)")
            cloud.observation = .failed("Couldn't access your iCloud account"); engine.refreshUploads(); engine.refreshUploads()
            check(engine.transfers.filter { $0.stage == .needsReview }.count == 4, "a persistent iCloud refusal becomes review after the grace period (0.8.3)")
            cloud.observation = .uploaded; engine.refreshUploads()
            check(engine.transfers.filter { $0.stage == .uploaded }.count == 4, "files iCloud refused recover automatically once Apple accepts them (0.8.3)")
        }
        do {
            let (bin, _) = try fixture("hang"); let cloud = FakeCloud(); let engine = store(cloud)
            engine.binaryFolder = bin; engine.capacityConfirmed = true
            engine.transfers = [
                Transfer(entry: .init(remoteHandle: "H:ABCDEFGH", relativePath: "first.bin", expectedBytes: 32)),
                Transfer(entry: .init(remoteHandle: "H:ABCDEFGI", relativePath: "second.bin", expectedBytes: 32))
            ]
            engine.startTransfers()
            try await waitFor { fm.fileExists(atPath: bin.appendingPathComponent("get-started").path) }
            engine.stopNow()
            check(engine.controlStatus.contains("Stopping"), "Stop acknowledges immediately")
            try await waitFor { !engine.running }
            check(engine.transfers[0].stage == .needsReview && engine.transfers[1].stage == .queued, "Stop retains the interrupted file for review and leaves later files queued")
            check(calls(bin).contains { $0.first == "transfers" && $0.contains("42") } && !calls(bin).contains { $0.first == "transfers" && ($0.contains("7") || $0.contains("-a")) }, "Stop cancels the app-owned service tag and never the unrelated transfer")
            check(fm.fileExists(atPath: engine.staging.appendingPathComponent(engine.transfers[0].id.uuidString).path), "Stop preserves the partial staging folder")
        }
        // Third review: shutdown-adjacent states, idle completion and low-space controls.
        do {
            let cloud = FakeCloud(); let engine = store(cloud)
            var t = uploaded(); t.stage = .awaitingUpload; engine.transfers = [t]
            check(engine.controlStatus.contains("waiting for iCloud"), "finished downloads awaiting upload are not mislabeled setup required")
            let destination = engine.destination; engine.destination = nil
            check(engine.controlStatus.contains("Reselect iCloud"), "restored waiting uploads explain the destination needed for monitoring")
            engine.destination = destination
            engine.update(t.id, .uploaded, "Fixture uploaded")
            check(engine.controlStatus.contains("Run complete"), "fully uploaded queue reports completion")
            engine.update(t.id, .needsReview, "Fixture interrupted")
            check(engine.controlStatus.contains("review incomplete"), "incomplete finished queue remains visibly distinct from completion")
            engine.running = true; engine.retry(engine.transfers[0])
            check(!engine.busy && engine.transfers[0].stage == .needsReview, "retry cannot race a running queue")
            engine.running = false; engine.destination = nil; engine.capacityConfirmed = true
            check(engine.startRequirements.contains { $0.contains("iCloud destination") }, "missing destination is explained even when capacity is acknowledged")
            engine.binaryFolder = nil
            check(engine.startRequirements.contains { $0.contains("MEGAcmd") }, "missing MEGA connection is explained")
            engine.stateWriteFailed = true; engine.startTransfers()
            check(!engine.running && engine.error != nil, "failed durable state blocks Start with an explanation")
        }
        do {
            struct WaitingSpace: SpaceAccess { func available(at url: URL) throws -> Int64 { 50_500_000_000 } }
            let cloud = FakeCloud(); let (bin, _) = try fixture("success")
            let engine = TransferStore(supportURL: base.appendingPathComponent(UUID().uuidString), cloud: cloud, disk: WaitingSpace(), startInDemo: true, autoDetectMEGA: false, startMonitor: false)
            engine.demo = false; engine.transfers = [Transfer(entry: .init(remoteHandle: "H:ABCDEFGH", relativePath: "waiting.bin", expectedBytes: 32))]
            engine.destination = engine.support.appendingPathComponent("fake-cloud"); engine.binaryFolder = bin; engine.capacityConfirmed = true
            engine.startTransfers(); try await waitFor { engine.waitingForSpace }
            let began = Date(); engine.stopNow(); try await waitFor { !engine.running }
            check(Date().timeIntervalSince(began) < 3 && engine.transfers[0].stage == .queued, "Stop responds during a disk-space wait without starting or changing the file")
            check(!calls(bin).contains { $0.first == "get" }, "space-wait Stop performs no file download")
        }
        print("PASS: \(count) engine assertions. All providers, downloads and cloud actions used disposable local fixtures.")
    }
}
