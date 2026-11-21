import SwiftUI
import AppKit
import CryptoKit
import Darwin
import HarborCore

struct SavedRun: Codable {
    public var transfers: [Transfer]
    public var events: [String]
    public var runID: UUID
    public var destinationPath: String?
    /// Name of the folder created inside the iCloud destination. Older saved runs (nil) used "Cloud Transfer+ <run ID>".
    public var runFolderName: String? = nil
    var sequence: Int64? = nil
    var sourceRoot: String? = nil
}

public var uiScale: CGFloat = 1.25

public enum CloudStatus { case missing, waiting, uploaded, uploadedOnlineOnly, failed(String) }
@MainActor public protocol CloudAccess {
    func status(of url: URL) -> CloudStatus
    func evict(_ url: URL) throws
    /// True while macOS is actively sending the file to iCloud. macOS reports no per-file percentage (checked 0.8.2).
    func isUploading(_ url: URL) -> Bool
}
public extension CloudAccess { func isUploading(_ url: URL) -> Bool { false } }
@MainActor public final class SystemCloudAccess: CloudAccess {
    public init() {}
    public func status(of url: URL) -> CloudStatus {
        do {
            var current = url
            current.removeAllCachedResourceValues()
            let v = try current.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingStatusKey])
            if let error = v.ubiquitousItemUploadingError { return .failed(error.localizedDescription) }
            if v.isUbiquitousItem == nil && !FileManager.default.fileExists(atPath: url.path) { return .missing }
            if v.isUbiquitousItem == true && v.ubiquitousItemIsUploaded == true && v.ubiquitousItemIsUploading != true {
                return v.ubiquitousItemDownloadingStatus == .notDownloaded ? .uploadedOnlineOnly : .uploaded
            }
            return .waiting
        } catch { return .failed(error.localizedDescription) }
    }
    public func evict(_ url: URL) throws { try FileManager.default.evictUbiquitousItem(at: url) }
    public func isUploading(_ url: URL) -> Bool {
        var current = url; current.removeAllCachedResourceValues()
        return (try? current.resourceValues(forKeys: [.ubiquitousItemIsUploadingKey]).ubiquitousItemIsUploading) == true
    }
}

public protocol FileHashing: Sendable { func digest(_ url: URL) async throws -> String }
public struct SHA256Hasher: FileHashing {
    public init() {}
    public func digest(_ url: URL) async throws -> String { try await TransferStore.digest(url) }
}

@MainActor public final class TransferStore: ObservableObject {
    @Published public var transfers: [Transfer] = []
    @Published public var events: [String] = []
    @Published public var demo = true
    @Published public var running = false
    @Published public var busy = false
    @Published public var waitingForSpace = false
    @Published public var freeBytes: Int64 = 0
    @Published public var freeSpaceKnown = false
    @Published public var destination: URL?
    @Published public var binaryFolder: URL?
    @Published public var error: String?
    @Published public var notice: String?
    /// Remembered per run and source, so a restart or re-choosing the same iCloud folder does not silently untick it.
    @Published public var capacityConfirmed = false {
        didSet { if !demo && oldValue != capacityConfirmed { preferences.set(capacityConfirmed, forKey: capacityKey) } }
    }
    private var capacityKey: String { "capacityConfirmed.\(runID.uuidString).\(selectedSourcePath ?? "")" }
    @Published public var autoRelease = false
    @Published public var selected: UUID?
    @Published public var filter = "All files"
    @Published public var search = ""
    @Published public var tab = "Overview"
    @Published public var showingSourcePicker = false
    @Published public var selectedSourcePath: String?
    /// Short confirmations shown under each setup step right after a choice (0.6.1), so re-choosing the same folder is visibly acknowledged.
    @Published public var destinationConfirmation: String?
    @Published public var sourceConfirmation: String?
    private var iCloudRootPath: String { fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").resolvingSymlinksInPath().standardizedFileURL.path }
    /// "iCloud Drive › My Folder" rather than the internal Mobile Documents path.
    public func iCloudDisplay(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(iCloudRootPath) else { return url.path }
        let rest = path.dropFirst(iCloudRootPath.count).split(separator: "/").map(String.init)
        return (["iCloud Drive"] + rest).joined(separator: " › ")
    }
    public var destinationDisplay: String { destination.map(iCloudDisplay) ?? "Not chosen" }
    public var runFolderDisplay: String { runRoot.map(iCloudDisplay) ?? "Not chosen" }
    @Published public var textScale: Double = 1.25 {
        didSet { uiScale = CGFloat(textScale); preferences.set(textScale, forKey: "textScale") }
    }
    // MARK: 0.8 parallel workers, live per-file progress, batches and measured time estimates
    public let parallelPolicy: ParallelPolicy
    @Published public private(set) var workerLimit = 1
    @Published public private(set) var macIdle = false
    @Published public private(set) var activeFiles: [UUID: ActiveFile] = [:]
    public private(set) var peakParallel = 0
    /// 0.9.1 Turbo: for when you step away. Runs `turboWorkers` files side by side whether or not the Mac is in use,
    /// retries sooner and waits less after network hiccups. Free-space checks still apply to every file, so Turbo
    /// can never fill the disk; it just stops holding back. Remembered between launches.
    public static let turboWorkers = 10
    @Published public var turbo = false {
        didSet {
            guard oldValue != turbo else { return }
            preferences.set(turbo, forKey: "turbo")
            refreshWorkerLimit()
            if running {
                log(turbo ? "Turbo on: up to \(workerLimit) files at a time, faster retries." : "Turbo off: back to normal speed (up to \(workerLimit) files at a time).")
                // Slots beyond the new limit simply aren't refilled; files already copying finish normally.
            }
            announce(.progress, turbo ? "Turbo on." : "Turbo off.")
        }
    }
    private var effectiveRetryDelay: TimeInterval { turbo ? min(retryDelay, 2) : retryDelay }
    private var effectiveMaxRetryDelay: TimeInterval { turbo ? min(maxRetryDelay, 30) : maxRetryDelay }
    private var effectiveCooldown: TimeInterval { turbo ? min(cooldownSeconds, 20) : cooldownSeconds }
    private var inFlight = 0
    private var inFlightReservation: Int64 = 0
    private var claimed = Set<UUID>()
    private var stopQueue = false
    private var failuresInARow = 0
    /// Automatic retries per file and when each may run again (0.8.5: one file never stops the queue).
    private var retryAfter: [UUID: Date] = [:]
    /// 0.8.6: up to 20 automatic attempts, waiting longer each time (1, 2, 4, 8, 16, then 30 minutes), before a file is set aside.
    public static let automaticAttempts = 20
    public var maxAttempts = TransferStore.automaticAttempts
    public var retryDelay: TimeInterval = 5
    public var maxRetryDelay: TimeInterval = 60
    public var retryingLaterCount: Int { let t = now(); return transfers.filter { $0.stage == .queued && (retryAfter[$0.id] ?? .distantPast) > t }.count }
    private func backoff(_ attempt: Int) -> TimeInterval { min(effectiveMaxRetryDelay, effectiveRetryDelay * pow(2, Double(max(0, attempt - 1)))) }
    /// Clears this app's own partial download for a file, only after MEGA confirms nothing is still writing into it.
    private func clearSlot(_ id: UUID) async -> Bool {
        let slot = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        guard fm.fileExists(atPath: slot.path) else { return true }
        do {
            if !(((try? fm.contentsOfDirectory(atPath: slot.path)) ?? []).isEmpty) {
                guard let client else { return false }
                try await client.cancelOwned(in: slot)
            }
            try removeStagingSlot(slot); return true
        } catch { return false }
    }
    /// Files set aside earlier for reasons a later attempt can fix go back in the queue automatically when transfers start.
    private func requeueRetryable() {
        for t in transfers where t.stage == .needsReview && (t.attempts ?? 0) < maxAttempts && !t.note.hasPrefix(TransferStore.iCloudAttention) && !t.note.hasPrefix("Destination already exists") {
            update(t.id, .queued, "Queued again automatically (attempt \((t.attempts ?? 0) + 1) of \(maxAttempts)).")
        }
    }
    public var cooldownSeconds: TimeInterval = 60
    /// 0.8.9: never flag a file and never ask for a retry. Files keep retrying quietly (every few seconds,
    /// then at most every \(longRetryDelay) s), and anything set aside earlier is rechecked automatically.
    public var quietRetries = false
    public var longRetryDelay: TimeInterval = 300
    private var lastAutoRecheck = Date.distantPast
    /// Silent version of Retry all: a matching iCloud copy is accepted, otherwise the file is queued again.
    /// Only a different, unverified file sitting at the destination is left alone (it is never overwritten).
    private func autoRecheckSetAside() async {
        guard quietRetries, let root = runRoot else { return }
        lastAutoRecheck = Date()
        let items = transfers.filter { $0.stage == .needsReview && !$0.note.hasPrefix(TransferStore.iCloudAttention) }
        var queued = 0, accepted = 0
        for t in items {
            guard let current = transfers.first(where: { $0.id == t.id }), current.stage == .needsReview else { continue }
            let slot = staging.appendingPathComponent(t.id.uuidString, isDirectory: true)
            do {
                let target = try Safety.destination(root: root, relativePath: t.entry.relativePath)
                if fm.fileExists(atPath: target.path) {
                    if let expected = current.sha256, try await hasher.digest(target) == expected {
                        try removeStagingSlot(slot)
                        update(t.id, .awaitingUpload, "Existing iCloud copy matches the recorded SHA-256. Waiting for Apple's upload status.")
                        accepted += 1
                    }
                    continue
                }
                if fm.fileExists(atPath: slot.path) {
                    guard let client else { continue }
                    try await client.cancelOwned(in: slot)
                    try removeStagingSlot(slot)
                }
                retryAfter.removeValue(forKey: t.id)
                if let i = transfers.firstIndex(where: { $0.id == t.id }) { transfers[i].attempts = 0 }
                update(t.id, .queued, "Queued again automatically.")
                queued += 1
            } catch { log("Automatic recheck will try \(t.entry.relativePath) again later: \(error.localizedDescription)") }
        }
        if queued + accepted > 0 { log("Automatic recheck: \(queued) queued again, \(accepted) already in iCloud.") }
    }
    @Published public private(set) var coolingDown = false
    private var samples: [(bytes: Int64, seconds: Double)] = []
    private var sumFileSeconds: Double = 0
    private var sleepActivity: NSObjectProtocol?
    public static let batchSize = 1000
    private func refreshWorkerLimit() {
        switch parallelPolicy {
        case .fixed(let n): workerLimit = max(1, n); macIdle = false
        case .adaptive(let active, let idle, let idleAfter):
            let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            macIdle = quiet >= idleAfter
            workerLimit = max(1, macIdle ? idle : active)
        }
        if turbo { workerLimit = max(workerLimit, TransferStore.turboWorkers) }
    }
    private func setActive(_ t: Transfer, phase: String, done: Int64? = nil) {
        var file = activeFiles[t.id] ?? ActiveFile(id: t.id, name: (t.entry.relativePath as NSString).lastPathComponent, bytes: t.entry.expectedBytes, done: 0, phase: phase, started: now())
        file.phase = phase; if let done { file.done = done }
        activeFiles[t.id] = file
    }
    /// Time for the given remaining work, from this session's measurements: each file costs a fixed overhead plus its
    /// bytes at the measured speed (least-squares fit), divided by how many files actually ran side by side.
    public func estimatedSeconds(files: Int, bytes: Int64) -> Double? {
        let wall = activeSeconds + (activeSince.map { now().timeIntervalSince($0) } ?? 0)
        guard samples.count >= 3, wall >= 30, files > 0 || bytes > 0 else { return nil }
        return ProgressTiming.estimate(samples: samples, sumFileSeconds: sumFileSeconds, wallSeconds: wall, files: files, bytes: bytes)
    }
    public var copiedFiles: Int { transfers.filter { [.awaitingUpload, .uploaded, .released].contains($0.stage) }.count }
    public var remainingFiles: Int { transfers.filter { [.queued, .downloading, .downloaded, .copying].contains($0.stage) }.count }
    public var percentText: String {
        guard totalBytes > 0 else { return "0%" }
        let p = Double(copiedBytes) * 100 / Double(totalBytes)
        return p > 0 && p < 10 ? String(format: "%.1f%%", p) : "\(Int(p))%"
    }
    public var averageSpeed: Double? {
        let wall = activeSeconds + (activeSince.map { now().timeIntervalSince($0) } ?? 0)
        return wall >= 10 && sessionBytes > 0 ? Double(sessionBytes) / wall : nil
    }
    public var currentBatch: BatchInfo? {
        let unsettled: Set<TransferStage> = [.queued, .downloading, .downloaded, .copying]
        guard let first = transfers.firstIndex(where: { unsettled.contains($0.stage) }) else { return nil }
        let size = TransferStore.batchSize
        let index = first / size
        let all = transfers[(index * size)..<min(transfers.count, (index + 1) * size)]
        // Excluded files are not part of the work; only copied files count as done (0.8.2).
        let slice = all.filter { $0.stage != .excluded }
        let done = slice.filter { [.awaitingUpload, .uploaded, .released].contains($0.stage) }
        let left = slice.filter { unsettled.contains($0.stage) }
        return BatchInfo(number: index + 1, count: (transfers.count + size - 1) / size, firstFile: index * size + 1, lastFile: index * size + all.count,
                         files: slice.count, settledFiles: done.count, bytes: slice.reduce(0) { $0 + $1.entry.expectedBytes },
                         settledBytes: done.reduce(0) { $0 + $1.entry.expectedBytes }, remainingFiles: left.count, remainingBytes: left.reduce(0) { $0 + $1.entry.expectedBytes },
                         reviewFiles: slice.filter { [.needsReview, .skipped].contains($0.stage) }.count)
    }

    public static let iCloudAttention = "iCloud still requires attention:"
    // MARK: 0.8.2 upload progress (Apple reports only uploading / uploaded per file)
    @Published public private(set) var uploadingNow: [UUID: Date] = [:]
    private var uploadHistory: [(at: Date, bytes: Int64)] = []
    private func recordUploadProgress() {
        let t = now(); let b = uploadedBytes
        if uploadHistory.last?.bytes != b || (uploadHistory.last.map { t.timeIntervalSince($0.at) >= 30 } ?? true) { uploadHistory.append((t, b)) }
        // Speed is measured over the last 15 minutes so it follows the real current pace.
        while uploadHistory.count > 2, let first = uploadHistory.first, t.timeIntervalSince(first.at) > 900 { uploadHistory.removeFirst() }
    }
    public var awaitingUploadFiles: Int { transfers.filter { $0.stage == .awaitingUpload }.count }
    public var pendingUploadBytes: Int64 { max(0, copiedBytes - uploadedBytes) }
    /// Bytes per second that Apple has confirmed as uploaded; nil until a minute of evidence shows progress.
    public var uploadRate: Double? {
        guard let first = uploadHistory.first, let last = uploadHistory.last, last.at.timeIntervalSince(first.at) >= 60, last.bytes > first.bytes else { return nil }
        return Double(last.bytes - first.bytes) / last.at.timeIntervalSince(first.at)
    }
    /// Time for Apple to upload what has already been copied, at the measured upload speed.
    public var uploadSecondsLeft: Double? { guard pendingUploadBytes > 0, let r = uploadRate, r > 0 else { return nil }; return Double(pendingUploadBytes) / r }
    public var uploadPercentText: String {
        guard copiedBytes > 0 else { return "0%" }
        let p = Double(uploadedBytes) * 100 / Double(copiedBytes)
        return p > 0 && p < 10 ? String(format: "%.1f%%", p) : "\(Int(p))%"
    }

    // MARK: 0.7 sound, spoken progress and time remaining
    public let feedback: any FeedbackOutput
    @Published public var soundsMuted = false { didSet { preferences.set(soundsMuted, forKey: "soundsMuted"); if soundsMuted { feedback.stopSpeaking() } } }
    /// Bytes copied to iCloud and timing for this session's transfers (pauses and space waits excluded).
    @Published public private(set) var sessionBytes: Int64 = 0
    public private(set) var sessionFiles = 0
    private var activeSeconds: TimeInterval = 0
    private var activeSince: Date?
    private var lastAnnouncedPercent = -1
    public var copiedBytes: Int64 { transfers.filter { [.awaitingUpload, .uploaded, .released].contains($0.stage) }.reduce(0) { $0 + $1.entry.expectedBytes } }
    public var percentComplete: Int { totalBytes > 0 ? Int(Double(copiedBytes) * 100 / Double(totalBytes)) : 0 }
    public var remainingBytes: Int64 { transfers.filter { [.queued, .downloading, .downloaded, .copying].contains($0.stage) }.reduce(0) { $0 + $1.entry.expectedBytes } }
    public var transferRate: Double? { ProgressTiming.rate(bytes: sessionBytes, seconds: activeSeconds + (activeSince.map { now().timeIntervalSince($0) } ?? 0), files: sessionFiles) }
    /// Short header text, e.g. "37% copied · about 2d 4h left".
    public var progressSummary: String {
        guard !demo, !transfers.isEmpty else { return "" }
        var text = "\(percentText) copied"
        if remainingBytes == 0 && remainingFiles == 0 { return text }
        if let seconds = estimatedSeconds(files: remainingFiles, bytes: remainingBytes) { text += " · about \(ProgressTiming.format(seconds: seconds, spoken: false)) left" }
        else if running { text += " · estimating time…" }
        return text
    }
    public var spokenProgress: String {
        var text = "\(percentComplete) percent copied. iCloud has uploaded \(uploadPercentText.replacingOccurrences(of: "%", with: " percent")) of that."
        if remainingBytes == 0 { return text + " All files are copied." }
        if let seconds = estimatedSeconds(files: remainingFiles, bytes: remainingBytes) { text += " About \(ProgressTiming.format(seconds: seconds, spoken: true)) remaining." }
        else { text += " Time remaining will be estimated after a few files." }
        return text
    }
    public func announce(_ kind: ChimeKind, _ text: String? = nil) {
        guard !soundsMuted, !demo else { return }
        feedback.chime(kind)
        if let text { feedback.say(text) }
    }
    /// Speaks progress on request (menu or button), even when the queue is idle. Muting also silences this.
    public func speakProgressNow() { announce(.progress, spokenProgress) }
    private var tickTimer: Timer?
    /// Seconds between quiet working ticks.
    public static let tickInterval: TimeInterval = 4
    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: TransferStore.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, self.running, !self.waitingForSpace, !self.soundsMuted else { return }; self.feedback.tick() }
        }
    }
    private func stopTicking() { tickTimer?.invalidate(); tickTimer = nil }
    private func resumeTiming() { if activeSince == nil { activeSince = now() } }
    private func pauseTiming() { if let since = activeSince { activeSeconds += now().timeIntervalSince(since); activeSince = nil } }
    private func fileCopied(_ t: Transfer) {
        let bytes = t.entry.expectedBytes
        if let started = activeFiles[t.id]?.started {
            let seconds = max(0.05, now().timeIntervalSince(started))
            samples.append((bytes, seconds)); sumFileSeconds += seconds
            if samples.count > 3000 { samples.removeFirst(samples.count - 3000) }
        }
        sessionBytes += bytes; sessionFiles += 1
        // Like a screen-reader installer: speak only at each 10% step; a quiet tick in between shows it is still working.
        let percent = percentComplete
        if lastAnnouncedPercent >= 0 && percent / 10 > lastAnnouncedPercent / 10 { announce(.progress, spokenProgress) }
        lastAnnouncedPercent = percent
    }

    public var runID = UUID()
    public var runFolderName: String? = "Cloud Transfer+"
    public let transfersEnabled = true
    public var expectedDestinationPath: String?
    @Published public var pauseRequested = false
    @Published public var autoReleasing = false
    public var stopSignal = StopSignal()
    var releaseTask: Task<Void, Never>?
    public var releaseGeneration: UInt64 = 0
    public let supportOverride: URL?
    public let preferences: UserDefaults
    let cloud: any CloudAccess
    let hasher: any FileHashing
    let disk: any SpaceAccess
    let uploadErrorGrace: TimeInterval
    let now: () -> Date
    private var uploadFailureFirstSeen: [UUID: Date] = [:]
    public var uploadCursor = 0
    @Published public var stateWriteFailed = false
    private var lockDescriptor: Int32?
    private var journalSequence: Int64 = 0
    private var snapshotRun: UUID?
    private var snapshotCount = 0
    private var dirtyTransfer: Transfer?
    private var dirtyEvent: String?
    private var transferIndex: [UUID: Int] = [:]
    public var client: MegaClient? { binaryFolder.map { MegaClient(binaries: $0, scratch: support.appendingPathComponent("Command scratch", isDirectory: true), disk: disk) } }
    public var monitor: Timer?
    public let fm = FileManager.default
    public var support: URL { if let supportOverride { return supportOverride }; return fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cloud Transfer+", isDirectory: true) }
    public var stateURL: URL { support.appendingPathComponent("pilot.json") }
    public var archiveFolder: URL { support.appendingPathComponent("Archived runs", isDirectory: true) }
    public var stagingRoot: URL { support.appendingPathComponent("Staging", isDirectory: true) }
    public var staging: URL { stagingRoot.appendingPathComponent(runID.uuidString, isDirectory: true) }
    public var runRoot: URL? { destination?.appendingPathComponent(runFolderName ?? "Cloud Transfer+ \(runID.uuidString)", isDirectory: true) }

    public init(supportURL: URL? = nil, preferences: UserDefaults = .standard, cloud: (any CloudAccess)? = nil, hasher: any FileHashing = SHA256Hasher(), disk: any SpaceAccess = SystemSpace(), uploadErrorGrace: TimeInterval = 900, now: @escaping () -> Date = Date.init, startInDemo: Bool = false, autoDetectMEGA: Bool = true, startMonitor: Bool = true, feedback: (any FeedbackOutput)? = nil, parallel: ParallelPolicy = .fixed(1), autoReleaseByDefault: Bool = false, quietRetries: Bool = false) {
        self.feedback = feedback ?? SilentFeedback(); self.parallelPolicy = parallel; self.quietRetries = quietRetries
        self.supportOverride = supportURL; self.preferences = preferences; self.cloud = cloud ?? SystemCloudAccess(); self.hasher = hasher; self.disk = disk; self.uploadErrorGrace = max(0, uploadErrorGrace); self.now = now
        soundsMuted = preferences.bool(forKey: "soundsMuted")
        // 0.8.7: the app turns automatic release on by default so the Mac's disk never fills with already-uploaded copies.
        autoRelease = (preferences.object(forKey: "autoRelease") as? Bool) ?? autoReleaseByDefault
        if let saved = preferences.object(forKey: "textScale") as? Double, (0.8...2.5).contains(saved) { textScale = saved }
        turbo = preferences.bool(forKey: "turbo")
        uiScale = CGFloat(textScale)
        if startInDemo { loadDemo() } else { openWorkspace(); tab = transfers.isEmpty ? "Connections" : "Overview" }
        refreshSpace()
        let official = URL(fileURLWithPath: "/Applications/MEGAcmd.app/Contents/MacOS", isDirectory: true)
        if autoDetectMEGA && fm.isExecutableFile(atPath: official.appendingPathComponent("mega-exec").path) { binaryFolder = official }
        if startMonitor { monitor = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshSpace(); self?.refreshUploads() } } }
    }

    deinit { if let lockDescriptor { Darwin.close(lockDescriptor) } }

    private func acquireRunLock() throws {
        guard lockDescriptor == nil else { return }
        try fm.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(support.appendingPathComponent(".run.lock").path, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HarborError.invalid("Transfer history could not be locked. Close any other Cloud Transfer+ window before trying again.") }
        lockDescriptor = descriptor
    }

    public var totalBytes: Int64 { transfers.reduce(0) { $1.stage == .excluded ? $0 : $0 + $1.entry.expectedBytes } }
    public var includedCount: Int { transfers.filter { $0.stage != .excluded }.count }
    public var excludedCount: Int { transfers.filter { $0.stage == .excluded }.count }
    /// Windows Recycle Bin and volume-system folders: deleted files and OS bookkeeping, not user data (0.8.1).
    nonisolated public static func isSystemJunk(_ path: String) -> Bool {
        let p = path.lowercased()
        return p.contains("$recycle.bin") || p.contains("system volume information") || p.contains("recycler/")
    }
    /// Leaves Recycle Bin and system files out of the copy. MEGA originals are untouched; "Include again" undoes it.
    public func excludeSystemJunk(announceResult: Bool = true) {
        guard !demo, !running, !busy, !stateWriteFailed else { if running { error = "Pause or stop transfers before excluding files." }; return }
        let targets = transfers.filter { TransferStore.isSystemJunk($0.entry.relativePath) && [.queued, .needsReview, .skipped].contains($0.stage) }
        guard !targets.isEmpty else { if announceResult { notice = "No Recycle Bin or system files are waiting to be copied." }; return }
        let size = ByteCountFormatter.string(fromByteCount: targets.reduce(0) { $0 + $1.entry.expectedBytes }, countStyle: .decimal)
        busy = true
        Task {
            defer { busy = false }
            for t in targets {
                // A file stopped mid-download may have a partial copy in this app's staging; reconcile and remove it.
                let slot = staging.appendingPathComponent(t.id.uuidString, isDirectory: true)
                if t.stage != .queued, fm.fileExists(atPath: slot.path), let client {
                    do { try await client.cancelOwned(in: slot); try removeStagingSlot(slot) }
                    catch { log("Kept a partial download for \(t.entry.relativePath): \(error.localizedDescription)") }
                }
                update(t.id, .excluded, "Excluded: Windows Recycle Bin or system file. Not copied. The MEGA original is untouched; use Include again to copy it.")
            }
            log("Excluded \(targets.count) Recycle Bin and system files (\(size)). They will not be copied.")
            if announceResult { notice = "Excluded \(targets.count) Recycle Bin and system files (\(size)). They will not be copied; MEGA originals are untouched." }
        }
    }
    public func includeAgain(_ t: Transfer) {
        guard !demo, !busy, t.stage == .excluded else { return }
        update(t.id, .queued, "Included again; queued.")
        log("Included again: \(t.entry.relativePath).")
    }
    public var uploadedBytes: Int64 { transfers.filter { [.uploaded, .released].contains($0.stage) }.reduce(0) { $0 + $1.entry.expectedBytes } }
    public var completed: Int { transfers.filter { [.uploaded, .released].contains($0.stage) }.count }
    public var reviewCount: Int { transfers.filter { $0.stage == .needsReview }.count }
    public var queuedCount: Int { transfers.filter { $0.stage == .queued }.count }
    /// Looks for MEGA's free helper app (MEGAcmd) in its standard place and connects it. Returns true when found.
    @discardableResult public func detectMEGAHelper() -> Bool {
        let official = URL(fileURLWithPath: "/Applications/MEGAcmd.app/Contents/MacOS", isDirectory: true)
        guard fm.isExecutableFile(atPath: official.appendingPathComponent("mega-exec").path) else { return false }
        binaryFolder = official; return true
    }
    public var startRequirements: [String] {
        var reasons: [String] = []
        if stateWriteFailed { reasons.append("Transfer history needs attention before continuing.") }
        if demo { reasons.append("Open the live workspace first.") }
        if binaryFolder == nil { reasons.append("Connect the MEGA app (MEGAcmd).") }
        if destination == nil { reasons.append("Choose the iCloud destination folder.") }
        if queuedCount == 0 { reasons.append(transfers.isEmpty ? "Choose the MEGA folder to copy." : "No files are queued. Retry or recheck files needing review.") }
        if !capacityConfirmed { reasons.append("Tick \"iCloud has room\" after checking your iCloud storage.") }
        if busy { reasons.append("Wait for the current operation to finish.") }
        return reasons
    }
    public var controlStatus: String {
        if running {
            if stopSignal.isCancelled { return "Stopping — cancelling this app's download; local work may finish." }
            if pauseRequested { return "Pausing — finishing the current file." }
            return waitingForSpace ? "Waiting for free space" : (activeFiles.count <= 1 ? "Transferring — 1 file at a time" : "Transferring — \(activeFiles.count) files at a time")
        }
        if pauseRequested { return "Paused — progress retained" }
        if !transfers.isEmpty && queuedCount == 0 && !busy {
            if reviewCount > 0 || transfers.contains(where: { $0.stage == .skipped }) { return "Queue finished — review incomplete files" }
            if transfers.contains(where: { $0.stage == .awaitingUpload }) { return destination == nil ? "Reselect iCloud destination to monitor uploads" : "Downloads finished — waiting for iCloud" }
            if transfers.allSatisfy({ [.uploaded, .released].contains($0.stage) }) { return "Run complete — Apple reports uploaded" }
        }
        return startRequirements.isEmpty ? "Ready to transfer" : "Setup required"
    }
    public func pauseAfterFile() {
        guard running, !pauseRequested else { return }
        pauseRequested = true
        log("Pause requested. The current file will finish; no next file will start. Apple uploads may continue.")
    }
    public var releasable: [Transfer] { transfers.filter { $0.stage == .uploaded } }
    public var hasActiveFiles: Bool { transfers.contains { $0.stage.isActive } }
    public var visible: [Transfer] { transfers.filter { t in
        (search.isEmpty || t.entry.relativePath.localizedCaseInsensitiveContains(search)) &&
        (filter == "All files" || (filter == "Uploaded" && [.uploaded, .released].contains(t.stage)) || (filter == "Needs review" && t.stage == .needsReview) || (filter == "Queued" && t.stage == .queued) || (filter == "Deferred" && [.skipped, .excluded].contains(t.stage)))
    } }

    public func loadDemo() {
        guard !running, !busy else { return }
        demo = true; destination = nil; capacityConfirmed = false; runID = UUID()
        let examples: [(String, Int64, TransferStage)] = [
            ("Photography / Iceland / Northern lights.jpg", 28_400_000, .released),
            ("Documents / Personal / Archive 2024.pdf", 8_100_000, .uploaded),
            ("Films / Family / Summer memories.mov", 2_420_000_000, .awaitingUpload),
            ("Photography / Japan / Kyoto morning.jpg", 34_600_000, .downloaded),
            ("Documents / Projects / Brand assets.zip", 184_000_000, .queued),
            ("Photography / Originals / Studio session.dng", 92_000_000, .needsReview),
            ("Documents / Finance / Annual records.pdf", 12_000_000, .queued),
            ("Films / Family / Birthday celebration.mp4", 1_860_000_000, .queued)]
        transfers = examples.map { path, bytes, stage in
            var t = Transfer(entry: .init(remoteHandle: "H:DEMOFILE", relativePath: path, expectedBytes: bytes)); t.stage = stage
            t.note = stage == .needsReview ? "Example: source changed. Review required before continuing." : "Illustrative sample. No real file has been transferred."
            return t
        }
        events = ["Demo workspace opened. All transfer data is illustrative.", "Your MEGA account and iCloud files have not been accessed."]
        selected = transfers.first?.id
    }

    public func openWorkspace() {
        guard !running, !busy else { return }
        // Never overwrite unreadable history with a new empty run.
        let saved: SavedRun?
        do { try acquireRunLock(); saved = try RunJournal(folder: support).load() }
        catch { self.error = "Saved history could not be recovered: \(error.localizedDescription). It was not replaced."; stateWriteFailed = true; return }
        if let name = saved?.runFolderName, name.isEmpty || name.contains("/") || name.contains("\\") || name == "." || name == ".." || Safety.hasUnsafeCharacters(name) {
            error = "Unsafe destination folder in saved history. It was preserved."; stateWriteFailed = true; return
        }
        if let saved, !saved.transfers.isEmpty {
            do {
                try Safety.validate(saved.transfers.map(\.entry))
                guard Set(saved.transfers.map(\.id)).count == saved.transfers.count else { throw HarborError.invalid("Duplicate file identities in saved history.") }
                if let name = saved.runFolderName { guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { throw HarborError.invalid("Unsafe saved destination folder.") } }
            } catch { self.error = "Saved history failed validation and was preserved: \(error.localizedDescription)"; stateWriteFailed = true; return }
        }
        demo = false; transfers = saved?.transfers ?? []; events = saved?.events ?? []
        destination = nil; runID = saved?.runID ?? UUID(); selected = nil
        runFolderName = saved == nil ? "Cloud Transfer+" : saved?.runFolderName
        selectedSourcePath = saved?.sourceRoot
        expectedDestinationPath = saved?.destinationPath; journalSequence = saved?.sequence ?? 0; snapshotRun = nil
        // 0.6: restore the run's iCloud folder when it still exists inside iCloud Drive, and the storage confirmation
        // the user already gave for this run. Previously both were cleared on every launch, silently blocking Start.
        if let path = expectedDestinationPath, let restored = validICloudFolder(URL(fileURLWithPath: path, isDirectory: true)) { destination = restored }
        capacityConfirmed = preferences.bool(forKey: capacityKey)
        for i in transfers.indices where [.downloading, .downloaded, .copying].contains(transfers[i].stage) {
            transfers[i].stage = .needsReview
            transfers[i].note = "App stopped while this file was in progress. Partial data retained. Retry first reconciles this app's service downloads."
        }
        log(saved == nil ? "Workspace ready. Choose your MEGA source and iCloud destination." : destination != nil ? "History recovered. iCloud destination restored." : "History recovered. Reselect the original iCloud destination before continuing.")
    }

    public func log(_ message: String) {
        let event = "\(Date().formatted(date: .omitted, time: .standard)) \(message)"
        events.insert(event, at: 0); dirtyEvent = event
        if events.count > 500 { events.removeLast(events.count - 500) }
        persist()
    }

    public func persist() {
        guard !demo, !stateWriteFailed else { return }
        do {
            let journal = RunJournal(folder: support)
            if snapshotRun != runID || snapshotCount != transfers.count || (dirtyTransfer == nil && dirtyEvent == nil) || journalSequence % 5000 == 0 {
                var saved = SavedRun(transfers: transfers, events: events, runID: runID, destinationPath: destination?.path ?? expectedDestinationPath, runFolderName: runFolderName, sourceRoot: selectedSourcePath)
                saved.sequence = journalSequence
                try journal.writeSnapshot(saved)
                snapshotRun = runID; snapshotCount = transfers.count
                // Move off sequence zero so subsequent transitions append rather than repeatedly snapshot.
                journalSequence += 1
                try journal.append(JournalDelta(runID: runID, sequence: journalSequence, transfer: nil, event: nil, destinationPath: saved.destinationPath, runFolderName: runFolderName))
            } else {
                journalSequence += 1
                try journal.append(JournalDelta(runID: runID, sequence: journalSequence, transfer: dirtyTransfer, event: dirtyEvent, destinationPath: destination?.path ?? expectedDestinationPath, runFolderName: runFolderName))
            }
            dirtyTransfer = nil; dirtyEvent = nil
        } catch {
            stateWriteFailed = true; stopSignal.cancel(); pauseRequested = true
            autoRelease = false; releaseGeneration &+= 1; releaseTask?.cancel()
            self.error = "Transfer history could not be saved. File operations are blocked: \(error.localizedDescription)"
        }
    }

    public func refreshSpace() {
        let available = try? disk.available(at: support)
        freeSpaceKnown = available != nil
        freeBytes = available ?? 0
        // Emergency brake: something else is filling the disk during a download. Stop the download now.
        if !demo && running && freeBytes < Safety.reserve && !stopSignal.isCancelled {
            pauseRequested = true; stopSignal.cancel()
            log("The 50 GB disk reserve was reached or could not be read. Stop requested; the queue is paused.")
        }
    }

    public func chooseBinaries() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.message = "Choose the folder containing the official MEGAcmd mega-get executable. Sign in using MEGAcmd separately."
        if panel.runModal() == .OK, let url = panel.url {
            guard fm.isExecutableFile(atPath: url.appendingPathComponent("mega-exec").path) else { error = "This folder does not contain MEGAcmd's mega-exec. Choose /Applications/MEGAcmd.app/Contents/MacOS."; return }
            binaryFolder = url
        }
    }

    public func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Use this folder"; panel.message = "Choose a folder in iCloud Drive. Files are copied into a \"\(runFolderName ?? "Cloud Transfer+")\" folder inside it."
        panel.directoryURL = destination ?? URL(fileURLWithPath: iCloudRootPath, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            // Guard against accidentally choosing ordinary local storage as a cloud target.
            guard validICloudFolder(url) != nil else { error = "Choose a folder in this Mac's iCloud Drive. Other locations are not supported in this app."; return }
            if let expectedDestinationPath, !TransferStore.samePath(expectedDestinationPath, url.path), transfers.contains(where: { $0.stage != .queued }) {
                error = "This run already copied files to \(expectedDestinationPath). Choose that same folder so nothing is duplicated."; return
            }
            // Choosing the folder no longer unticks the storage confirmation.
            let same = destination.map { TransferStore.samePath($0.path, url.path) } ?? false
            destination = url; expectedDestinationPath = url.path
            destinationConfirmation = same ? "✓ \(iCloudDisplay(url)) is selected (unchanged)." : "✓ Now using \(iCloudDisplay(url))."
            log("iCloud destination selected: \(iCloudDisplay(url)).")
        }
    }

    /// Returns the folder when it exists and is iCloud Drive or inside it.
    public func validICloudFolder(_ url: URL) -> URL? {
        let cloud = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        var isDirectory: ObjCBool = false
        guard path == cloud || path.hasPrefix(cloud + "/"), fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }
    nonisolated public static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path == URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
    }

    public func importManifest() {
        guard !running, !busy, !demo else { return }
        guard transfers.isEmpty else { error = "This run already has a manifest. Use Start new run to archive it first."; return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.message = "Import a reviewed file manifest. This does not start any downloads."
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let attrs = try fm.attributesOfItem(atPath: url.path)
                guard (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 150_000_000 else { throw HarborError.invalid("Manifest exceeds 150 MB.") }
                let entries = try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: url))
                try Safety.validate(entries); capacityConfirmed = false; transfers = entries.map(Transfer.init); selected = transfers.first?.id
                log("Imported \(entries.count) files. Nothing has been downloaded.")
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Lists a MEGA folder with MEGAcmd and writes a manifest for review. Read-only on MEGA; nothing is downloaded.
    public func buildManifest() {
        guard !demo, !running, !busy, let client else { return }
        let alert = NSAlert(); alert.messageText = "Build a manifest from a MEGA folder"
        alert.informativeText = "Enter one absolute MEGA folder, for example /Photos. Exact byte sizes and full source paths are preserved. This only reads metadata; it does not download files."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24)); field.stringValue = "/"; field.setAccessibilityLabel("MEGA source folder")
        alert.accessoryView = field; alert.addButton(withTitle: "Read file list"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let root: String
        do { root = try MegaMetadata.sourceRoot(field.stringValue) } catch { self.error = error.localizedDescription; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let response = try await client.execute(["ls", "-l", "-R", "--show-handles", "--time-format=%s", root], timeout: 180)
                guard response.status == 0 else { throw HarborError.invalid("MEGA could not read this folder (\(response.status)). Check the folder and your sign-in.") }
                let result = try await Task.detached(priority: .utility) { try MegaMetadata.inventory(response.output, root: root) }.value
                let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "manifest.json"
                panel.message = "Save this exact-size manifest. Review it before importing. Source folder names are preserved."
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(result.entries).write(to: url, options: .atomic)
                if !result.excluded.isEmpty {
                    try result.excluded.joined(separator: "\n").write(to: url.deletingPathExtension().appendingPathExtension("excluded.txt"), atomically: true, encoding: .utf8)
                }
                notice = "Saved \(result.entries.count) exact-size files. \(result.excluded.count) unsupported files are listed separately. No file contents were downloaded."
                log(notice!)
            } catch { self.error = error.localizedDescription }
        }
    }

    public func update(_ id: UUID, _ stage: TransferStage, _ note: String, hash: String? = nil) {
        if transferIndex.count != transfers.count || transferIndex[id].map({ !transfers.indices.contains($0) || transfers[$0].id != id }) != false {
            transferIndex = Dictionary(transfers.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        }
        guard let i = transferIndex[id] else { return }
        transfers[i].stage = stage; transfers[i].note = note; transfers[i].updated = Date()
        if let hash { transfers[i].sha256 = hash }
        if stage != .awaitingUpload { uploadFailureFirstSeen.removeValue(forKey: id) }
        dirtyTransfer = transfers[i]
        persist()
    }

    public func startTransfers() {
        guard !running else { return }
        guard startRequirements.isEmpty else { error = startRequirements.joined(separator: "\n"); return }
        running = true; pauseRequested = false; stopSignal = StopSignal(); stopQueue = false; failuresInARow = 0
        requeueRetryable()
        lastAnnouncedPercent = percentComplete; resumeTiming(); startTicking(); refreshWorkerLimit()
        // Keep the Mac awake (the display may still sleep) so transfers continue overnight.
        sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Cloud Transfer+ is copying files")
        announce(.started, "Transfer started. \(spokenProgress)")
        log(turbo ? "Transfers started in Turbo: up to \(workerLimit) files at a time; MEGA originals are preserved." : "Transfers started. Up to \(workerLimit) files at a time (more while the Mac is idle); MEGA originals are preserved.")
        Task {
            do {
                guard let client else { throw HarborError.invalid("MEGAcmd is not connected.") }
                try requireDurableState()
                try await client.cancelOwned(in: stagingRoot)
            } catch { finishRun(); self.error = "Could not reconcile this app's earlier downloads: \(error.localizedDescription)"; return }
            await autoRecheckSetAside()
            var lastLimitCheck = Date.distantPast
            while true {
                if pauseRequested || stopQueue {
                    if inFlight == 0 { break }
                    try? await Task.sleep(nanoseconds: 200_000_000); continue
                }
                if Date().timeIntervalSince(lastLimitCheck) >= 5 { refreshWorkerLimit(); lastLimitCheck = Date() }
                if quietRetries && Date().timeIntervalSince(lastAutoRecheck) >= 120 && reviewCount > 0 { await autoRecheckSetAside() }
                let clock = now()
                guard let t = transfers.first(where: { $0.stage == .queued && !claimed.contains($0.id) && (retryAfter[$0.id] ?? .distantPast) <= clock }) else {
                    let waitingRetries = transfers.contains { $0.stage == .queued && !claimed.contains($0.id) }
                    if inFlight == 0 && !waitingRetries {
                        // Self-check before finishing: anything set aside that can still be retried goes back in the queue.
                        let before = queuedCount; requeueRetryable()
                        if queuedCount > before { log("Self-check: \(queuedCount - before) set-aside file(s) queued again automatically."); continue }
                        break
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000); continue
                }
                if inFlight >= workerLimit || coolingDown { try? await Task.sleep(nanoseconds: 200_000_000); continue }
                refreshSpace()
                let need = 2 * t.entry.expectedBytes + 1_000_000_000
                if !Safety.hasRoom(available: freeBytes - inFlightReservation, size: t.entry.expectedBytes) {
                    if inFlight > 0 { try? await Task.sleep(nanoseconds: 500_000_000); continue } // wait for running files to free space
                    if !waitingForSpace {
                        waitingForSpace = true; pauseTiming()
                        announce(.problem, "Waiting for free space on this Mac.")
                        log("Waiting for free space: the next file needs \(ByteCountFormatter.string(fromByteCount: Safety.requiredSpace(for: t.entry.expectedBytes), countStyle: .decimal)) free. Release uploaded files or turn on automatic release.")
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                if waitingForSpace { waitingForSpace = false; resumeTiming() }
                claimed.insert(t.id); inFlight += 1; inFlightReservation += need
                peakParallel = max(peakParallel, inFlight)
                Task { @MainActor in
                    defer { claimed.remove(t.id); inFlight -= 1; inFlightReservation -= need; activeFiles.removeValue(forKey: t.id) }
                    // A retry first clears this app's own partial download from the previous attempt.
                    if (t.attempts ?? 0) > 0 { _ = await clearSlot(t.id) }
                    do {
                        try await transfer(t); failuresInARow = 0; retryAfter.removeValue(forKey: t.id)
                    } catch {
                        // Stop was pressed: keep the interrupted file for review and stop as asked.
                        if stopSignal.isCancelled {
                            update(t.id, .needsReview, error.localizedDescription)
                            log("Needs review: \(t.entry.relativePath). Partial files retained."); return
                        }
                        let tried = (transfers.first(where: { $0.id == t.id })?.attempts ?? t.attempts ?? 0) + 1
                        if let i = transfers.firstIndex(where: { $0.id == t.id }) { transfers[i].attempts = tried }
                        if tried < maxAttempts || quietRetries {
                            // Partial data is only a copy of the MEGA original; it is cleared once MEGA confirms it stopped.
                            _ = await clearSlot(t.id)
                            let wait = tried >= maxAttempts ? longRetryDelay : backoff(tried)
                            retryAfter[t.id] = now().addingTimeInterval(wait)
                            update(t.id, .queued, "Queued; trying again in \(Int(wait)) seconds (last attempt: \(error.localizedDescription)).")
                            log("Retrying later: \(t.entry.relativePath) — \(error.localizedDescription)")
                        } else {
                            update(t.id, .needsReview, "Set aside after \(tried) automatic attempts: \(error.localizedDescription)")
                            log("Needs review after \(tried) attempts: \(t.entry.relativePath). Other files continue.")
                        }
                        failuresInARow += 1
                        // Many failures in a row means MEGA or the network is down: wait a minute, then carry on (never stop).
                        if failuresInARow >= 5 && !coolingDown {
                            coolingDown = true
                            let pause = effectiveCooldown
                            log("Several files failed in a row. Waiting \(Int(pause)) seconds for MEGA or the network, then continuing automatically.")
                            announce(.problem, "MEGA is not answering. Waiting \(pause >= 60 ? "a minute" : "\(Int(pause)) seconds"), then continuing.")
                            try? await Task.sleep(nanoseconds: UInt64(max(0, pause) * 1_000_000_000))
                            coolingDown = false; failuresInARow = 0
                        }
                    }
                }
            }
            finishRun()
            log(pauseRequested ? "Paused. No further files will start." : "Queue stopped. Check upload and review states.")
            if queuedCount == 0 && reviewCount == 0 { announce(.finished, "Transfer complete. Every file is copied to iCloud. Apple may still be uploading some of them.") }
            else if stopSignal.isCancelled { announce(.stopped, "Transfer stopped. \(spokenProgress)") }
            else if pauseRequested { announce(.paused, "Transfer paused. \(spokenProgress)") }
            else { announce(.problem, "Transfer stopped because files need review. \(spokenProgress)") }
        }
    }

    private func finishRun() {
        waitingForSpace = false; running = false; pauseTiming(); stopTicking()
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity); self.sleepActivity = nil }
    }

    /// Stops the current download immediately and pauses the queue.
    public func stopNow() {
        guard running else { return }
        pauseRequested = true; stopSignal.cancel(); haltReleases()
        log("Stop requested. Cancelling this app's active download; local copying or verification may finish. No next file will start. Apple uploads may continue.")
    }

    public func transfer(_ t: Transfer) async throws {
        guard binaryFolder != nil, let root = runRoot else { throw HarborError.invalid("Select the transfer locations first.") }
        refreshSpace()
        guard Safety.hasRoom(available: freeBytes, size: t.entry.expectedBytes) else { throw HarborError.invalid("Not enough free space for this file plus the 50 GB reserve.") }
        let initialTarget = try Safety.destination(root: root, relativePath: t.entry.relativePath)
        guard !fm.fileExists(atPath: initialTarget.path) else { throw HarborError.invalid("Destination already exists. No download started and no file was overwritten. Review the paths or recheck an earlier verified copy.") }
        let slot = staging.appendingPathComponent(t.id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: slot.path) else { throw HarborError.invalid("A staging folder already exists. Use Retry to clear it.") }
        try fm.createDirectory(at: slot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        update(t.id, .downloading, "Downloading through MEGAcmd. Pause waits for this file; Stop now cancels it.")
        setActive(t, phase: "Downloading", done: 0)
        guard let client else { throw HarborError.invalid("MEGAcmd is not connected.") }
        try requireDurableState()
        let id = t.id
        try await client.download(handle: t.entry.remoteHandle, into: slot, expectedBytes: t.entry.expectedBytes, stop: stopSignal) { [weak self] done in
            Task { @MainActor in if let self, var file = self.activeFiles[id], file.phase == "Downloading" { file.done = done; self.activeFiles[id] = file } }
        }
        setActive(t, phase: "Checking download", done: t.entry.expectedBytes)
        guard !stopSignal.isCancelled else { throw HarborError.invalid("Stopped before local verification.") }
        let children = try fm.contentsOfDirectory(at: slot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard children.count == 1, let file = children.first else { throw HarborError.invalid("Expected exactly one downloaded file; received a folder or ambiguous output.") }
        let props = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard props.isRegularFile == true, props.isSymbolicLink != true, Int64(props.fileSize ?? -1) == t.entry.expectedBytes else { throw HarborError.invalid("Downloaded file type or size differs from manifest. Retained for review.") }
        let hash = try await hasher.digest(file)
        guard !stopSignal.isCancelled else { throw HarborError.invalid("Stopped before copying to iCloud. Staging retained.") }
        update(t.id, .downloaded, "Download size checked; local SHA-256 recorded. Remote bytes have not been independently compared.", hash: hash)
        refreshSpace(); guard freeBytes >= Safety.reserve + t.entry.expectedBytes else { throw HarborError.invalid("Disk reserve reached. Download retained; cloud copy not started.") }
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw HarborError.invalid("Run folder is a symbolic link. Operation blocked.") }
        let target = try Safety.destination(root: root, relativePath: t.entry.relativePath)
        guard !fm.fileExists(atPath: target.path) else { throw HarborError.invalid("Destination already exists. It will not be overwritten.") }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Recheck after parent creation to reject pre-existing symlinks.
        _ = try Safety.destination(root: root, relativePath: t.entry.relativePath)
        update(t.id, .copying, "Copying the downloaded file to the selected iCloud folder.")
        setActive(t, phase: "Copying to iCloud", done: 0)
        try requireDurableState()
        let watcher = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let size = Int64((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if let self, var f = self.activeFiles[id], f.phase == "Copying to iCloud" { f.done = min(size, f.bytes); self.activeFiles[id] = f }
            }
        }
        defer { watcher.cancel() }
        try await Task.detached(priority: .utility) { try FileManager.default.copyItem(at: file, to: target) }.value
        setActive(t, phase: "Checking iCloud copy", done: t.entry.expectedBytes)
        let copiedHash = try await hasher.digest(target)
        guard hash == copiedHash else { throw HarborError.invalid("Local copy checksum mismatch. Both files retained for review.") }
        // The verified iCloud copy and the MEGA original both exist, so the staged download is no longer needed.
        try requireDurableState()
        try removeStagingSlot(slot)
        update(t.id, .awaitingUpload, "Local iCloud copy matches SHA-256; staged download removed. Waiting for Apple's upload status.")
        log("Local copy checked. Waiting for iCloud upload.")
        fileCopied(t)
    }

    /// Deletes one of this app's own staging folders, and only if it is inside the staging root.
    public func removeStagingSlot(_ slot: URL) throws {
        guard fm.fileExists(atPath: slot.path) else { return }
        guard slot.resolvingSymlinksInPath().path.hasPrefix(stagingRoot.resolvingSymlinksInPath().path + "/") else { throw HarborError.invalid("Unsafe staging location. Cleanup blocked.") }
        try fm.removeItem(at: slot)
    }

    nonisolated public static func digest(_ url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 8_388_608), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }.value
    }

    public func refreshUploads() {
        guard !demo, let root = runRoot, !stateWriteFailed else { return }
        defer { recordUploadProgress() }
        // 0.8.3: files whose local copy is verified but iCloud refused them keep being rechecked and recover on their own.
        let candidates = transfers.filter { [.awaitingUpload, .uploaded].contains($0.stage) || ($0.stage == .needsReview && $0.note.hasPrefix(TransferStore.iCloudAttention)) }
        if !candidates.isEmpty {
            // Bound main-thread filesystem work so large libraries remain controllable.
            let count = min(40, candidates.count)
            for offset in 0..<count {
                let t = candidates[(uploadCursor + offset) % candidates.count]
                do {
                    let url = try Safety.destination(root: root, relativePath: t.entry.relativePath)
                    switch cloud.status(of: url) {
                    case .missing:
                        // Self-check (0.8.6): a copied file that vanished from the iCloud folder is copied again automatically.
                        let tried = (t.attempts ?? 0) + 1
                        if let i = transfers.firstIndex(where: { $0.id == t.id }) { transfers[i].attempts = tried }
                        if tried < maxAttempts { update(t.id, .queued, "Self-check: the iCloud copy was missing, so it will be copied again automatically.") }
                        else { update(t.id, .needsReview, "The iCloud destination is missing. A cloud copy has not been confirmed. MEGA original retained.") }
                    case .failed(let message):
                        let first = uploadFailureFirstSeen[t.id] ?? now()
                        uploadFailureFirstSeen[t.id] = first
                        if now().timeIntervalSince(first) >= uploadErrorGrace {
                            let note = "\(TransferStore.iCloudAttention) \(message). The verified local copy is kept and rechecked automatically; it continues as soon as iCloud accepts it. If this lasts, check System Settings › Apple Account › iCloud."
                            if t.stage != .needsReview || t.note != note { update(t.id, .needsReview, note) }
                        } else {
                            let note = "iCloud reported a temporary problem: \(message). Upload is not confirmed; monitoring briefly for recovery. Local copy retained."
                            if t.stage != .awaitingUpload || t.note != note { update(t.id, .awaitingUpload, note) }
                        }
                    case .waiting:
                        uploadFailureFirstSeen.removeValue(forKey: t.id)
                        if t.stage == .uploaded { update(t.id, .awaitingUpload, "Apple no longer reports a completed upload. Local release is blocked.") }
                        if t.stage == .needsReview { update(t.id, .awaitingUpload, "iCloud is reachable again. Waiting for Apple's upload; the verified local copy is kept.") }
                        if cloud.isUploading(url) { if uploadingNow[t.id] == nil { uploadingNow[t.id] = now() } } else { uploadingNow.removeValue(forKey: t.id) }
                    case .uploaded, .uploadedOnlineOnly:
                        uploadFailureFirstSeen.removeValue(forKey: t.id)
                        if t.stage != .uploaded { update(t.id, .uploaded, "Apple reports uploaded. Cloud read-back has not been performed.") }
                    }
                } catch { update(t.id, .needsReview, "Destination could not be checked: \(error.localizedDescription)") }
            }
            uploadCursor = (uploadCursor + count) % candidates.count
            for id in uploadingNow.keys where transfers.first(where: { $0.id == id })?.stage != .awaitingUpload { uploadingNow.removeValue(forKey: id) }
        }
        guard autoRelease, transfersEnabled, !autoReleasing, !releasable.isEmpty else { return }
        let generation = releaseGeneration
        let items = releasable
        autoReleasing = true
        releaseTask = Task {
            defer { if releaseGeneration == generation { autoReleasing = false; releaseTask = nil } }
            for t in items {
                guard autoRelease, releaseGeneration == generation, !Task.isCancelled else { break }
                _ = await releaseOne(t, automaticGeneration: generation)
            }
        }
    }

    public func setAutoRelease(_ on: Bool) {
        if on && (!transfersEnabled || demo || stateWriteFailed) { error = "Automatic release is blocked in the current workspace."; return }
        guard on else {
            autoRelease = false; preferences.set(false, forKey: "autoRelease"); releaseGeneration &+= 1
            releaseTask?.cancel(); releaseTask = nil; autoReleasing = false
            log("Automatic release turned off. Local copies will stay on this Mac until released."); return
        }
        // 0.8.7: no confirmation; the user's choice is remembered.
        releaseGeneration &+= 1; autoRelease = true; preferences.set(true, forKey: "autoRelease")
        log("Automatic release turned on. Local copies are freed after Apple reports each upload; iCloud and MEGA copies stay.")
    }
    /// Stops releases that are in progress right now without changing the user's setting (used by Stop, quit, new source).
    public func haltReleases() {
        releaseGeneration &+= 1; releaseTask?.cancel(); releaseTask = nil; autoReleasing = false
    }

    public func release(_ t: Transfer) {
        guard transfersEnabled, !demo, !busy, t.stage == .uploaded else { return }
        let alert = NSAlert(); alert.messageText = "Release this local copy?"; alert.informativeText = "Apple reports this file uploaded. A cloud download-and-compare has NOT been performed. The MEGA original remains. macOS will be asked to remove the local iCloud download."
        alert.addButton(withTitle: "Keep local copy"); alert.addButton(withTitle: "Release local copy")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        Task { if await releaseOne(t) { log("Local release requested with your approval. Confirm free disk space increased.") }; busy = false }
    }

    public func releaseAll() {
        let items = releasable
        guard transfersEnabled, !demo, !busy, !items.isEmpty else { return }
        let size = ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.entry.expectedBytes }, countStyle: .decimal)
        let alert = NSAlert(); alert.messageText = "Release \(items.count) uploaded files (\(size))?"
        alert.informativeText = "Each file's checksum and upload status is checked again first. A cloud download-and-compare has NOT been performed. The MEGA originals remain. macOS will be asked to remove the local iCloud downloads."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Release \(items.count) files")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        Task {
            var done = 0
            for t in items { if await releaseOne(t) { done += 1 } }
            log("Released \(done) of \(items.count) files with your approval. Confirm free disk space increased.")
            busy = false
        }
    }

    /// Rechecks one uploaded file and asks macOS to evict its local copy. Returns true when release was requested.
    public func releaseOne(_ t: Transfer, automaticGeneration: UInt64? = nil) async -> Bool {
        guard transfersEnabled, !demo, !stateWriteFailed, releaseAuthorized(automaticGeneration), let root = runRoot, let current = transfers.first(where: { $0.id == t.id }), current.stage == .uploaded else { return false }
        do {
            let target = try Safety.destination(root: root, relativePath: current.entry.relativePath)
            guard let expected = current.sha256 else { update(t.id, .needsReview, "No recorded checksum. Release blocked."); return false }
            if case .uploadedOnlineOnly = cloud.status(of: target) {
                guard releaseAuthorized(automaticGeneration) else { return false }
                update(t.id, .released, "Apple reports uploaded and already stored online only. No download, hydration or eviction was requested. Cloud read-back not performed.")
                return !stateWriteFailed
            }
            let available = try disk.available(at: target.deletingLastPathComponent())
            guard available >= Safety.reserve else { throw HarborError.invalid("Insufficient disk reserve for local verification. No local release was requested.") }
            guard try await hasher.digest(target) == expected else { update(t.id, .needsReview, "Local file changed since it was verified. Release blocked."); return false }
            guard releaseAuthorized(automaticGeneration), transfers.first(where: { $0.id == t.id })?.stage == .uploaded else { return false }
            switch cloud.status(of: target) {
            case .uploaded: break
            case .uploadedOnlineOnly: update(t.id, .released, "Apple reports this file is already online only. No further release was needed."); return !stateWriteFailed
            case .missing: update(t.id, .needsReview, "Destination is missing. Release blocked; cloud copy is not confirmed."); return false
            case .failed(let message): update(t.id, .needsReview, "iCloud status could not be verified: \(message)"); return false
            case .waiting: update(t.id, .awaitingUpload, "Upload is not confirmed. Local release postponed."); return false
            }
            try requireDurableState()
            guard releaseAuthorized(automaticGeneration) else { return false }
            try cloud.evict(target)
            try removeStagingSlot(staging.appendingPathComponent(t.id.uuidString, isDirectory: true))
            update(t.id, .released, "Local release requested from macOS. Cloud read-back not performed. MEGA original retained.")
            return true
        } catch {
            if releaseAuthorized(automaticGeneration) { update(t.id, .needsReview, "Release could not be verified: \(error.localizedDescription). No cloud-copy claim was made. Local data was not intentionally deleted.") }
            return false
        }
    }

    private func releaseAuthorized(_ generation: UInt64?) -> Bool {
        if let generation { return autoRelease && generation == releaseGeneration && !Task.isCancelled }
        return true
    }

    private func requireDurableState() throws {
        guard !stateWriteFailed else { throw HarborError.invalid("Transfer history could not be saved. Further file operations are blocked.") }
    }

    /// For a file that needs review or was skipped: accepts an existing matching iCloud copy, or clears the app's staging and queues the file again.
    public func retry(_ t: Transfer) {
        guard transfersEnabled, !demo, !running, !busy, [.needsReview, .skipped].contains(t.stage), let current = transfers.first(where: { $0.id == t.id }), [.needsReview, .skipped].contains(current.stage) else { return }
        guard let root = runRoot else { error = "Reselect the iCloud destination first."; return }
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let client else { throw HarborError.invalid("Reconnect MEGAcmd before retrying.") }
                try requireDurableState()
                try await client.cancelOwned(in: staging.appendingPathComponent(t.id.uuidString, isDirectory: true))
                let target = try Safety.destination(root: root, relativePath: t.entry.relativePath)
                let slot = staging.appendingPathComponent(t.id.uuidString, isDirectory: true)
                if fm.fileExists(atPath: target.path) {
                    guard let expected = t.sha256, try await hasher.digest(target) == expected else {
                        throw HarborError.invalid("A file already exists at \(target.path) and does not match a verified download. It was not changed. Move it out of the run folder in Finder if it is incomplete, then retry.")
                    }
                    try removeStagingSlot(slot)
                    update(t.id, .awaitingUpload, "Existing iCloud copy matches the recorded SHA-256. Waiting for Apple's upload status.")
                    log("Rechecked \(t.entry.relativePath): iCloud copy matches.")
                } else {
                    let alert = NSAlert(); alert.messageText = "Download this file again?"
                    alert.informativeText = "Any partial download this app kept for this file will be deleted from its staging folder. The MEGA original is not touched. The file will be queued again."
                    alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Queue again")
                    guard alert.runModal() == .alertSecondButtonReturn else { return }
                    try removeStagingSlot(slot)
                    update(t.id, .queued, "Queued again after review.")
                    log("Queued again: \(t.entry.relativePath).")
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    public var reviewItems: [Transfer] { transfers.filter { $0.stage == .needsReview } }
    /// Retries every file that needs review in one go (0.8.5). A verified iCloud copy is accepted as is; otherwise this
    /// app's own partial download is cleared after MEGA confirms it stopped, and the file is queued again.
    public func retryAllReview() {
        let items = reviewItems
        guard transfersEnabled, !demo, !busy, !stateWriteFailed, !items.isEmpty else { return }
        guard let root = runRoot else { error = "Choose the iCloud destination first."; return }
        let alert = NSAlert(); alert.messageText = "Retry \(items.count) file\(items.count == 1 ? "" : "s")?"
        alert.informativeText = "Each file is checked again. A matching iCloud copy is kept; otherwise this app's partial download is cleared and the file is downloaded again. MEGA originals are never touched."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Retry \(items.count)")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        Task {
            defer { busy = false }
            var queued = 0, accepted = 0, kept = 0
            for t in items {
                guard let current = transfers.first(where: { $0.id == t.id }), current.stage == .needsReview else { continue }
                let slot = staging.appendingPathComponent(t.id.uuidString, isDirectory: true)
                do {
                    let target = try Safety.destination(root: root, relativePath: t.entry.relativePath)
                    if fm.fileExists(atPath: target.path) {
                        if let expected = current.sha256, try await hasher.digest(target) == expected {
                            try removeStagingSlot(slot)
                            update(t.id, .awaitingUpload, "Existing iCloud copy matches the recorded SHA-256. Waiting for Apple's upload status.")
                            accepted += 1
                        } else { kept += 1 }
                        continue
                    }
                    if fm.fileExists(atPath: slot.path) {
                        guard let client else { throw HarborError.invalid("Reconnect MEGAcmd before retrying.") }
                        try await client.cancelOwned(in: slot)
                        try removeStagingSlot(slot)
                    }
                    retryAfter.removeValue(forKey: t.id)
                    if let i = transfers.firstIndex(where: { $0.id == t.id }) { transfers[i].attempts = 0 }
                    update(t.id, .queued, "Queued again after Retry all.")
                    queued += 1
                } catch { kept += 1; log("Could not retry \(t.entry.relativePath): \(error.localizedDescription)") }
            }
            log("Retry all: \(queued) queued again, \(accepted) already in iCloud, \(kept) still need a look.")
            notice = "\(queued) queued again, \(accepted) already safely in iCloud\(kept > 0 ? ", \(kept) still need a look (an unexpected file is in the way)" : "")." + (running ? "" : " Press Start transfers to continue.")
        }
    }

    public func skip(_ t: Transfer) {
        guard !demo, !busy, [.queued, .awaitingUpload, .needsReview].contains(t.stage), transfers.first(where: { $0.id == t.id })?.stage == t.stage else { return }
        update(t.id, .skipped, "Deferred without a confirmed backup. Any local copy and MEGA original are preserved. Retry or recheck before counting it as migrated.")
        log("Skipped: \(t.entry.relativePath).")
    }

    /// Archives the current run's history so a new manifest can be imported.
    public func startNewRun() {
        guard !demo, !running, !busy, !autoReleasing, !stateWriteFailed, !transfers.isEmpty else { return }
        guard !hasActiveFiles else { error = "Queued or waiting files remain. Finish them or use Defer before starting a new run."; return }
        let unfinished = transfers.filter { [.needsReview, .skipped].contains($0.stage) }.count
        let alert = NSAlert(); alert.messageText = "Archive this run and start a new one?"
        alert.informativeText = "This run's history will be archived. Uploaded files stay in iCloud. \(unfinished) deferred or review items are not confirmed backups; any partial local files are retained for review. This app's service downloads must be reconciled first."
        alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Archive and start new run")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        haltReleases(); busy = true
        Task {
            defer { busy = false }
            do {
                try await archiveFinishedRun()
            } catch { self.error = "Run was not reset: \(error.localizedDescription). Retained local files were not deleted." }
        }
    }

    private func archiveFinishedRun() async throws {
        guard !running, !hasActiveFiles, !autoReleasing else { throw HarborError.invalid("Finish or defer the current run before selecting another source.") }
        try requireDurableState()
        if fm.fileExists(atPath: staging.path) {
            guard let client else { throw HarborError.invalid("Reconnect MEGAcmd before archiving partial downloads.") }
            try await client.cancelOwned(in: staging)
        }
        try fm.createDirectory(at: archiveFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let archived = archiveFolder.appendingPathComponent("run-\(stamp)-\(runID.uuidString).json")
        let data = try JSONEncoder().encode(SavedRun(transfers: transfers, events: events, runID: runID, destinationPath: destination?.path ?? expectedDestinationPath, runFolderName: runFolderName, sourceRoot: selectedSourcePath))
        try data.write(to: archived, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archived.path)
        // Do not delete retained evidence or a potentially sole local copy when archiving.
        transfers = []; events = []; selectedSourcePath = nil; runID = UUID(); runFolderName = "Cloud Transfer+"; selected = nil
        journalSequence = 0; snapshotRun = nil; dirtyTransfer = nil; dirtyEvent = nil
        expectedDestinationPath = destination?.path; capacityConfirmed = false
        log("New run started. Previous history archived; partial local data retained for review.")
    }

    public func prepareSourceFolder(_ path: String, handle: String? = nil) {
        guard !demo, !running, !busy, !stateWriteFailed, let client else { return }
        guard !hasActiveFiles else { error = "Finish or defer the current run before selecting another source."; return }
        let root: String
        do { root = try MegaMetadata.sourceRoot(path) } catch { self.error = error.localizedDescription; return }
        if let handle, handle.range(of: Safety.handlePattern, options: .regularExpression) == nil { error = "Invalid MEGA folder identity."; return }
        if !transfers.isEmpty {
            let alert = NSAlert(); alert.messageText = "Use this folder for a new backup?"
            alert.informativeText = "The completed run's history will be archived. Existing iCloud files, MEGA originals and retained partial files stay untouched. No download starts until you press Start transfers."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Use folder")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        haltReleases(); busy = true
        Task {
            defer { busy = false }
            do {
                let response = try await client.execute(["ls", "-l", "-R", "--show-handles", "--time-format=%s", handle ?? root], timeout: 180)
                guard response.status == 0 else { throw HarborError.invalid("MEGA could not read the chosen folder.") }
                let result = try await Task.detached(priority: .utility) { try MegaMetadata.inventory(response.output, root: root) }.value
                // Do not archive a previous run until the new folder inventory has succeeded.
                if !transfers.isEmpty { try await archiveFinishedRun() }
                try requireDurableState()
                selectedSourcePath = root; capacityConfirmed = false
                transfers = result.entries.map { entry in
                    var t = Transfer(entry: entry)
                    if TransferStore.isSystemJunk(entry.relativePath) { t.stage = .excluded; t.note = "Excluded: Windows Recycle Bin or system file. Not copied. The MEGA original is untouched; use Include again to copy it." }
                    return t
                }
                selected = transfers.first?.id
                log("Selected MEGA folder \(root): \(transfers.count) files ready. Nothing downloaded.")
                sourceConfirmation = "✓ \(transfers.count.formatted()) files listed from MEGA \(root). Nothing downloaded yet."
                try requireDurableState()
                if !result.excluded.isEmpty {
                    let report = support.appendingPathComponent("source-exclusions.txt")
                    try result.excluded.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
                    notice = "\(result.excluded.count) unsupported files were excluded. Review source-exclusions.txt in this run's history folder before treating this source as fully migrated."
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    public func exportReport() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = demo ? "Cloud-Transfer-Plus-DEMO-report.json" : "Cloud-Transfer-Plus-report.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(SavedRun(transfers: transfers, events: [demo ? "DEMO DATA — NO REAL TRANSFERS" : "Transfer report. Upload reported is not cloud read-back verification."] + events, runID: runID, destinationPath: destination?.path ?? expectedDestinationPath, runFolderName: runFolderName, sourceRoot: selectedSourcePath)).write(to: url, options: .atomic) }
            catch { self.error = error.localizedDescription }
        }
    }
}
